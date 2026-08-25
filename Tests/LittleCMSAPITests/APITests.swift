import LittleCMS
import Testing

@Suite struct PixelFormatPresets {
    // Pinned to the C headers' TYPE_* macros, printed by a reference
    // program; a preset that drifts from its macro converts wrongly.
    static let pins: [(String, PixelFormat, UInt32)] = [
        ("gray8", .gray8, 196617), ("gray16", .gray16, 196618), ("grayFloat", .grayFloat, 4390924),
        ("rgb8", .rgb8, 262169), ("rgba8", .rgba8, 262297), ("argb8", .argb8, 278681),
        ("bgr8", .bgr8, 263193), ("bgra8", .bgra8, 279705), ("rgb8Planar", .rgb8Planar, 266265),
        ("rgb16", .rgb16, 262170), ("rgba16", .rgba16, 262298), ("rgbHalf", .rgbHalf, 4456474),
        ("rgbFloat", .rgbFloat, 4456476), ("rgbaFloat", .rgbaFloat, 4456604),
        ("rgbDouble", .rgbDouble, 4456472),
        ("cmyk8", .cmyk8, 393249), ("cmyk16", .cmyk16, 393250), ("cmykFloat", .cmykFloat, 4587556),
        ("lab8", .lab8, 655385), ("lab16", .lab16, 655386), ("labFloat", .labFloat, 4849692),
        ("labDouble", .labDouble, 4849688),
        ("xyz16", .xyz16, 589850), ("xyzFloat", .xyzFloat, 4784156), ("xyzDouble", .xyzDouble, 4784152),
    ]

    @Test func matchTheMacros() {
        for (name, format, value) in Self.pins {
            #expect(format.rawValue == value, "\(name)")
        }
    }

    @Test func pixelSizes() {
        #expect(PixelFormat.rgb8.bytesPerPixel == 3)
        #expect(PixelFormat.bgra8.bytesPerPixel == 4)
        #expect(PixelFormat.labDouble.bytesPerPixel == 24)
        #expect(PixelFormat.rgba16.bytesPerPixel == 8)
    }
}

@Suite struct Profiles {
    @Test func builtIns() throws {
        let srgb = try Profile.sRGB()
        #expect(srgb.colorSpace == .rgb)
        #expect(srgb.connectionSpace == .xyz)
        #expect(srgb.profileClass == .display)
        #expect(srgb.profileDescription == "sRGB built-in")
        #expect(srgb.isMatrixShaper)
        #expect(srgb.supports(.perceptual))

        let lab = try Profile.lab()
        #expect(lab.colorSpace == .lab)

        let white = try #require(srgb.mediaWhitePoint)
        #expect(abs(white.y - 1.0) < 1e-6)
    }

    @Test func saveAndReload() throws {
        let bytes = try Profile.sRGB().save()
        #expect(bytes.count > 128)
        let reloaded = try Profile(data: bytes)
        #expect(reloaded.profileDescription == "sRGB built-in")
        #expect(reloaded.version == 4.4)
    }

    @Test func garbageThrows() {
        #expect(throws: CMSError.self) {
            _ = try Profile(data: [UInt8](repeating: 0xAB, count: 64))
        }
        do {
            _ = try Profile(data: [1, 2, 3])
            Issue.record("parsed garbage")
        } catch let error as CMSError {
            #expect(!error.message.isEmpty)
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test func grayFactory() throws {
        let gray = try Profile.gray(whitePoint: .d50, curve: ToneCurve(gamma: 2.2))
        #expect(gray.colorSpace == .gray)
    }

    @Test func rgbFactory() throws {
        // Rec. 709 primaries around D65.
        let d65 = CIExyY(x: 0.3127, y: 0.3290, yLuminance: 1.0)
        let primaries = RGBPrimaries(
            red: CIExyY(x: 0.64, y: 0.33, yLuminance: 1),
            green: CIExyY(x: 0.30, y: 0.60, yLuminance: 1),
            blue: CIExyY(x: 0.15, y: 0.06, yLuminance: 1)
        )
        let curve = try ToneCurve(gamma: 2.2)
        let profile = try Profile.rgb(whitePoint: d65, primaries: primaries, curves: (curve, curve, curve))
        #expect(profile.colorSpace == .rgb)
        #expect(profile.isMatrixShaper)
    }
}

@Suite struct ToneCurves {
    @Test func gamma() throws {
        let curve = try ToneCurve(gamma: 2.2)
        #expect(abs(Double(curve.evaluate(Float(0.5))) - 0.2176) < 0.001)
        #expect(curve.isMonotonic)
        #expect(!curve.isLinear)
        let estimated = try #require(curve.estimatedGamma())
        #expect(abs(estimated - 2.2) < 0.01)
    }

    @Test func reversal() throws {
        let curve = try ToneCurve(gamma: 3.0)
        let inverse = try curve.reversed()
        let there = curve.evaluate(Float(0.25))
        #expect(abs(Double(inverse.evaluate(there)) - 0.25) < 0.001)
    }

    @Test func table() throws {
        let identity = try ToneCurve(table: [0, 0x8000, 0xFFFF])
        #expect(identity.isLinear)
        #expect(abs(Int(identity.evaluate(UInt16(0x4000))) - 0x4000) <= 1)
    }

    @Test func parametric() throws {
        // Type 4 is the sRGB shape; near-black is the linear segment.
        let srgb = try ToneCurve(
            parametricType: 4,
            parameters: [2.4, 1 / 1.055, 0.055 / 1.055, 1 / 12.92, 0.04045]
        )
        #expect(abs(Double(srgb.evaluate(Float(0.02))) - 0.02 / 12.92) < 1e-5)
    }
}

@Suite struct Transforms {
    @Test func sRGBToLab() throws {
        let transform = try Transform(
            from: .sRGB(), format: .rgb8,
            to: .lab(), format: .labDouble,
            intent: .relativeColorimetric
        )
        let pixels: [UInt8] = [255, 255, 255, 0, 0, 0, 255, 0, 0]
        var lab = [Double](repeating: 0, count: 9)
        pixels.withUnsafeBytes { input in
            lab.withUnsafeMutableBytes { output in
                transform.convert(from: input, to: output, pixelCount: 3)
            }
        }
        #expect(abs(lab[0] - 100) < 0.01)                        // white L
        #expect(abs(lab[1]) < 0.01 && abs(lab[2]) < 0.01)        // white a, b
        #expect(lab[3] < 0.01)                                   // black L
        #expect(lab[6] > 50 && lab[7] > 60)                      // red is red
    }

    @Test func byteConvenience() throws {
        let transform = try Transform(
            from: .sRGB(), format: .rgb8, to: .sRGB(), format: .bgra8
        )
        let out = try transform.convert([10, 20, 30])
        #expect(out.count == 4)
        #expect(out[0] == 30 && out[1] == 20 && out[2] == 10)
    }

    @Test func partialPixelThrows() throws {
        let transform = try Transform(
            from: .sRGB(), format: .rgb8, to: .sRGB(), format: .rgb8
        )
        #expect(throws: CMSError.self) { _ = try transform.convert([1, 2]) }
    }

    @Test func mismatchThrows() throws {
        // A gray profile cannot serve a 3-channel RGB layout.
        let gray = try Profile.gray(whitePoint: .d50, curve: ToneCurve(gamma: 2.2))
        do {
            _ = try Transform(from: gray, format: .rgb8, to: .sRGB(), format: .rgb8)
            Issue.record("built an impossible transform")
        } catch let error as CMSError {
            #expect(!error.message.isEmpty)
        }
    }

    @Test func chain() throws {
        let transform = try Transform(
            chain: [try .sRGB(), try .lab(), try .sRGB()],
            inputFormat: .rgb8, outputFormat: .rgb8
        )
        let out = try transform.convert([200, 100, 50])
        #expect(out.count == 3)
        #expect(abs(Int(out[0]) - 200) <= 1 && abs(Int(out[1]) - 100) <= 1)
    }

    @Test func concurrentUse() async throws {
        let transform = try Transform(
            from: .sRGB(), format: .rgb8, to: .lab(), format: .lab16,
            options: [.noCache]
        )
        await withTaskGroup(of: [UInt8].self) { group in
            for i in 0..<8 {
                group.addTask {
                    let pixel = [UInt8](repeating: UInt8(i * 30), count: 3)
                    return (try? transform.convert(pixel)) ?? []
                }
            }
            for await result in group { #expect(result.count == 6) }
        }
    }
}

@Suite struct Colorimetry {
    @Test func labRoundTrip() {
        let lab = CIELab(l: 50, a: 20, b: -30)
        let white = lab.deltaE2000(to: lab, kL: 1, kC: 1, kH: 1)
        #expect(white == 0)
        #expect(lab.deltaE(to: CIELab(l: 51, a: 20, b: -30)) == 1)
    }
}

@Suite struct Tags {
    @Test func signatureRoundTrip() {
        #expect(Tag.mediaWhitePoint.rawValue == 0x77_74_70_74)
        #expect(Tag.mediaWhitePoint.description == "wtpt")
        #expect(Tag("A2B0") == .aToB0)
        #expect(Signature(rawValue: 0x43_52_54_20).description == "CRT ")
    }

    @Test func enumeratesWhatAProfileCarries() throws {
        let srgb = try Profile.sRGB()
        let tags = srgb.tags
        #expect(tags.count > 5)
        #expect(tags.contains(.mediaWhitePoint))
        #expect(tags.contains(.profileDescription))
        #expect(!tags.contains(.namedColor2))
        // The collection lists exactly what `contains` agrees with.
        for tag in tags { #expect(tags.contains(tag)) }
    }

    @Test func readsTypedPayloads() throws {
        let srgb = try Profile.sRGB()
        let white = try #require(srgb.tags.xyz(.mediaWhitePoint))
        #expect(abs(white.y - 1.0) < 1e-6)

        let red = try #require(srgb.tags.xyz(.redColorant))
        #expect(red.x > 0.4 && red.x < 0.5)

        let curve = try #require(srgb.tags.curve(.redTRC))
        #expect(abs(Double(curve.evaluate(Float(1.0))) - 1.0) < 1e-5)
        #expect(curve.isMonotonic)

        #expect(srgb.tags.text(.profileDescription) == "sRGB built-in")
        #expect(srgb.tags.text(.copyright) != nil)
    }

    @Test func wrongShapeAnswersNil() throws {
        let srgb = try Profile.sRGB()
        // Present, but not an XYZ tag.
        #expect(srgb.tags.xyz(.profileDescription) == nil)
        // Not present at all.
        #expect(srgb.tags.curve(.grayTRC) == nil)
        #expect(srgb.tags.text(.characterizationTarget) == nil)
        #expect(srgb.tags.signature(.technology) == nil)
    }

    @Test func writesAndReadsBack() throws {
        let profile = try Profile.sRGB()
        try profile.tags.set(.luminance, xyz: CIEXYZ(x: 1, y: 2, z: 3))
        let read = try #require(profile.tags.xyz(.luminance))
        #expect(read.y == 2)

        try profile.tags.set(.technology, signature: Signature(rawValue: 0x43_52_54_20))
        #expect(profile.tags.signature(.technology)?.description == "CRT ")

        try profile.tags.set(.profileDescription, text: "a name", language: "en", country: "US")
        #expect(profile.tags.text(.profileDescription) == "a name")

        let curve = try ToneCurve(gamma: 1.8)
        try profile.tags.set(.grayTRC, curve: curve)
        let back = try #require(profile.tags.curve(.grayTRC))
        #expect(abs(Double(back.evaluate(Float(0.5))) - Double(curve.evaluate(Float(0.5)))) < 1e-6)
    }

    @Test func survivesASaveRoundTrip() throws {
        let profile = try Profile.sRGB()
        try profile.tags.set(.profileDescription, text: "round trip")
        try profile.tags.set(.luminance, xyz: CIEXYZ(x: 0.5, y: 0.25, z: 0.125))

        let reloaded = try Profile(data: profile.save())
        #expect(reloaded.tags.text(.profileDescription) == "round trip")
        let luminance = try #require(reloaded.tags.xyz(.luminance))
        #expect(abs(luminance.z - 0.125) < 1e-4)
    }

    @Test func removalAndLinking() throws {
        let profile = try Profile.sRGB()
        #expect(profile.tags.contains(.redTRC))
        try profile.tags.remove(.redTRC)
        #expect(!profile.tags.contains(.redTRC))

        try profile.tags.set(.grayTRC, curve: ToneCurve(gamma: 2.0))
        try profile.tags.link(.redTRC, to: .grayTRC)
        #expect(profile.tags.linkTarget(.redTRC) == .grayTRC)
        #expect(profile.tags.linkTarget(.grayTRC) == nil)
    }

    @Test func translations() throws {
        let profile = try Profile.sRGB()
        try profile.tags.set(.copyright, text: "one", language: "en", country: "US")
        let locales = profile.tags.translations(.copyright)
        #expect(locales.contains { $0.language == "en" && $0.country == "US" })
    }

    @Test func rawBytesCarryTheTypeSignature() throws {
        let srgb = try Profile.sRGB()
        let raw = try #require(srgb.tags.rawData(.mediaWhitePoint))
        #expect(raw.count >= 8)
        #expect(String(decoding: raw.prefix(4), as: UTF8.self) == "XYZ ")
        #expect(srgb.tags.rawData(.namedColor2) == nil)
    }

    @Test func metadataIsEmptyWithoutTheTag() throws {
        #expect(try Profile.sRGB().tags.metadata.isEmpty)
    }
}

@Suite struct MoreTags {
    @Test func dateTimeRoundTrip() throws {
        let profile = try Profile.sRGB()
        let when = DateTime(year: 2026, month: 8, day: 25, hours: 13, minutes: 45, seconds: 5)
        try profile.tags.set(.calibrationDateTime, dateTime: when)
        #expect(profile.tags.dateTime(.calibrationDateTime) == when)

        let reloaded = try Profile(data: profile.save())
        #expect(reloaded.tags.dateTime(.calibrationDateTime) == when)
    }

    @Test func chromaticAdaptationIsAMatrix() throws {
        let srgb = try Profile.sRGB()
        guard let chad = srgb.tags.chromaticAdaptation else { return }
        #expect(chad.count == 9)
        // A sane adaptation is near the identity on the diagonal.
        #expect(abs(chad[0] - 1) < 0.2 && abs(chad[4] - 1) < 0.2)
    }
}
