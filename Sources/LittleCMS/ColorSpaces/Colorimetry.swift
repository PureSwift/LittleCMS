// The colour spaces the profile connection space is expressed in, and the
// distances between colours in them.
//
// Ported expression by expression.  Several of these are written in ways a
// numerical analyst would improve — `pow(x, 0.5)` where `sqrt` would do,
// a hue wrapped by repeated subtraction — and they are kept exactly as
// they are, because the values they produce are what everything measures
// against.

/// CIE XYZ tristimulus values.
@frozen
public struct CIEXYZ: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    @inlinable
    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// D50, the illuminant every ICC profile connection space is relative to.
    public static let d50 = CIEXYZ(x: 0.9642, y: 1.0, z: 0.8249)
}

/// CIE xyY chromaticity and luminance.
@frozen
public struct CIExyY: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var yLuminance: Double

    @inlinable
    public init(x: Double = 0, y: Double = 0, yLuminance: Double = 0) {
        self.x = x
        self.y = y
        self.yLuminance = yLuminance
    }

    public static let d50 = CIEXYZ.d50.chromaticity
}

/// CIE L*a*b*.
@frozen
public struct CIELab: Equatable, Sendable {
    public var l: Double
    public var a: Double
    public var b: Double

    @inlinable
    public init(l: Double = 0, a: Double = 0, b: Double = 0) {
        self.l = l
        self.a = a
        self.b = b
    }
}

/// CIE L*C*h°, the cylindrical form of L*a*b*.
@frozen
public struct CIELCh: Equatable, Sendable {
    public var l: Double
    public var c: Double
    public var h: Double

    @inlinable
    public init(l: Double = 0, c: Double = 0, h: Double = 0) {
        self.l = l
        self.c = c
        self.h = h
    }
}

// -- conversions -------------------------------------------------------

extension CIEXYZ {
    /// The reference computes one reciprocal and multiplies by it, which
    /// is not the same as three divisions in the last bit.
    @inlinable
    public var chromaticity: CIExyY {
        let inverseSum = 1.0 / (x + y + z)
        return CIExyY(x: x * inverseSum, y: y * inverseSum, yLuminance: y)
    }
}

extension CIExyY {
    @inlinable
    public var tristimulus: CIEXYZ {
        CIEXYZ(
            x: (x / y) * yLuminance,
            y: yLuminance,
            z: ((1 - x - y) / y) * yLuminance
        )
    }
}

/// The L* companding function and its inverse.  The linear segment below
/// the limit is what keeps the transform finite near black.
@usableFromInline
enum LabCompanding {
    @usableFromInline
    static func forward(_ t: Double) -> Double {
        let limit = (24.0 / 116.0) * (24.0 / 116.0) * (24.0 / 116.0)
        if t <= limit {
            return (841.0 / 108.0) * t + (16.0 / 116.0)
        }
        return pow(t, 1.0 / 3.0)
    }

    @usableFromInline
    static func inverse(_ t: Double) -> Double {
        let limit = 24.0 / 116.0
        if t <= limit {
            return (108.0 / 841.0) * (t - (16.0 / 116.0))
        }
        return t * t * t
    }
}

extension CIELab {
    /// Converts from XYZ relative to `whitePoint`, D50 when none is given.
    @inlinable
    public init(_ xyz: CIEXYZ, whitePoint: CIEXYZ = .d50) {
        let fx = LabCompanding.forward(xyz.x / whitePoint.x)
        let fy = LabCompanding.forward(xyz.y / whitePoint.y)
        let fz = LabCompanding.forward(xyz.z / whitePoint.z)

        l = 116.0 * fy - 16.0
        a = 500.0 * (fx - fy)
        b = 200.0 * (fy - fz)
    }

    /// Converts back to XYZ.  The reference reaches the companding inputs
    /// by the shortcut `y ± k·a`, not by inverting the forward expression.
    @inlinable
    public func tristimulus(whitePoint: CIEXYZ = .d50) -> CIEXYZ {
        let y = (l + 16.0) / 116.0
        let x = y + 0.002 * a
        let z = y - 0.005 * b

        return CIEXYZ(
            x: LabCompanding.inverse(x) * whitePoint.x,
            y: LabCompanding.inverse(y) * whitePoint.y,
            z: LabCompanding.inverse(z) * whitePoint.z
        )
    }

    @inlinable
    public var cylindrical: CIELCh {
        CIELCh(
            l: l,
            c: pow(a * a + b * b, 0.5),
            h: atan2Degrees(b, a)
        )
    }
}

extension CIELCh {
    @inlinable
    public var rectangular: CIELab {
        let radians = (h * Double.pi) / 180.0
        return CIELab(l: l, a: c * cos(radians), b: c * sin(radians))
    }
}

/// `atan2` in degrees, wrapped into `[0, 360)`, and zero when both
/// arguments are.  The reference wraps by repeated addition rather than
/// by remainder, which matters only for values a remainder would round
/// differently — so it is kept.
@inlinable
public func atan2Degrees(_ a: Double, _ b: Double) -> Double {
    var h = (a == 0 && b == 0) ? 0 : atan2(a, b)
    h *= 180.0 / Double.pi

    while h > 360.0 { h -= 360.0 }
    while h < 0 { h += 360.0 }
    return h
}

// -- the encoded forms -------------------------------------------------
//
// Lab is carried through 16-bit channels in two different scalings: the
// version 4 encoding, and the version 2 one it replaced.  Reading a v2
// profile with v4 scaling is a real and subtle bug, so both exist here
// under names that cannot be confused.

extension CIELab {
    @inlinable
    static func clampL(_ value: Double) -> Double {
        min(max(value, 0), 100.0)
    }

    /// Version 4 clamps a and b to a round ±128/127, and version 2 to the
    /// largest value its own scaling can carry.  The two limits are not
    /// the same number and are not interchangeable.
    @inlinable
    static func clampAB4(_ value: Double) -> Double {
        min(max(value, minimumEncodeableAB), maximumEncodeableAB4)
    }

    @inlinable
    static func clampAB2(_ value: Double) -> Double {
        min(max(value, minimumEncodeableAB), maximumEncodeableAB2)
    }

    /// Version 4: L over 0…0xFFFF, a and b offset by 128 and scaled by 257.
    public init(encodedV4 channels: (UInt16, UInt16, UInt16)) {
        l = Double(channels.0) / 655.35
        a = Double(channels.1) / 257.0 - 128.0
        b = Double(channels.2) / 257.0 - 128.0
    }

    public var encodedV4: (UInt16, UInt16, UInt16) {
        (
            quickSaturateWord(CIELab.clampL(l) * 655.35),
            quickSaturateWord((CIELab.clampAB4(a) + 128.0) * 257.0),
            quickSaturateWord((CIELab.clampAB4(b) + 128.0) * 257.0)
        )
    }

    /// Version 2: L scaled by 652.8, a and b by 256.
    public init(encodedV2 channels: (UInt16, UInt16, UInt16)) {
        l = Double(channels.0) / 652.800
        a = Double(channels.1) / 256.0 - 128.0
        b = Double(channels.2) / 256.0 - 128.0
    }

    public var encodedV2: (UInt16, UInt16, UInt16) {
        (
            quickSaturateWord(CIELab.clampL(l) * 652.8),
            quickSaturateWord((CIELab.clampAB2(a) + 128.0) * 256.0),
            quickSaturateWord((CIELab.clampAB2(b) + 128.0) * 256.0)
        )
    }
}

@usableFromInline let minimumEncodeableAB = -128.0
/// Version 4 stops at a round 127, not at the largest value its scaling
/// could express.
@usableFromInline let maximumEncodeableAB4 = 127.0
/// Version 2 stops at the largest value its scaling can express.
@usableFromInline let maximumEncodeableAB2 = (65535.0 / 256.0) - 128.0
/// One code short of 2.0, which is as much XYZ as 1.15 fixed point holds.
@usableFromInline let maximumEncodeableXYZ = 1.0 + 32767.0 / 32768.0

extension CIEXYZ {
    /// XYZ rides in 16-bit channels as 1.15 fixed point.  Decoding goes
    /// through 15.16 rather than dividing: the reference shifts the code
    /// left and reuses the fixed-point conversion, and the two are not
    /// the same expression even where they agree.
    public init(encoded channels: (UInt16, UInt16, UInt16)) {
        @inline(__always)
        func decode(_ code: UInt16) -> Double {
            S15Fixed16.toDouble(Int32(code) << 1)
        }
        x = decode(channels.0)
        y = decode(channels.1)
        z = decode(channels.2)
    }

    public var encoded: (UInt16, UInt16, UInt16) {
        // A non-positive Y takes the whole colour to black, which the
        // reference does before clamping the channels individually.
        var (cx, cy, cz) = (x, y, z)
        if cy <= 0 {
            cx = 0
            cy = 0
            cz = 0
        }
        cx = min(max(cx, 0), maximumEncodeableXYZ)
        cy = min(max(cy, 0), maximumEncodeableXYZ)
        cz = min(max(cz, 0), maximumEncodeableXYZ)

        return (
            quickSaturateWord(cx * 32768.0),
            quickSaturateWord(cy * 32768.0),
            quickSaturateWord(cz * 32768.0)
        )
    }
}
