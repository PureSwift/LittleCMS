import CLCMS2
import LittleCMS

// Choosing a formatter for a pixel layout.
//
// A formatter is picked by walking an ordered table and taking the first
// entry whose type matches the layout once the entry's mask is taken
// out: `(format & ~mask) == type`.  The mask says which fields the entry
// does not care about, so an entry can stand for a whole family — "any
// colour space, any number of extra channels" — while an earlier, more
// specific entry still wins for the layouts it names.
//
// **First match wins, so order is behaviour.** The table is therefore
// built as a *prefix* of the reference's: entries appear in the
// reference's order, and the ones not yet ported are simply absent from
// the end.  That is safe in a way that omitting from the middle is not.
// A layout that would have matched an entry we have still matches it,
// because everything before it is present and did not match; a layout
// whose entry is missing matches nothing and is reported unsupported,
// rather than falling through to a looser entry that would answer
// wrongly.  Growing the table can only ever turn "unsupported" into
// "supported", never change an answer already given.

// -- assembling a format word ----------------------------------------------

// The header's `*_SH` macros, which are how every entry in the table is
// spelled.  Verified against the generated `TYPE_*` constants in the
// tests: if a shift here were wrong, the reconstruction of a named type
// would not equal the constant the compiler computed.

@inline(__always) func bytesSH(_ v: UInt32) -> UInt32 { v }
@inline(__always) func channelsSH(_ v: UInt32) -> UInt32 { v << 3 }
@inline(__always) func extraSH(_ v: UInt32) -> UInt32 { v << 7 }
@inline(__always) func doSwapSH(_ v: UInt32) -> UInt32 { v << 10 }
@inline(__always) func endian16SH(_ v: UInt32) -> UInt32 { v << 11 }
@inline(__always) func planarSH(_ v: UInt32) -> UInt32 { v << 12 }
@inline(__always) func flavorSH(_ v: UInt32) -> UInt32 { v << 13 }
@inline(__always) func swapFirstSH(_ v: UInt32) -> UInt32 { v << 14 }
@inline(__always) func colorSpaceSH(_ v: UInt32) -> UInt32 { v << 16 }
@inline(__always) func floatSH(_ v: UInt32) -> UInt32 { v << 22 }
@inline(__always) func premulSH(_ v: UInt32) -> UInt32 { v << 23 }

/// The "don't care" masks the table entries are written with.
enum Any_ {
    static let space = colorSpaceSH(31)
    static let channels = channelsSH(15)
    static let extra = extraSH(7)
    static let planar = planarSH(1)
    static let endian = endian16SH(1)
    static let swap = doSwapSH(1)
    static let swapFirst = swapFirstSH(1)
    static let flavor = flavorSH(1)
    static let premul = premulSH(1)
}

// -- the table ---------------------------------------------------------------

/// One row: the layout it stands for, the fields it ignores, and what to
/// do with a buffer in that layout.
struct FormatterEntry {
    let type: UInt32
    let mask: UInt32
    let unpack: cmsFormatter16?
    let pack: cmsFormatter16?

    init(_ type: UInt32, _ mask: UInt32, unpack: cmsFormatter16? = nil, pack: cmsFormatter16? = nil) {
        self.type = type
        self.mask = mask
        self.unpack = unpack
        self.pack = pack
    }

    @inline(__always)
    func matches(_ format: UInt32) -> Bool {
        (format & ~mask) == type
    }
}

/// `(dwInput & ~Mask) == Type`, over the table in order.
func selectFormatter(_ format: UInt32, from table: [FormatterEntry]) -> FormatterEntry? {
    for entry in table where entry.matches(format) { return entry }
    return nil
}

// -- the formatters ----------------------------------------------------------

// Each takes the transform, the working buffer of 16-bit channels, the
// client's buffer, and the plane stride, and returns the client's
// pointer advanced past one pixel.  The stride matters only to the
// planar formatters; the interleaved ones ignore it, and so does the
// transform pointer, which exists for the few that need to ask about
// alpha.  That pointer is opaque even to plugins -- the struct is
// forward-declared and never defined in either shipped header -- so it
// arrives as an OpaquePointer and the formatters that need it will go
// through the accessors the plugin API provides.
//
// Widening a byte replicates it rather than shifting: 0xFF becomes
// 0xFFFF, so white stays white.  Narrowing is the reference's rounding
// multiply, not a shift, so the two are inverses across the range.

@inline(__always) private func widen(_ v: UInt8) -> cmsUInt16Number {
    cmsUInt16Number(v) << 8 | cmsUInt16Number(v)
}

@inline(__always) private func narrow(_ v: cmsUInt16Number) -> UInt8 {
    UInt8(truncatingIfNeeded: (cmsUInt32Number(v) &* 65281 &+ 8_388_608) >> 24)
}

@inline(__always) private func reversed(_ v: UInt8) -> UInt8 { 0xFF &- v }

/// A grey pixel fills three channels, not one: the value goes on to be
/// treated as a lightness, and the two it is padded with are what the
/// rest of the pipeline expects to find.
@Sendable private func unroll1Byte(
    _ info: OpaquePointer?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, var accum else { return accum }
    let v = widen(accum.pointee)
    wIn[0] = v
    wIn[1] = v
    wIn[2] = v
    accum += 1
    return accum
}

@Sendable private func unroll1ByteReversed(
    _ info: OpaquePointer?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, var accum else { return accum }
    let v = widen(reversed(accum.pointee))
    wIn[0] = v
    wIn[1] = v
    wIn[2] = v
    accum += 1
    return accum
}

/// Builds an interleaved byte unpacker for a fixed channel order.
/// `order` maps buffer position to working-channel index, which is the
/// whole of what distinguishes RGB from BGR from ARGB.
private func byteUnpacker(
    _ order: [Int], skip: Int = 0, invert: Bool = false
) -> @Sendable (
    OpaquePointer?,
    UnsafeMutablePointer<cmsUInt16Number>?,
    UnsafeMutablePointer<cmsUInt8Number>?,
    cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    { _, wIn, accum, _ in
        guard let wIn, var accum else { return accum }
        accum += skip
        for slot in order {
            let raw = invert ? reversed(accum.pointee) : accum.pointee
            wIn[slot] = widen(raw)
            accum += 1
        }
        return accum
    }
}

private func bytePacker(
    _ order: [Int], skip: Int = 0, invert: Bool = false
) -> @Sendable (
    OpaquePointer?,
    UnsafeMutablePointer<cmsUInt16Number>?,
    UnsafeMutablePointer<cmsUInt8Number>?,
    cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    { _, wOut, output, _ in
        guard let wOut, var output else { return output }
        output += skip
        for slot in order {
            let value = narrow(wOut[slot])
            output.pointee = invert ? reversed(value) : value
            output += 1
        }
        return output
    }
}

/// The word formatters read and write in the host's byte order, not the
/// file's — a 16-bit buffer belongs to the client, and the byte-swapped
/// layouts are named separately for the cases where it does not.
private func wordUnpacker(
    _ order: [Int], skip: Int = 0
) -> @Sendable (
    OpaquePointer?,
    UnsafeMutablePointer<cmsUInt16Number>?,
    UnsafeMutablePointer<cmsUInt8Number>?,
    cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    { _, wIn, accum, _ in
        guard let wIn, var accum else { return accum }
        accum += skip * 2
        for slot in order {
            wIn[slot] = UnsafeRawPointer(accum).loadUnaligned(as: cmsUInt16Number.self)
            accum += 2
        }
        return accum
    }
}

private func wordPacker(
    _ order: [Int], skip: Int = 0
) -> @Sendable (
    OpaquePointer?,
    UnsafeMutablePointer<cmsUInt16Number>?,
    UnsafeMutablePointer<cmsUInt8Number>?,
    cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    { _, wOut, output, _ in
        guard let wOut, var output else { return output }
        output += skip * 2
        for slot in order {
            UnsafeMutableRawPointer(output).storeBytes(
                of: wOut[slot], as: cmsUInt16Number.self
            )
            output += 2
        }
        return output
    }
}

@Sendable private func unroll1Word(
    _ info: OpaquePointer?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, var accum else { return accum }
    let v = UnsafeRawPointer(accum).loadUnaligned(as: cmsUInt16Number.self)
    wIn[0] = v
    wIn[1] = v
    wIn[2] = v
    accum += 2
    return accum
}
