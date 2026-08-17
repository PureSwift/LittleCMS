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
