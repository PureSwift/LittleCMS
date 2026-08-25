// Multi-localized unicode: the strings an ICC profile carries in more
// than one language.
//
// The reference stores these as a directory of language/country pairs
// over one memory pool, which is a serialization concern rather than a
// modelling one; here it is a list of entries, and the pool arrives when
// the tag is written.  What has to be reproduced exactly is which entry a
// lookup finds, because a profile with several translations is common and
// picking a different one is a visible difference.

/// A language or country code, as the two characters ICC carries and the
/// 16-bit value the reference compares.
@frozen
public struct LocaleCode: Hashable, Sendable {
    public var rawValue: UInt16

    @inlinable
    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// The reference reads exactly two characters, and treats a shorter
    /// string as the code it can make from what is there.
    @inlinable
    public init(_ first: UInt8, _ second: UInt8) {
        rawValue = UInt16(first) << 8 | UInt16(second)
    }

    /// `strTo16`: a null pointer or an empty string is the zero code,
    /// which is how "no language" is spelled.
    public init(twoCharacters buffer: UnsafePointer<CChar>?) {
        guard let buffer else {
            self.init(rawValue: 0)
            return
        }
        // Both characters are read, whatever they are: the API declares
        // three, and the reference's testbed passes codes whose first
        // byte is zero and second is not, expecting them to be distinct.
        let first = UInt8(bitPattern: buffer[0])
        let second = UInt8(bitPattern: buffer[1])
        self.init(first, second)
    }

    @inlinable
    public var characters: (UInt8, UInt8) {
        (UInt8(truncatingIfNeeded: rawValue >> 8), UInt8(truncatingIfNeeded: rawValue))
    }

    public static let none = LocaleCode(rawValue: 0)
}

/// One translation.
public struct Translation: Sendable {
    public var language: LocaleCode
    public var country: LocaleCode
    /// UTF-16 code units, which is what the format stores and what the
    /// wide-character accessors convert to and from.
    public var text: [UInt16]

    public init(language: LocaleCode, country: LocaleCode, text: [UInt16]) {
        self.language = language
        self.country = country
        self.text = text
    }
}

/// The engine's multi-localized string table.
public final class MultiLocalizedUnicode {
    public private(set) var translations: [Translation] = []

    public init(capacity: Int = 0) {
        if capacity > 0 { translations.reserveCapacity(capacity) }
    }

    public init(copying other: MultiLocalizedUnicode) {
        translations = other.translations
    }

    /// Adds a translation, refusing a pair the table already holds.
    ///
    /// The reference allows one string per language and country and
    /// declines a second outright — the first one set wins, and a caller
    /// wanting to change it has to build a new table.  Replacing instead
    /// would look like an improvement and would quietly change which
    /// string a profile carries.
    @discardableResult
    public func set(_ text: [UInt16], language: LocaleCode, country: LocaleCode) -> Bool {
        guard !translations.contains(where: {
            $0.language == language && $0.country == country
        }) else { return false }

        translations.append(Translation(language: language, country: country, text: text))
        return true
    }

    /// The translation a lookup finds, and it is not simply the exact
    /// match or nothing.
    ///
    /// An exact language-and-country match wins.  Failing that, the first
    /// entry whose *language* matches is used, whatever its country.
    /// Failing even that, the first entry in the table is returned — so a
    /// lookup for a language the profile has never heard of still comes
    /// back with a string.  Only an empty table finds nothing.
    public func lookup(language: LocaleCode, country: LocaleCode) -> Translation? {
        guard !translations.isEmpty else { return nil }

        var best: Int?
        for (index, entry) in translations.enumerated() where entry.language == language {
            if best == nil { best = index }
            if entry.country == country { return entry }
        }

        return translations[best ?? 0]
    }
}
