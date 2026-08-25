// Half-precision conversion.
//
// Table-driven, exactly as the reference is.  Swift's `Float16` would be
// the obvious implementation and is deliberately not used: it rounds
// differently from these tables at the subnormal boundary and carries NaN
// payloads differently, and the values this produces end up in pixel data
// that is compared byte for byte.
//
// The tables are in HalfTables.swift, transcribed mechanically from the
// reference by scripts/gen_half_tables.py.

// Not `@inlinable`: that would require exposing ten kilobytes of table as
// `@usableFromInline`, and everything on a hot path that converts halves
// is inside this module, where the optimizer sees them anyway.

/// `_cmsHalf2Float`.
public func halfToFloat(_ h: UInt16) -> Float {
    let n = Int(h >> 10)
    let bits = halfMantissa[Int(h & 0x3FF) + Int(halfOffset[n])] &+ halfExponent[n]
    return Float(bitPattern: bits)
}

/// `_cmsFloat2Half`.
public func floatToHalf(_ value: Float) -> UInt16 {
    let n = value.bitPattern
    let j = Int((n >> 23) & 0x1FF)
    return UInt16(truncatingIfNeeded: UInt32(halfBase[j]) &+ ((n & 0x007F_FFFF) >> UInt32(halfShift[j])))
}
