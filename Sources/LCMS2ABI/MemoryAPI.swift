import CLCMS2
import LittleCMS

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
// A memory-handler plugin replaces these in the reference.  When plugin
// support arrives it can replace them here too — but only for what goes
// through this family.  Swift's own allocations (class instances, array
// and string storage) come from the runtime and cannot be routed through
// a client's allocator; that gap is recorded in docs/abi-audit.md rather
// than papered over.

@c @implementation
public func _cmsMalloc(_ ContextID: cmsContext?, _ size: cmsUInt32Number) -> UnsafeMutableRawPointer? {
    guard AllocationPolicy.allows(size: size) else { return nil }
    return malloc(Int(size))
}

@c @implementation
public func _cmsMallocZero(_ ContextID: cmsContext?, _ size: cmsUInt32Number) -> UnsafeMutableRawPointer? {
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
    guard let total = AllocationPolicy.arraySize(count: num, size: size) else { return nil }
    return _cmsMallocZero(ContextID, total)
}

@c @implementation
public func _cmsRealloc(
    _ ContextID: cmsContext?,
    _ Ptr: UnsafeMutableRawPointer?,
    _ NewSize: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    guard AllocationPolicy.allowsReallocation(size: NewSize) else { return nil }
    return realloc(Ptr, Int(NewSize))
}

@c @implementation
public func _cmsFree(_ ContextID: cmsContext?, _ Ptr: UnsafeMutableRawPointer?) {
    if let Ptr { free(Ptr) }
}

@c @implementation
public func _cmsDupMem(
    _ ContextID: cmsContext?,
    _ Org: UnsafeRawPointer?,
    _ size: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    guard AllocationPolicy.allowsDuplication(size: size) else { return nil }
    guard let block = _cmsMalloc(ContextID, size) else { return nil }
    if let Org { memmove(block, Org, Int(size)) }
    return block
}
