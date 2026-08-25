import CLCMS2
import LCMS2ABI
import LittleCMSCore

extension Profile {
    /// The profile's tags.
    public var tags: TagView { TagView(profile: self) }

    /// A profile's tag table: which tags it carries, and their payloads
    /// read and written as Swift values.
    ///
    /// The view is a window on the profile, not a copy — writing through
    /// it changes the profile, and the profile must outlive it.
    public struct TagView: RandomAccessCollection {
        let profile: Profile

        public var startIndex: Int { 0 }
        public var endIndex: Int { Int(cmsGetTagCount(profile.handle)) }

        /// The signature of the tag at `position`, in table order.
        public subscript(position: Int) -> Tag {
            Tag(rawValue: cmsGetTagSignature(profile.handle, cmsUInt32Number(position)).rawValue)
        }

        public func contains(_ tag: Tag) -> Bool {
            cmsIsTag(profile.handle, cmsTagSignature(rawValue: tag.rawValue)) != 0
        }

        // -- reading ---------------------------------------------------
        //
        // Each accessor asks for one shape.  A tag the profile does not
        // carry, or carries as something else, answers nil: the pointer
        // `cmsReadTag` hands back is only meaningful as the type its
        // signature implies, so guessing is not an option.

        private func read(_ tag: Tag) -> UnsafeMutableRawPointer? {
            cmsReadTag(profile.handle, cmsTagSignature(rawValue: tag.rawValue))
        }

        private func holds(_ tag: Tag, _ shape: Shape) -> Bool {
            Self.shape(of: tag) == shape && contains(tag)
        }

        public func xyz(_ tag: Tag) -> CIEXYZ? {
            guard holds(tag, .xyz), let raw = read(tag) else { return nil }
            let value = raw.assumingMemoryBound(to: cmsCIEXYZ.self).pointee
            return CIEXYZ(x: value.X, y: value.Y, z: value.Z)
        }

        /// A transfer curve.  The curve belongs to the profile and stays
        /// valid while it is open, so the copy handed back is its own.
        public func curve(_ tag: Tag) -> ToneCurve? {
            guard holds(tag, .curve), let raw = read(tag) else { return nil }
            let borrowed = raw.assumingMemoryBound(to: cmsToneCurve.self)
            guard let copy = cmsDupToneCurve(borrowed) else { return nil }
            return ToneCurve(context: profile.context, handle: copy)
        }

        /// The three video-card gamma curves, in red, green, blue order.
        public var videoCardGamma: [ToneCurve]? {
            guard contains(.videoCardGamma), let raw = read(.videoCardGamma) else { return nil }
            let curves = raw.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)
            var result: [ToneCurve] = []
            for i in 0..<3 {
                guard let borrowed = curves[i], let copy = cmsDupToneCurve(borrowed) else { return nil }
                result.append(ToneCurve(context: profile.context, handle: copy))
            }
            return result
        }

        /// A text tag, best-matched to the locale.  The four described
        /// by the header have shorthands on `Profile` itself.
        public func text(_ tag: Tag, language: String? = nil, country: String? = nil) -> String? {
            guard holds(tag, .text), let raw = read(tag) else { return nil }
            let mlu = raw.assumingMemoryBound(to: cmsMLU.self)
            let lang = localeField(language)
            let ctry = localeField(country)

            let needed = cmsMLUgetUTF8(mlu, lang, ctry, nil, 0)
            guard needed > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(needed))
            guard cmsMLUgetUTF8(mlu, lang, ctry, &buffer, cmsUInt32Number(buffer.count)) > 0
            else { return nil }
            return String(cString: buffer)
        }

        /// Every locale a text tag is written in.
        public func translations(_ tag: Tag) -> [(language: String, country: String)] {
            guard holds(tag, .text), let raw = read(tag) else { return [] }
            let mlu = raw.assumingMemoryBound(to: cmsMLU.self)
            let count = cmsMLUtranslationsCount(mlu)
            var result: [(String, String)] = []
            for i in 0..<count {
                var lang = [CChar](repeating: 0, count: 3)
                var ctry = [CChar](repeating: 0, count: 3)
                guard cmsMLUtranslationsCodes(mlu, i, &lang, &ctry) != 0 else { continue }
                result.append((String(cString: lang), String(cString: ctry)))
            }
            return result
        }

        public func signature(_ tag: Tag) -> Signature? {
            guard holds(tag, .signature), let raw = read(tag) else { return nil }
            return Signature(rawValue: raw.assumingMemoryBound(to: cmsSignature.self).pointee)
        }

        public func dateTime(_ tag: Tag) -> DateTime? {
            guard holds(tag, .dateTime), let raw = read(tag) else { return nil }
            let value = raw.assumingMemoryBound(to: tm.self).pointee
            return DateTime(
                year: Int(value.tm_year) + 1900, month: Int(value.tm_mon) + 1,
                day: Int(value.tm_mday), hours: Int(value.tm_hour),
                minutes: Int(value.tm_min), seconds: Int(value.tm_sec)
            )
        }

        /// The chromatic adaptation matrix, nine numbers in row-major
        /// order.  The only fixed-point array tag with a named shape;
        /// the element count is the tag's, not the payload's, because
        /// the payload does not carry one.
        public var chromaticAdaptation: [Double]? {
            guard let raw = read(.chromaticAdaptation), contains(.chromaticAdaptation) else { return nil }
            let values = raw.assumingMemoryBound(to: cmsFloat64Number.self)
            return Array(UnsafeBufferPointer(start: values, count: 9))
        }

        /// The RGB primaries a `chrm` tag records.
        public var chromaticity: RGBPrimaries? {
            guard contains(.chromaticity), let raw = read(.chromaticity) else { return nil }
            let triple = raw.assumingMemoryBound(to: cmsCIExyYTRIPLE.self).pointee
            func point(_ p: cmsCIExyY) -> CIExyY { CIExyY(x: p.x, y: p.y, yLuminance: p.Y) }
            return RGBPrimaries(red: point(triple.Red), green: point(triple.Green), blue: point(triple.Blue))
        }

        /// The key/value pairs of a `meta` tag.
        public var metadata: [String: String] {
            guard contains(.metadata), let raw = read(.metadata) else { return [:] }
            var result: [String: String] = [:]
            var entry = cmsDictGetEntryList(raw)
            while let e = entry {
                if let name = e.pointee.Name, let value = e.pointee.Value {
                    result[wideString(name)] = wideString(value)
                }
                entry = cmsDictNextEntry(e)
            }
            return result
        }

        /// A tag's bytes exactly as the file holds them, type signature
        /// included — for a tag this library has no shape for.
        public func rawData(_ tag: Tag) -> [UInt8]? {
            let sig = cmsTagSignature(rawValue: tag.rawValue)
            let size = cmsReadRawTag(profile.handle, sig, nil, 0)
            guard size > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(size))
            let got = bytes.withUnsafeMutableBytes {
                cmsReadRawTag(profile.handle, sig, $0.baseAddress, size)
            }
            return got > 0 ? bytes : nil
        }

        // -- writing ---------------------------------------------------

        private func write(_ tag: Tag, _ data: UnsafeRawPointer?, or what: String) throws {
            guard cmsWriteTag(profile.handle, cmsTagSignature(rawValue: tag.rawValue), data) != 0
            else { throw profile.context.take(or: "couldn't write \(what) to '\(tag)'") }
        }

        public func set(_ tag: Tag, xyz value: CIEXYZ) throws {
            var encoded = cmsCIEXYZ(X: value.x, Y: value.y, Z: value.z)
            try write(tag, &encoded, or: "an XYZ value")
        }

        public func set(_ tag: Tag, curve: ToneCurve) throws {
            try write(tag, curve.handle, or: "a curve")
        }

        /// Writes one translation of a text tag.  A tag written with no
        /// locale is stored under the "any language, any country" code
        /// the format reserves for it.
        public func set(
            _ tag: Tag, text: String, language: String? = nil, country: String? = nil
        ) throws {
            guard let mlu = cmsMLUalloc(profile.context.raw, 1) else {
                throw profile.context.take(or: "couldn't allocate text")
            }
            defer { cmsMLUfree(mlu) }
            let lang = localeField(language ?? "en")
            let ctry = localeField(country ?? "US")
            guard cmsMLUsetUTF8(mlu, lang, ctry, text) != 0 else {
                throw profile.context.take(or: "couldn't encode text")
            }
            try write(tag, mlu, or: "text")
        }

        public func set(_ tag: Tag, dateTime value: DateTime) throws {
            var encoded = tm()
            encoded.tm_year = Int32(value.year - 1900)
            encoded.tm_mon = Int32(value.month - 1)
            encoded.tm_mday = Int32(value.day)
            encoded.tm_hour = Int32(value.hours)
            encoded.tm_min = Int32(value.minutes)
            encoded.tm_sec = Int32(value.seconds)
            try write(tag, &encoded, or: "a date")
        }

        public func set(_ tag: Tag, signature value: Signature) throws {
            var encoded = cmsSignature(value.rawValue)
            try write(tag, &encoded, or: "a signature")
        }

        /// Points one tag at another's payload, as the format lets a
        /// profile do rather than storing the bytes twice.
        public func link(_ tag: Tag, to other: Tag) throws {
            guard cmsLinkTag(
                profile.handle,
                cmsTagSignature(rawValue: tag.rawValue),
                cmsTagSignature(rawValue: other.rawValue)
            ) != 0 else {
                throw profile.context.take(or: "couldn't link '\(tag)' to '\(other)'")
            }
        }

        /// What `tag` is linked to, or nil when it holds its own payload.
        public func linkTarget(_ tag: Tag) -> Tag? {
            let target = cmsTagLinkedTo(profile.handle, cmsTagSignature(rawValue: tag.rawValue))
            return target.rawValue == 0 ? nil : Tag(rawValue: target.rawValue)
        }

        /// Removes a tag.  Writing nothing to it is how the format says
        /// "not present", and the reference spells it the same way.
        public func remove(_ tag: Tag) throws {
            try write(tag, nil, or: "a removal")
        }

        // -- what shape a tag has --------------------------------------

        enum Shape {
            case xyz, curve, text, signature, dateTime, other
        }

        /// The payload shape a signature implies.  Only the tags with a
        /// Swift accessor need naming; everything else is reachable as
        /// raw bytes.
        static func shape(of tag: Tag) -> Shape {
            switch tag {
            case .mediaWhitePoint, .mediaBlackPoint, .luminance,
                 .redColorant, .greenColorant, .blueColorant:
                return .xyz
            case .redTRC, .greenTRC, .blueTRC, .grayTRC:
                return .curve
            case .profileDescription, .deviceManufacturerDescription,
                 .deviceModelDescription, .copyright, .viewingConditionsDescription:
                return .text
            case .technology, .colorimetricIntentImageState,
                 .perceptualRenderingIntentGamut, .saturationRenderingIntentGamut:
                return .signature
            case .calibrationDateTime:
                return .dateTime
            default:
                return .other
            }
        }
    }
}

/// A `wchar_t*` as a Swift string.  The C API stores dictionary keys
/// and values in the platform's wide characters, four bytes on
/// everything this library builds for.
private func wideString(_ pointer: UnsafeMutablePointer<wchar_t>) -> String {
    var scalars = String.UnicodeScalarView()
    var p = pointer
    while p.pointee != 0 {
        if let scalar = Unicode.Scalar(UInt32(bitPattern: Int32(p.pointee))) {
            scalars.append(scalar)
        }
        p += 1
    }
    return String(scalars)
}
