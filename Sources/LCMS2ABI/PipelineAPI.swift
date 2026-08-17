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
    /// Makes an independent copy — the reference's `DupElemPtr`, except
    /// that here it rebuilds the whole stage rather than only its data,
    /// because the evaluator is a closure rather than a function pointer.
    var duplicate: ((StageBox) -> UnsafeMutablePointer<cmsStage>?)?
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
func stageHandle(_ box: StageBox) -> UnsafeMutablePointer<cmsStage> {
    StageBox.handle(for: box).assumingMemoryBound(to: cmsStage.self)
}

@inline(__always)
private func handle(_ box: StageBox) -> UnsafeMutablePointer<cmsStage> {
    stageHandle(box)
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

    /// `BlessLUT`: the pipeline's own channel counts follow its ends, and
    /// the answer says whether the chain actually joins up.  A chain that
    /// does not still stays linked — the reference reports the mismatch
    /// rather than undoing the insertion, and a caller that ignores the
    /// answer is left holding exactly that.
    @discardableResult
    func bless() -> Bool {
        guard let first = stage(stages.first), let last = stage(stages.last)
        else { return true }

        inputChannels = first.inputChannels
        outputChannels = last.outputChannels

        for i in 1..<max(stages.count, 1) {
            guard let previous = stage(stages[i - 1]), let next = stage(stages[i]),
                  next.inputChannels == previous.outputChannels
            else { return false }
        }
        return true
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
    box.duplicate = { cmsStageAllocIdentity($0.context, cmsUInt32Number($0.inputChannels)) }
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

    // The stage takes a copy of each curve: the caller keeps what it
    // passed and may free it the moment this returns.  Storing the
    // caller's pointers instead would look identical until someone did.
    //
    // No curves given means an identity ramp per channel, which the
    // reference builds rather than special-casing later.
    for i in 0..<count {
        if let Curves, let given = Curves[i] {
            curves[i] = cmsDupToneCurve(given)
        } else {
            var gamma = 1.0
            curves[i] = cmsBuildParametricToneCurve(ContextID, 1, &gamma)
        }
        if curves[i] == nil {
            for j in 0..<i { cmsFreeToneCurve(curves[j]) }
            _cmsFree(ContextID, curveArray)
            _cmsFree(ContextID, raw)
            return nil
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
    box.duplicate = { source in
        // Handing the originals over is enough — the allocator copies
        // them, so copying here first would make two copies and leak
        // one.
        guard let data = source.data?.assumingMemoryBound(to: _cmsStageToneCurvesData.self),
              let list = data.pointee.TheCurves
        else { return nil }
        return cmsStageAllocToneCurves(source.context, data.pointee.nCurves, list)
    }
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
    box.duplicate = { source in
        guard let data = source.data?.assumingMemoryBound(to: _cmsStageMatrixData.self)
        else { return nil }
        return cmsStageAllocMatrix(
            source.context,
            cmsUInt32Number(source.outputChannels), cmsUInt32Number(source.inputChannels),
            data.pointee.Double, data.pointee.Offset
        )
    }
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
        case cmsSigCLutElemType:
            freeCLutData(box, data)
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

@c @implementation
public func cmsStageDup(
    _ mpe: UnsafeMutablePointer<cmsStage>?
) -> UnsafeMutablePointer<cmsStage>? {
    guard let mpe, let box = stage(mpe), let duplicate = box.duplicate,
          let copy = duplicate(box)
    else { return nil }
    // What the stage *implements* can differ from what it is — a stage
    // built as a CLUT may stand in for a named transform — and the copy
    // stands in for the same thing.
    stage(copy)?.implements = box.implements
    return copy
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
    return box.bless() ? 1 : 0
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
    stage(removed)?.next = nil
    box.relink()
    // May fail, and the reference ignores it here.
    box.bless()

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

/// Whether a pipeline is marked to be stored in eight bits.  Only the
/// tag layer asks, and it asks through a raw pointer because that is
/// what a type-decision function is handed.
func pipelineSavesAs8Bits(_ data: UnsafeRawPointer) -> Bool {
    Unmanaged<PipelineBox>.fromOpaque(data).takeUnretainedValue().saveAs8Bits
}

@c @implementation
public func cmsGetPipelineContextID(_ lut: UnsafePointer<cmsPipeline>?) -> cmsContext? {
    pipeline(lut)?.context
}

@c @implementation
public func cmsPipelineDup(
    _ Orig: UnsafePointer<cmsPipeline>?
) -> UnsafeMutablePointer<cmsPipeline>? {
    guard let Orig, let source = pipeline(Orig) else { return nil }
    guard let copy = cmsPipelineAlloc(
        source.context,
        cmsUInt32Number(source.inputChannels), cmsUInt32Number(source.outputChannels)
    ), let box = pipeline(copy) else { return nil }

    for s in source.stages {
        guard let duplicated = cmsStageDup(s) else {
            cmsPipelineFree(copy)
            return nil
        }
        box.stages.append(duplicated)
    }
    box.relink()
    box.saveAs8Bits = source.saveAs8Bits

    if !box.bless() {
        cmsPipelineFree(copy)
        return nil
    }
    return copy
}

@c @implementation
public func cmsPipelineCat(
    _ l1: UnsafeMutablePointer<cmsPipeline>?,
    _ l2: UnsafePointer<cmsPipeline>?
) -> cmsBool {
    guard let l1, let l2, let first = pipeline(l1), let second = pipeline(l2) else { return 0 }

    // Two empty pipelines: the shape has to come from somewhere, so it
    // comes from the one being appended.
    if first.stages.isEmpty && second.stages.isEmpty {
        first.inputChannels = second.inputChannels
        first.outputChannels = second.outputChannels
    }

    for s in second.stages {
        // Each stage is copied — l2 keeps its own.
        if cmsPipelineInsertStage(l1, cmsAT_END, cmsStageDup(s)) == 0 { return 0 }
    }
    return first.bless() ? 1 : 0
}

/// Newton's method on a 3->3 or 4->3 pipeline: step towards the target
/// using a Jacobian estimated by finite differences, and stop as soon as
/// a step stops improving — the *previous* guess is then the answer, so
/// the result is written before each step rather than after the loop.
@c @implementation
public func cmsPipelineEvalReverseFloat(
    _ Target: UnsafeMutablePointer<cmsFloat32Number>?,
    _ Result: UnsafeMutablePointer<cmsFloat32Number>?,
    _ Hint: UnsafeMutablePointer<cmsFloat32Number>?,
    _ lut: UnsafePointer<cmsPipeline>?
) -> cmsBool {
    guard let Target, let Result, let box = pipeline(lut) else { return 0 }

    let inputs = box.inputChannels
    if inputs != 3 && inputs != 4 { return 0 }
    if box.outputChannels != 3 { return 0 }

    let epsilon: Float = 0.001
    let maximumIterations = 30

    var x = [Float](repeating: 0, count: 4)
    if let Hint {
        // Only three channels come from the hint whatever the shape.
        for j in 0..<3 { x[j] = Hint[j] }
    } else {
        // Begin at any point; a third of the way along each axis.
        x[0] = 0.3; x[1] = 0.3; x[2] = 0.3
    }
    // A four-input pipeline holds its fourth channel fixed.
    x[3] = inputs == 4 ? Target[3] : 0

    var fx = [Float](repeating: 0, count: 4)
    var xd = [Float](repeating: 0, count: 4)
    var fxd = [Float](repeating: 0, count: 4)
    var lastError = 1e20

    for _ in 0..<maximumIterations {
        x.withUnsafeBufferPointer { source in
            fx.withUnsafeMutableBufferPointer { destination in
                cmsPipelineEvalFloat(source.baseAddress!, destination.baseAddress!, lut)
            }
        }

        var sum: Float = 0
        for i in 0..<3 {
            let difference = Target[i] - fx[i]
            sum += difference * difference
        }
        // Square root is one of the operations IEEE 754 requires to be
        // correctly rounded, so this and the reference's sqrtf cannot
        // disagree — no libm shim needed for it.
        let error = cmsFloat64Number(sum.squareRoot())

        // Not converging any more: the last kept guess stands.
        if error >= lastError { break }
        lastError = error
        for j in 0..<inputs { Result[j] = x[j] }
        if error <= 0 { break }

        var jacobian = Matrix3(Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(0, 0, 0))
        for j in 0..<3 {
            for k in 0..<4 { xd[k] = x[k] }
            // Stepped away from the boundary rather than across it.
            if xd[j] < 1.0 - epsilon { xd[j] += epsilon } else { xd[j] -= epsilon }

            xd.withUnsafeBufferPointer { source in
                fxd.withUnsafeMutableBufferPointer { destination in
                    cmsPipelineEvalFloat(source.baseAddress!, destination.baseAddress!, lut)
                }
            }

            for row in 0..<3 {
                jacobian[row][j] = cmsFloat64Number((fxd[row] - fx[row]) / epsilon)
            }
        }

        guard let step = jacobian.solve(Vector3(
            cmsFloat64Number(fx[0] - Target[0]),
            cmsFloat64Number(fx[1] - Target[1]),
            cmsFloat64Number(fx[2] - Target[2])
        )) else { return 0 }

        x[0] -= cmsFloat32Number(step.x)
        x[1] -= cmsFloat32Number(step.y)
        x[2] -= cmsFloat32Number(step.z)

        for j in 0..<3 {
            if x[j] < 0 { x[j] = 0 } else if x[j] > 1.0 { x[j] = 1.0 }
        }
    }

    return 1
}

// -- stages the library builds for itself -------------------------------------

// These are the ordinary allocators with `Implements` set afterwards.
// The distinction matters: a stage *is* a matrix or a curve set, and
// separately it *stands for* something — a Lab version conversion, an
// identity — which the optimizer reads to recognise work it can drop.
// `cmsStageType` still answers with what the stage is.

@c @implementation
public func _cmsStageAllocIdentityCurves(
    _ ContextID: cmsContext?,
    _ nChannels: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    guard let mpe = cmsStageAllocToneCurves(ContextID, nChannels, nil) else { return nil }
    stage(mpe)?.implements = cmsSigIdentityElemType
    return mpe
}

/// Version 2 encoded Lab counts to 0xFF00 where version 4 counts to
/// 0xFFFF, so converting between them is a scale by 65535/65280 — near
/// enough to one that it looks like rounding noise and is not.
@c @implementation
public func _cmsStageAllocLabV2ToV4(
    _ ContextID: cmsContext?
) -> UnsafeMutablePointer<cmsStage>? {
    let scale = 65535.0 / 65280.0
    let matrix: [cmsFloat64Number] = [scale, 0, 0, 0, scale, 0, 0, 0, scale]
    guard let mpe = cmsStageAllocMatrix(ContextID, 3, 3, matrix, nil) else { return nil }
    stage(mpe)?.implements = cmsSigLabV2toV4
    return mpe
}

@c @implementation
public func _cmsStageAllocLabV4ToV2(
    _ ContextID: cmsContext?
) -> UnsafeMutablePointer<cmsStage>? {
    let scale = 65280.0 / 65535.0
    let matrix: [cmsFloat64Number] = [scale, 0, 0, 0, scale, 0, 0, 0, scale]
    guard let mpe = cmsStageAllocMatrix(ContextID, 3, 3, matrix, nil) else { return nil }
    stage(mpe)?.implements = cmsSigLabV4toV2
    return mpe
}

/// A CLUT that changes nothing: two nodes on every axis, sampled with
/// each node's own position.  Two is the fewest a grid can have and
/// still interpolate, so this is the cheapest possible identity — and
/// it exists because a device link has to carry a table even when the
/// table does nothing.
@c @implementation
public func _cmsStageAllocIdentityCLut(
    _ ContextID: cmsContext?,
    _ nChan: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    var dimensions = [cmsUInt32Number](repeating: 2, count: Int(MAX_INPUT_DIMENSIONS))
    guard let mpe = cmsStageAllocCLut16bitGranular(
        ContextID, &dimensions, nChan, nChan, nil
    ) else { return nil }

    var channels = nChan
    let sampled = withUnsafeMutablePointer(to: &channels) { cargo in
        cmsStageSampleCLut16bit(mpe, { input, output, cargo in
            guard let input, let output, let cargo else { return 0 }
            let n = Int(cargo.assumingMemoryBound(to: cmsUInt32Number.self).pointee)
            for i in 0..<n { output[i] = input[i] }
            return 1
        }, UnsafeMutableRawPointer(cargo), 0)
    }
    if sampled == 0 {
        cmsStageFree(mpe)
        return nil
    }

    stage(mpe)?.implements = cmsSigIdentityElemType
    return mpe
}

// The two PCS conversion stages.
//
// A pipeline's channels run 0..1, but neither Lab nor XYZ does, so each
// of these scales into the space, converts, and scales back out.  The
// XYZ scale is 1 + 32767/32768 — the largest value the 15.16 encoding
// can hold — so an XYZ channel of 1.0 in a pipeline means that, not one.

private let maximumEncodeableXYZ = 1.0 + 32767.0 / 32768.0

@c @implementation
public func _cmsStageAllocLab2XYZ(
    _ ContextID: cmsContext?
) -> UnsafeMutablePointer<cmsStage>? {
    let box = StageBox(
        context: ContextID,
        type: cmsSigLab2XYZElemType,
        inputChannels: 3,
        outputChannels: 3
    ) { input, output, _ in
        // Lab arrives with L over a hundred and the two chroma axes
        // offset by 128 into the unit interval.
        var lab = cmsCIELab(
            L: cmsFloat64Number(input[0]) * 100.0,
            a: cmsFloat64Number(input[1]) * 255.0 - 128.0,
            b: cmsFloat64Number(input[2]) * 255.0 - 128.0
        )
        var xyz = cmsCIEXYZ()
        cmsLab2XYZ(nil, &xyz, &lab)
        output[0] = cmsFloat32Number(xyz.X / maximumEncodeableXYZ)
        output[1] = cmsFloat32Number(xyz.Y / maximumEncodeableXYZ)
        output[2] = cmsFloat32Number(xyz.Z / maximumEncodeableXYZ)
    }
    box.duplicate = { _cmsStageAllocLab2XYZ($0.context) }
    return handle(box)
}

@c @implementation
public func _cmsStageAllocXYZ2Lab(
    _ ContextID: cmsContext?
) -> UnsafeMutablePointer<cmsStage>? {
    let box = StageBox(
        context: ContextID,
        type: cmsSigXYZ2LabElemType,
        inputChannels: 3,
        outputChannels: 3
    ) { input, output, _ in
        var xyz = cmsCIEXYZ(
            X: cmsFloat64Number(input[0]) * maximumEncodeableXYZ,
            Y: cmsFloat64Number(input[1]) * maximumEncodeableXYZ,
            Z: cmsFloat64Number(input[2]) * maximumEncodeableXYZ
        )
        var lab = cmsCIELab()
        cmsXYZ2Lab(nil, &lab, &xyz)
        output[0] = cmsFloat32Number(lab.L / 100.0)
        output[1] = cmsFloat32Number((lab.a + 128.0) / 255.0)
        output[2] = cmsFloat32Number((lab.b + 128.0) / 255.0)
    }
    box.duplicate = { _cmsStageAllocXYZ2Lab($0.context) }
    return handle(box)
}
