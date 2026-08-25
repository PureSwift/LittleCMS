// Fixed-point conversion and rounding.
//
// Ported literally from the reference, including the type-punned floor,
// because every value that crosses the ICC boundary passes through here.
// A rounding difference in the last bit propagates through interpolation
// into pixels, so these are the functions the whole engine's byte-for-byte
// agreement rests on: they are measured against the reference exhaustively
// before anything is built on them.

/// The reference's fast floor: add a magic constant that forces the
/// mantissa to align the integer part into the low word, then read it out.
///
/// This is `_cmsQuickFloor`, and it is not `floor()`.  The reference builds
/// with it by default (`CMS_DONT_USE_FAST_FLOOR` selects the slow path),
/// its result is only valid for the limited range the magic constant
/// covers, and at ties it differs from what a correctly-rounded floor
/// would give.  Reproducing the arithmetic exactly matters more than any
/// of that.
@inlinable
public func quickFloor(_ value: Double) -> Int32 {
    // 2^36 * 1.5.  The 52-bit mantissa minus the 16 bits of fraction
    // leaves the integer part starting at bit 16 of the low word.
    let magic = 68719476736.0 * 1.5
    let bits = (value + magic).bitPattern

    // The reference reads `halves[0]` on a little-endian host and
    // `halves[1]` on a big-endian one — in both cases the low 32 bits of
    // the double, which is what this takes without depending on layout.
    return Int32(bitPattern: UInt32(truncatingIfNeeded: bits)) >> 16
}

/// `_cmsQuickFloorWord`: floor into a 16-bit word, biased so the fast
/// floor's valid range covers the whole unsigned range.
@inlinable
public func quickFloorWord(_ value: Double) -> UInt16 {
    UInt16(truncatingIfNeeded: quickFloor(value - 32767.0) &+ 32767)
}

/// `_cmsQuickSaturateWord`: round to nearest and clamp to 16 bits.
@inlinable
public func quickSaturateWord(_ value: Double) -> UInt16 {
    let rounded = value + 0.5
    if rounded <= 0 { return 0 }
    if rounded >= 65535.0 { return 0xFFFF }
    return quickFloorWord(rounded)
}

/// Signed 15.16 fixed point, the encoding of every XYZ number in an ICC
/// profile.
public enum S15Fixed16 {
    @inlinable
    public static func toDouble(_ fixed: Int32) -> Double {
        Double(fixed) / 65536.0
    }

    @inlinable
    public static func fromDouble(_ value: Double) -> Int32 {
        // The reference is `(cmsS15Fixed16Number) floor(v * 65536.0 + 0.5)`
        // — the real floor, not the fast one.
        //
        // That C cast is undefined when the result does not fit in 32 bits,
        // and the hardware the reference runs on does not agree with itself
        // about it: arm64's fcvtzs saturates, while x86-64's cvttsd2si
        // yields INT32_MIN for overflow in *either* direction.  So there is
        // no portable behaviour to reproduce, only a portable behaviour to
        // choose.  This saturates — the answer a caller would want, and the
        // one arm64 already gives — and NaN maps to zero, as fcvtzs does.
        //
        // Nothing valid reaches here: an ICC 15.16 number cannot exceed
        // ±32768, so only malformed input or a fuzzer gets to the clamp.
        let scaled = (value * 65536.0 + 0.5).rounded(.down)
        if scaled.isNaN { return 0 }
        if scaled > 2147483647.0 { return .max }
        if scaled < -2147483648.0 { return .min }
        return Int32(scaled)
    }
}

/// Unsigned 8.8 fixed point, used by the v2 gamma encoding.
public enum U8Fixed8 {
    @inlinable
    public static func toDouble(_ fixed: UInt16) -> Double {
        Double(fixed) / 256.0
    }

    @inlinable
    public static func fromDouble(_ value: Double) -> UInt16 {
        UInt16(truncatingIfNeeded: S15Fixed16.fromDouble(value) >> 8)
    }
}

/// `_cmsQuantizeVal`: the sample value of grid point `i` of `maxSamples`,
/// as a 16-bit code.
@inlinable
public func quantizeValue(_ i: Double, maxSamples: UInt32) -> UInt16 {
    let x = (i * 65535.0) / Double(maxSamples - 1)
    return quickSaturateWord(x)
}
