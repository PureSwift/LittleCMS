// Named colours: the spot-colour tables a profile carries, where each
// entry has a name and both a PCS value and a device colorant.
//
// The names are compared case-insensitively and stored as bytes rather
// than as text, because the format gives them a fixed byte length and a
// profile in the wild may hold anything in them.

/// The most channels a colorant can have, `cmsMAXCHANNELS`.
public let maximumChannels = 16
/// The byte length the format gives a colour's name, `cmsMAX_PATH`.
public let maximumNameLength = 256

/// One named colour.
public struct NamedColor: Sendable {
    /// The name, without its terminator.  Bytes, not a string: nothing
    /// promises this is valid text in any encoding.
    public var name: [UInt8]
    public var pcs: (UInt16, UInt16, UInt16)
    public var colorant: [UInt16]

    public init(name: [UInt8], pcs: (UInt16, UInt16, UInt16), colorant: [UInt16]) {
        self.name = name
        self.pcs = pcs
        self.colorant = colorant
    }
}

/// The engine's named colour table.
public final class NamedColorList {
    public private(set) var colors: [NamedColor] = []
    /// How many colorant channels each entry carries.
    public let colorantCount: Int
    /// Applied to every name when one is displayed; the format stores
    /// them once for the whole table, at 32 bytes each.
    public var prefix: [UInt8]
    public var suffix: [UInt8]

    /// The fixed byte length of the prefix and suffix fields.
    public static let affixLength = 32

    public init?(colorantCount: Int, prefix: [UInt8], suffix: [UInt8], reserving: Int = 0) {
        // More channels than a colorant can hold is refused outright.
        guard colorantCount <= maximumChannels else { return nil }
        self.colorantCount = colorantCount
        self.prefix = prefix
        self.suffix = suffix
        if reserving > 0 { colors.reserveCapacity(reserving) }
    }

    public init(copying other: NamedColorList) {
        colorantCount = other.colorantCount
        prefix = other.prefix
        suffix = other.suffix
        colors = other.colors
    }

    /// Appends a colour, truncating the name to what the format holds.
    /// A missing name, PCS or colorant becomes zeroes, as in the
    /// reference.
    public func append(name: [UInt8]?, pcs: (UInt16, UInt16, UInt16)?, colorant: [UInt16]?) {
        var stored = [UInt16](repeating: 0, count: colorantCount)
        if let colorant {
            for i in 0..<min(colorantCount, colorant.count) { stored[i] = colorant[i] }
        }

        colors.append(NamedColor(
            name: Array((name ?? []).prefix(maximumNameLength - 1)),
            pcs: pcs ?? (0, 0, 0),
            colorant: stored
        ))
    }

    /// The index of a colour by name, compared case-insensitively, or nil.
    public func index(ofName name: [UInt8]) -> Int? {
        colors.firstIndex { caselessEqual($0.name, name) }
    }
}

/// `cmsstrcasecmp`'s comparison, in the form the C library's `toupper`
/// gives it for the bytes a name can hold.
@inlinable
public func caselessCompare(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
    var i = 0
    while true {
        let left = i < a.count ? uppercased(a[i]) : 0
        let right = i < b.count ? uppercased(b[i]) : 0
        if left != right { return Int32(left) - Int32(right) }
        if left == 0 { return 0 }
        i += 1
    }
}

@inlinable
public func caselessEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    caselessCompare(a, b) == 0
}

/// Only the unaccented Latin letters, which is what `toupper` changes in
/// the default locale — and the default locale is what the reference
/// runs in.
@inlinable
public func uppercased(_ byte: UInt8) -> UInt8 {
    (byte >= 0x61 && byte <= 0x7A) ? byte - 0x20 : byte
}
