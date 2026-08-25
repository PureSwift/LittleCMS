// The arithmetic behind linking two profiles through the PCS.
//
// Between one profile's PCS output and the next profile's PCS input a
// transform may need a correction: absolute colorimetric scales one
// white point to the other, and black point compensation maps one
// black to the other with the white pinned.  Both come out as a 3x3
// matrix and an offset applied in XYZ.  This file is those
// computations; where they go in the pipeline is decided elsewhere.

/// A matrix and an offset, `y = m x + offset`, applied in XYZ.
public struct XYZLayer: Equatable, Sendable {
    public var matrix: Matrix3
    public var offset: Vector3

    public init(matrix: Matrix3, offset: Vector3) {
        self.matrix = matrix
        self.offset = offset
    }

    public static let identity = XYZLayer(matrix: .identity, offset: Vector3(0, 0, 0))

    /// Whether applying this would change anything worth a stage — the
    /// reference's `IsEmptyLayer`, a summed absolute distance from
    /// identity below 0.002.
    public var isEmpty: Bool {
        var diff = 0.0
        let identity = Matrix3.identity
        for i in 0..<3 {
            for j in 0..<3 {
                diff += (matrix[i][j] - identity[i][j]).magnitude
            }
        }
        diff += offset.x.magnitude + offset.y.magnitude + offset.z.magnitude
        return diff < 0.002
    }
}

public enum IntentArithmetic {
    /// Black point compensation: a linear scaling in XYZ taking the
    /// source black to the destination black while leaving D50 fixed.
    /// Both black points are relative to their white point.
    ///
    ///     a = (bpOut - D50) / (bpIn - D50)
    ///     b = -D50 (bpOut - bpIn) / (bpIn - D50)
    public static func blackPointCompensation(from blackIn: CIEXYZ, to blackOut: CIEXYZ) -> XYZLayer {
        let d50 = CIEXYZ.d50
        let tx = blackIn.x - d50.x
        let ty = blackIn.y - d50.y
        let tz = blackIn.z - d50.z

        let ax = (blackOut.x - d50.x) / tx
        let ay = (blackOut.y - d50.y) / ty
        let az = (blackOut.z - d50.z) / tz

        let bx = -d50.x * (blackOut.x - blackIn.x) / tx
        let by = -d50.y * (blackOut.y - blackIn.y) / ty
        let bz = -d50.z * (blackOut.z - blackIn.z) / tz

        return XYZLayer(
            matrix: Matrix3(Vector3(ax, 0, 0), Vector3(0, ay, 0), Vector3(0, 0, az)),
            offset: Vector3(bx, by, bz)
        )
    }

    /// The colour temperature a chromatic adaptation matrix implies:
    /// D50 taken back through its inverse is the absolute white, and
    /// that white's correlated temperature is the answer.  Zero when the
    /// matrix cannot be inverted and -1 when the white has no
    /// temperature — two failures the reference reports differently and
    /// its caller checks only one of.
    public static func temperature(ofAdaptation chad: Matrix3) -> Double {
        guard let inverse = chad.inverse else { return 0.0 }
        let d = inverse.evaluate(Vector3(CIEXYZ.d50.x, CIEXYZ.d50.y, CIEXYZ.d50.z))
        let destination = CIEXYZ(x: d.x, y: d.y, z: d.z)
        guard let kelvin = destination.chromaticity.temperature else { return -1.0 }
        return kelvin
    }

    /// The Bradford adaptation from the daylight white of a temperature
    /// to D50, or nil for a temperature the daylight locus does not
    /// cover.
    public static func adaptation(forTemperature kelvin: Double) -> Matrix3? {
        guard let chromaticity = CIExyY(temperature: kelvin) else { return nil }
        return ChromaticAdaptation.matrix(from: chromaticity.tristimulus, to: .d50)
    }

    /// Absolute colorimetric: the scaling from the source white to the
    /// destination white, and — when the observer is not taken as fully
    /// adapted — the chromatic adaptations undone in proportion.
    ///
    /// The three cases are the reference's, including the way an
    /// adaptation state of exactly zero composes its matrices; that path
    /// assigns `m` once and then overwrites it, and only the second
    /// assignment is kept here.
    public static func absoluteIntent(
        adaptationState: Double,
        whiteIn: CIEXYZ, adaptationIn: Matrix3,
        whiteOut: CIEXYZ, adaptationOut: Matrix3
    ) -> Matrix3? {
        let scale = Matrix3(
            Vector3(whiteIn.x / whiteOut.x, 0, 0),
            Vector3(0, whiteIn.y / whiteOut.y, 0),
            Vector3(0, 0, whiteIn.z / whiteOut.z)
        )

        // Fully adapted: keep the chromatic adaptation.  V4 behaviour.
        if adaptationState == 1.0 {
            return scale
        }

        if adaptationState == 0.0 {
            // Not adapted at all: undo the chromatic adaptation.
            let m2 = adaptationOut * scale
            guard let inverseIn = adaptationIn.inverse else { return nil }
            return m2 * inverseIn
        }

        // Partly adapted: a white at a temperature between the two, and
        // an adaptation from there to D50 in place of the output's.
        guard let inverseIn = adaptationIn.inverse else { return nil }
        let m3 = inverseIn * scale

        let temperatureSource = temperature(ofAdaptation: adaptationIn)
        let temperatureDestination = temperature(ofAdaptation: adaptationOut)
        if temperatureSource < 0.0 || temperatureDestination < 0.0 { return nil }

        if scale.isIdentity && (temperatureSource - temperatureDestination).magnitude < 0.01 {
            return .identity
        }

        let mixed = (1.0 - adaptationState) * temperatureDestination + adaptationState * temperatureSource
        guard let mixedAdaptation = adaptation(forTemperature: mixed) else { return nil }
        return m3 * mixedAdaptation
    }
}
