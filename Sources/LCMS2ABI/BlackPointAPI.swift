import CLCMS2
import LittleCMSCore

// Finding a profile's black point, for black point compensation.
//
// A profile rarely says its black point outright — the tag for it is
// deprecated and, where present, mostly wrong — so it is measured: the
// darkest colorant is pushed through the profile to Lab, or a ramp of
// L* is round-tripped through it and the knee of the curve found.  The
// answer is turned neutral and clipped to L* ≤ 50, since a black point
// with chroma tints everything compensated against it.

/// The darkest and lightest colorants of the common spaces, in the
/// 16-bit encoding.  `_cmsEndPointsBySpace`.
func endPointsBySpace(_ space: cmsColorSpaceSignature) -> (white: [UInt16], black: [UInt16])? {
    switch space {
    case cmsSigGrayData: return ([0xFFFF], [0])
    case cmsSigRgbData: return ([0xFFFF, 0xFFFF, 0xFFFF], [0, 0, 0])
    case cmsSigLabData: return ([0xFFFF, 0x8080, 0x8080], [0, 0x8080, 0x8080])
    case cmsSigCmykData: return ([0, 0, 0, 0], [0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF])
    case cmsSigCmyData: return ([0, 0, 0], [0xFFFF, 0xFFFF, 0xFFFF])
    default: return nil
    }
}

/// A layout word for the profile's colour space at a width — no
/// swaps, no extras — or zero for a space with no channel count.
@c @implementation
public func cmsFormatterForColorspaceOfProfile(
    _ hProfile: cmsHPROFILE?, _ nBytes: cmsUInt32Number, _ lIsFloat: cmsBool
) -> cmsUInt32Number {
    formatter(for: cmsGetColorSpace(hProfile), nBytes, lIsFloat)
}

/// The same for the profile's PCS.
@c @implementation
public func cmsFormatterForPCSOfProfile(
    _ hProfile: cmsHPROFILE?, _ nBytes: cmsUInt32Number, _ lIsFloat: cmsBool
) -> cmsUInt32Number {
    formatter(for: cmsGetPCS(hProfile), nBytes, lIsFloat)
}

private func formatter(
    for space: cmsColorSpaceSignature, _ nBytes: cmsUInt32Number, _ lIsFloat: cmsBool
) -> cmsUInt32Number {
    let bits = cmsUInt32Number(bitPattern: _cmsLCMScolorSpace(space))
    let channels = cmsChannelsOfColorSpace(space)
    if channels < 0 { return 0 }
    return floatSH(lIsFloat != 0 ? 1 : 0) | colorSpaceSH(bits) | bytesSH(nBytes & 7)
        | channelsSH(cmsUInt32Number(channels))
}

private let noBlack = cmsCIEXYZ(X: 0, Y: 0, Z: 0)
private let perceptualBlack = cmsCIEXYZ(X: cmsPERCEPTUAL_BLACK_X, Y: cmsPERCEPTUAL_BLACK_Y, Z: cmsPERCEPTUAL_BLACK_Z)

/// Lab through the profile and back, PCS to PCS, with relative
/// colorimetric on the way back in.
private func createRoundtripXForm(_ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number) -> cmsHTRANSFORM? {
    let ContextID = cmsGetProfileContextID(hProfile)
    let hLab = cmsCreateLab4ProfileTHR(ContextID, nil)
    defer { cmsCloseProfile(hLab) }

    var profiles: [cmsHPROFILE?] = [hLab, hProfile, hProfile, hLab]
    var intents: [cmsUInt32Number] = [
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), intent,
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC),
    ]
    var bpc: [cmsBool] = [0, 0, 0, 0]
    var states: [cmsFloat64Number] = [1.0, 1.0, 1.0, 1.0]

    return cmsCreateExtendedTransform(
        ContextID, 4, &profiles, &bpc, &intents, &states, nil, 0,
        SLCMS_TYPE_Lab_DBL, SLCMS_TYPE_Lab_DBL,
        cmsUInt32Number(cmsFLAGS_NOCACHE | cmsFLAGS_NOOPTIMIZE)
    )
}

/// The darkest colorant through the profile in the input direction,
/// which takes more ink to mean darker.  L* is clipped to at most 50,
/// and a synthetic negative profile — black lighter than 95 — reads as
/// zero.  False, and a black of zero, when the profile cannot be read
/// that way.
private func blackPointAsDarkerColorant(
    _ hInput: cmsHPROFILE?, _ intent: cmsUInt32Number,
    _ blackPoint: UnsafeMutablePointer<cmsCIEXYZ>
) -> Bool {
    let ContextID = cmsGetProfileContextID(hInput)

    if cmsIsIntentSupported(hInput, intent, cmsUInt32Number(LCMS_USED_AS_INPUT)) == 0 {
        blackPoint.pointee = noBlack
        return false
    }

    let format = cmsFormatterForColorspaceOfProfile(hInput, 2, 0)
    guard let ends = endPointsBySpace(cmsGetColorSpace(hInput)),
          ends.black.count == PixelFormat(format).channels
    else {
        blackPoint.pointee = noBlack
        return false
    }

    // Lab is the output, but the V2 profile so as not to recurse.
    guard let hLab = cmsCreateLab2ProfileTHR(ContextID, nil) else {
        blackPoint.pointee = noBlack
        return false
    }
    let xform = cmsCreateTransformTHR(
        ContextID, hInput, format, hLab, SLCMS_TYPE_Lab_DBL, intent,
        cmsUInt32Number(cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE)
    )
    cmsCloseProfile(hLab)
    guard let xform else {
        blackPoint.pointee = noBlack
        return false
    }

    var lab = cmsCIELab()
    var black = ends.black
    cmsDoTransform(xform, &black, &lab, 1)
    cmsDeleteTransform(xform)

    if lab.L > 95 {
        lab.L = 0
    } else if lab.L < 0 {
        lab.L = 0
    } else if lab.L > 50 {
        lab.L = 50
    }

    var xyz = cmsCIEXYZ()
    cmsLab2XYZ(nil, &xyz, &lab)
    blackPoint.pointee = xyz
    return true
}

/// The black of an output CMYK profile without its ink limiting: Lab
/// zero in through perceptual and back out through relative
/// colorimetric.
private func blackPointUsingPerceptualBlack(
    _ blackPoint: UnsafeMutablePointer<cmsCIEXYZ>, _ hProfile: cmsHPROFILE?
) -> Bool {
    if cmsIsIntentSupported(hProfile, cmsUInt32Number(INTENT_PERCEPTUAL), cmsUInt32Number(LCMS_USED_AS_INPUT)) == 0 {
        blackPoint.pointee = noBlack
        return true
    }
    guard let roundTrip = createRoundtripXForm(hProfile, cmsUInt32Number(INTENT_PERCEPTUAL)) else {
        blackPoint.pointee = noBlack
        return false
    }

    var labIn = cmsCIELab(L: 0, a: 0, b: 0)
    var labOut = cmsCIELab()
    cmsDoTransform(roundTrip, &labIn, &labOut, 1)
    cmsDeleteTransform(roundTrip)

    if labOut.L > 50 { labOut.L = 50 }
    labOut.a = 0
    labOut.b = 0

    var xyz = cmsCIEXYZ()
    cmsLab2XYZ(nil, &xyz, &labOut)
    blackPoint.pointee = xyz
    return true
}

private func isInkColorspace(_ c: cmsColorSpaceSignature) -> Bool {
    switch c {
    case cmsSigCmykData, cmsSigCmyData,
         cmsSigMCH1Data, cmsSigMCH2Data, cmsSigMCH3Data, cmsSigMCH4Data, cmsSigMCH5Data,
         cmsSigMCH6Data, cmsSigMCH7Data, cmsSigMCH8Data, cmsSigMCH9Data, cmsSigMCHAData,
         cmsSigMCHBData, cmsSigMCHCData, cmsSigMCHDData, cmsSigMCHEData, cmsSigMCHFData,
         cmsSig1colorData, cmsSig2colorData, cmsSig3colorData, cmsSig4colorData, cmsSig5colorData,
         cmsSig6colorData, cmsSig7colorData, cmsSig8colorData, cmsSig9colorData, cmsSig10colorData,
         cmsSig11colorData, cmsSig12colorData, cmsSig13colorData, cmsSig14colorData, cmsSig15colorData:
        return true
    default:
        return false
    }
}

/// Whether the class and intent are ones a black point can be found
/// for; when not, the black is zero and the answer false.
private func precheck(
    _ blackPoint: UnsafeMutablePointer<cmsCIEXYZ>, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number
) -> Bool {
    let devClass = cmsGetDeviceClass(hProfile)
    if devClass == cmsSigLinkClass || devClass == cmsSigAbstractClass || devClass == cmsSigNamedColorClass {
        blackPoint.pointee = noBlack
        return false
    }
    if intent != cmsUInt32Number(INTENT_PERCEPTUAL) && intent != cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)
        && intent != cmsUInt32Number(INTENT_SATURATION)
    {
        blackPoint.pointee = noBlack
        return false
    }
    return true
}

/// The V4 perceptual and saturation intents have a black point of their
/// own, fixed by the spec — except that a matrix-shaper shares its
/// colorimetric one.  Nil when this rule does not apply.
private func v4PerceptualBlack(
    _ blackPoint: UnsafeMutablePointer<cmsCIEXYZ>, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number
) -> Bool? {
    guard cmsGetEncodedICCversion(hProfile) >= 0x4000000,
          intent == cmsUInt32Number(INTENT_PERCEPTUAL) || intent == cmsUInt32Number(INTENT_SATURATION)
    else { return nil }
    if cmsIsMatrixShaper(hProfile) != 0 {
        return blackPointAsDarkerColorant(hProfile, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), blackPoint)
    }
    blackPoint.pointee = perceptualBlack
    return true
}

/// The black point of a profile used as a source.
@c @implementation
public func cmsDetectBlackPoint(
    _ BlackPoint: UnsafeMutablePointer<cmsCIEXYZ>?, _ hProfile: cmsHPROFILE?,
    _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number
) -> cmsBool {
    guard let BlackPoint else { return 0 }
    if !precheck(BlackPoint, hProfile, Intent) { return 0 }
    if let answer = v4PerceptualBlack(BlackPoint, hProfile, Intent) { return answer ? 1 : 0 }

    // The media black point tag is not consulted: the reference builds
    // without CMS_USE_PROFILE_BLACK_POINT_TAG, since the tag is bogus
    // on most profiles.

    // An output profile in an ink space: discount its ink limiting.
    if Intent == cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)
        && cmsGetDeviceClass(hProfile) == cmsSigOutputClass
        && isInkColorspace(cmsGetColorSpace(hProfile))
    {
        return blackPointUsingPerceptualBlack(BlackPoint, hProfile) ? 1 : 0
    }

    return blackPointAsDarkerColorant(hProfile, Intent, BlackPoint) ? 1 : 0
}

/// The x at which a quadratic fitted to the points by least squares
/// reaches zero, clipped to 0..50, or zero when the fit is degenerate.
private func rootOfLeastSquaresFitQuadraticCurve(_ x: [Double], _ y: [Double]) -> Double {
    let n = x.count
    if n < 4 { return 0 }

    var sumX = 0.0, sumX2 = 0.0, sumX3 = 0.0, sumX4 = 0.0
    var sumY = 0.0, sumYX = 0.0, sumYX2 = 0.0
    for i in 0..<n {
        let xn = x[i], yn = y[i]
        sumX += xn
        sumX2 += xn * xn
        sumX3 += xn * xn * xn
        sumX4 += xn * xn * xn * xn
        sumY += yn
        sumYX += yn * xn
        sumYX2 += yn * xn * xn
    }

    let m = Matrix3(
        Vector3(Double(n), sumX, sumX2),
        Vector3(sumX, sumX2, sumX3),
        Vector3(sumX2, sumX3, sumX4)
    )
    guard let res = m.solve(Vector3(sumY, sumYX, sumYX2)) else { return 0 }

    let a = res.z, b = res.y, c = res.x
    if a.magnitude < 1.0e-10 {
        if b.magnitude < 1.0e-10 { return 0 }
        return max(0, min(50, -c / b))
    }
    let d = b * b - 4.0 * a * c
    if d <= 0 { return 0 }
    let rt = (-b + d.squareRoot()) / (2.0 * a)
    return max(0, min(50, rt))
}

/// The black point of a profile used as a destination — Adobe's method:
/// round-trip a ramp of L* through the profile and, unless the mid
/// range comes back straight, fit a quadratic to the shadows and take
/// its root.  Only for a LUT-based grey, RGB or ink profile; anything
/// else is treated as a source.
@c @implementation
public func cmsDetectDestinationBlackPoint(
    _ BlackPoint: UnsafeMutablePointer<cmsCIEXYZ>?, _ hProfile: cmsHPROFILE?,
    _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number
) -> cmsBool {
    guard let BlackPoint else { return 0 }
    if !precheck(BlackPoint, hProfile, Intent) { return 0 }
    if let answer = v4PerceptualBlack(BlackPoint, hProfile, Intent) { return answer ? 1 : 0 }

    let colorSpace = cmsGetColorSpace(hProfile)
    if cmsIsCLUT(hProfile, Intent, cmsUInt32Number(LCMS_USED_AS_OUTPUT)) == 0
        || (colorSpace != cmsSigGrayData && colorSpace != cmsSigRgbData && !isInkColorspace(colorSpace))
    {
        return cmsDetectBlackPoint(BlackPoint, hProfile, Intent, dwFlags)
    }

    // A first guess: the source black for relative colorimetric, zero
    // for the others.
    var initialLab = cmsCIELab(L: 0, a: 0, b: 0)
    if Intent == cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC) {
        var iniXYZ = cmsCIEXYZ()
        if cmsDetectBlackPoint(&iniXYZ, hProfile, Intent, dwFlags) == 0 { return 0 }
        cmsXYZ2Lab(nil, &initialLab, &iniXYZ)
    }

    guard let roundTrip = createRoundtripXForm(hProfile, Intent) else { return 0 }
    defer { cmsDeleteTransform(roundTrip) }

    var inRamp = [Double](repeating: 0, count: 256)
    var outRamp = [Double](repeating: 0, count: 256)
    for l in 0..<256 {
        var lab = cmsCIELab(
            L: Double(l) * 100.0 / 255.0,
            a: min(50, max(-50, initialLab.a)),
            b: min(50, max(-50, initialLab.b))
        )
        var destLab = cmsCIELab()
        cmsDoTransform(roundTrip, &lab, &destLab, 1)
        inRamp[l] = lab.L
        outRamp[l] = destLab.L
    }

    // Made monotonic from the top down.
    for l in stride(from: 254, through: 1, by: -1) {
        outRamp[l] = min(outRamp[l], outRamp[l + 1])
    }

    if !(outRamp[0] < outRamp[255]) {
        BlackPoint.pointee = noBlack
        return 0
    }

    let minL = outRamp[0], maxL = outRamp[255]
    if Intent == cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC) {
        // A straight mid range means the guess stands.
        var nearlyStraightMidrange = true
        for l in 0..<256 {
            if !((inRamp[l] <= minL + 0.2 * (maxL - minL)) || ((inRamp[l] - outRamp[l]).magnitude < 4.0)) {
                nearlyStraightMidrange = false
            }
        }
        if nearlyStraightMidrange {
            cmsLab2XYZ(nil, BlackPoint, &initialLab)
            return 1
        }
    }

    // The round trip's shadows: nearly flat at the black, then a knee
    // and a nearly straight line to white.  Fit the knee.
    var yRamp = [Double](repeating: 0, count: 256)
    for l in 0..<256 {
        yRamp[l] = (outRamp[l] - minL) / (maxL - minL)
    }

    let lo: Double, hi: Double
    if Intent == cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC) {
        lo = 0.1
        hi = 0.5
    } else {
        lo = 0.03
        hi = 0.25
    }

    var x: [Double] = []
    var y: [Double] = []
    for l in 0..<256 {
        let ff = yRamp[l]
        if ff >= lo && ff < hi {
            x.append(inRamp[l])
            y.append(ff)
        }
    }
    if x.count < 3 {
        BlackPoint.pointee = noBlack
        return 0
    }

    var lab = cmsCIELab(
        L: rootOfLeastSquaresFitQuadraticCurve(x, y),
        a: initialLab.a, b: initialLab.b
    )
    if lab.L < 0.0 { lab.L = 0 }
    cmsLab2XYZ(nil, BlackPoint, &lab)
    return 1
}
