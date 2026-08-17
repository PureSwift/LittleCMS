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

// -- the tables ----------------------------------------------------------------

// What is present, and why leaving the rest out is safe.
//
// The reference's table opens with eight float and double entries before
// the first integer one.  Those are not here yet, which is a gap in the
// middle rather than at the end — so the earlier claim that only a
// prefix is safe was too coarse.  The precise rule is:
//
//   omitting an entry is safe when no layout it would have caught
//   matches any later entry that *is* present.
//
// For the float entries that holds by construction.  Every one of them
// carries FLOAT_SH(1), and no integer entry masks the float bit away, so
// a float layout cannot fall through into an integer entry: it matches
// nothing and is reported unsupported.  Equally, an integer layout can
// never have matched a float entry in the first place.  The two halves
// of the table do not overlap, so they can be filled in independently.
//
// Within each half the ordering still matters and is the reference's.

// One function per channel ordering, written out rather than built.
//
// A C function pointer cannot capture, so the order cannot be passed to
// a shared builder -- it has to be in the function.  That is exactly why
// the reference has a separate function per ordering too, and why there
// are a hundred and twenty-four of them.

@Sendable private func unrollBytes3(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes3Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[2] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes3Skip1Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes3Skip1SwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes4(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    values[3] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes4Reverse(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = widen(reversed(p.pointee))
    p += 1
    values[1] = widen(reversed(p.pointee))
    p += 1
    values[2] = widen(reversed(p.pointee))
    p += 1
    values[3] = widen(reversed(p.pointee))
    p += 1
    return p
}

@Sendable private func unrollBytes4SwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[3] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes4Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[3] = widen(p.pointee)
    p += 1
    values[2] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollBytes4SwapSwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[2] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    values[3] = widen(p.pointee)
    p += 1
    return p
}

@Sendable private func unrollWords2(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords3(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords3Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords4(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[3] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords4Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[3] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords4SwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[3] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func unrollWords4SwapSwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[2] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[1] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[0] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    values[3] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packBytes1(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[0])
    p += 1
    return p
}

@Sendable private func packBytes3(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    return p
}

@Sendable private func packBytes3Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    return p
}

@Sendable private func packBytes4(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[3])
    p += 1
    return p
}

@Sendable private func packBytes4Reverse(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = reversed(narrow(values[0]))
    p += 1
    p.pointee = reversed(narrow(values[1]))
    p += 1
    p.pointee = reversed(narrow(values[2]))
    p += 1
    p.pointee = reversed(narrow(values[3]))
    p += 1
    return p
}

@Sendable private func packBytes4Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[3])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    return p
}

@Sendable private func packBytes4SwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[3])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    return p
}

@Sendable private func packBytes4SwapSwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[3])
    p += 1
    return p
}

@Sendable private func packWords1(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: values[0], as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packWords3(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: values[0], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[1], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[2], as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packWords3Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: values[2], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[1], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[0], as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packWords4(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: values[0], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[1], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[2], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[3], as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packWords4Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: values[3], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[2], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[1], as: cmsUInt16Number.self)
    p += 2
    UnsafeMutableRawPointer(p).storeBytes(of: values[0], as: cmsUInt16Number.self)
    p += 2
    return p
}

/// Reversing here happens in sixteen bits and *then* narrows, while
/// `packBytes4Reverse` narrows first and reverses in eight.  The
/// reference is inconsistent between the two, and the two do not agree
/// for every value, so each follows the one it mirrors.
@Sendable private func pack1ByteReversed(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(0xFFFF &- values[0])
    p += 1
    return p
}

@Sendable private func packBytes3Skip1(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    p += 1
    return p
}

@Sendable private func packBytes3Skip1SwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    return p
}

@Sendable private func packBytes3Skip1SwapSwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    p += 1
    return p
}

@Sendable private func packBytes3Skip1Swap(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 1
    p.pointee = narrow(values[2])
    p += 1
    p.pointee = narrow(values[1])
    p += 1
    p.pointee = narrow(values[0])
    p += 1
    return p
}

@Sendable private func unrollBytes3Skip1SwapSwapFirst(
    _ info: OpaquePointer?,
    _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    values[2] = widen(p.pointee)
    p += 1
    values[1] = widen(p.pointee)
    p += 1
    values[0] = widen(p.pointee)
    p += 1
    // The extra channel is stepped over last, not first, despite the
    // name saying swap-first: that names the *colour* order.
    p += 1
    return p
}

/// The integer half of the input table, in the reference's order.
let inputFormatters16: [FormatterEntry] = [
    FormatterEntry(channelsSH(1) | bytesSH(1), Any_.space, unpack: unroll1Byte),
    FormatterEntry(
        channelsSH(1) | bytesSH(1) | flavorSH(1), Any_.space, unpack: unroll1ByteReversed
    ),
    FormatterEntry(channelsSH(3) | bytesSH(1), Any_.space, unpack: unrollBytes3),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | doSwapSH(1), Any_.space, unpack: unrollBytes3Swap
    ),
    FormatterEntry(
        channelsSH(3) | extraSH(1) | bytesSH(1) | doSwapSH(1), Any_.space,
        unpack: unrollBytes3Skip1Swap
    ),
    FormatterEntry(
        channelsSH(3) | extraSH(1) | bytesSH(1) | swapFirstSH(1), Any_.space,
        unpack: unrollBytes3Skip1SwapFirst
    ),
    FormatterEntry(
        channelsSH(3) | extraSH(1) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        unpack: unrollBytes3Skip1SwapSwapFirst
    ),
    FormatterEntry(channelsSH(4) | bytesSH(1), Any_.space, unpack: unrollBytes4),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | flavorSH(1), Any_.space, unpack: unrollBytes4Reverse
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | swapFirstSH(1), Any_.space, unpack: unrollBytes4SwapFirst
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | doSwapSH(1), Any_.space, unpack: unrollBytes4Swap
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        unpack: unrollBytes4SwapSwapFirst
    ),
    FormatterEntry(channelsSH(1) | bytesSH(2), Any_.space, unpack: unroll1Word),
    FormatterEntry(channelsSH(2) | bytesSH(2), Any_.space, unpack: unrollWords2),
    FormatterEntry(channelsSH(3) | bytesSH(2), Any_.space, unpack: unrollWords3),
    FormatterEntry(channelsSH(4) | bytesSH(2), Any_.space, unpack: unrollWords4),
    FormatterEntry(
        channelsSH(3) | bytesSH(2) | doSwapSH(1), Any_.space, unpack: unrollWords3Swap
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(2) | swapFirstSH(1), Any_.space, unpack: unrollWords4SwapFirst
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(2) | doSwapSH(1), Any_.space, unpack: unrollWords4Swap
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(2) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        unpack: unrollWords4SwapSwapFirst
    ),
]

/// The integer half of the output table, in the reference's order.
let outputFormatters16: [FormatterEntry] = [
    FormatterEntry(channelsSH(1) | bytesSH(1), Any_.space, pack: packBytes1),
    FormatterEntry(
        channelsSH(1) | bytesSH(1) | flavorSH(1), Any_.space, pack: pack1ByteReversed
    ),
    FormatterEntry(channelsSH(3) | bytesSH(1), Any_.space, pack: packBytes3),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1), Any_.space, pack: packBytes3Skip1
    ),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1) | swapFirstSH(1), Any_.space,
        pack: packBytes3Skip1SwapFirst
    ),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        pack: packBytes3Skip1SwapSwapFirst
    ),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | doSwapSH(1) | extraSH(1), Any_.space,
        pack: packBytes3Skip1Swap
    ),
    FormatterEntry(channelsSH(3) | bytesSH(1) | doSwapSH(1), Any_.space, pack: packBytes3Swap),
    FormatterEntry(channelsSH(4) | bytesSH(1), Any_.space, pack: packBytes4),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | flavorSH(1), Any_.space, pack: packBytes4Reverse
    ),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | swapFirstSH(1), Any_.space, pack: packBytes4SwapFirst
    ),
    FormatterEntry(channelsSH(4) | bytesSH(1) | doSwapSH(1), Any_.space, pack: packBytes4Swap),
    FormatterEntry(
        channelsSH(4) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        pack: packBytes4SwapSwapFirst
    ),
    FormatterEntry(channelsSH(1) | bytesSH(2), Any_.space, pack: packWords1),
    FormatterEntry(channelsSH(3) | bytesSH(2), Any_.space, pack: packWords3),
    FormatterEntry(channelsSH(3) | bytesSH(2) | doSwapSH(1), Any_.space, pack: packWords3Swap),
    FormatterEntry(channelsSH(4) | bytesSH(2), Any_.space, pack: packWords4),
    FormatterEntry(channelsSH(4) | bytesSH(2) | doSwapSH(1), Any_.space, pack: packWords4Swap),
]

// -- the entry point -------------------------------------------------------------

/// Picks a formatter for a layout.  A layout with no colour channels has
/// no formatter by definition, and one the table does not cover returns
/// an empty result rather than a wrong one.
@c @implementation
public func _cmsGetFormatter(
    _ ContextID: cmsContext?,
    _ Type: cmsUInt32Number,
    _ Dir: cmsFormatterDirection,
    _ dwFlags: cmsUInt32Number
) -> cmsFormatter {
    var result = cmsFormatter()

    if PixelFormat(Type).channels == 0 { return result }
    // Only the 16-bit half exists so far; a caller asking for the float
    // path gets nothing, which is what an unsupported layout looks like.
    if dwFlags != cmsUInt32Number(CMS_PACK_FLAGS_16BITS) { return result }

    let table = Dir == cmsFormatterInput ? inputFormatters16 : outputFormatters16
    guard let entry = selectFormatter(Type, from: table) else { return result }

    result.Fmt16 = Dir == cmsFormatterInput ? entry.unpack : entry.pack
    return result
}
