// The CIECAM02 colour appearance model: XYZ under stated viewing
// conditions to lightness, chroma and hue, and back.
//
// Ported step by step from the reference, whose arithmetic — including
// its own value of pi and its `pow(x, 0.5)` square roots — is what the
// numbers are measured against.

/// A colour in the model's J, C, h correlates.
@frozen
public struct CIEJCh: Equatable, Sendable {
    public var j: Double
    public var c: Double
    public var h: Double

    @inlinable
    public init(j: Double = 0, c: Double = 0, h: Double = 0) {
        self.j = j
        self.c = c
        self.h = h
    }
}

/// The surround a colour is viewed in.
public enum Surround: UInt32, Sendable {
    case average = 1
    case dim = 2
    case dark = 3
    case cutSheet = 4
}

/// What the model needs to know about the viewing environment.
public struct ViewingConditions: Sendable {
    public var whitePoint: CIEXYZ
    /// Background luminance factor.
    public var yb: Double
    /// Adapting field luminance, in cd/m².
    public var la: Double
    /// Any raw value; the four known surrounds have their own parameters
    /// and every other value means average.
    public var surround: UInt32
    /// The degree of adaptation, or `ViewingConditions.calculateD` to
    /// let the model derive it.
    public var d: Double

    public static let calculateD = -1.0

    public init(whitePoint: CIEXYZ, yb: Double, la: Double, surround: UInt32, d: Double) {
        self.whitePoint = whitePoint
        self.yb = yb
        self.la = la
        self.surround = surround
        self.d = d
    }
}

/// The reference's pi, kept to its ten digits.
private let pi = 3.141592654

/// A colour on its way through the model, every intermediate kept.
private struct CAM02Color {
    var xyz = (0.0, 0.0, 0.0)
    var rgb = (0.0, 0.0, 0.0)
    var rgbc = (0.0, 0.0, 0.0)
    var rgbp = (0.0, 0.0, 0.0)
    var rgbpa = (0.0, 0.0, 0.0)
    var a = 0.0, b = 0.0, h = 0.0, e = 0.0, bigH = 0.0, bigA = 0.0
    var j = 0.0, q = 0.0, s = 0.0, t = 0.0, c = 0.0, m = 0.0
}

/// A CIECAM02 model set up for one set of viewing conditions.
public struct CIECAM02: Sendable {
    fileprivate var adoptedWhite: CAM02Color
    fileprivate let la: Double, yb: Double
    fileprivate let f: Double, c: Double, nc: Double
    fileprivate let surround: UInt32
    fileprivate let n: Double, nbb: Double, ncb: Double, z: Double, fl: Double, d: Double

    public init(_ vc: ViewingConditions) {
        var white = CAM02Color()
        white.xyz = (vc.whitePoint.x, vc.whitePoint.y, vc.whitePoint.z)
        la = vc.la
        yb = vc.yb
        surround = vc.surround

        switch Surround(rawValue: vc.surround) {
        case .cutSheet:
            f = 0.8; c = 0.41; nc = 0.8
        case .dark:
            f = 0.8; c = 0.525; nc = 0.8
        case .dim:
            f = 0.9; c = 0.59; nc = 0.95
        default:
            f = 1.0; c = 0.69; nc = 1.0
        }

        n = yb / white.xyz.1
        z = 1.48 + pow(n, 0.5)
        nbb = 0.725 * pow(1.0 / n, 0.2)
        fl = CIECAM02.computeFL(la)
        if vc.d == ViewingConditions.calculateD {
            let temp = 1.0 - ((1.0 / 3.6) * exp((-la - 42) / 92.0))
            d = f * temp
        } else {
            d = vc.d
        }
        ncb = nbb

        adoptedWhite = white
        // The white goes through the forward model as far as the
        // achromatic response, which everything after is relative to.
        // The adaptation step reads the white's own CAT02 response, so
        // it is stored before the step runs.
        adoptedWhite = CIECAM02.xyzToCAT02(adoptedWhite)
        adoptedWhite = chromaticAdaptation(adoptedWhite)
        adoptedWhite = CIECAM02.cat02ToHPE(adoptedWhite)
        adoptedWhite = nonlinearCompression(adoptedWhite)
    }

    private static func computeFL(_ la: Double) -> Double {
        let k = 1.0 / ((5.0 * la) + 1.0)
        return 0.2 * pow(k, 4.0) * (5.0 * la) + 0.1 * (pow((1.0 - pow(k, 4.0)), 2.0)) * (pow((5.0 * la), (1.0 / 3.0)))
    }

    private static func xyzToCAT02(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        clr.rgb.0 = (clr.xyz.0 * 0.7328) + (clr.xyz.1 * 0.4296) + (clr.xyz.2 * -0.1624)
        clr.rgb.1 = (clr.xyz.0 * -0.7036) + (clr.xyz.1 * 1.6975) + (clr.xyz.2 * 0.0061)
        clr.rgb.2 = (clr.xyz.0 * 0.0030) + (clr.xyz.1 * 0.0136) + (clr.xyz.2 * 0.9834)
        return clr
    }

    private func chromaticAdaptation(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let wy = adoptedWhite.xyz.1
        clr.rgbc.0 = ((wy * (d / adoptedWhite.rgb.0)) + (1.0 - d)) * clr.rgb.0
        clr.rgbc.1 = ((wy * (d / adoptedWhite.rgb.1)) + (1.0 - d)) * clr.rgb.1
        clr.rgbc.2 = ((wy * (d / adoptedWhite.rgb.2)) + (1.0 - d)) * clr.rgb.2
        return clr
    }

    private static func cat02ToHPE(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let m0 = ((0.38971 * 1.096124) + (0.68898 * 0.454369) + (-0.07868 * -0.009628))
        let m1 = ((0.38971 * -0.278869) + (0.68898 * 0.473533) + (-0.07868 * -0.005698))
        let m2 = ((0.38971 * 0.182745) + (0.68898 * 0.072098) + (-0.07868 * 1.015326))
        let m3 = ((-0.22981 * 1.096124) + (1.18340 * 0.454369) + (0.04641 * -0.009628))
        let m4 = ((-0.22981 * -0.278869) + (1.18340 * 0.473533) + (0.04641 * -0.005698))
        let m5 = ((-0.22981 * 0.182745) + (1.18340 * 0.072098) + (0.04641 * 1.015326))
        let m6 = -0.009628
        let m7 = -0.005698
        let m8 = 1.015326
        clr.rgbp.0 = (clr.rgbc.0 * m0) + (clr.rgbc.1 * m1) + (clr.rgbc.2 * m2)
        clr.rgbp.1 = (clr.rgbc.0 * m3) + (clr.rgbc.1 * m4) + (clr.rgbc.2 * m5)
        clr.rgbp.2 = (clr.rgbc.0 * m6) + (clr.rgbc.1 * m7) + (clr.rgbc.2 * m8)
        return clr
    }

    private func compress(_ v: Double) -> Double {
        if v < 0 {
            let temp = pow((-1.0 * fl * v / 100.0), 0.42)
            return (-1.0 * 400.0 * temp) / (temp + 27.13) + 0.1
        } else {
            let temp = pow((fl * v / 100.0), 0.42)
            return (400.0 * temp) / (temp + 27.13) + 0.1
        }
    }

    private func nonlinearCompression(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        clr.rgbpa.0 = compress(clr.rgbp.0)
        clr.rgbpa.1 = compress(clr.rgbp.1)
        clr.rgbpa.2 = compress(clr.rgbp.2)
        clr.bigA = (((2.0 * clr.rgbpa.0) + clr.rgbpa.1 + (clr.rgbpa.2 / 20.0)) - 0.305) * nbb
        return clr
    }

    private func computeCorrelates(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let a = clr.rgbpa.0 - (12.0 * clr.rgbpa.1 / 11.0) + (clr.rgbpa.2 / 11.0)
        let b = (clr.rgbpa.0 + clr.rgbpa.1 - (2.0 * clr.rgbpa.2)) / 9.0
        let r2d = (180.0 / pi)
        var temp: Double

        if a == 0 {
            if b == 0 { clr.h = 0 } else if b > 0 { clr.h = 90 } else { clr.h = 270 }
        } else if a > 0 {
            temp = b / a
            if b > 0 { clr.h = (r2d * atan(temp)) } else if b == 0 { clr.h = 0 } else { clr.h = (r2d * atan(temp)) + 360 }
        } else {
            temp = b / a
            clr.h = (r2d * atan(temp)) + 180
        }

        let d2r = (pi / 180.0)
        let e = ((12500.0 / 13.0) * nc * ncb) * (cos((clr.h * d2r + 2.0)) + 3.8)

        if clr.h < 20.14 {
            temp = ((clr.h + 122.47) / 1.2) + ((20.14 - clr.h) / 0.8)
            clr.bigH = 300 + (100 * ((clr.h + 122.47) / 1.2)) / temp
        } else if clr.h < 90.0 {
            temp = ((clr.h - 20.14) / 0.8) + ((90.00 - clr.h) / 0.7)
            clr.bigH = (100 * ((clr.h - 20.14) / 0.8)) / temp
        } else if clr.h < 164.25 {
            temp = ((clr.h - 90.00) / 0.7) + ((164.25 - clr.h) / 1.0)
            clr.bigH = 100 + ((100 * ((clr.h - 90.00) / 0.7)) / temp)
        } else if clr.h < 237.53 {
            temp = ((clr.h - 164.25) / 1.0) + ((237.53 - clr.h) / 1.2)
            clr.bigH = 200 + ((100 * ((clr.h - 164.25) / 1.0)) / temp)
        } else {
            temp = ((clr.h - 237.53) / 1.2) + ((360 - clr.h + 20.14) / 0.8)
            clr.bigH = 300 + ((100 * ((clr.h - 237.53) / 1.2)) / temp)
        }

        clr.j = 100.0 * pow((clr.bigA / adoptedWhite.bigA), (c * z))
        clr.q = (4.0 / c) * pow((clr.j / 100.0), 0.5) * (adoptedWhite.bigA + 4.0) * pow(fl, 0.25)
        let t = (e * pow(((a * a) + (b * b)), 0.5)) / (clr.rgbpa.0 + clr.rgbpa.1 + ((21.0 / 20.0) * clr.rgbpa.2))
        clr.c = pow(t, 0.9) * pow((clr.j / 100.0), 0.5) * pow((1.64 - pow(0.29, n)), 0.73)
        clr.m = clr.c * pow(fl, 0.25)
        clr.s = 100.0 * pow((clr.m / clr.q), 0.5)
        return clr
    }

    private func inverseCorrelates(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let d2r = pi / 180.0
        let t = pow((clr.c / (pow((clr.j / 100.0), 0.5) * (pow((1.64 - pow(0.29, n)), 0.73)))), (1.0 / 0.9))
        let e = ((12500.0 / 13.0) * nc * ncb) * (cos((clr.h * d2r + 2.0)) + 3.8)
        clr.bigA = adoptedWhite.bigA * pow((clr.j / 100.0), (1.0 / (c * z)))
        let p2 = (clr.bigA / nbb) + 0.305

        if t <= 0.0 {
            // The special case the spec notes: no division by zero.
            clr.a = 0.0
            clr.b = 0.0
        } else {
            let hr = clr.h * d2r
            let p1 = e / t
            let p3 = 21.0 / 20.0
            if sin(hr).magnitude >= cos(hr).magnitude {
                let p4 = p1 / sin(hr)
                clr.b = (p2 * (2.0 + p3) * (460.0 / 1403.0)) / (p4 + (2.0 + p3) * (220.0 / 1403.0) * (cos(hr) / sin(hr)) - (27.0 / 1403.0) + p3 * (6300.0 / 1403.0))
                clr.a = clr.b * (cos(hr) / sin(hr))
            } else {
                let p5 = p1 / cos(hr)
                clr.a = (p2 * (2.0 + p3) * (460.0 / 1403.0)) / (p5 + (2.0 + p3) * (220.0 / 1403.0) - ((27.0 / 1403.0) - p3 * (6300.0 / 1403.0)) * (sin(hr) / cos(hr)))
                clr.b = clr.a * (sin(hr) / cos(hr))
            }
        }

        clr.rgbpa.0 = ((460.0 / 1403.0) * p2) + ((451.0 / 1403.0) * clr.a) + ((288.0 / 1403.0) * clr.b)
        clr.rgbpa.1 = ((460.0 / 1403.0) * p2) - ((891.0 / 1403.0) * clr.a) - ((261.0 / 1403.0) * clr.b)
        clr.rgbpa.2 = ((460.0 / 1403.0) * p2) - ((220.0 / 1403.0) * clr.a) - ((6300.0 / 1403.0) * clr.b)
        return clr
    }

    private func decompress(_ v: Double) -> Double {
        let c1: Double = (v - 0.1) < 0 ? -1 : 1
        return c1 * (100.0 / fl) * pow(((27.13 * (v - 0.1).magnitude) / (400.0 - (v - 0.1).magnitude)), (1.0 / 0.42))
    }

    private func inverseNonlinearity(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        clr.rgbp.0 = decompress(clr.rgbpa.0)
        clr.rgbp.1 = decompress(clr.rgbpa.1)
        clr.rgbp.2 = decompress(clr.rgbpa.2)
        return clr
    }

    private static func hpeToCAT02(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let m0 = ((0.7328 * 1.910197) + (0.4296 * 0.370950))
        let m1 = ((0.7328 * -1.112124) + (0.4296 * 0.629054))
        let m2 = ((0.7328 * 0.201908) + (0.4296 * 0.000008) - 0.1624)
        let m3 = ((-0.7036 * 1.910197) + (1.6975 * 0.370950))
        let m4 = ((-0.7036 * -1.112124) + (1.6975 * 0.629054))
        let m5 = ((-0.7036 * 0.201908) + (1.6975 * 0.000008) + 0.0061)
        let m6 = ((0.0030 * 1.910197) + (0.0136 * 0.370950))
        let m7 = ((0.0030 * -1.112124) + (0.0136 * 0.629054))
        let m8 = ((0.0030 * 0.201908) + (0.0136 * 0.000008) + 0.9834)
        clr.rgbc.0 = (clr.rgbp.0 * m0) + (clr.rgbp.1 * m1) + (clr.rgbp.2 * m2)
        clr.rgbc.1 = (clr.rgbp.0 * m3) + (clr.rgbp.1 * m4) + (clr.rgbp.2 * m5)
        clr.rgbc.2 = (clr.rgbp.0 * m6) + (clr.rgbp.1 * m7) + (clr.rgbp.2 * m8)
        return clr
    }

    private func inverseChromaticAdaptation(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        let wy = adoptedWhite.xyz.1
        clr.rgb.0 = clr.rgbc.0 / ((wy * d / adoptedWhite.rgb.0) + 1.0 - d)
        clr.rgb.1 = clr.rgbc.1 / ((wy * d / adoptedWhite.rgb.1) + 1.0 - d)
        clr.rgb.2 = clr.rgbc.2 / ((wy * d / adoptedWhite.rgb.2) + 1.0 - d)
        return clr
    }

    private static func cat02ToXYZ(_ clr: CAM02Color) -> CAM02Color {
        var clr = clr
        clr.xyz.0 = (clr.rgb.0 * 1.096124) + (clr.rgb.1 * -0.278869) + (clr.rgb.2 * 0.182745)
        clr.xyz.1 = (clr.rgb.0 * 0.454369) + (clr.rgb.1 * 0.473533) + (clr.rgb.2 * 0.072098)
        clr.xyz.2 = (clr.rgb.0 * -0.009628) + (clr.rgb.1 * -0.005698) + (clr.rgb.2 * 1.015326)
        return clr
    }

    /// XYZ to the appearance correlates.
    public func forward(_ xyz: CIEXYZ) -> CIEJCh {
        var clr = CAM02Color()
        clr.xyz = (xyz.x, xyz.y, xyz.z)
        clr = CIECAM02.xyzToCAT02(clr)
        clr = chromaticAdaptation(clr)
        clr = CIECAM02.cat02ToHPE(clr)
        clr = nonlinearCompression(clr)
        clr = computeCorrelates(clr)
        return CIEJCh(j: clr.j, c: clr.c, h: clr.h)
    }

    /// The appearance correlates back to XYZ.
    public func reverse(_ jch: CIEJCh) -> CIEXYZ {
        var clr = CAM02Color()
        clr.j = jch.j
        clr.c = jch.c
        clr.h = jch.h
        clr = inverseCorrelates(clr)
        clr = inverseNonlinearity(clr)
        clr = CIECAM02.hpeToCAT02(clr)
        clr = inverseChromaticAdaptation(clr)
        clr = CIECAM02.cat02ToXYZ(clr)
        return CIEXYZ(x: clr.xyz.0, y: clr.xyz.1, z: clr.xyz.2)
    }
}
