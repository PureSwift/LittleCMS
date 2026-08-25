// 3-vectors and 3x3 matrices.
//
// The chromatic adaptation and matrix-shaper paths run on these, and the
// order the reference sums its products in decides the last bit of the
// result, so the expressions are transcribed rather than rearranged.
//
// Both types are C layout: the plugin header declares them and callers
// construct them, so the field order is contract.  LCMS2ABI asserts their
// size and stride against the imported C types.

/// The reference's MATRIX_DET_TOLERANCE.  Named for what it is rather
/// than where it started: the same constant decides when a matrix is
/// singular, when a curve parameter counts as zero, and when a smoothing
/// factor is too small to bother with.
public let smallestMeaningfulValue = 0.0001

/// `cmsVEC3` — three doubles, indexed X, Y, Z.
@frozen
public struct Vector3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    @inlinable
    public subscript(index: Int) -> Double {
        get {
            switch index {
            case 0: return x
            case 1: return y
            default: return z
            }
        }
        set {
            switch index {
            case 0: x = newValue
            case 1: y = newValue
            default: z = newValue
            }
        }
    }

    @inlinable
    public static func - (a: Vector3, b: Vector3) -> Vector3 {
        Vector3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    @inlinable
    public func cross(_ v: Vector3) -> Vector3 {
        Vector3(
            y * v.z - v.y * z,
            z * v.x - v.z * x,
            x * v.y - v.x * y
        )
    }

    @inlinable
    public func dot(_ v: Vector3) -> Double {
        x * v.x + y * v.y + z * v.z
    }

    @inlinable
    public var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    @inlinable
    public func distance(to b: Vector3) -> Double {
        let d1 = x - b.x
        let d2 = y - b.y
        let d3 = z - b.z
        return (d1 * d1 + d2 * d2 + d3 * d3).squareRoot()
    }
}

/// `cmsMAT3` — three row vectors.
@frozen
public struct Matrix3: Equatable, Sendable {
    public var rows: (Vector3, Vector3, Vector3)

    @inlinable
    public init(_ r0: Vector3, _ r1: Vector3, _ r2: Vector3) {
        rows = (r0, r1, r2)
    }

    @inlinable
    public subscript(row: Int) -> Vector3 {
        get {
            switch row {
            case 0: return rows.0
            case 1: return rows.1
            default: return rows.2
            }
        }
        set {
            switch row {
            case 0: rows.0 = newValue
            case 1: rows.1 = newValue
            default: rows.2 = newValue
            }
        }
    }

    @inlinable
    public static var identity: Matrix3 {
        Matrix3(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
    }

    // Spelled out because the stored rows are a tuple, which no synthesis
    // reaches through.
    @inlinable
    public static func == (a: Matrix3, b: Matrix3) -> Bool {
        a.rows.0 == b.rows.0 && a.rows.1 == b.rows.1 && a.rows.2 == b.rows.2
    }

    /// The reference's `CloseEnough`: within one 16-bit code.
    @inlinable
    static func closeEnough(_ a: Double, _ b: Double) -> Bool {
        (b - a).magnitude < (1.0 / 65535.0)
    }

    @inlinable
    public var isIdentity: Bool {
        let identity = Matrix3.identity
        for i in 0..<3 {
            for j in 0..<3 where !Matrix3.closeEnough(self[i][j], identity[i][j]) {
                return false
            }
        }
        return true
    }

    /// Matrix product, in the reference's summation order.
    @inlinable
    public static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        @inline(__always)
        func rowcol(_ i: Int, _ j: Int) -> Double {
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]
        }
        return Matrix3(
            Vector3(rowcol(0, 0), rowcol(0, 1), rowcol(0, 2)),
            Vector3(rowcol(1, 0), rowcol(1, 1), rowcol(1, 2)),
            Vector3(rowcol(2, 0), rowcol(2, 1), rowcol(2, 2))
        )
    }

    /// A determinant smaller than this counts as singular.
    @usableFromInline
    static let determinantTolerance = smallestMeaningfulValue

    /// The inverse, or nil when the matrix is singular.  Each cofactor is
    /// spelled the way the reference spells it.
    @inlinable
    public var inverse: Matrix3? {
        let c0 = self[1][1] * self[2][2] - self[1][2] * self[2][1]
        let c1 = -self[1][0] * self[2][2] + self[1][2] * self[2][0]
        let c2 = self[1][0] * self[2][1] - self[1][1] * self[2][0]

        let det = self[0][0] * c0 + self[0][1] * c1 + self[0][2] * c2
        if det.magnitude < Matrix3.determinantTolerance { return nil }

        return Matrix3(
            Vector3(
                c0 / det,
                (self[0][2] * self[2][1] - self[0][1] * self[2][2]) / det,
                (self[0][1] * self[1][2] - self[0][2] * self[1][1]) / det
            ),
            Vector3(
                c1 / det,
                (self[0][0] * self[2][2] - self[0][2] * self[2][0]) / det,
                (self[0][2] * self[1][0] - self[0][0] * self[1][2]) / det
            ),
            Vector3(
                c2 / det,
                (self[0][1] * self[2][0] - self[0][0] * self[2][1]) / det,
                (self[0][0] * self[1][1] - self[0][1] * self[1][0]) / det
            )
        )
    }

    /// Applies the matrix to a vector.
    @inlinable
    public func evaluate(_ v: Vector3) -> Vector3 {
        Vector3(
            self[0][0] * v.x + self[0][1] * v.y + self[0][2] * v.z,
            self[1][0] * v.x + self[1][1] * v.y + self[1][2] * v.z,
            self[2][0] * v.x + self[2][1] * v.y + self[2][2] * v.z
        )
    }

    /// Solves `self * x = b`, or nil when singular.
    @inlinable
    public func solve(_ b: Vector3) -> Vector3? {
        guard let inverse else { return nil }
        return inverse.evaluate(b)
    }
}
