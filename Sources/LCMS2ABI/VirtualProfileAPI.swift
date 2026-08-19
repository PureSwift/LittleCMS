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
