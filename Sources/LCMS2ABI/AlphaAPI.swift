import CLCMS2
import LittleCMSCore

// Carrying the extra channels across a transform.
//
// A transform converts colour channels and ignores the rest.  With
// cmsFLAGS_COPY_ALPHA the rest — the extra channels, alpha typically —
// are copied from the input to the output instead of left as they were,
// converted between widths when the two layouts differ.  Where each
// extra channel sits in a pixel follows from the layout's channel order
// and swaps, worked out here once per call.

@inline(__always)
private func quickSaturateByte(_ d: Double) -> UInt8 {
    let d = d + 0.5
    if d <= 0 { return 0 }
    if d >= 255.0 { return 255 }
    return UInt8(truncatingIfNeeded: quickFloorWord(d))
}

@inline(__always)
private func changeEndian(_ w: UInt16) -> UInt16 { (w << 8) | (w >> 8) }

@inline(__always)
private func from16to8(_ n: UInt16) -> UInt8 {
    UInt8(truncatingIfNeeded: (UInt32(n) &* 65281 &+ 8_388_608) >> 24)
}

/// The width a channel is stored at, where the layout's byte field says
/// zero for eight.
@inline(__always)
private func trueBytesSize(_ format: cmsUInt32Number) -> Int {
    let bytes = PixelFormat(format).bytes
    return bytes == 0 ? 8 : bytes
}

/// One value copied between two widths.  The six widths are the ones a
/// pixel format can name; each pair has its own conversion, and each is
/// spelled the way the reference spells it — the same saturation, the
/// same rounding, the same float-versus-double intermediate.
private typealias AlphaCopy = (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void

private enum Width: Int {
    case byte = 0, word, wordSwapped, half, float, double

    init?(_ format: cmsUInt32Number) {
        let f = PixelFormat(format)
        switch (f.bytes, f.floatingPoint) {
        case (0, true): self = .double
        case (2, true): self = .half
        case (4, true): self = .float
        case (2, false): self = f.endianSwapped ? .wordSwapped : .word
        case (1, false): self = .byte
        default: return nil
        }
    }
}

private func load8(_ s: UnsafeRawPointer) -> UInt8 { s.load(as: UInt8.self) }
private func load16(_ s: UnsafeRawPointer) -> UInt16 { s.loadUnaligned(as: UInt16.self) }
private func loadF(_ s: UnsafeRawPointer) -> Float { s.loadUnaligned(as: Float.self) }
private func loadD(_ s: UnsafeRawPointer) -> Double { s.loadUnaligned(as: Double.self) }
private func loadH(_ s: UnsafeRawPointer) -> Float { _cmsHalf2Float(load16(s)) }

private func store8(_ d: UnsafeMutableRawPointer, _ v: UInt8) { d.storeBytes(of: v, as: UInt8.self) }
private func store16(_ d: UnsafeMutableRawPointer, _ v: UInt16) { d.storeBytes(of: v, as: UInt16.self) }
private func storeF(_ d: UnsafeMutableRawPointer, _ v: Float) { d.storeBytes(of: v, as: Float.self) }
private func storeD(_ d: UnsafeMutableRawPointer, _ v: Double) { d.storeBytes(of: v, as: Double.self) }
private func storeH(_ d: UnsafeMutableRawPointer, _ v: Float) { store16(d, _cmsFloat2Half(v)) }

/// `FormattersAlpha[from][to]`.
private func alphaCopy(from: Width, to: Width) -> AlphaCopy {
    switch (from, to) {
    // from 8
    case (.byte, .byte): return { d, s in store8(d, load8(s)) }
    case (.byte, .word): return { d, s in store16(d, fromByte(load8(s))) }
    case (.byte, .wordSwapped): return { d, s in store16(d, changeEndian(fromByte(load8(s)))) }
    case (.byte, .half): return { d, s in storeH(d, Float(load8(s)) / 255.0) }
    case (.byte, .float): return { d, s in storeF(d, Float(load8(s)) / 255.0) }
    case (.byte, .double): return { d, s in storeD(d, Double(load8(s)) / 255.0) }
    // from 16
    case (.word, .byte): return { d, s in store8(d, from16to8(load16(s))) }
    case (.word, .word): return { d, s in store16(d, load16(s)) }
    case (.word, .wordSwapped): return { d, s in store16(d, changeEndian(load16(s))) }
    case (.word, .half): return { d, s in storeH(d, Float(load16(s)) / 65535.0) }
    case (.word, .float): return { d, s in storeF(d, Float(load16(s)) / 65535.0) }
    case (.word, .double): return { d, s in storeD(d, Double(load16(s)) / 65535.0) }
    // from 16 swapped
    case (.wordSwapped, .byte): return { d, s in store8(d, from16to8(changeEndian(load16(s)))) }
    case (.wordSwapped, .word): return { d, s in store16(d, changeEndian(load16(s))) }
    case (.wordSwapped, .wordSwapped): return { d, s in store16(d, load16(s)) }
    case (.wordSwapped, .half): return { d, s in storeH(d, Float(changeEndian(load16(s))) / 65535.0) }
    case (.wordSwapped, .float): return { d, s in storeF(d, Float(changeEndian(load16(s))) / 65535.0) }
    case (.wordSwapped, .double): return { d, s in storeD(d, Double(changeEndian(load16(s))) / 65535.0) }
    // from half
    case (.half, .byte): return { d, s in store8(d, quickSaturateByte(Double(loadH(s)) * 255.0)) }
    case (.half, .word): return { d, s in store16(d, quickSaturateWord(Double(loadH(s)) * 65535.0)) }
    case (.half, .wordSwapped): return { d, s in store16(d, changeEndian(quickSaturateWord(Double(loadH(s)) * 65535.0))) }
    case (.half, .half): return { d, s in store16(d, load16(s)) }
    case (.half, .float): return { d, s in storeF(d, loadH(s)) }
    case (.half, .double): return { d, s in storeD(d, Double(loadH(s))) }
    // from float
    case (.float, .byte): return { d, s in store8(d, quickSaturateByte(Double(loadF(s)) * 255.0)) }
    case (.float, .word): return { d, s in store16(d, quickSaturateWord(Double(loadF(s)) * 65535.0)) }
    case (.float, .wordSwapped): return { d, s in store16(d, changeEndian(quickSaturateWord(Double(loadF(s)) * 65535.0))) }
    case (.float, .half): return { d, s in storeH(d, loadF(s)) }
    case (.float, .float): return { d, s in storeF(d, loadF(s)) }
    case (.float, .double): return { d, s in storeD(d, Double(loadF(s))) }
    // from double
    case (.double, .byte): return { d, s in store8(d, quickSaturateByte(loadD(s) * 255.0)) }
    case (.double, .word): return { d, s in store16(d, quickSaturateWord(loadD(s) * 65535.0)) }
    case (.double, .wordSwapped): return { d, s in store16(d, changeEndian(quickSaturateWord(loadD(s) * 65535.0))) }
    case (.double, .half): return { d, s in storeH(d, Float(loadD(s))) }
    case (.double, .float): return { d, s in storeF(d, Float(loadD(s))) }
    case (.double, .double): return { d, s in storeD(d, loadD(s)) }
    }
}

@inline(__always)
private func fromByte(_ v: UInt8) -> UInt16 { UInt16(v) << 8 | UInt16(v) }

/// Where each extra channel starts within a pixel and how far it is to
/// the same channel of the next pixel: for chunky layouts the pixel
/// size, for planar ones the channel size with the planes a stride
/// apart.  Nil for a layout with no channels or too many.
private func componentIncrements(
    _ format: cmsUInt32Number, bytesPerPlane: cmsUInt32Number
) -> (starts: [Int], increments: [Int])? {
    let f = PixelFormat(format)
    let extra = f.extra
    let nchannels = f.channels
    let total = nchannels + extra
    let channelSize = trueBytesSize(format)
    if total <= 0 || total >= maximumChannels { return nil }

    var channels = [Int](repeating: 0, count: maximumChannels)
    for i in 0..<total {
        channels[i] = f.swapped ? total - i - 1 : i
    }
    // Swap-first rotates the positions: CMYK → KCMY is 0123 → 3012.
    if f.swapFirst && total > (f.planar ? 0 : 1) {
        let tmp = channels[0]
        for i in 0..<(total - 1) { channels[i] = channels[i + 1] }
        channels[total - 1] = tmp
    }

    let increments: [Int]
    if f.planar {
        for i in 0..<total { channels[i] *= Int(bytesPerPlane) }
        increments = [Int](repeating: channelSize, count: extra)
    } else {
        if channelSize > 1 {
            for i in 0..<total { channels[i] *= channelSize }
        }
        increments = [Int](repeating: channelSize * total, count: extra)
    }
    return (Array(channels[nchannels..<(nchannels + extra)]), increments)
}

/// Copies the extra channels from input to output when the transform's
/// flags ask for it, in the widths each side stores them at.
func handleExtraChannels(
    _ transform: TransformBox,
    _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer,
    _ pixelsPerLine: Int, _ lineCount: Int,
    _ stride: cmsStride
) {
    if transform.originalFlags & cmsUInt32Number(cmsFLAGS_COPY_ALPHA) == 0 { return }
    // In place with one layout: the channels are already where they go.
    if transform.inputFormat == transform.outputFormat && UnsafeRawPointer(output) == input { return }

    let nExtra = PixelFormat(transform.inputFormat).extra
    if nExtra != PixelFormat(transform.outputFormat).extra { return }
    if nExtra == 0 { return }

    guard let source = componentIncrements(transform.inputFormat, bytesPerPlane: stride.BytesPerPlaneIn),
          let destination = componentIncrements(transform.outputFormat, bytesPerPlane: stride.BytesPerPlaneOut)
    else { return }

    guard let from = Width(transform.inputFormat), let to = Width(transform.outputFormat) else {
        report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unrecognized alpha channel width", to: transform.context)
        return
    }
    let copy = alphaCopy(from: from, to: to)

    var sourceLine = 0
    var destinationLine = 0
    for _ in 0..<lineCount {
        for k in 0..<nExtra {
            var s = input + source.starts[k] + sourceLine
            var d = output + destination.starts[k] + destinationLine
            for _ in 0..<pixelsPerLine {
                copy(d, s)
                s += source.increments[k]
                d += destination.increments[k]
            }
        }
        sourceLine += Int(stride.BytesPerLineIn)
        destinationLine += Int(stride.BytesPerLineOut)
    }
}
