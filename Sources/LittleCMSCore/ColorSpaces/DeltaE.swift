// How far apart two colours are.
//
// Five metrics, each the industry's answer from a different decade, and
// each ported expression for expression: the constants are empirical, the
// groupings decide the last bit, and a tidier arrangement would be a
// different number.

@inlinable
func squared(_ v: Double) -> Double { v * v }

@inlinable
func radians(_ degrees: Double) -> Double { (degrees * Double.pi) / 180.0 }

extension CIELab {
    /// CIE 1976: the plain Euclidean distance.
    public func deltaE(to other: CIELab) -> Double {
        let dL = abs(l - other.l)
        let da = abs(a - other.a)
        let db = abs(b - other.b)
        return pow(squared(dL) + squared(da) + squared(db), 0.5)
    }

    /// CIE 1994.
    public func deltaE94(to other: CIELab) -> Double {
        let dL = abs(l - other.l)

        let lch1 = cylindrical
        let lch2 = other.cylindrical

        let dC = abs(lch1.c - lch2.c)
        let dE = deltaE(to: other)

        let dhsq = squared(dE) - squared(dL) - squared(dC)
        let dh = dhsq < 0 ? 0 : pow(dhsq, 0.5)

        let c12 = (lch1.c * lch2.c).squareRoot()
        let sc = 1.0 + (0.048 * c12)
        let sh = 1.0 + (0.014 * c12)

        return (squared(dL) + squared(dC) / squared(sc) + squared(dh) / squared(sh)).squareRoot()
    }

    /// BFD.
    public func deltaEBFD(to other: CIELab) -> Double {
        let lbfd1 = CIELab.computeLBFD(self)
        let lbfd2 = CIELab.computeLBFD(other)
        let deltaL = lbfd2 - lbfd1

        let lch1 = cylindrical
        let lch2 = other.cylindrical

        let deltaC = lch2.c - lch1.c
        let averageC = (lch1.c + lch2.c) / 2
        let averageH = (lch1.h + lch2.h) / 2

        let dE = deltaE(to: other)

        let deltah: Double
        if squared(dE) > (squared(other.l - l) + squared(deltaC)) {
            deltah = (squared(dE) - squared(other.l - l) - squared(deltaC)).squareRoot()
        } else {
            deltah = 0
        }

        let dc = 0.035 * averageC / (1 + 0.00365 * averageC) + 0.521
        let g = (squared(squared(averageC)) / (squared(squared(averageC)) + 14000)).squareRoot()
        let t = 0.627 + (
            0.055 * cos((averageH - 254) / (180 / Double.pi))
                - 0.040 * cos((2 * averageH - 136) / (180 / Double.pi))
                + 0.070 * cos((3 * averageH - 31) / (180 / Double.pi))
                + 0.049 * cos((4 * averageH + 114) / (180 / Double.pi))
                - 0.015 * cos((5 * averageH - 103) / (180 / Double.pi))
        )

        let dh = dc * (g * t + 1 - g)
        let rh = -0.260 * cos((averageH - 308) / (180 / Double.pi))
            - 0.379 * cos((2 * averageH - 160) / (180 / Double.pi))
            - 0.636 * cos((3 * averageH + 254) / (180 / Double.pi))
            + 0.226 * cos((4 * averageH + 140) / (180 / Double.pi))
            - 0.194 * cos((5 * averageH + 280) / (180 / Double.pi))

        let c6 = averageC * averageC * averageC * averageC * averageC * averageC
        let rc = (c6 / (c6 + 70000000)).squareRoot()
        let rt = rh * rc

        return (
            squared(deltaL) + squared(deltaC / dc) + squared(deltah / dh)
                + (rt * (deltaC / dc) * (deltah / dh))
        ).squareRoot()
    }

    static func computeLBFD(_ lab: CIELab) -> Double {
        let yt: Double
        if lab.l > 7.996969 {
            yt = (squared((lab.l + 16) / 116) * ((lab.l + 16) / 116)) * 100
        } else {
            yt = 100 * (lab.l / 903.3)
        }
        return 54.6 * (log10(exp(1.0)) * log(yt + 1.5)) - 9.6
    }

    /// CMC(l:c).
    public func deltaECMC(to other: CIELab, l lightness: Double, c chroma: Double) -> Double {
        if l == 0 && other.l == 0 { return 0 }

        let lch1 = cylindrical
        let lch2 = other.cylindrical

        let dL = other.l - l
        let dC = lch2.c - lch1.c
        let dE = deltaE(to: other)

        let dh: Double
        if squared(dE) > (squared(dL) + squared(dC)) {
            dh = (squared(dE) - squared(dL) - squared(dC)).squareRoot()
        } else {
            dh = 0
        }

        let t: Double
        if lch1.h > 164 && lch1.h < 345 {
            t = 0.56 + abs(0.2 * cos((lch1.h + 168) / (180 / Double.pi)))
        } else {
            t = 0.36 + abs(0.4 * cos((lch1.h + 35) / (180 / Double.pi)))
        }

        let sc = 0.0638 * lch1.c / (1 + 0.0131 * lch1.c) + 0.638
        var sl = 0.040975 * l / (1 + 0.01765 * l)
        if l < 16 { sl = 0.511 }

        let c4 = lch1.c * lch1.c * lch1.c * lch1.c
        let f = (c4 / (c4 + 1900)).squareRoot()
        let sh = sc * (t * f + 1 - f)

        return (
            squared(dL / (lightness * sl))
                + squared(dC / (chroma * sc))
                + squared(dh / sh)
        ).squareRoot()
    }

    /// CIEDE2000.
    public func deltaE2000(to other: CIELab, kL: Double, kC: Double, kH: Double) -> Double {
        let l1 = l, a1 = a, b1 = b
        let c = (squared(a1) + squared(b1)).squareRoot()

        let ls = other.l, aS = other.a, bs = other.b
        let cs = (squared(aS) + squared(bs)).squareRoot()

        let g = 0.5 * (
            1 - (pow((c + cs) / 2, 7.0) / (pow((c + cs) / 2, 7.0) + pow(25.0, 7.0))).squareRoot()
        )

        let aP = (1 + g) * a1
        let bP = b1
        let cP = (squared(aP) + squared(bP)).squareRoot()
        let hP = atan2Degrees(bP, aP)

        let aPs = (1 + g) * aS
        let bPs = bs
        let cPs = (squared(aPs) + squared(bPs)).squareRoot()
        let hPs = atan2Degrees(bPs, aPs)

        let meanCP = (cP + cPs) / 2

        let hpsPlusHp = hPs + hP
        let hpsMinusHp = hPs - hP

        // The 180.000001 is the reference's, not a typo of 180: it decides
        // which way a hue difference of exactly half a turn is taken.
        let meanHP: Double = abs(hpsMinusHp) <= 180.000001
            ? hpsPlusHp / 2
            : (hpsPlusHp < 360 ? (hpsPlusHp + 360) / 2 : (hpsPlusHp - 360) / 2)

        let deltah: Double = hpsMinusHp <= -180.000001
            ? hpsMinusHp + 360
            : (hpsMinusHp > 180 ? hpsMinusHp - 360 : hpsMinusHp)

        let deltaL = ls - l1
        let deltaC = cPs - cP
        let deltaH = 2 * (cPs * cP).squareRoot() * sin(radians(deltah) / 2)

        let t = 1 - 0.17 * cos(radians(meanHP - 30))
            + 0.24 * cos(radians(2 * meanHP))
            + 0.32 * cos(radians(3 * meanHP + 6))
            - 0.2 * cos(radians(4 * meanHP - 63))

        let sl = 1 + (0.015 * squared((ls + l1) / 2 - 50)) / (20 + squared((ls + l1) / 2 - 50)).squareRoot()
        let sc = 1 + 0.045 * (cP + cPs) / 2
        let sh = 1 + 0.015 * ((cPs + cP) / 2) * t

        let deltaRo = 30 * exp(-squared((meanHP - 275) / 25))
        let rc = 2 * (pow(meanCP, 7.0) / (pow(meanCP, 7.0) + pow(25.0, 7.0))).squareRoot()
        let rt = -sin(2 * radians(deltaRo)) * rc

        return (
            squared(deltaL / (sl * kL))
                + squared(deltaC / (sc * kC))
                + squared(deltaH / (sh * kH))
                + rt * (deltaC / (sc * kC)) * (deltaH / (sh * kH))
        ).squareRoot()
    }
}
