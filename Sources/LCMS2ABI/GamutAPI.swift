import CLCMS2
import LittleCMS

// Gamut checking, black tone curves, and two profile measurements —
// the parts of the library that measure a profile by running transforms
// through it.

/// The chain with a Lab identity appended, as a transform: the way to
/// see what a chain of profiles produces in Lab.
func _cmsChain2Lab(
    _ ContextID: cmsContext?,
    _ InputFormat: cmsUInt32Number, _ OutputFormat: cmsUInt32Number,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> cmsHTRANSFORM? {
    let nProfiles = hProfiles.count
    if nProfiles > 254 { return nil }
    guard let hLab = cmsCreateLab4ProfileTHR(ContextID, nil) else { return nil }
    defer { cmsCloseProfile(hLab) }

    var profiles = hProfiles + [hLab]
    var bpcList = bpc.map { cmsBool($0 ? 1 : 0) } + [0]
    var adaptation = adaptationStates + [1.0]
    var intentList = intents + [cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)]

    return cmsCreateExtendedTransform(
        ContextID, cmsUInt32Number(nProfiles + 1), &profiles, &bpcList, &intentList, &adaptation,
        nil, 0, InputFormat, OutputFormat, dwFlags
    )
}

/// K to L*: black ink alone through the chain, sampled at `nPoints`,
/// with L* negated so that more ink is a larger value.
private func computeKToLstar(
    _ ContextID: cmsContext?, _ nPoints: Int,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let xform = _cmsChain2Lab(
        ContextID, SLCMS_TYPE_CMYK_FLT, SLCMS_TYPE_Lab_DBL,
        intents, hProfiles, bpc, adaptationStates, dwFlags
    ) else { return nil }
    defer { cmsDeleteTransform(xform) }

    var sampled = [cmsFloat32Number](repeating: 0, count: nPoints)
    for i in 0..<nPoints {
        var cmyk: [cmsFloat32Number] = [0, 0, 0, cmsFloat32Number(Double(i) * 100.0 / Double(nPoints - 1))]
        var lab = cmsCIELab()
        cmsDoTransform(xform, &cmyk, &lab, 1)
        sampled[i] = cmsFloat32Number(1.0 - lab.L / 100.0)
    }
    return cmsBuildTabulatedToneCurveFloat(ContextID, cmsUInt32Number(nPoints), &sampled)
}

/// The black tone curve of a CMYK to CMYK chain: K to L* through the
/// input side and through the output profile, joined.  Nil unless the
/// chain is CMYK to CMYK ending in an output profile, or when the join
/// is not monotonic.
func _cmsBuildKToneCurve(
    _ ContextID: cmsContext?, _ nPoints: Int,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsToneCurve>? {
    let n = hProfiles.count
    if cmsGetColorSpace(hProfiles[0]) != cmsSigCmykData || cmsGetColorSpace(hProfiles[n - 1]) != cmsSigCmykData {
        return nil
    }
    if cmsGetDeviceClass(hProfiles[n - 1]) != cmsSigOutputClass { return nil }

    guard let inCurve = computeKToLstar(
        ContextID, nPoints,
        Array(intents[0..<(n - 1)]), Array(hProfiles[0..<(n - 1)]),
        Array(bpc[0..<(n - 1)]), Array(adaptationStates[0..<(n - 1)]), dwFlags
    ) else { return nil }
    defer { cmsFreeToneCurve(inCurve) }

    guard let outCurve = computeKToLstar(
        ContextID, nPoints,
        [intents[n - 1]], [hProfiles[n - 1]], [bpc[n - 1]], [adaptationStates[n - 1]], dwFlags
    ) else { return nil }
    defer { cmsFreeToneCurve(outCurve) }

    guard let kTone = cmsJoinToneCurve(ContextID, inCurve, outCurve, cmsUInt32Number(nPoints)) else { return nil }
    if cmsIsToneCurveMonotonic(kTone) == 0 {
        cmsFreeToneCurve(kTone)
        return nil
    }
    return kTone
}

// -- gamut check -----------------------------------------------------------------

/// The transforms a gamut sample runs through, and the error past which
/// a colour counts as out of gamut.
private struct GamutChain {
    var hInput: cmsHTRANSFORM?
    var hForward: cmsHTRANSFORM?
    var hReverse: cmsHTRANSFORM?
    var threshold: Double
}

private let errorThreshold = 5.0

/// Out of gamut, measured by going to the gamut device and back twice:
/// a colour that survives the first round trip is in; one that changes
/// on the first and holds on the second is out by that much; one that
/// changes on both is judged by the ratio.
private func gamutSampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let t = Cargo.assumingMemoryBound(to: GamutChain.self).pointee

    var labIn1 = cmsCIELab(), labOut1 = cmsCIELab(), labOut2 = cmsCIELab()
    var proof = [cmsUInt16Number](repeating: 0, count: maximumChannels)
    var proof2 = [cmsUInt16Number](repeating: 0, count: maximumChannels)

    cmsDoTransform(t.hInput, In, &labIn1, 1)
    cmsDoTransform(t.hForward, &labIn1, &proof, 1)
    cmsDoTransform(t.hReverse, &proof, &labOut1, 1)
    var labIn2 = labOut1
    cmsDoTransform(t.hForward, &labOut1, &proof2, 1)
    cmsDoTransform(t.hReverse, &proof2, &labOut2, 1)

    let dE1 = cmsDeltaE(&labIn1, &labOut1)
    let dE2 = cmsDeltaE(&labIn2, &labOut2)

    if dE1 < t.threshold && dE2 < t.threshold {
        Out[0] = 0
    } else if dE1 < t.threshold && dE2 > t.threshold {
        // Undefined; taken as in gamut.
        Out[0] = 0
    } else if dE1 > t.threshold && dE2 < t.threshold {
        Out[0] = cmsUInt16Number(truncatingIfNeeded: quickFloor((dE1 - t.threshold) + 0.5))
    } else {
        // Both large, perhaps a perceptual mapping: judge by the ratio.
        let errorRatio = dE2 == 0.0 ? dE1 : dE1 / dE2
        if errorRatio > t.threshold {
            Out[0] = cmsUInt16Number(truncatingIfNeeded: quickFloor((errorRatio - t.threshold) + 0.5))
        } else {
            Out[0] = 0
        }
    }
    return 1
}

/// A one-channel CLUT over the input space that holds how far out of
/// the gamut profile's gamut each colour is, as a ΔE past the
/// threshold — one for a matrix-shaper, which round-trips exactly, five
/// for a LUT profile whose two directions differ in resolution.
func _cmsCreateGamutCheckPipeline(
    _ ContextID: cmsContext?,
    _ hProfiles: [cmsHPROFILE?], _ bpc: [Bool], _ intents: [cmsUInt32Number],
    _ adaptationStates: [cmsFloat64Number],
    _ nGamutPCSposition: Int, _ hGamut: cmsHPROFILE?
) -> UnsafeMutablePointer<cmsPipeline>? {
    if nGamutPCSposition <= 0 || nGamutPCSposition > 255 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Wrong position of PCS. 1..255 expected, \(nGamutPCSposition) found.", to: ContextID
        )
        return nil
    }
    guard let hLab = cmsCreateLab4ProfileTHR(ContextID, nil) else { return nil }
    defer { cmsCloseProfile(hLab) }

    var chain = GamutChain(threshold: cmsIsMatrixShaper(hGamut) != 0 ? 1.0 : errorThreshold)

    var profileList = Array(hProfiles[0..<nGamutPCSposition]) + [hLab]
    var bpcList = bpc[0..<nGamutPCSposition].map { cmsBool($0 ? 1 : 0) } + [0]
    var adaptationList = Array(adaptationStates[0..<nGamutPCSposition]) + [1.0]
    var intentList = Array(intents[0..<nGamutPCSposition]) + [cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)]

    let colorSpace = cmsGetColorSpace(hGamut)
    let nChannels = cmsUInt32Number(bitPattern: cmsChannelsOfColorSpace(colorSpace))
    let nGridpoints = _cmsReasonableGridpointsByColorspace(colorSpace, cmsUInt32Number(cmsFLAGS_HIGHRESPRECALC))

    let inputColorSpace = cmsGetColorSpace(profileList[0])
    let nInputChannels = cmsUInt32Number(bitPattern: cmsChannelsOfColorSpace(inputColorSpace))

    // Input to Lab double.
    chain.hInput = cmsCreateExtendedTransform(
        ContextID, cmsUInt32Number(nGamutPCSposition + 1), &profileList, &bpcList, &intentList, &adaptationList,
        nil, 0, channelsSH(nInputChannels) | bytesSH(2), SLCMS_TYPE_Lab_DBL, cmsUInt32Number(cmsFLAGS_NOCACHE)
    )
    // Lab double to the gamut device and back.
    let deviceFormat = channelsSH(nChannels) | bytesSH(2)
    chain.hForward = cmsCreateTransformTHR(
        ContextID, hLab, SLCMS_TYPE_Lab_DBL, hGamut, deviceFormat,
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(cmsFLAGS_NOCACHE)
    )
    chain.hReverse = cmsCreateTransformTHR(
        ContextID, hGamut, deviceFormat, hLab, SLCMS_TYPE_Lab_DBL,
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(cmsFLAGS_NOCACHE)
    )
    defer {
        if let x = chain.hInput { cmsDeleteTransform(x) }
        if let x = chain.hForward { cmsDeleteTransform(x) }
        if let x = chain.hReverse { cmsDeleteTransform(x) }
    }

    guard chain.hInput != nil, chain.hForward != nil, chain.hReverse != nil else { return nil }
    guard let gamut = cmsPipelineAlloc(ContextID, 3, 1) else { return nil }
    let clut = cmsStageAllocCLut16bit(ContextID, nGridpoints, nChannels, 1, nil)
    if cmsPipelineInsertStage(gamut, cmsAT_BEGIN, clut) == 0 {
        cmsPipelineFree(gamut)
        return nil
    }
    _ = cmsStageSampleCLut16bit(clut, gamutSampler, &chain, 0)
    return gamut
}

// -- total area coverage -------------------------------------------------------------

private struct TACEstimator {
    var nOutputChans: Int
    var hRoundTrip: cmsHTRANSFORM?
    var maxTAC: Float
}

private func estimateTAC(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Cargo else { return 0 }
    let bp = Cargo.assumingMemoryBound(to: TACEstimator.self)
    var roundTrip = [cmsFloat32Number](repeating: 0, count: maximumChannels)
    cmsDoTransform(bp.pointee.hRoundTrip, In, &roundTrip, 1)
    var sum: Float = 0
    for i in 0..<bp.pointee.nOutputChans { sum += roundTrip[i] }
    if sum > bp.pointee.maxTAC {
        bp.pointee.maxTAC = sum
    }
    return 1
}

/// The most ink an output profile ever asks for, in percent, found by
/// sweeping Lab through it on the perceptual intent — coarsely in L*,
/// finely in a* and b*.
@c @implementation
public func cmsDetectTAC(_ hProfile: cmsHPROFILE?) -> cmsFloat64Number {
    let ContextID = cmsGetProfileContextID(hProfile)
    if cmsGetDeviceClass(hProfile) != cmsSigOutputClass { return 0 }

    let dwFormatter = cmsFormatterForColorspaceOfProfile(hProfile, 4, 1)
    if dwFormatter == 0 { return 0 }

    var bp = TACEstimator(nOutputChans: PixelFormat(dwFormatter).channels, hRoundTrip: nil, maxTAC: 0)
    if bp.nOutputChans >= maximumChannels { return 0 }

    guard let hLab = cmsCreateLab4ProfileTHR(ContextID, nil) else { return 0 }
    bp.hRoundTrip = cmsCreateTransformTHR(
        ContextID, hLab, SLCMS_TYPE_Lab_16, hProfile, dwFormatter,
        cmsUInt32Number(INTENT_PERCEPTUAL), cmsUInt32Number(cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE)
    )
    cmsCloseProfile(hLab)
    guard bp.hRoundTrip != nil else { return 0 }
    defer { cmsDeleteTransform(bp.hRoundTrip) }

    var gridPoints: [cmsUInt32Number] = [6, 74, 74]
    if cmsSliceSpace16(3, &gridPoints, estimateTAC, &bp) == 0 {
        bp.maxTAC = 0
    }
    return cmsFloat64Number(bp.maxTAC)
}

/// The gamma of an RGB profile, estimated by fitting the Y that a
/// synthetic grey ramp produces.  -1 for a profile this cannot be
/// asked of.
@c @implementation
public func cmsDetectRGBProfileGamma(_ hProfile: cmsHPROFILE?, _ threshold: cmsFloat64Number) -> cmsFloat64Number {
    if cmsGetColorSpace(hProfile) != cmsSigRgbData { return -1 }
    let cl = cmsGetDeviceClass(hProfile)
    if cl != cmsSigInputClass && cl != cmsSigDisplayClass && cl != cmsSigOutputClass && cl != cmsSigColorSpaceClass {
        return -1
    }
    let ContextID = cmsGetProfileContextID(hProfile)
    guard let hXYZ = cmsCreateXYZProfileTHR(ContextID) else { return -1 }
    defer { cmsCloseProfile(hXYZ) }

    guard let xform = cmsCreateTransformTHR(
        ContextID, hProfile, SLCMS_TYPE_RGB_16, hXYZ, SLCMS_TYPE_XYZ_DBL,
        cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(cmsFLAGS_NOOPTIMIZE)
    ) else { return -1 }

    var rgb = [cmsUInt16Number](repeating: 0, count: 256 * 3)
    var xyz = [cmsCIEXYZ](repeating: cmsCIEXYZ(), count: 256)
    for i in 0..<256 {
        let v = widen(UInt8(i))
        rgb[i * 3] = v; rgb[i * 3 + 1] = v; rgb[i * 3 + 2] = v
    }
    cmsDoTransform(xform, &rgb, &xyz, 256)
    cmsDeleteTransform(xform)

    var yNormalized = xyz.map { cmsFloat32Number($0.Y) }
    guard let yCurve = cmsBuildTabulatedToneCurveFloat(ContextID, 256, &yNormalized) else { return -1 }
    defer { cmsFreeToneCurve(yCurve) }
    return cmsEstimateGamma(yCurve, threshold)
}
