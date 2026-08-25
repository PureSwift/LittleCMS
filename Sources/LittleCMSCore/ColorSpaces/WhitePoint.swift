// White points and chromatic adaptation.
//
// Adaptation is what makes a colour measured under one illuminant mean
// something under another, and every profile connection through XYZ goes
// through it.  The cone matrix is Bradford unless a caller supplies its
// own.

/// The correlated-colour-temperature relation, valid over the range the
/// reference accepts and refusing outside it.
extension CIExyY {
    /// The daylight locus point for a colour temperature, or nil outside
    /// 4000K…25000K where the approximation does not hold.
    public init?(temperature kelvin: Double) {
        let t = kelvin
        let t2 = t * t
        let t3 = t2 * t

        let x: Double
        if t >= 4000.0 && t <= 7000.0 {
            x = -4.6070 * (1e9 / t3) + 2.9678 * (1e6 / t2) + 0.09911 * (1e3 / t) + 0.244063
        } else if t > 7000.0 && t <= 25000.0 {
            x = -2.0064 * (1e9 / t3) + 1.9018 * (1e6 / t2) + 0.24748 * (1e3 / t) + 0.237040
        } else {
            return nil
        }

        let y = -3.000 * (x * x) + 2.870 * x - 0.275
        self.init(x: x, y: y, yLuminance: 1.0)
    }

    /// The nearest correlated colour temperature, by walking the
    /// isotemperature lines until the sign of the distance flips.  Nil
    /// when the point lies off the ends of the table.
    public var temperature: Double? {
        // To CIE 1960 (u, v).
        let us = (2 * x) / (-x + 6 * y + 1.5)
        let vs = (3 * y) / (-x + 6 * y + 1.5)

        var di = 0.0
        var mi = 0.0

        for (index, line) in isotemperatureLines.enumerated() {
            let dj = ((vs - line.v) - line.t * (us - line.u)) / (1.0 + line.t * line.t).squareRoot()

            if index != 0 && di / dj < 0.0 {
                return 1000000.0 / (mi + (di / (di - dj)) * (line.mirek - mi))
            }

            di = dj
            mi = line.mirek
        }

        return nil
    }
}

/// A line of constant correlated colour temperature in CIE 1960 (u, v).
@usableFromInline
struct Isotemperature: Sendable {
    @usableFromInline var mirek: Double
    @usableFromInline var u: Double
    @usableFromInline var v: Double
    @usableFromInline var t: Double

    @usableFromInline
    init(mirek: Double, u: Double, v: Double, t: Double) {
        self.mirek = mirek
        self.u = u
        self.v = v
        self.t = t
    }
}

/// Robertson's table, transcribed from the reference.
@usableFromInline
let isotemperatureLines: [Isotemperature] = [
    Isotemperature(mirek: 0, u: 0.18006, v: 0.26352, t: -0.24341),
    Isotemperature(mirek: 10, u: 0.18066, v: 0.26589, t: -0.25479),
    Isotemperature(mirek: 20, u: 0.18133, v: 0.26846, t: -0.26876),
    Isotemperature(mirek: 30, u: 0.18208, v: 0.27119, t: -0.28539),
    Isotemperature(mirek: 40, u: 0.18293, v: 0.27407, t: -0.30470),
    Isotemperature(mirek: 50, u: 0.18388, v: 0.27709, t: -0.32675),
    Isotemperature(mirek: 60, u: 0.18494, v: 0.28021, t: -0.35156),
    Isotemperature(mirek: 70, u: 0.18611, v: 0.28342, t: -0.37915),
    Isotemperature(mirek: 80, u: 0.18740, v: 0.28668, t: -0.40955),
    Isotemperature(mirek: 90, u: 0.18880, v: 0.28997, t: -0.44278),
    Isotemperature(mirek: 100, u: 0.19032, v: 0.29326, t: -0.47888),
    Isotemperature(mirek: 125, u: 0.19462, v: 0.30141, t: -0.58204),
    Isotemperature(mirek: 150, u: 0.19962, v: 0.30921, t: -0.70471),
    Isotemperature(mirek: 175, u: 0.20525, v: 0.31647, t: -0.84901),
    Isotemperature(mirek: 200, u: 0.21142, v: 0.32312, t: -1.0182),
    Isotemperature(mirek: 225, u: 0.21807, v: 0.32909, t: -1.2168),
    Isotemperature(mirek: 250, u: 0.22511, v: 0.33439, t: -1.4512),
    Isotemperature(mirek: 275, u: 0.23247, v: 0.33904, t: -1.7298),
    Isotemperature(mirek: 300, u: 0.24010, v: 0.34308, t: -2.0637),
    Isotemperature(mirek: 325, u: 0.24702, v: 0.34655, t: -2.4681),
    Isotemperature(mirek: 350, u: 0.25591, v: 0.34951, t: -2.9641),
    Isotemperature(mirek: 375, u: 0.26400, v: 0.35200, t: -3.5814),
    Isotemperature(mirek: 400, u: 0.27218, v: 0.35407, t: -4.3633),
    Isotemperature(mirek: 425, u: 0.28039, v: 0.35577, t: -5.3762),
    Isotemperature(mirek: 450, u: 0.28863, v: 0.35714, t: -6.7262),
    Isotemperature(mirek: 475, u: 0.29685, v: 0.35823, t: -8.5955),
    Isotemperature(mirek: 500, u: 0.30505, v: 0.35907, t: -11.324),
    Isotemperature(mirek: 525, u: 0.31320, v: 0.35968, t: -15.628),
    Isotemperature(mirek: 550, u: 0.32129, v: 0.36011, t: -23.325),
    Isotemperature(mirek: 575, u: 0.32931, v: 0.36038, t: -40.770),
    Isotemperature(mirek: 600, u: 0.33724, v: 0.36051, t: -116.45),
]

public enum ChromaticAdaptation {
    /// Bradford, the cone response the reference uses when a caller does
    /// not supply one.
    public static let bradford = Matrix3(
        Vector3(0.8951, 0.2664, -0.1614),
        Vector3(-0.7502, 1.7135, 0.0367),
        Vector3(0.0389, -0.0685, 1.0296)
    )

    /// The matrix taking colours measured under `source` to what they
    /// would be under `destination`, or nil when the cone matrix cannot
    /// be inverted or a cone response comes out too near zero to divide by.
    public static func matrix(
        from source: CIEXYZ,
        to destination: CIEXYZ,
        cone: Matrix3 = bradford
    ) -> Matrix3? {
        guard let coneInverse = cone.inverse else { return nil }

        let sourceRGB = cone.evaluate(Vector3(source.x, source.y, source.z))
        let destinationRGB = cone.evaluate(Vector3(destination.x, destination.y, destination.z))

        guard sourceRGB.x.magnitude >= Matrix3.determinantTolerance,
              sourceRGB.y.magnitude >= Matrix3.determinantTolerance,
              sourceRGB.z.magnitude >= Matrix3.determinantTolerance
        else { return nil }

        let scale = Matrix3(
            Vector3(destinationRGB.x / sourceRGB.x, 0.0, 0.0),
            Vector3(0.0, destinationRGB.y / sourceRGB.y, 0.0),
            Vector3(0.0, 0.0, destinationRGB.z / sourceRGB.z)
        )

        return coneInverse * (scale * cone)
    }
}

extension CIEXYZ {
    /// This colour as it would be under `illuminant`, having been measured
    /// under `sourceWhitePoint`.
    public func adapted(to illuminant: CIEXYZ, from sourceWhitePoint: CIEXYZ) -> CIEXYZ? {
        guard let bradford = ChromaticAdaptation.matrix(from: sourceWhitePoint, to: illuminant) else {
            return nil
        }
        let result = bradford.evaluate(Vector3(x, y, z))
        return CIEXYZ(x: result.x, y: result.y, z: result.z)
    }
}

/// The chromaticities of an RGB space's three primaries.
public struct RGBPrimaries: Equatable, Sendable {
    public var red: CIExyY
    public var green: CIExyY
    public var blue: CIExyY

    public init(red: CIExyY, green: CIExyY, blue: CIExyY) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The matrix taking RGB to XYZ for these primaries and a white
    /// point, adapted to D50 — the colorants a matrix-shaper profile
    /// stores.  Nil when the primaries are degenerate or the white cannot
    /// be adapted.
    public func transferMatrix(whitePoint: CIExyY) -> Matrix3? {
        let xn = whitePoint.x, yn = whitePoint.y
        let xr = red.x, yr = red.y
        let xg = green.x, yg = green.y
        let xb = blue.x, yb = blue.y

        let primaries = Matrix3(
            Vector3(xr, xg, xb),
            Vector3(yr, yg, yb),
            Vector3(1 - xr - yr, 1 - xg - yg, 1 - xb - yb)
        )
        guard let inverse = primaries.inverse else { return nil }

        let white = Vector3(xn / yn, 1.0, (1.0 - xn - yn) / yn)
        let coefficients = inverse.evaluate(white)

        let result = Matrix3(
            Vector3(coefficients.x * xr, coefficients.y * xg, coefficients.z * xb),
            Vector3(coefficients.x * yr, coefficients.y * yg, coefficients.z * yb),
            Vector3(coefficients.x * (1.0 - xr - yr), coefficients.y * (1.0 - xg - yg), coefficients.z * (1.0 - xb - yb))
        )

        // `_cmsAdaptMatrixToD50`: Bradford from the white to D50, applied
        // on the left.
        guard let bradford = ChromaticAdaptation.matrix(from: whitePoint.tristimulus, to: .d50)
        else { return nil }
        return bradford * result
    }
}
