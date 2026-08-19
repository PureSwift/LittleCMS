import CLCMS2
import LittleCMS

// The four built-in optimization schemes.
//
// Each takes a pipeline and, when it applies, replaces it with a
// faster equivalent that answers slightly differently — which is why a
// caller can turn them off, and why every probe so far did.  In order
// of preference: a chain of curves alone becomes one table per channel;
// a matrix-shaper pair at 8 bits becomes fixed-point tables and one
// matrix; an RGB transform gets prelinearisation curves and a CLUT; and
// anything else 16-bit becomes a CLUT, keeping the end curves it had.
// The evaluators these install are the reference's, including its
// fixed-point arithmetic, so that the answers are the reference's.

private let prelinearizationPoints: cmsUInt32Number = 4096

@inline(__always)
private func pipeline(_ p: UnsafeMutablePointer<cmsPipeline>?) -> PipelineBox? {
    guard let p else { return nil }
    return Unmanaged<PipelineBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

@inline(__always) private func isFloat(_ f: cmsUInt32Number) -> Bool { PixelFormat(f).floatingPoint }
@inline(__always) private func is8bit(_ f: cmsUInt32Number) -> Bool { PixelFormat(f).bytes == 1 }

/// The stages of a pipeline when they are exactly these types, in order.
private func stages(
    _ lut: UnsafeMutablePointer<cmsPipeline>?, _ types: [cmsStageSignature]
) -> [UnsafeMutablePointer<cmsStage>]? {
    if Int(cmsPipelineStageCount(lut)) != types.count { return nil }
    var found: [UnsafeMutablePointer<cmsStage>] = []
    var stage = cmsPipelineGetPtrToFirstStage(lut)
    for type in types {
        guard let s = stage, cmsStageType(s) == type else { return nil }
        found.append(s)
        stage = cmsStageNext(s)
    }
    return found
}

private func curveSet(_ mpe: UnsafeMutablePointer<cmsStage>?) -> UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>? {
    guard let mpe, cmsStageType(mpe) == cmsSigCurveSetElemType,
          let data = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self)
    else { return nil }
    return data.pointee.TheCurves
}

private func allCurvesAreLinear(_ mpe: UnsafeMutablePointer<cmsStage>?) -> Bool {
    guard let curves = curveSet(mpe) else { return false }
    for i in 0..<Int(cmsStageOutputChannels(mpe)) where cmsIsToneCurveLinear(curves[i]) == 0 {
        return false
    }
    return true
}

// -- the resampler ---------------------------------------------------------------

/// A sampler implemented by another pipeline: the way a CLUT is filled
/// from whatever the pipeline computes.  Float in the middle, 16 bits
/// at the ends.
private func xformSampler16(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let lut = Cargo.assumingMemoryBound(to: cmsPipeline.self)
    let inputs = Int(cmsPipelineInputChannels(lut))
    let outputs = Int(cmsPipelineOutputChannels(lut))
    var inFloat = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    var outFloat = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    for i in 0..<inputs { inFloat[i] = cmsFloat32Number(Double(In[i]) / 65535.0) }
    cmsPipelineEvalFloat(&inFloat, &outFloat, lut)
    for i in 0..<outputs { Out[i] = quickSaturateWord(Double(outFloat[i]) * 65535.0) }
    return 1
}

// The 16-bit prelinearised evaluator: curves in, a CLUT, curves out,
// each through its interpolation parameters.  A missing curve is a
// pass-through.

private struct Prelin16Data {
    var nInputs: Int
    var nOutputs: Int
    var paramsIn: UnsafeMutablePointer<UnsafeMutablePointer<cmsInterpParams>?>
    var clut: UnsafeMutablePointer<cmsInterpParams>
    var paramsOut: UnsafeMutablePointer<UnsafeMutablePointer<cmsInterpParams>?>
}

private func prelinEval16(
    _ Input: UnsafePointer<cmsUInt16Number>?, _ Output: UnsafeMutablePointer<cmsUInt16Number>?, _ D: UnsafeRawPointer?
) {
    guard let Input, let Output, let D else { return }
    let p16 = D.assumingMemoryBound(to: Prelin16Data.self).pointee
    var stageABC = [cmsUInt16Number](repeating: 0, count: Int(MAX_INPUT_DIMENSIONS))
    var stageDEF = [cmsUInt16Number](repeating: 0, count: maximumChannels)

    for i in 0..<p16.nInputs {
        if let params = p16.paramsIn[i], let lerp = params.pointee.Interpolation.Lerp16 {
            lerp(Input + i, &stageABC[i], params)
        } else {
            stageABC[i] = Input[i]
        }
    }
    p16.clut.pointee.Interpolation.Lerp16?(stageABC, &stageDEF, p16.clut)
    for i in 0..<p16.nOutputs {
        if let params = p16.paramsOut[i], let lerp = params.pointee.Interpolation.Lerp16 {
            lerp(&stageDEF[i], Output + i, params)
        } else {
            Output[i] = stageDEF[i]
        }
    }
}

private func prelinOpt16free(_ ContextID: cmsContext?, _ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }
    let p16 = ptr.assumingMemoryBound(to: Prelin16Data.self).pointee
    _cmsFree(ContextID, UnsafeMutableRawPointer(p16.paramsIn))
    _cmsFree(ContextID, UnsafeMutableRawPointer(p16.paramsOut))
    _cmsFree(ContextID, ptr)
}

private func prelin16dup(_ ContextID: cmsContext?, _ ptr: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr else { return nil }
    let source = ptr.assumingMemoryBound(to: Prelin16Data.self).pointee
    guard let copy = _cmsDupMem(ContextID, ptr, cmsUInt32Number(MemoryLayout<Prelin16Data>.size)) else { return nil }
    let stride = cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsInterpParams>?>.stride)
    let p = copy.assumingMemoryBound(to: Prelin16Data.self)
    // The reference copies only the output list; the input list lives
    // inline in its struct.  Both are copied here since both are heap.
    guard let ins = _cmsDupMem(ContextID, source.paramsIn, cmsUInt32Number(source.nInputs) * stride),
          let outs = _cmsDupMem(ContextID, source.paramsOut, cmsUInt32Number(source.nOutputs) * stride)
    else {
        _cmsFree(ContextID, copy)
        return nil
    }
    p.pointee.paramsIn = ins.assumingMemoryBound(to: UnsafeMutablePointer<cmsInterpParams>?.self)
    p.pointee.paramsOut = outs.assumingMemoryBound(to: UnsafeMutablePointer<cmsInterpParams>?.self)
    return copy
}

private func prelinOpt16alloc(
    _ ContextID: cmsContext?, _ colorMap: UnsafeMutablePointer<cmsInterpParams>,
    _ nInputs: Int, _ inCurves: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>?,
    _ nOutputs: Int, _ outCurves: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> UnsafeMutableRawPointer? {
    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<Prelin16Data>.size)) else { return nil }
    let stride = cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsInterpParams>?>.stride)
    guard let ins = _cmsCalloc(ContextID, cmsUInt32Number(max(nInputs, 1)), stride) else {
        _cmsFree(ContextID, raw)
        return nil
    }
    guard let outs = _cmsCalloc(ContextID, cmsUInt32Number(max(nOutputs, 1)), stride) else {
        _cmsFree(ContextID, ins)
        _cmsFree(ContextID, raw)
        return nil
    }
    let paramsIn = ins.assumingMemoryBound(to: UnsafeMutablePointer<cmsInterpParams>?.self)
    let paramsOut = outs.assumingMemoryBound(to: UnsafeMutablePointer<cmsInterpParams>?.self)
    for i in 0..<nInputs { paramsIn[i] = inCurves?[i]?.pointee.InterpParams }
    for i in 0..<nOutputs { paramsOut[i] = outCurves?[i]?.pointee.InterpParams }

    raw.assumingMemoryBound(to: Prelin16Data.self).initialize(to: Prelin16Data(
        nInputs: nInputs, nOutputs: nOutputs, paramsIn: paramsIn, clut: colorMap, paramsOut: paramsOut
    ))
    return raw
}

// -- fixing the white ------------------------------------------------------------------

/// Sets one node of a CLUT — the one exactly at `at`, when `at` lands
/// on a node — to `value`.  For 1, 3 and 4 inputs.
private func patchLUT(
    _ clut: UnsafeMutablePointer<cmsStage>, _ at: [cmsUInt16Number], _ value: [cmsUInt16Number],
    _ nChannelsOut: Int, _ nChannelsIn: Int
) -> Bool {
    guard cmsStageType(clut) == cmsSigCLutElemType else {
        report(cmsUInt32Number(cmsERROR_INTERNAL), "(internal) Attempt to PatchLUT on non-lut stage", to: cmsGetStageContextID(clut))
        return false
    }
    guard let grid = cmsStageData(clut)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let p16 = grid.pointee.Params, let table = grid.pointee.Tab.T
    else { return false }
    let domain = withUnsafeBytes(of: &p16.pointee.Domain) { $0.bindMemory(to: cmsUInt32Number.self).map { Double($0) } }
    let opta = withUnsafeBytes(of: &p16.pointee.opta) { $0.bindMemory(to: cmsUInt32Number.self).map { Int($0) } }

    var index = 0
    switch nChannelsIn {
    case 4:
        let px = Double(at[0]) * domain[0] / 65535.0
        let py = Double(at[1]) * domain[1] / 65535.0
        let pz = Double(at[2]) * domain[2] / 65535.0
        let pw = Double(at[3]) * domain[3] / 65535.0
        let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
        let z0 = Int(pz.rounded(.down)), w0 = Int(pw.rounded(.down))
        if px - Double(x0) != 0 || py - Double(y0) != 0 || pz - Double(z0) != 0 || pw - Double(w0) != 0 { return false }
        index = opta[3] * x0 + opta[2] * y0 + opta[1] * z0 + opta[0] * w0
    case 3:
        let px = Double(at[0]) * domain[0] / 65535.0
        let py = Double(at[1]) * domain[1] / 65535.0
        let pz = Double(at[2]) * domain[2] / 65535.0
        let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down)), z0 = Int(pz.rounded(.down))
        if px - Double(x0) != 0 || py - Double(y0) != 0 || pz - Double(z0) != 0 { return false }
        index = opta[2] * x0 + opta[1] * y0 + opta[0] * z0
    case 1:
        let px = Double(at[0]) * domain[0] / 65535.0
        let x0 = Int(px.rounded(.down))
        if px - Double(x0) != 0 { return false }
        index = opta[0] * x0
    default:
        report(
            cmsUInt32Number(cmsERROR_INTERNAL),
            "(internal) \(nChannelsIn) Channels are not supported on PatchLUT", to: cmsGetStageContextID(clut)
        )
        return false
    }
    for i in 0..<nChannelsOut { table[index + i] = value[i] }
    return true
}

/// Equal, or so far apart that fixing them would be wrong.
private func whitesAreEqual(_ n: Int, _ white1: [cmsUInt16Number], _ white2: [cmsUInt16Number]) -> Bool {
    for i in 0..<n {
        if abs(Int(white1[i]) - Int(white2[i])) > 0xF000 { return true }
        if white1[i] != white2[i] { return false }
    }
    return true
}

/// Pins the node for the input white to the output white, so that white
/// comes out white — the scum dot fix.  Through the pre and post curves
/// when the pipeline has them.
@discardableResult
private func fixWhiteMisalignment(
    _ lut: UnsafeMutablePointer<cmsPipeline>, _ entry: cmsColorSpaceSignature, _ exit: cmsColorSpaceSignature
) -> Bool {
    guard let inEnds = endPointsBySpace(entry), let outEnds = endPointsBySpace(exit) else { return false }
    let whitePointIn = inEnds.white, whitePointOut = outEnds.white
    let nIns = whitePointIn.count, nOuts = whitePointOut.count

    if Int(cmsPipelineInputChannels(lut)) != nIns { return false }
    if Int(cmsPipelineOutputChannels(lut)) != nOuts { return false }

    var obtained = [cmsUInt16Number](repeating: 0, count: maximumChannels)
    cmsPipelineEval16(whitePointIn, &obtained, lut)
    if whitesAreEqual(nOuts, whitePointOut, obtained) { return true }

    let curves = cmsSigCurveSetElemType, clutType = cmsSigCLutElemType
    var preLin: UnsafeMutablePointer<cmsStage>?, clut: UnsafeMutablePointer<cmsStage>?, postLin: UnsafeMutablePointer<cmsStage>?
    if let s = stages(lut, [curves, clutType, curves]) {
        preLin = s[0]; clut = s[1]; postLin = s[2]
    } else if let s = stages(lut, [curves, clutType]) {
        preLin = s[0]; clut = s[1]
    } else if let s = stages(lut, [clutType, curves]) {
        clut = s[0]; postLin = s[1]
    } else if let s = stages(lut, [clutType]) {
        clut = s[0]
    } else {
        return false
    }
    guard let clut else { return false }

    var whiteIn = whitePointIn
    if let pre = curveSet(preLin) {
        for i in 0..<nIns { whiteIn[i] = cmsEvalToneCurve16(pre[i], whitePointIn[i]) }
    }
    var whiteOut = whitePointOut
    if let post = curveSet(postLin) {
        for i in 0..<nOuts {
            if let inverse = cmsReverseToneCurve(post[i]) {
                whiteOut[i] = cmsEvalToneCurve16(inverse, whitePointOut[i])
                cmsFreeToneCurve(inverse)
            }
        }
    }
    _ = patchLUT(clut, whiteIn, whiteOut, nOuts, nIns)
    return true
}

/// Resamples the pipeline into a CLUT of a reasonable size, keeping the
/// pipeline's own first and last curves as pre and post linearisation
/// when the flags allow and they are not linear.
func optimizeByResampling(
    _ Lut: UnsafeMutablePointer<UnsafeMutablePointer<cmsPipeline>?>, _ Intent: cmsUInt32Number,
    _ InputFormat: UnsafeMutablePointer<cmsUInt32Number>, _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>,
    _ dwFlags: UnsafeMutablePointer<cmsUInt32Number>
) -> Bool {
    if isFloat(InputFormat.pointee) || isFloat(OutputFormat.pointee) { return false }
    let colorSpace = _cmsICCcolorSpace(cmsInt32Number(PixelFormat(InputFormat.pointee).colorSpace))
    let outputColorSpace = _cmsICCcolorSpace(cmsInt32Number(PixelFormat(OutputFormat.pointee).colorSpace))
    if colorSpace == cmsColorSpaceSignature(0) || outputColorSpace == cmsColorSpaceSignature(0) { return false }

    guard let src = Lut.pointee else { return false }
    let nGridPoints: cmsUInt32Number
    if cmsPipelineStageCount(src) == 0 {
        nGridPoints = 2
    } else {
        nGridPoints = _cmsReasonableGridpointsByColorspace(colorSpace, dwFlags.pointee)
        // 16-bit Lab in cannot be resampled: centring.
        if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_FORCE_CLUT) == 0 && colorSpace == cmsSigLabData
            && PixelFormat(InputFormat.pointee).bytes == 2
        {
            return false
        }
    }

    let ContextID = cmsGetPipelineContextID(src)
    let inputs = cmsPipelineInputChannels(src), outputs = cmsPipelineOutputChannels(src)
    guard let dest = cmsPipelineAlloc(ContextID, inputs, outputs) else { return false }

    var keepPreLin: UnsafeMutablePointer<cmsStage>?, keepPostLin: UnsafeMutablePointer<cmsStage>?
    var newPreLin: UnsafeMutablePointer<cmsStage>?, newPostLin: UnsafeMutablePointer<cmsStage>?

    func fail() -> Bool {
        if let k = keepPreLin { _ = cmsPipelineInsertStage(src, cmsAT_BEGIN, k) }
        if let k = keepPostLin { _ = cmsPipelineInsertStage(src, cmsAT_END, k) }
        cmsPipelineFree(dest)
        return false
    }

    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_CLUT_PRE_LINEARIZATION) != 0 {
        if let preLin = cmsPipelineGetPtrToFirstStage(src), cmsStageType(preLin) == cmsSigCurveSetElemType,
           !allCurvesAreLinear(preLin)
        {
            newPreLin = cmsStageDup(preLin)
            if cmsPipelineInsertStage(dest, cmsAT_BEGIN, newPreLin) == 0 { return fail() }
            cmsPipelineUnlinkStage(src, cmsAT_BEGIN, &keepPreLin)
        }
    }

    guard let clut = cmsStageAllocCLut16bit(ContextID, nGridPoints, inputs, outputs, nil) else { return fail() }
    if cmsPipelineInsertStage(dest, cmsAT_END, clut) == 0 { return fail() }

    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_CLUT_POST_LINEARIZATION) != 0 {
        if let postLin = cmsPipelineGetPtrToLastStage(src), cmsStageType(postLin) == cmsSigCurveSetElemType,
           !allCurvesAreLinear(postLin)
        {
            newPostLin = cmsStageDup(postLin)
            if cmsPipelineInsertStage(dest, cmsAT_END, newPostLin) == 0 { return fail() }
            cmsPipelineUnlinkStage(src, cmsAT_END, &keepPostLin)
        }
    }

    if cmsStageSampleCLut16bit(clut, xformSampler16, UnsafeMutableRawPointer(src), 0) == 0 { return fail() }

    if let k = keepPreLin { cmsStageFree(k) }
    if let k = keepPostLin { cmsStageFree(k) }
    cmsPipelineFree(src)

    guard let dataCLUT = cmsStageData(clut)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = dataCLUT.pointee.Params
    else {
        cmsPipelineFree(dest)
        return false
    }
    let dataSetIn = curveSet(newPreLin)
    let dataSetOut = curveSet(newPostLin)

    if dataSetIn == nil && dataSetOut == nil {
        // The CLUT's own kernel serves as the evaluator, with its
        // parameters as the data — the reference casts the one function
        // type to the other, and the argument types agree.
        guard let lerp = params.pointee.Interpolation.Lerp16 else {
            cmsPipelineFree(dest)
            return false
        }
        let evaluator = unsafeBitCast(lerp, to: _cmsPipelineEval16Fn.self)
        _cmsPipelineSetOptimizationParameters(dest, evaluator, UnsafeMutableRawPointer(params), nil, nil)
    } else {
        guard let p16 = prelinOpt16alloc(ContextID, params, Int(inputs), dataSetIn, Int(outputs), dataSetOut) else {
            cmsPipelineFree(dest)
            return false
        }
        _cmsPipelineSetOptimizationParameters(dest, prelinEval16, p16, prelinOpt16free, prelin16dup)
    }

    if Intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP)
    }
    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP) == 0 {
        fixWhiteMisalignment(dest, colorSpace, outputColorSpace)
    }
    Lut.pointee = dest
    return true
}

// -- prelinearisation for RGB ---------------------------------------------------------

/// Straightens the first and last 2% of a curve into lines to the end
/// points, so that they are reached.
private func slopeLimiting(_ g: UnsafeMutablePointer<cmsToneCurve>) {
    guard let table = g.pointee.Table16 else { return }
    let nEntries = Int(g.pointee.nEntries)
    let atBegin = Int((Double(nEntries) * 0.02 + 0.5).rounded(.down))
    let atEnd = nEntries - atBegin - 1
    let beginVal: Double, endVal: Double
    if cmsIsToneCurveDescending(g) != 0 {
        beginVal = 0xFFFF; endVal = 0
    } else {
        beginVal = 0; endVal = 0xFFFF
    }

    var val = Double(table[atBegin])
    var slope = (val - beginVal) / Double(atBegin)
    var beta = val - slope * Double(atBegin)
    for i in 0..<atBegin { table[i] = quickSaturateWord(Double(i) * slope + beta) }

    val = Double(table[atEnd])
    slope = (endVal - val) / Double(atBegin)
    beta = val - slope * Double(atEnd)
    for i in atEnd..<nEntries { table[i] = quickSaturateWord(Double(i) * slope + beta) }
}

/// The 8-bit prelinearised evaluator's tables: for each of the 256 input
/// values per channel, the node and the offset within it — the
/// tetrahedral interpolation's set-up done once.
private struct Prelin8Data {
    var p: UnsafeMutablePointer<cmsInterpParams>
    var rx: [UInt16], ry: [UInt16], rz: [UInt16]
    var x0: [UInt32], y0: [UInt32], z0: [UInt32]
}

@inline(__always) private func toFixedDomain(_ a: Int32) -> Int32 { a &+ ((a &+ 0x7FFF) / 0xFFFF) }

private func prelinOpt8alloc(
    _ ContextID: cmsContext?, _ p: UnsafeMutablePointer<cmsInterpParams>,
    _ g: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> UnsafeMutableRawPointer? {
    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<Prelin8Data>.size)) else { return nil }
    let domain = withUnsafeBytes(of: &p.pointee.Domain) { $0.bindMemory(to: cmsUInt32Number.self).map { Int32($0) } }
    let opta = withUnsafeBytes(of: &p.pointee.opta) { $0.bindMemory(to: cmsUInt32Number.self).map { UInt32($0) } }

    var data = Prelin8Data(
        p: p,
        rx: [UInt16](repeating: 0, count: 256), ry: [UInt16](repeating: 0, count: 256), rz: [UInt16](repeating: 0, count: 256),
        x0: [UInt32](repeating: 0, count: 256), y0: [UInt32](repeating: 0, count: 256), z0: [UInt32](repeating: 0, count: 256)
    )
    for i in 0..<256 {
        var input: [Int32]
        if let g {
            input = [
                Int32(cmsEvalToneCurve16(g[0], widen(UInt8(i)))),
                Int32(cmsEvalToneCurve16(g[1], widen(UInt8(i)))),
                Int32(cmsEvalToneCurve16(g[2], widen(UInt8(i)))),
            ]
        } else {
            let v = Int32(widen(UInt8(i)))
            input = [v, v, v]
        }
        let v1 = toFixedDomain(input[0] &* domain[0])
        let v2 = toFixedDomain(input[1] &* domain[1])
        let v3 = toFixedDomain(input[2] &* domain[2])

        data.x0[i] = opta[2] &* UInt32(bitPattern: v1 >> 16)
        data.y0[i] = opta[1] &* UInt32(bitPattern: v2 >> 16)
        data.z0[i] = opta[0] &* UInt32(bitPattern: v3 >> 16)
        data.rx[i] = UInt16(truncatingIfNeeded: v1 & 0xFFFF)
        data.ry[i] = UInt16(truncatingIfNeeded: v2 & 0xFFFF)
        data.rz[i] = UInt16(truncatingIfNeeded: v3 & 0xFFFF)
    }
    raw.assumingMemoryBound(to: Prelin8Data.self).initialize(to: data)
    return raw
}

private func prelin8free(_ ContextID: cmsContext?, _ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }
    ptr.assumingMemoryBound(to: Prelin8Data.self).deinitialize(count: 1)
    _cmsFree(ContextID, ptr)
}

private func prelin8dup(_ ContextID: cmsContext?, _ ptr: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr, let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<Prelin8Data>.size)) else { return nil }
    raw.assumingMemoryBound(to: Prelin8Data.self).initialize(to: ptr.assumingMemoryBound(to: Prelin8Data.self).pointee)
    return raw
}

/// Tetrahedral interpolation for 8-bit input over the precomputed
/// tables, in the reference's fixed point.
private func prelinEval8(
    _ Input: UnsafePointer<cmsUInt16Number>?, _ Output: UnsafeMutablePointer<cmsUInt16Number>?, _ D: UnsafeRawPointer?
) {
    guard let Input, let Output, let D else { return }
    let p8 = D.assumingMemoryBound(to: Prelin8Data.self)
    let p = p8.pointee.p
    let totalOut = Int(p.pointee.nOutputs)
    guard let lutTable = p.pointee.Table?.assumingMemoryBound(to: cmsUInt16Number.self) else { return }
    let opta = withUnsafeBytes(of: &p.pointee.opta) { $0.bindMemory(to: cmsUInt32Number.self).map { Int32($0) } }

    let r = Int(Input[0] >> 8), g = Int(Input[1] >> 8), b = Int(Input[2] >> 8)
    let x0 = Int32(bitPattern: p8.pointee.x0[r]), y0 = Int32(bitPattern: p8.pointee.y0[g]), z0 = Int32(bitPattern: p8.pointee.z0[b])
    let rx = Int32(p8.pointee.rx[r]), ry = Int32(p8.pointee.ry[g]), rz = Int32(p8.pointee.rz[b])
    let x1 = x0 &+ (rx == 0 ? 0 : opta[2])
    let y1 = y0 &+ (ry == 0 ? 0 : opta[1])
    let z1 = z0 &+ (rz == 0 ? 0 : opta[0])

    for outChan in 0..<totalOut {
        @inline(__always) func dens(_ i: Int32, _ j: Int32, _ k: Int32) -> Int32 {
            Int32(lutTable[Int(i &+ j &+ k) + outChan])
        }
        let c0 = dens(x0, y0, z0)
        var c1: Int32, c2: Int32, c3: Int32
        if rx >= ry && ry >= rz {
            c1 = dens(x1, y0, z0) - c0
            c2 = dens(x1, y1, z0) - dens(x1, y0, z0)
            c3 = dens(x1, y1, z1) - dens(x1, y1, z0)
        } else if rx >= rz && rz >= ry {
            c1 = dens(x1, y0, z0) - c0
            c2 = dens(x1, y1, z1) - dens(x1, y0, z1)
            c3 = dens(x1, y0, z1) - dens(x1, y0, z0)
        } else if rz >= rx && rx >= ry {
            c1 = dens(x1, y0, z1) - dens(x0, y0, z1)
            c2 = dens(x1, y1, z1) - dens(x1, y0, z1)
            c3 = dens(x0, y0, z1) - c0
        } else if ry >= rx && rx >= rz {
            c1 = dens(x1, y1, z0) - dens(x0, y1, z0)
            c2 = dens(x0, y1, z0) - c0
            c3 = dens(x1, y1, z1) - dens(x1, y1, z0)
        } else if ry >= rz && rz >= rx {
            c1 = dens(x1, y1, z1) - dens(x0, y1, z1)
            c2 = dens(x0, y1, z0) - c0
            c3 = dens(x0, y1, z1) - dens(x0, y1, z0)
        } else if rz >= ry && ry >= rx {
            c1 = dens(x1, y1, z1) - dens(x0, y1, z1)
            c2 = dens(x0, y1, z1) - dens(x0, y0, z1)
            c3 = dens(x0, y0, z1) - c0
        } else {
            c1 = 0; c2 = 0; c3 = 0
        }
        let rest = c1 &* rx &+ c2 &* ry &+ c3 &* rz &+ 0x8001
        Output[outChan] = cmsUInt16Number(truncatingIfNeeded: c0 &+ ((rest &+ (rest >> 16)) >> 16))
    }
}

/// A curve with wide flat stretches at either end cannot be inverted
/// usefully.
private func isDegenerated(_ g: UnsafeMutablePointer<cmsToneCurve>?) -> Bool {
    guard let g, let table = g.pointee.Table16 else { return false }
    let nEntries = Int(g.pointee.nEntries)
    var zeros = 0, poles = 0
    for i in 0..<nEntries {
        if table[i] == 0x0000 { zeros += 1 }
        if table[i] == 0xFFFF { poles += 1 }
    }
    if zeros == 1 && poles == 1 { return false }
    if zeros > nEntries / 20 { return true }
    if poles > nEntries / 20 { return true }
    return false
}

/// The prelinearisation scheme for RGB to RGB: measures the transform's
/// grey response, uses it as curves ahead of a CLUT resampled through
/// their inverse, and — at 8 bits — installs the tetrahedral evaluator
/// with its tables precomputed.
func optimizeByComputingLinearization(
    _ Lut: UnsafeMutablePointer<UnsafeMutablePointer<cmsPipeline>?>, _ Intent: cmsUInt32Number,
    _ InputFormat: UnsafeMutablePointer<cmsUInt32Number>, _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>,
    _ dwFlags: UnsafeMutablePointer<cmsUInt32Number>
) -> Bool {
    if isFloat(InputFormat.pointee) || isFloat(OutputFormat.pointee) { return false }
    let inFormat = PixelFormat(InputFormat.pointee), outFormat = PixelFormat(OutputFormat.pointee)
    if inFormat.colorSpace != Int(PT_RGB) || inFormat.planar { return false }
    if outFormat.colorSpace != Int(PT_RGB) || outFormat.planar { return false }
    // At 16 bits the caller has to ask.
    if !is8bit(InputFormat.pointee) && dwFlags.pointee & cmsUInt32Number(cmsFLAGS_CLUT_PRE_LINEARIZATION) == 0 {
        return false
    }

    guard let originalLut = Lut.pointee else { return false }
    let ContextID = cmsGetPipelineContextID(originalLut)
    let colorSpace = _cmsICCcolorSpace(cmsInt32Number(inFormat.colorSpace))
    let outputColorSpace = _cmsICCcolorSpace(cmsInt32Number(outFormat.colorSpace))
    if colorSpace == cmsColorSpaceSignature(0) || outputColorSpace == cmsColorSpaceSignature(0) { return false }
    let nGridPoints = _cmsReasonableGridpointsByColorspace(colorSpace, dwFlags.pointee)
    let inputs = Int(cmsPipelineInputChannels(originalLut))
    let outputs = cmsPipelineOutputChannels(originalLut)

    var trans = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: maximumChannels)
    var transReverse = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: maximumChannels)
    var lutPlusCurves: UnsafeMutablePointer<cmsPipeline>?
    var optimizedLUT: UnsafeMutablePointer<cmsPipeline>?
    func fail() -> Bool {
        for t in 0..<inputs {
            if let c = trans[t] { cmsFreeToneCurve(c) }
            if let c = transReverse[t] { cmsFreeToneCurve(c) }
        }
        if let l = lutPlusCurves { cmsPipelineFree(l) }
        if let l = optimizedLUT { cmsPipelineFree(l) }
        return false
    }

    // Degenerate curves at the end mean the transform squeezes and clips
    // the CLUT before it, which cannot be linearised.
    guard let last = cmsPipelineGetPtrToLastStage(originalLut) else { return fail() }
    if cmsStageType(last) == cmsSigCurveSetElemType,
       let data = cmsStageData(last)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self)
    {
        for i in 0..<Int(data.pointee.nCurves) where isDegenerated(data.pointee.TheCurves?[i]) {
            return fail()
        }
    }

    for t in 0..<inputs {
        trans[t] = cmsBuildTabulatedToneCurve16(ContextID, prelinearizationPoints, nil)
        if trans[t] == nil { return fail() }
    }

    // The grey response.
    var inValues = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    var outValues = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    for i in 0..<Int(prelinearizationPoints) {
        let v = cmsFloat32Number(Double(i) / Double(prelinearizationPoints - 1))
        for t in 0..<inputs { inValues[t] = v }
        cmsPipelineEvalFloat(&inValues, &outValues, originalLut)
        for t in 0..<inputs {
            trans[t]?.pointee.Table16?[i] = quickSaturateWord(Double(outValues[t]) * 65535.0)
        }
    }
    for t in 0..<inputs { slopeLimiting(trans[t]!) }

    var suitable = true
    for t in 0..<inputs where suitable {
        if cmsIsToneCurveMonotonic(trans[t]) == 0 { suitable = false }
        if isDegenerated(trans[t]) { suitable = false }
    }
    if !suitable { return fail() }

    for t in 0..<inputs {
        transReverse[t] = cmsReverseToneCurveEx(prelinearizationPoints, trans[t])
        if transReverse[t] == nil { return fail() }
    }

    lutPlusCurves = cmsPipelineDup(originalLut)
    guard let plus = lutPlusCurves else { return fail() }
    if cmsPipelineInsertStage(plus, cmsAT_BEGIN, cmsStageAllocToneCurves(ContextID, cmsUInt32Number(inputs), &transReverse)) == 0 {
        return fail()
    }

    optimizedLUT = cmsPipelineAlloc(ContextID, cmsUInt32Number(inputs), outputs)
    guard let optimized = optimizedLUT else { return fail() }
    let optimizedPrelinMpe = cmsStageAllocToneCurves(ContextID, cmsUInt32Number(inputs), &trans)
    if cmsPipelineInsertStage(optimized, cmsAT_BEGIN, optimizedPrelinMpe) == 0 { return fail() }
    let optimizedCLUTmpe = cmsStageAllocCLut16bit(ContextID, nGridPoints, cmsUInt32Number(inputs), outputs, nil)
    if cmsPipelineInsertStage(optimized, cmsAT_END, optimizedCLUTmpe) == 0 { return fail() }
    if cmsStageSampleCLut16bit(optimizedCLUTmpe, xformSampler16, UnsafeMutableRawPointer(plus), 0) == 0 { return fail() }

    for t in 0..<inputs {
        cmsFreeToneCurve(trans[t]); trans[t] = nil
        cmsFreeToneCurve(transReverse[t]); transReverse[t] = nil
    }
    cmsPipelineFree(plus)
    lutPlusCurves = nil

    guard let prelinCurves = curveSet(optimizedPrelinMpe),
          let clutData = cmsStageData(optimizedCLUTmpe)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let clutParams = clutData.pointee.Params
    else { return fail() }

    if is8bit(InputFormat.pointee) {
        guard let p8 = prelinOpt8alloc(ContextID, clutParams, prelinCurves) else { return fail() }
        _cmsPipelineSetOptimizationParameters(optimized, prelinEval8, p8, prelin8free, prelin8dup)
    } else {
        guard let p16 = prelinOpt16alloc(ContextID, clutParams, 3, prelinCurves, 3, nil) else { return fail() }
        _cmsPipelineSetOptimizationParameters(optimized, prelinEval16, p16, prelinOpt16free, prelin16dup)
    }

    if Intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP)
    }
    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP) == 0 {
        if !fixWhiteMisalignment(optimized, colorSpace, outputColorSpace) { return fail() }
    }

    cmsPipelineFree(originalLut)
    Lut.pointee = optimized
    return true
}

// -- curves alone ------------------------------------------------------------------------

/// One precomputed table per curve, at 256 or 65536 entries.
private struct Curves16Data {
    var nCurves: Int
    var nElements: Int
    var curves: UnsafeMutablePointer<UnsafeMutablePointer<cmsUInt16Number>?>
}

private func curvesFree(_ ContextID: cmsContext?, _ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }
    let data = ptr.assumingMemoryBound(to: Curves16Data.self).pointee
    for i in 0..<data.nCurves { _cmsFree(ContextID, UnsafeMutableRawPointer(data.curves[i])) }
    _cmsFree(ContextID, UnsafeMutableRawPointer(data.curves))
    _cmsFree(ContextID, ptr)
}

private func curvesDup(_ ContextID: cmsContext?, _ ptr: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr, let copy = _cmsDupMem(ContextID, ptr, cmsUInt32Number(MemoryLayout<Curves16Data>.size)) else { return nil }
    let data = copy.assumingMemoryBound(to: Curves16Data.self)
    let source = data.pointee
    let stride = cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsUInt16Number>?>.stride)
    guard let list = _cmsDupMem(ContextID, source.curves, cmsUInt32Number(source.nCurves) * stride) else {
        _cmsFree(ContextID, copy)
        return nil
    }
    data.pointee.curves = list.assumingMemoryBound(to: UnsafeMutablePointer<cmsUInt16Number>?.self)
    for i in 0..<source.nCurves {
        data.pointee.curves[i] = _cmsDupMem(
            ContextID, source.curves[i], cmsUInt32Number(source.nElements) * 2
        )?.assumingMemoryBound(to: cmsUInt16Number.self)
    }
    return copy
}

private func curvesAlloc(
    _ ContextID: cmsContext?, _ nCurves: Int, _ nElements: Int,
    _ g: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>
) -> UnsafeMutableRawPointer? {
    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<Curves16Data>.size)) else { return nil }
    let stride = cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsUInt16Number>?>.stride)
    guard let list = _cmsCalloc(ContextID, cmsUInt32Number(nCurves), stride) else {
        _cmsFree(ContextID, raw)
        return nil
    }
    let curves = list.assumingMemoryBound(to: UnsafeMutablePointer<cmsUInt16Number>?.self)
    for i in 0..<nCurves {
        guard let table = _cmsCalloc(ContextID, cmsUInt32Number(nElements), 2) else {
            for j in 0..<i { _cmsFree(ContextID, UnsafeMutableRawPointer(curves[j])) }
            _cmsFree(ContextID, list)
            _cmsFree(ContextID, raw)
            return nil
        }
        let t = table.assumingMemoryBound(to: cmsUInt16Number.self)
        curves[i] = t
        if nElements == 256 {
            for j in 0..<nElements { t[j] = cmsEvalToneCurve16(g[i], widen(UInt8(j))) }
        } else {
            for j in 0..<nElements { t[j] = cmsEvalToneCurve16(g[i], cmsUInt16Number(j)) }
        }
    }
    raw.assumingMemoryBound(to: Curves16Data.self).initialize(to: Curves16Data(nCurves: nCurves, nElements: nElements, curves: curves))
    return raw
}

private func fastEvaluateCurves8(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ D: UnsafeRawPointer?
) {
    guard let In, let Out, let D else { return }
    let data = D.assumingMemoryBound(to: Curves16Data.self).pointee
    for i in 0..<data.nCurves {
        Out[i] = data.curves[i]![Int(In[i] >> 8)]
    }
}

private func fastEvaluateCurves16(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ D: UnsafeRawPointer?
) {
    guard let In, let Out, let D else { return }
    let data = D.assumingMemoryBound(to: Curves16Data.self).pointee
    for i in 0..<data.nCurves {
        Out[i] = data.curves[i]![Int(In[i])]
    }
}

/// The evaluator for a pipeline that turned out to be an identity: the
/// input is the output.  Its data is the pipeline, for the channel count.
func fastIdentity16(
    _ In: UnsafePointer<cmsUInt16Number>?,
    _ Out: UnsafeMutablePointer<cmsUInt16Number>?,
    _ Data: UnsafeRawPointer?
) {
    guard let In, let Out, let Data else { return }
    let box = Unmanaged<PipelineBox>.fromOpaque(Data).takeUnretainedValue()
    for i in 0..<box.inputChannels { Out[i] = In[i] }
}

/// A pipeline of curves only becomes one sampled curve per channel, or
/// nothing at all when they come out linear.
func optimizeByJoiningCurves(
    _ Lut: UnsafeMutablePointer<UnsafeMutablePointer<cmsPipeline>?>, _ Intent: cmsUInt32Number,
    _ InputFormat: UnsafeMutablePointer<cmsUInt32Number>, _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>,
    _ dwFlags: UnsafeMutablePointer<cmsUInt32Number>
) -> Bool {
    if isFloat(InputFormat.pointee) || isFloat(OutputFormat.pointee) { return false }
    guard let src = Lut.pointee else { return false }

    var mpe = cmsPipelineGetPtrToFirstStage(src)
    while let s = mpe {
        if cmsStageType(s) != cmsSigCurveSetElemType { return false }
        mpe = cmsStageNext(s)
    }

    let ContextID = cmsGetPipelineContextID(src)
    let inputs = Int(cmsPipelineInputChannels(src))
    guard let dest = cmsPipelineAlloc(ContextID, cmsUInt32Number(inputs), cmsPipelineOutputChannels(src)) else { return false }

    var gammaTables = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: inputs)
    var obtainedCurves: UnsafeMutablePointer<cmsStage>?
    func fail() -> Bool {
        if let o = obtainedCurves { cmsStageFree(o) }
        for g in gammaTables { if let g { cmsFreeToneCurve(g) } }
        cmsPipelineFree(dest)
        return false
    }

    for i in 0..<inputs {
        gammaTables[i] = cmsBuildTabulatedToneCurve16(ContextID, prelinearizationPoints, nil)
        if gammaTables[i] == nil { return fail() }
    }
    var inFloat = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    var outFloat = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    for i in 0..<Int(prelinearizationPoints) {
        for j in 0..<inputs { inFloat[j] = cmsFloat32Number(Double(i) / Double(prelinearizationPoints - 1)) }
        cmsPipelineEvalFloat(&inFloat, &outFloat, src)
        for j in 0..<inputs { gammaTables[j]?.pointee.Table16?[i] = quickSaturateWord(Double(outFloat[j]) * 65535.0) }
    }

    obtainedCurves = cmsStageAllocToneCurves(ContextID, cmsUInt32Number(inputs), &gammaTables)
    guard let obtained = obtainedCurves else { return fail() }
    for i in 0..<inputs {
        cmsFreeToneCurve(gammaTables[i])
        gammaTables[i] = nil
    }

    if !allCurvesAreLinear(obtained) {
        if cmsPipelineInsertStage(dest, cmsAT_BEGIN, obtained) == 0 { return fail() }
        guard let data = cmsStageData(obtained)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self),
              let curves = data.pointee.TheCurves
        else { return fail() }
        obtainedCurves = nil
        let nCurves = Int(data.pointee.nCurves)
        if is8bit(InputFormat.pointee) {
            guard let c16 = curvesAlloc(ContextID, nCurves, 256, curves) else { return fail() }
            dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOCACHE)
            _cmsPipelineSetOptimizationParameters(dest, fastEvaluateCurves8, c16, curvesFree, curvesDup)
        } else {
            guard let c16 = curvesAlloc(ContextID, nCurves, 65536, curves) else { return fail() }
            dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOCACHE)
            _cmsPipelineSetOptimizationParameters(dest, fastEvaluateCurves16, c16, curvesFree, curvesDup)
        }
    } else {
        cmsStageFree(obtained)
        obtainedCurves = nil
        if cmsPipelineInsertStage(dest, cmsAT_BEGIN, cmsStageAllocIdentity(ContextID, cmsUInt32Number(inputs))) == 0 { return fail() }
        dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOCACHE)
        _cmsPipelineSetOptimizationParameters(dest, fastIdentity16, UnsafeMutableRawPointer(dest), nil, nil)
    }

    cmsPipelineFree(src)
    Lut.pointee = dest
    return true
}

// -- matrix-shaper at 8 bits ----------------------------------------------------------

/// The 8-bit matrix-shaper's tables, in 1.14 fixed point: a first shaper
/// from 256 input values, the matrix and offset, and a second shaper
/// over the 16385 values 1.14 can take.
private struct MatShaper8Data {
    var shaper1R: [Int32], shaper1G: [Int32], shaper1B: [Int32]
    var mat: [[Int32]]
    var off: [Int32]
    var shaper2R: [UInt16], shaper2G: [UInt16], shaper2B: [UInt16]
}

@inline(__always) private func doubleTo1Fixed14(_ x: Double) -> Int32 {
    Int32(truncatingIfNeeded: Int64((x * 16384.0 + 0.5).rounded(.down)))
}

private func freeMatShaper(_ ContextID: cmsContext?, _ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }
    ptr.assumingMemoryBound(to: MatShaper8Data.self).deinitialize(count: 1)
    _cmsFree(ContextID, ptr)
}

private func dupMatShaper(_ ContextID: cmsContext?, _ ptr: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr, let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<MatShaper8Data>.size)) else { return nil }
    raw.assumingMemoryBound(to: MatShaper8Data.self).initialize(to: ptr.assumingMemoryBound(to: MatShaper8Data.self).pointee)
    return raw
}

/// The 8-bit matrix-shaper evaluator: first shaper, matrix in 1.14,
/// clip, second shaper.  The input words are known to be a byte
/// doubled, so the low byte is the byte.
private func matShaperEval16(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ D: UnsafeRawPointer?
) {
    guard let In, let Out, let D else { return }
    let p = D.assumingMemoryBound(to: MatShaper8Data.self)
    let ri = Int(In[0] & 0xFF), gi = Int(In[1] & 0xFF), bi = Int(In[2] & 0xFF)
    let r = p.pointee.shaper1R[ri], g = p.pointee.shaper1G[gi], b = p.pointee.shaper1B[bi]

    let m = p.pointee.mat, off = p.pointee.off
    let l1 = (m[0][0] &* r &+ m[0][1] &* g &+ m[0][2] &* b &+ off[0] &+ 0x2000) >> 14
    let l2 = (m[1][0] &* r &+ m[1][1] &* g &+ m[1][2] &* b &+ off[1] &+ 0x2000) >> 14
    let l3 = (m[2][0] &* r &+ m[2][1] &* g &+ m[2][2] &* b &+ off[2] &+ 0x2000) >> 14

    let ci = l1 < 0 ? 0 : (l1 > 16384 ? 16384 : Int(l1))
    let cg = l2 < 0 ? 0 : (l2 > 16384 ? 16384 : Int(l2))
    let cb = l3 < 0 ? 0 : (l3 > 16384 ? 16384 : Int(l3))
    Out[0] = p.pointee.shaper2R[ci]
    Out[1] = p.pointee.shaper2G[cg]
    Out[2] = p.pointee.shaper2B[cb]
}

private func fillFirstShaper(_ curve: UnsafeMutablePointer<cmsToneCurve>?) -> [Int32] {
    var table = [Int32](repeating: 0, count: 256)
    for i in 0..<256 {
        let r = cmsFloat32Number(Double(i) / 255.0)
        let y = cmsEvalToneCurveFloat(curve, r)
        table[i] = y < 131072.0 ? doubleTo1Fixed14(Double(y)) : 0x7FFF_FFFF
    }
    return table
}

private func fillSecondShaper(_ curve: UnsafeMutablePointer<cmsToneCurve>?, is8BitsOutput: Bool) -> [UInt16] {
    var table = [UInt16](repeating: 0, count: 16385)
    for i in 0..<16385 {
        let r = cmsFloat32Number(Double(i) / 16384.0)
        var val = cmsEvalToneCurveFloat(curve, r)
        if val < 0 { val = 0 }
        if val > 1.0 { val = 1.0 }
        if is8BitsOutput {
            // The byte the output will be, stored doubled so that the
            // formatter's `& 0xFF` is the whole rounding.
            let w = quickSaturateWord(Double(val) * 65535.0)
            table[i] = widen(narrow(w))
        } else {
            table[i] = quickSaturateWord(Double(val) * 65535.0)
        }
    }
    return table
}

private func setMatShaper(
    _ dest: UnsafeMutablePointer<cmsPipeline>,
    _ curve1: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>, _ mat: cmsMAT3, _ off: UnsafePointer<cmsFloat64Number>?,
    _ curve2: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>, _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>
) -> Bool {
    let ContextID = cmsGetPipelineContextID(dest)
    let is8Bits = is8bit(OutputFormat.pointee)
    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<MatShaper8Data>.size)) else { return false }

    var m = mat
    let matrix: [[Int32]] = withUnsafePointer(to: &m) { mp in
        mp.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { d in
            (0..<3).map { i in (0..<3).map { j in doubleTo1Fixed14(d[i * 3 + j]) } }
        }
    }
    let offset: [Int32] = (0..<3).map { i in off.map { doubleTo1Fixed14($0[i]) } ?? 0 }

    raw.assumingMemoryBound(to: MatShaper8Data.self).initialize(to: MatShaper8Data(
        shaper1R: fillFirstShaper(curve1[0]), shaper1G: fillFirstShaper(curve1[1]), shaper1B: fillFirstShaper(curve1[2]),
        mat: matrix, off: offset,
        shaper2R: fillSecondShaper(curve2[0], is8BitsOutput: is8Bits),
        shaper2G: fillSecondShaper(curve2[1], is8BitsOutput: is8Bits),
        shaper2B: fillSecondShaper(curve2[2], is8BitsOutput: is8Bits)
    ))

    if is8Bits { OutputFormat.pointee |= optimizedSH(1) }
    _cmsPipelineSetOptimizationParameters(dest, matShaperEval16, raw, freeMatShaper, dupMatShaper)
    return true
}

/// Curves, matrix (or two), curves at 8 bits in: the two matrices
/// multiplied, and the whole thing evaluated in fixed point.  An
/// identity matrix means only curves are left, which the curve joiner
/// takes.
func optimizeMatrixShaper(
    _ Lut: UnsafeMutablePointer<UnsafeMutablePointer<cmsPipeline>?>, _ Intent: cmsUInt32Number,
    _ InputFormat: UnsafeMutablePointer<cmsUInt32Number>, _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>,
    _ dwFlags: UnsafeMutablePointer<cmsUInt32Number>
) -> Bool {
    if PixelFormat(InputFormat.pointee).channels != 3 || PixelFormat(OutputFormat.pointee).channels != 3 { return false }
    if !is8bit(InputFormat.pointee) { return false }
    guard let src = Lut.pointee else { return false }
    let ContextID = cmsGetPipelineContextID(src)

    let curves = cmsSigCurveSetElemType, matrix = cmsSigMatrixElemType
    var res = cmsMAT3()
    var offset: UnsafeMutablePointer<cmsFloat64Number>?
    var identityMat = false
    let curve1: UnsafeMutablePointer<cmsStage>, curve2: UnsafeMutablePointer<cmsStage>

    if let s = stages(src, [curves, matrix, matrix, curves]) {
        curve1 = s[0]; curve2 = s[3]
        guard let data1 = cmsStageData(s[1])?.assumingMemoryBound(to: _cmsStageMatrixData.self),
              let data2 = cmsStageData(s[2])?.assumingMemoryBound(to: _cmsStageMatrixData.self)
        else { return false }
        if cmsStageInputChannels(s[1]) != 3 || cmsStageOutputChannels(s[1]) != 3
            || cmsStageInputChannels(s[2]) != 3 || cmsStageOutputChannels(s[2]) != 3
        {
            return false
        }
        if data1.pointee.Offset != nil { return false }
        data2.pointee.Double.withMemoryRebound(to: cmsMAT3.self, capacity: 1) { a in
            data1.pointee.Double.withMemoryRebound(to: cmsMAT3.self, capacity: 1) { b in
                _cmsMAT3per(&res, a, b)
            }
        }
        offset = data2.pointee.Offset
        if _cmsMAT3isIdentity(&res) != 0 && offset == nil { identityMat = true }
    } else if let s = stages(src, [curves, matrix, curves]) {
        curve1 = s[0]; curve2 = s[2]
        guard let data = cmsStageData(s[1])?.assumingMemoryBound(to: _cmsStageMatrixData.self) else { return false }
        if cmsStageInputChannels(s[1]) != 3 || cmsStageOutputChannels(s[1]) != 3 { return false }
        data.pointee.Double.withMemoryRebound(to: cmsMAT3.self, capacity: 1) { res = $0.pointee }
        offset = data.pointee.Offset
        if _cmsMAT3isIdentity(&res) != 0 && offset == nil { identityMat = true }
    } else {
        return false
    }

    guard let dest = cmsPipelineAlloc(ContextID, cmsPipelineInputChannels(src), cmsPipelineOutputChannels(src)) else { return false }
    func fail() -> Bool {
        cmsPipelineFree(dest)
        return false
    }
    if cmsPipelineInsertStage(dest, cmsAT_BEGIN, cmsStageDup(curve1)) == 0 { return fail() }
    if !identityMat {
        let m = withUnsafePointer(to: &res) {
            $0.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { cmsStageAllocMatrix(ContextID, 3, 3, $0, offset) }
        }
        if cmsPipelineInsertStage(dest, cmsAT_END, m) == 0 { return fail() }
    }
    if cmsPipelineInsertStage(dest, cmsAT_END, cmsStageDup(curve2)) == 0 { return fail() }

    if identityMat {
        var d: UnsafeMutablePointer<cmsPipeline>? = dest
        _ = optimizeByJoiningCurves(&d, Intent, InputFormat, OutputFormat, dwFlags)
        cmsPipelineFree(src)
        Lut.pointee = d
        return true
    }

    guard let c1 = curveSet(curve1), let c2 = curveSet(curve2) else { return fail() }
    // The cache costs more than it saves here.
    dwFlags.pointee |= cmsUInt32Number(cmsFLAGS_NOCACHE)
    _ = setMatShaper(dest, c1, res, offset, c2, OutputFormat)
    cmsPipelineFree(src)
    Lut.pointee = dest
    return true
}
