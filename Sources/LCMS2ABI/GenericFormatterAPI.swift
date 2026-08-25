import CLCMS2
import LittleCMSCore

// The rest of the 16-bit formatter tables: the generic entries that
// serve any layout of a given width by reading the layout back from the
// transform, the planar ones, the floating-point layouts converted to
// and from 16 bits, and the few remaining fixed shapes.
//
// Each is a port of the reference's function of the same name, and
// where the reference is odd — a stride divided by the wrong format's
// pixel size, a planar index in the wrong unit — the oddity is kept,
// because a client sees the effect and the point is to see the same
// one.

typealias Info = UnsafeMutablePointer<_cmstransform_struct>
typealias Words = UnsafeMutablePointer<cmsUInt16Number>
typealias Bytes = UnsafeMutablePointer<cmsUInt8Number>

@inline(__always) private func reverseFlavor(_ v: UInt16) -> UInt16 { 0xFFFF &- v }
@inline(__always) private func changeEndian(_ w: UInt16) -> UInt16 { (w << 8) | (w >> 8) }

/// `_cmsToFixedDomain`: 0..0xFFFF spread to 0..0x10000.
@inline(__always) private func toFixedDomain(_ a: UInt32) -> UInt32 { a &+ ((a &+ 0x7FFF) / 0xFFFF) }

@inline(__always) private func pixelSize(_ format: cmsUInt32Number) -> Int {
    let bytes = PixelFormat(format).bytes
    return bytes == 0 ? 8 : bytes
}

@inline(__always) private func isInkSpace(_ format: cmsUInt32Number) -> Bool {
    switch Int32(PixelFormat(format).colorSpace) {
    case PT_CMY, PT_CMYK, PT_MCH5, PT_MCH6, PT_MCH7, PT_MCH8, PT_MCH9,
         PT_MCH10, PT_MCH11, PT_MCH12, PT_MCH13, PT_MCH14, PT_MCH15:
        return true
    default:
        return false
    }
}

/// Divides an alpha out of a value already scaled to 16 bits, in the
/// fixed-point arithmetic the reference uses, saturating.
@inline(__always) private func unpremultiply(_ v: UInt32, _ alphaFactor: UInt32) -> UInt32 {
    if alphaFactor == 0 { return v }
    let q = (v << 16) / alphaFactor
    return q > 0xFFFF ? 0xFFFF : q
}

@inline(__always) private func premultiply(_ v: UInt16, _ alphaFactor: UInt32) -> UInt16 {
    UInt16(truncatingIfNeeded: (UInt32(v) &* alphaFactor &+ 0x8000) >> 16)
}

/// The rotation a swap-first layout without extras asks for on input:
/// the first channel to the end.
@inline(__always) private func rotateFirstToLast(_ w: Words, _ nChan: Int) {
    let tmp = w[0]
    for i in 0..<(nChan - 1) { w[i] = w[i + 1] }
    w[nChan - 1] = tmp
}

// -- floating-point layouts into 16 bits -------------------------------------------

@inline(__always)
private func labFrom<T: BinaryFloatingPoint>(
    _ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number, as type: T.Type
) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let raw = UnsafeRawPointer(accum)
    var lab: cmsCIELab
    if PixelFormat(info.pointee.InputFormat).planar {
        // The planar stride is taken in bytes here, undivided.
        lab = cmsCIELab(
            L: Double(raw.loadUnaligned(as: T.self)),
            a: Double(raw.loadUnaligned(fromByteOffset: Int(stride), as: T.self)),
            b: Double(raw.loadUnaligned(fromByteOffset: Int(stride) * 2, as: T.self))
        )
        cmsFloat2LabEncoded(wIn, &lab)
        return accum + MemoryLayout<T>.size
    }
    lab = cmsCIELab(
        L: Double(raw.loadUnaligned(as: T.self)),
        a: Double(raw.loadUnaligned(fromByteOffset: MemoryLayout<T>.size, as: T.self)),
        b: Double(raw.loadUnaligned(fromByteOffset: MemoryLayout<T>.size * 2, as: T.self))
    )
    cmsFloat2LabEncoded(wIn, &lab)
    return accum + MemoryLayout<T>.size * (3 + PixelFormat(info.pointee.InputFormat).extra)
}

@inline(__always)
private func xyzFrom<T: BinaryFloatingPoint>(
    _ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number, as type: T.Type
) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let raw = UnsafeRawPointer(accum)
    var xyz: cmsCIEXYZ
    if PixelFormat(info.pointee.InputFormat).planar {
        xyz = cmsCIEXYZ(
            X: Double(raw.loadUnaligned(as: T.self)),
            Y: Double(raw.loadUnaligned(fromByteOffset: Int(stride), as: T.self)),
            Z: Double(raw.loadUnaligned(fromByteOffset: Int(stride) * 2, as: T.self))
        )
        cmsFloat2XYZEncoded(wIn, &xyz)
        return accum + MemoryLayout<T>.size
    }
    xyz = cmsCIEXYZ(
        X: Double(raw.loadUnaligned(as: T.self)),
        Y: Double(raw.loadUnaligned(fromByteOffset: MemoryLayout<T>.size, as: T.self)),
        Z: Double(raw.loadUnaligned(fromByteOffset: MemoryLayout<T>.size * 2, as: T.self))
    )
    cmsFloat2XYZEncoded(wIn, &xyz)
    return accum + MemoryLayout<T>.size * (3 + PixelFormat(info.pointee.InputFormat).extra)
}

@Sendable func unrollLabDoubleTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    labFrom(info, wIn, accum, stride, as: Double.self)
}
@Sendable func unrollXYZDoubleTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    xyzFrom(info, wIn, accum, stride, as: Double.self)
}
@Sendable func unrollLabFloatTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    labFrom(info, wIn, accum, stride, as: Float.self)
}
@Sendable func unrollXYZFloatTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    xyzFrom(info, wIn, accum, stride, as: Float.self)
}

/// A single double, spread to three channels as grey is.
@Sendable func unrollDouble1Chan(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wIn, let accum else { return accum }
    let v = quickSaturateWord(UnsafeRawPointer(accum).loadUnaligned(as: Double.self) * 65535.0)
    wIn[0] = v; wIn[1] = v; wIn[2] = v
    return accum + 8
}

/// Any layout of doubles or floats to 16 bits.  The value is narrowed
/// to float first — the reference casts to cmsFloat32Number before
/// multiplying — and inks are in percent.
@inline(__always)
private func unrollRealTo16<T: BinaryFloatingPoint>(
    _ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number, as type: T.Type
) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    let planar = format.planar
    let maximum = isInkSpace(info.pointee.InputFormat) ? 655.35 : 65535.0
    let stride = Int(stride) / pixelSize(info.pointee.InputFormat)
    let raw = UnsafeRawPointer(accum)
    let start = extraFirst ? extra : 0

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        let offset = (planar ? (i + start) * stride : i + start) * MemoryLayout<T>.size
        let v = Double(Float(raw.loadUnaligned(fromByteOffset: offset, as: T.self)))
        var vi = quickSaturateWord(v * maximum)
        if reverse { vi = reverseFlavor(vi) }
        wIn[index] = vi
    }
    if extra == 0 && swapFirst { rotateFirstToLast(wIn, nChan) }
    return accum + (planar ? MemoryLayout<T>.size : (nChan + extra) * MemoryLayout<T>.size)
}

@Sendable func unrollDoubleTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    unrollRealTo16(info, wIn, accum, stride, as: Double.self)
}
@Sendable func unrollFloatTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    unrollRealTo16(info, wIn, accum, stride, as: Float.self)
}

/// Halves to 16 bits.  The stride is divided by the *output* format's
/// pixel size, as the reference has it.
@Sendable func unrollHalfTo16(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    let planar = format.planar
    let maximum: Float = isInkSpace(info.pointee.InputFormat) ? 655.35 : 65535.0
    let stride = Int(stride) / pixelSize(info.pointee.OutputFormat)
    let raw = UnsafeRawPointer(accum)
    let start = extraFirst ? extra : 0

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        let offset = (planar ? (i + start) * stride : i + start) * 2
        var v = _cmsHalf2Float(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        if reverse { v = maximum - v }
        wIn[index] = quickSaturateWord(Double(v) * Double(maximum))
    }
    if extra == 0 && swapFirst { rotateFirstToLast(wIn, nChan) }
    return accum + (planar ? 2 : (nChan + extra) * 2)
}

// -- the remaining fixed byte shapes -----------------------------------------------

@Sendable func unroll1ByteSkip1(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wIn, let accum else { return accum }
    let v = widen(accum[0])
    wIn[0] = v; wIn[1] = v; wIn[2] = v
    return accum + 2
}

@Sendable func unroll1ByteSkip2(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wIn, let accum else { return accum }
    let v = widen(accum[0])
    wIn[0] = v; wIn[1] = v; wIn[2] = v
    return accum + 3
}

/// Duplex: two bytes, two channels.
@Sendable func unroll2Bytes(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wIn, let accum else { return accum }
    wIn[0] = widen(accum[0])
    wIn[1] = widen(accum[1])
    return accum + 2
}

/// Planar bytes: one channel per plane, a stride apart, with an alpha
/// divided out when premultiplied.  Advances one byte.
@Sendable func unrollPlanarBytes(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let swapFirst = format.swapFirst
    let reverse = format.inverted
    let extraFirst = doSwap != swapFirst
    let extra = format.extra
    let premul = format.premultiplied
    let stride = Int(stride)
    var p = accum
    var alphaFactor: UInt32 = 1

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(widen(p[0]))) }
        p += extra * stride
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(widen(p[nChan * stride])))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = UInt32(widen(p[0]))
        if reverse { v = UInt32(reverseFlavor(UInt16(v))) }
        if premul && alphaFactor > 0 { v = unpremultiply(v, alphaFactor) }
        wIn[index] = UInt16(v)
        p += stride
    }
    return accum + 1
}

/// Chunky bytes of any layout.
@Sendable func unrollChunkyBytes(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extra = format.extra
    let premul = format.premultiplied
    let extraFirst = doSwap != swapFirst
    var p = accum
    var alphaFactor: UInt32 = 1

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(widen(p[0]))) }
        p += extra
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(widen(p[nChan])))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = UInt32(widen(p[0]))
        if reverse { v = UInt32(reverseFlavor(UInt16(v))) }
        if premul && alphaFactor > 0 { v = unpremultiply(v, alphaFactor) }
        wIn[index] = UInt16(v)
        p += 1
    }
    if !extraFirst { p += extra }
    if extra == 0 && swapFirst { rotateFirstToLast(wIn, nChan) }
    return p
}

// -- generic words -----------------------------------------------------------------

/// Planar words.  Only a swapped layout's extras are skipped, and
/// swap-first is not consulted — the reference's shape.
@Sendable func unrollPlanarWords(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapEndian = format.endianSwapped
    let stride = Int(stride)
    var p = UnsafeRawPointer(accum)

    if doSwap { p += format.extra * stride }
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = p.loadUnaligned(as: UInt16.self)
        if swapEndian { v = changeEndian(v) }
        wIn[index] = reverse ? reverseFlavor(v) : v
        p += stride
    }
    return accum + 2
}

@Sendable func unrollAnyWords(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let swapEndian = format.endianSwapped
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    var p = accum

    if extraFirst { p += extra * 2 }
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = UnsafeRawPointer(p).loadUnaligned(as: UInt16.self)
        if swapEndian { v = changeEndian(v) }
        wIn[index] = reverse ? reverseFlavor(v) : v
        p += 2
    }
    if !extraFirst { p += extra * 2 }
    if extra == 0 && swapFirst { rotateFirstToLast(wIn, nChan) }
    return p
}

/// Planar premultiplied words: the alpha is the first plane or the one
/// past the colour planes, and each colour is divided by it before the
/// flavour is applied.
@Sendable func unrollPlanarWordsPremul(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let swapFirst = format.swapFirst
    let reverse = format.inverted
    let swapEndian = format.endianSwapped
    let extraFirst = doSwap != swapFirst
    let stride = Int(stride)
    let words = UnsafeRawPointer(accum)
    var p = UnsafeRawPointer(accum)

    let alpha = extraFirst
        ? words.loadUnaligned(as: UInt16.self)
        : words.loadUnaligned(fromByteOffset: (nChan * stride / 2) * 2, as: UInt16.self)
    let alphaFactor = toFixedDomain(UInt32(alpha))

    if extraFirst { p += stride }
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = UInt32(p.loadUnaligned(as: UInt16.self))
        if swapEndian { v = UInt32(changeEndian(UInt16(v))) }
        if alphaFactor > 0 { v = unpremultiply(v, alphaFactor) }
        wIn[index] = reverse ? reverseFlavor(UInt16(v)) : UInt16(v)
        p += stride
    }
    return accum + 2
}

@Sendable func unrollAnyWordsPremul(_ info: Info?, _ wIn: Words?, _ accum: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wIn, let accum else { return accum }
    let format = PixelFormat(info.pointee.InputFormat)
    let nChan = format.channels
    let swapEndian = format.endianSwapped
    let doSwap = format.swapped
    let reverse = format.inverted
    let swapFirst = format.swapFirst
    let extraFirst = doSwap != swapFirst
    let words = UnsafeRawPointer(accum)
    var p = accum

    let alpha = extraFirst
        ? words.loadUnaligned(as: UInt16.self)
        : words.loadUnaligned(fromByteOffset: nChan * 2, as: UInt16.self)
    let alphaFactor = toFixedDomain(UInt32(alpha))

    if extraFirst { p += 2 }
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = UInt32(UnsafeRawPointer(p).loadUnaligned(as: UInt16.self))
        if swapEndian { v = UInt32(changeEndian(UInt16(v))) }
        if alphaFactor > 0 { v = unpremultiply(v, alphaFactor) }
        wIn[index] = reverse ? reverseFlavor(UInt16(v)) : UInt16(v)
        p += 2
    }
    if !extraFirst { p += 2 }
    return p
}

// -- 16 bits out to floating-point layouts -----------------------------------------

@Sendable func packLabDoubleFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    var lab = cmsCIELab()
    cmsLabEncoded2Float(&lab, wOut)
    let raw = UnsafeMutableRawPointer(output)
    if PixelFormat(info.pointee.OutputFormat).planar {
        // The stride is used undivided, as an index of doubles.
        let s = Int(stride)
        raw.storeBytes(of: lab.L, toByteOffset: 0, as: Double.self)
        raw.storeBytes(of: lab.a, toByteOffset: s * 8, as: Double.self)
        raw.storeBytes(of: lab.b, toByteOffset: s * 16, as: Double.self)
        return output + 8
    }
    raw.storeBytes(of: lab.L, toByteOffset: 0, as: Double.self)
    raw.storeBytes(of: lab.a, toByteOffset: 8, as: Double.self)
    raw.storeBytes(of: lab.b, toByteOffset: 16, as: Double.self)
    return output + 24 + PixelFormat(info.pointee.OutputFormat).extra * 8
}

@Sendable func packXYZDoubleFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    var xyz = cmsCIEXYZ()
    cmsXYZEncoded2Float(&xyz, wOut)
    let raw = UnsafeMutableRawPointer(output)
    if PixelFormat(info.pointee.OutputFormat).planar {
        let s = Int(stride) / pixelSize(info.pointee.OutputFormat)
        raw.storeBytes(of: xyz.X, toByteOffset: 0, as: Double.self)
        raw.storeBytes(of: xyz.Y, toByteOffset: s * 8, as: Double.self)
        raw.storeBytes(of: xyz.Z, toByteOffset: s * 16, as: Double.self)
        return output + 8
    }
    raw.storeBytes(of: xyz.X, toByteOffset: 0, as: Double.self)
    raw.storeBytes(of: xyz.Y, toByteOffset: 8, as: Double.self)
    raw.storeBytes(of: xyz.Z, toByteOffset: 16, as: Double.self)
    return output + 24 + PixelFormat(info.pointee.OutputFormat).extra * 8
}

@Sendable func packLabFloatFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    var lab = cmsCIELab()
    cmsLabEncoded2Float(&lab, wOut)
    let raw = UnsafeMutableRawPointer(output)
    if PixelFormat(info.pointee.OutputFormat).planar {
        let s = Int(stride) / pixelSize(info.pointee.OutputFormat)
        raw.storeBytes(of: Float(lab.L), toByteOffset: 0, as: Float.self)
        raw.storeBytes(of: Float(lab.a), toByteOffset: s * 4, as: Float.self)
        raw.storeBytes(of: Float(lab.b), toByteOffset: s * 8, as: Float.self)
        return output + 4
    }
    raw.storeBytes(of: Float(lab.L), toByteOffset: 0, as: Float.self)
    raw.storeBytes(of: Float(lab.a), toByteOffset: 4, as: Float.self)
    raw.storeBytes(of: Float(lab.b), toByteOffset: 8, as: Float.self)
    return output + (3 + PixelFormat(info.pointee.OutputFormat).extra) * 4
}

@Sendable func packXYZFloatFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    var xyz = cmsCIEXYZ()
    cmsXYZEncoded2Float(&xyz, wOut)
    let raw = UnsafeMutableRawPointer(output)
    if PixelFormat(info.pointee.OutputFormat).planar {
        let s = Int(stride) / pixelSize(info.pointee.OutputFormat)
        raw.storeBytes(of: Float(xyz.X), toByteOffset: 0, as: Float.self)
        raw.storeBytes(of: Float(xyz.Y), toByteOffset: s * 4, as: Float.self)
        raw.storeBytes(of: Float(xyz.Z), toByteOffset: s * 8, as: Float.self)
        return output + 4
    }
    raw.storeBytes(of: Float(xyz.X), toByteOffset: 0, as: Float.self)
    raw.storeBytes(of: Float(xyz.Y), toByteOffset: 4, as: Float.self)
    raw.storeBytes(of: Float(xyz.Z), toByteOffset: 8, as: Float.self)
    return output + 12 + PixelFormat(info.pointee.OutputFormat).extra * 4
}

/// 16 bits to any layout of a real width, with the last value refilled
/// at the front for a swap-first layout.  The reversed flavour here is
/// `maximum - v` on the already-divided value, which is what the
/// reference computes — a wrong answer it gives consistently.
@inline(__always)
private func packRealFrom16(
    _ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number,
    width: Int, _ store: (UnsafeMutableRawPointer, Int, Double) -> Void
) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let extra = format.extra
    let swapFirst = format.swapFirst
    let planar = format.planar
    let extraFirst = doSwap != swapFirst
    let maximum = isInkSpace(info.pointee.OutputFormat) ? 655.35 : 65535.0
    let stride = Int(stride) / pixelSize(info.pointee.OutputFormat)
    let raw = UnsafeMutableRawPointer(output)
    let start = extraFirst ? extra : 0

    var v = 0.0
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        v = Double(wOut[index]) / maximum
        if reverse { v = maximum - v }
        store(raw, planar ? (i + start) * stride : i + start, v)
    }
    if extra == 0 && swapFirst {
        (raw + width).copyMemory(from: raw, byteCount: (nChan - 1) * width)
        store(raw, 0, v)
    }
    return output + (planar ? width : (nChan + extra) * width)
}

@Sendable func packDoubleFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    packRealFrom16(info, wOut, output, stride, width: 8) { raw, i, v in
        raw.storeBytes(of: v, toByteOffset: i * 8, as: Double.self)
    }
}

@Sendable func packFloatFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    packRealFrom16(info, wOut, output, stride, width: 4) { raw, i, v in
        raw.storeBytes(of: Float(v), toByteOffset: i * 4, as: Float.self)
    }
}

/// Halves, in single precision throughout as the reference is.
@Sendable func packHalfFrom16(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let extra = format.extra
    let swapFirst = format.swapFirst
    let planar = format.planar
    let extraFirst = doSwap != swapFirst
    let maximum: Float = isInkSpace(info.pointee.OutputFormat) ? 655.35 : 65535.0
    let stride = Int(stride) / pixelSize(info.pointee.OutputFormat)
    let raw = UnsafeMutableRawPointer(output)
    let start = extraFirst ? extra : 0

    var v: Float = 0
    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        v = Float(wOut[index]) / maximum
        if reverse { v = maximum - v }
        let at = planar ? (i + start) * stride : i + start
        raw.storeBytes(of: _cmsFloat2Half(v), toByteOffset: at * 2, as: UInt16.self)
    }
    if extra == 0 && swapFirst {
        (raw + 2).copyMemory(from: raw, byteCount: (nChan - 1) * 2)
        raw.storeBytes(of: _cmsFloat2Half(v), as: UInt16.self)
    }
    return output + (planar ? 2 : (nChan + extra) * 2)
}

// -- the remaining fixed byte and word shapes --------------------------------------

@Sendable func pack1ByteSkip1(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[0] = narrow(wOut[0])
    return output + 2
}

@Sendable func pack1ByteSkip1SwapFirst(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[1] = narrow(wOut[0])
    return output + 2
}

// The "optimized" byte packers take the low byte outright: they serve a
// pipeline the optimizer built to leave its answer there.
@Sendable func pack3BytesOptimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[0] = UInt8(wOut[0] & 0xFF); output[1] = UInt8(wOut[1] & 0xFF); output[2] = UInt8(wOut[2] & 0xFF)
    return output + 3
}
@Sendable func pack3BytesAndSkip1Optimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[0] = UInt8(wOut[0] & 0xFF); output[1] = UInt8(wOut[1] & 0xFF); output[2] = UInt8(wOut[2] & 0xFF)
    return output + 4
}
@Sendable func pack3BytesAndSkip1SwapFirstOptimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[1] = UInt8(wOut[0] & 0xFF); output[2] = UInt8(wOut[1] & 0xFF); output[3] = UInt8(wOut[2] & 0xFF)
    return output + 4
}
@Sendable func pack3BytesAndSkip1SwapSwapFirstOptimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[0] = UInt8(wOut[2] & 0xFF); output[1] = UInt8(wOut[1] & 0xFF); output[2] = UInt8(wOut[0] & 0xFF)
    return output + 4
}
@Sendable func pack3BytesAndSkip1SwapOptimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[1] = UInt8(wOut[2] & 0xFF); output[2] = UInt8(wOut[1] & 0xFF); output[3] = UInt8(wOut[0] & 0xFF)
    return output + 4
}
@Sendable func pack3BytesSwapOptimized(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    output[0] = UInt8(wOut[2] & 0xFF); output[1] = UInt8(wOut[1] & 0xFF); output[2] = UInt8(wOut[0] & 0xFF)
    return output + 3
}

@Sendable func pack6Bytes(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<6 { output[i] = narrow(wOut[i]) }
    return output + 6
}
@Sendable func pack6BytesSwap(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<6 { output[i] = narrow(wOut[5 - i]) }
    return output + 6
}

/// Chunky bytes of any layout, multiplying an alpha already in the
/// buffer back in when premultiplied.
@Sendable func packChunkyBytes(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let reverse = format.inverted
    let extra = format.extra
    let swapFirst = format.swapFirst
    let premul = format.premultiplied
    let extraFirst = doSwap != swapFirst
    let swap1 = output
    var p = output
    var v: UInt16 = 0
    var alphaFactor: UInt32 = 0

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(widen(p[0]))) }
        p += extra
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(widen(p[nChan])))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        v = wOut[index]
        if reverse { v = reverseFlavor(v) }
        if premul { v = premultiply(v, alphaFactor) }
        p[0] = narrow(v)
        p += 1
    }
    if !extraFirst { p += extra }
    if extra == 0 && swapFirst {
        UnsafeMutableRawPointer(swap1 + 1).copyMemory(from: swap1, byteCount: nChan - 1)
        swap1[0] = narrow(v)
    }
    return p
}

@Sendable func packPlanarBytes(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let swapFirst = format.swapFirst
    let reverse = format.inverted
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    let premul = format.premultiplied
    let stride = Int(stride)
    var p = output
    var alphaFactor: UInt32 = 0

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(widen(p[0]))) }
        p += extra * stride
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(widen(p[nChan * stride])))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = wOut[index]
        if reverse { v = reverseFlavor(v) }
        if premul { v = premultiply(v, alphaFactor) }
        p[0] = narrow(v)
        p += stride
    }
    return output + 1
}

@inline(__always) private func putWord(_ output: Bytes, _ i: Int, _ v: UInt16) {
    UnsafeMutableRawPointer(output).storeBytes(of: v, toByteOffset: i * 2, as: UInt16.self)
}

@Sendable func pack1WordSkip1(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    putWord(output, 0, wOut[0])
    return output + 4
}
@Sendable func pack1WordSkip1SwapFirst(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    putWord(output, 1, wOut[0])
    return output + 4
}
@Sendable func pack1WordBigEndian(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    putWord(output, 0, changeEndian(wOut[0]))
    return output + 2
}
@Sendable func pack3WordsBigEndian(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<3 { putWord(output, i, changeEndian(wOut[i])) }
    return output + 6
}
@Sendable func pack3WordsAndSkip1(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<3 { putWord(output, i, wOut[i]) }
    return output + 8
}
@Sendable func pack3WordsAndSkip1SwapSwapFirst(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<3 { putWord(output, i, wOut[2 - i]) }
    return output + 8
}
@Sendable func pack4WordsBigEndian(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<4 { putWord(output, i, changeEndian(wOut[i])) }
    return output + 8
}
@Sendable func pack6Words(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<6 { putWord(output, i, wOut[i]) }
    return output + 12
}
@Sendable func pack6WordsSwap(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let wOut, let output else { return output }
    for i in 0..<6 { putWord(output, i, wOut[5 - i]) }
    return output + 12
}

@Sendable func packChunkyWords(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let swapEndian = format.endianSwapped
    let doSwap = format.swapped
    let reverse = format.inverted
    let extra = format.extra
    let swapFirst = format.swapFirst
    let premul = format.premultiplied
    let extraFirst = doSwap != swapFirst
    let swap1 = UnsafeMutableRawPointer(output)
    var p = output
    var v: UInt16 = 0
    var alphaFactor: UInt32 = 0

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(swap1.loadUnaligned(as: UInt16.self))) }
        p += extra * 2
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(swap1.loadUnaligned(fromByteOffset: nChan * 2, as: UInt16.self)))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        v = wOut[index]
        if swapEndian { v = changeEndian(v) }
        if reverse { v = reverseFlavor(v) }
        if premul { v = premultiply(v, alphaFactor) }
        putWord(p, 0, v)
        p += 2
    }
    if !extraFirst { p += extra * 2 }
    if extra == 0 && swapFirst {
        (swap1 + 2).copyMemory(from: swap1, byteCount: (nChan - 1) * 2)
        swap1.storeBytes(of: v, as: UInt16.self)
    }
    return p
}

/// Planar words.  The alpha for a premultiplied layout is read at word
/// index `nChan * stride`, with the stride in bytes — the reference's
/// index, kept as it is.
@Sendable func packPlanarWords(_ info: Info?, _ wOut: Words?, _ output: Bytes?, _ stride: cmsUInt32Number) -> Bytes? {
    guard let info, let wOut, let output else { return output }
    let format = PixelFormat(info.pointee.OutputFormat)
    let nChan = format.channels
    let doSwap = format.swapped
    let swapFirst = format.swapFirst
    let reverse = format.inverted
    let extra = format.extra
    let extraFirst = doSwap != swapFirst
    let premul = format.premultiplied
    let swapEndian = format.endianSwapped
    let stride = Int(stride)
    let words = UnsafeMutableRawPointer(output)
    var p = output
    var alphaFactor: UInt32 = 0

    if extraFirst {
        if premul && extra > 0 { alphaFactor = toFixedDomain(UInt32(words.loadUnaligned(as: UInt16.self))) }
        p += extra * stride
    } else if premul && extra > 0 {
        alphaFactor = toFixedDomain(UInt32(words.loadUnaligned(fromByteOffset: nChan * stride * 2, as: UInt16.self)))
    }

    for i in 0..<nChan {
        let index = doSwap ? nChan - i - 1 : i
        var v = wOut[index]
        if swapEndian { v = changeEndian(v) }
        if reverse { v = reverseFlavor(v) }
        if premul { v = premultiply(v, alphaFactor) }
        putWord(p, 0, v)
        p += stride
    }
    return output + 2
}
