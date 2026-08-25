// How ICC fields are encoded, apart from where the bytes come from.
//
// The stream mechanics live at the boundary, where FILE* and the public
// cmsIOHANDLER vtable are.  What is here is the part that decides what the
// bytes mean: byte order, the padding between elements, and which values
// the format is willing to believe.  Those are the parts the engine's own
// profile reader will share, and the parts worth testing without a heap.

public enum ICCField {
    /// `_cmsALIGNLONG`: ICC elements start on a four-byte boundary, and the
    /// gap between one and the next is padding.
    @inlinable
    public static func alignedLength(_ length: UInt32) -> UInt32 {
        (length &+ 3) & ~3
    }

    /// How many padding bytes separate `position` from the next element.
    @inlinable
    public static func paddingAfter(_ position: UInt32) -> UInt32 {
        alignedLength(position) &- position
    }

    /// Whether a 32-bit float read out of a profile is one to accept.
    ///
    /// The reference refuses absurd magnitudes outright, and then refuses
    /// anything that is not zero or normal — so a subnormal, an infinity
    /// and a NaN are all rejected, which is what stops a crafted profile
    /// putting one into a curve.  A NaN fails the magnitude comparisons
    /// (every comparison against it is false) and is caught by the second
    /// test, exactly as it is in the reference.
    /// The magnitude test is done in `Double`, which is not a detail: C
    /// promotes the float to double before comparing it against `1E+20`,
    /// and the nearest float to 1e20 is larger than 1e20.  Comparing in
    /// `Float` accepts that value where the reference refuses it.
    @inlinable
    public static func isAcceptable(_ value: Float) -> Bool {
        let widened = Double(value)
        if widened > 1e20 || widened < -1e20 { return false }
        return value.isZero || value.isNormal
    }
}
