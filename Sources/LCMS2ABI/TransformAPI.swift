import CLCMS2
import LittleCMS

// The transform: a pipeline with a pixel layout at each end.
//
// Creating one links the profiles into a pipeline, chooses the
// formatters that unpack the input layout and pack the output one, and
// picks the loop that joins them — 16-bit or floating point, with or
// without a one-pixel cache, with or without a gamut check.  Applying
// one runs that loop over a buffer.
//
// The handle a caller holds is a small C struct: its head is the two
// format words, where the reference's testbed expects to find them, and
// the rest is the box behind `swift_ctx`.  Once created a transform is
// not changed by use — the cache is copied to the stack per call — so
// one may be applied from several threads at once, as the reference
// promises.

final class TransformBox {
    let context: cmsContext?
    var inputFormat: cmsUInt32Number
    var outputFormat: cmsUInt32Number

    /// The loop that applies the transform.  A C function, so that a
    /// plugin may supply one and a parallelization plugin may wrap it.
    var xform: _cmsTransform2Fn?

    var fromInput: cmsFormatter16?
    var toOutput: cmsFormatter16?
    var fromInputFloat: cmsFormatterFloat?
    var toOutputFloat: cmsFormatterFloat?

    /// The seed of the one-pixel cache: zero in, and what zero maps to.
    var cacheIn = [cmsUInt16Number](repeating: 0, count: maximumChannels)
    var cacheOut = [cmsUInt16Number](repeating: 0, count: maximumChannels)

    var lut: UnsafeMutablePointer<cmsPipeline>?
    var gamutCheck: UnsafeMutablePointer<cmsPipeline>?

    var inputColorant: UnsafeMutablePointer<cmsNAMEDCOLORLIST>?
    var outputColorant: UnsafeMutablePointer<cmsNAMEDCOLORLIST>?

    var entryColorSpace = cmsColorSpaceSignature(0)
    var exitColorSpace = cmsColorSpaceSignature(0)
    var entryWhitePoint = cmsCIEXYZ()
    var exitWhitePoint = cmsCIEXYZ()

    var sequence: UnsafeMutablePointer<cmsSEQ>?

    var originalFlags: cmsUInt32Number = 0
    var adaptationState: cmsFloat64Number = 0
    var renderingIntent: cmsUInt32Number = 0

    var userData: UnsafeMutableRawPointer?
    var freeUserData: _cmsFreeUserDataFn?

    var oldXform: _cmsTransformFn?
    var worker: _cmsTransform2Fn?
    var maxWorkers: cmsInt32Number = 0
    var workerFlags: cmsUInt32Number = 0

    init(context: cmsContext?, inputFormat: cmsUInt32Number, outputFormat: cmsUInt32Number) {
        self.context = context
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }
}

public typealias TransformHandle = UnsafeMutablePointer<_cmstransform_struct>

/// A private flag the reference sets in the transform's flags — not in
/// any shipped header — recording that the formatters may be swapped
/// after creation.
private let canChangeFormatter: cmsUInt32Number = 0x0200_0000

@inline(__always)
func transform(_ p: TransformHandle?) -> TransformBox? {
    guard let p, let ctx = p.pointee.swift_ctx else { return nil }
    return Unmanaged<TransformBox>.fromOpaque(ctx).takeUnretainedValue()
}

@inline(__always)
private func transform(_ h: cmsHTRANSFORM?) -> TransformBox? {
    transform(h?.assumingMemoryBound(to: _cmstransform_struct.self))
}

/// A new handle over the box; the struct's format words mirror the box's.
private func allocateHandle(_ box: TransformBox) -> TransformHandle? {
    guard let raw = _cmsMallocZero(
        box.context, cmsUInt32Number(MemoryLayout<_cmstransform_struct>.size)
    ) else { return nil }
    let p = raw.assumingMemoryBound(to: _cmstransform_struct.self)
    p.pointee.InputFormat = box.inputFormat
    p.pointee.OutputFormat = box.outputFormat
    p.pointee.swift_ctx = Unmanaged.passRetained(box).toOpaque()
    return p
}

@c @implementation
public func cmsDeleteTransform(_ hTransform: cmsHTRANSFORM?) {
    guard let hTransform else { return }
    let p = hTransform.assumingMemoryBound(to: _cmstransform_struct.self)
    guard let ctx = p.pointee.swift_ctx else { return }
    let box = Unmanaged<TransformBox>.fromOpaque(ctx).takeRetainedValue()

    if let gamut = box.gamutCheck { cmsPipelineFree(gamut) }
    if let lut = box.lut { cmsPipelineFree(lut) }
    if let colorant = box.inputColorant { cmsFreeNamedColorList(colorant) }
    if let colorant = box.outputColorant { cmsFreeNamedColorList(colorant) }
    if let sequence = box.sequence { cmsFreeProfileSequenceDescription(sequence) }
    if let userData = box.userData, let free = box.freeUserData {
        free(box.context, userData)
    }
    _cmsFree(box.context, UnsafeMutableRawPointer(p))
}

// -- applying ------------------------------------------------------------------

/// The bytes one channel takes in a layout, where the byte field's zero
/// means a double.
@inline(__always)
private func pixelSize(_ format: cmsUInt32Number) -> cmsUInt32Number {
    let bytes = cmsUInt32Number(PixelFormat(format).bytes)
    return bytes == 0 ? cmsUInt32Number(MemoryLayout<cmsUInt64Number>.size) : bytes
}

@c @implementation
public func cmsDoTransform(
    _ Transform: cmsHTRANSFORM?,
    _ InputBuffer: UnsafeRawPointer?,
    _ OutputBuffer: UnsafeMutableRawPointer?,
    _ Size: cmsUInt32Number
) {
    guard let Transform, let box = transform(Transform), let xform = box.xform else { return }
    let p = Transform.assumingMemoryBound(to: _cmstransform_struct.self)
    var stride = cmsStride(
        BytesPerLineIn: 0, BytesPerLineOut: 0,
        BytesPerPlaneIn: Size &* pixelSize(box.inputFormat),
        BytesPerPlaneOut: Size &* pixelSize(box.outputFormat)
    )
    xform(p, InputBuffer, OutputBuffer, Size, 1, &stride)
}

/// The older planar entry: one stride serves both sides.
@c @implementation
public func cmsDoTransformStride(
    _ Transform: cmsHTRANSFORM?,
    _ InputBuffer: UnsafeRawPointer?,
    _ OutputBuffer: UnsafeMutableRawPointer?,
    _ Size: cmsUInt32Number,
    _ Stride: cmsUInt32Number
) {
    guard let Transform, let box = transform(Transform), let xform = box.xform else { return }
    let p = Transform.assumingMemoryBound(to: _cmstransform_struct.self)
    var stride = cmsStride(
        BytesPerLineIn: 0, BytesPerLineOut: 0,
        BytesPerPlaneIn: Stride, BytesPerPlaneOut: Stride
    )
    xform(p, InputBuffer, OutputBuffer, Size, 1, &stride)
}

@c @implementation
public func cmsDoTransformLineStride(
    _ Transform: cmsHTRANSFORM?,
    _ InputBuffer: UnsafeRawPointer?,
    _ OutputBuffer: UnsafeMutableRawPointer?,
    _ PixelsPerLine: cmsUInt32Number,
    _ LineCount: cmsUInt32Number,
    _ BytesPerLineIn: cmsUInt32Number,
    _ BytesPerLineOut: cmsUInt32Number,
    _ BytesPerPlaneIn: cmsUInt32Number,
    _ BytesPerPlaneOut: cmsUInt32Number
) {
    guard let Transform, let box = transform(Transform), let xform = box.xform else { return }
    let p = Transform.assumingMemoryBound(to: _cmstransform_struct.self)
    var stride = cmsStride(
        BytesPerLineIn: BytesPerLineIn, BytesPerLineOut: BytesPerLineOut,
        BytesPerPlaneIn: BytesPerPlaneIn, BytesPerPlaneOut: BytesPerPlaneOut
    )
    xform(p, InputBuffer, OutputBuffer, PixelsPerLine, LineCount, &stride)
}

// -- the loops -----------------------------------------------------------------

// Each is a C function of the transform struct, so that it can be handed
// out as the worker and so that the transform can hold it as a plain
// pointer alongside one a plugin supplied.  Each recovers the box from
// the struct, copies the extra channels if asked, then walks the lines.
// The per-pixel buffers live on the stack: this is the hot path.

@inline(__always)
private func pipelineBox(_ p: UnsafeMutablePointer<cmsPipeline>?) -> PipelineBox? {
    guard let p else { return nil }
    return Unmanaged<PipelineBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

/// One pixel through the gamut check, then through the pipeline or to
/// the alarm codes.
@inline(__always)
private func transformOnePixelWithGamutCheck(
    _ box: TransformBox, _ lut: PipelineBox, _ gamut: PipelineBox,
    _ wIn: UnsafePointer<cmsUInt16Number>, _ wOut: UnsafeMutablePointer<cmsUInt16Number>
) {
    var outOfGamut: cmsUInt16Number = 0
    evaluate16(gamut, wIn, &outOfGamut)
    if outOfGamut >= 1 {
        let alarm = Context.resolve(box.context).chunks.alarmCodes
        for i in 0..<lut.outputChannels {
            wOut[i] = alarm[i]
        }
    } else {
        evaluate16(lut, wIn, wOut)
    }
}

/// Runs `body` over every pixel of every line, with the buffers advanced
/// by the formatters within a line and by the line strides between.
@inline(__always)
private func eachLine(
    _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number,
    _ stride: UnsafePointer<cmsStride>,
    _ body: (inout UnsafeMutablePointer<cmsUInt8Number>?, inout UnsafeMutablePointer<cmsUInt8Number>?) -> Void
) {
    var strideIn = 0
    var strideOut = 0
    let inputBytes = input.map { UnsafeMutablePointer(mutating: $0.assumingMemoryBound(to: cmsUInt8Number.self)) }
    let outputBytes = output?.assumingMemoryBound(to: cmsUInt8Number.self)
    for _ in 0..<Int(lineCount) {
        var accum = inputBytes.map { $0 + strideIn }
        var out = outputBytes.map { $0 + strideOut }
        for _ in 0..<Int(pixelsPerLine) {
            body(&accum, &out)
        }
        strideIn += Int(stride.pointee.BytesPerLineIn)
        strideOut += Int(stride.pointee.BytesPerLineOut)
    }
}

@inline(__always)
private func prologue(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) -> TransformBox? {
    guard let box = transform(p), let stride else { return nil }
    if let input, let output {
        handleExtraChannels(box, input, output, Int(pixelsPerLine), Int(lineCount), stride.pointee)
    }
    return box
}

/// Two zeroed word buffers of the channel maximum, on the stack.
@inline(__always)
private func withWordBuffers(
    _ body: (UnsafeMutablePointer<cmsUInt16Number>, UnsafeMutablePointer<cmsUInt16Number>) -> Void
) {
    withUnsafeTemporaryAllocation(of: cmsUInt16Number.self, capacity: 2 * maximumChannels) { storage in
        let a = storage.baseAddress!
        a.initialize(repeating: 0, count: 2 * maximumChannels)
        body(a, a + maximumChannels)
    }
}

@inline(__always)
private func withFloatBuffers(
    _ body: (UnsafeMutablePointer<cmsFloat32Number>, UnsafeMutablePointer<cmsFloat32Number>) -> Void
) {
    withUnsafeTemporaryAllocation(of: cmsFloat32Number.self, capacity: 2 * maximumChannels) { storage in
        let a = storage.baseAddress!
        a.initialize(repeating: 0, count: 2 * maximumChannels)
        body(a, a + maximumChannels)
    }
}

/// Floating point, with the gamut check folded in: out of gamut is
/// signalled by a value above zero, and the alarm codes go out scaled
/// to 0..1.
private func floatXFORM(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInputFloat, let toOutput = box.toOutputFloat, let lut = pipelineBox(box.lut)
    else { return }
    let gamut = pipelineBox(box.gamutCheck)
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withFloatBuffers { fIn, fOut in
        eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
            accum = fromInput(p, fIn, accum, planeIn)
            if let gamut {
                var outOfGamut: cmsFloat32Number = 0
                evaluateFloat(gamut, fIn, &outOfGamut)
                if outOfGamut > 0.0 {
                    let alarm = Context.resolve(box.context).chunks.alarmCodes
                    for c in 0..<maximumChannels {
                        fOut[c] = cmsFloat32Number(alarm[c]) / 65535.0
                    }
                } else {
                    evaluateFloat(lut, fIn, fOut)
                }
            } else {
                evaluateFloat(lut, fIn, fOut)
            }
            out = toOutput(p, fOut, out, planeOut)
        }
    }
}

/// Floating point, formatters only.
private func nullFloatXFORM(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInputFloat, let toOutput = box.toOutputFloat
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withFloatBuffers { fIn, _ in
        eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
            accum = fromInput(p, fIn, accum, planeIn)
            out = toOutput(p, fIn, out, planeOut)
        }
    }
}

/// 16 bits, formatters only.
private func nullXFORM(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInput, let toOutput = box.toOutput
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withWordBuffers { wIn, _ in
        eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
            accum = fromInput(p, wIn, accum, planeIn)
            out = toOutput(p, wIn, out, planeOut)
        }
    }
}

/// 16 bits, no cache, no gamut check.
private func precalculatedXFORM(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInput, let toOutput = box.toOutput, let lut = pipelineBox(box.lut)
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withWordBuffers { wIn, wOut in
        eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
            accum = fromInput(p, wIn, accum, planeIn)
            evaluate16(lut, wIn, wOut)
            out = toOutput(p, wOut, out, planeOut)
        }
    }
}

/// 16 bits, gamut check, no cache.
private func precalculatedXFORMGamutCheck(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInput, let toOutput = box.toOutput,
          let lut = pipelineBox(box.lut), let gamut = pipelineBox(box.gamutCheck)
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withWordBuffers { wIn, wOut in
        eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
            accum = fromInput(p, wIn, accum, planeIn)
            transformOnePixelWithGamutCheck(box, lut, gamut, wIn, wOut)
            out = toOutput(p, wOut, out, planeOut)
        }
    }
}

/// The one-pixel cache as two stack buffers seeded from the transform.
@inline(__always)
private func withCache(
    _ box: TransformBox,
    _ body: (UnsafeMutablePointer<cmsUInt16Number>, UnsafeMutablePointer<cmsUInt16Number>) -> Void
) {
    withUnsafeTemporaryAllocation(of: cmsUInt16Number.self, capacity: 2 * maximumChannels) { storage in
        let cacheIn = storage.baseAddress!
        let cacheOut = cacheIn + maximumChannels
        box.cacheIn.withUnsafeBufferPointer { cacheIn.initialize(from: $0.baseAddress!, count: maximumChannels) }
        box.cacheOut.withUnsafeBufferPointer { cacheOut.initialize(from: $0.baseAddress!, count: maximumChannels) }
        body(cacheIn, cacheOut)
    }
}

@inline(__always)
private func sameWords(_ a: UnsafePointer<cmsUInt16Number>, _ b: UnsafePointer<cmsUInt16Number>) -> Bool {
    memcmp(a, b, maximumChannels * 2) == 0
}

@inline(__always)
private func copyWords(_ to: UnsafeMutablePointer<cmsUInt16Number>, _ from: UnsafePointer<cmsUInt16Number>) {
    to.update(from: from, count: maximumChannels)
}

/// 16 bits with the one-pixel cache: a pixel equal to the last is
/// answered from memory.  The cache starts from the transform's seed
/// and lives on this call's stack, so concurrent calls do not share it.
private func cachedXFORM(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInput, let toOutput = box.toOutput, let lut = pipelineBox(box.lut)
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withWordBuffers { wIn, wOut in
        withCache(box) { cacheIn, cacheOut in
            eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
                accum = fromInput(p, wIn, accum, planeIn)
                if sameWords(wIn, cacheIn) {
                    copyWords(wOut, cacheOut)
                } else {
                    evaluate16(lut, wIn, wOut)
                    copyWords(cacheIn, wIn)
                    copyWords(cacheOut, wOut)
                }
                out = toOutput(p, wOut, out, planeOut)
            }
        }
    }
}

/// 16 bits, cache and gamut check.
private func cachedXFORMGamutCheck(
    _ p: TransformHandle?, _ input: UnsafeRawPointer?, _ output: UnsafeMutableRawPointer?,
    _ pixelsPerLine: cmsUInt32Number, _ lineCount: cmsUInt32Number, _ stride: UnsafePointer<cmsStride>?
) {
    guard let box = prologue(p, input, output, pixelsPerLine, lineCount, stride), let stride,
          let fromInput = box.fromInput, let toOutput = box.toOutput,
          let lut = pipelineBox(box.lut), let gamut = pipelineBox(box.gamutCheck)
    else { return }
    let planeIn = stride.pointee.BytesPerPlaneIn
    let planeOut = stride.pointee.BytesPerPlaneOut

    withWordBuffers { wIn, wOut in
        withCache(box) { cacheIn, cacheOut in
            eachLine(input, output, pixelsPerLine, lineCount, stride) { accum, out in
                accum = fromInput(p, wIn, accum, planeIn)
                if sameWords(wIn, cacheIn) {
                    copyWords(wOut, cacheOut)
                } else {
                    transformOnePixelWithGamutCheck(box, lut, gamut, wIn, wOut)
                    copyWords(cacheIn, wIn)
                    copyWords(cacheOut, wOut)
                }
                out = toOutput(p, wOut, out, planeOut)
            }
        }
    }
}

/// The formatters a transform holds when it was created with no
/// layouts, to be given some later: they consume and produce nothing.
private func unrollNothing(
    _ info: TransformHandle?, _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? { accum }

private func packNothing(
    _ info: TransformHandle?, _ wOut: UnsafeMutablePointer<cmsUInt16Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? { output }

// -- the plugin accessors ------------------------------------------------------

@c @implementation
public func _cmsSetTransformUserData(
    _ CMMcargo: TransformHandle?, _ ptr: UnsafeMutableRawPointer?, _ FreePrivateDataFn: _cmsFreeUserDataFn?
) {
    guard let box = transform(CMMcargo) else { return }
    box.userData = ptr
    box.freeUserData = FreePrivateDataFn
}

@c @implementation
public func _cmsGetTransformUserData(_ CMMcargo: TransformHandle?) -> UnsafeMutableRawPointer? {
    transform(CMMcargo)?.userData
}

@c @implementation
public func _cmsGetTransformFormatters16(
    _ CMMcargo: TransformHandle?,
    _ FromInput: UnsafeMutablePointer<cmsFormatter16?>?, _ ToOutput: UnsafeMutablePointer<cmsFormatter16?>?
) {
    guard let box = transform(CMMcargo) else { return }
    FromInput?.pointee = box.fromInput
    ToOutput?.pointee = box.toOutput
}

@c @implementation
public func _cmsGetTransformFormattersFloat(
    _ CMMcargo: TransformHandle?,
    _ FromInput: UnsafeMutablePointer<cmsFormatterFloat?>?, _ ToOutput: UnsafeMutablePointer<cmsFormatterFloat?>?
) {
    guard let box = transform(CMMcargo) else { return }
    FromInput?.pointee = box.fromInputFloat
    ToOutput?.pointee = box.toOutputFloat
}

@c @implementation
public func _cmsGetTransformFlags(_ CMMcargo: TransformHandle?) -> cmsUInt32Number {
    transform(CMMcargo)?.originalFlags ?? 0
}

@c @implementation
public func _cmsGetTransformWorker(_ CMMcargo: TransformHandle?) -> _cmsTransform2Fn? {
    transform(CMMcargo)?.worker
}

@c @implementation
public func _cmsGetTransformMaxWorkers(_ CMMcargo: TransformHandle?) -> cmsInt32Number {
    transform(CMMcargo)?.maxWorkers ?? 0
}

@c @implementation
public func _cmsGetTransformWorkerFlags(_ CMMcargo: TransformHandle?) -> cmsUInt32Number {
    transform(CMMcargo)?.workerFlags ?? 0
}

// -- creation ------------------------------------------------------------------

@inline(__always)
private func isFloat(_ format: cmsUInt32Number) -> Bool { PixelFormat(format).floatingPoint }

/// `AllocEmptyTransform`: the box, the pipeline handed over, the
/// formatters, and the loop — decided by whether either layout is
/// floating point and by the flags.  Optimization happens here, between
/// taking the pipeline and choosing the loop.  Nil, and the pipeline
/// freed, on a layout no formatter serves.
private func allocateEmptyTransform(
    _ ContextID: cmsContext?, _ lut: UnsafeMutablePointer<cmsPipeline>?,
    _ intent: cmsUInt32Number,
    _ inputFormat: inout cmsUInt32Number, _ outputFormat: inout cmsUInt32Number,
    _ dwFlags: inout cmsUInt32Number
) -> TransformBox? {
    let box = TransformBox(context: ContextID, inputFormat: inputFormat, outputFormat: outputFormat)
    box.lut = lut

    if box.lut != nil {
        // A transform plugin is offered the pipeline first — unless the
        // caller asked for no optimization — and the newest to accept
        // takes over the whole loop.  Then the optimizer.
        if dwFlags & cmsUInt32Number(cmsFLAGS_NOOPTIMIZE) == 0 {
            for entry in PluginRegistry.resolve(ContextID).transforms {
                var xform: _cmsTransform2Fn? = nil
                var userData: UnsafeMutableRawPointer? = nil
                var freeUserData: _cmsFreeUserDataFn? = nil
                if entry.factory(&xform, &userData, &freeUserData, &box.lut, &inputFormat, &outputFormat, &dwFlags) != 0 {
                    // The plugin owns the loop; the original parameters
                    // are kept as a record.  cmsFLAGS_CAN_CHANGE_FORMATTER
                    // is not set, so the transform is not reformattable
                    // unless the plugin changed the flags to say so.  The
                    // formatters are filled in for its convenience; a
                    // missing one is its problem, not an error here.
                    box.xform = xform
                    box.userData = userData
                    box.freeUserData = freeUserData
                    box.inputFormat = inputFormat
                    box.outputFormat = outputFormat
                    box.originalFlags = dwFlags
                    box.fromInput = _cmsGetFormatter(ContextID, inputFormat, cmsFormatterInput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16
                    box.toOutput = _cmsGetFormatter(ContextID, outputFormat, cmsFormatterOutput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16
                    box.fromInputFloat = _cmsGetFormatter(ContextID, inputFormat, cmsFormatterInput, cmsUInt32Number(CMS_PACK_FLAGS_FLOAT)).FmtFloat
                    box.toOutputFloat = _cmsGetFormatter(ContextID, outputFormat, cmsFormatterOutput, cmsUInt32Number(CMS_PACK_FLAGS_FLOAT)).FmtFloat
                    if entry.legacy {
                        // A one-scanline function from before 2.8, called
                        // once per line by the adaptor.
                        box.oldXform = unsafeBitCast(xform, to: _cmsTransformFn?.self)
                        box.xform = transform2ToTransformAdaptor
                    }
                    parallelizeIfSuitable(box)
                    return box
                }
            }
        }
        _ = _cmsOptimizePipeline(ContextID, &box.lut, intent, &inputFormat, &outputFormat, &dwFlags)
    }

    func unsupported() -> TransformBox? {
        report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unsupported raster format", to: ContextID)
        if let lut = box.lut { cmsPipelineFree(lut) }
        return nil
    }

    if isFloat(inputFormat) || isFloat(outputFormat) {
        box.fromInputFloat = _cmsGetFormatter(ContextID, inputFormat, cmsFormatterInput, cmsUInt32Number(CMS_PACK_FLAGS_FLOAT)).FmtFloat
        box.toOutputFloat = _cmsGetFormatter(ContextID, outputFormat, cmsFormatterOutput, cmsUInt32Number(CMS_PACK_FLAGS_FLOAT)).FmtFloat
        dwFlags |= canChangeFormatter

        if box.fromInputFloat == nil || box.toOutputFloat == nil { return unsupported() }

        // Floating point never caches.
        // Spelled as if/else: a C function pointer cannot be formed from
        // a conditional expression.
        if dwFlags & cmsUInt32Number(cmsFLAGS_NULLTRANSFORM) != 0 {
            box.xform = nullFloatXFORM
        } else {
            box.xform = floatXFORM
        }
    } else {
        if inputFormat == 0 && outputFormat == 0 {
            // Layouts to be given later.
            box.fromInput = unrollNothing
            box.toOutput = packNothing
            dwFlags |= canChangeFormatter
        } else {
            box.fromInput = _cmsGetFormatter(ContextID, inputFormat, cmsFormatterInput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16
            box.toOutput = _cmsGetFormatter(ContextID, outputFormat, cmsFormatterOutput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16

            if box.fromInput == nil || box.toOutput == nil { return unsupported() }

            // A transform whose input is wider than a byte can be
            // reformatted later; an 8-bit one may have been optimized
            // around that width.
            let bytesPerPixelInput = PixelFormat(inputFormat).bytes
            if bytesPerPixelInput == 0 || bytesPerPixelInput >= 2 {
                dwFlags |= canChangeFormatter
            }
        }

        if dwFlags & cmsUInt32Number(cmsFLAGS_NULLTRANSFORM) != 0 {
            box.xform = nullXFORM
        } else if dwFlags & cmsUInt32Number(cmsFLAGS_NOCACHE) != 0 {
            if dwFlags & cmsUInt32Number(cmsFLAGS_GAMUTCHECK) != 0 {
                box.xform = precalculatedXFORMGamutCheck
            } else {
                box.xform = precalculatedXFORM
            }
        } else {
            if dwFlags & cmsUInt32Number(cmsFLAGS_GAMUTCHECK) != 0 {
                box.xform = cachedXFORMGamutCheck
            } else {
                box.xform = cachedXFORM
            }
        }
    }

    // Copying alpha needs the same number of extra channels each side.
    if dwFlags & cmsUInt32Number(cmsFLAGS_COPY_ALPHA) != 0 {
        if PixelFormat(inputFormat).extra != PixelFormat(outputFormat).extra {
            report(cmsUInt32Number(cmsERROR_NOT_SUITABLE), "Mismatched alpha channels", to: ContextID)
            if let lut = box.lut { cmsPipelineFree(lut) }
            return nil
        }
    }

    box.inputFormat = inputFormat
    box.outputFormat = outputFormat
    box.originalFlags = dwFlags
    parallelizeIfSuitable(box)
    return box
}

/// `ParalellizeIfSuitable`: a parallelization plugin's scheduler takes
/// the loop as its worker.
private func parallelizeIfSuitable(_ box: TransformBox) {
    if let parallel = PluginRegistry.resolve(box.context).parallelization {
        box.worker = box.xform
        box.xform = parallel.scheduler
        box.maxWorkers = parallel.maxWorkers
        box.workerFlags = parallel.workerFlags
    }
}

/// `_cmsTransform2toTransformAdaptor`: runs a one-scanline transform
/// function once per line, after copying the extra channels across.
private func transform2ToTransformAdaptor(
    _ CMMcargo: TransformHandle?,
    _ InputBuffer: UnsafeRawPointer?,
    _ OutputBuffer: UnsafeMutableRawPointer?,
    _ PixelsPerLine: cmsUInt32Number,
    _ LineCount: cmsUInt32Number,
    _ Stride: UnsafePointer<cmsStride>?
) {
    guard let box = transform(CMMcargo), let old = box.oldXform, let Stride, let InputBuffer, let OutputBuffer else { return }
    handleExtraChannels(box, InputBuffer, OutputBuffer, Int(PixelsPerLine), Int(LineCount), Stride.pointee)

    var strideIn = 0
    var strideOut = 0
    for _ in 0..<Int(LineCount) {
        old(CMMcargo, InputBuffer.advanced(by: strideIn), OutputBuffer.advanced(by: strideOut), PixelsPerLine, Stride.pointee.BytesPerPlaneIn)
        strideIn += Int(Stride.pointee.BytesPerLineIn)
        strideOut += Int(Stride.pointee.BytesPerLineOut)
    }
}

/// The colour spaces at the two ends of a chain, following each profile
/// in the direction the chain uses it — a named colour profile takes a
/// one-channel index in.
private func transformColorSpaces(
    _ hProfiles: [cmsHPROFILE?]
) -> (input: cmsColorSpaceSignature, output: cmsColorSpaceSignature)? {
    guard let first = hProfiles.first, first != nil else { return nil }
    var input = cmsGetColorSpace(first)
    var post = input

    for (i, hProfile) in hProfiles.enumerated() {
        guard hProfile != nil else { return nil }
        let isInput = post != cmsSigXYZData && post != cmsSigLabData
        let cls = cmsGetDeviceClass(hProfile)

        let colorSpaceIn: cmsColorSpaceSignature
        let colorSpaceOut: cmsColorSpaceSignature
        if cls == cmsSigNamedColorClass {
            colorSpaceIn = cmsSig1colorData
            colorSpaceOut = hProfiles.count > 1 ? cmsGetPCS(hProfile) : cmsGetColorSpace(hProfile)
        } else if isInput || cls == cmsSigLinkClass {
            colorSpaceIn = cmsGetColorSpace(hProfile)
            colorSpaceOut = cmsGetPCS(hProfile)
        } else {
            colorSpaceIn = cmsGetPCS(hProfile)
            colorSpaceOut = cmsGetColorSpace(hProfile)
        }
        if i == 0 { input = colorSpaceIn }
        post = colorSpaceOut
    }
    return (input, post)
}

/// Whether a layout's colour space agrees with the profile's.  A zero
/// layout is accepted (linkicc's bypass); PT_ANY is accepted on channel
/// count alone; and the two Lab encodings stand for each other.
private func isProperColorSpace(_ check: cmsColorSpaceSignature, _ format: cmsUInt32Number) -> Bool {
    let space1 = Int32(PixelFormat(format).colorSpace)
    let space2 = _cmsLCMScolorSpace(check)

    if format == 0 { return true }
    if space1 == PT_ANY { return PixelFormat(format).channels == Int(cmsChannelsOf(check)) }
    if space1 == space2 { return true }
    if space1 == PT_LabV2 && space2 == PT_Lab { return true }
    if space1 == PT_Lab && space2 == PT_LabV2 { return true }
    return false
}

/// Some old profiles carry a media white a hundred times too big.
private func normalizedWhitePoint(_ tag: UnsafeMutableRawPointer?) -> cmsCIEXYZ {
    guard let tag else { return cmsCIEXYZ(X: cmsD50X, Y: cmsD50Y, Z: cmsD50Z) }
    var w = tag.assumingMemoryBound(to: cmsCIEXYZ.self).pointee
    while w.X > 2.0 && w.Y > 2.0 && w.Z > 2.0 {
        w.X /= 10.0
        w.Y /= 10.0
        w.Z /= 10.0
    }
    return w
}

@c @implementation
public func cmsCreateExtendedTransform(
    _ ContextID: cmsContext?,
    _ nProfiles: cmsUInt32Number,
    _ hProfiles: UnsafeMutablePointer<cmsHPROFILE?>?,
    _ BPC: UnsafeMutablePointer<cmsBool>?,
    _ Intents: UnsafeMutablePointer<cmsUInt32Number>?,
    _ AdaptationStates: UnsafeMutablePointer<cmsFloat64Number>?,
    _ hGamutProfile: cmsHPROFILE?,
    _ nGamutPCSposition: cmsUInt32Number,
    _ InputFormat: cmsUInt32Number,
    _ OutputFormat: cmsUInt32Number,
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    if nProfiles <= 0 || nProfiles > 255 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Wrong number of profiles. 1..255 expected, \(nProfiles) found.", to: ContextID
        )
        return nil
    }
    guard let hProfiles, let BPC, let Intents, let AdaptationStates else { return nil }
    let n = Int(nProfiles)
    let profiles = Array(UnsafeBufferPointer(start: hProfiles, count: n))
    let intents = Array(UnsafeBufferPointer(start: Intents, count: n))
    var bpc = UnsafeBufferPointer(start: BPC, count: n).map { $0 != 0 }
    let adaptationStates = Array(UnsafeBufferPointer(start: AdaptationStates, count: n))

    var inputFormat = InputFormat
    var outputFormat = OutputFormat
    var dwFlags = dwFlags
    let lastIntent = intents[n - 1]

    // A transform that only reformats.
    if dwFlags & cmsUInt32Number(cmsFLAGS_NULLTRANSFORM) != 0 {
        guard let box = allocateEmptyTransform(
            ContextID, nil, cmsUInt32Number(INTENT_PERCEPTUAL), &inputFormat, &outputFormat, &dwFlags
        ) else { return nil }
        return UnsafeMutableRawPointer(allocateHandle(box))
    }

    if dwFlags & cmsUInt32Number(cmsFLAGS_GAMUTCHECK) != 0 && hGamutProfile == nil {
        dwFlags &= ~cmsUInt32Number(cmsFLAGS_GAMUTCHECK)
    }
    if dwFlags & cmsUInt32Number(cmsFLAGS_GAMUTCHECK) != 0
        && (nGamutPCSposition <= 0 || nGamutPCSposition >= nProfiles - 1)
    {
        report(cmsUInt32Number(cmsERROR_RANGE), "Wrong gamut PCS position '\(nGamutPCSposition)'", to: ContextID)
        return nil
    }

    // Floating point never caches.
    if isFloat(inputFormat) || isFloat(outputFormat) {
        dwFlags |= cmsUInt32Number(cmsFLAGS_NOCACHE)
    }

    guard let (entryColorSpace, exitColorSpace) = transformColorSpaces(profiles) else {
        report(cmsUInt32Number(cmsERROR_NULL), "NULL input profiles on transform", to: ContextID)
        return nil
    }
    if !isProperColorSpace(entryColorSpace, inputFormat) {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Wrong input color space on transform", to: ContextID)
        return nil
    }
    if !isProperColorSpace(exitColorSpace, outputFormat) {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Wrong output color space on transform", to: ContextID)
        return nil
    }

    // A 16-bit transform out of a near-linear RGB profile is not
    // optimized: the prelinearisation the optimizer would build loses
    // too much in the shadows there.
    if entryColorSpace == cmsSigRgbData && PixelFormat(inputFormat).bytes == 2
        && dwFlags & cmsUInt32Number(cmsFLAGS_NOOPTIMIZE) == 0
    {
        let gamma = cmsDetectRGBProfileGamma(profiles[0], 0.1)
        if gamma > 0 && gamma < 1.6 {
            dwFlags |= cmsUInt32Number(cmsFLAGS_NOOPTIMIZE)
        }
    }

    guard let lut = linkProfiles(ContextID, intents, profiles, &bpc, adaptationStates, dwFlags) else {
        report(cmsUInt32Number(cmsERROR_NOT_SUITABLE), "Couldn't link the profiles", to: ContextID)
        return nil
    }

    if cmsChannelsOfColorSpace(entryColorSpace) != cmsInt32Number(cmsPipelineInputChannels(lut))
        || cmsChannelsOfColorSpace(exitColorSpace) != cmsInt32Number(cmsPipelineOutputChannels(lut))
    {
        cmsPipelineFree(lut)
        report(cmsUInt32Number(cmsERROR_NOT_SUITABLE), "Channel count doesn't match. Profile is corrupted", to: ContextID)
        return nil
    }

    guard let box = allocateEmptyTransform(ContextID, lut, lastIntent, &inputFormat, &outputFormat, &dwFlags)
    else { return nil }

    box.entryColorSpace = entryColorSpace
    box.exitColorSpace = exitColorSpace
    box.renderingIntent = intents[n - 1]

    box.entryWhitePoint = normalizedWhitePoint(cmsReadTag(profiles[0], cmsSigMediaWhitePointTag))
    box.exitWhitePoint = normalizedWhitePoint(cmsReadTag(profiles[n - 1], cmsSigMediaWhitePointTag))

    if let hGamutProfile, dwFlags & cmsUInt32Number(cmsFLAGS_GAMUTCHECK) != 0 {
        box.gamutCheck = _cmsCreateGamutCheckPipeline(
            ContextID, profiles, bpc, intents, adaptationStates, Int(nGamutPCSposition), hGamutProfile
        )
    }

    // Colorant tables: the input's from its own tag; the output's from
    // the devicelink's out-table when it is one, else its own tag.
    if cmsIsTag(profiles[0], cmsSigColorantTableTag) != 0 {
        box.inputColorant = cmsDupNamedColorList(
            cmsReadTag(profiles[0], cmsSigColorantTableTag)?.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
        )
    }
    let last = profiles[n - 1]
    if cmsGetDeviceClass(last) == cmsSigLinkClass {
        if cmsIsTag(last, cmsSigColorantTableOutTag) != 0 {
            box.outputColorant = cmsDupNamedColorList(
                cmsReadTag(last, cmsSigColorantTableOutTag)?.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
            )
        }
    } else if cmsIsTag(last, cmsSigColorantTableTag) != 0 {
        box.outputColorant = cmsDupNamedColorList(
            cmsReadTag(last, cmsSigColorantTableTag)?.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
        )
    }

    if dwFlags & cmsUInt32Number(cmsFLAGS_KEEP_SEQUENCE) != 0 {
        box.sequence = _cmsCompileProfileSequence(ContextID, profiles)
    }

    // The cache seed: what zero maps to.
    if dwFlags & cmsUInt32Number(cmsFLAGS_NOCACHE) == 0, let lut = pipelineBox(box.lut) {
        for i in 0..<maximumChannels { box.cacheIn[i] = 0 }
        var seed = [cmsUInt16Number](repeating: 0, count: maximumChannels)
        if let gamut = pipelineBox(box.gamutCheck) {
            transformOnePixelWithGamutCheck(box, lut, gamut, box.cacheIn, &seed)
        } else {
            evaluate16(lut, box.cacheIn, &seed)
        }
        box.cacheOut = seed
    }

    return UnsafeMutableRawPointer(allocateHandle(box))
}

@c @implementation
public func cmsCreateMultiprofileTransformTHR(
    _ ContextID: cmsContext?,
    _ hProfiles: UnsafeMutablePointer<cmsHPROFILE?>?,
    _ nProfiles: cmsUInt32Number,
    _ InputFormat: cmsUInt32Number,
    _ OutputFormat: cmsUInt32Number,
    _ Intent: cmsUInt32Number,
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    if nProfiles <= 0 || nProfiles > 255 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Wrong number of profiles. 1..255 expected, \(nProfiles) found.", to: ContextID
        )
        return nil
    }
    let n = Int(nProfiles)
    var bpc = [cmsBool](repeating: dwFlags & cmsUInt32Number(cmsFLAGS_BLACKPOINTCOMPENSATION) != 0 ? 1 : 0, count: n)
    var intents = [cmsUInt32Number](repeating: Intent, count: n)
    var adaptationStates = [cmsFloat64Number](repeating: cmsSetAdaptationStateTHR(ContextID, -1), count: n)

    return cmsCreateExtendedTransform(
        ContextID, nProfiles, hProfiles, &bpc, &intents, &adaptationStates,
        nil, 0, InputFormat, OutputFormat, dwFlags
    )
}

@c @implementation
public func cmsCreateMultiprofileTransform(
    _ hProfiles: UnsafeMutablePointer<cmsHPROFILE?>?,
    _ nProfiles: cmsUInt32Number,
    _ InputFormat: cmsUInt32Number,
    _ OutputFormat: cmsUInt32Number,
    _ Intent: cmsUInt32Number,
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    if nProfiles <= 0 || nProfiles > 255 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Wrong number of profiles. 1..255 expected, \(nProfiles) found.", to: nil
        )
        return nil
    }
    return cmsCreateMultiprofileTransformTHR(
        cmsGetProfileContextID(hProfiles?[0]), hProfiles, nProfiles,
        InputFormat, OutputFormat, Intent, dwFlags
    )
}

@c @implementation
public func cmsCreateTransformTHR(
    _ ContextID: cmsContext?,
    _ Input: cmsHPROFILE?, _ InputFormat: cmsUInt32Number,
    _ Output: cmsHPROFILE?, _ OutputFormat: cmsUInt32Number,
    _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    var array: [cmsHPROFILE?] = [Input, Output]
    return cmsCreateMultiprofileTransformTHR(
        ContextID, &array, Output == nil ? 1 : 2, InputFormat, OutputFormat, Intent, dwFlags
    )
}

@c @implementation
public func cmsCreateTransform(
    _ Input: cmsHPROFILE?, _ InputFormat: cmsUInt32Number,
    _ Output: cmsHPROFILE?, _ OutputFormat: cmsUInt32Number,
    _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    cmsCreateTransformTHR(
        cmsGetProfileContextID(Input), Input, InputFormat, Output, OutputFormat, Intent, dwFlags
    )
}

/// Proofing: input to the proofing profile and back, then to the
/// output — four profiles, with the return through the proof in
/// relative colorimetric.  Without soft-proofing or gamut checking asked
/// for, it is a plain transform.
@c @implementation
public func cmsCreateProofingTransformTHR(
    _ ContextID: cmsContext?,
    _ InputProfile: cmsHPROFILE?, _ InputFormat: cmsUInt32Number,
    _ OutputProfile: cmsHPROFILE?, _ OutputFormat: cmsUInt32Number,
    _ ProofingProfile: cmsHPROFILE?,
    _ nIntent: cmsUInt32Number, _ ProofingIntent: cmsUInt32Number,
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    let doBPC: cmsBool = dwFlags & cmsUInt32Number(cmsFLAGS_BLACKPOINTCOMPENSATION) != 0 ? 1 : 0
    var array: [cmsHPROFILE?] = [InputProfile, ProofingProfile, ProofingProfile, OutputProfile]
    var intents: [cmsUInt32Number] = [nIntent, nIntent, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), ProofingIntent]
    var bpc: [cmsBool] = [doBPC, doBPC, 0, 0]
    var adaptation = [cmsFloat64Number](repeating: cmsSetAdaptationStateTHR(ContextID, -1), count: 4)

    if dwFlags & cmsUInt32Number(cmsFLAGS_SOFTPROOFING | cmsFLAGS_GAMUTCHECK) == 0 {
        return cmsCreateTransformTHR(
            ContextID, InputProfile, InputFormat, OutputProfile, OutputFormat, nIntent, dwFlags
        )
    }
    return cmsCreateExtendedTransform(
        ContextID, 4, &array, &bpc, &intents, &adaptation,
        ProofingProfile, 1, InputFormat, OutputFormat, dwFlags
    )
}

@c @implementation
public func cmsCreateProofingTransform(
    _ InputProfile: cmsHPROFILE?, _ InputFormat: cmsUInt32Number,
    _ OutputProfile: cmsHPROFILE?, _ OutputFormat: cmsUInt32Number,
    _ ProofingProfile: cmsHPROFILE?,
    _ nIntent: cmsUInt32Number, _ ProofingIntent: cmsUInt32Number,
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    cmsCreateProofingTransformTHR(
        cmsGetProfileContextID(InputProfile),
        InputProfile, InputFormat, OutputProfile, OutputFormat, ProofingProfile,
        nIntent, ProofingIntent, dwFlags
    )
}

// -- inspection ----------------------------------------------------------------

@c @implementation
public func cmsGetTransformContextID(_ hTransform: cmsHTRANSFORM?) -> cmsContext? {
    transform(hTransform)?.context
}

@c @implementation
public func cmsGetTransformInputFormat(_ hTransform: cmsHTRANSFORM?) -> cmsUInt32Number {
    transform(hTransform)?.inputFormat ?? 0
}

@c @implementation
public func cmsGetTransformOutputFormat(_ hTransform: cmsHTRANSFORM?) -> cmsUInt32Number {
    transform(hTransform)?.outputFormat ?? 0
}

/// The transform's pipeline — the transform's, not the caller's to free.
@c @implementation
public func cmsGetTransformPipeline(_ hTransform: cmsHTRANSFORM?) -> UnsafeMutablePointer<cmsPipeline>? {
    transform(hTransform)?.lut
}

@c @implementation
public func cmsGetTransformGamutCheckPipeline(_ hTransform: cmsHTRANSFORM?) -> UnsafeMutablePointer<cmsPipeline>? {
    transform(hTransform)?.gamutCheck
}

/// Swaps the layouts of a transform that allows it — one built at 16
/// bits or wider, or one built with no layouts to be given them now.
@c @implementation
public func cmsChangeBuffersFormat(
    _ hTransform: cmsHTRANSFORM?, _ InputFormat: cmsUInt32Number, _ OutputFormat: cmsUInt32Number
) -> cmsBool {
    guard let hTransform, let box = transform(hTransform) else { return 0 }

    if box.originalFlags & canChangeFormatter == 0 {
        report(
            cmsUInt32Number(cmsERROR_NOT_SUITABLE),
            "cmsChangeBuffersFormat works only on transforms created originally with at least 16 bits of precision",
            to: box.context
        )
        return 0
    }

    let fromInput = _cmsGetFormatter(box.context, InputFormat, cmsFormatterInput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16
    let toOutput = _cmsGetFormatter(box.context, OutputFormat, cmsFormatterOutput, cmsUInt32Number(CMS_PACK_FLAGS_16BITS)).Fmt16
    guard let fromInput, let toOutput else {
        report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unsupported raster format", to: box.context)
        return 0
    }

    box.inputFormat = InputFormat
    box.outputFormat = OutputFormat
    box.fromInput = fromInput
    box.toOutput = toOutput
    let p = hTransform.assumingMemoryBound(to: _cmstransform_struct.self)
    p.pointee.InputFormat = InputFormat
    p.pointee.OutputFormat = OutputFormat
    return 1
}

@c @implementation
public func cmsGetTransformInputColorants(_ hTransform: cmsHTRANSFORM?) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST>? {
    transform(hTransform)?.inputColorant
}

@c @implementation
public func cmsGetTransformOutputColorants(_ hTransform: cmsHTRANSFORM?) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST>? {
    transform(hTransform)?.outputColorant
}

/// The named colour list a transform starts with, when its first stage
/// is the named colour lookup.
@c @implementation
public func cmsGetNamedColorList(_ xform: cmsHTRANSFORM?) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST>? {
    guard let box = transform(xform), let lut = box.lut,
          let first = cmsPipelineGetPtrToFirstStage(lut),
          cmsStageType(first) == cmsSigNamedColorElemType
    else { return nil }
    return cmsStageData(first)?.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
}
