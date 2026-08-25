// The signatures a profile is described by.  Open sets — a profile in
// the wild can carry anything — so these are raw-value structs with the
// common cases named, not closed enums.

/// A color space signature, `cmsColorSpaceSignature`.
public struct ColorSpace: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    private static func sig(_ text: StaticString) -> ColorSpace {
        var value: UInt32 = 0
        text.withUTF8Buffer { for byte in $0 { value = value << 8 | UInt32(byte) } }
        return ColorSpace(rawValue: value)
    }

    public static let xyz = sig("XYZ ")
    public static let lab = sig("Lab ")
    public static let luv = sig("Luv ")
    public static let ycbcr = sig("YCbr")
    public static let yxy = sig("Yxy ")
    public static let rgb = sig("RGB ")
    public static let gray = sig("GRAY")
    public static let hsv = sig("HSV ")
    public static let hls = sig("HLS ")
    public static let cmyk = sig("CMYK")
    public static let cmy = sig("CMY ")
}

/// A profile class signature, `cmsProfileClassSignature`.
public struct ProfileClass: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    private static func sig(_ text: StaticString) -> ProfileClass {
        var value: UInt32 = 0
        text.withUTF8Buffer { for byte in $0 { value = value << 8 | UInt32(byte) } }
        return ProfileClass(rawValue: value)
    }

    public static let input = sig("scnr")
    public static let display = sig("mntr")
    public static let output = sig("prtr")
    public static let deviceLink = sig("link")
    public static let abstract = sig("abst")
    public static let colorSpaceConversion = sig("spac")
    public static let namedColor = sig("nmcl")
}
