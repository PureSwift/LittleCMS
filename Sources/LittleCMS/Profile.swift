import CLCMS2
import LCMS2ABI
import LittleCMSCore

/// An ICC profile.
public final class Profile {
    let context: CaptureContext
    let handle: cmsHPROFILE

    init(context: CaptureContext, handle: cmsHPROFILE) {
        self.context = context
        self.handle = handle
    }

    deinit {
        _ = cmsCloseProfile(handle)
    }

    private convenience init(
        _ context: CaptureContext, _ handle: cmsHPROFILE?, or fallback: String
    ) throws {
        guard let handle else { throw context.take(or: fallback) }
        self.init(context: context, handle: handle)
    }

    // -- opening -------------------------------------------------------

    public convenience init(data: [UInt8]) throws {
        let context = CaptureContext()
        let handle = data.withUnsafeBytes {
            cmsOpenProfileFromMemTHR(context.raw, $0.baseAddress, cmsUInt32Number($0.count))
        }
        try self.init(context, handle, or: "couldn't parse profile")
    }

    public convenience init(contentsOfFile path: String) throws {
        let context = CaptureContext()
        let handle = cmsOpenProfileFromFileTHR(context.raw, path, "r")
        try self.init(context, handle, or: "couldn't open '\(path)'")
    }

    // -- the built-in profiles -----------------------------------------

    public static func sRGB() throws -> Profile {
        let context = CaptureContext()
        return try Profile(context, cmsCreate_sRGBProfileTHR(context.raw), or: "couldn't build sRGB")
    }

    /// CIE L*a*b* version 4, D50 unless another white point is given.
    public static func lab(whitePoint: CIExyY? = nil) throws -> Profile {
        let context = CaptureContext()
        let handle: cmsHPROFILE?
        if let whitePoint {
            var wp = cmsCIExyY(x: whitePoint.x, y: whitePoint.y, Y: whitePoint.yLuminance)
            handle = cmsCreateLab4ProfileTHR(context.raw, &wp)
        } else {
            handle = cmsCreateLab4ProfileTHR(context.raw, nil)
        }
        return try Profile(context, handle, or: "couldn't build Lab profile")
    }

    public static func xyz() throws -> Profile {
        let context = CaptureContext()
        return try Profile(context, cmsCreateXYZProfileTHR(context.raw), or: "couldn't build XYZ profile")
    }

    /// A monochrome profile with the given transfer curve.
    public static func gray(whitePoint: CIExyY, curve: ToneCurve) throws -> Profile {
        let context = CaptureContext()
        var wp = cmsCIExyY(x: whitePoint.x, y: whitePoint.y, Y: whitePoint.yLuminance)
        let handle = cmsCreateGrayProfileTHR(context.raw, &wp, curve.handle)
        return try Profile(context, handle, or: "couldn't build gray profile")
    }

    /// A matrix-shaper RGB profile from primaries and transfer curves.
    public static func rgb(
        whitePoint: CIExyY, primaries: RGBPrimaries, curves: (ToneCurve, ToneCurve, ToneCurve)
    ) throws -> Profile {
        let context = CaptureContext()
        var wp = cmsCIExyY(x: whitePoint.x, y: whitePoint.y, Y: whitePoint.yLuminance)
        var triple = cmsCIExyYTRIPLE(
            Red: cmsCIExyY(x: primaries.red.x, y: primaries.red.y, Y: primaries.red.yLuminance),
            Green: cmsCIExyY(x: primaries.green.x, y: primaries.green.y, Y: primaries.green.yLuminance),
            Blue: cmsCIExyY(x: primaries.blue.x, y: primaries.blue.y, Y: primaries.blue.yLuminance)
        )
        var table: [UnsafeMutablePointer<cmsToneCurve>?] = [
            curves.0.handle, curves.1.handle, curves.2.handle,
        ]
        let handle = cmsCreateRGBProfileTHR(context.raw, &wp, &triple, &table)
        return try Profile(context, handle, or: "couldn't build RGB profile")
    }

    /// The profile that maps everything to nothing, for measuring.
    public static func null() throws -> Profile {
        let context = CaptureContext()
        return try Profile(context, cmsCreateNULLProfileTHR(context.raw), or: "couldn't build NULL profile")
    }

    // -- the header ----------------------------------------------------

    public var colorSpace: ColorSpace {
        ColorSpace(rawValue: cmsGetColorSpace(handle).rawValue)
    }

    /// The profile connection space its transforms pivot through.
    public var connectionSpace: ColorSpace {
        ColorSpace(rawValue: cmsGetPCS(handle).rawValue)
    }

    public var profileClass: ProfileClass {
        ProfileClass(rawValue: cmsGetDeviceClass(handle).rawValue)
    }

    /// The ICC specification version, e.g. 4.3.
    public var version: Double {
        get { cmsGetProfileVersion(handle) }
        set { cmsSetProfileVersion(handle, newValue) }
    }

    // -- descriptions --------------------------------------------------

    /// The kinds of text a profile describes itself with.
    public enum Info: UInt32, Sendable {
        case description = 0
        case manufacturer = 1
        case model = 2
        case copyright = 3
    }

    /// One of the profile's descriptive strings, best-matched to the
    /// locale, or nil when the profile carries none.
    public func text(
        _ kind: Info = .description, language: String? = nil, country: String? = nil
    ) -> String? {
        let lang = localeField(language)
        let ctry = localeField(country)
        let info = cmsInfoType(rawValue: kind.rawValue)

        let needed = cmsGetProfileInfoUTF8(handle, info, lang, ctry, nil, 0)
        guard needed > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(needed))
        guard cmsGetProfileInfoUTF8(
            handle, info, lang, ctry, &buffer, cmsUInt32Number(buffer.count)
        ) > 0 else { return nil }
        return String(cString: buffer)
    }

    public var profileDescription: String? { text(.description) }
    public var manufacturer: String? { text(.manufacturer) }
    public var model: String? { text(.model) }
    public var copyright: String? { text(.copyright) }

    // -- capabilities --------------------------------------------------

    /// The conversion directions a profile can serve in.
    public enum Direction: UInt32, Sendable {
        case input = 0
        case output = 1
        case proof = 2
    }

    public func supports(_ intent: Intent, as direction: Direction = .input) -> Bool {
        cmsIsIntentSupported(handle, cmsUInt32Number(intent.rawValue), cmsUInt32Number(direction.rawValue)) != 0
    }

    /// Whether the profile converts through curves and a matrix alone.
    public var isMatrixShaper: Bool { cmsIsMatrixShaper(handle) != 0 }

    /// The media white point tag, as measured XYZ.
    public var mediaWhitePoint: CIEXYZ? { tags.xyz(.mediaWhitePoint) }

    // -- named colors --------------------------------------------------

    /// The spot colours of a named-color profile, in table order.
    public var namedColors: [NamedColor] {
        guard let tag = cmsReadTag(handle, cmsSigNamedColor2Tag) else { return [] }
        let list = tag.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
        let count = cmsNamedColorCount(list)
        var colors: [NamedColor] = []
        colors.reserveCapacity(Int(count))
        for i in 0..<count {
            var name = [CChar](repeating: 0, count: 256)
            var pcs = [cmsUInt16Number](repeating: 0, count: 3)
            var colorant = [cmsUInt16Number](repeating: 0, count: 16)
            guard cmsNamedColorInfo(list, i, &name, nil, nil, &pcs, &colorant) != 0 else { continue }
            let bytes = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            colors.append(NamedColor(name: bytes, pcs: (pcs[0], pcs[1], pcs[2]), colorant: colorant))
        }
        return colors
    }

    // -- saving --------------------------------------------------------

    /// The profile serialized, with its ID freshly computed.
    public func save() throws -> [UInt8] {
        var size: cmsUInt32Number = 0
        guard cmsSaveProfileToMem(handle, nil, &size) != 0 else {
            throw context.take(or: "couldn't serialize profile")
        }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard bytes.withUnsafeMutableBytes({ cmsSaveProfileToMem(handle, $0.baseAddress, &size) }) != 0
        else { throw context.take(or: "couldn't serialize profile") }
        return bytes
    }

    public func write(toFile path: String) throws {
        guard cmsSaveProfileToFile(handle, path) != 0 else {
            throw context.take(or: "couldn't write '\(path)'")
        }
    }
}
