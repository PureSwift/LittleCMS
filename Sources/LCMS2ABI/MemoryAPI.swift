import CLCMS2
import LittleCMSCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The library's allocator.
//
// The size policy is the engine's, where it can be tested without a heap;
// the allocation itself is here, through the platform's own malloc, so a
// block this library returns is one the reference's free() would accept
// and vice versa.  Clients and plugins do pass blocks across that line.
//
// A memory-handler plugin replaces the allocator per context — its
// functions sit in the context struct, and each entry point here checks
// for one before falling back to the built-in.  What a plugin can
// replace is what goes through this family: the C-layout blocks the
// library hands out and keeps.  Swift's own allocations — class
// instances, array and string storage — come from the runtime and cannot
// be routed through a client's allocator; that gap is recorded in
// docs/abi-audit.md rather than papered over.

/// The context struct behind a handle — the static global one for nil.
@inline(__always)
private func slots(_ ContextID: cmsContext?) -> UnsafeMutablePointer<_cmsContext_struct> {
    swift_c_resolve_context(ContextID)
}

@c @implementation
public func _cmsMalloc(_ ContextID: cmsContext?, _ size: cmsUInt32Number) -> UnsafeMutableRawPointer? {
    if let hook = slots(ContextID).pointee.malloc_fn {
        return unsafeBitCast(hook, to: _cmsMallocFnPtrType.self)(ContextID, size)
    }
    guard AllocationPolicy.allows(size: size) else { return nil }
    return malloc(Int(size))
}

@c @implementation
public func _cmsMallocZero(_ ContextID: cmsContext?, _ size: cmsUInt32Number) -> UnsafeMutableRawPointer? {
    if let hook = slots(ContextID).pointee.malloc_zero_fn {
        return unsafeBitCast(hook, to: _cmsMalloZerocFnPtrType.self)(ContextID, size)
    }
    // The default goes through _cmsMalloc, so a plugin that supplied
    // only that still sees every allocation.
    guard let block = _cmsMalloc(ContextID, size) else { return nil }
    memset(block, 0, Int(size))
    return block
}

@c @implementation
public func _cmsCalloc(
    _ ContextID: cmsContext?,
    _ num: cmsUInt32Number,
    _ size: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    if let hook = slots(ContextID).pointee.calloc_fn {
        return unsafeBitCast(hook, to: _cmsCallocFnPtrType.self)(ContextID, num, size)
    }
    guard let total = AllocationPolicy.arraySize(count: num, size: size) else { return nil }
    return _cmsMallocZero(ContextID, total)
}

@c @implementation
public func _cmsRealloc(
    _ ContextID: cmsContext?,
    _ Ptr: UnsafeMutableRawPointer?,
    _ NewSize: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    if let hook = slots(ContextID).pointee.realloc_fn {
        return unsafeBitCast(hook, to: _cmsReallocFnPtrType.self)(ContextID, Ptr, NewSize)
    }
    guard AllocationPolicy.allowsReallocation(size: NewSize) else { return nil }
    return realloc(Ptr, Int(NewSize))
}

@c @implementation
public func _cmsFree(_ ContextID: cmsContext?, _ Ptr: UnsafeMutableRawPointer?) {
    // Freeing nothing is nothing, and a plugin is not asked about it.
    guard let Ptr else { return }
    if let hook = slots(ContextID).pointee.free_fn {
        unsafeBitCast(hook, to: _cmsFreeFnPtrType.self)(ContextID, Ptr)
        return
    }
    free(Ptr)
}

@c @implementation
public func _cmsDupMem(
    _ ContextID: cmsContext?,
    _ Org: UnsafeRawPointer?,
    _ size: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    if let hook = slots(ContextID).pointee.dup_fn {
        return unsafeBitCast(hook, to: _cmsDupFnPtrType.self)(ContextID, Org, size)
    }
    guard AllocationPolicy.allowsDuplication(size: size) else { return nil }
    guard let block = _cmsMalloc(ContextID, size) else { return nil }
    if let Org { memmove(block, Org, Int(size)) }
    return block
}
