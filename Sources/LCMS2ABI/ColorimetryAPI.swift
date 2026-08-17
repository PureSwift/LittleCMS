import CLCMS2
import LittleCMS

// Colour space conversions, colour differences, and adaptation.
//
// cmsCIEXYZ, cmsCIExyY, cmsCIELab and cmsCIELCh are all caller-allocated
// value types with published layouts, so the engine's mirrors are checked
// against them in Tests/LittleCMSTests/LayoutTests.swift and the two are
// converted by field rather than reinterpreted — three doubles either way,
// and naming the fields keeps a reordering from passing silently.

@inline(__always)
func engine(_ v: cmsCIEXYZ) -> CIEXYZ { CIEXYZ(x: v.X, y: v.Y, z: v.Z) }
@inline(__always)
func abi(_ v: CIEXYZ) -> cmsCIEXYZ { cmsCIEXYZ(X: v.x, Y: v.y, Z: v.z) }
@inline(__always)
func engine(_ v: cmsCIExyY) -> CIExyY { CIExyY(x: v.x, y: v.y, yLuminance: v.Y) }
@inline(__always)
func abi(_ v: CIExyY) -> cmsCIExyY { cmsCIExyY(x: v.x, y: v.y, Y: v.yLuminance) }
@inline(__always)
func engine(_ v: cmsCIELab) -> CIELab { CIELab(l: v.L, a: v.a, b: v.b) }
@inline(__always)
func abi(_ v: CIELab) -> cmsCIELab { cmsCIELab(L: v.l, a: v.a, b: v.b) }
@inline(__always)
func engine(_ v: cmsCIELCh) -> CIELCh { CIELCh(l: v.L, c: v.C, h: v.h) }
@inline(__always)
func abi(_ v: CIELCh) -> cmsCIELCh { cmsCIELCh(L: v.l, C: v.c, h: v.h) }

// -- the standard illuminant -------------------------------------------
//
// These return pointers to storage that outlives every caller, because
// the reference returns pointers to its own statics and clients keep them.

private nonisolated(unsafe) let d50XYZ: UnsafeMutablePointer<cmsCIEXYZ> = {
    let storage = UnsafeMutablePointer<cmsCIEXYZ>.allocate(capacity: 1)
    storage.initialize(to: abi(CIEXYZ.d50))
    return storage
}()

private nonisolated(unsafe) let d50xyY: UnsafeMutablePointer<cmsCIExyY> = {
    let storage = UnsafeMutablePointer<cmsCIExyY>.allocate(capacity: 1)
    storage.initialize(to: abi(CIEXYZ.d50.chromaticity))
    return storage
}()

@c @implementation
public func cmsD50_XYZ() -> UnsafePointer<cmsCIEXYZ>? {
    UnsafePointer(d50XYZ)
}

@c @implementation
public func cmsD50_xyY() -> UnsafePointer<cmsCIExyY>? {
    UnsafePointer(d50xyY)
}

// -- conversions -------------------------------------------------------

@c @implementation
public func cmsXYZ2xyY(_ Dest: UnsafeMutablePointer<cmsCIExyY>?, _ Source: UnsafePointer<cmsCIEXYZ>?) {
    guard let Dest, let Source else { return }
    Dest.pointee = abi(engine(Source.pointee).chromaticity)
}

@c @implementation
public func cmsxyY2XYZ(_ Dest: UnsafeMutablePointer<cmsCIEXYZ>?, _ Source: UnsafePointer<cmsCIExyY>?) {
    guard let Dest, let Source else { return }
    Dest.pointee = abi(engine(Source.pointee).tristimulus)
}

@c @implementation
public func cmsXYZ2Lab(
    _ WhitePoint: UnsafePointer<cmsCIEXYZ>?,
    _ Lab: UnsafeMutablePointer<cmsCIELab>?,
    _ xyz: UnsafePointer<cmsCIEXYZ>?
) {
    guard let Lab, let xyz else { return }
    // A null white point means D50, which is what the connection space is.
    let white = WhitePoint.map { engine($0.pointee) } ?? .d50
    Lab.pointee = abi(CIELab(engine(xyz.pointee), whitePoint: white))
}

@c @implementation
public func cmsLab2XYZ(
    _ WhitePoint: UnsafePointer<cmsCIEXYZ>?,
    _ xyz: UnsafeMutablePointer<cmsCIEXYZ>?,
    _ Lab: UnsafePointer<cmsCIELab>?
) {
    guard let xyz, let Lab else { return }
    let white = WhitePoint.map { engine($0.pointee) } ?? .d50
    xyz.pointee = abi(engine(Lab.pointee).tristimulus(whitePoint: white))
}

@c @implementation
public func cmsLab2LCh(_ LCh: UnsafeMutablePointer<cmsCIELCh>?, _ Lab: UnsafePointer<cmsCIELab>?) {
    guard let LCh, let Lab else { return }
    LCh.pointee = abi(engine(Lab.pointee).cylindrical)
}

@c @implementation
public func cmsLCh2Lab(_ Lab: UnsafeMutablePointer<cmsCIELab>?, _ LCh: UnsafePointer<cmsCIELCh>?) {
    guard let Lab, let LCh else { return }
    Lab.pointee = abi(engine(LCh.pointee).rectangular)
}

// -- the encoded forms -------------------------------------------------

@inline(__always)
private func triple(_ p: UnsafePointer<cmsUInt16Number>) -> (UInt16, UInt16, UInt16) {
    (p[0], p[1], p[2])
}

@inline(__always)
private func store(_ v: (UInt16, UInt16, UInt16), into p: UnsafeMutablePointer<cmsUInt16Number>) {
    p[0] = v.0
    p[1] = v.1
    p[2] = v.2
}

@c @implementation
public func cmsLabEncoded2Float(
    _ Lab: UnsafeMutablePointer<cmsCIELab>?,
    _ wLab: UnsafePointer<cmsUInt16Number>?
) {
    guard let Lab, let wLab else { return }
    Lab.pointee = abi(CIELab(encodedV4: triple(wLab)))
}

@c @implementation
public func cmsFloat2LabEncoded(
    _ wLab: UnsafeMutablePointer<cmsUInt16Number>?,
    _ fLab: UnsafePointer<cmsCIELab>?
) {
    guard let wLab, let fLab else { return }
    store(engine(fLab.pointee).encodedV4, into: wLab)
}

@c @implementation
public func cmsLabEncoded2FloatV2(
    _ Lab: UnsafeMutablePointer<cmsCIELab>?,
    _ wLab: UnsafePointer<cmsUInt16Number>?
) {
    guard let Lab, let wLab else { return }
    Lab.pointee = abi(CIELab(encodedV2: triple(wLab)))
}

@c @implementation
public func cmsFloat2LabEncodedV2(
    _ wLab: UnsafeMutablePointer<cmsUInt16Number>?,
    _ fLab: UnsafePointer<cmsCIELab>?
) {
    guard let wLab, let fLab else { return }
    store(engine(fLab.pointee).encodedV2, into: wLab)
}

@c @implementation
public func cmsXYZEncoded2Float(
    _ fxyz: UnsafeMutablePointer<cmsCIEXYZ>?,
    _ XYZ: UnsafePointer<cmsUInt16Number>?
) {
    guard let fxyz, let XYZ else { return }
    fxyz.pointee = abi(CIEXYZ(encoded: triple(XYZ)))
}

@c @implementation
public func cmsFloat2XYZEncoded(
    _ XYZ: UnsafeMutablePointer<cmsUInt16Number>?,
    _ fXYZ: UnsafePointer<cmsCIEXYZ>?
) {
    guard let XYZ, let fXYZ else { return }
    store(engine(fXYZ.pointee).encoded, into: XYZ)
}

// -- colour differences ------------------------------------------------

@c @implementation
public func cmsDeltaE(_ Lab1: UnsafePointer<cmsCIELab>?, _ Lab2: UnsafePointer<cmsCIELab>?) -> cmsFloat64Number {
    guard let Lab1, let Lab2 else { return 0 }
    return engine(Lab1.pointee).deltaE(to: engine(Lab2.pointee))
}

@c @implementation
public func cmsCIE94DeltaE(_ Lab1: UnsafePointer<cmsCIELab>?, _ Lab2: UnsafePointer<cmsCIELab>?) -> cmsFloat64Number {
    guard let Lab1, let Lab2 else { return 0 }
    return engine(Lab1.pointee).deltaE94(to: engine(Lab2.pointee))
}

@c @implementation
public func cmsBFDdeltaE(_ Lab1: UnsafePointer<cmsCIELab>?, _ Lab2: UnsafePointer<cmsCIELab>?) -> cmsFloat64Number {
    guard let Lab1, let Lab2 else { return 0 }
    return engine(Lab1.pointee).deltaEBFD(to: engine(Lab2.pointee))
}

@c @implementation
public func cmsCMCdeltaE(
    _ Lab1: UnsafePointer<cmsCIELab>?,
    _ Lab2: UnsafePointer<cmsCIELab>?,
    _ l: cmsFloat64Number,
    _ c: cmsFloat64Number
) -> cmsFloat64Number {
    guard let Lab1, let Lab2 else { return 0 }
    return engine(Lab1.pointee).deltaECMC(to: engine(Lab2.pointee), l: l, c: c)
}

@c @implementation
public func cmsCIE2000DeltaE(
    _ Lab1: UnsafePointer<cmsCIELab>?,
    _ Lab2: UnsafePointer<cmsCIELab>?,
    _ Kl: cmsFloat64Number,
    _ Kc: cmsFloat64Number,
    _ Kh: cmsFloat64Number
) -> cmsFloat64Number {
    guard let Lab1, let Lab2 else { return 0 }
    return engine(Lab1.pointee).deltaE2000(to: engine(Lab2.pointee), kL: Kl, kC: Kc, kH: Kh)
}

// -- white points and adaptation ---------------------------------------

@c @implementation
public func cmsWhitePointFromTemp(
    _ WhitePoint: UnsafeMutablePointer<cmsCIExyY>?,
    _ TempK: cmsFloat64Number
) -> cmsBool {
    guard let WhitePoint else { return 0 }
    guard let point = CIExyY(temperature: TempK) else {
        report(cmsUInt32Number(cmsERROR_RANGE), "cmsWhitePointFromTemp: invalid temp", to: nil)
        return 0
    }
    WhitePoint.pointee = abi(point)
    return 1
}

@c @implementation
public func cmsTempFromWhitePoint(
    _ TempK: UnsafeMutablePointer<cmsFloat64Number>?,
    _ WhitePoint: UnsafePointer<cmsCIExyY>?
) -> cmsBool {
    guard let TempK, let WhitePoint else { return 0 }
    guard let temperature = engine(WhitePoint.pointee).temperature else { return 0 }
    TempK.pointee = temperature
    return 1
}

@c @implementation
public func cmsAdaptToIlluminant(
    _ Result: UnsafeMutablePointer<cmsCIEXYZ>?,
    _ SourceWhitePt: UnsafePointer<cmsCIEXYZ>?,
    _ Illuminant: UnsafePointer<cmsCIEXYZ>?,
    _ Value: UnsafePointer<cmsCIEXYZ>?
) -> cmsBool {
    guard let Result, let SourceWhitePt, let Illuminant, let Value else { return 0 }
    guard let adapted = engine(Value.pointee).adapted(
        to: engine(Illuminant.pointee),
        from: engine(SourceWhitePt.pointee)
    ) else { return 0 }
    Result.pointee = abi(adapted)
    return 1
}

@c @implementation
public func cmsDesaturateLab(
    _ Lab: UnsafeMutablePointer<cmsCIELab>?,
    _ amax: Double,
    _ amin: Double,
    _ bmax: Double,
    _ bmin: Double
) -> cmsBool {
    guard let Lab else { return 0 }
    var value = engine(Lab.pointee)
    let outcome = value.desaturate(aMax: amax, aMin: amin, bMax: bmax, bMin: bmin)
    Lab.pointee = abi(value)
    return outcome ? 1 : 0
}

// -- colour space notations --------------------------------------------------

// The library carries two names for a colour space: the ICC signature a
// profile stores, and the small `PT_*` code a pixel format packs into
// five bits.  These translate between them.
//
// Neither is a bijection.  Several signatures collapse onto one code —
// `cmsSig4colorData` and `cmsSigMCH4Data` are both `PT_MCH4` — so the
// round trip through the code and back does not always return the
// signature it started from.

@c @implementation
public func _cmsLCMScolorSpace(_ ProfileSpace: cmsColorSpaceSignature) -> cmsInt32Number {
    switch ProfileSpace {
    case cmsSigGrayData: return cmsInt32Number(PT_GRAY)
    case cmsSigRgbData: return cmsInt32Number(PT_RGB)
    case cmsSigCmyData: return cmsInt32Number(PT_CMY)
    case cmsSigCmykData: return cmsInt32Number(PT_CMYK)
    case cmsSigYCbCrData: return cmsInt32Number(PT_YCbCr)
    case cmsSigLuvData: return cmsInt32Number(PT_YUV)
    case cmsSigXYZData: return cmsInt32Number(PT_XYZ)
    case cmsSigLabData: return cmsInt32Number(PT_Lab)
    case cmsSigLuvKData: return cmsInt32Number(PT_YUVK)
    case cmsSigHsvData: return cmsInt32Number(PT_HSV)
    case cmsSigHlsData: return cmsInt32Number(PT_HLS)
    case cmsSigYxyData: return cmsInt32Number(PT_Yxy)

    // The `ncolor` and `MCHn` spellings of the same width answer alike.
    case cmsSig1colorData, cmsSigMCH1Data: return cmsInt32Number(PT_MCH1)
    case cmsSig2colorData, cmsSigMCH2Data: return cmsInt32Number(PT_MCH2)
    case cmsSig3colorData, cmsSigMCH3Data: return cmsInt32Number(PT_MCH3)
    case cmsSig4colorData, cmsSigMCH4Data: return cmsInt32Number(PT_MCH4)
    case cmsSig5colorData, cmsSigMCH5Data: return cmsInt32Number(PT_MCH5)
    case cmsSig6colorData, cmsSigMCH6Data: return cmsInt32Number(PT_MCH6)
    case cmsSig7colorData, cmsSigMCH7Data: return cmsInt32Number(PT_MCH7)
    case cmsSig8colorData, cmsSigMCH8Data: return cmsInt32Number(PT_MCH8)
    case cmsSig9colorData, cmsSigMCH9Data: return cmsInt32Number(PT_MCH9)
    case cmsSig10colorData, cmsSigMCHAData: return cmsInt32Number(PT_MCH10)
    case cmsSig11colorData, cmsSigMCHBData: return cmsInt32Number(PT_MCH11)
    case cmsSig12colorData, cmsSigMCHCData: return cmsInt32Number(PT_MCH12)
    case cmsSig13colorData, cmsSigMCHDData: return cmsInt32Number(PT_MCH13)
    case cmsSig14colorData, cmsSigMCHEData: return cmsInt32Number(PT_MCH14)
    case cmsSig15colorData, cmsSigMCHFData: return cmsInt32Number(PT_MCH15)

    default: return 0
    }
}

@c @implementation
public func _cmsICCcolorSpace(_ OurNotation: cmsInt32Number) -> cmsColorSpaceSignature {
    switch OurNotation {
    // One and two are accepted alongside the named codes: an older
    // numbering where a channel count stood in for the space.
    case 1, cmsInt32Number(PT_GRAY): return cmsSigGrayData
    case 2, cmsInt32Number(PT_RGB): return cmsSigRgbData

    case cmsInt32Number(PT_CMY): return cmsSigCmyData
    case cmsInt32Number(PT_CMYK): return cmsSigCmykData
    case cmsInt32Number(PT_YCbCr): return cmsSigYCbCrData
    case cmsInt32Number(PT_YUV): return cmsSigLuvData
    case cmsInt32Number(PT_XYZ): return cmsSigXYZData

    // Both Lab codes name the same signature; the version distinction
    // lives in the encoding, not the space.
    case cmsInt32Number(PT_LabV2), cmsInt32Number(PT_Lab): return cmsSigLabData

    case cmsInt32Number(PT_YUVK): return cmsSigLuvKData
    case cmsInt32Number(PT_HSV): return cmsSigHsvData
    case cmsInt32Number(PT_HLS): return cmsSigHlsData
    case cmsInt32Number(PT_Yxy): return cmsSigYxyData

    // Back the other way, only the `MCHn` spelling is produced.
    case cmsInt32Number(PT_MCH1): return cmsSigMCH1Data
    case cmsInt32Number(PT_MCH2): return cmsSigMCH2Data
    case cmsInt32Number(PT_MCH3): return cmsSigMCH3Data
    case cmsInt32Number(PT_MCH4): return cmsSigMCH4Data
    case cmsInt32Number(PT_MCH5): return cmsSigMCH5Data
    case cmsInt32Number(PT_MCH6): return cmsSigMCH6Data
    case cmsInt32Number(PT_MCH7): return cmsSigMCH7Data
    case cmsInt32Number(PT_MCH8): return cmsSigMCH8Data
    case cmsInt32Number(PT_MCH9): return cmsSigMCH9Data
    case cmsInt32Number(PT_MCH10): return cmsSigMCHAData
    case cmsInt32Number(PT_MCH11): return cmsSigMCHBData
    case cmsInt32Number(PT_MCH12): return cmsSigMCHCData
    case cmsInt32Number(PT_MCH13): return cmsSigMCHDData
    case cmsInt32Number(PT_MCH14): return cmsSigMCHEData
    case cmsInt32Number(PT_MCH15): return cmsSigMCHFData

    default: return cmsColorSpaceSignature(0)
    }
}

/// Channels, with a space the library does not know answered as three
/// rather than refused — which is why `cmsChannelsOfColorSpace` exists
/// alongside it and returns -1 instead.
@c @implementation
public func cmsChannelsOf(_ ColorSpace: cmsColorSpaceSignature) -> cmsUInt32Number {
    let n = cmsChannelsOfColorSpace(ColorSpace)
    if n < 0 { return 3 }
    return cmsUInt32Number(n)
}
