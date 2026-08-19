import CLCMS2
import LittleCMS

// CLUT stages: a multi-dimensional table, the interpolation parameters
// that describe its shape, and the samplers that walk it.
//
// Three things have to be the same live memory, not copies of each
// other: the table, the `_cmsStageCLutData` block `cmsStageData` hands
// out, and the `cmsInterpParams` that block points at.  A client samples
// a CLUT by writing through `Tab.T` and then evaluates the stage, and a
// plugin may call `Params->Interpolation.Lerp16` itself.  So the
// evaluator reads the same pointer the client wrote through, and calls
// through the same function pointer the client can read — which is also
// what lets a replaced kernel take effect.

private let maximumInputDimensions = Int(MAX_INPUT_DIMENSIONS)

/// `CubeSize`: how many table entries a grid of these node counts needs,
/// or zero if the answer is unusable — a dimension with one node cannot
/// be interpolated, and the product must stay inside a 32-bit count with
/// room to spare for the indexing arithmetic.
private func cubeSize(_ dimensions: UnsafePointer<cmsUInt32Number>, _ inputs: Int) -> UInt32 {
    var result: UInt64 = 1
    var b = inputs
    while b > 0 {
        let dimension = UInt64(dimensions[b - 1])
        if dimension <= 1 { return 0 }
        if result > UInt64(UInt32.max) / dimension { return 0 }
        result *= dimension
        b -= 1
    }
    // Again, before anything multiplies it by an output count.
    if result > UInt64(UInt32.max) / 15 { return 0 }
    return UInt32(result)
}

@inline(__always)
private func clutData(_ mpe: UnsafePointer<cmsStage>?) -> UnsafeMutablePointer<_cmsStageCLutData>? {
    guard let raw = cmsStageData(mpe) else { return nil }
    return raw.assumingMemoryBound(to: _cmsStageCLutData.self)
}

// -- building -------------------------------------------------------------

/// Both granular allocators are this function; they differ only in which
/// arm of the table union they fill and which flag the parameters carry.
private func allocateCLut(
    _ ContextID: cmsContext?,
    _ clutPoints: UnsafePointer<cmsUInt32Number>,
    _ inputChan: cmsUInt32Number,
    _ outputChan: cmsUInt32Number,
    _ table16: UnsafePointer<cmsUInt16Number>?,
    _ tableFloat: UnsafePointer<cmsFloat32Number>?,
    isFloat: Bool
) -> UnsafeMutablePointer<cmsStage>? {
    if Int(inputChan) > maximumInputDimensions {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Too many input channels (\(inputChan) channels, max=\(maximumInputDimensions))",
            to: ContextID
        )
        return nil
    }

    let cube = cubeSize(clutPoints, Int(inputChan))
    let entries = UInt64(outputChan) * UInt64(cube)
    if entries == 0 || entries > UInt64(UInt32.max) { return nil }
    let count = Int(entries)

    guard let raw = _cmsMallocZero(
        ContextID, cmsUInt32Number(MemoryLayout<_cmsStageCLutData>.size)
    ) else { return nil }
    let data = raw.assumingMemoryBound(to: _cmsStageCLutData.self)

    let elementSize = isFloat
        ? MemoryLayout<cmsFloat32Number>.stride
        : MemoryLayout<cmsUInt16Number>.stride
    guard let tableStorage = _cmsCalloc(
        ContextID, cmsUInt32Number(count), cmsUInt32Number(elementSize)
    ) else {
        _cmsFree(ContextID, raw)
        return nil
    }

    data.pointee.nEntries = cmsUInt32Number(count)
    data.pointee.HasFloatValues = isFloat ? 1 : 0

    if isFloat {
        let values = tableStorage.assumingMemoryBound(to: cmsFloat32Number.self)
        if let tableFloat {
            for i in 0..<count { values[i] = tableFloat[i] }
        }
        data.pointee.Tab.TFloat = values
    } else {
        let values = tableStorage.assumingMemoryBound(to: cmsUInt16Number.self)
        if let table16 {
            for i in 0..<count { values[i] = table16[i] }
        }
        data.pointee.Tab.T = values
    }

    let flags = cmsUInt32Number(isFloat ? CMS_LERP_FLAGS_FLOAT : CMS_LERP_FLAGS_16BITS)
    guard let params = computeInterpParams(
        ContextID, clutPoints, inputChan, outputChan, tableStorage, flags
    ) else {
        _cmsFree(ContextID, tableStorage)
        _cmsFree(ContextID, raw)
        return nil
    }
    data.pointee.Params = params

    // Chosen once here rather than per evaluation, as the reference does
    // when it picks an EvalPtr.  Spelled as a statement rather than a
    // conditional expression: the type checker cannot handle a ternary
    // between two function references here.
    let evaluate: (UnsafePointer<Float>, UnsafeMutablePointer<Float>, StageBox) -> Void
    if isFloat {
        evaluate = evaluateCLutFloat
    } else {
        evaluate = evaluateCLutIn16
    }

    let box = StageBox(
        context: ContextID,
        type: cmsSigCLutElemType,
        inputChannels: Int(inputChan),
        outputChannels: Int(outputChan),
        evaluate: evaluate
    )
    box.data = raw
    box.duplicate = duplicateCLut
    return stageHandle(box)
}

/// A float CLUT is interpolated directly.
private func evaluateCLutFloat(
    _ input: UnsafePointer<Float>,
    _ output: UnsafeMutablePointer<Float>,
    _ box: StageBox
) {
    guard let data = box.data?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = data.pointee.Params,
          let lerp = params.pointee.Interpolation.LerpFloat
    else { return }
    lerp(input, output, params)
}

/// A 16-bit CLUT is reached through a conversion at each end, so a
/// pipeline that contains one loses precision there even in float.
private func evaluateCLutIn16(
    _ input: UnsafePointer<Float>,
    _ output: UnsafeMutablePointer<Float>,
    _ box: StageBox
) {
    guard let data = box.data?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = data.pointee.Params,
          let lerp = params.pointee.Interpolation.Lerp16
    else { return }

    var in16 = [cmsUInt16Number](repeating: 0, count: maximumStageChannels)
    var out16 = [cmsUInt16Number](repeating: 0, count: maximumStageChannels)

    for i in 0..<box.inputChannels {
        in16[i] = quickSaturateWord(cmsFloat64Number(input[i]) * 65535.0)
    }
    in16.withUnsafeBufferPointer { source in
        out16.withUnsafeMutableBufferPointer { destination in
            lerp(source.baseAddress!, destination.baseAddress!, params)
        }
    }
    for i in 0..<box.outputChannels {
        output[i] = cmsFloat32Number(out16[i]) / 65535.0
    }
}

/// The copy gets its own table and its own parameters pointing at that
/// table — sharing either would make two stages one.
private func duplicateCLut(_ box: StageBox) -> UnsafeMutablePointer<cmsStage>? {
    guard let data = box.data?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = data.pointee.Params
    else { return nil }

    let isFloat = data.pointee.HasFloatValues != 0
    let copy = withUnsafeBytes(of: &params.pointee.nSamples) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { samples in
            allocateCLut(
                box.context, samples.baseAddress!,
                cmsUInt32Number(box.inputChannels), cmsUInt32Number(box.outputChannels),
                isFloat ? nil : data.pointee.Tab.T,
                isFloat ? data.pointee.Tab.TFloat : nil,
                isFloat: isFloat
            )
        }
    }
    // The interpolation flags come along too: a CLUT switched to
    // trilinear stays trilinear when the pipeline holding it is copied
    // into a transform, which is the whole point of switching it.  Found
    // when a Lab-indexed output profile came out a code or two off.
    if let copy, let copied = cmsStageData(copy)?.assumingMemoryBound(to: _cmsStageCLutData.self),
       let copiedParams = copied.pointee.Params
    {
        copiedParams.pointee.dwFlags = params.pointee.dwFlags
    }
    return copy
}

/// Releases what a CLUT stage owns.  Called from `cmsStageFree`.
func freeCLutData(_ box: StageBox, _ data: UnsafeMutableRawPointer) {
    let clut = data.assumingMemoryBound(to: _cmsStageCLutData.self)
    // Either arm of the union is the same allocation.
    if let table = clut.pointee.Tab.T {
        _cmsFree(box.context, UnsafeMutableRawPointer(table))
    }
    _cmsFreeInterpParams(clut.pointee.Params)
}

// -- the four allocators --------------------------------------------------

@c @implementation
public func cmsStageAllocCLut16bitGranular(
    _ ContextID: cmsContext?,
    _ clutPoints: UnsafePointer<cmsUInt32Number>?,
    _ inputChan: cmsUInt32Number,
    _ outputChan: cmsUInt32Number,
    _ Table: UnsafePointer<cmsUInt16Number>?
) -> UnsafeMutablePointer<cmsStage>? {
    guard let clutPoints else { return nil }
    return allocateCLut(ContextID, clutPoints, inputChan, outputChan, Table, nil, isFloat: false)
}

@c @implementation
public func cmsStageAllocCLutFloatGranular(
    _ ContextID: cmsContext?,
    _ clutPoints: UnsafePointer<cmsUInt32Number>?,
    _ inputChan: cmsUInt32Number,
    _ outputChan: cmsUInt32Number,
    _ Table: UnsafePointer<cmsFloat32Number>?
) -> UnsafeMutablePointer<cmsStage>? {
    guard let clutPoints else { return nil }
    return allocateCLut(ContextID, clutPoints, inputChan, outputChan, nil, Table, isFloat: true)
}

@c @implementation
public func cmsStageAllocCLut16bit(
    _ ContextID: cmsContext?,
    _ nGridPoints: cmsUInt32Number,
    _ inputChan: cmsUInt32Number,
    _ outputChan: cmsUInt32Number,
    _ Table: UnsafePointer<cmsUInt16Number>?
) -> UnsafeMutablePointer<cmsStage>? {
    var dimensions = [cmsUInt32Number](
        repeating: nGridPoints, count: maximumInputDimensions
    )
    return cmsStageAllocCLut16bitGranular(ContextID, &dimensions, inputChan, outputChan, Table)
}

@c @implementation
public func cmsStageAllocCLutFloat(
    _ ContextID: cmsContext?,
    _ nGridPoints: cmsUInt32Number,
    _ inputChan: cmsUInt32Number,
    _ outputChan: cmsUInt32Number,
    _ Table: UnsafePointer<cmsFloat32Number>?
) -> UnsafeMutablePointer<cmsStage>? {
    var dimensions = [cmsUInt32Number](
        repeating: nGridPoints, count: maximumInputDimensions
    )
    return cmsStageAllocCLutFloatGranular(ContextID, &dimensions, inputChan, outputChan, Table)
}

// -- sampling --------------------------------------------------------------

/// The node index walks the grid the way the table is laid out: the last
/// input varies fastest.  `SAMPLER_INSPECT` makes the walk read-only —
/// the sampler still sees every node, but nothing it writes is kept.
@c @implementation
public func cmsStageSampleCLut16bit(
    _ mpe: UnsafeMutablePointer<cmsStage>?,
    _ Sampler: cmsSAMPLER16?,
    _ Cargo: UnsafeMutableRawPointer?,
    _ dwFlags: cmsUInt32Number
) -> cmsBool {
    guard let mpe, let Sampler, let clut = clutData(mpe),
          let params = clut.pointee.Params
    else { return 0 }

    let inputs = Int(params.pointee.nInputs)
    let outputs = Int(params.pointee.nOutputs)
    if inputs <= 0 || outputs <= 0 { return 0 }
    if inputs > maximumInputDimensions { return 0 }
    // The reference is strict here where the input bound is not.
    if outputs >= maximumStageChannels { return 0 }

    var samples = [cmsUInt32Number](repeating: 0, count: maximumInputDimensions)
    withUnsafeBytes(of: &params.pointee.nSamples) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { values in
            for i in 0..<maximumInputDimensions { samples[i] = values[i] }
        }
    }

    let total = cubeSize(samples, inputs)
    if total == 0 { return 0 }

    var input = [cmsUInt16Number](repeating: 0, count: maximumInputDimensions + 1)
    var output = [cmsUInt16Number](repeating: 0, count: maximumStageChannels)
    let table = clut.pointee.Tab.T
    let keep = (dwFlags & cmsUInt32Number(SAMPLER_INSPECT)) == 0

    var index = 0
    for node in 0..<Int(total) {
        var rest = node
        for t in stride(from: inputs - 1, through: 0, by: -1) {
            let colorant = rest % Int(samples[t])
            rest /= Int(samples[t])
            input[t] = quantizeValue(cmsFloat64Number(colorant), maxSamples: samples[t])
        }

        if let table {
            for t in 0..<outputs { output[t] = table[index + t] }
        }

        let accepted = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                Sampler(source.baseAddress!, destination.baseAddress!, Cargo)
            }
        }
        if accepted == 0 { return 0 }

        if keep, let table {
            for t in 0..<outputs { table[index + t] = output[t] }
        }
        index += outputs
    }

    return 1
}

@c @implementation
public func cmsStageSampleCLutFloat(
    _ mpe: UnsafeMutablePointer<cmsStage>?,
    _ Sampler: cmsSAMPLERFLOAT?,
    _ Cargo: UnsafeMutableRawPointer?,
    _ dwFlags: cmsUInt32Number
) -> cmsBool {
    guard let mpe, let Sampler, let clut = clutData(mpe),
          let params = clut.pointee.Params
    else { return 0 }

    let inputs = Int(params.pointee.nInputs)
    let outputs = Int(params.pointee.nOutputs)
    if inputs <= 0 || outputs <= 0 { return 0 }
    if inputs > maximumInputDimensions { return 0 }
    if outputs >= maximumStageChannels { return 0 }

    var samples = [cmsUInt32Number](repeating: 0, count: maximumInputDimensions)
    withUnsafeBytes(of: &params.pointee.nSamples) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { values in
            for i in 0..<maximumInputDimensions { samples[i] = values[i] }
        }
    }

    let total = cubeSize(samples, inputs)
    if total == 0 { return 0 }

    var input = [cmsFloat32Number](repeating: 0, count: maximumInputDimensions + 1)
    var output = [cmsFloat32Number](repeating: 0, count: maximumStageChannels)
    let table = clut.pointee.Tab.TFloat
    let keep = (dwFlags & cmsUInt32Number(SAMPLER_INSPECT)) == 0

    var index = 0
    for node in 0..<Int(total) {
        var rest = node
        for t in stride(from: inputs - 1, through: 0, by: -1) {
            let colorant = rest % Int(samples[t])
            rest /= Int(samples[t])
            // Quantized as a 16-bit code and then scaled, not computed
            // in float — the grid positions are the same either way.
            input[t] = cmsFloat32Number(
                cmsFloat64Number(quantizeValue(cmsFloat64Number(colorant), maxSamples: samples[t]))
                    / 65535.0
            )
        }

        if let table {
            for t in 0..<outputs { output[t] = table[index + t] }
        }

        let accepted = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                Sampler(source.baseAddress!, destination.baseAddress!, Cargo)
            }
        }
        if accepted == 0 { return 0 }

        if keep, let table {
            for t in 0..<outputs { table[index + t] = output[t] }
        }
        index += outputs
    }

    return 1
}

// -- slicing ---------------------------------------------------------------

/// The same walk with no table behind it: the sampler is handed each
/// node position and nowhere to put an answer.
@c @implementation
public func cmsSliceSpace16(
    _ nInputs: cmsUInt32Number,
    _ clutPoints: UnsafePointer<cmsUInt32Number>?,
    _ Sampler: cmsSAMPLER16?,
    _ Cargo: UnsafeMutableRawPointer?
) -> cmsBool {
    guard let clutPoints, let Sampler else { return 0 }
    if Int(nInputs) >= maximumChannels { return 0 }

    let total = cubeSize(clutPoints, Int(nInputs))
    if total == 0 { return 0 }

    var input = [cmsUInt16Number](repeating: 0, count: maximumChannels)
    for node in 0..<Int(total) {
        var rest = node
        for t in stride(from: Int(nInputs) - 1, through: 0, by: -1) {
            let colorant = rest % Int(clutPoints[t])
            rest /= Int(clutPoints[t])
            input[t] = quantizeValue(cmsFloat64Number(colorant), maxSamples: clutPoints[t])
        }
        let accepted = input.withUnsafeBufferPointer { source in
            Sampler(source.baseAddress!, nil, Cargo)
        }
        if accepted == 0 { return 0 }
    }
    return 1
}

@c @implementation
public func cmsSliceSpaceFloat(
    _ nInputs: cmsUInt32Number,
    _ clutPoints: UnsafePointer<cmsUInt32Number>?,
    _ Sampler: cmsSAMPLERFLOAT?,
    _ Cargo: UnsafeMutableRawPointer?
) -> cmsBool {
    guard let clutPoints, let Sampler else { return 0 }
    if Int(nInputs) >= maximumChannels { return 0 }

    let total = cubeSize(clutPoints, Int(nInputs))
    if total == 0 { return 0 }

    var input = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    for node in 0..<Int(total) {
        var rest = node
        for t in stride(from: Int(nInputs) - 1, through: 0, by: -1) {
            let colorant = rest % Int(clutPoints[t])
            rest /= Int(clutPoints[t])
            input[t] = cmsFloat32Number(
                cmsFloat64Number(
                    quantizeValue(cmsFloat64Number(colorant), maxSamples: clutPoints[t])
                ) / 65535.0
            )
        }
        let accepted = input.withUnsafeBufferPointer { source in
            Sampler(source.baseAddress!, nil, Cargo)
        }
        if accepted == 0 { return 0 }
    }
    return 1
}
