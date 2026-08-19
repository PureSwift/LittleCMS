import CLCMS2
import LittleCMS

// Linking a chain of profiles into one pipeline.
//
// Each profile contributes its own pipeline, read in whichever direction
// the chain needs it; between two of them, where the PCS is crossed, a
// correction may go — the white point scaling of absolute colorimetric,
// or black point compensation — and a conversion between XYZ and Lab
// when one profile's PCS is not the other's.  The first intent in the
// chain chooses the handler for the whole chain, which is how a plugin
// takes over the linking.

/// One row of the intent table: what it is called, and how it links.
struct IntentEntry: Sendable {
    let intent: cmsUInt32Number
    let description: StaticString
    let link: @Sendable (
        cmsContext?, [cmsUInt32Number], [cmsHPROFILE?], [Bool], [cmsFloat64Number], cmsUInt32Number
    ) -> UnsafeMutablePointer<cmsPipeline>?
}

/// The built-in intents, in the order cmsGetSupportedIntents lists them.
let defaultIntents: [IntentEntry] = [
    IntentEntry(intent: cmsUInt32Number(INTENT_PERCEPTUAL), description: "Perceptual", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), description: "Relative colorimetric", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_SATURATION), description: "Saturation", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC), description: "Absolute colorimetric", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_PERCEPTUAL), description: "Perceptual preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_RELATIVE_COLORIMETRIC), description: "Relative colorimetric preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_SATURATION), description: "Saturation preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_PERCEPTUAL), description: "Perceptual preserving black plane", link: blackPreservingKPlaneIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_RELATIVE_COLORIMETRIC), description: "Relative colorimetric preserving black plane", link: blackPreservingKPlaneIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_SATURATION), description: "Saturation preserving black plane", link: blackPreservingKPlaneIntents),
]

// -- the correction between two profiles ---------------------------------------

/// The XYZ layer between profile `i - 1` and profile `i`: the absolute
/// intent's white scaling, or black point compensation when asked and
/// the two blacks differ, or nothing.  The offset is divided into the
/// XYZ encoding, since the stage sees encoded values.
private func computeConversion(
    _ i: Int, _ hProfiles: [cmsHPROFILE?], _ intent: cmsUInt32Number,
    _ bpc: Bool, _ adaptationState: cmsFloat64Number
) -> XYZLayer? {
    var layer = XYZLayer.identity

    if intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        let whiteIn = _cmsReadMediaWhitePoint(hProfiles[i - 1])
        guard let chadIn = _cmsReadCHAD(hProfiles[i - 1]) else { return nil }
        let whiteOut = _cmsReadMediaWhitePoint(hProfiles[i])
        guard let chadOut = _cmsReadCHAD(hProfiles[i]) else { return nil }

        guard let m = IntentArithmetic.absoluteIntent(
            adaptationState: adaptationState,
            whiteIn: engine(whiteIn), adaptationIn: matrix(chadIn),
            whiteOut: engine(whiteOut), adaptationOut: matrix(chadOut)
        ) else { return nil }
        layer.matrix = m
    } else if bpc {
        // The detectors leave their answer untouched on failure, and the
        // reference does not check: a failure is a black of zero.
        var blackIn = cmsCIEXYZ(X: 0, Y: 0, Z: 0)
        var blackOut = cmsCIEXYZ(X: 0, Y: 0, Z: 0)
        _ = cmsDetectBlackPoint(&blackIn, hProfiles[i - 1], intent, 0)
        _ = cmsDetectDestinationBlackPoint(&blackOut, hProfiles[i], intent, 0)

        if blackIn.X != blackOut.X || blackIn.Y != blackOut.Y || blackIn.Z != blackOut.Z {
            layer = IntentArithmetic.blackPointCompensation(from: engine(blackIn), to: engine(blackOut))
        }
    }

    layer.offset = Vector3(
        layer.offset.x / maximumEncodeableXYZ,
        layer.offset.y / maximumEncodeableXYZ,
        layer.offset.z / maximumEncodeableXYZ
    )
    return layer
}

@inline(__always)
private func matrix(_ m: cmsMAT3) -> Matrix3 {
    var m = m
    return withUnsafePointer(to: &m) { $0.matrix }
}

private func layerStage(_ ContextID: cmsContext?, _ layer: XYZLayer) -> UnsafeMutablePointer<cmsStage>? {
    var m = cmsMAT3()
    var off = cmsVEC3()
    withUnsafeMutablePointer(to: &m) { $0.matrix = layer.matrix }
    withUnsafeMutablePointer(to: &off) { $0.vector = layer.offset }
    return withUnsafePointer(to: &m) { mp in
        withUnsafePointer(to: &off) { op in
            mp.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { md in
                op.withMemoryRebound(to: cmsFloat64Number.self, capacity: 3) { od in
                    cmsStageAllocMatrix(ContextID, 3, 3, md, od)
                }
            }
        }
    }
}

/// Appends to `result` whatever takes `inPCS` to `outPCS` with the layer
/// applied in XYZ along the way; false on a mismatch that cannot be
/// bridged.
private func addConversion(
    _ result: UnsafeMutablePointer<cmsPipeline>,
    _ inPCS: cmsColorSpaceSignature, _ outPCS: cmsColorSpaceSignature,
    _ layer: XYZLayer
) -> Bool {
    let ContextID = cmsGetPipelineContextID(result)
    @inline(__always) func put(_ s: UnsafeMutablePointer<cmsStage>?) -> Bool {
        cmsPipelineInsertStage(result, cmsAT_END, s) != 0
    }

    switch inPCS {
    case cmsSigXYZData:
        switch outPCS {
        case cmsSigXYZData:
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
        case cmsSigLabData:
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
            if !put(_cmsStageAllocXYZ2Lab(ContextID)) { return false }
        default:
            return false
        }
    case cmsSigLabData:
        switch outPCS {
        case cmsSigXYZData:
            if !put(_cmsStageAllocLab2XYZ(ContextID)) { return false }
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
        case cmsSigLabData:
            if !layer.isEmpty {
                if !put(_cmsStageAllocLab2XYZ(ContextID))
                    || !put(layerStage(ContextID, layer))
                    || !put(_cmsStageAllocXYZ2Lab(ContextID))
                {
                    return false
                }
            }
        default:
            return false
        }
    default:
        // Anything else has to match exactly.
        if inPCS != outPCS { return false }
    }
    return true
}

/// The same space, or CMYK against 4-colour, or XYZ against Lab — the
/// last two because either can be computed from the other.
private func colorSpaceIsCompatible(_ a: cmsColorSpaceSignature, _ b: cmsColorSpaceSignature) -> Bool {
    if a == b { return true }
    if a == cmsSig4colorData && b == cmsSigCmykData { return true }
    if a == cmsSigCmykData && b == cmsSig4colorData { return true }
    if a == cmsSigXYZData && b == cmsSigLabData { return true }
    if a == cmsSigLabData && b == cmsSigXYZData { return true }
    return false
}

// -- the ICC intents -----------------------------------------------------------

/// The four ICC intents.  Walks the chain keeping the current colour
/// space: the first profile is read in the input direction unless it is
/// a devicelink; any later profile is read as input while the current
/// space is a device space and as output once it is a PCS.
@Sendable func defaultICCIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles == 0 { return nil }

    guard let result = cmsPipelineAlloc(ContextID, 0, 0) else { return nil }
    var currentColorSpace = cmsGetColorSpace(hProfiles[0])
    var colorSpaceOut = cmsSigLabData

    func fail(_ lut: UnsafeMutablePointer<cmsPipeline>? = nil) -> UnsafeMutablePointer<cmsPipeline>? {
        if let lut { cmsPipelineFree(lut) }
        cmsPipelineFree(result)
        return nil
    }

    for i in 0..<nProfiles {
        let hProfile = hProfiles[i]
        let classSig = cmsGetDeviceClass(hProfile)
        let isDeviceLink = classSig == cmsSigLinkClass || classSig == cmsSigAbstractClass

        let isInput: Bool
        if i == 0 && !isDeviceLink {
            isInput = true
        } else {
            isInput = currentColorSpace != cmsSigXYZData && currentColorSpace != cmsSigLabData
        }

        let intent = intents[i]
        let colorSpaceIn: cmsColorSpaceSignature
        if isInput || isDeviceLink {
            colorSpaceIn = cmsGetColorSpace(hProfile)
            colorSpaceOut = cmsGetPCS(hProfile)
        } else {
            colorSpaceIn = cmsGetPCS(hProfile)
            colorSpaceOut = cmsGetColorSpace(hProfile)
        }

        if !colorSpaceIsCompatible(colorSpaceIn, currentColorSpace) {
            report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "ColorSpace mismatch", to: ContextID)
            return fail()
        }

        let lut: UnsafeMutablePointer<cmsPipeline>?
        if isDeviceLink || (classSig == cmsSigNamedColorClass && nProfiles == 1) {
            // A devicelink takes no intent and no correction — except an
            // abstract profile after the first, which sits in the PCS
            // and may need one.
            guard let read = _cmsReadDevicelinkLUT(hProfile, intent) else { return fail() }
            lut = read

            var layer = XYZLayer.identity
            if classSig == cmsSigAbstractClass && i > 0 {
                guard let computed = computeConversion(i, hProfiles, intent, bpc[i], adaptationStates[i])
                else { return fail(lut) }
                layer = computed
            }
            if !addConversion(result, currentColorSpace, colorSpaceIn, layer) { return fail(lut) }
        } else if isInput {
            guard let read = _cmsReadInputLUT(hProfile, intent) else { return fail() }
            lut = read
        } else {
            guard let read = _cmsReadOutputLUT(hProfile, intent) else { return fail() }
            lut = read
            guard let layer = computeConversion(i, hProfiles, intent, bpc[i], adaptationStates[i])
            else { return fail(lut) }
            if !addConversion(result, currentColorSpace, colorSpaceIn, layer) { return fail(lut) }
        }

        if cmsPipelineCat(result, lut) == 0 { return fail(lut) }
        cmsPipelineFree(lut)

        currentColorSpace = colorSpaceOut
    }

    // Clip negatives at the end when asked and the exit is a device space.
    if dwFlags & cmsUInt32Number(cmsFLAGS_NONEGATIVES) != 0 {
        if colorSpaceOut == cmsSigGrayData || colorSpaceOut == cmsSigRgbData || colorSpaceOut == cmsSigCmykData {
            guard let clip = _cmsStageClipNegatives(ContextID, cmsUInt32Number(cmsChannelsOfColorSpace(colorSpaceOut)))
            else { return fail() }
            if cmsPipelineInsertStage(result, cmsAT_END, clip) == 0 { return fail() }
        }
    }

    return result
}

@c @implementation
public func _cmsDefaultICCintents(
    _ ContextID: cmsContext?,
    _ nProfiles: cmsUInt32Number,
    _ TheIntents: UnsafeMutablePointer<cmsUInt32Number>?,
    _ hProfiles: UnsafeMutablePointer<cmsHPROFILE?>?,
    _ BPC: UnsafeMutablePointer<cmsBool>?,
    _ AdaptationStates: UnsafeMutablePointer<cmsFloat64Number>?,
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    guard let TheIntents, let hProfiles, let BPC, let AdaptationStates else { return nil }
    let n = Int(nProfiles)
    return defaultICCIntents(
        ContextID,
        Array(UnsafeBufferPointer(start: TheIntents, count: n)),
        Array(UnsafeBufferPointer(start: hProfiles, count: n)),
        UnsafeBufferPointer(start: BPC, count: n).map { $0 != 0 },
        Array(UnsafeBufferPointer(start: AdaptationStates, count: n)),
        dwFlags
    )
}

// -- the black-preserving intents ---------------------------------------------

/// The ICC intent a black-preserving one stands on.
private func translateNonICCIntent(_ intent: cmsUInt32Number) -> cmsUInt32Number {
    switch Int32(intent) {
    case INTENT_PRESERVE_K_ONLY_PERCEPTUAL, INTENT_PRESERVE_K_PLANE_PERCEPTUAL:
        return cmsUInt32Number(INTENT_PERCEPTUAL)
    case INTENT_PRESERVE_K_ONLY_RELATIVE_COLORIMETRIC, INTENT_PRESERVE_K_PLANE_RELATIVE_COLORIMETRIC:
        return cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)
    case INTENT_PRESERVE_K_ONLY_SATURATION, INTENT_PRESERVE_K_PLANE_SATURATION:
        return cmsUInt32Number(INTENT_SATURATION)
    default:
        return intent
    }
}

private func isCMYKDevicelink(_ hProfile: cmsHPROFILE?) -> Bool {
    cmsGetDeviceClass(hProfile) == cmsSigLinkClass && cmsGetColorSpace(hProfile) == cmsSigCmykData
}

/// The part of both black-preserving handlers that decides whether
/// there is any black to preserve: the chain must go CMYK to CMYK, with
/// trailing CMYK devicelinks set aside.  When it does not, the chain is
/// linked with the plain ICC intents; when it does, the answer is the
/// index of the last profile in the preserved part.
private func blackPreservingSetup(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> (iccIntents: [cmsUInt32Number], lastProfile: Int?, fallback: UnsafeMutablePointer<cmsPipeline>?) {
    let nProfiles = hProfiles.count
    let iccIntents = intents.map(translateNonICCIntent)

    var lastProfilePos = nProfiles - 1
    var hLastProfile = hProfiles[lastProfilePos]
    while isCMYKDevicelink(hLastProfile) {
        if lastProfilePos < 2 { break }
        lastProfilePos -= 1
        hLastProfile = hProfiles[lastProfilePos]
    }

    if cmsGetColorSpace(hProfiles[0]) != cmsSigCmykData
        || !(cmsGetColorSpace(hLastProfile) == cmsSigCmykData || cmsGetDeviceClass(hLastProfile) == cmsSigOutputClass)
    {
        return (iccIntents, nil, defaultICCIntents(ContextID, iccIntents, hProfiles, bpc, adaptationStates, dwFlags))
    }
    return (iccIntents, lastProfilePos, nil)
}

/// The K-only sampler's cargo: the plain transform and the K curve.
private struct GrayOnlyParams {
    var cmyk2cmyk: UnsafeMutablePointer<cmsPipeline>?
    var kTone: UnsafeMutablePointer<cmsToneCurve>?
}

/// Pure black stays pure black, through the K curve; anything else goes
/// through the plain transform.
private func blackPreservingGrayOnlySampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let bp = Cargo.assumingMemoryBound(to: GrayOnlyParams.self).pointee
    if In[0] == 0 && In[1] == 0 && In[2] == 0 {
        Out[0] = 0; Out[1] = 0; Out[2] = 0
        Out[3] = cmsEvalToneCurve16(bp.kTone, In[3])
        return 1
    }
    cmsPipelineEval16(In, Out, bp.cmyk2cmyk)
    return 1
}

/// Black ink only: a CMYK to CMYK CLUT that maps pure K through a K to
/// K curve and everything else through the plain transform, with any
/// trailing CMYK devicelinks appended after.
@Sendable func blackPreservingKOnlyIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles < 1 || nProfiles > 255 { return nil }
    let (iccIntents, lastProfile, fallback) = blackPreservingSetup(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
    guard let lastProfilePos = lastProfile else { return fallback }
    let preserved = lastProfilePos + 1

    guard let result = cmsPipelineAlloc(ContextID, 4, 4) else { return nil }
    var bp = GrayOnlyParams(cmyk2cmyk: nil, kTone: nil)
    defer {
        if let l = bp.cmyk2cmyk { cmsPipelineFree(l) }
        if let k = bp.kTone { cmsFreeToneCurve(k) }
    }
    func fail() -> UnsafeMutablePointer<cmsPipeline>? {
        cmsPipelineFree(result)
        return nil
    }

    bp.cmyk2cmyk = defaultICCIntents(
        ContextID, Array(iccIntents[0..<preserved]), Array(hProfiles[0..<preserved]),
        Array(bpc[0..<preserved]), Array(adaptationStates[0..<preserved]), dwFlags
    )
    if bp.cmyk2cmyk == nil { return fail() }

    bp.kTone = _cmsBuildKToneCurve(
        ContextID, 4096, Array(iccIntents[0..<preserved]), Array(hProfiles[0..<preserved]),
        Array(bpc[0..<preserved]), Array(adaptationStates[0..<preserved]), dwFlags
    )
    if bp.kTone == nil { return fail() }

    let nGridPoints = _cmsReasonableGridpointsByColorspace(cmsSigCmykData, dwFlags)
    guard let clut = cmsStageAllocCLut16bit(ContextID, nGridPoints, 4, 4, nil) else { return fail() }
    if cmsPipelineInsertStage(result, cmsAT_BEGIN, clut) == 0 { return fail() }
    // No pre or post linearisation this time.
    if cmsStageSampleCLut16bit(clut, blackPreservingGrayOnlySampler, &bp, 0) == 0 { return fail() }

    for i in (lastProfilePos + 1)..<nProfiles {
        guard let devlink = _cmsReadDevicelinkLUT(hProfiles[i], iccIntents[i]) else { return fail() }
        defer { cmsPipelineFree(devlink) }
        if cmsPipelineCat(result, devlink) == 0 { return fail() }
    }
    return result
}

/// The K-plane sampler's cargo.
private struct PreserveKPlaneParams {
    var cmyk2cmyk: UnsafeMutablePointer<cmsPipeline>?
    var hProofOutput: cmsHTRANSFORM?
    var cmyk2Lab: cmsHTRANSFORM?
    var kTone: UnsafeMutablePointer<cmsToneCurve>?
    var labK2cmyk: UnsafeMutablePointer<cmsPipeline>?
    var maxError: Double
    var hRoundTrip: cmsHTRANSFORM?
    var maxTAC: Double
}

/// Keeps the K plane: the plain transform's K is replaced by the K
/// curve's, CMY re-solved by reverse interpolation against that K, and
/// the total ink held under the output profile's limit.  The CLUT is
/// 16-bit but the arithmetic is float, as the reference's is.
private func blackPreservingSampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let bp = Cargo.assumingMemoryBound(to: PreserveKPlaneParams.self)

    var inf = [cmsFloat32Number](repeating: 0, count: 4)
    var outf = [cmsFloat32Number](repeating: 0, count: 4)
    var labK = [cmsFloat32Number](repeating: 0, count: 4)
    for i in 0..<4 { inf[i] = cmsFloat32Number(Double(In[i]) / 65535.0) }

    labK[3] = cmsEvalToneCurveFloat(bp.pointee.kTone, inf[3])

    if In[0] == 0 && In[1] == 0 && In[2] == 0 {
        Out[0] = 0; Out[1] = 0; Out[2] = 0
        Out[3] = quickSaturateWord(Double(labK[3]) * 65535.0)
        return 1
    }

    cmsPipelineEvalFloat(&inf, &outf, bp.pointee.cmyk2cmyk)
    for i in 0..<4 { Out[i] = quickSaturateWord(Double(outf[i]) * 65535.0) }

    // K may already be right, mostly at K = 0.
    if (outf[3] - labK[3]).magnitude < Float(3.0 / 65535.0) { return 1 }

    // Measure the plain answer in Lab, and get the Lab of the output CMYK.
    var colorimetricLab = cmsCIELab()
    cmsDoTransform(bp.pointee.hProofOutput, Out, &colorimetricLab, 1)
    cmsDoTransform(bp.pointee.cmyk2Lab, &outf, &labK, 1)

    // CMY for that Lab at the fixed K, by reverse interpolation — or the
    // plain answer when none can be found.
    // The reference passes the same buffer as target and hint; the
    // hint is copied out first, so a copy here is the same thing.
    var hint = outf
    let found = cmsPipelineEvalReverseFloat(&labK, &outf, &hint, bp.pointee.labK2cmyk)
    if found == 0 { return 1 }
    outf[3] = labK[3]

    let sumCMY = Double(outf[0]) + Double(outf[1]) + Double(outf[2])
    let sumCMYK = sumCMY + Double(outf[3])
    var ratio: Double
    if sumCMYK > bp.pointee.maxTAC {
        ratio = 1 - ((sumCMYK - bp.pointee.maxTAC) / sumCMY)
        if ratio < 0 { ratio = 0 }
    } else {
        ratio = 1.0
    }

    Out[0] = quickSaturateWord(Double(outf[0]) * ratio * 65535.0)
    Out[1] = quickSaturateWord(Double(outf[1]) * ratio * 65535.0)
    Out[2] = quickSaturateWord(Double(outf[2]) * ratio * 65535.0)
    Out[3] = quickSaturateWord(Double(outf[3]) * 65535.0)

    var blackPreservingLab = cmsCIELab()
    cmsDoTransform(bp.pointee.hProofOutput, Out, &blackPreservingLab, 1)
    let error = cmsDeltaE(&colorimetricLab, &blackPreservingLab)
    if error > bp.pointee.maxError { bp.pointee.maxError = error }
    return 1
}

/// Black plane preserved.
@Sendable func blackPreservingKPlaneIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles < 1 || nProfiles > 255 { return nil }
    let (iccIntents, lastProfile, fallback) = blackPreservingSetup(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
    guard let lastProfilePos = lastProfile else { return fallback }
    let preserved = lastProfilePos + 1
    let hLastProfile = hProfiles[lastProfilePos]

    guard let result = cmsPipelineAlloc(ContextID, 4, 4) else { return nil }
    var bp = PreserveKPlaneParams(maxError: 0, maxTAC: 0)
    defer {
        if let l = bp.cmyk2cmyk { cmsPipelineFree(l) }
        if let x = bp.cmyk2Lab { cmsDeleteTransform(x) }
        if let x = bp.hProofOutput { cmsDeleteTransform(x) }
        if let k = bp.kTone { cmsFreeToneCurve(k) }
        if let l = bp.labK2cmyk { cmsPipelineFree(l) }
    }
    // The reference returns whatever it has on failure — the result
    // pipeline as it stands, not NULL — after cleaning up.  Kept.

    bp.labK2cmyk = _cmsReadInputLUT(hLastProfile, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC))
    if bp.labK2cmyk == nil { return result }

    bp.maxTAC = cmsDetectTAC(hLastProfile) / 100.0
    if bp.maxTAC <= 0 { return result }

    bp.cmyk2cmyk = defaultICCIntents(
        ContextID, Array(iccIntents[0..<preserved]), Array(hProfiles[0..<preserved]),
        Array(bpc[0..<preserved]), Array(adaptationStates[0..<preserved]), dwFlags
    )
    if bp.cmyk2cmyk == nil { return result }

    bp.kTone = _cmsBuildKToneCurve(
        ContextID, 4096, Array(iccIntents[0..<preserved]), Array(hProfiles[0..<preserved]),
        Array(bpc[0..<preserved]), Array(adaptationStates[0..<preserved]), dwFlags
    )
    if bp.kTone == nil { return result }

    let hLab = cmsCreateLab4ProfileTHR(ContextID, nil)
    bp.hProofOutput = cmsCreateTransformTHR(
        ContextID, hLastProfile, channelsSH(4) | bytesSH(2), hLab, SLCMS_TYPE_Lab_DBL,
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(cmsFLAGS_NOCACHE | cmsFLAGS_NOOPTIMIZE)
    )
    if bp.hProofOutput == nil {
        cmsCloseProfile(hLab)
        return result
    }
    bp.cmyk2Lab = cmsCreateTransformTHR(
        ContextID, hLastProfile, floatSH(1) | channelsSH(4) | bytesSH(4), hLab,
        floatSH(1) | channelsSH(3) | bytesSH(4),
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(cmsFLAGS_NOCACHE | cmsFLAGS_NOOPTIMIZE)
    )
    cmsCloseProfile(hLab)
    if bp.cmyk2Lab == nil { return result }

    bp.maxError = 0
    let nGridPoints = _cmsReasonableGridpointsByColorspace(cmsSigCmykData, dwFlags)
    guard let clut = cmsStageAllocCLut16bit(ContextID, nGridPoints, 4, 4, nil) else { return result }
    if cmsPipelineInsertStage(result, cmsAT_BEGIN, clut) == 0 { return result }
    _ = cmsStageSampleCLut16bit(clut, blackPreservingSampler, &bp, 0)

    for i in (lastProfilePos + 1)..<nProfiles {
        guard let devlink = _cmsReadDevicelinkLUT(hProfiles[i], iccIntents[i]) else { return result }
        defer { cmsPipelineFree(devlink) }
        if cmsPipelineCat(result, devlink) == 0 { return result }
    }
    return result
}

// -- linking -------------------------------------------------------------------

/// `_cmsLinkProfiles`: settles BPC per profile — never for absolute
/// colorimetric, always for a V4 profile in perceptual or saturation —
/// then hands the chain to the handler of its first intent.
func linkProfiles(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: inout [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles <= 0 || nProfiles > 255 {
        report(cmsUInt32Number(cmsERROR_RANGE), "Couldn't link '\(nProfiles)' profiles", to: ContextID)
        return nil
    }

    for i in 0..<nProfiles {
        if intents[i] == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
            bpc[i] = false
        }
        if intents[i] == cmsUInt32Number(INTENT_PERCEPTUAL) || intents[i] == cmsUInt32Number(INTENT_SATURATION) {
            if cmsGetEncodedICCversion(hProfiles[i]) >= 0x4000000 {
                bpc[i] = true
            }
        }
    }

    // A plugin's intents would be searched first; there are none.
    guard let entry = defaultIntents.first(where: { $0.intent == intents[0] }) else {
        report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unsupported intent '\(intents[0])'", to: ContextID)
        return nil
    }
    return entry.link(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
}

// -- what intents there are ----------------------------------------------------

/// The description strings, as C strings that live as long as the
/// library: a caller keeps the pointers it is given.  Written once, at
/// first use, and only ever read after.
private nonisolated(unsafe) let intentDescriptions: [UnsafeMutablePointer<CChar>] = defaultIntents.map { entry in
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
    p.initialize(repeating: 0, count: 256)
    entry.description.withUTF8Buffer { utf8 in
        for (i, byte) in utf8.prefix(255).enumerated() { p[i] = CChar(bitPattern: byte) }
    }
    return p
}

@c @implementation
public func cmsGetSupportedIntentsTHR(
    _ ContextID: cmsContext?,
    _ nMax: cmsUInt32Number,
    _ Codes: UnsafeMutablePointer<cmsUInt32Number>?,
    _ Descriptions: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> cmsUInt32Number {
    var n: cmsUInt32Number = 0
    for (i, entry) in defaultIntents.enumerated() {
        if n < nMax {
            Codes?[Int(n)] = entry.intent
            Descriptions?[Int(n)] = intentDescriptions[i]
        }
        n += 1
    }
    // A plugin's intents would follow.
    return n
}

@c @implementation
public func cmsGetSupportedIntents(
    _ nMax: cmsUInt32Number,
    _ Codes: UnsafeMutablePointer<cmsUInt32Number>?,
    _ Descriptions: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> cmsUInt32Number {
    cmsGetSupportedIntentsTHR(nil, nMax, Codes, Descriptions)
}
