// One-dimensional interpolation.
//
// A tabulated tone curve is a lookup table plus this, and the exact
// arithmetic is what decides whether a transform's output byte matches
// the reference's.  The 16-bit path works in 15.16 fixed point throughout
// and never sees a float; the float path clamps its input in a way that
// is not quite a clamp, and both are kept as the reference has them.
//
// The multi-dimensional kernels — trilinear, tetrahedral, and the rest —
// arrive with the pipelines that need them.

/// `_cmsToFixedDomain`: maps a 16-bit-scaled product into 15.16 without
/// the rounding a plain shift would introduce.
@inlinable
public func toFixedDomain(_ a: Int32) -> Int32 {
    a &+ ((a &+ 0x7FFF) / 0xFFFF)
}

/// `_cmsFromFixedDomain`, its counterpart.
@inlinable
public func fromFixedDomain(_ a: Int32) -> Int32 {
    a &- ((a &+ 0x7FFF) >> 16)
}

/// The reference's fixed-point lerp between two table entries.
///
/// `a` is the fractional position in the low sixteen bits.  The addition
/// of 0x8000 before the shift is the rounding, and doing it in unsigned
/// arithmetic is what keeps a descending table from underflowing.
@inlinable
public func linearInterpolate(_ a: Int32, _ low: Int32, _ high: Int32) -> UInt16 {
    var difference = UInt32(bitPattern: (high &- low) &* a) &+ 0x8000
    difference = (difference >> 16) &+ UInt32(bitPattern: low)
    return UInt16(truncatingIfNeeded: difference)
}

/// The reference's input conditioning for the float path.  Not a plain
/// clamp: anything below a billionth — and any NaN — becomes zero, which
/// is what keeps a denormal out of the cell index.
@inlinable
public func clampInterpolationInput(_ v: Float) -> Float {
    if v < 1.0e-9 || v.isNaN { return 0.0 }
    return v > 1.0 ? 1.0 : v
}

public enum Interpolation1D {
    /// The 16-bit table lookup, `LinLerp1D`.
    ///
    /// `domain` is the number of table entries minus one.
    @inlinable
    public static func lookup(
        _ value: UInt16,
        table: UnsafePointer<UInt16>,
        domain: UInt32
    ) -> UInt16 {
        // The last cell has no successor to interpolate towards, and a
        // one-entry table is all last cell.
        if value == 0xFFFF || domain == 0 {
            return table[Int(domain)]
        }

        var val3 = Int32(domain) &* Int32(value)
        val3 = toFixedDomain(val3)

        let cell = Int(val3 >> 16)
        let rest = val3 & 0xFFFF

        return linearInterpolate(rest, Int32(table[cell]), Int32(table[cell + 1]))
    }

    /// The float table lookup, `LinLerp1Dfloat`.
    @inlinable
    public static func lookup(
        _ value: Float,
        table: UnsafePointer<Float>,
        domain: UInt32
    ) -> Float {
        let clamped = clampInterpolationInput(value)

        if clamped == 1.0 || domain == 0 {
            return table[Int(domain)]
        }

        let scaled = clamped * Float(domain)
        // floor and ceil rather than cell and cell+1: at an exact grid
        // point both land on the same cell, and the interpolation is
        // then between an entry and itself.
        let cell0 = Int(scaled.rounded(.down))
        let cell1 = Int(scaled.rounded(.up))
        let rest = scaled - Float(cell0)

        let y0 = table[cell0]
        let y1 = table[cell1]
        return y0 + (y1 - y0) * rest
    }
}
