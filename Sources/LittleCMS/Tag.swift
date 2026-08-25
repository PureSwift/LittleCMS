// The tags a profile carries.
//
// An ICC profile is a table of tags, each a four-character signature
// naming a payload whose shape the signature decides.  Swift cannot
// express "the type depends on the key", so reading is by typed
// accessor — `profile.tags.xyz(.mediaWhitePoint)` — and a tag asked for
// as the wrong shape answers nil rather than reinterpreting bytes.

/// A tag signature.  An open set: a profile in the wild may carry a
/// private tag no specification names.
public struct Tag: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// A signature from its four characters.
    public init(_ text: StaticString) {
        var value: UInt32 = 0
        text.withUTF8Buffer { for byte in $0.prefix(4) { value = value << 8 | UInt32(byte) } }
        self.init(rawValue: value)
    }

    /// The four characters, as they appear in the file.
    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // Colorimetry.
    public static let mediaWhitePoint = Tag("wtpt")
    public static let mediaBlackPoint = Tag("bkpt")
    public static let luminance = Tag("lumi")
    public static let redColorant = Tag("rXYZ")
    public static let greenColorant = Tag("gXYZ")
    public static let blueColorant = Tag("bXYZ")
    public static let chromaticAdaptation = Tag("chad")
    public static let chromaticity = Tag("chrm")

    // Transfer curves.
    public static let redTRC = Tag("rTRC")
    public static let greenTRC = Tag("gTRC")
    public static let blueTRC = Tag("bTRC")
    public static let grayTRC = Tag("kTRC")
    public static let videoCardGamma = Tag("vcgt")

    // Text.
    public static let profileDescription = Tag("desc")
    public static let deviceManufacturerDescription = Tag("dmnd")
    public static let deviceModelDescription = Tag("dmdd")
    public static let copyright = Tag("cprt")
    public static let viewingConditionsDescription = Tag("vued")
    public static let characterizationTarget = Tag("targ")

    // Signatures and enumerations.
    public static let technology = Tag("tech")
    public static let colorimetricIntentImageState = Tag("c2sp")
    public static let perceptualRenderingIntentGamut = Tag("rig0")
    public static let saturationRenderingIntentGamut = Tag("rig2")

    // Structure.
    public static let namedColor2 = Tag("ncl2")
    public static let colorantTable = Tag("clrt")
    public static let colorantTableOut = Tag("clot")
    public static let colorantOrder = Tag("clro")
    public static let metadata = Tag("meta")
    public static let profileSequenceDescription = Tag("pseq")
    public static let calibrationDateTime = Tag("calt")

    // The conversion tables.
    public static let aToB0 = Tag("A2B0")
    public static let aToB1 = Tag("A2B1")
    public static let aToB2 = Tag("A2B2")
    public static let bToA0 = Tag("B2A0")
    public static let bToA1 = Tag("B2A1")
    public static let bToA2 = Tag("B2A2")
    public static let gamut = Tag("gamt")
    public static let preview0 = Tag("pre0")
    public static let preview1 = Tag("pre1")
    public static let preview2 = Tag("pre2")
}

/// A four-character value some tags hold as their whole payload — the
/// technology that made a profile, say.
public struct Signature: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A date and time as ICC stores one: six numbers, UTC, no zone and no
/// calendar arithmetic.
public struct DateTime: Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hours: Int
    public var minutes: Int
    public var seconds: Int

    public init(year: Int, month: Int, day: Int, hours: Int, minutes: Int, seconds: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
    }
}
