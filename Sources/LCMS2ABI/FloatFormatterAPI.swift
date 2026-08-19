import CLCMS2
import LittleCMS

// The floating-point formatters.
//
// A transform with a floating-point layout at either end works in
// float throughout, so these unpack any layout to floats in 0..1 and
// pack floats back to any layout.  Lab and XYZ have their own entries
// that speak the space's units — L* 0..100, XYZ up to the encodeable
// maximum — and everything else goes through one generic entry per
// width that reads the layout back from the transform.  Ink spaces are
// carried in percent, so a float CMYK layout holds 0..100.
//
// The generic entries are ports of the reference's, with the same
// float-versus-double intermediates: where it computes in double and
// narrows once, so does this, and where it multiplies floats it does
// too, because that is what decides the last bit.

private typealias FloatUnroll = @convention(c) (
    UnsafeMutablePointer<_cmstransform_struct>?, UnsafeMutablePointer<cmsFloat32Number>?,
    UnsafeMutablePointer<cmsUInt8Number>?, cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>?

/// One row of a float table.
struct FloatFormatterEntry {
    let type: UInt32
    let mask: UInt32
    let function: cmsFormatterFloat

    @inline(__always)
    func matches(_ format: UInt32) -> Bool {
        (format & ~mask) == type
    }
}

@inline(__always)
private func isInkSpace(_ format: cmsUInt32Number) -> Bool {
    switch Int32(PixelFormat(format).colorSpace) {
    case PT_CMY, PT_CMYK, PT_MCH5, PT_MCH6, PT_MCH7, PT_MCH8, PT_MCH9,
         PT_MCH10, PT_MCH11, PT_MCH12, PT_MCH13, PT_MCH14, PT_MCH15:
        return true
    default:
        return false
    }
}

/// The width a channel is stored at, where the byte field's zero
/// means eight.
@inline(__always)
private func pixelSize(_ format: cmsUInt32Number) -> Int {
    let bytes = PixelFormat(format).bytes
    return bytes == 0 ? 8 : bytes
}

@inline(__always)
private func fromByte(_ v: UInt8) -> UInt16 { UInt16(v) << 8 | UInt16(v) }

@inline(__always)
private func from16to8(_ n: UInt16) -> UInt8 {
    UInt8(truncatingIfNeeded: (UInt32(n) &* 65281 &+ 8_388_608) >> 24)
}

/// `FomLabV2ToLabV4`: × 257/256, saturating.
@inline(__always)
private func labV2ToV4(_ x: UInt16) -> UInt16 {
    let a = (Int(x) << 8 | Int(x)) >> 8
    return a > 0xFFFF ? 0xFFFF : UInt16(a)
}

/// `lab4toFloat`, spelled in single precision as the reference is.
@inline(__always)
private func lab4ToFloat(_ wIn: UnsafeMutablePointer<cmsFloat32Number>, _ lab4: (UInt16, UInt16, UInt16)) {
    let l = Float(lab4.0) / Float(655.35)
    let a = (Float(lab4.1) / Float(257.0)) - Float(128.0)
    let b = (Float(lab4.2) / Float(257.0)) - Float(128.0)
    wIn[0] = l / Float(100.0)
    wIn[1] = (a + Float(128.0)) / Float(255.0)
    wIn[2] = (b + Float(128.0)) / Float(255.0)
}

// -- unpacking -------------------------------------------------------------------

/// Lab or XYZ from three values in the space's units, in float or
/// double, chunky or planar.  `scale` maps a value into 0..1.
@inline(__always)
private func unrollThree<T: BinaryFloatingPoint>(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number,
    as type: T.Type,
    _ scale: (T, T, T) -> (Double, Double, Double)
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wIn, let accum else { return accum }
    let format = info.pointee.InputFormat
    let raw = UnsafeRawPointer(accum)
    @inline(__always) func at(_ i: Int) -> T {
        raw.loadUnaligned(fromByteOffset: i * MemoryLayout<T>.size, as: T.self)
    }
    if PixelFormat(format).planar {
        let s = Int(stride) / pixelSize(format)
        let (a, b, c) = scale(at(0), at(s), at(s * 2))
        wIn[0] = Float(a); wIn[1] = Float(b); wIn[2] = Float(c)
        return accum + MemoryLayout<T>.size
    }
    let (a, b, c) = scale(at(0), at(1), at(2))
    wIn[0] = Float(a); wIn[1] = Float(b); wIn[2] = Float(c)
    return accum + MemoryLayout<T>.size * (3 + PixelFormat(format).extra)
}

// The `+ 128` happens in the stored width — a float stays a float
// there — and the division promotes to double, as the reference's
// expression does.
@inline(__always)
private func labScale<T: BinaryFloatingPoint>(_ l: T, _ a: T, _ b: T) -> (Double, Double, Double) {
    (Double(l) / 100.0, Double(a + 128) / 255.0, Double(b + 128) / 255.0)
}

@inline(__always)
private func xyzScale<T: BinaryFloatingPoint>(_ x: T, _ y: T, _ z: T) -> (Double, Double, Double) {
    (Double(x) / maximumEncodeableXYZ, Double(y) / maximumEncodeableXYZ, Double(z) / maximumEncodeableXYZ)
}

@Sendable private func unrollLabDoubleToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollThree(info, wIn, accum, stride, as: Double.self, labScale)
}

@Sendable private func unrollLabFloatToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollThree(info, wIn, accum, stride, as: Float.self, labScale)
}

@Sendable private func unrollXYZDoubleToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollThree(info, wIn, accum, stride, as: Double.self, xyzScale)
}

@Sendable private func unrollXYZFloatToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollThree(info, wIn, accum, stride, as: Float.self, xyzScale)
}

/// The generic unpacker over any width: reads each colour channel out
/// of its position in the pixel — after the extra channels when those
/// come first, reversed when swapped — divides it into 0..1, undoes a
/// premultiplied alpha, and inverts for a reversed flavour.  `load`
/// gives the value at an index in the arithmetic the width uses.
@inline(__always)
private func unrollGeneric<V: BinaryFloatingPoint>(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number,
    width: Int, inkMaximum: V, premultiply: Bool,
    _ load: (UnsafeRawPointer, Int) -> V
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    let planar = format.planar
    let premul = premultiply && format.premultiplied
    let maximum: V = isInkSpace(info.pointee.InputFormat) ? inkMaximum : 1
    let raw = UnsafeRawPointer(accum)
    let stride = Int(stride) / pixelSize(info.pointee.InputFormat)

    var alphaFactor: V = 1
    if premul && extra > 0 {
        if planar {
            alphaFactor = (extraFirst ? load(raw, 0) : load(raw, nChan * stride)) / maximum
        } else {
            alphaFactor = (extraFirst ? load(raw, 0) : load(raw, nChan)) / maximum
        }
    }

    let start = extraFirst ? extra : 0
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = planar ? load(raw, (i + start) * stride) : load(raw, i + start)
        if premul && alphaFactor > 0 { v /= alphaFactor }
        v /= maximum
        wIn[index] = Float(reverse ? 1 - v : v)
    }

    if extra == 0 && swapFirst {
        let tmp = wIn[0]
        for i in 0..<(nChan - 1) { wIn[i] = wIn[i + 1] }
        wIn[nChan - 1] = tmp
    }

    return accum + (planar ? width : (nChan + extra) * width)
}

@Sendable private func unrollFloatsToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollGeneric(info, wIn, accum, stride, width: 4, inkMaximum: Float(100), premultiply: true) {
        $0.loadUnaligned(fromByteOffset: $1 * 4, as: Float.self)
    }
}

@Sendable private func unrollDoublesToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollGeneric(info, wIn, accum, stride, width: 8, inkMaximum: Double(100), premultiply: true) {
        $0.loadUnaligned(fromByteOffset: $1 * 8, as: Double.self)
    }
}

@Sendable private func unroll8ToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    // Bytes are always 0..255, ink or not, and never premultiplied here.
    unrollGeneric(info, wIn, accum, stride, width: 1, inkMaximum: Float(1), premultiply: false) {
        Float($0.load(fromByteOffset: $1, as: UInt8.self)) / Float(255.0)
    }
}

@Sendable private func unroll16ToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollGeneric(info, wIn, accum, stride, width: 2, inkMaximum: Float(1), premultiply: false) {
        Float($0.loadUnaligned(fromByteOffset: $1 * 2, as: UInt16.self)) / Float(65535.0)
    }
}

@Sendable private func unrollHalfToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    unrollGeneric(info, wIn, accum, stride, width: 2, inkMaximum: Float(100), premultiply: false) {
        _cmsHalf2Float($0.loadUnaligned(fromByteOffset: $1 * 2, as: UInt16.self))
    }
}

@Sendable private func unrollLabV2_8ToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    lab4ToFloat(wIn, (labV2ToV4(fromByte(accum[0])), labV2ToV4(fromByte(accum[1])), labV2ToV4(fromByte(accum[2]))))
    return accum + 3
}

@Sendable private func unrollALabV2_8ToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    lab4ToFloat(wIn, (labV2ToV4(fromByte(accum[1])), labV2ToV4(fromByte(accum[2])), labV2ToV4(fromByte(accum[3]))))
    return accum + 4
}

@Sendable private func unrollLabV2_16ToFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wIn: UnsafeMutablePointer<cmsFloat32Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    let raw = UnsafeRawPointer(accum)
    lab4ToFloat(wIn, (
        labV2ToV4(raw.loadUnaligned(fromByteOffset: 0, as: UInt16.self)),
        labV2ToV4(raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
        labV2ToV4(raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
    ))
    return accum + 6
}

// -- packing ---------------------------------------------------------------------

/// Lab or XYZ to three values in the space's units.
@inline(__always)
private func packThree<T: BinaryFloatingPoint>(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number,
    as type: T.Type,
    _ scale: (Float, Float, Float) -> (Double, Double, Double)
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wOut, let output else { return output }
    let format = info.pointee.OutputFormat
    let raw = UnsafeMutableRawPointer(output)
    let (a, b, c) = scale(wOut[0], wOut[1], wOut[2])
    @inline(__always) func put(_ i: Int, _ v: Double) {
        raw.storeBytes(of: T(v), toByteOffset: i * MemoryLayout<T>.size, as: T.self)
    }
    if PixelFormat(format).planar {
        let s = Int(stride) / pixelSize(format)
        put(0, a); put(s, b); put(s * 2, c)
        return output + MemoryLayout<T>.size
    }
    put(0, a); put(1, b); put(2, c)
    return output + MemoryLayout<T>.size * (3 + PixelFormat(format).extra)
}

@inline(__always)
private func labUnscale(_ l: Float, _ a: Float, _ b: Float) -> (Double, Double, Double) {
    (Double(l) * 100.0, Double(a) * 255.0 - 128.0, Double(b) * 255.0 - 128.0)
}

@inline(__always)
private func xyzUnscale(_ x: Float, _ y: Float, _ z: Float) -> (Double, Double, Double) {
    (Double(x) * maximumEncodeableXYZ, Double(y) * maximumEncodeableXYZ, Double(z) * maximumEncodeableXYZ)
}

@Sendable private func packLabFloatFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packThree(info, wOut, output, stride, as: Float.self, labUnscale)
}

@Sendable private func packXYZFloatFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packThree(info, wOut, output, stride, as: Float.self, xyzUnscale)
}

@Sendable private func packLabDoubleFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packThree(info, wOut, output, stride, as: Double.self, labUnscale)
}

@Sendable private func packXYZDoubleFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packThree(info, wOut, output, stride, as: Double.self, xyzUnscale)
}

/// The V2 Lab encodings, through the colorimetry encoders.
@inline(__always)
private func encodedLabV2(_ wOut: UnsafeMutablePointer<cmsFloat32Number>, v4: Bool) -> (UInt16, UInt16, UInt16) {
    var lab = cmsCIELab(
        L: Double(wOut[0] * 100.0),
        a: Double(wOut[1] * 255.0 - 128.0),
        b: Double(wOut[2] * 255.0 - 128.0)
    )
    var w: (UInt16, UInt16, UInt16) = (0, 0, 0)
    withUnsafeMutablePointer(to: &w) {
        $0.withMemoryRebound(to: cmsUInt16Number.self, capacity: 3) { p in
            if v4 { cmsFloat2LabEncoded(p, &lab) } else { cmsFloat2LabEncodedV2(p, &lab) }
        }
    }
    return w
}

@Sendable private func packEncodedBytesLabV2FromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wOut, let output else { return output }
    // The reference encodes with the V4 encoder here, and takes the
    // high byte of each word.
    let w = encodedLabV2(wOut, v4: true)
    let format = info.pointee.OutputFormat
    if PixelFormat(format).planar {
        let s = Int(stride) / pixelSize(format)
        output[0] = UInt8(w.0 >> 8); output[s] = UInt8(w.1 >> 8); output[s * 2] = UInt8(w.2 >> 8)
        return output + 1
    }
    output[0] = UInt8(w.0 >> 8); output[1] = UInt8(w.1 >> 8); output[2] = UInt8(w.2 >> 8)
    return output + 3 + PixelFormat(format).extra
}

@Sendable private func packEncodedWordsLabV2FromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wOut, let output else { return output }
    let w = encodedLabV2(wOut, v4: false)
    let format = info.pointee.OutputFormat
    let raw = UnsafeMutableRawPointer(output)
    if PixelFormat(format).planar {
        let s = Int(stride) / pixelSize(format)
        raw.storeBytes(of: w.0, toByteOffset: 0, as: UInt16.self)
        raw.storeBytes(of: w.1, toByteOffset: s * 2, as: UInt16.self)
        raw.storeBytes(of: w.2, toByteOffset: s * 4, as: UInt16.self)
        return output + 2
    }
    raw.storeBytes(of: w.0, toByteOffset: 0, as: UInt16.self)
    raw.storeBytes(of: w.1, toByteOffset: 2, as: UInt16.self)
    raw.storeBytes(of: w.2, toByteOffset: 4, as: UInt16.self)
    return output + (3 + PixelFormat(format).extra) * 2
}

/// The generic packer over any width: the mirror of the unpacker.  Each
/// colour channel is scaled and stored by `store` at its position in
/// the pixel; for a swap-first layout without extras the values are then
/// shifted up one and the front refilled with the last one stored, which
/// is the reference's way of rotating them and is kept for its exact
/// effect.  `store` is told whether the flavour is reversed and whether
/// the space is an ink space, and does the arithmetic its width calls for.
@inline(__always)
private func packGeneric(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number,
    width: Int,
    _ store: (UnsafeMutableRawPointer, Int, Float, Bool, Bool) -> Void
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let extra = format.extra
    let swapFirst = format.swapFirst
    let planar = format.planar
    let extraFirst = doSwap != swapFirst
    let ink = isInkSpace(info.pointee.OutputFormat)
    let raw = UnsafeMutableRawPointer(output)
    let stride = Int(stride) / pixelSize(info.pointee.OutputFormat)
    let start = extraFirst ? extra : 0

    var last: Float = 0
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        last = wOut[index]
        store(raw, planar ? (i + start) * stride : i + start, last, reverse, ink)
    }

    if extra == 0 && swapFirst {
        // Overlapping move, which copyMemory allows.
        (raw + width).copyMemory(from: raw, byteCount: (nChan - 1) * width)
        store(raw, 0, last, reverse, ink)
    }

    return output + (planar ? width : (nChan + extra) * width)
}

@Sendable private func packFloatsFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packGeneric(info, wOut, output, stride, width: 4) { raw, i, value, reverse, ink in
        let maximum = ink ? 100.0 : 1.0
        var v = Double(value) * maximum
        if reverse { v = maximum - v }
        raw.storeBytes(of: Float(v), toByteOffset: i * 4, as: Float.self)
    }
}

@Sendable private func packDoublesFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packGeneric(info, wOut, output, stride, width: 8) { raw, i, value, reverse, ink in
        let maximum = ink ? 100.0 : 1.0
        var v = Double(value) * maximum
        if reverse { v = maximum - v }
        raw.storeBytes(of: v, toByteOffset: i * 8, as: Double.self)
    }
}

@Sendable private func packWordsFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packGeneric(info, wOut, output, stride, width: 2) { raw, i, value, reverse, _ in
        var v = Double(value) * 65535.0
        if reverse { v = 65535.0 - v }
        raw.storeBytes(of: quickSaturateWord(v), toByteOffset: i * 2, as: UInt16.self)
    }
}

@Sendable private func packBytesFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packGeneric(info, wOut, output, stride, width: 1) { raw, i, value, reverse, _ in
        var v = Double(value) * 65535.0
        if reverse { v = 65535.0 - v }
        raw.storeBytes(of: from16to8(quickSaturateWord(v)), toByteOffset: i, as: UInt8.self)
    }
}

@Sendable private func packHalfFromFloat(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ wOut: UnsafeMutablePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    packGeneric(info, wOut, output, stride, width: 2) { raw, i, value, reverse, ink in
        // Single precision throughout, as the reference is here.
        let maximum: Float = ink ? 100.0 : 1.0
        var v = value * maximum
        if reverse { v = maximum - v }
        raw.storeBytes(of: _cmsFloat2Half(v), toByteOffset: i * 2, as: UInt16.self)
    }
}

// -- the tables ------------------------------------------------------------------

private let anyFloatLayout = Any_.planar | Any_.swapFirst | Any_.swap | Any_.extra | Any_.channels | Any_.space

/// The reference's input table, in its order.  The specific Lab and XYZ
/// entries come first, then the generic float and double ones, then the
/// V2 Lab encodings, then the generic integer widths, then half.
let inputFormattersFloat: [FloatFormatterEntry] = [
    FloatFormatterEntry(type: SLCMS_TYPE_Lab_DBL, mask: Any_.planar | Any_.extra, function: unrollLabDoubleToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_Lab_FLT, mask: Any_.planar | Any_.extra, function: unrollLabFloatToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_XYZ_DBL, mask: Any_.planar | Any_.extra, function: unrollXYZDoubleToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_XYZ_FLT, mask: Any_.planar | Any_.extra, function: unrollXYZFloatToFloat),
    FloatFormatterEntry(type: floatSH(1) | bytesSH(4), mask: anyFloatLayout | Any_.premul, function: unrollFloatsToFloat),
    FloatFormatterEntry(type: floatSH(1) | bytesSH(0), mask: anyFloatLayout | Any_.premul, function: unrollDoublesToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_LabV2_8, mask: 0, function: unrollLabV2_8ToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_ALabV2_8, mask: 0, function: unrollALabV2_8ToFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_LabV2_16, mask: 0, function: unrollLabV2_16ToFloat),
    FloatFormatterEntry(type: bytesSH(1), mask: anyFloatLayout, function: unroll8ToFloat),
    FloatFormatterEntry(type: bytesSH(2), mask: anyFloatLayout, function: unroll16ToFloat),
    FloatFormatterEntry(type: floatSH(1) | bytesSH(2), mask: anyFloatLayout, function: unrollHalfToFloat),
]

/// The reference's output table, in its order.
let outputFormattersFloat: [FloatFormatterEntry] = [
    FloatFormatterEntry(type: SLCMS_TYPE_Lab_FLT, mask: Any_.planar | Any_.extra, function: packLabFloatFromFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_XYZ_FLT, mask: Any_.planar | Any_.extra, function: packXYZFloatFromFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_Lab_DBL, mask: Any_.planar | Any_.extra, function: packLabDoubleFromFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_XYZ_DBL, mask: Any_.planar | Any_.extra, function: packXYZDoubleFromFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_LabV2_8, mask: Any_.planar | Any_.extra, function: packEncodedBytesLabV2FromFloat),
    FloatFormatterEntry(type: SLCMS_TYPE_LabV2_16, mask: Any_.planar | Any_.extra, function: packEncodedWordsLabV2FromFloat),
    FloatFormatterEntry(type: floatSH(1) | bytesSH(4), mask: anyFloatLayout | Any_.flavor, function: packFloatsFromFloat),
    FloatFormatterEntry(type: floatSH(1) | bytesSH(0), mask: anyFloatLayout | Any_.flavor, function: packDoublesFromFloat),
    FloatFormatterEntry(type: bytesSH(2), mask: anyFloatLayout | Any_.flavor, function: packWordsFromFloat),
    FloatFormatterEntry(type: bytesSH(1), mask: anyFloatLayout | Any_.flavor, function: packBytesFromFloat),
    // Half is not planar-capable in the reference's table.
    FloatFormatterEntry(
        type: floatSH(1) | bytesSH(2),
        mask: Any_.flavor | Any_.swapFirst | Any_.swap | Any_.extra | Any_.channels | Any_.space,
        function: packHalfFromFloat
    ),
]

/// The float half of _cmsGetFormatter.
func selectFloatFormatter(_ format: UInt32, _ direction: cmsFormatterDirection) -> cmsFormatterFloat? {
    let table = direction == cmsFormatterInput ? inputFormattersFloat : outputFormattersFloat
    return table.first { $0.matches(format) }?.function
}
