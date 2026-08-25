import CLCMS2
import LittleCMSCore

// Reading a profile as a pipeline.
//
// A profile stores its conversion in whichever of several forms its
// version and class allow — a LUT tag per intent in one of four types,
// or the matrix-shaper tags, or a named colour table — and each of them
// encodes its ends a little differently.  What a transform wants is one
// pipeline that goes from device to PCS (or back) in the current
// encoding, whatever the profile did.  So these readers pick the tag,
// copy the pipeline out of it, and add whatever conversion stages the
// original type calls for at the ends: a V2 Lab LUT is scaled to V4, a
// floating-point tag is brought into the 0..1 encoding, a matrix-shaper
// is assembled from its parts.

// The tag per intent, in each direction and precision.  Absolute
// colorimetric shares the relative tag at 16 bits — the difference is
// applied outside the profile — but has its own floating-point tag.
private let device2PCS16 = [cmsSigAToB0Tag, cmsSigAToB1Tag, cmsSigAToB2Tag, cmsSigAToB1Tag]
private let device2PCSFloat = [cmsSigDToB0Tag, cmsSigDToB1Tag, cmsSigDToB2Tag, cmsSigDToB3Tag]
private let pcs2Device16 = [cmsSigBToA0Tag, cmsSigBToA1Tag, cmsSigBToA2Tag, cmsSigBToA1Tag]
private let pcs2DeviceFloat = [cmsSigBToD0Tag, cmsSigBToD1Tag, cmsSigBToD2Tag, cmsSigBToD3Tag]

/// XYZ is carried in 1.15 fixed point, so a matrix producing it in the
/// 0..1 range must scale by 65536/(65535*2), and the inverse on the way
/// back.
private let inputAdjust = 1.0 / maximumEncodeableXYZ
private let outputAdjust = maximumEncodeableXYZ

// A grey profile has one curve and no matrix, so the matrix is D50
// scaled into the encoding, and going back it picks Y (or L*) out.
private let grayInputMatrix = [inputAdjust * cmsD50X, inputAdjust * cmsD50Y, inputAdjust * cmsD50Z]
private let oneToThreeInputMatrix: [cmsFloat64Number] = [1, 1, 1]
private let pickYMatrix: [cmsFloat64Number] = [0, outputAdjust * cmsD50Y, 0]
private let pickLstarMatrix: [cmsFloat64Number] = [1, 0, 0]

private let version4 = cmsUInt32Number(0x4000000)

@inline(__always)
private func isV4(_ hProfile: cmsHPROFILE?) -> Bool {
    cmsGetEncodedICCversion(hProfile) >= version4
}

@inline(__always)
private func pipeline(_ p: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<cmsPipeline>? {
    p?.assumingMemoryBound(to: cmsPipeline.self)
}

/// Appends stages in order, giving up on the first that is missing or
/// does not fit; the pipeline is freed on failure and nil returned, which
/// is what every reader here wants.
private func append(
    _ lut: UnsafeMutablePointer<cmsPipeline>?,
    _ stages: UnsafeMutablePointer<cmsStage>?...
) -> UnsafeMutablePointer<cmsPipeline>? {
    return insert(lut, at: cmsAT_END, stages)
}

private func insert(
    _ lut: UnsafeMutablePointer<cmsPipeline>?,
    at position: cmsStageLoc,
    _ stages: [UnsafeMutablePointer<cmsStage>?]
) -> UnsafeMutablePointer<cmsPipeline>? {
    guard let lut else {
        for s in stages { cmsStageFree(s) }
        return nil
    }
    for (i, s) in stages.enumerated() where cmsPipelineInsertStage(lut, position, s) == 0 {
        // Insertion frees the stage it rejected; the rest are still ours.
        for later in stages[(i + 1)...] { cmsStageFree(later) }
        cmsPipelineFree(lut)
        return nil
    }
    return lut
}

// -- the fixed-up header values -----------------------------------------------

/// The media white point, defaulting to D50 when absent and — for a V2
/// display profile — when present, since those were written under a
/// spec that put D50 there regardless.
func _cmsReadMediaWhitePoint(_ hProfile: cmsHPROFILE?) -> cmsCIEXYZ {
    guard let tag = cmsReadTag(hProfile, cmsSigMediaWhitePointTag) else {
        return cmsD50_XYZ()!.pointee
    }
    if !isV4(hProfile) && cmsGetDeviceClass(hProfile) == cmsSigDisplayClass {
        return cmsD50_XYZ()!.pointee
    }
    return tag.assumingMemoryBound(to: cmsCIEXYZ.self).pointee
}

/// The chromatic adaptation matrix, or identity when absent — except
/// that a V2 display profile without one is taken to have been adapted
/// from its media white point to D50, and that matrix is computed.
func _cmsReadCHAD(_ hProfile: cmsHPROFILE?) -> cmsMAT3? {
    if let tag = cmsReadTag(hProfile, cmsSigChromaticAdaptationTag) {
        return tag.assumingMemoryBound(to: cmsMAT3.self).pointee
    }
    var identity = cmsMAT3()
    _cmsMAT3identity(&identity)

    if !isV4(hProfile) && cmsGetDeviceClass(hProfile) == cmsSigDisplayClass {
        guard let white = cmsReadTag(hProfile, cmsSigMediaWhitePointTag) else {
            return identity
        }
        let from = engine(white.assumingMemoryBound(to: cmsCIEXYZ.self).pointee)
        guard let m = ChromaticAdaptation.matrix(from: from, to: engine(cmsD50_XYZ()!.pointee))
        else { return nil }
        var result = cmsMAT3()
        withUnsafeMutablePointer(to: &result) { $0.matrix = m }
        return result
    }
    return identity
}

/// The colorant tags as one matrix, columns red, green, blue.
private func readColorantMatrix(_ hProfile: cmsHPROFILE?) -> cmsMAT3? {
    guard let red = cmsReadTag(hProfile, cmsSigRedColorantTag),
          let green = cmsReadTag(hProfile, cmsSigGreenColorantTag),
          let blue = cmsReadTag(hProfile, cmsSigBlueColorantTag)
    else { return nil }
    let r = red.assumingMemoryBound(to: cmsCIEXYZ.self).pointee
    let g = green.assumingMemoryBound(to: cmsCIEXYZ.self).pointee
    let b = blue.assumingMemoryBound(to: cmsCIEXYZ.self).pointee

    var m = cmsMAT3()
    _cmsVEC3init(&m.v.0, r.X, g.X, b.X)
    _cmsVEC3init(&m.v.1, r.Y, g.Y, b.Y)
    _cmsVEC3init(&m.v.2, r.Z, g.Z, b.Z)
    return m
}

private func matrixStage(
    _ ContextID: cmsContext?, rows: cmsUInt32Number, cols: cmsUInt32Number,
    _ values: [cmsFloat64Number]
) -> UnsafeMutablePointer<cmsStage>? {
    values.withUnsafeBufferPointer { cmsStageAllocMatrix(ContextID, rows, cols, $0.baseAddress, nil) }
}

private func matrixStage(
    _ ContextID: cmsContext?, _ m: cmsMAT3
) -> UnsafeMutablePointer<cmsStage>? {
    var m = m
    return withUnsafePointer(to: &m) {
        $0.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) {
            cmsStageAllocMatrix(ContextID, 3, 3, $0, nil)
        }
    }
}

// -- matrix-shaper, input direction --------------------------------------------

/// Grey to PCS: the curve, then the D50 scaling — or, for a Lab PCS, the
/// value spread to three channels with the curve on L* and flat 0x8080
/// on a* and b*.
private func buildGrayInputMatrixPipeline(_ hProfile: cmsHPROFILE?) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard let grayTRC = cmsReadTag(hProfile, cmsSigGrayTRCTag)?.assumingMemoryBound(to: cmsToneCurve.self)
    else { return nil }

    let lut = cmsPipelineAlloc(ContextID, 1, 3)

    if cmsGetPCS(hProfile) == cmsSigLabData {
        var zero: [cmsUInt16Number] = [0x8080, 0x8080]
        guard let emptyTab = cmsBuildTabulatedToneCurve16(ContextID, 2, &zero) else {
            cmsPipelineFree(lut)
            return nil
        }
        defer { cmsFreeToneCurve(emptyTab) }
        var labCurves: [UnsafeMutablePointer<cmsToneCurve>?] = [grayTRC, emptyTab, emptyTab]
        return append(
            lut,
            matrixStage(ContextID, rows: 3, cols: 1, oneToThreeInputMatrix),
            cmsStageAllocToneCurves(ContextID, 3, &labCurves)
        )
    }

    var curves: [UnsafeMutablePointer<cmsToneCurve>?] = [grayTRC]
    return append(
        lut,
        cmsStageAllocToneCurves(ContextID, 1, &curves),
        matrixStage(ContextID, rows: 3, cols: 1, grayInputMatrix)
    )
}

/// RGB to PCS: the three curves, then the colorant matrix scaled into
/// the XYZ encoding, then — if the profile is a Lab one wearing
/// matrix-shaper tags, which the spec forbids and the reference tolerates
/// — a conversion to Lab.
private func buildRGBInputMatrixShaper(_ hProfile: cmsHPROFILE?) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard var mat = readColorantMatrix(hProfile) else { return nil }

    withUnsafeMutablePointer(to: &mat) { p in
        p.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { d in
            for i in 0..<9 { d[i] *= inputAdjust }
        }
    }

    guard let red = cmsReadTag(hProfile, cmsSigRedTRCTag),
          let green = cmsReadTag(hProfile, cmsSigGreenTRCTag),
          let blue = cmsReadTag(hProfile, cmsSigBlueTRCTag)
    else { return nil }
    var shapes: [UnsafeMutablePointer<cmsToneCurve>?] = [
        red.assumingMemoryBound(to: cmsToneCurve.self),
        green.assumingMemoryBound(to: cmsToneCurve.self),
        blue.assumingMemoryBound(to: cmsToneCurve.self),
    ]

    var lut = append(
        cmsPipelineAlloc(ContextID, 3, 3),
        cmsStageAllocToneCurves(ContextID, 3, &shapes),
        matrixStage(ContextID, mat)
    )
    if cmsGetPCS(hProfile) == cmsSigLabData {
        lut = append(lut, _cmsStageAllocXYZ2Lab(ContextID))
    }
    return lut
}

// -- floating-point tags -------------------------------------------------------

/// A DToB or BToD tag speaks the space's own units at whichever of its
/// ends is Lab or XYZ; the transform speaks 0..1, so a normalisation goes
/// on each such end.
private func readFloatTag(
    _ hProfile: cmsHPROFILE?, _ tagFloat: cmsTagSignature,
    from: cmsColorSpaceSignature, to: cmsColorSpaceSignature
) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard var lut = cmsPipelineDup(pipeline(cmsReadTag(hProfile, tagFloat))) else { return nil }

    if from == cmsSigLabData {
        guard let l = insert(lut, at: cmsAT_BEGIN, [_cmsStageNormalizeToLabFloat(ContextID)]) else { return nil }
        lut = l
    } else if from == cmsSigXYZData {
        guard let l = insert(lut, at: cmsAT_BEGIN, [_cmsStageNormalizeToXyzFloat(ContextID)]) else { return nil }
        lut = l
    }

    if to == cmsSigLabData {
        return append(lut, _cmsStageNormalizeFromLabFloat(ContextID))
    } else if to == cmsSigXYZData {
        return append(lut, _cmsStageNormalizeFromXyzFloat(ContextID))
    }
    return lut
}

/// A profile whose PCS is Lab indexes its CLUT in Lab, and the reference
/// found trilinear interpolation the better fit there.  The flag is on
/// the live parameters, so the next evaluation sees it.
private func changeInterpolationToTrilinear(_ lut: UnsafeMutablePointer<cmsPipeline>?) {
    var stage = cmsPipelineGetPtrToFirstStage(lut)
    while let s = stage {
        if cmsStageType(s) == cmsSigCLutElemType,
           let data = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageCLutData.self),
           let params = data.pointee.Params
        {
            params.pointee.dwFlags |= cmsUInt32Number(CMS_LERP_FLAGS_TRILINEAR)
        }
        stage = cmsStageNext(s)
    }
}

// -- input direction -----------------------------------------------------------

/// The pipeline from device to PCS for an intent — or, for an intent
/// beyond the four ICC ones, the matrix-shaper regardless of what LUTs
/// are present, which is how the black-preserving intents get at it.
@c @implementation
public func _cmsReadInputLUT(
    _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)

    // A named colour profile is its table.
    if cmsGetDeviceClass(hProfile) == cmsSigNamedColorClass {
        guard let nc = cmsReadTag(hProfile, cmsSigNamedColor2Tag)?
            .assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
        else { return nil }
        return append(
            cmsPipelineAlloc(ContextID, 0, 0),
            _cmsStageAllocNamedColor(nc, 1),
            _cmsStageAllocLabV2ToV4(ContextID)
        )
    }

    if Intent <= cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        var tag16 = device2PCS16[Int(Intent)]
        let tagFloat = device2PCSFloat[Int(Intent)]

        // A floating-point tag wins over a 16-bit one.
        if cmsIsTag(hProfile, tagFloat) != 0 {
            return readFloatTag(
                hProfile, tagFloat,
                from: cmsGetColorSpace(hProfile), to: cmsGetPCS(hProfile)
            )
        }

        // Fall back to perceptual when the intent's own tag is missing.
        if cmsIsTag(hProfile, tag16) == 0 {
            tag16 = device2PCS16[0]
        }

        if cmsIsTag(hProfile, tag16) != 0 {
            guard let read = pipeline(cmsReadTag(hProfile, tag16)) else { return nil }
            // Reading first, then asking: the true type is only known
            // once the tag has been read.
            let originalType = _cmsGetTagTrueType(hProfile, tag16)
            // The profile owns what it read; the transform gets a copy.
            var lut = cmsPipelineDup(read)

            // Only a 16-bit LUT with a Lab PCS needs its output rescaled
            // from V2 to V4 encoding — and its input, if that is Lab too.
            if originalType != cmsSigLut16Type || cmsGetPCS(hProfile) != cmsSigLabData {
                return lut
            }
            if cmsGetColorSpace(hProfile) == cmsSigLabData {
                lut = insert(lut, at: cmsAT_BEGIN, [_cmsStageAllocLabV4ToV2(ContextID)])
            }
            return append(lut, _cmsStageAllocLabV2ToV4(ContextID))
        }
    }

    // No LUT: build the matrix-shaper.
    if cmsGetColorSpace(hProfile) == cmsSigGrayData {
        return buildGrayInputMatrixPipeline(hProfile)
    }
    return buildRGBInputMatrixShaper(hProfile)
}

// -- output direction ----------------------------------------------------------

/// PCS to grey: pick Y from XYZ or L* from Lab, then the inverse curve.
private func buildGrayOutputPipeline(_ hProfile: cmsHPROFILE?) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard let grayTRC = cmsReadTag(hProfile, cmsSigGrayTRCTag)?.assumingMemoryBound(to: cmsToneCurve.self),
          let revGrayTRC = cmsReverseToneCurve(grayTRC)
    else { return nil }
    defer { cmsFreeToneCurve(revGrayTRC) }

    let pick = cmsGetPCS(hProfile) == cmsSigLabData ? pickLstarMatrix : pickYMatrix
    var curves: [UnsafeMutablePointer<cmsToneCurve>?] = [revGrayTRC]
    return append(
        cmsPipelineAlloc(ContextID, 3, 1),
        matrixStage(ContextID, rows: 1, cols: 3, pick),
        cmsStageAllocToneCurves(ContextID, 1, &curves)
    )
}

/// PCS to RGB: the inverse colorant matrix scaled out of the XYZ
/// encoding, then the inverse curves — preceded by Lab to XYZ for the
/// tolerated case of a Lab profile with matrix-shaper tags.
private func buildRGBOutputMatrixShaper(_ hProfile: cmsHPROFILE?) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    guard var mat = readColorantMatrix(hProfile) else { return nil }
    var inv = cmsMAT3()
    guard _cmsMAT3inverse(&mat, &inv) != 0 else { return nil }

    withUnsafeMutablePointer(to: &inv) { p in
        p.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { d in
            for i in 0..<9 { d[i] *= outputAdjust }
        }
    }

    guard let red = cmsReadTag(hProfile, cmsSigRedTRCTag),
          let green = cmsReadTag(hProfile, cmsSigGreenTRCTag),
          let blue = cmsReadTag(hProfile, cmsSigBlueTRCTag)
    else { return nil }

    var invShapes: [UnsafeMutablePointer<cmsToneCurve>?] = [
        cmsReverseToneCurve(red.assumingMemoryBound(to: cmsToneCurve.self)),
        cmsReverseToneCurve(green.assumingMemoryBound(to: cmsToneCurve.self)),
        cmsReverseToneCurve(blue.assumingMemoryBound(to: cmsToneCurve.self)),
    ]
    defer { for c in invShapes { cmsFreeToneCurve(c) } }
    // The reference leaks the ones that did reverse when one did not;
    // the defer above frees them, which changes nothing a caller sees.
    if invShapes.contains(where: { $0 == nil }) { return nil }

    var lut = cmsPipelineAlloc(ContextID, 3, 3)
    if cmsGetPCS(hProfile) == cmsSigLabData {
        lut = append(lut, _cmsStageAllocLab2XYZ(ContextID))
    }
    return append(
        lut,
        matrixStage(ContextID, inv),
        cmsStageAllocToneCurves(ContextID, 3, &invShapes)
    )
}

/// The pipeline from PCS to device for an intent.
@c @implementation
public func _cmsReadOutputLUT(
    _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)

    if Intent <= cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        var tag16 = pcs2Device16[Int(Intent)]
        let tagFloat = pcs2DeviceFloat[Int(Intent)]

        if cmsIsTag(hProfile, tagFloat) != 0 {
            return readFloatTag(
                hProfile, tagFloat,
                from: cmsGetPCS(hProfile), to: cmsGetColorSpace(hProfile)
            )
        }

        if cmsIsTag(hProfile, tag16) == 0 {
            tag16 = pcs2Device16[0]
        }

        if cmsIsTag(hProfile, tag16) != 0 {
            guard let read = pipeline(cmsReadTag(hProfile, tag16)) else { return nil }
            let originalType = _cmsGetTagTrueType(hProfile, tag16)
            guard var lut = cmsPipelineDup(read) else { return nil }

            if cmsGetPCS(hProfile) == cmsSigLabData {
                changeInterpolationToTrilinear(lut)
            }

            if originalType != cmsSigLut16Type || cmsGetPCS(hProfile) != cmsSigLabData {
                return lut
            }
            guard let l = insert(lut, at: cmsAT_BEGIN, [_cmsStageAllocLabV4ToV2(ContextID)]) else { return nil }
            lut = l
            if cmsGetColorSpace(hProfile) == cmsSigLabData {
                return append(lut, _cmsStageAllocLabV2ToV4(ContextID))
            }
            return lut
        }
    }

    if cmsGetColorSpace(hProfile) == cmsSigGrayData {
        return buildGrayOutputPipeline(hProfile)
    }
    return buildRGBOutputMatrixShaper(hProfile)
}

// -- devicelinks ---------------------------------------------------------------

/// The pipeline of a devicelink or abstract profile, which has no
/// matrix-shaper form and no direction to choose.  A named colour
/// profile read this way gives device colorants rather than PCS.
@c @implementation
public func _cmsReadDevicelinkLUT(
    _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let ContextID = cmsGetProfileContextID(hProfile)
    if Intent > cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) { return nil }

    var tag16 = device2PCS16[Int(Intent)]
    var tagFloat = device2PCSFloat[Int(Intent)]

    if cmsGetDeviceClass(hProfile) == cmsSigNamedColorClass {
        guard let nc = cmsReadTag(hProfile, cmsSigNamedColor2Tag)?
            .assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
        else { return nil }
        let lut = append(cmsPipelineAlloc(ContextID, 0, 0), _cmsStageAllocNamedColor(nc, 0))
        if cmsGetColorSpace(hProfile) == cmsSigLabData {
            return append(lut, _cmsStageAllocLabV2ToV4(ContextID))
        }
        return lut
    }

    if cmsIsTag(hProfile, tagFloat) != 0 {
        return readFloatTag(
            hProfile, tagFloat,
            from: cmsGetColorSpace(hProfile), to: cmsGetPCS(hProfile)
        )
    }

    // The perceptual float tag is taken as-is, with no normalisation —
    // the reference does that, so this does.
    tagFloat = device2PCSFloat[0]
    if cmsIsTag(hProfile, tagFloat) != 0 {
        return cmsPipelineDup(pipeline(cmsReadTag(hProfile, tagFloat)))
    }

    if cmsIsTag(hProfile, tag16) == 0 {
        tag16 = device2PCS16[0]
        if cmsIsTag(hProfile, tag16) == 0 { return nil }
    }

    guard let read = pipeline(cmsReadTag(hProfile, tag16)),
          var lut = cmsPipelineDup(read)
    else { return nil }

    if cmsGetPCS(hProfile) == cmsSigLabData {
        changeInterpolationToTrilinear(lut)
    }

    let originalType = _cmsGetTagTrueType(hProfile, tag16)
    if originalType != cmsSigLut16Type { return lut }

    // Lab may be at either end, or both.
    if cmsGetColorSpace(hProfile) == cmsSigLabData {
        guard let l = insert(lut, at: cmsAT_BEGIN, [_cmsStageAllocLabV4ToV2(ContextID)]) else { return nil }
        lut = l
    }
    if cmsGetPCS(hProfile) == cmsSigLabData {
        return append(lut, _cmsStageAllocLabV2ToV4(ContextID))
    }
    return lut
}

// -- what a profile can do -----------------------------------------------------

/// Whether the matrix-shaper tags are all present for the profile's
/// space: the one curve for grey, three curves and three colorants for
/// RGB, and nothing else qualifies.
@c @implementation
public func cmsIsMatrixShaper(_ hProfile: cmsHPROFILE?) -> cmsBool {
    switch cmsGetColorSpace(hProfile) {
    case cmsSigGrayData:
        return cmsIsTag(hProfile, cmsSigGrayTRCTag)
    case cmsSigRgbData:
        let present = [
            cmsSigRedColorantTag, cmsSigGreenColorantTag, cmsSigBlueColorantTag,
            cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag,
        ].allSatisfy { cmsIsTag(hProfile, $0) != 0 }
        return present ? 1 : 0
    default:
        return 0
    }
}

/// Whether the intent has a LUT tag in the direction asked.  A
/// devicelink supports exactly the intent in its header; a proofing use
/// needs the intent on input and relative colorimetric on output.
@c @implementation
public func cmsIsCLUT(
    _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number, _ UsedDirection: cmsUInt32Number
) -> cmsBool {
    if cmsGetDeviceClass(hProfile) == cmsSigLinkClass {
        return cmsGetHeaderRenderingIntent(hProfile) == Intent ? 1 : 0
    }

    let table: [cmsTagSignature]
    switch Int32(UsedDirection) {
    case LCMS_USED_AS_INPUT:
        table = device2PCS16
    case LCMS_USED_AS_OUTPUT:
        table = pcs2Device16
    case LCMS_USED_AS_PROOF:
        let asInput = cmsIsIntentSupported(hProfile, Intent, cmsUInt32Number(LCMS_USED_AS_INPUT)) != 0
        let asOutput = cmsIsIntentSupported(
            hProfile, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), cmsUInt32Number(LCMS_USED_AS_OUTPUT)
        ) != 0
        return asInput && asOutput ? 1 : 0
    default:
        report(
            cmsUInt32Number(cmsERROR_RANGE), "Unexpected direction (\(UsedDirection))",
            to: cmsGetProfileContextID(hProfile)
        )
        return 0
    }

    // The extended intents are not CLUT-based.
    if Intent > cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) { return 0 }
    return cmsIsTag(hProfile, table[Int(Intent)])
}

/// A CLUT for the intent, or a matrix-shaper — which the reference
/// counts as supporting every intent, though a V2 one cannot really do
/// relative colorimetric with a non-zero black; many profiles claim it.
@c @implementation
public func cmsIsIntentSupported(
    _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number, _ UsedDirection: cmsUInt32Number
) -> cmsBool {
    if cmsIsCLUT(hProfile, Intent, UsedDirection) != 0 { return 1 }
    return cmsIsMatrixShaper(hProfile)
}

// -- profile sequences ---------------------------------------------------------

/// The description and the id tags carry two halves of one record;
/// this joins them when both are present and agree in length, and
/// otherwise takes whichever exists.
func _cmsReadProfileSequence(_ hProfile: cmsHPROFILE?) -> UnsafeMutablePointer<cmsSEQ>? {
    let profileSeq = cmsReadTag(hProfile, cmsSigProfileSequenceDescTag)?.assumingMemoryBound(to: cmsSEQ.self)
    let profileId = cmsReadTag(hProfile, cmsSigProfileSequenceIdTag)?.assumingMemoryBound(to: cmsSEQ.self)

    guard let profileSeq else {
        guard let profileId else { return nil }
        return cmsDupProfileSequenceDescription(profileId)
    }
    guard let profileId, profileSeq.pointee.n == profileId.pointee.n else {
        return cmsDupProfileSequenceDescription(profileSeq)
    }

    guard let newSeq = cmsDupProfileSequenceDescription(profileSeq) else { return nil }
    for i in 0..<Int(profileSeq.pointee.n) {
        newSeq.pointee.seq[i].ProfileID = profileId.pointee.seq[i].ProfileID
        newSeq.pointee.seq[i].Description = cmsMLUdup(profileId.pointee.seq[i].Description)
    }
    return newSeq
}

/// Writes the sequence to the description tag, and to the id tag as
/// well on a V4 profile.
func _cmsWriteProfileSequence(_ hProfile: cmsHPROFILE?, _ seq: UnsafePointer<cmsSEQ>?) -> Bool {
    if cmsWriteTag(hProfile, cmsSigProfileSequenceDescTag, seq) == 0 { return false }
    if isV4(hProfile) {
        if cmsWriteTag(hProfile, cmsSigProfileSequenceIdTag, seq) == 0 { return false }
    }
    return true
}

private func mluCopy(_ hProfile: cmsHPROFILE?, _ sig: cmsTagSignature) -> UnsafeMutablePointer<cmsMLU>? {
    guard let mlu = cmsReadTag(hProfile, sig) else { return nil }
    return cmsMLUdup(mlu.assumingMemoryBound(to: cmsMLU.self))
}

/// A sequence record describing each profile in a chain, from its
/// header and its descriptive tags.
func _cmsCompileProfileSequence(
    _ ContextID: cmsContext?, _ hProfiles: [cmsHPROFILE?]
) -> UnsafeMutablePointer<cmsSEQ>? {
    guard let seq = cmsAllocProfileSequenceDescription(ContextID, cmsUInt32Number(hProfiles.count))
    else { return nil }

    for (i, h) in hProfiles.enumerated() {
        let ps = seq.pointee.seq + i
        cmsGetHeaderAttributes(h, &ps.pointee.attributes)
        withUnsafeMutablePointer(to: &ps.pointee.ProfileID.ID8) {
            $0.withMemoryRebound(to: cmsUInt8Number.self, capacity: 16) { cmsGetHeaderProfileID(h, $0) }
        }
        ps.pointee.deviceMfg = cmsGetHeaderManufacturer(h)
        ps.pointee.deviceModel = cmsGetHeaderModel(h)

        if let tech = cmsReadTag(h, cmsSigTechnologyTag) {
            ps.pointee.technology = tech.assumingMemoryBound(to: cmsTechnologySignature.self).pointee
        } else {
            ps.pointee.technology = cmsTechnologySignature(0)
        }

        ps.pointee.Manufacturer = mluCopy(h, cmsSigDeviceMfgDescTag)
        ps.pointee.Model = mluCopy(h, cmsSigDeviceModelDescTag)
        ps.pointee.Description = mluCopy(h, cmsSigProfileDescriptionTag)
    }
    return seq
}

// -- descriptive text ----------------------------------------------------------

private func infoTag(_ hProfile: cmsHPROFILE?, _ Info: cmsInfoType) -> UnsafeMutablePointer<cmsMLU>? {
    let sig: cmsTagSignature
    switch Info {
    case cmsInfoDescription:
        // Apple writes a multilingual description under its own tag.
        sig = cmsIsTag(hProfile, cmsSigProfileDescriptionMLTag) != 0
            ? cmsSigProfileDescriptionMLTag : cmsSigProfileDescriptionTag
    case cmsInfoManufacturer:
        sig = cmsSigDeviceMfgDescTag
    case cmsInfoModel:
        sig = cmsSigDeviceModelDescTag
    case cmsInfoCopyright:
        sig = cmsSigCopyrightTag
    default:
        return nil
    }
    return cmsReadTag(hProfile, sig)?.assumingMemoryBound(to: cmsMLU.self)
}

@c @implementation
public func cmsGetProfileInfo(
    _ hProfile: cmsHPROFILE?, _ Info: cmsInfoType,
    _ LanguageCode: UnsafePointer<CChar>?, _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<wchar_t>?, _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let mlu = infoTag(hProfile, Info) else { return 0 }
    return cmsMLUgetWide(mlu, LanguageCode, CountryCode, Buffer, BufferSize)
}

@c @implementation
public func cmsGetProfileInfoASCII(
    _ hProfile: cmsHPROFILE?, _ Info: cmsInfoType,
    _ LanguageCode: UnsafePointer<CChar>?, _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<CChar>?, _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let mlu = infoTag(hProfile, Info) else { return 0 }
    return cmsMLUgetASCII(mlu, LanguageCode, CountryCode, Buffer, BufferSize)
}

@c @implementation
public func cmsGetProfileInfoUTF8(
    _ hProfile: cmsHPROFILE?, _ Info: cmsInfoType,
    _ LanguageCode: UnsafePointer<CChar>?, _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<CChar>?, _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let mlu = infoTag(hProfile, Info) else { return 0 }
    return cmsMLUgetUTF8(mlu, LanguageCode, CountryCode, Buffer, BufferSize)
}
