// The parametric tone curves the ICC specification defines, and the few
// the reference adds beyond it.
//
// Every branch here is the reference's, including the ones that look
// arbitrary: a curve whose gamma is within a hair of zero answers a large
// finite number rather than an infinity, a negative input is sometimes
// passed through and sometimes flattened to zero, and which of those
// happens depends on the type.  These are the values profiles in the wild
// were built against.

/// What the reference answers instead of infinity.  Not `Double.infinity`:
/// the constant is a float literal in the reference and its double value
/// is what propagates into curves.
@usableFromInline let curvePlusInfinity = Double(Float(1e22))

/// The threshold below which the reference treats a parameter as zero.
/// Shared with the matrix code, which is where the name comes from.
@usableFromInline let parameterTolerance = Matrix3.determinantTolerance

public enum ParametricCurve {
    /// The types the reference can evaluate.  A curve of any other type
    /// cannot be built, and evaluating one answers zero.
    public static let supportedTypes: [Int32] = [
        1, 2, 3, 4, 5, 6, 7, 8, 108, 109,
    ]

    @inline(__always)
    static func sigmoidBase(_ k: Double, _ t: Double) -> Double {
        (1.0 / (1.0 + exp(-k * t))) - 0.5
    }

    @inline(__always)
    static func invertedSigmoidBase(_ k: Double, _ t: Double) -> Double {
        -log((1.0 / (t + 0.5)) - 1.0) / k
    }

    @inline(__always)
    static func sigmoid(_ k: Double, _ t: Double) -> Double {
        let correction = 0.5 / sigmoidBase(k, 1)
        return correction * sigmoidBase(k, 2.0 * t - 1.0) + 0.5
    }

    @inline(__always)
    static func inverseSigmoid(_ k: Double, _ t: Double) -> Double {
        let correction = 0.5 / sigmoidBase(k, 1)
        return (invertedSigmoidBase(k, (t - 0.5) / correction) + 1.0) / 2.0
    }

    /// Evaluates the curve of the given type at `r`.
    ///
    /// A negative type is the inverse of its positive counterpart.  An
    /// unsupported type answers zero, which is what the reference's
    /// unreachable default does.
    public static func evaluate(type: Int32, params: UnsafePointer<Double>, at r: Double) -> Double {
        let p = params

        switch type {
        // Y = X^g
        case 1:
            if r < 0 {
                return abs(p[0] - 1.0) < parameterTolerance ? r : 0
            }
            return pow(r, p[0])

        case -1:
            if r < 0 {
                return abs(p[0] - 1.0) < parameterTolerance ? r : 0
            }
            if abs(p[0]) < parameterTolerance { return curvePlusInfinity }
            return pow(r, 1 / p[0])

        // CIE 122-1966: Y = (aX + b)^g above the discontinuity, else 0
        case 2:
            if abs(p[1]) < parameterTolerance { return 0 }
            let disc = -p[2] / p[1]
            if r >= disc {
                let e = p[1] * r + p[2]
                return e > 0 ? pow(e, p[0]) : 0
            }
            return 0

        case -2:
            if abs(p[0]) < parameterTolerance || abs(p[1]) < parameterTolerance { return 0 }
            if r < 0 { return 0 }
            let value = (pow(r, 1.0 / p[0]) - p[2]) / p[1]
            return value < 0 ? 0 : value

        // IEC 61966-3: Y = (aX + b)^g + c above the discontinuity, else c
        case 3:
            if abs(p[1]) < parameterTolerance { return 0 }
            var disc = -p[2] / p[1]
            if disc < 0 { disc = 0 }
            if r >= disc {
                let e = p[1] * r + p[2]
                return e > 0 ? pow(e, p[0]) + p[3] : 0
            }
            return p[3]

        case -3:
            if abs(p[0]) < parameterTolerance || abs(p[1]) < parameterTolerance { return 0 }
            if r >= p[3] {
                let e = r - p[3]
                return e > 0 ? (pow(e, 1 / p[0]) - p[2]) / p[1] : 0
            }
            return -p[2] / p[1]

        // IEC 61966-2.1, which is sRGB: a power segment above d, linear below
        case 4:
            if r >= p[4] {
                let e = p[1] * r + p[2]
                return e > 0 ? pow(e, p[0]) : 0
            }
            return r * p[3]

        case -4:
            let e = p[1] * p[4] + p[2]
            let disc = e < 0 ? 0 : pow(e, p[0])
            if r >= disc {
                if abs(p[0]) < parameterTolerance || abs(p[1]) < parameterTolerance { return 0 }
                return (pow(r, 1.0 / p[0]) - p[2]) / p[1]
            }
            if abs(p[3]) < parameterTolerance { return 0 }
            return r / p[3]

        // As type 4, with an offset on each segment
        case 5:
            if r >= p[4] {
                let e = p[1] * r + p[2]
                return e > 0 ? pow(e, p[0]) + p[5] : p[5]
            }
            return r * p[3] + p[6]

        case -5:
            let disc = p[3] * p[4] + p[6]
            if r >= disc {
                let e = r - p[5]
                if e < 0 { return 0 }
                if abs(p[0]) < parameterTolerance || abs(p[1]) < parameterTolerance { return 0 }
                return (pow(e, 1.0 / p[0]) - p[2]) / p[1]
            }
            if abs(p[3]) < parameterTolerance { return 0 }
            return (r - p[6]) / p[3]

        // The segmented-curve types, from the floating point specification.
        // Type 6 is type 5 without the discontinuity.
        case 6:
            let e = p[1] * r + p[2]
            // At a gamma of exactly one the reference does not clamp,
            // which keeps the segment linear through negative inputs.
            if p[0] == 1.0 { return e + p[3] }
            return e < 0 ? p[3] : pow(e, p[0]) + p[3]

        case -6:
            if abs(p[0]) < parameterTolerance || abs(p[1]) < parameterTolerance { return 0 }
            let e = r - p[3]
            if e < 0 { return 0 }
            return (pow(e, 1.0 / p[0]) - p[2]) / p[1]

        // Y = a·log(b·X^g + c) + d
        case 7:
            let e = p[2] * pow(r, p[0]) + p[3]
            return e <= 0 ? p[4] : p[1] * log10(e) + p[4]

        case -7:
            if abs(p[0]) < parameterTolerance
                || abs(p[1]) < parameterTolerance
                || abs(p[2]) < parameterTolerance { return 0 }
            return pow((pow(10.0, (r - p[4]) / p[1]) - p[3]) / p[2], 1.0 / p[0])

        // Y = a·b^(cX + d) + e
        case 8:
            return p[0] * pow(p[1], p[2] * r + p[3]) + p[4]

        case -8:
            let disc = r - p[4]
            if disc < 0 { return 0 }
            if abs(p[0]) < parameterTolerance || abs(p[2]) < parameterTolerance { return 0 }
            return (log(disc / p[0]) / log(p[1]) - p[3]) / p[2]

        // S-shaped
        case 108:
            if abs(p[0]) < parameterTolerance { return 0 }
            return pow(1.0 - pow(1 - r, 1 / p[0]), 1 / p[0])

        case -108:
            return 1 - pow(1 - pow(r, p[0]), p[0])

        // Sigmoidal
        case 109:
            return sigmoid(p[0], r)

        case -109:
            return inverseSigmoid(p[0], r)

        default:
            // The reference calls this unreachable; a curve of an
            // unsupported type cannot be built in the first place.
            return 0
        }
    }

    /// How many parameters each type takes.  Building a curve reads
    /// exactly this many, so the count is part of the contract.
    public static func parameterCount(forType type: Int32) -> Int? {
        switch abs(type) {
        case 1: return 1
        case 2: return 3
        case 3: return 4
        case 4: return 5
        case 5: return 7
        case 6: return 4
        case 7: return 5
        case 8: return 5
        case 108: return 1
        case 109: return 1
        default: return nil
        }
    }
}
