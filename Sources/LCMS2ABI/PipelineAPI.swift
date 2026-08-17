import CLCMS2
import LittleCMS

// Pipelines and the stages they chain.
//
// A pipeline evaluates in floating point throughout, whatever precision
// it was asked in: the 16-bit entry point widens on the way in, walks the
// stages, and narrows on the way out.  That is worth knowing, because it
// means a 16-bit transform through a pipeline is not 16-bit arithmetic.
//
// The stage objects are opaque — nothing published reaches into them —
// but a stage's *data* is not: cmsStageData hands out the pointer, and
// the shapes it can point at are declared in the plugin header for
// clients to cast to.  So the data blocks are C memory and the stages
// that own them are Swift.

final class StageBox: HandleBox {
    let context: cmsContext?
    var type: cmsStageSignature
    var implements: cmsStageSignature
    var inputChannels: Int
    var outputChannels: Int

    /// The published block cmsStageData returns, when the stage has one.
    var data: UnsafeMutableRawPointer?
    /// Anything the stage keeps alive that the block only points at.
    var retained: [AnyObject] = []
    /// Evaluated in floating point, always.
    var evaluate: (UnsafePointer<Float>, UnsafeMutablePointer<Float>, StageBox) -> Void
    /// The next stage in the pipeline, or nil at the end.
    var next: UnsafeMutablePointer<cmsStage>?

    init(
        context: cmsContext?,
        type: cmsStageSignature,
        inputChannels: Int,
        outputChannels: Int,
        evaluate: @escaping (UnsafePointer<Float>, UnsafeMutablePointer<Float>, StageBox) -> Void
    ) {
        self.context = context
        self.type = type
        implements = type
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.evaluate = evaluate
    }
}

@inline(__always)
private func stage(_ p: UnsafePointer<cmsStage>?) -> StageBox? {
    guard let p else { return nil }
    return Unmanaged<StageBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

@inline(__always)
private func handle(_ box: StageBox) -> UnsafeMutablePointer<cmsStage> {
    StageBox.handle(for: box).assumingMemoryBound(to: cmsStage.self)
}

final class PipelineBox: HandleBox {
    let context: cmsContext?
    var inputChannels: Int
    var outputChannels: Int
    var stages: [UnsafeMutablePointer<cmsStage>] = []
    var saveAs8Bits = false

    init(context: cmsContext?, inputChannels: Int, outputChannels: Int) {
        self.context = context
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
    }

    /// Keeps each stage's `next` agreeing with the array, since a client
    /// walks the chain with cmsStageNext rather than by index.
    func relink() {
        for (i, s) in stages.enumerated() {
            stage(s)?.next = i + 1 < stages.count ? stages[i + 1] : nil
        }
    }
}

@inline(__always)
private func pipeline(_ p: UnsafePointer<cmsPipeline>?) -> PipelineBox? {
    guard let p else { return nil }
    return Unmanaged<PipelineBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

@inline(__always)
private func handle(_ box: PipelineBox) -> UnsafeMutablePointer<cmsPipeline> {
    PipelineBox.handle(for: box).assumingMemoryBound(to: cmsPipeline.self)
}

// -- stages --------------------------------------------------------------

@c @implementation
public func cmsStageAllocIdentity(
    _ ContextID: cmsContext?,
    _ nChannels: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    let box = StageBox(
        context: ContextID,
        type: cmsSigIdentityElemType,
        inputChannels: Int(nChannels),
        outputChannels: Int(nChannels)
    ) { input, output, stage in
        for i in 0..<stage.inputChannels { output[i] = input[i] }
    }
    return handle(box)
}

@c @implementation
public func cmsStageAllocToneCurves(
    _ ContextID: cmsContext?,
    _ nChannels: cmsUInt32Number,
    _ Curves: UnsafePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> UnsafeMutablePointer<cmsStage>? {
    let count = Int(nChannels)

    guard let raw = _cmsMallocZero(
        ContextID, cmsUInt32Number(MemoryLayout<_cmsStageToneCurvesData>.size)
    ) else { return nil }
    let data = raw.assumingMemoryBound(to: _cmsStageToneCurvesData.self)

    guard let curveArray = _cmsCalloc(
        ContextID, nChannels, cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsToneCurve>?>.stride)
    ) else {
        _cmsFree(ContextID, raw)
        return nil
    }
    let curves = curveArray.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)

    // No curves given means an identity ramp per channel, which the
    // reference builds rather than special-casing later.
    for i in 0..<count {
        if let Curves, let given = Curves[i] {
            curves[i] = given
        } else {
            var gamma = 1.0
            curves[i] = cmsBuildParametricToneCurve(ContextID, 1, &gamma)
        }
    }

    data.pointee.nCurves = nChannels
    data.pointee.TheCurves = curves

    let box = StageBox(
        context: ContextID,
        type: cmsSigCurveSetElemType,
        inputChannels: count,
        outputChannels: count
    ) { input, output, stage in
        guard let data = stage.data?.assumingMemoryBound(to: _cmsStageToneCurvesData.self),
              let curves = data.pointee.TheCurves
        else { return }
        for i in 0..<Int(data.pointee.nCurves) {
            output[i] = cmsEvalToneCurveFloat(curves[i], input[i])
        }
    }
    box.data = raw
    return handle(box)
}

@c @implementation
public func cmsStageAllocMatrix(
    _ ContextID: cmsContext?,
    _ Rows: cmsUInt32Number,
    _ Cols: cmsUInt32Number,
    _ Matrix: UnsafePointer<cmsFloat64Number>?,
    _ Offset: UnsafePointer<cmsFloat64Number>?
) -> UnsafeMutablePointer<cmsStage>? {
    let elements = Int(Rows) * Int(Cols)
    // The reference refuses a matrix whose element count has overflowed.
    if Rows == 0 || Cols == 0 || elements / Int(Cols) != Int(Rows) { return nil }

    guard let raw = _cmsMallocZero(
        ContextID, cmsUInt32Number(MemoryLayout<_cmsStageMatrixData>.size)
    ) else { return nil }
    let data = raw.assumingMemoryBound(to: _cmsStageMatrixData.self)

    guard let doubles = _cmsCalloc(
        ContextID, cmsUInt32Number(elements), cmsUInt32Number(MemoryLayout<cmsFloat64Number>.stride)
    ) else {
        _cmsFree(ContextID, raw)
        return nil
    }
    let values = doubles.assumingMemoryBound(to: cmsFloat64Number.self)
    if let Matrix {
        for i in 0..<elements { values[i] = Matrix[i] }
    }
    data.pointee.Double = values

    if let Offset {
        guard let offsets = _cmsCalloc(
            ContextID, Rows, cmsUInt32Number(MemoryLayout<cmsFloat64Number>.stride)
        ) else {
            _cmsFree(ContextID, doubles)
            _cmsFree(ContextID, raw)
            return nil
        }
        let o = offsets.assumingMemoryBound(to: cmsFloat64Number.self)
        for i in 0..<Int(Rows) { o[i] = Offset[i] }
        data.pointee.Offset = o
    }

    let box = StageBox(
        context: ContextID,
        type: cmsSigMatrixElemType,
        inputChannels: Int(Cols),
        outputChannels: Int(Rows)
    ) { input, output, stage in
        guard let data = stage.data?.assumingMemoryBound(to: _cmsStageMatrixData.self),
              let matrix = data.pointee.Double
        else { return }

        // Accumulated in double and narrowed once, which the reference
        // calls out: doing it in float loses precision visibly.
        for i in 0..<stage.outputChannels {
            var sum = 0.0
            for j in 0..<stage.inputChannels {
                sum += cmsFloat64Number(input[j]) * matrix[i * stage.inputChannels + j]
            }
            if let offset = data.pointee.Offset {
                sum += offset[i]
            }
            output[i] = cmsFloat32Number(sum)
        }
    }
    box.data = raw
    return handle(box)
}

@c @implementation
public func cmsStageFree(_ mpe: UnsafeMutablePointer<cmsStage>?) {
    guard let mpe, let box = stage(mpe) else { return }

    // The published block and whatever hangs off it.
    if let data = box.data {
        switch box.type {
        case cmsSigCurveSetElemType:
            let curves = data.assumingMemoryBound(to: _cmsStageToneCurvesData.self)
            if let list = curves.pointee.TheCurves {
                for i in 0..<Int(curves.pointee.nCurves) {
                    cmsFreeToneCurve(list[i])
                }
                _cmsFree(box.context, UnsafeMutableRawPointer(list))
            }
        case cmsSigMatrixElemType:
            let matrix = data.assumingMemoryBound(to: _cmsStageMatrixData.self)
            if let values = matrix.pointee.Double {
                _cmsFree(box.context, UnsafeMutableRawPointer(values))
            }
            if let offset = matrix.pointee.Offset {
                _cmsFree(box.context, UnsafeMutableRawPointer(offset))
            }
        default:
            break
        }
        _cmsFree(box.context, data)
    }

    _ = StageBox.consume(UnsafeMutableRawPointer(mpe))
}

@c @implementation
public func cmsStageNext(_ mpe: UnsafePointer<cmsStage>?) -> UnsafeMutablePointer<cmsStage>? {
    stage(mpe)?.next
}

@c @implementation
public func cmsStageInputChannels(_ mpe: UnsafePointer<cmsStage>?) -> cmsUInt32Number {
    cmsUInt32Number(stage(mpe)?.inputChannels ?? 0)
}

@c @implementation
public func cmsStageOutputChannels(_ mpe: UnsafePointer<cmsStage>?) -> cmsUInt32Number {
    cmsUInt32Number(stage(mpe)?.outputChannels ?? 0)
}

@c @implementation
public func cmsStageType(_ mpe: UnsafePointer<cmsStage>?) -> cmsStageSignature {
    stage(mpe)?.type ?? cmsStageSignature(0)
}

@c @implementation
public func cmsStageData(_ mpe: UnsafePointer<cmsStage>?) -> UnsafeMutableRawPointer? {
    // The live block, not a copy: a client that samples a CLUT writes
    // through this, and the stage has to see what it wrote.
    stage(mpe)?.data
}

@c @implementation
public func cmsGetStageContextID(_ mpe: UnsafePointer<cmsStage>?) -> cmsContext? {
    stage(mpe)?.context
}

// -- pipelines ------------------------------------------------------------

@c @implementation
public func cmsPipelineAlloc(
    _ ContextID: cmsContext?,
    _ InputChannels: cmsUInt32Number,
    _ OutputChannels: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    // Zero is allowed and means a placeholder; the ceiling is not.
    if Int(InputChannels) >= maximumChannels || Int(OutputChannels) >= maximumChannels {
        return nil
    }
    return handle(PipelineBox(
        context: ContextID,
        inputChannels: Int(InputChannels),
        outputChannels: Int(OutputChannels)
    ))
}

@c @implementation
public func cmsPipelineFree(_ lut: UnsafeMutablePointer<cmsPipeline>?) {
    guard let lut, let box = pipeline(lut) else { return }
    // A pipeline owns the stages inserted into it.
    for s in box.stages { cmsStageFree(s) }
    box.stages.removeAll()
    _ = PipelineBox.consume(UnsafeMutableRawPointer(lut))
}

@c @implementation
public func cmsPipelineInputChannels(_ lut: UnsafePointer<cmsPipeline>?) -> cmsUInt32Number {
    cmsUInt32Number(pipeline(lut)?.inputChannels ?? 0)
}

@c @implementation
public func cmsPipelineOutputChannels(_ lut: UnsafePointer<cmsPipeline>?) -> cmsUInt32Number {
    cmsUInt32Number(pipeline(lut)?.outputChannels ?? 0)
}

@c @implementation
public func cmsPipelineStageCount(_ lut: UnsafePointer<cmsPipeline>?) -> cmsUInt32Number {
    cmsUInt32Number(pipeline(lut)?.stages.count ?? 0)
}

@c @implementation
public func cmsPipelineGetPtrToFirstStage(
    _ lut: UnsafePointer<cmsPipeline>?
) -> UnsafeMutablePointer<cmsStage>? {
    pipeline(lut)?.stages.first
}

@c @implementation
public func cmsPipelineGetPtrToLastStage(
    _ lut: UnsafePointer<cmsPipeline>?
) -> UnsafeMutablePointer<cmsStage>? {
    pipeline(lut)?.stages.last
}

@c @implementation
public func cmsPipelineSetSaveAs8bitsFlag(
    _ lut: UnsafeMutablePointer<cmsPipeline>?,
    _ On: cmsBool
) -> cmsBool {
    guard let box = pipeline(lut) else { return 0 }
    let previous = box.saveAs8Bits
    box.saveAs8Bits = On != 0
    return previous ? 1 : 0
}

@c @implementation
public func cmsPipelineInsertStage(
    _ lut: UnsafeMutablePointer<cmsPipeline>?,
    _ loc: cmsStageLoc,
    _ mpe: UnsafeMutablePointer<cmsStage>?
) -> cmsBool {
    guard let box = pipeline(lut), let mpe else { return 0 }

    if loc == cmsAT_BEGIN {
        box.stages.insert(mpe, at: 0)
    } else {
        box.stages.append(mpe)
    }
    box.relink()

    // The pipeline's own channel counts follow its ends.
    if let first = box.stages.first, let firstBox = stage(first) {
        box.inputChannels = firstBox.inputChannels
    }
    if let last = box.stages.last, let lastBox = stage(last) {
        box.outputChannels = lastBox.outputChannels
    }
    return 1
}

@c @implementation
public func cmsPipelineUnlinkStage(
    _ lut: UnsafeMutablePointer<cmsPipeline>?,
    _ loc: cmsStageLoc,
    _ mpe: UnsafeMutablePointer<UnsafeMutablePointer<cmsStage>?>?
) {
    guard let box = pipeline(lut), !box.stages.isEmpty else {
        mpe?.pointee = nil
        return
    }

    let removed = loc == cmsAT_BEGIN ? box.stages.removeFirst() : box.stages.removeLast()
    box.relink()

    if let first = box.stages.first, let firstBox = stage(first) {
        box.inputChannels = firstBox.inputChannels
    }
    if let last = box.stages.last, let lastBox = stage(last) {
        box.outputChannels = lastBox.outputChannels
    }

    // Handing the stage back transfers it; keeping no pointer frees it.
    if let mpe {
        mpe.pointee = removed
    } else {
        cmsStageFree(removed)
    }
}

@c @implementation
public func cmsPipelineEvalFloat(
    _ In: UnsafePointer<cmsFloat32Number>?,
    _ Out: UnsafeMutablePointer<cmsFloat32Number>?,
    _ lut: UnsafePointer<cmsPipeline>?
) {
    guard let In, let Out, let box = pipeline(lut) else { return }

    // Two buffers ping-ponged through the chain, as the reference does.
    var storage = [[Float]](
        repeating: [Float](repeating: 0, count: maximumStageChannels), count: 2
    )
    for i in 0..<box.inputChannels { storage[0][i] = In[i] }

    var phase = 0
    for s in box.stages {
        guard let stageBox = stage(s) else { continue }
        let next = phase ^ 1
        storage[phase].withUnsafeBufferPointer { source in
            storage[next].withUnsafeMutableBufferPointer { destination in
                stageBox.evaluate(source.baseAddress!, destination.baseAddress!, stageBox)
            }
        }
        phase = next
    }

    for i in 0..<box.outputChannels { Out[i] = storage[phase][i] }
}

@c @implementation
public func cmsPipelineEval16(
    _ In: UnsafePointer<cmsUInt16Number>?,
    _ Out: UnsafeMutablePointer<cmsUInt16Number>?,
    _ lut: UnsafePointer<cmsPipeline>?
) {
    guard let In, let Out, let box = pipeline(lut) else { return }

    // Widened on the way in and narrowed on the way out: a pipeline is
    // evaluated in floating point whatever precision it was asked in.
    var input = [Float](repeating: 0, count: maximumStageChannels)
    var output = [Float](repeating: 0, count: maximumStageChannels)
    for i in 0..<box.inputChannels {
        input[i] = cmsFloat32Number(In[i]) / 65535.0
    }

    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            cmsPipelineEvalFloat(source.baseAddress!, destination.baseAddress!, lut)
        }
    }

    for i in 0..<box.outputChannels {
        Out[i] = quickSaturateWord(cmsFloat64Number(output[i]) * 65535.0)
    }
}

@c @implementation
public func cmsGetPipelineContextID(_ lut: UnsafePointer<cmsPipeline>?) -> cmsContext? {
    pipeline(lut)?.context
}
