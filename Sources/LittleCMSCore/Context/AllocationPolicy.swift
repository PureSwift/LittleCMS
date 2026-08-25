// What the library's allocator refuses.
//
// The reference wraps malloc with a coarse size check, "just to prevent
// exploits": a profile claiming an enormous table should fail to allocate
// rather than succeed and be believed.  The policy is here, in the engine,
// because it is arithmetic and belongs where it can be tested; the actual
// allocation is at the boundary, where the C library is, so that a pointer
// this library returns is one the platform's free() would accept.

public enum AllocationPolicy {
    /// `MAX_MEMORY_FOR_ALLOC`.  512 MiB is the reference's limit when it
    /// is built without large-file support, which is how the reference
    /// this library is measured against is built — with it, the limit is
    /// 2 GiB.  A client that hits this is being refused by the reference
    /// too, so the number is part of the observable behaviour.
    public static let maximumAllocation: UInt32 = 512 * 1024 * 1024

    /// Whether a plain allocation of `size` bytes is allowed.  Zero is
    /// refused, as the reference refuses it.
    @inlinable
    public static func allows(size: UInt32) -> Bool {
        size != 0 && size <= maximumAllocation
    }

    /// Whether a reallocation to `size` bytes is allowed.  Unlike a plain
    /// allocation, zero is permitted: the reference passes it through to
    /// realloc, whose answer for zero is the platform's business.
    @inlinable
    public static func allowsReallocation(size: UInt32) -> Bool {
        size <= maximumAllocation
    }

    /// The byte count for an array allocation, or nil when the request is
    /// refused.  The checks are the reference's, in its order: the
    /// product is computed with the wraparound C gives it, a zero total
    /// is refused before anything divides by `size`, and the division and
    /// the two comparisons then catch what wrapped.
    @inlinable
    public static func arraySize(count: UInt32, size: UInt32) -> UInt32? {
        let total = count &* size
        if total == 0 { return nil }
        if count >= UInt32.max / size { return nil }
        if total < count || total < size { return nil }
        if total > maximumAllocation { return nil }
        return total
    }

    /// Whether duplicating a block of `size` bytes is allowed.  Zero is
    /// permitted here and refused by the allocation it then attempts,
    /// which is the reference's behaviour rather than a separate rule.
    @inlinable
    public static func allowsDuplication(size: UInt32) -> Bool {
        size <= maximumAllocation
    }
}
