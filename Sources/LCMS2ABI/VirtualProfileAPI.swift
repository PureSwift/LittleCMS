import CLCMS2
import LittleCMS

// Profiles the library makes up: built from parameters rather than read
// from a file, and useful mostly as ends of a transform — a Lab profile
// to get colours out in Lab, an RGB profile for a space with known
// primaries.  Each is a placeholder with the tags written into it.

/// The description and copyright every built-in profile carries.
private func setTextTags(_ hProfile: cmsHPROFILE?, _ description: String) -> Bool {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard let descriptionMLU = cmsMLUalloc(ContextID, 1),
          let copyrightMLU = cmsMLUalloc(ContextID, 1)
    else { return false }
    defer {
        cmsMLUfree(descriptionMLU)
        cmsMLUfree(copyrightMLU)
    }

    func setWide(_ mlu: UnsafeMutablePointer<cmsMLU>, _ text: String) -> Bool {
        var wide = text.unicodeScalars.map { wchar_t($0.value) }
        wide.append(0)
        return cmsMLUsetWide(mlu, "en", "US", &wide) != 0
    }
    if !setWide(descriptionMLU, description) { return false }
    if !setWide(copyrightMLU, "No copyright, use freely") { return false }

    if cmsWriteTag(hProfile, cmsSigProfileDescriptionTag, descriptionMLU) == 0 { return false }
    if cmsWriteTag(hProfile, cmsSigCopyrightTag, copyrightMLU) == 0 { return false }
    return true
}

/// A display-class RGB profile from a white point, primaries and
/// transfer curves — each optional, and each written only when given.
/// The white point goes in as D50 with a chromatic adaptation tag from
/// the real white; the primaries become colorants adapted to D50 and a
/// chromaticity tag; and curves that are the same object are linked
/// rather than written twice.
@c @implementation
public func cmsCreateRGBProfileTHR(
    _ ContextID: cmsContext?,
    _ WhitePoint: UnsafePointer<cmsCIExyY>?,
    _ Primaries: UnsafePointer<cmsCIExyYTRIPLE>?,
    _ TransferFunction: UnsafePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> cmsHPROFILE? {
    guard let hICC = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetProfileVersion(hICC, 4.4)
    cmsSetDeviceClass(hICC, cmsSigDisplayClass)
    cmsSetColorSpace(hICC, cmsSigRgbData)
    cmsSetPCS(hICC, cmsSigXYZData)
    cmsSetHeaderRenderingIntent(hICC, cmsUInt32Number(INTENT_PERCEPTUAL))

    if !setTextTags(hICC, "RGB built-in") { return fail() }

    if let WhitePoint {
        if cmsWriteTag(hICC, cmsSigMediaWhitePointTag, cmsD50_XYZ()) == 0 { return fail() }

        let white = engine(WhitePoint.pointee).tristimulus
        // A white that cannot be adapted leaves the matrix as whatever it
        // was — the reference ignores the failure and writes it anyway.
        var chad = cmsMAT3()
        if let m = ChromaticAdaptation.matrix(from: white, to: .d50) {
            withUnsafeMutablePointer(to: &chad) { $0.matrix = m }
        }
        if cmsWriteTag(hICC, cmsSigChromaticAdaptationTag, &chad) == 0 { return fail() }
    }

    if let WhitePoint, let Primaries {
        let maxWhite = CIExyY(x: WhitePoint.pointee.x, y: WhitePoint.pointee.y, yLuminance: 1.0)
        let primaries = RGBPrimaries(
            red: engine(Primaries.pointee.Red),
            green: engine(Primaries.pointee.Green),
            blue: engine(Primaries.pointee.Blue)
        )
        guard let m = primaries.transferMatrix(whitePoint: maxWhite) else { return fail() }

        var red = cmsCIEXYZ(X: m[0][0], Y: m[1][0], Z: m[2][0])
        var green = cmsCIEXYZ(X: m[0][1], Y: m[1][1], Z: m[2][1])
        var blue = cmsCIEXYZ(X: m[0][2], Y: m[1][2], Z: m[2][2])

        if cmsWriteTag(hICC, cmsSigRedColorantTag, &red) == 0 { return fail() }
        if cmsWriteTag(hICC, cmsSigBlueColorantTag, &blue) == 0 { return fail() }
        if cmsWriteTag(hICC, cmsSigGreenColorantTag, &green) == 0 { return fail() }
    }

    if let TransferFunction {
        if cmsWriteTag(hICC, cmsSigRedTRCTag, TransferFunction[0]) == 0 { return fail() }

        if TransferFunction[1] == TransferFunction[0] {
            if cmsLinkTag(hICC, cmsSigGreenTRCTag, cmsSigRedTRCTag) == 0 { return fail() }
        } else {
            if cmsWriteTag(hICC, cmsSigGreenTRCTag, TransferFunction[1]) == 0 { return fail() }
        }

        if TransferFunction[2] == TransferFunction[0] {
            if cmsLinkTag(hICC, cmsSigBlueTRCTag, cmsSigRedTRCTag) == 0 { return fail() }
        } else {
            if cmsWriteTag(hICC, cmsSigBlueTRCTag, TransferFunction[2]) == 0 { return fail() }
        }
    }

    if let Primaries {
        if cmsWriteTag(hICC, cmsSigChromaticityTag, Primaries) == 0 { return fail() }
    }

    return hICC
}

@c @implementation
public func cmsCreateRGBProfile(
    _ WhitePoint: UnsafePointer<cmsCIExyY>?,
    _ Primaries: UnsafePointer<cmsCIExyYTRIPLE>?,
    _ TransferFunction: UnsafePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> cmsHPROFILE? {
    cmsCreateRGBProfileTHR(nil, WhitePoint, Primaries, TransferFunction)
}

/// The identity pipeline a Lab profile carries, built by `stage`.
private func writeIdentityLUT(
    _ hProfile: cmsHPROFILE?, _ ContextID: cmsContext?,
    _ stage: (cmsContext?) -> UnsafeMutablePointer<cmsStage>?
) -> Bool {
    guard let lut = cmsPipelineAlloc(ContextID, 3, 3) else { return false }
    defer { cmsPipelineFree(lut) }
    if cmsPipelineInsertStage(lut, cmsAT_BEGIN, stage(ContextID)) == 0 { return false }
    return cmsWriteTag(hProfile, cmsSigAToB0Tag, lut) != 0
}

/// A V2 Lab identity: an abstract profile whose one LUT is an identity
/// CLUT — a CLUT so that it reads back as a 16-bit LUT and gets the V2
/// Lab treatment.
@c @implementation
public func cmsCreateLab2ProfileTHR(
    _ ContextID: cmsContext?, _ WhitePoint: UnsafePointer<cmsCIExyY>?
) -> cmsHPROFILE? {
    guard let hProfile = cmsCreateRGBProfileTHR(
        ContextID, WhitePoint ?? cmsD50_xyY(), nil, nil
    ) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hProfile)
        return nil
    }

    cmsSetProfileVersion(hProfile, 2.1)
    cmsSetDeviceClass(hProfile, cmsSigAbstractClass)
    cmsSetColorSpace(hProfile, cmsSigLabData)
    cmsSetPCS(hProfile, cmsSigLabData)

    if !setTextTags(hProfile, "Lab identity built-in") { return fail() }
    if !writeIdentityLUT(hProfile, ContextID, { _cmsStageAllocIdentityCLut($0, 3) }) { return fail() }
    return hProfile
}

@c @implementation
public func cmsCreateLab2Profile(_ WhitePoint: UnsafePointer<cmsCIExyY>?) -> cmsHPROFILE? {
    cmsCreateLab2ProfileTHR(nil, WhitePoint)
}

/// A V4 Lab identity: as above, but the LUT is identity curves and the
/// white point is written as given.
@c @implementation
public func cmsCreateLab4ProfileTHR(
    _ ContextID: cmsContext?, _ WhitePoint: UnsafePointer<cmsCIExyY>?
) -> cmsHPROFILE? {
    var xyz: cmsCIEXYZ
    if let WhitePoint {
        xyz = abi(engine(WhitePoint.pointee).tristimulus)
    } else {
        xyz = cmsD50_XYZ()!.pointee
    }

    guard let hProfile = cmsCreateRGBProfileTHR(ContextID, nil, nil, nil) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hProfile)
        return nil
    }

    cmsSetProfileVersion(hProfile, 4.4)
    cmsSetDeviceClass(hProfile, cmsSigAbstractClass)
    cmsSetColorSpace(hProfile, cmsSigLabData)
    cmsSetPCS(hProfile, cmsSigLabData)

    if cmsWriteTag(hProfile, cmsSigMediaWhitePointTag, &xyz) == 0 { return fail() }
    if !setTextTags(hProfile, "Lab identity built-in") { return fail() }
    if !writeIdentityLUT(hProfile, ContextID, { _cmsStageAllocIdentityCurves($0, 3) }) { return fail() }
    return hProfile
}

@c @implementation
public func cmsCreateLab4Profile(_ WhitePoint: UnsafePointer<cmsCIExyY>?) -> cmsHPROFILE? {
    cmsCreateLab4ProfileTHR(nil, WhitePoint)
}

// -- the rest of the built-in profiles ---------------------------------------------

/// A one-entry profile sequence naming this library as manufacturer.
private func setSeqDescTag(_ hProfile: cmsHPROFILE?, _ model: String) -> Bool {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard let seq = cmsAllocProfileSequenceDescription(ContextID, 1) else { return false }
    defer { cmsFreeProfileSequenceDescription(seq) }

    seq.pointee.seq[0].deviceMfg = cmsSignature(0)
    seq.pointee.seq[0].deviceModel = cmsSignature(0)
    seq.pointee.seq[0].attributes = 0
    seq.pointee.seq[0].technology = cmsTechnologySignature(0)

    _ = cmsMLUsetASCII(seq.pointee.seq[0].Manufacturer, cmsNoLanguage, cmsNoCountry, "Little CMS")
    _ = model.withCString { cmsMLUsetASCII(seq.pointee.seq[0].Model, cmsNoLanguage, cmsNoCountry, $0) }

    return _cmsWriteProfileSequence(hProfile, seq)
}

/// A display-class grey profile: a white point and a curve, each
/// written only when given.
@c @implementation
public func cmsCreateGrayProfileTHR(
    _ ContextID: cmsContext?,
    _ WhitePoint: UnsafePointer<cmsCIExyY>?,
    _ TransferFunction: UnsafePointer<cmsToneCurve>?
) -> cmsHPROFILE? {
    guard let hICC = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetProfileVersion(hICC, 4.4)
    cmsSetDeviceClass(hICC, cmsSigDisplayClass)
    cmsSetColorSpace(hICC, cmsSigGrayData)
    cmsSetPCS(hICC, cmsSigXYZData)
    cmsSetHeaderRenderingIntent(hICC, cmsUInt32Number(INTENT_PERCEPTUAL))

    if !setTextTags(hICC, "gray built-in") { return fail() }

    if let WhitePoint {
        var tmp = abi(engine(WhitePoint.pointee).tristimulus)
        if cmsWriteTag(hICC, cmsSigMediaWhitePointTag, &tmp) == 0 { return fail() }
    }
    if let TransferFunction {
        if cmsWriteTag(hICC, cmsSigGrayTRCTag, TransferFunction) == 0 { return fail() }
    }
    return hICC
}

@c @implementation
public func cmsCreateGrayProfile(
    _ WhitePoint: UnsafePointer<cmsCIExyY>?, _ TransferFunction: UnsafePointer<cmsToneCurve>?
) -> cmsHPROFILE? {
    cmsCreateGrayProfileTHR(nil, WhitePoint, TransferFunction)
}

/// A devicelink in one space that applies a curve per channel and
/// nothing else.
@c @implementation
public func cmsCreateLinearizationDeviceLinkTHR(
    _ ContextID: cmsContext?,
    _ ColorSpace: cmsColorSpaceSignature,
    _ TransferFunctions: UnsafePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> cmsHPROFILE? {
    guard let hICC = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetProfileVersion(hICC, 4.4)
    cmsSetDeviceClass(hICC, cmsSigLinkClass)
    cmsSetColorSpace(hICC, ColorSpace)
    cmsSetPCS(hICC, ColorSpace)
    cmsSetHeaderRenderingIntent(hICC, cmsUInt32Number(INTENT_PERCEPTUAL))

    let nChannels = cmsUInt32Number(bitPattern: cmsChannelsOfColorSpace(ColorSpace))
    guard let pipeline = cmsPipelineAlloc(ContextID, nChannels, nChannels) else { return fail() }
    defer { cmsPipelineFree(pipeline) }

    if cmsPipelineInsertStage(pipeline, cmsAT_BEGIN, cmsStageAllocToneCurves(ContextID, nChannels, TransferFunctions)) == 0 {
        return fail()
    }
    if !setTextTags(hICC, "Linearization built-in") { return fail() }
    if cmsWriteTag(hICC, cmsSigAToB0Tag, pipeline) == 0 { return fail() }
    if !setSeqDescTag(hICC, "Linearization built-in") { return fail() }
    return hICC
}

@c @implementation
public func cmsCreateLinearizationDeviceLink(
    _ ColorSpace: cmsColorSpaceSignature,
    _ TransferFunctions: UnsafePointer<UnsafeMutablePointer<cmsToneCurve>?>?
) -> cmsHPROFILE? {
    cmsCreateLinearizationDeviceLinkTHR(nil, ColorSpace, TransferFunctions)
}

/// The ink-limiting rule: when the four inks sum past the limit, CMY are
/// scaled down together and K is left alone.
private func inkLimitingSampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let inkLimit = Cargo.assumingMemoryBound(to: cmsFloat64Number.self).pointee * 655.35
    let sumCMY = Double(In[0]) + Double(In[1]) + Double(In[2])
    let sumCMYK = sumCMY + Double(In[3])

    var ratio: Double
    if sumCMYK > inkLimit && sumCMY > 0 {
        ratio = 1 - ((sumCMYK - inkLimit) / sumCMY)
        if ratio < 0 { ratio = 0 }
    } else {
        ratio = 1
    }
    Out[0] = quickSaturateWord(Double(In[0]) * ratio)
    Out[1] = quickSaturateWord(Double(In[1]) * ratio)
    Out[2] = quickSaturateWord(Double(In[2]) * ratio)
    Out[3] = In[3]
    return 1
}

/// A CMYK devicelink that limits total ink to a percentage of 400.
@c @implementation
public func cmsCreateInkLimitingDeviceLinkTHR(
    _ ContextID: cmsContext?, _ ColorSpace: cmsColorSpaceSignature, _ Limit: cmsFloat64Number
) -> cmsHPROFILE? {
    if ColorSpace != cmsSigCmykData {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "InkLimiting: Only CMYK currently supported", to: ContextID)
        return nil
    }
    var limit = Limit
    if limit < 1.0 || limit > 400 {
        report(cmsUInt32Number(cmsERROR_RANGE), "InkLimiting: Limit should be between 1..400", to: ContextID)
        if limit < 1 { limit = 1 }
        if limit > 400 { limit = 400 }
    }

    guard let hICC = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetProfileVersion(hICC, 4.4)
    cmsSetDeviceClass(hICC, cmsSigLinkClass)
    cmsSetColorSpace(hICC, ColorSpace)
    cmsSetPCS(hICC, ColorSpace)
    cmsSetHeaderRenderingIntent(hICC, cmsUInt32Number(INTENT_PERCEPTUAL))

    guard let lut = cmsPipelineAlloc(ContextID, 4, 4) else { return fail() }
    defer { cmsPipelineFree(lut) }

    let nChannels = cmsChannelsOf(ColorSpace)
    guard let clut = cmsStageAllocCLut16bit(ContextID, 17, nChannels, nChannels, nil) else { return fail() }
    if cmsStageSampleCLut16bit(clut, inkLimitingSampler, &limit, 0) == 0 {
        cmsStageFree(clut)
        return fail()
    }
    if cmsPipelineInsertStage(lut, cmsAT_BEGIN, _cmsStageAllocIdentityCurves(ContextID, nChannels)) == 0
        || cmsPipelineInsertStage(lut, cmsAT_END, clut) == 0
        || cmsPipelineInsertStage(lut, cmsAT_END, _cmsStageAllocIdentityCurves(ContextID, nChannels)) == 0
    {
        return fail()
    }

    if !setTextTags(hICC, "ink-limiting built-in") { return fail() }
    if cmsWriteTag(hICC, cmsSigAToB0Tag, lut) == 0 { return fail() }
    if !setSeqDescTag(hICC, "ink-limiting built-in") { return fail() }
    return hICC
}

@c @implementation
public func cmsCreateInkLimitingDeviceLink(
    _ ColorSpace: cmsColorSpaceSignature, _ Limit: cmsFloat64Number
) -> cmsHPROFILE? {
    cmsCreateInkLimitingDeviceLinkTHR(nil, ColorSpace, Limit)
}

/// An XYZ identity: an abstract profile whose LUT is identity curves.
@c @implementation
public func cmsCreateXYZProfileTHR(_ ContextID: cmsContext?) -> cmsHPROFILE? {
    guard let hProfile = cmsCreateRGBProfileTHR(ContextID, cmsD50_xyY(), nil, nil) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hProfile)
        return nil
    }

    cmsSetProfileVersion(hProfile, 4.4)
    cmsSetDeviceClass(hProfile, cmsSigAbstractClass)
    cmsSetColorSpace(hProfile, cmsSigXYZData)
    cmsSetPCS(hProfile, cmsSigXYZData)

    if !setTextTags(hProfile, "XYZ identity built-in") { return fail() }
    if !writeIdentityLUT(hProfile, ContextID, { _cmsStageAllocIdentityCurves($0, 3) }) { return fail() }
    return hProfile
}

@c @implementation
public func cmsCreateXYZProfile() -> cmsHPROFILE? {
    cmsCreateXYZProfileTHR(nil)
}

/// The sRGB transfer curve as a type-4 parametric: linear below 0.04045,
/// a 2.4 power above.
private func buildsRGBGamma(_ ContextID: cmsContext?) -> UnsafeMutablePointer<cmsToneCurve>? {
    var parameters: [cmsFloat64Number] = [2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045]
    return cmsBuildParametricToneCurve(ContextID, 4, &parameters)
}

/// sRGB: Rec.709 primaries under D65 with the sRGB curve on all three
/// channels — one curve, so the green and blue tags link to red.
@c @implementation
public func cmsCreate_sRGBProfileTHR(_ ContextID: cmsContext?) -> cmsHPROFILE? {
    var d65 = cmsCIExyY(x: 0.3127, y: 0.3290, Y: 1.0)
    var rec709 = cmsCIExyYTRIPLE(
        Red: cmsCIExyY(x: 0.6400, y: 0.3300, Y: 1.0),
        Green: cmsCIExyY(x: 0.3000, y: 0.6000, Y: 1.0),
        Blue: cmsCIExyY(x: 0.1500, y: 0.0600, Y: 1.0)
    )
    guard let gamma = buildsRGBGamma(ContextID) else { return nil }
    var curves: [UnsafeMutablePointer<cmsToneCurve>?] = [gamma, gamma, gamma]

    let hsRGB = cmsCreateRGBProfileTHR(ContextID, &d65, &rec709, &curves)
    cmsFreeToneCurve(gamma)
    guard let hsRGB else { return nil }

    if !setTextTags(hsRGB, "sRGB built-in") {
        cmsCloseProfile(hsRGB)
        return nil
    }
    return hsRGB
}

@c @implementation
public func cmsCreate_sRGBProfile() -> cmsHPROFILE? {
    cmsCreate_sRGBProfileTHR(nil)
}

/// OkLab, as a colour-space-class profile whose LUTs go through D65 and
/// LMS with a cube-root nonlinearity.  Experimental in the reference and
/// not saveable as a file — the float normalisation stages have no tag
/// type — but usable as a transform end.
@c @implementation
public func cmsCreate_OkLabProfile(_ ctx: cmsContext?) -> cmsHPROFILE? {
    let d65ToD50: [cmsFloat64Number] = [
        1.047886, 0.022919, -0.050216,
        0.029582, 0.990484, -0.017079,
        -0.009252, 0.015073, 0.751678,
    ]
    let d50ToD65: [cmsFloat64Number] = [
        0.955512609517083, -0.023073214184645, 0.063308961782107,
        -0.028324949364887, 1.009942432477107, 0.021054814890112,
        0.012328875695483, -0.020535835374141, 1.330713916450354,
    ]
    let d65ToLMS: [cmsFloat64Number] = [
        0.8189330101, 0.3618667424, -0.1288597137,
        0.0329845436, 0.9293118715, 0.0361456387,
        0.0482003018, 0.2643662691, 0.6338517070,
    ]
    let lmsToD65: [cmsFloat64Number] = [
        1.227013851103521, -0.557799980651822, 0.281256148966468,
        -0.040580178423281, 1.112256869616830, -0.071676678665601,
        -0.076381284505707, -0.421481978418013, 1.586163220440795,
    ]
    let lmsPrimeToOkLab: [cmsFloat64Number] = [
        0.2104542553, 0.7936177850, -0.0040720468,
        1.9779984951, -2.4285922050, 0.4505937099,
        0.0259040371, 0.7827717662, -0.8086757660,
    ]
    let okLabToLMSPrime: [cmsFloat64Number] = [
        0.999999998450520, 0.396337792173768, 0.215803758060759,
        1.000000008881761, -0.105561342323656, -0.063854174771706,
        1.000000054672411, -0.089484182094966, -1.291485537864092,
    ]
    func matrix(_ m: [cmsFloat64Number]) -> UnsafeMutablePointer<cmsStage>? {
        m.withUnsafeBufferPointer { cmsStageAllocMatrix(ctx, 3, 3, $0.baseAddress, nil) }
    }

    let cubeRoot = cmsBuildGamma(ctx, 1.0 / 3.0)
    let cube = cmsBuildGamma(ctx, 3.0)
    defer {
        cmsFreeToneCurve(cubeRoot)
        cmsFreeToneCurve(cube)
    }
    var roots: [UnsafeMutablePointer<cmsToneCurve>?] = [cubeRoot, cubeRoot, cubeRoot]
    var cubes: [UnsafeMutablePointer<cmsToneCurve>?] = [cube, cube, cube]

    let aToB = cmsPipelineAlloc(ctx, 3, 3)
    let bToA = cmsPipelineAlloc(ctx, 3, 3)
    defer {
        cmsPipelineFree(bToA)
        cmsPipelineFree(aToB)
    }
    guard let hProfile = cmsCreateProfilePlaceholder(ctx) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hProfile)
        return nil
    }

    cmsSetProfileVersion(hProfile, 4.4)
    cmsSetDeviceClass(hProfile, cmsSigColorSpaceClass)
    cmsSetColorSpace(hProfile, cmsSig3colorData)
    cmsSetPCS(hProfile, cmsSigXYZData)
    cmsSetHeaderRenderingIntent(hProfile, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC))

    // PCS (XYZ, D50) to OkLab.
    for stage in [
        _cmsStageNormalizeToXyzFloat(ctx), matrix(d50ToD65), matrix(d65ToLMS),
        cmsStageAllocToneCurves(ctx, 3, &roots), matrix(lmsPrimeToOkLab),
    ] {
        if cmsPipelineInsertStage(bToA, cmsAT_END, stage) == 0 { return fail() }
    }
    if cmsWriteTag(hProfile, cmsSigBToA0Tag, bToA) == 0 { return fail() }

    for stage in [
        matrix(okLabToLMSPrime), cmsStageAllocToneCurves(ctx, 3, &cubes), matrix(lmsToD65),
        matrix(d65ToD50), _cmsStageNormalizeFromXyzFloat(ctx),
    ] {
        if cmsPipelineInsertStage(aToB, cmsAT_END, stage) == 0 { return fail() }
    }
    if cmsWriteTag(hProfile, cmsSigAToB0Tag, aToB) == 0 { return fail() }
    return hProfile
}

/// The knobs of the brightness/contrast/hue/saturation abstract profile,
/// with the two white points when a temperature shift is asked.
private struct BCHSWAdjusts {
    var brightness: Double
    var contrast: Double
    var hue: Double
    var saturation: Double
    var adjustWhitePoint: Bool
    var whiteSource = cmsCIEXYZ()
    var whiteDestination = cmsCIEXYZ()
}

private func bchswSampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let bchsw = Cargo.assumingMemoryBound(to: BCHSWAdjusts.self)

    var labIn = cmsCIELab()
    cmsLabEncoded2Float(&labIn, In)
    var lchIn = cmsCIELCh()
    cmsLab2LCh(&lchIn, &labIn)

    var lchOut = cmsCIELCh(
        L: lchIn.L * bchsw.pointee.contrast + bchsw.pointee.brightness,
        C: lchIn.C + bchsw.pointee.saturation,
        h: lchIn.h + bchsw.pointee.hue
    )
    var labOut = cmsCIELab()
    cmsLCh2Lab(&labOut, &lchOut)

    if bchsw.pointee.adjustWhitePoint {
        var xyz = cmsCIEXYZ()
        cmsLab2XYZ(&bchsw.pointee.whiteSource, &xyz, &labOut)
        cmsXYZ2Lab(&bchsw.pointee.whiteDestination, &labOut, &xyz)
    }
    cmsFloat2LabEncoded(Out, &labOut)
    return 1
}

/// An abstract Lab-to-Lab profile applying brightness, contrast, hue and
/// saturation, and a white point shift between two temperatures.
@c @implementation
public func cmsCreateBCHSWabstractProfileTHR(
    _ ContextID: cmsContext?,
    _ nLUTPoints: cmsUInt32Number,
    _ Bright: cmsFloat64Number, _ Contrast: cmsFloat64Number,
    _ Hue: cmsFloat64Number, _ Saturation: cmsFloat64Number,
    _ TempSrc: cmsUInt32Number, _ TempDest: cmsUInt32Number
) -> cmsHPROFILE? {
    var bchsw = BCHSWAdjusts(
        brightness: Bright, contrast: Contrast, hue: Hue, saturation: Saturation,
        adjustWhitePoint: TempSrc != TempDest
    )
    if bchsw.adjustWhitePoint {
        var white = cmsCIExyY()
        // The reference does not check either answer; an out-of-range
        // temperature leaves the white as it was.
        _ = cmsWhitePointFromTemp(&white, cmsFloat64Number(TempSrc))
        bchsw.whiteSource = abi(engine(white).tristimulus)
        _ = cmsWhitePointFromTemp(&white, cmsFloat64Number(TempDest))
        bchsw.whiteDestination = abi(engine(white).tristimulus)
    }

    guard let hICC = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetDeviceClass(hICC, cmsSigAbstractClass)
    cmsSetColorSpace(hICC, cmsSigLabData)
    cmsSetPCS(hICC, cmsSigLabData)
    cmsSetHeaderRenderingIntent(hICC, cmsUInt32Number(INTENT_PERCEPTUAL))

    guard let pipeline = cmsPipelineAlloc(ContextID, 3, 3) else { return fail() }
    defer { cmsPipelineFree(pipeline) }

    var dimensions = [cmsUInt32Number](repeating: nLUTPoints, count: Int(MAX_INPUT_DIMENSIONS))
    guard let clut = cmsStageAllocCLut16bitGranular(ContextID, &dimensions, 3, 3, nil) else { return fail() }
    if cmsStageSampleCLut16bit(clut, bchswSampler, &bchsw, 0) == 0 {
        cmsStageFree(clut)
        return fail()
    }
    if cmsPipelineInsertStage(pipeline, cmsAT_END, clut) == 0 { return fail() }

    if !setTextTags(hICC, "BCHS built-in") { return fail() }
    if cmsWriteTag(hICC, cmsSigMediaWhitePointTag, cmsD50_XYZ()) == 0 { return fail() }
    if cmsWriteTag(hICC, cmsSigAToB0Tag, pipeline) == 0 { return fail() }
    return hICC
}

@c @implementation
public func cmsCreateBCHSWabstractProfile(
    _ nLUTPoints: cmsUInt32Number,
    _ Bright: cmsFloat64Number, _ Contrast: cmsFloat64Number,
    _ Hue: cmsFloat64Number, _ Saturation: cmsFloat64Number,
    _ TempSrc: cmsUInt32Number, _ TempDest: cmsUInt32Number
) -> cmsHPROFILE? {
    cmsCreateBCHSWabstractProfileTHR(nil, nLUTPoints, Bright, Contrast, Hue, Saturation, TempSrc, TempDest)
}

/// A grey output profile whose one channel is always zero — a device
/// nothing reaches, useful for gamut checking.
@c @implementation
public func cmsCreateNULLProfileTHR(_ ContextID: cmsContext?) -> cmsHPROFILE? {
    guard let hProfile = cmsCreateProfilePlaceholder(ContextID) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hProfile)
        return nil
    }

    cmsSetProfileVersion(hProfile, 4.4)
    if !setTextTags(hProfile, "NULL profile built-in") { return fail() }
    cmsSetDeviceClass(hProfile, cmsSigOutputClass)
    cmsSetColorSpace(hProfile, cmsSigGrayData)
    cmsSetPCS(hProfile, cmsSigLabData)

    guard let lut = cmsPipelineAlloc(ContextID, 3, 1) else { return fail() }
    defer { cmsPipelineFree(lut) }

    var zero: [cmsUInt16Number] = [0, 0]
    let emptyTab = cmsBuildTabulatedToneCurve16(ContextID, 2, &zero)
    var three: [UnsafeMutablePointer<cmsToneCurve>?] = [emptyTab, emptyTab, emptyTab]
    let postLin = cmsStageAllocToneCurves(ContextID, 3, &three)
    let outLin = cmsStageAllocToneCurves(ContextID, 1, &three)
    cmsFreeToneCurve(emptyTab)

    let pickLstar: [cmsFloat64Number] = [1, 0, 0]
    if cmsPipelineInsertStage(lut, cmsAT_END, postLin) == 0 { return fail() }
    if cmsPipelineInsertStage(lut, cmsAT_END, pickLstar.withUnsafeBufferPointer {
        cmsStageAllocMatrix(ContextID, 1, 3, $0.baseAddress, nil)
    }) == 0 { return fail() }
    if cmsPipelineInsertStage(lut, cmsAT_END, outLin) == 0 { return fail() }

    if cmsWriteTag(hProfile, cmsSigBToA0Tag, lut) == 0 { return fail() }
    if cmsWriteTag(hProfile, cmsSigMediaWhitePointTag, cmsD50_XYZ()) == 0 { return fail() }
    return hProfile
}

@c @implementation
public func cmsCreateNULLProfile() -> cmsHPROFILE? {
    cmsCreateNULLProfileTHR(nil)
}

// -- a transform as a profile ----------------------------------------------------

private func isPCS(_ space: cmsColorSpaceSignature) -> Bool {
    space == cmsSigXYZData || space == cmsSigLabData
}

/// The class and spaces a devicelink gets — or, when asked to guess,
/// whatever class the two ends imply: abstract between two PCSs, output
/// from a PCS, input into one.
private func fixColorSpaces(
    _ hProfile: cmsHPROFILE?, _ colorSpace: cmsColorSpaceSignature, _ pcs: cmsColorSpaceSignature,
    _ dwFlags: cmsUInt32Number
) {
    if dwFlags & cmsUInt32Number(cmsFLAGS_GUESSDEVICECLASS) != 0 {
        if isPCS(colorSpace) && isPCS(pcs) {
            cmsSetDeviceClass(hProfile, cmsSigAbstractClass)
            cmsSetColorSpace(hProfile, colorSpace)
            cmsSetPCS(hProfile, pcs)
            return
        }
        if isPCS(colorSpace) && !isPCS(pcs) {
            cmsSetDeviceClass(hProfile, cmsSigOutputClass)
            cmsSetPCS(hProfile, colorSpace)
            cmsSetColorSpace(hProfile, pcs)
            return
        }
        if isPCS(pcs) && !isPCS(colorSpace) {
            cmsSetDeviceClass(hProfile, cmsSigInputClass)
            cmsSetColorSpace(hProfile, colorSpace)
            cmsSetPCS(hProfile, pcs)
            return
        }
    }
    cmsSetDeviceClass(hProfile, cmsSigLinkClass)
    cmsSetColorSpace(hProfile, colorSpace)
    cmsSetPCS(hProfile, pcs)
}

/// A named colour transform dumped as a named colour profile: every
/// colour's colorant is what the transform makes of its index.
private func createNamedColorDevicelink(_ xform: cmsHTRANSFORM) -> cmsHPROFILE? {
    guard let box = transform(xform.assumingMemoryBound(to: _cmstransform_struct.self)) else { return nil }
    guard let hICC = cmsCreateProfilePlaceholder(box.context) else { return nil }
    func fail() -> cmsHPROFILE? {
        cmsCloseProfile(hICC)
        return nil
    }

    cmsSetDeviceClass(hICC, cmsSigNamedColorClass)
    cmsSetColorSpace(hICC, box.exitColorSpace)
    cmsSetPCS(hICC, cmsSigLabData)

    if !setTextTags(hICC, "Named color devicelink") { return fail() }
    guard let original = cmsGetNamedColorList(xform) else { return fail() }
    let nColors = cmsNamedColorCount(original)

    // A copy with the colorant count of the output space.
    let source = namedColorBox(original)
    guard let list = NamedColorList(
        colorantCount: Int(cmsPipelineOutputChannels(box.lut)),
        prefix: source.list.prefix, suffix: source.list.suffix, reserving: source.list.colors.count
    ) else { return fail() }
    let nc2 = NamedColorListBox(list, context: source.context)

    let exitSpace = box.exitColorSpace
    _ = cmsChangeBuffersFormat(
        xform, SLCMS_TYPE_NAMED_COLOR_INDEX,
        floatSH(0) | colorSpaceSH(cmsUInt32Number(bitPattern: _cmsLCMScolorSpace(exitSpace)))
            | bytesSH(2) | channelsSH(cmsUInt32Number(bitPattern: cmsChannelsOfColorSpace(exitSpace)))
    )

    for i in 0..<Int(nColors) {
        var index = cmsUInt32Number(i)
        var colorant = [cmsUInt16Number](repeating: 0, count: maximumChannels)
        cmsDoTransform(xform, &index, &colorant, 1)
        let color = source.list.colors[i]
        list.append(name: color.name, pcs: color.pcs, colorant: colorant)
    }

    let handle = NamedColorListBox.handle(for: nc2).assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
    defer { cmsFreeNamedColorList(handle) }
    if cmsWriteTag(hICC, cmsSigNamedColor2Tag, handle) == 0 { return fail() }
    return hICC
}

/// The stage sequences a LUT tag can store, per version and tag.
private struct AllowedLUT {
    let isV4: Bool
    let requiredTag: cmsTagSignature?
    let stages: [cmsStageSignature]
}

private let allowedLUTTypes: [AllowedLUT] = [
    AllowedLUT(isV4: false, requiredTag: nil, stages: [cmsSigMatrixElemType, cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: false, requiredTag: nil, stages: [cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: false, requiredTag: nil, stages: [cmsSigCurveSetElemType, cmsSigCLutElemType]),
    AllowedLUT(isV4: true, requiredTag: nil, stages: [cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigAToB0Tag, stages: [cmsSigCurveSetElemType, cmsSigMatrixElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigAToB0Tag, stages: [cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigAToB0Tag, stages: [cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType, cmsSigMatrixElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigBToA0Tag, stages: [cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigBToA0Tag, stages: [cmsSigCurveSetElemType, cmsSigMatrixElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigBToA0Tag, stages: [cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType]),
    AllowedLUT(isV4: true, requiredTag: cmsSigBToA0Tag, stages: [cmsSigCurveSetElemType, cmsSigMatrixElemType, cmsSigCurveSetElemType, cmsSigCLutElemType, cmsSigCurveSetElemType]),
]

private func stageTypes(_ lut: UnsafeMutablePointer<cmsPipeline>?) -> [cmsStageSignature] {
    var types: [cmsStageSignature] = []
    var s = cmsPipelineGetPtrToFirstStage(lut)
    while let stage = s {
        types.append(cmsStageType(stage))
        s = cmsStageNext(stage)
    }
    return types
}

private func findCombination(
    _ lut: UnsafeMutablePointer<cmsPipeline>?, isV4: Bool, destinationTag: cmsTagSignature
) -> AllowedLUT? {
    let types = stageTypes(lut)
    return allowedLUTTypes.first { tab in
        if tab.isV4 != isV4 { return false }
        if let required = tab.requiredTag, required != destinationTag { return false }
        return tab.stages == types
    }
}

/// A transform written out as a devicelink (or, when asked to guess and
/// the ends allow it, an input, output or abstract profile).  The
/// pipeline must be one a LUT tag can hold; when it is not, the
/// optimizer is asked to resample it into one, and a version-2 Lab end
/// gets its rescaling as curves.
@c @implementation
public func cmsTransform2DeviceLink(
    _ hTransform: cmsHTRANSFORM?, _ Version: cmsFloat64Number, _ dwFlags: cmsUInt32Number
) -> cmsHPROFILE? {
    guard let hTransform, let box = transform(hTransform.assumingMemoryBound(to: _cmstransform_struct.self)),
          let xformLut = box.lut
    else { return nil }
    let ContextID = box.context
    var dwFlags = dwFlags

    if let first = cmsPipelineGetPtrToFirstStage(xformLut), cmsStageType(first) == cmsSigNamedColorElemType {
        return createNamedColorDevicelink(hTransform)
    }

    var lut: UnsafeMutablePointer<cmsPipeline>? = cmsPipelineDup(xformLut)
    guard lut != nil else { return nil }
    var hProfile: cmsHPROFILE?
    func fail() -> cmsHPROFILE? {
        cmsPipelineFree(lut)
        if let hProfile { cmsCloseProfile(hProfile) }
        return nil
    }

    // A V2 profile carries Lab in the V2 encoding at both ends.
    if box.entryColorSpace == cmsSigLabData && Version < 4.0 {
        if cmsPipelineInsertStage(lut, cmsAT_BEGIN, _cmsStageAllocLabV2ToV4curves(ContextID)) == 0 { return fail() }
    }
    if box.exitColorSpace == cmsSigLabData && Version < 4.0 {
        dwFlags |= cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP)
        if cmsPipelineInsertStage(lut, cmsAT_END, _cmsStageAllocLabV4ToV2(ContextID)) == 0 { return fail() }
    }

    hProfile = cmsCreateProfilePlaceholder(ContextID)
    guard hProfile != nil else { return fail() }
    cmsSetProfileVersion(hProfile, Version)
    fixColorSpaces(hProfile, box.entryColorSpace, box.exitColorSpace, dwFlags)

    let chansIn = cmsChannelsOfColorSpace(box.entryColorSpace)
    let chansOut = cmsChannelsOfColorSpace(box.exitColorSpace)
    var frmIn = colorSpaceSH(cmsUInt32Number(bitPattern: _cmsLCMScolorSpace(box.entryColorSpace)))
        | channelsSH(cmsUInt32Number(bitPattern: chansIn)) | bytesSH(2)
    var frmOut = colorSpaceSH(cmsUInt32Number(bitPattern: _cmsLCMScolorSpace(box.exitColorSpace)))
        | channelsSH(cmsUInt32Number(bitPattern: chansOut)) | bytesSH(2)

    let deviceClass = cmsGetDeviceClass(hProfile)
    let destinationTag = deviceClass == cmsSigOutputClass ? cmsSigBToA0Tag : cmsSigAToB0Tag
    let isV4 = Version >= 4.0

    var allowed: AllowedLUT? = dwFlags & cmsUInt32Number(cmsFLAGS_FORCE_CLUT) != 0
        ? nil : findCombination(lut, isV4: isV4, destinationTag: destinationTag)

    if allowed == nil {
        _ = _cmsOptimizePipeline(ContextID, &lut, box.renderingIntent, &frmIn, &frmOut, &dwFlags)
        allowed = findCombination(lut, isV4: isV4, destinationTag: destinationTag)
    }

    if allowed == nil {
        // Force a CLUT, which can always be written, and pad with
        // identity curves where the tag wants them.
        dwFlags |= cmsUInt32Number(cmsFLAGS_FORCE_CLUT)
        _ = _cmsOptimizePipeline(ContextID, &lut, box.renderingIntent, &frmIn, &frmOut, &dwFlags)

        if let first = cmsPipelineGetPtrToFirstStage(lut), cmsStageType(first) != cmsSigCurveSetElemType {
            if cmsPipelineInsertStage(lut, cmsAT_BEGIN, _cmsStageAllocIdentityCurves(ContextID, cmsUInt32Number(bitPattern: chansIn))) == 0 {
                return fail()
            }
        }
        if let last = cmsPipelineGetPtrToLastStage(lut), cmsStageType(last) != cmsSigCurveSetElemType {
            if cmsPipelineInsertStage(lut, cmsAT_END, _cmsStageAllocIdentityCurves(ContextID, cmsUInt32Number(bitPattern: chansOut))) == 0 {
                return fail()
            }
        }
        allowed = findCombination(lut, isV4: isV4, destinationTag: destinationTag)
    }

    guard allowed != nil else { return fail() }

    if dwFlags & cmsUInt32Number(cmsFLAGS_8BITS_DEVICELINK) != 0 {
        cmsPipelineSetSaveAs8bitsFlag(lut, 1)
    }

    if !setTextTags(hProfile, "devicelink") { return fail() }
    if cmsWriteTag(hProfile, destinationTag, lut) == 0 { return fail() }

    if let colorant = box.inputColorant, deviceClass == cmsSigLinkClass || deviceClass == cmsSigInputClass {
        if cmsWriteTag(hProfile, cmsSigColorantTableTag, colorant) == 0 { return fail() }
    }
    if let colorant = box.outputColorant {
        let tag = deviceClass == cmsSigLinkClass ? cmsSigColorantTableOutTag : cmsSigColorantTableTag
        if cmsWriteTag(hProfile, tag, colorant) == 0 { return fail() }
    }
    if deviceClass == cmsSigLinkClass, let sequence = box.sequence {
        if !_cmsWriteProfileSequence(hProfile, sequence) { return fail() }
    }

    var white = deviceClass == cmsSigInputClass ? box.entryWhitePoint : box.exitWhitePoint
    if cmsWriteTag(hProfile, cmsSigMediaWhitePointTag, &white) == 0 { return fail() }

    // Per 7.2.15 of the V4 spec.
    cmsSetHeaderRenderingIntent(hProfile, box.renderingIntent)
    cmsPipelineFree(lut)
    return hProfile
}
