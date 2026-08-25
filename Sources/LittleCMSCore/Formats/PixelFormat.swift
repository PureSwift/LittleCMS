// The pixel-format word.
//
// Every `TYPE_*` constant is one 32-bit word describing a buffer layout:
// how many colour channels, how many extra ones, how wide each is,
// whether they are planar, in what order, and which colour space they
// belong to.  There are 178 named combinations in the header, but the
// word is what the library actually reads, and it can describe layouts
// no constant names.
//
// The accessors are the header's `T_*` macros.  They are here rather
// than at the boundary because they are arithmetic on a number, and
// because the engine needs them where no C header exists.

/// One decoded pixel-format word.
///
/// Nothing validates on construction: a word that names an impossible
/// layout is a word the formatter tables simply will not match, which is
/// how the library reports it.
public struct PixelFormat: Equatable, Sendable {
    public let rawValue: UInt32

    @inlinable
    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Bytes per channel.  Zero is not a mistake — it means eight bytes,
    /// the only width that does not fit in the three bits available.
    @inlinable public var bytes: Int { Int(rawValue & 7) }

    /// Colour channels, not counting the extra ones.
    @inlinable public var channels: Int { Int((rawValue >> 3) & 15) }

    /// Channels carried alongside the colour, such as alpha.
    @inlinable public var extra: Int { Int((rawValue >> 7) & 7) }

    /// Whether the channel order is reversed.
    @inlinable public var swapped: Bool { (rawValue >> 10) & 1 != 0 }

    /// Whether 16-bit channels are little-endian.
    @inlinable public var endianSwapped: Bool { (rawValue >> 11) & 1 != 0 }

    /// Whether each channel is a separate plane rather than interleaved.
    @inlinable public var planar: Bool { (rawValue >> 12) & 1 != 0 }

    /// Whether the values are inverted, as subtractive inks are.
    @inlinable public var inverted: Bool { (rawValue >> 13) & 1 != 0 }

    /// Whether the extra channels come first rather than last.
    @inlinable public var swapFirst: Bool { (rawValue >> 14) & 1 != 0 }

    /// The colour space, as the header's small enumeration rather than
    /// an ICC signature.
    @inlinable public var colorSpace: Int { Int((rawValue >> 16) & 31) }

    /// Whether the channels are premultiplied by the alpha.
    @inlinable public var premultiplied: Bool { (rawValue >> 23) & 1 != 0 }

    /// Whether the channels are floating point rather than integer.
    @inlinable public var floatingPoint: Bool { (rawValue >> 22) & 1 != 0 }

    /// Every channel in the buffer, colour and extra together — which is
    /// what decides the stride from one pixel to the next.
    @inlinable public var totalChannels: Int { channels + extra }
}
