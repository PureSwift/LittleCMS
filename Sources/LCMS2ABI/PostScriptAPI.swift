import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// PostScript colour space arrays and colour rendering dictionaries.
//
// A profile is written out as the PostScript that a Level 2 interpreter
// needs to do the same conversion: a CSA for the input side (a
// CIEBasedA, ABC or DEF dictionary, depending on how the profile is
// built) and a CRD for the output side (always a table, always through
// Lab).  The text is the reference's, formatted with the same printf
// conversions, so the two are compared as text.

private let maxPSColumns = 60

/// The reference keeps the column count in a file-level static, and so
/// does this — the generators are not re-entrant there either.
private nonisolated(unsafe) var actualColumn = 0

/// `_cmsIOPrintf`'s output side: text through the handler, with any
/// comma made a period — the reference's guard against a decimal-comma
/// locale, applied to everything it emits.
@discardableResult
private func emit(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ text: String) -> Bool {
    var bytes = Array(text.utf8)
    for i in bytes.indices where bytes[i] == UInt8(ascii: ",") { bytes[i] = UInt8(ascii: ".") }
    return bytes.withUnsafeBufferPointer { m.pointee.Write?(m, cmsUInt32Number($0.count), UnsafeMutableRawPointer(mutating: $0.baseAddress)) != 0 }
}

/// A number through the C formatter, for the conversions PostScript is
/// written with: %f, %.6f, %g, %.3f.
private func cfmt(_ format: String, _ v: Double) -> String {
    var buffer = [CChar](repeating: 0, count: 64)
    let n = withVaList([v]) { vsnprintf(&buffer, 63, format, $0) }
    if n < 0 { return "" }
    return String(cString: buffer)
}

private func cfmt(_ format: String, _ v: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: 64)
    let n = withVaList([v]) { vsnprintf(&buffer, 63, format, $0) }
    if n < 0 { return "" }
    return String(cString: buffer)
}

@inline(__always) private func word2Byte(_ w: UInt16) -> UInt8 {
    UInt8((Double(w) / 257.0 + 0.5).rounded(.down))
}

private func writeByte(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ b: UInt8) {
    emit(m, cfmt("%02x", Int32(b)))
    actualColumn += 2
    if actualColumn > maxPSColumns {
        emit(m, "\n")
        actualColumn = 0
    }
}

/// Line ends replaced by spaces, and the text held to 2047 bytes.
private func removeCR(_ text: [CChar]) -> String {
    var bytes = text.prefix { $0 != 0 }.prefix(2047).map { UInt8(bitPattern: $0) }
    for i in bytes.indices where bytes[i] == 10 || bytes[i] == 13 { bytes[i] = 32 }
    return String(decoding: bytes, as: UTF8.self)
}

private func emitPSEscaped(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ text: UnsafePointer<CChar>) {
    var p = text
    while p.pointee != 0 {
        let c = UInt8(bitPattern: p.pointee)
        if c == UInt8(ascii: "\\") || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") {
            emit(m, "\\" + String(UnicodeScalar(c)))
        } else if c < 0x20 || c >= 0x7F {
            emit(m, "\\" + cfmt("%03o", Int32(c)))
        } else {
            emit(m, String(UnicodeScalar(c)))
        }
        p += 1
    }
}

private func emitHeader(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ title: String, _ hProfile: cmsHPROFILE?) {
    var timer = time(nil)
    var descASCII = [CChar](repeating: 0, count: 256)
    var copyrightASCII = [CChar](repeating: 0, count: 256)
    if let description = cmsReadTag(hProfile, cmsSigProfileDescriptionTag) {
        _ = cmsMLUgetASCII(description.assumingMemoryBound(to: cmsMLU.self), cmsNoLanguage, cmsNoCountry, &descASCII, 255)
    }
    if let copyright = cmsReadTag(hProfile, cmsSigCopyrightTag) {
        _ = cmsMLUgetASCII(copyright.assumingMemoryBound(to: cmsMLU.self), cmsNoLanguage, cmsNoCountry, &copyrightASCII, 255)
    }
    emit(m, "%!PS-Adobe-3.0\n")
    emit(m, "%\n")
    emit(m, "% \(title)\n")
    emit(m, "% Source: \(removeCR(descASCII))\n")
    emit(m, "%         \(removeCR(copyrightASCII))\n")
    // ctime's text ends in a newline of its own.
    let created = ctime(&timer).map { String(cString: $0) } ?? "\n"
    emit(m, "% Created: \(created)")
    emit(m, "%\n")
    emit(m, "%%BeginResource\n")
}

private func emitWhiteBlackD50(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ blackPoint: cmsCIEXYZ) {
    emit(m, "/BlackPoint [\(cfmt("%f", blackPoint.X)) \(cfmt("%f", blackPoint.Y)) \(cfmt("%f", blackPoint.Z))]\n")
    let d50 = cmsD50_XYZ()!.pointee
    emit(m, "/WhitePoint [\(cfmt("%f", d50.X)) \(cfmt("%f", d50.Y)) \(cfmt("%f", d50.Z))]\n")
}

private func emitRangeCheck(_ m: UnsafeMutablePointer<cmsIOHANDLER>) {
    emit(m, "dup 0.0 lt { pop 0.0 } if dup 1.0 gt { pop 1.0 } if ")
}

private func emitIntent(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ intent: cmsUInt32Number) {
    let name: String
    switch Int32(intent) {
    case INTENT_PERCEPTUAL: name = "Perceptual"
    case INTENT_RELATIVE_COLORIMETRIC: name = "RelativeColorimetric"
    case INTENT_ABSOLUTE_COLORIMETRIC: name = "AbsoluteColorimetric"
    case INTENT_SATURATION: name = "Saturation"
    default: name = "Undefined"
    }
    emit(m, "/RenderingIntent (\(name))\n")
}

private func emitLab2XYZ(_ m: UnsafeMutablePointer<cmsIOHANDLER>) {
    emit(m, "/RangeABC [ 0 1 0 1 0 1]\n")
    emit(m, "/DecodeABC [\n")
    emit(m, "{100 mul  16 add 116 div } bind\n")
    emit(m, "{255 mul 128 sub 500 div } bind\n")
    emit(m, "{255 mul 128 sub 200 div } bind\n")
    emit(m, "]\n")
    emit(m, "/MatrixABC [ 1 1 1 1 0 0 0 0 -1]\n")
    emit(m, "/RangeLMN [ -0.236 1.254 0 1 -0.635 1.640 ]\n")
    emit(m, "/DecodeLMN [\n")
    emit(m, "{dup 6 29 div ge {dup dup mul mul} {4 29 div sub 108 841 div mul} ifelse 0.964200 mul} bind\n")
    emit(m, "{dup 6 29 div ge {dup dup mul mul} {4 29 div sub 108 841 div mul} ifelse } bind\n")
    emit(m, "{dup 6 29 div ge {dup dup mul mul} {4 29 div sub 108 841 div mul} ifelse 0.824900 mul} bind\n")
    emit(m, "]\n")
}

/// A curve as PostScript: `{ 1 }` when linear or missing, a power when
/// one fits, else the table with an interpolation procedure around it.
private func emit1Gamma(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ table: UnsafeMutablePointer<cmsToneCurve>?) {
    guard let table, table.pointee.nEntries > 0, cmsIsToneCurveLinear(table) == 0 else {
        emit(m, "{ 1 } bind ")
        return
    }
    let gamma = cmsEstimateGamma(table, 0.001)
    if gamma > 0 {
        emit(m, "{ \(cfmt("%g", gamma)) exp } bind ")
        return
    }
    emit(m, "{ ")
    emitRangeCheck(m)
    emit(m, " [")
    let entries = table.pointee.Table16
    for i in 0..<Int(table.pointee.nEntries) {
        if i % 10 == 0 { emit(m, "\n  ") }
        emit(m, "\(entries?[i] ?? 0) ")
    }
    emit(m, "] ")
    emit(m, "dup ")
    emit(m, "length 1 sub ")
    emit(m, "3 -1 roll ")
    emit(m, "mul ")
    emit(m, "dup ")
    emit(m, "dup ")
    emit(m, "floor cvi ")
    emit(m, "exch ")
    emit(m, "ceiling cvi ")
    emit(m, "3 index ")
    emit(m, "exch ")
    emit(m, "get\n  ")
    emit(m, "4 -1 roll ")
    emit(m, "3 -1 roll ")
    emit(m, "get ")
    emit(m, "dup ")
    emit(m, "3 1 roll ")
    emit(m, "sub ")
    emit(m, "3 -1 roll ")
    emit(m, "dup ")
    emit(m, "floor cvi ")
    emit(m, "sub ")
    emit(m, "mul ")
    emit(m, "add ")
    emit(m, "65535 div\n")
    emit(m, " } bind ")
}

private func gammaTableEquals(_ g1: UnsafeMutablePointer<cmsToneCurve>, _ g2: UnsafeMutablePointer<cmsToneCurve>) -> Bool {
    if g1.pointee.nEntries != g2.pointee.nEntries { return false }
    guard let t1 = g1.pointee.Table16, let t2 = g2.pointee.Table16 else { return false }
    return memcmp(t1, t2, Int(g1.pointee.nEntries) * 2) == 0
}

/// Curves in a row, with `dup` for one that repeats the last.
private func emitNGamma(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ n: Int, _ g: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>) {
    for i in 0..<n {
        guard let curve = g[i] else { return }
        if i > 0, let previous = g[i - 1], gammaTableEquals(previous, curve) {
            emit(m, "dup ")
        } else {
            emit1Gamma(m, curve)
        }
    }
}

/// The sampler's state as it walks the CLUT: which major and minor
/// index it is in, so it can open and close the brackets between.
private struct PSSamplerCargo {
    var params: UnsafeMutablePointer<cmsInterpParams>
    var m: UnsafeMutablePointer<cmsIOHANDLER>
    var firstComponent: Int32 = -1
    var secondComponent: Int32 = -1
    var preMaj: String
    var postMaj: String
    var preMin: String
    var postMin: String
    var fixWhite: Bool
    var colorSpace: cmsColorSpaceSignature
}

private func outputValueSampler(
    _ In: UnsafePointer<cmsUInt16Number>?, _ Out: UnsafeMutablePointer<cmsUInt16Number>?, _ Cargo: UnsafeMutableRawPointer?
) -> cmsInt32Number {
    guard let In, let Out, let Cargo else { return 0 }
    let sc = Cargo.assumingMemoryBound(to: PSSamplerCargo.self)

    // Pure white — L* of 100 with a*, b* near zero — is pinned to the
    // space's white when asked.
    if sc.pointee.fixWhite {
        if In[0] == 0xFFFF && In[1] >= 0x7800 && In[1] <= 0x8800 && In[2] >= 0x7800 && In[2] <= 0x8800 {
            guard let ends = endPointsBySpace(sc.pointee.colorSpace) else { return 0 }
            for i in 0..<ends.white.count { Out[i] = ends.white[i] }
        }
    }

    if Int32(In[0]) != sc.pointee.firstComponent {
        if sc.pointee.firstComponent != -1 {
            emit(sc.pointee.m, sc.pointee.postMin)
            sc.pointee.secondComponent = -1
            emit(sc.pointee.m, sc.pointee.postMaj)
        }
        actualColumn = 0
        emit(sc.pointee.m, sc.pointee.preMaj)
        sc.pointee.firstComponent = Int32(In[0])
    }
    if Int32(In[1]) != sc.pointee.secondComponent {
        if sc.pointee.secondComponent != -1 {
            emit(sc.pointee.m, sc.pointee.postMin)
        }
        emit(sc.pointee.m, sc.pointee.preMin)
        sc.pointee.secondComponent = Int32(In[1])
    }
    for i in 0..<Int(sc.pointee.params.pointee.nOutputs) {
        writeByte(sc.pointee.m, word2Byte(Out[i]))
    }
    return 1
}

private func writeCLUT(
    _ m: UnsafeMutablePointer<cmsIOHANDLER>, _ mpe: UnsafeMutablePointer<cmsStage>,
    _ preMaj: String, _ postMaj: String, _ preMin: String, _ postMin: String,
    _ fixWhite: Bool, _ colorSpace: cmsColorSpaceSignature
) {
    guard let data = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = data.pointee.Params
    else { return }
    var sc = PSSamplerCargo(
        params: params, m: m, preMaj: preMaj, postMaj: postMaj, preMin: preMin, postMin: postMin,
        fixWhite: fixWhite, colorSpace: colorSpace
    )
    emit(m, "[")
    let samples = withUnsafeBytes(of: &params.pointee.nSamples) { $0.bindMemory(to: cmsUInt32Number.self).map { $0 } }
    for i in 0..<Int(params.pointee.nInputs) where i < Int(MAX_INPUT_DIMENSIONS) {
        emit(m, " \(samples[i]) ")
    }
    emit(m, " [\n")
    withUnsafeMutablePointer(to: &sc) { cargo in
        _ = cmsStageSampleCLut16bit(mpe, outputValueSampler, UnsafeMutableRawPointer(cargo), cmsUInt32Number(SAMPLER_INSPECT))
    }
    emit(m, postMin)
    emit(m, postMaj)
    emit(m, "] ")
}

private func emitCIEBasedA(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ curve: UnsafeMutablePointer<cmsToneCurve>?, _ blackPoint: cmsCIEXYZ) -> Bool {
    emit(m, "[ /CIEBasedA\n")
    emit(m, "  <<\n")
    emit(m, "/DecodeA ")
    emit1Gamma(m, curve)
    emit(m, " \n")
    emit(m, "/MatrixA [ 0.9642 1.0000 0.8249 ]\n")
    emit(m, "/RangeLMN [ 0.0 0.9642 0.0 1.0000 0.0 0.8249 ]\n")
    emitWhiteBlackD50(m, blackPoint)
    emitIntent(m, cmsUInt32Number(INTENT_PERCEPTUAL))
    emit(m, ">>\n")
    emit(m, "]\n")
    return true
}

private func emitCIEBasedABC(
    _ m: UnsafeMutablePointer<cmsIOHANDLER>, _ matrix: [Double],
    _ curves: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>, _ blackPoint: cmsCIEXYZ
) -> Bool {
    emit(m, "[ /CIEBasedABC\n")
    emit(m, "<<\n")
    emit(m, "/DecodeABC [ ")
    emitNGamma(m, 3, curves)
    emit(m, "]\n")
    emit(m, "/MatrixABC [ ")
    for i in 0..<3 {
        emit(m, "\(cfmt("%.6f", matrix[i])) \(cfmt("%.6f", matrix[i + 3])) \(cfmt("%.6f", matrix[i + 6])) ")
    }
    emit(m, "]\n")
    emit(m, "/RangeLMN [ 0.0 0.9642 0.0 1.0000 0.0 0.8249 ]\n")
    emitWhiteBlackD50(m, blackPoint)
    emitIntent(m, cmsUInt32Number(INTENT_PERCEPTUAL))
    emit(m, ">>\n")
    emit(m, "]\n")
    return true
}

private func emitCIEBasedDEF(
    _ m: UnsafeMutablePointer<cmsIOHANDLER>, _ pipeline: UnsafeMutablePointer<cmsPipeline>,
    _ intent: cmsUInt32Number, _ blackPoint: cmsCIEXYZ
) -> Bool {
    var mpe = cmsPipelineGetPtrToFirstStage(pipeline)
    let preMaj: String, postMaj: String, preMin: String, postMin: String
    switch cmsStageInputChannels(mpe) {
    case 3:
        emit(m, "[ /CIEBasedDEF\n")
        preMaj = "<"; postMaj = ">\n"; preMin = ""; postMin = ""
    case 4:
        emit(m, "[ /CIEBasedDEFG\n")
        preMaj = "["; postMaj = "]\n"; preMin = "<"; postMin = ">\n"
    default:
        return false
    }
    emit(m, "<<\n")
    if let s = mpe, cmsStageType(s) == cmsSigCurveSetElemType,
       let data = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self), let curves = data.pointee.TheCurves
    {
        emit(m, "/DecodeDEF [ ")
        emitNGamma(m, Int(cmsStageOutputChannels(s)), curves)
        emit(m, "]\n")
        mpe = cmsStageNext(s)
    }
    if let s = mpe, cmsStageType(s) == cmsSigCLutElemType {
        emit(m, "/Table ")
        writeCLUT(m, s, preMaj, postMaj, preMin, postMin, false, cmsColorSpaceSignature(0))
        emit(m, "]\n")
    }
    emitLab2XYZ(m)
    emitWhiteBlackD50(m, blackPoint)
    emitIntent(m, intent)
    emit(m, "   >>\n")
    emit(m, "]\n")
    return true
}

/// The Y a grey profile produces for each of 256 greys, as a curve.
private func extractGray2Y(_ ContextID: cmsContext?, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number) -> UnsafeMutablePointer<cmsToneCurve>? {
    let out = cmsBuildTabulatedToneCurve16(ContextID, 256, nil)
    let hXYZ = cmsCreateXYZProfile()
    let xform = cmsCreateTransformTHR(ContextID, hProfile, SLCMS_TYPE_GRAY_8, hXYZ, SLCMS_TYPE_XYZ_DBL, intent, cmsUInt32Number(cmsFLAGS_NOOPTIMIZE))
    if let out, let xform, let table = out.pointee.Table16 {
        for i in 0..<256 {
            var gray = UInt8(i)
            var xyz = cmsCIEXYZ()
            cmsDoTransform(xform, &gray, &xyz, 1)
            table[i] = quickSaturateWord(xyz.Y * 65535.0)
        }
    }
    if let xform { cmsDeleteTransform(xform) }
    if let hXYZ { cmsCloseProfile(hXYZ) }
    return out
}

private func writeInputLUT(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number) -> Bool {
    var inputFormat = cmsFormatterForColorspaceOfProfile(hProfile, 2, 0)
    let nChannels = PixelFormat(inputFormat).channels
    var blackPoint = cmsCIEXYZ()
    _ = cmsDetectBlackPoint(&blackPoint, hProfile, intent, 0)

    let hLab = cmsCreateLab4ProfileTHR(m.pointee.ContextID, nil)
    var profiles: [cmsHPROFILE?] = [hProfile, hLab]
    let xform = cmsCreateMultiprofileTransform(&profiles, 2, inputFormat, SLCMS_TYPE_Lab_DBL, intent, 0)
    cmsCloseProfile(hLab)
    guard let xform else {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Cannot create transform Profile -> Lab", to: m.pointee.ContextID)
        return false
    }
    defer { cmsDeleteTransform(xform) }

    switch nChannels {
    case 1:
        let gray2Y = extractGray2Y(m.pointee.ContextID, hProfile, intent)
        _ = emitCIEBasedA(m, gray2Y, blackPoint)
        cmsFreeToneCurve(gray2Y)
    case 3, 4:
        var outFrm = SLCMS_TYPE_Lab_16
        var deviceLink: UnsafeMutablePointer<cmsPipeline>? = cmsPipelineDup(cmsGetTransformPipeline(xform))
        guard deviceLink != nil else { return false }
        var flags = dwFlags | cmsUInt32Number(cmsFLAGS_FORCE_CLUT)
        _ = _cmsOptimizePipeline(m.pointee.ContextID, &deviceLink, intent, &inputFormat, &outFrm, &flags)
        let rc = emitCIEBasedDEF(m, deviceLink!, intent, blackPoint)
        cmsPipelineFree(deviceLink)
        if !rc { return false }
    default:
        report(
            cmsUInt32Number(cmsERROR_COLORSPACE_CHECK),
            "Only 3, 4 channels are supported for CSA. This profile has \(nChannels) channels.", to: m.pointee.ContextID
        )
        return false
    }
    return true
}

private func writeInputMatrixShaper(
    _ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hProfile: cmsHPROFILE?,
    _ matrix: UnsafeMutablePointer<cmsStage>, _ shaper: UnsafeMutablePointer<cmsStage>
) -> Bool {
    let colorSpace = cmsGetColorSpace(hProfile)
    var blackPoint = cmsCIEXYZ()
    _ = cmsDetectBlackPoint(&blackPoint, hProfile, cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC), 0)
    guard let shaperData = cmsStageData(shaper)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self),
          let curves = shaperData.pointee.TheCurves
    else { return false }

    if colorSpace == cmsSigGrayData {
        return emitCIEBasedA(m, curves[0], blackPoint)
    } else if colorSpace == cmsSigRgbData {
        guard let matrixData = cmsStageData(matrix)?.assumingMemoryBound(to: _cmsStageMatrixData.self),
              let values = matrixData.pointee.Double
        else { return false }
        var mat = [Double](repeating: 0, count: 9)
        for i in 0..<9 { mat[i] = values[i] * maximumEncodeableXYZ }
        return emitCIEBasedABC(m, mat, curves, blackPoint)
    }
    report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Profile is not suitable for CSA. Unsupported colorspace.", to: m.pointee.ContextID)
    return false
}

private func writeNamedColorCSA(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hNamedColor: cmsHPROFILE?, _ intent: cmsUInt32Number) -> Bool {
    let hLab = cmsCreateLab4ProfileTHR(m.pointee.ContextID, nil)
    let xform = cmsCreateTransform(hNamedColor, SLCMS_TYPE_NAMED_COLOR_INDEX, hLab, SLCMS_TYPE_Lab_DBL, intent, 0)
    cmsCloseProfile(hLab)
    guard let xform else { return false }
    defer { cmsDeleteTransform(xform) }
    guard let list = cmsGetNamedColorList(xform) else { return false }

    emit(m, "<<\n")
    emit(m, "(colorlistcomment) (Named color CSA)\n")
    emit(m, "(Prefix) [ (Pantone ) (PANTONE ) ]\n")
    emit(m, "(Suffix) [ ( CV) ( CVC) ( C) ]\n")
    let nColors = cmsNamedColorCount(list)
    var colorName = [CChar](repeating: 0, count: Int(cmsMAX_PATH))
    for i in 0..<nColors {
        var index = cmsUInt16Number(i)
        var lab = cmsCIELab()
        if cmsNamedColorInfo(list, i, &colorName, nil, nil, nil, nil) == 0 { continue }
        cmsDoTransform(xform, &index, &lab, 1)
        emit(m, "  (")
        emitPSEscaped(m, colorName)
        emit(m, ") [ \(cfmt("%.3f", lab.L)) \(cfmt("%.3f", lab.a)) \(cfmt("%.3f", lab.b)) ]\n")
    }
    emit(m, ">>\n")
    return true
}

private func generateCSA(
    _ ContextID: cmsContext?, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number,
    _ mem: UnsafeMutablePointer<cmsIOHANDLER>
) -> cmsUInt32Number {
    if cmsGetDeviceClass(hProfile) == cmsSigNamedColorClass {
        if !writeNamedColorCSA(mem, hProfile, intent) { return 0 }
        return mem.pointee.UsedSpace
    }
    let colorSpace = cmsGetPCS(hProfile)
    if colorSpace != cmsSigXYZData && colorSpace != cmsSigLabData {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Invalid output color space", to: ContextID)
        return 0
    }
    guard let lut = _cmsReadInputLUT(hProfile, intent) else { return 0 }
    defer { cmsPipelineFree(lut) }

    if cmsPipelineStageCount(lut) == 2,
       let shaper = cmsPipelineGetPtrToFirstStage(lut), cmsStageType(shaper) == cmsSigCurveSetElemType,
       let matrix = cmsStageNext(shaper), cmsStageType(matrix) == cmsSigMatrixElemType
    {
        if !writeInputMatrixShaper(mem, hProfile, matrix, shaper) { return 0 }
    } else {
        if !writeInputLUT(mem, hProfile, intent, dwFlags) { return 0 }
    }
    return mem.pointee.UsedSpace
}

/// The chromatic adaptation and black point compensation of the CRD, as
/// PostScript over the PQR stage.
private func emitPQRStage(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hProfile: cmsHPROFILE?, _ doBPC: Bool, _ isAbsolute: Bool) {
    if isAbsolute {
        let white = _cmsReadMediaWhitePoint(hProfile)
        emit(m, "/MatrixPQR [1 0 0 0 1 0 0 0 1 ]\n")
        emit(m, "/RangePQR [ -0.5 2 -0.5 2 -0.5 2 ]\n")
        emit(m, "% Absolute colorimetric -- encode to relative to maximize LUT usage\n"
            + "/TransformPQR [\n"
            + "{0.9642 mul \(cfmt("%g", white.X)) div exch pop exch pop exch pop exch pop} bind\n"
            + "{1.0000 mul \(cfmt("%g", white.Y)) div exch pop exch pop exch pop exch pop} bind\n"
            + "{0.8249 mul \(cfmt("%g", white.Z)) div exch pop exch pop exch pop exch pop} bind\n]\n")
        return
    }
    emit(m, "% Bradford Cone Space\n/MatrixPQR [0.8951 -0.7502 0.0389 0.2664 1.7135 -0.0685 -0.1614 0.0367 1.0296 ] \n")
    emit(m, "/RangePQR [ -0.5 2 -0.5 2 -0.5 2 ]\n")
    if !doBPC {
        emit(m, "% VonKries-like transform in Bradford Cone Space\n"
            + "/TransformPQR [\n"
            + "{exch pop exch 3 get mul exch pop exch 3 get div} bind\n"
            + "{exch pop exch 4 get mul exch pop exch 4 get div} bind\n"
            + "{exch pop exch 5 get mul exch pop exch 5 get div} bind\n]\n")
    } else {
        emit(m, "% VonKries-like transform in Bradford Cone Space plus BPC\n/TransformPQR [\n")
        emit(m, "{4 index 3 get div 2 index 3 get mul 2 index 3 get 2 index 3 get sub mul 2 index 3 get 4 index 3 get 3 index 3 get sub mul sub 3 index 3 get 3 index 3 get exch sub div exch pop exch pop exch pop exch pop } bind\n")
        emit(m, "{4 index 4 get div 2 index 4 get mul 2 index 4 get 2 index 4 get sub mul 2 index 4 get 4 index 4 get 3 index 4 get sub mul sub 3 index 4 get 3 index 4 get exch sub div exch pop exch pop exch pop exch pop } bind\n")
        emit(m, "{4 index 5 get div 2 index 5 get mul 2 index 5 get 2 index 5 get sub mul 2 index 5 get 4 index 5 get 3 index 5 get sub mul sub 3 index 5 get 3 index 5 get exch sub div exch pop exch pop exch pop exch pop } bind\n]\n")
    }
}

private func emitXYZ2Lab(_ m: UnsafeMutablePointer<cmsIOHANDLER>) {
    emit(m, "/RangeLMN [ -0.635 2.0 0 2 -0.635 2.0 ]\n")
    emit(m, "/EncodeLMN [\n")
    emit(m, "{ 0.964200  div dup 0.008856 le {7.787 mul 16 116 div add}{1 3 div exp} ifelse } bind\n")
    emit(m, "{ 1.000000  div dup 0.008856 le {7.787 mul 16 116 div add}{1 3 div exp} ifelse } bind\n")
    emit(m, "{ 0.824900  div dup 0.008856 le {7.787 mul 16 116 div add}{1 3 div exp} ifelse } bind\n")
    emit(m, "]\n")
    emit(m, "/MatrixABC [ 0 1 0 1 -1 1 0 0 -1 ]\n")
    emit(m, "/EncodeABC [\n")
    emit(m, "{ 116 mul  16 sub 100 div  } bind\n")
    emit(m, "{ 500 mul 128 add 256 div  } bind\n")
    emit(m, "{ 200 mul 128 add 256 div  } bind\n")
    emit(m, "]\n")
}

private func writeOutputLUT(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number) -> Bool {
    let doBPC = dwFlags & cmsUInt32Number(cmsFLAGS_BLACKPOINTCOMPENSATION) != 0
    var fixWhite = dwFlags & cmsUInt32Number(cmsFLAGS_NOWHITEONWHITEFIXUP) == 0
    var inFrm = SLCMS_TYPE_Lab_16

    guard let hLab = cmsCreateLab4ProfileTHR(m.pointee.ContextID, nil) else { return false }
    var outputFormat = cmsFormatterForColorspaceOfProfile(hProfile, 2, 0)
    let nChannels = PixelFormat(outputFormat).channels
    let colorSpace = cmsGetColorSpace(hProfile)

    var relativeEncodingIntent = intent
    if relativeEncodingIntent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) {
        relativeEncodingIntent = cmsUInt32Number(INTENT_RELATIVE_COLORIMETRIC)
    }

    var profiles: [cmsHPROFILE?] = [hLab, hProfile]
    let xform = cmsCreateMultiprofileTransformTHR(m.pointee.ContextID, &profiles, 2, SLCMS_TYPE_Lab_DBL, outputFormat, relativeEncodingIntent, 0)
    cmsCloseProfile(hLab)
    guard let xform else {
        report(cmsUInt32Number(cmsERROR_COLORSPACE_CHECK), "Cannot create transform Lab -> Profile in CRD creation", to: m.pointee.ContextID)
        return false
    }
    defer { cmsDeleteTransform(xform) }

    var deviceLink: UnsafeMutablePointer<cmsPipeline>? = cmsPipelineDup(cmsGetTransformPipeline(xform))
    guard deviceLink != nil else {
        report(cmsUInt32Number(cmsERROR_CORRUPTION_DETECTED), "Cannot access link for CRD", to: m.pointee.ContextID)
        return false
    }
    var flags = dwFlags | cmsUInt32Number(cmsFLAGS_FORCE_CLUT)
    if _cmsOptimizePipeline(m.pointee.ContextID, &deviceLink, relativeEncodingIntent, &inFrm, &outputFormat, &flags) == 0 {
        cmsPipelineFree(deviceLink)
        report(cmsUInt32Number(cmsERROR_CORRUPTION_DETECTED), "Cannot create CLUT table for CRD", to: m.pointee.ContextID)
        return false
    }
    defer { cmsPipelineFree(deviceLink) }

    emit(m, "<<\n")
    emit(m, "/ColorRenderingType 1\n")
    var blackPoint = cmsCIEXYZ()
    _ = cmsDetectBlackPoint(&blackPoint, hProfile, intent, 0)
    emitWhiteBlackD50(m, blackPoint)
    emitPQRStage(m, hProfile, doBPC, intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC))
    emitXYZ2Lab(m)

    if intent == cmsUInt32Number(INTENT_ABSOLUTE_COLORIMETRIC) { fixWhite = false }

    emit(m, "/RenderTable ")
    if let first = cmsPipelineGetPtrToFirstStage(deviceLink) {
        if cmsStageType(first) != cmsSigCLutElemType {
            report(cmsUInt32Number(cmsERROR_CORRUPTION_DETECTED), "Cannot create CLUT, revise your flags!", to: m.pointee.ContextID)
            return false
        }
        writeCLUT(m, first, "<", ">\n", "", "", fixWhite, colorSpace)
    }
    emit(m, " \(nChannels) {} bind ")
    for _ in 1..<max(nChannels, 1) { emit(m, "dup ") }
    emit(m, "]\n")
    emitIntent(m, intent)
    emit(m, ">>\n")
    if flags & cmsUInt32Number(cmsFLAGS_NODEFAULTRESOURCEDEF) == 0 {
        emit(m, "/Current exch /ColorRendering defineresource pop\n")
    }
    return true
}

private func buildColorantList(_ nColorant: Int, _ out: [cmsUInt16Number]) -> String {
    let n = min(nColorant, maximumChannels)
    return (0..<n).map { cfmt("%.3f", Double(out[$0]) / 65535.0) }.joined(separator: " ")
}

private func writeNamedColorCRD(_ m: UnsafeMutablePointer<cmsIOHANDLER>, _ hNamedColor: cmsHPROFILE?, _ intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number) -> Bool {
    let outputFormat = cmsFormatterForColorspaceOfProfile(hNamedColor, 2, 0)
    let nColorant = PixelFormat(outputFormat).channels
    guard let xform = cmsCreateTransform(hNamedColor, SLCMS_TYPE_NAMED_COLOR_INDEX, nil, outputFormat, intent, dwFlags) else { return false }
    defer { cmsDeleteTransform(xform) }
    guard let list = cmsGetNamedColorList(xform) else { return false }

    emit(m, "<<\n")
    emit(m, "(colorlistcomment) (Named profile) \n")
    emit(m, "(Prefix) [ (Pantone ) (PANTONE ) ]\n")
    emit(m, "(Suffix) [ ( CV) ( CVC) ( C) ]\n")
    let nColors = cmsNamedColorCount(list)
    var colorName = [CChar](repeating: 0, count: Int(cmsMAX_PATH))
    for i in 0..<nColors {
        var index = cmsUInt16Number(i)
        var out = [cmsUInt16Number](repeating: 0, count: maximumChannels)
        if cmsNamedColorInfo(list, i, &colorName, nil, nil, nil, nil) == 0 { continue }
        cmsDoTransform(xform, &index, &out, 1)
        emit(m, "  (")
        emitPSEscaped(m, colorName)
        emit(m, ") [ \(buildColorantList(nColorant, out)) ]\n")
    }
    emit(m, "   >>")
    if dwFlags & cmsUInt32Number(cmsFLAGS_NODEFAULTRESOURCEDEF) == 0 {
        emit(m, " /Current exch /HPSpotTable defineresource pop\n")
    }
    return true
}

private func generateCRD(
    _ ContextID: cmsContext?, _ hProfile: cmsHPROFILE?, _ intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number,
    _ mem: UnsafeMutablePointer<cmsIOHANDLER>
) -> cmsUInt32Number {
    if dwFlags & cmsUInt32Number(cmsFLAGS_NODEFAULTRESOURCEDEF) == 0 {
        emitHeader(mem, "Color Rendering Dictionary (CRD)", hProfile)
    }
    if cmsGetDeviceClass(hProfile) == cmsSigNamedColorClass {
        if !writeNamedColorCRD(mem, hProfile, intent, dwFlags) { return 0 }
    } else {
        if !writeOutputLUT(mem, hProfile, intent, dwFlags) { return 0 }
    }
    if dwFlags & cmsUInt32Number(cmsFLAGS_NODEFAULTRESOURCEDEF) == 0 {
        emit(mem, "%%EndResource\n")
        emit(mem, "\n% CRD End\n")
    }
    return mem.pointee.UsedSpace
}

@c @implementation
public func cmsGetPostScriptColorResource(
    _ ContextID: cmsContext?, _ Type: cmsPSResourceType, _ hProfile: cmsHPROFILE?,
    _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number, _ io: UnsafeMutablePointer<cmsIOHANDLER>?
) -> cmsUInt32Number {
    guard let io else { return 0 }
    switch Type {
    case cmsPS_RESOURCE_CSA:
        return generateCSA(ContextID, hProfile, Intent, dwFlags, io)
    default:
        return generateCRD(ContextID, hProfile, Intent, dwFlags, io)
    }
}

@c @implementation
public func cmsGetPostScriptCRD(
    _ ContextID: cmsContext?, _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number,
    _ Buffer: UnsafeMutableRawPointer?, _ dwBufferLen: cmsUInt32Number
) -> cmsUInt32Number {
    let mem = Buffer == nil
        ? cmsOpenIOhandlerFromNULL(ContextID)
        : cmsOpenIOhandlerFromMem(ContextID, Buffer, dwBufferLen, "w")
    guard let mem else { return 0 }
    let used = cmsGetPostScriptColorResource(ContextID, cmsPS_RESOURCE_CRD, hProfile, Intent, dwFlags, mem)
    _ = cmsCloseIOhandler(mem)
    return used
}

@c @implementation
public func cmsGetPostScriptCSA(
    _ ContextID: cmsContext?, _ hProfile: cmsHPROFILE?, _ Intent: cmsUInt32Number, _ dwFlags: cmsUInt32Number,
    _ Buffer: UnsafeMutableRawPointer?, _ dwBufferLen: cmsUInt32Number
) -> cmsUInt32Number {
    let mem = Buffer == nil
        ? cmsOpenIOhandlerFromNULL(ContextID)
        : cmsOpenIOhandlerFromMem(ContextID, Buffer, dwBufferLen, "w")
    guard let mem else { return 0 }
    let used = cmsGetPostScriptColorResource(ContextID, cmsPS_RESOURCE_CSA, hProfile, Intent, dwFlags, mem)
    _ = cmsCloseIOhandler(mem)
    return used
}
