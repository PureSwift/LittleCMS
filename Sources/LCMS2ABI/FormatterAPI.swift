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
// **First match wins, so order is behaviour.** Both tables are the
// reference's, entry for entry and in its order, and the float tables
// in FloatFormatterAPI.swift likewise.  A specific entry ahead of a
// generic one wins for the layouts it names; the generic entries at the
// end read the layout back from the transform they are handed and serve
// whatever is left.

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
@inline(__always) func optimizedSH(_ v: UInt32) -> UInt32 { v << 21 }
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
// transform pointer, which exists for the ones that must know the layout
// they were chosen for -- the generic entries that stand for a family of
// layouts read it back from `info->InputFormat` or `OutputFormat`.  The
// struct is opaque to plugins, but its head is fixed by the reference's
// testbed, which builds one on the stack and calls a formatter with it;
// so a formatter reads those two fields and nothing else.
//
// Widening a byte replicates it rather than shifting: 0xFF becomes
// 0xFFFF, so white stays white.  Narrowing is the reference's rounding
// multiply, not a shift, so the two are inverses across the range.

@inline(__always) func widen(_ v: UInt8) -> cmsUInt16Number {
    cmsUInt16Number(v) << 8 | cmsUInt16Number(v)
}

@inline(__always) func narrow(_ v: cmsUInt16Number) -> UInt8 {
    UInt8(truncatingIfNeeded: (cmsUInt32Number(v) &* 65281 &+ 8_388_608) >> 24)
}

@inline(__always) private func reversed(_ v: UInt8) -> UInt8 { 0xFF &- v }

/// A grey pixel fills three channels, not one: the value goes on to be
/// treated as a lightness, and the two it is padded with are what the
/// rest of the pipeline expects to find.
@Sendable private func unroll1Byte(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
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

/// Reversal in sixteen bits, matching the packers that do the same.
@Sendable private func unroll1WordReversed(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    let v = 0xFFFF &- UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    values[0] = v
    values[1] = v
    values[2] = v
    p += 2
    return p
}

/// One word read, then four skipped: the layout carries three extra
/// channels the colour does not use.
@Sendable private func unroll1WordSkip3(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    let v = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
    values[0] = v
    values[1] = v
    values[2] = v
    p += 8
    return p
}

@Sendable private func unrollWords3Skip1Swap(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 2
    for slot in [2, 1, 0] {
        values[slot] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
        p += 2
    }
    return p
}

@Sendable private func unrollWords3Skip1SwapFirst(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 2
    for slot in [0, 1, 2] {
        values[slot] = UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
        p += 2
    }
    return p
}

@Sendable private func unrollWords4Reverse(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    for slot in 0..<4 {
        values[slot] = 0xFFFF &- UnsafeRawPointer(p).loadUnaligned(as: cmsUInt16Number.self)
        p += 2
    }
    return p
}

/// The word packers reverse in sixteen bits, as their unpackers do.
@Sendable private func pack1WordReversed(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    UnsafeMutableRawPointer(p).storeBytes(of: 0xFFFF &- values[0], as: cmsUInt16Number.self)
    p += 2
    return p
}

@Sendable private func packWords4Reverse(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    for slot in 0..<4 {
        UnsafeMutableRawPointer(p).storeBytes(
            of: 0xFFFF &- values[slot], as: cmsUInt16Number.self
        )
        p += 2
    }
    return p
}

/// Both of these step over the extra channel *first*, unlike their
/// byte counterparts where only one of the pair does.
@Sendable private func packWords3Skip1SwapFirst(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 2
    for slot in [0, 1, 2] {
        UnsafeMutableRawPointer(p).storeBytes(of: values[slot], as: cmsUInt16Number.self)
        p += 2
    }
    return p
}

@Sendable private func packWords3Skip1Swap(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?, _ values: UnsafeMutablePointer<cmsUInt16Number>?,
    _ buffer: UnsafeMutablePointer<cmsUInt8Number>?, _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let values, var p = buffer else { return buffer }
    p += 2
    for slot in [2, 1, 0] {
        UnsafeMutableRawPointer(p).storeBytes(of: values[slot], as: cmsUInt16Number.self)
        p += 2
    }
    return p
}

// -- the V2 Lab encodings ------------------------------------------------------

/// `FomLabV2ToLabV4`: × 257/256, saturating.
@inline(__always) private func labV2ToV4(_ x: UInt16) -> UInt16 {
    let a = (Int(x) << 8 | Int(x)) >> 8
    return a > 0xFFFF ? 0xFFFF : UInt16(a)
}

/// `FomLabV4ToLabV2`: × 256/257, rounded.
@inline(__always) private func labV4ToV2(_ x: UInt16) -> UInt16 {
    UInt16(((Int(x) << 8) + 0x80) / 257)
}

@Sendable private func unrollLabV2_8(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    wIn[0] = labV2ToV4(widen(accum[0]))
    wIn[1] = labV2ToV4(widen(accum[1]))
    wIn[2] = labV2ToV4(widen(accum[2]))
    return accum + 3
}

@Sendable private func unrollALabV2_8(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    wIn[0] = labV2ToV4(widen(accum[1]))
    wIn[1] = labV2ToV4(widen(accum[2]))
    wIn[2] = labV2ToV4(widen(accum[3]))
    return accum + 4
}

@Sendable private func unrollLabV2_16(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wIn: UnsafeMutablePointer<cmsUInt16Number>?,
    _ accum: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wIn, let accum else { return accum }
    let raw = UnsafeRawPointer(accum)
    wIn[0] = labV2ToV4(raw.loadUnaligned(fromByteOffset: 0, as: UInt16.self))
    wIn[1] = labV2ToV4(raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
    wIn[2] = labV2ToV4(raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self))
    return accum + 6
}

@Sendable private func packLabV2_8(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wOut: UnsafeMutablePointer<cmsUInt16Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wOut, let output else { return output }
    output[0] = narrow(labV4ToV2(wOut[0]))
    output[1] = narrow(labV4ToV2(wOut[1]))
    output[2] = narrow(labV4ToV2(wOut[2]))
    return output + 3
}

@Sendable private func packALabV2_8(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wOut: UnsafeMutablePointer<cmsUInt16Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wOut, let output else { return output }
    output[1] = narrow(labV4ToV2(wOut[0]))
    output[2] = narrow(labV4ToV2(wOut[1]))
    output[3] = narrow(labV4ToV2(wOut[2]))
    return output + 4
}

@Sendable private func packLabV2_16(
    _ info: UnsafeMutablePointer<_cmstransform_struct>?,
    _ wOut: UnsafeMutablePointer<cmsUInt16Number>?,
    _ output: UnsafeMutablePointer<cmsUInt8Number>?,
    _ stride: cmsUInt32Number
) -> UnsafeMutablePointer<cmsUInt8Number>? {
    guard let wOut, let output else { return output }
    let raw = UnsafeMutableRawPointer(output)
    raw.storeBytes(of: labV4ToV2(wOut[0]), toByteOffset: 0, as: UInt16.self)
    raw.storeBytes(of: labV4ToV2(wOut[1]), toByteOffset: 2, as: UInt16.self)
    raw.storeBytes(of: labV4ToV2(wOut[2]), toByteOffset: 4, as: UInt16.self)
    return output + 6
}

/// The reference's 16-bit input table, entry for entry and in its order:
/// the floating-point layouts first, then bytes, then words, with the
/// specific shapes ahead of the generic entries that would otherwise
/// catch them.  Order is behaviour.
let inputFormatters16: [FormatterEntry] = [
    FormatterEntry(SLCMS_TYPE_Lab_DBL, Any_.planar | Any_.extra, unpack: unrollLabDoubleTo16),
    FormatterEntry(SLCMS_TYPE_XYZ_DBL, Any_.planar | Any_.extra, unpack: unrollXYZDoubleTo16),
    FormatterEntry(SLCMS_TYPE_Lab_FLT, Any_.planar | Any_.extra, unpack: unrollLabFloatTo16),
    FormatterEntry(SLCMS_TYPE_XYZ_FLT, Any_.planar | Any_.extra, unpack: unrollXYZFloatTo16),
    FormatterEntry(SLCMS_TYPE_GRAY_DBL, 0, unpack: unrollDouble1Chan),
    FormatterEntry(floatSH(1) | bytesSH(0), anyReal, unpack: unrollDoubleTo16),
    FormatterEntry(floatSH(1) | bytesSH(4), anyReal, unpack: unrollFloatTo16),
    FormatterEntry(floatSH(1) | bytesSH(2), anyReal, unpack: unrollHalfTo16),

    FormatterEntry(channelsSH(1) | bytesSH(1), Any_.space, unpack: unroll1Byte),
    FormatterEntry(channelsSH(1) | bytesSH(1) | extraSH(1), Any_.space, unpack: unroll1ByteSkip1),
    FormatterEntry(channelsSH(1) | bytesSH(1) | extraSH(2), Any_.space, unpack: unroll1ByteSkip2),
    FormatterEntry(channelsSH(1) | bytesSH(1) | flavorSH(1), Any_.space, unpack: unroll1ByteReversed),
    FormatterEntry(colorSpaceSH(cmsUInt32Number(PT_MCH2)) | channelsSH(2) | bytesSH(1), 0, unpack: unroll2Bytes),

    FormatterEntry(SLCMS_TYPE_LabV2_8, 0, unpack: unrollLabV2_8),
    FormatterEntry(SLCMS_TYPE_ALabV2_8, 0, unpack: unrollALabV2_8),
    FormatterEntry(SLCMS_TYPE_LabV2_16, 0, unpack: unrollLabV2_16),

    FormatterEntry(channelsSH(3) | bytesSH(1), Any_.space, unpack: unrollBytes3),
    FormatterEntry(channelsSH(3) | bytesSH(1) | doSwapSH(1), Any_.space, unpack: unrollBytes3Swap),
    FormatterEntry(channelsSH(3) | extraSH(1) | bytesSH(1) | doSwapSH(1), Any_.space, unpack: unrollBytes3Skip1Swap),
    FormatterEntry(channelsSH(3) | extraSH(1) | bytesSH(1) | swapFirstSH(1), Any_.space, unpack: unrollBytes3Skip1SwapFirst),
    FormatterEntry(
        channelsSH(3) | extraSH(1) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        unpack: unrollBytes3Skip1SwapSwapFirst
    ),

    FormatterEntry(channelsSH(4) | bytesSH(1), Any_.space, unpack: unrollBytes4),
    FormatterEntry(channelsSH(4) | bytesSH(1) | flavorSH(1), Any_.space, unpack: unrollBytes4Reverse),
    FormatterEntry(channelsSH(4) | bytesSH(1) | swapFirstSH(1), Any_.space, unpack: unrollBytes4SwapFirst),
    FormatterEntry(channelsSH(4) | bytesSH(1) | doSwapSH(1), Any_.space, unpack: unrollBytes4Swap),
    FormatterEntry(channelsSH(4) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space, unpack: unrollBytes4SwapSwapFirst),

    FormatterEntry(bytesSH(1) | planarSH(1), anyByteLayout | Any_.premul, unpack: unrollPlanarBytes),
    FormatterEntry(bytesSH(1), anyByteLayout | Any_.premul, unpack: unrollChunkyBytes),

    FormatterEntry(channelsSH(1) | bytesSH(2), Any_.space, unpack: unroll1Word),
    FormatterEntry(channelsSH(1) | bytesSH(2) | flavorSH(1), Any_.space, unpack: unroll1WordReversed),
    FormatterEntry(channelsSH(1) | bytesSH(2) | extraSH(3), Any_.space, unpack: unroll1WordSkip3),

    FormatterEntry(channelsSH(2) | bytesSH(2), Any_.space, unpack: unrollWords2),
    FormatterEntry(channelsSH(3) | bytesSH(2), Any_.space, unpack: unrollWords3),
    FormatterEntry(channelsSH(4) | bytesSH(2), Any_.space, unpack: unrollWords4),

    FormatterEntry(channelsSH(3) | bytesSH(2) | doSwapSH(1), Any_.space, unpack: unrollWords3Swap),
    FormatterEntry(channelsSH(3) | bytesSH(2) | extraSH(1) | swapFirstSH(1), Any_.space, unpack: unrollWords3Skip1SwapFirst),
    FormatterEntry(channelsSH(3) | bytesSH(2) | extraSH(1) | doSwapSH(1), Any_.space, unpack: unrollWords3Skip1Swap),
    FormatterEntry(channelsSH(4) | bytesSH(2) | flavorSH(1), Any_.space, unpack: unrollWords4Reverse),
    FormatterEntry(channelsSH(4) | bytesSH(2) | swapFirstSH(1), Any_.space, unpack: unrollWords4SwapFirst),
    FormatterEntry(channelsSH(4) | bytesSH(2) | doSwapSH(1), Any_.space, unpack: unrollWords4Swap),
    FormatterEntry(channelsSH(4) | bytesSH(2) | doSwapSH(1) | swapFirstSH(1), Any_.space, unpack: unrollWords4SwapSwapFirst),

    FormatterEntry(bytesSH(2) | planarSH(1), anyPlanarWordLayout, unpack: unrollPlanarWords),
    FormatterEntry(bytesSH(2), anyWordLayout, unpack: unrollAnyWords),

    FormatterEntry(bytesSH(2) | planarSH(1) | premulSH(1), anyPlanarWordLayout, unpack: unrollPlanarWordsPremul),
    FormatterEntry(bytesSH(2) | premulSH(1), anyWordLayout, unpack: unrollAnyWordsPremul),
]

/// The reference's 16-bit output table, in its order.
let outputFormatters16: [FormatterEntry] = [
    FormatterEntry(SLCMS_TYPE_Lab_DBL, Any_.planar | Any_.extra, pack: packLabDoubleFrom16),
    FormatterEntry(SLCMS_TYPE_XYZ_DBL, Any_.planar | Any_.extra, pack: packXYZDoubleFrom16),
    FormatterEntry(SLCMS_TYPE_Lab_FLT, Any_.planar | Any_.extra, pack: packLabFloatFrom16),
    FormatterEntry(SLCMS_TYPE_XYZ_FLT, Any_.planar | Any_.extra, pack: packXYZFloatFrom16),
    FormatterEntry(floatSH(1) | bytesSH(0), anyReal, pack: packDoubleFrom16),
    FormatterEntry(floatSH(1) | bytesSH(4), anyReal, pack: packFloatFrom16),
    FormatterEntry(floatSH(1) | bytesSH(2), anyReal, pack: packHalfFrom16),

    FormatterEntry(channelsSH(1) | bytesSH(1), Any_.space, pack: packBytes1),
    FormatterEntry(channelsSH(1) | bytesSH(1) | extraSH(1), Any_.space, pack: pack1ByteSkip1),
    FormatterEntry(channelsSH(1) | bytesSH(1) | extraSH(1) | swapFirstSH(1), Any_.space, pack: pack1ByteSkip1SwapFirst),
    FormatterEntry(channelsSH(1) | bytesSH(1) | flavorSH(1), Any_.space, pack: pack1ByteReversed),

    FormatterEntry(SLCMS_TYPE_LabV2_8, 0, pack: packLabV2_8),
    FormatterEntry(SLCMS_TYPE_ALabV2_8, 0, pack: packALabV2_8),
    FormatterEntry(SLCMS_TYPE_LabV2_16, 0, pack: packLabV2_16),

    FormatterEntry(channelsSH(3) | bytesSH(1) | optimizedSH(1), Any_.space, pack: pack3BytesOptimized),
    FormatterEntry(channelsSH(3) | bytesSH(1) | extraSH(1) | optimizedSH(1), Any_.space, pack: pack3BytesAndSkip1Optimized),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1) | swapFirstSH(1) | optimizedSH(1), Any_.space,
        pack: pack3BytesAndSkip1SwapFirstOptimized
    ),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1) | doSwapSH(1) | swapFirstSH(1) | optimizedSH(1), Any_.space,
        pack: pack3BytesAndSkip1SwapSwapFirstOptimized
    ),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | doSwapSH(1) | extraSH(1) | optimizedSH(1), Any_.space,
        pack: pack3BytesAndSkip1SwapOptimized
    ),
    FormatterEntry(channelsSH(3) | bytesSH(1) | doSwapSH(1) | optimizedSH(1), Any_.space, pack: pack3BytesSwapOptimized),

    FormatterEntry(channelsSH(3) | bytesSH(1), Any_.space, pack: packBytes3),
    FormatterEntry(channelsSH(3) | bytesSH(1) | extraSH(1), Any_.space, pack: packBytes3Skip1),
    FormatterEntry(channelsSH(3) | bytesSH(1) | extraSH(1) | swapFirstSH(1), Any_.space, pack: packBytes3Skip1SwapFirst),
    FormatterEntry(
        channelsSH(3) | bytesSH(1) | extraSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        pack: packBytes3Skip1SwapSwapFirst
    ),
    FormatterEntry(channelsSH(3) | bytesSH(1) | doSwapSH(1) | extraSH(1), Any_.space, pack: packBytes3Skip1Swap),
    FormatterEntry(channelsSH(3) | bytesSH(1) | doSwapSH(1), Any_.space, pack: packBytes3Swap),
    FormatterEntry(channelsSH(4) | bytesSH(1), Any_.space, pack: packBytes4),
    FormatterEntry(channelsSH(4) | bytesSH(1) | flavorSH(1), Any_.space, pack: packBytes4Reverse),
    FormatterEntry(channelsSH(4) | bytesSH(1) | swapFirstSH(1), Any_.space, pack: packBytes4SwapFirst),
    FormatterEntry(channelsSH(4) | bytesSH(1) | doSwapSH(1), Any_.space, pack: packBytes4Swap),
    FormatterEntry(channelsSH(4) | bytesSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space, pack: packBytes4SwapSwapFirst),
    FormatterEntry(channelsSH(6) | bytesSH(1), Any_.space, pack: pack6Bytes),
    FormatterEntry(channelsSH(6) | bytesSH(1) | doSwapSH(1), Any_.space, pack: pack6BytesSwap),

    FormatterEntry(bytesSH(1), anyByteLayout | Any_.premul, pack: packChunkyBytes),
    FormatterEntry(bytesSH(1) | planarSH(1), anyByteLayout | Any_.premul, pack: packPlanarBytes),

    FormatterEntry(channelsSH(1) | bytesSH(2), Any_.space, pack: packWords1),
    FormatterEntry(channelsSH(1) | bytesSH(2) | extraSH(1), Any_.space, pack: pack1WordSkip1),
    FormatterEntry(channelsSH(1) | bytesSH(2) | extraSH(1) | swapFirstSH(1), Any_.space, pack: pack1WordSkip1SwapFirst),
    FormatterEntry(channelsSH(1) | bytesSH(2) | flavorSH(1), Any_.space, pack: pack1WordReversed),
    FormatterEntry(channelsSH(1) | bytesSH(2) | endian16SH(1), Any_.space, pack: pack1WordBigEndian),
    FormatterEntry(channelsSH(3) | bytesSH(2), Any_.space, pack: packWords3),
    FormatterEntry(channelsSH(3) | bytesSH(2) | doSwapSH(1), Any_.space, pack: packWords3Swap),
    FormatterEntry(channelsSH(3) | bytesSH(2) | endian16SH(1), Any_.space, pack: pack3WordsBigEndian),
    FormatterEntry(channelsSH(3) | bytesSH(2) | extraSH(1), Any_.space, pack: pack3WordsAndSkip1),
    FormatterEntry(channelsSH(3) | bytesSH(2) | extraSH(1) | doSwapSH(1), Any_.space, pack: packWords3Skip1Swap),
    FormatterEntry(channelsSH(3) | bytesSH(2) | extraSH(1) | swapFirstSH(1), Any_.space, pack: packWords3Skip1SwapFirst),
    FormatterEntry(
        channelsSH(3) | bytesSH(2) | extraSH(1) | doSwapSH(1) | swapFirstSH(1), Any_.space,
        pack: pack3WordsAndSkip1SwapSwapFirst
    ),

    FormatterEntry(channelsSH(4) | bytesSH(2), Any_.space, pack: packWords4),
    FormatterEntry(channelsSH(4) | bytesSH(2) | flavorSH(1), Any_.space, pack: packWords4Reverse),
    FormatterEntry(channelsSH(4) | bytesSH(2) | doSwapSH(1), Any_.space, pack: packWords4Swap),
    FormatterEntry(channelsSH(4) | bytesSH(2) | endian16SH(1), Any_.space, pack: pack4WordsBigEndian),

    FormatterEntry(channelsSH(6) | bytesSH(2), Any_.space, pack: pack6Words),
    FormatterEntry(channelsSH(6) | bytesSH(2) | doSwapSH(1), Any_.space, pack: pack6WordsSwap),

    FormatterEntry(bytesSH(2), anyWordLayout | Any_.premul, pack: packChunkyWords),
    FormatterEntry(bytesSH(2) | planarSH(1), anyPlanarWordLayout | Any_.premul, pack: packPlanarWords),
]

// The composite masks the generic entries use.
private let anyReal = Any_.channels | Any_.planar | Any_.swapFirst | Any_.flavor | Any_.swap | Any_.extra | Any_.space
private let anyByteLayout = Any_.flavor | Any_.swapFirst | Any_.swap | Any_.extra | Any_.channels | Any_.space
private let anyWordLayout = Any_.flavor | Any_.swapFirst | Any_.swap | Any_.endian | Any_.extra | Any_.channels | Any_.space
private let anyPlanarWordLayout = Any_.flavor | Any_.swap | Any_.endian | Any_.extra | Any_.channels | Any_.space

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

    // A plugin's formatters would be tried first; there are none.
    if dwFlags == cmsUInt32Number(CMS_PACK_FLAGS_FLOAT) {
        result.FmtFloat = selectFloatFormatter(Type, Dir)
        return result
    }

    let table = Dir == cmsFormatterInput ? inputFormatters16 : outputFormatters16
    // On output the optimized bit is only a hint: a layout without a
    // dedicated fast packer (planar 8-bit, say) still gets its plain one.
    let lookup = Dir == cmsFormatterOutput ? Type & ~optimizedSH(1) : Type
    guard let entry = selectFormatter(lookup, from: table) else { return result }

    result.Fmt16 = Dir == cmsFormatterInput ? entry.unpack : entry.pack
    return result
}
