import CLCMS2
import LittleCMS

// Linking a chain of profiles into one pipeline.
//
// Each profile contributes its own pipeline, read in whichever direction
// the chain needs it; between two of them, where the PCS is crossed, a
// correction may go — the white point scaling of absolute colorimetric,
// or black point compensation — and a conversion between XYZ and Lab
// when one profile's PCS is not the other's.  The first intent in the
// chain chooses the handler for the whole chain, which is how a plugin
// takes over the linking.

/// One row of the intent table: what it is called, and how it links.
struct IntentEntry: Sendable {
    let intent: cmsUInt32Number
    let description: StaticString
    let link: @Sendable (
        cmsContext?, [cmsUInt32Number], [cmsHPROFILE?], [Bool], [cmsFloat64Number], cmsUInt32Number
    ) -> UnsafeMutablePointer<cmsPipeline>?
}

/// The built-in intents, in the order cmsGetSupportedIntents lists them.
let defaultIntents: [IntentEntry] = [
    IntentEntry(intent: cmsUInt32Number(INTENT_PERCEPTUAL), description: "Perceptual", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), description: "Relative colorimetric", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_SATURATION), description: "Saturation", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC), description: "Absolute colorimetric", link: defaultICCIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_PERCEPTUAL), description: "Perceptual preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_RELATIVE_COLORIMETRIC), description: "Relative colorimetric preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_ONLY_SATURATION), description: "Saturation preserving black ink", link: blackPreservingKOnlyIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_PERCEPTUAL), description: "Perceptual preserving black plane", link: blackPreservingKPlaneIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_RELATIVE_COLORIMETRIC), description: "Relative colorimetric preserving black plane", link: blackPreservingKPlaneIntents),
    IntentEntry(intent: cmsUInt32Number(INTENT_PRESERVE_K_PLANE_SATURATION), description: "Saturation preserving black plane", link: blackPreservingKPlaneIntents),
]

// -- the correction between two profiles ---------------------------------------

/// The XYZ layer between profile `i - 1` and profile `i`: the absolute
/// intent's white scaling, or black point compensation when asked and
/// the two blacks differ, or nothing.  The offset is divided into the
/// XYZ encoding, since the stage sees encoded values.
private func computeConversion(
    _ i: Int, _ hProfiles: [cmsHPROFILE?], _ intent: cmsUInt32Number,
    _ bpc: Bool, _ adaptationState: cmsFloat64Number
) -> XYZLayer? {
    var layer = XYZLayer.identity

    if intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        let whiteIn = _cmsReadMediaWhitePoint(hProfiles[i - 1])
        guard let chadIn = _cmsReadCHAD(hProfiles[i - 1]) else { return nil }
        let whiteOut = _cmsReadMediaWhitePoint(hProfiles[i])
        guard let chadOut = _cmsReadCHAD(hProfiles[i]) else { return nil }

        guard let m = IntentArithmetic.absoluteIntent(
            adaptationState: adaptationState,
            whiteIn: engine(whiteIn), adaptationIn: matrix(chadIn),
            whiteOut: engine(whiteOut), adaptationOut: matrix(chadOut)
        ) else { return nil }
        layer.matrix = m
    } else if bpc {
        // The detectors leave their answer untouched on failure, and the
        // reference does not check: a failure is a black of zero.
        var blackIn = cmsCIEXYZ(X: 0, Y: 0, Z: 0)
        var blackOut = cmsCIEXYZ(X: 0, Y: 0, Z: 0)
        _ = cmsDetectBlackPoint(&blackIn, hProfiles[i - 1], intent, 0)
        _ = cmsDetectDestinationBlackPoint(&blackOut, hProfiles[i], intent, 0)

        if blackIn.X != blackOut.X || blackIn.Y != blackOut.Y || blackIn.Z != blackOut.Z {
            layer = IntentArithmetic.blackPointCompensation(from: engine(blackIn), to: engine(blackOut))
        }
    }

    layer.offset = Vector3(
        layer.offset.x / maximumEncodeableXYZ,
        layer.offset.y / maximumEncodeableXYZ,
        layer.offset.z / maximumEncodeableXYZ
    )
    return layer
}

@inline(__always)
private func matrix(_ m: cmsMAT3) -> Matrix3 {
    var m = m
    return withUnsafePointer(to: &m) { $0.matrix }
}

private func layerStage(_ ContextID: cmsContext?, _ layer: XYZLayer) -> UnsafeMutablePointer<cmsStage>? {
    var m = cmsMAT3()
    var off = cmsVEC3()
    withUnsafeMutablePointer(to: &m) { $0.matrix = layer.matrix }
    withUnsafeMutablePointer(to: &off) { $0.vector = layer.offset }
    return withUnsafePointer(to: &m) { mp in
        withUnsafePointer(to: &off) { op in
            mp.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { md in
                op.withMemoryRebound(to: cmsFloat64Number.self, capacity: 3) { od in
                    cmsStageAllocMatrix(ContextID, 3, 3, md, od)
                }
            }
        }
    }
}

/// Appends to `result` whatever takes `inPCS` to `outPCS` with the layer
/// applied in XYZ along the way; false on a mismatch that cannot be
/// bridged.
private func addConversion(
    _ result: UnsafeMutablePointer<cmsPipeline>,
    _ inPCS: cmsColorSpaceSignature, _ outPCS: cmsColorSpaceSignature,
    _ layer: XYZLayer
) -> Bool {
    let ContextID = cmsGetPipelineContextID(result)
    @inline(__always) func put(_ s: UnsafeMutablePointer<cmsStage>?) -> Bool {
        cmsPipelineInsertStage(result, cmsAT_END, s) != 0
    }

    switch inPCS {
    case cmsSigXYZData:
        switch outPCS {
        case cmsSigXYZData:
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
        case cmsSigLabData:
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
            if !put(_cmsStageAllocXYZ2Lab(ContextID)) { return false }
        default:
            return false
        }
    case cmsSigLabData:
        switch outPCS {
        case cmsSigXYZData:
            if !put(_cmsStageAllocLab2XYZ(ContextID)) { return false }
            if !layer.isEmpty && !put(layerStage(ContextID, layer)) { return false }
        case cmsSigLabData:
            if !layer.isEmpty {
                if !put(_cmsStageAllocLab2XYZ(ContextID))
                    || !put(layerStage(ContextID, layer))
                    || !put(_cmsStageAllocXYZ2Lab(ContextID))
                {
                    return false
                }
            }
        default:
            return false
        }
    default:
        // Anything else has to match exactly.
        if inPCS != outPCS { return false }
    }
    return true
}

/// The same space, or CMYK against 4-colour, or XYZ against Lab — the
/// last two because either can be computed from the other.
private func colorSpaceIsCompatible(_ a: cmsColorSpaceSignature, _ b: cmsColorSpaceSignature) -> Bool {
    if a == b { return true }
    if a == cmsSig4colorData && b == cmsSigCmykData { return true }
    if a == cmsSigCmykData && b == cmsSig4colorData { return true }
    if a == cmsSigXYZData && b == cmsSigLabData { return true }
    if a == cmsSigLabData && b == cmsSigXYZData { return true }
    return false
}

// -- the ICC intents -----------------------------------------------------------

/// The four ICC intents.  Walks the chain keeping the current colour
/// space: the first profile is read in the input direction unless it is
/// a devicelink; any later profile is read as input while the current
/// space is a device space and as output once it is a PCS.
@Sendable func defaultICCIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles == 0 { return nil }

    guard let result = cmsPipelineAlloc(ContextID, 0, 0) else { return nil }
    var currentColorSpace = cmsGetColorSpace(hProfiles[0])
    var colorSpaceOut = cmsSigLabData

    func fail(_ lut: UnsafeMutablePointer<cmsPipeline>? = nil) -> UnsafeMutablePointer<cmsPipeline>? {
        if let lut { cmsPipelineFree(lut) }
        cmsPipelineFree(result)
        return nil
    }

    for i in 0..<nProfiles {
        let hProfile = hProfiles[i]
        let classSig = cmsGetDeviceClass(hProfile)
        let isDeviceLink = classSig == cmsSigLinkClass || classSig == cmsSigAbstractClass

        let isInput: Bool
        if i == 0 && !isDeviceLink {
            isInput = true
        } else {
            isInput = currentColorSpace != cmsSigXYZData && currentColorSpace != cmsSigLabData
        }

        let intent = intents[i]
        let colorSpaceIn: cmsColorSpaceSignature
        if isInput || isDeviceLink {
            colorSpaceIn = cmsGetColorSpace(hProfile)
            colorSpaceOut = cmsGetPCS(hProfile)
        } else {
            colorSpaceIn = cmsGetPCS(hProfile)
            colorSpaceOut = cmsGetColorSpace(hProfile)
        }

        if !colorSpaceIsCompatible(colorSpaceIn, currentColorSpace) {
            report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "ColorSpace mismatch", to: ContextID)
            return fail()
        }

        let lut: UnsafeMutablePointer<cmsPipeline>?
        if isDeviceLink || (classSig == cmsSigNamedColorClass && nProfiles == 1) {
            // A devicelink takes no intent and no correction — except an
            // abstract profile after the first, which sits in the PCS
            // and may need one.
            guard let read = _cmsReadDevicelinkLUT(hProfile, intent) else { return fail() }
            lut = read

            var layer = XYZLayer.identity
            if classSig == cmsSigAbstractClass && i > 0 {
                guard let computed = computeConversion(i, hProfiles, intent, bpc[i], adaptationStates[i])
                else { return fail(lut) }
                layer = computed
            }
            if !addConversion(result, currentColorSpace, colorSpaceIn, layer) { return fail(lut) }
        } else if isInput {
            guard let read = _cmsReadInputLUT(hProfile, intent) else { return fail() }
            lut = read
        } else {
            guard let read = _cmsReadOutputLUT(hProfile, intent) else { return fail() }
            lut = read
            guard let layer = computeConversion(i, hProfiles, intent, bpc[i], adaptationStates[i])
            else { return fail(lut) }
            if !addConversion(result, currentColorSpace, colorSpaceIn, layer) { return fail(lut) }
        }

        if cmsPipelineCat(result, lut) == 0 { return fail(lut) }
        cmsPipelineFree(lut)

        currentColorSpace = colorSpaceOut
    }

    // Clip negatives at the end when asked and the exit is a device space.
    if dwFlags & cmsUInt32Number(cmsFLAGS_NONEGATIVES) != 0 {
        if colorSpaceOut == cmsSigGrayData || colorSpaceOut == cmsSigRgbData || colorSpaceOut == cmsSigCmykData {
            guard let clip = _cmsStageClipNegatives(ContextID, cmsUInt32Number(cmsChannelsOfColorSpace(colorSpaceOut)))
            else { return fail() }
            if cmsPipelineInsertStage(result, cmsAT_END, clip) == 0 { return fail() }
        }
    }

    return result
}

@c @implementation
public func _cmsDefaultICCintents(
    _ ContextID: cmsContext?,
    _ nProfiles: cmsUInt32Number,
    _ TheIntents: UnsafeMutablePointer<cmsUInt32Number>?,
    _ hProfiles: UnsafeMutablePointer<cmsHPROFILE?>?,
    _ BPC: UnsafeMutablePointer<cmsBool>?,
    _ AdaptationStates: UnsafeMutablePointer<cmsFloat64Number>?,
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    guard let TheIntents, let hProfiles, let BPC, let AdaptationStates else { return nil }
    let n = Int(nProfiles)
    return defaultICCIntents(
        ContextID,
        Array(UnsafeBufferPointer(start: TheIntents, count: n)),
        Array(UnsafeBufferPointer(start: hProfiles, count: n)),
        UnsafeBufferPointer(start: BPC, count: n).map { $0 != 0 },
        Array(UnsafeBufferPointer(start: AdaptationStates, count: n)),
        dwFlags
    )
}

// -- the black-preserving intents ---------------------------------------------

/// The ICC intent a black-preserving one stands on.
private func translateNonICCIntent(_ intent: cmsUInt32Number) -> cmsUInt32Number {
    switch Int32(intent) {
    case INTENT_PRESERVE_K_ONLY_PERCEPTUAL, INTENT_PRESERVE_K_PLANE_PERCEPTUAL:
        return cmsUInt32Number(INTENT_PERCEPTUAL)
    case INTENT_PRESERVE_K_ONLY_RELATIVE_COLORIMETRIC, INTENT_PRESERVE_K_PLANE_RELATIVE_COLORIMETRIC:
        return cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)
    case INTENT_PRESERVE_K_ONLY_SATURATION, INTENT_PRESERVE_K_PLANE_SATURATION:
        return cmsUInt32Number(INTENT_SATURATION)
    default:
        return intent
    }
}

private func isCMYKDevicelink(_ hProfile: cmsHPROFILE?) -> Bool {
    cmsGetDeviceClass(hProfile) == cmsSigLinkClass && cmsGetColorSpace(hProfile) == cmsSigCmykData
}

/// The part of both black-preserving handlers that decides whether
/// there is any black to preserve: the chain must go CMYK to CMYK, with
/// trailing CMYK devicelinks set aside.  When it does not, the chain is
/// linked with the plain ICC intents; when it does, the answer is the
/// index of the last profile in the preserved part.
private func blackPreservingSetup(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> (iccIntents: [cmsUInt32Number], lastProfile: Int?, fallback: UnsafeMutablePointer<cmsPipeline>?) {
    let nProfiles = hProfiles.count
    let iccIntents = intents.map(translateNonICCIntent)

    var lastProfilePos = nProfiles - 1
    var hLastProfile = hProfiles[lastProfilePos]
    while isCMYKDevicelink(hLastProfile) {
        if lastProfilePos < 2 { break }
        lastProfilePos -= 1
        hLastProfile = hProfiles[lastProfilePos]
    }

    if cmsGetColorSpace(hProfiles[0]) != cmsSigCmykData
        || !(cmsGetColorSpace(hLastProfile) == cmsSigCmykData || cmsGetDeviceClass(hLastProfile) == cmsSigOutputClass)
    {
        return (iccIntents, nil, defaultICCIntents(ContextID, iccIntents, hProfiles, bpc, adaptationStates, dwFlags))
    }
    return (iccIntents, lastProfilePos, nil)
}

/// Black ink only: a CMYK to CMYK CLUT that maps pure K through a K to
/// K curve and everything else through the plain transform.  The curve
/// comes from measuring both ends against Lab, which needs the virtual
/// Lab profile; until that exists the CMYK to CMYK case is refused.
@Sendable func blackPreservingKOnlyIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles < 1 || nProfiles > 255 { return nil }
    let (_, lastProfile, fallback) = blackPreservingSetup(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
    guard lastProfile != nil else { return fallback }

    report(
        cmsUInt32Number(cmsERROR_NOT_SUITABLE),
        "black-preserving intents on CMYK chains are not implemented", to: ContextID
    )
    return nil
}

/// Black plane: as above, but keeping the K plane and re-solving CMY
/// against it.  Refused for the same reason for now.
@Sendable func blackPreservingKPlaneIntents(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles < 1 || nProfiles > 255 { return nil }
    let (_, lastProfile, fallback) = blackPreservingSetup(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
    guard lastProfile != nil else { return fallback }

    report(
        cmsUInt32Number(cmsERROR_NOT_SUITABLE),
        "black-preserving intents on CMYK chains are not implemented", to: ContextID
    )
    return nil
}

// -- linking -------------------------------------------------------------------

/// `_cmsLinkProfiles`: settles BPC per profile — never for absolute
/// colorimetric, always for a V4 profile in perceptual or saturation —
/// then hands the chain to the handler of its first intent.
func linkProfiles(
    _ ContextID: cmsContext?,
    _ intents: [cmsUInt32Number], _ hProfiles: [cmsHPROFILE?],
    _ bpc: inout [Bool], _ adaptationStates: [cmsFloat64Number],
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsPipeline>? {
    let nProfiles = hProfiles.count
    if nProfiles <= 0 || nProfiles > 255 {
        report(cmsUInt32Number(cmsERROR_RANGE), "Couldn't link '\(nProfiles)' profiles", to: ContextID)
        return nil
    }

    for i in 0..<nProfiles {
        if intents[i] == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
            bpc[i] = false
        }
        if intents[i] == cmsUInt32Number(INTENT_PERCEPTUAL) || intents[i] == cmsUInt32Number(INTENT_SATURATION) {
            if cmsGetEncodedICCversion(hProfiles[i]) >= 0x4000000 {
                bpc[i] = true
            }
        }
    }

    // A plugin's intents would be searched first; there are none.
    guard let entry = defaultIntents.first(where: { $0.intent == intents[0] }) else {
        report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unsupported intent '\(intents[0])'", to: ContextID)
        return nil
    }
    return entry.link(ContextID, intents, hProfiles, bpc, adaptationStates, dwFlags)
}

// -- what intents there are ----------------------------------------------------

/// The description strings, as C strings that live as long as the
/// library: a caller keeps the pointers it is given.  Written once, at
/// first use, and only ever read after.
private nonisolated(unsafe) let intentDescriptions: [UnsafeMutablePointer<CChar>] = defaultIntents.map { entry in
    let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
    p.initialize(repeating: 0, count: 256)
    entry.description.withUTF8Buffer { utf8 in
        for (i, byte) in utf8.prefix(255).enumerated() { p[i] = CChar(bitPattern: byte) }
    }
    return p
}

@c @implementation
public func cmsGetSupportedIntentsTHR(
    _ ContextID: cmsContext?,
    _ nMax: cmsUInt32Number,
    _ Codes: UnsafeMutablePointer<cmsUInt32Number>?,
    _ Descriptions: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> cmsUInt32Number {
    var n: cmsUInt32Number = 0
    for (i, entry) in defaultIntents.enumerated() {
        if n < nMax {
            Codes?[Int(n)] = entry.intent
            Descriptions?[Int(n)] = intentDescriptions[i]
        }
        n += 1
    }
    // A plugin's intents would follow.
    return n
}

@c @implementation
public func cmsGetSupportedIntents(
    _ nMax: cmsUInt32Number,
    _ Codes: UnsafeMutablePointer<cmsUInt32Number>?,
    _ Descriptions: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> cmsUInt32Number {
    cmsGetSupportedIntentsTHR(nil, nMax, Codes, Descriptions)
}
