import CLCMS2
import LittleCMSCore

/// The engine context behind a `cmsContext`.
final class ContextBox: HandleBox {
    let context: Context
    /// What plugins have added to this context.
    let plugins: PluginRegistry

    init(copying source: Context?, plugins: PluginRegistry? = nil) {
        context = Context(copying: source)
        self.plugins = plugins ?? PluginRegistry()
    }
}

extension Context {
    /// The engine context a `cmsContext` refers to.  A null ID is the
    /// global context, which is what the reference means by context zero.
    static func resolve(_ id: cmsContext?) -> Context {
        guard let box = swift_c_resolve_context(id)?.pointee.swift_ctx else { return .global }
        return Unmanaged<ContextBox>.fromOpaque(box).takeUnretainedValue().context
    }
}

/// The context struct, allocated through a memory plugin's functions
/// when there are any — the reference does this too, and its testbed
/// relies on it: it marks the block through the plugin's own header
/// just before the handle.  Zeroed either way; nil when the plugin
/// refuses.
private func allocateContextStruct(
    malloc: UnsafeMutableRawPointer?, mallocZero: UnsafeMutableRawPointer?, free: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<_cmsContext_struct>? {
    let size = cmsUInt32Number(MemoryLayout<_cmsContext_struct>.size)
    let raw: UnsafeMutableRawPointer?
    if let mallocZero {
        raw = unsafeBitCast(mallocZero, to: _cmsMalloZerocFnPtrType.self)(nil, size)
    } else if let malloc {
        raw = unsafeBitCast(malloc, to: _cmsMallocFnPtrType.self)(nil, size)
        if let raw { memset(raw, 0, Int(size)) }
    } else {
        // Without a plugin the struct still gets a header's worth of
        // slack in front of it: the reference's testbed marks a context
        // by writing just before the handle, assuming a memory plugin's
        // header is there, and does so on contexts it created without
        // one.  With the reference that write lands in malloc slack;
        // here it lands in ours.
        let block = UnsafeMutableRawPointer.allocate(byteCount: contextSlack + Int(size), alignment: 16)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: contextSlack + Int(size))
        raw = block + contextSlack
    }
    guard let raw else { return nil }
    let handle = raw.bindMemory(to: _cmsContext_struct.self, capacity: 1)
    handle.pointee.handle_free_fn = (malloc != nil || mallocZero != nil) ? free : nil
    return handle
}

/// Releases a context struct the way it was allocated.
private func releaseContextStruct(_ handle: UnsafeMutablePointer<_cmsContext_struct>) {
    if let free = handle.pointee.handle_free_fn {
        unsafeBitCast(free, to: _cmsFreeFnPtrType.self)(nil, UnsafeMutableRawPointer(handle))
    } else {
        (UnsafeMutableRawPointer(handle) - contextSlack).deallocate()
    }
}

/// Room left in front of a context struct we allocate ourselves; see
/// `allocateContextStruct`.  The reference testbed's header is 32 bytes.
private let contextSlack = 32

@c @implementation
public func cmsCreateContext(_ Plugin: UnsafeMutableRawPointer?, _ UserData: UnsafeMutableRawPointer?) -> cmsContext? {
    // The memory handler, when the chain has one, is found before
    // anything else: the context's own storage comes through it.
    let memory = Plugin.flatMap { findMemoryPlugin($0) }
    guard let handle = allocateContextStruct(
        malloc: memory?.pointee.MallocPtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) },
        mallocZero: memory?.pointee.MallocZeroPtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) },
        free: memory?.pointee.FreePtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
    ) else { return nil }
    handle.pointee.user_data = UserData
    handle.pointee.swift_ctx = ContextBox.handle(for: ContextBox(copying: nil))
    swift_c_register_context(handle)

    // The reference registers the plugins before returning the context,
    // and returns NULL if that fails.  The memory handler goes in first,
    // so the rest of the registration allocates through it.
    if let Plugin {
        if let memory {
            _ = cmsPluginTHR(handle, UnsafeMutableRawPointer(memory))
        }
        if cmsPluginTHR(handle, Plugin) == 0 {
            cmsDeleteContext(handle)
            return nil
        }
    }
    return handle
}

@c @implementation
public func cmsDupContext(_ ContextID: cmsContext?, _ NewUserData: UnsafeMutableRawPointer?) -> cmsContext? {
    let source = Context.resolve(ContextID)

    // The copy keeps the original's user data unless given its own, and
    // inherits its logger: the reference duplicates every chunk, and
    // those two are chunks like the rest.
    let resolved = swift_c_resolve_context(ContextID)!
    let userData = NewUserData ?? resolved.pointee.user_data
    let logger = resolved.pointee.error_logger

    // Allocated through the source's memory handler, as the reference
    // does — the copy inherits that handler, so it can release itself.
    guard let handle = allocateContextStruct(
        malloc: resolved.pointee.malloc_fn, mallocZero: resolved.pointee.malloc_zero_fn, free: resolved.pointee.free_fn
    ) else { return nil }
    handle.pointee.error_logger = logger
    handle.pointee.user_data = userData
    handle.pointee.swift_ctx = ContextBox.handle(
        for: ContextBox(copying: source, plugins: PluginRegistry.resolve(ContextID).copy())
    )
    // The memory handler is a chunk like the rest, and comes along.
    copyMemoryHooks(from: ContextID, to: handle)
    swift_c_register_context(handle)
    return handle
}

@c @implementation
public func cmsDeleteContext(_ ContextID: cmsContext?) {
    // Deleting the global context is not a thing: the reference has
    // nothing to unlink for it either.
    // ...and neither is deleting a handle that is not a context: the
    // reference walks its pool and ignores what it does not find.
    guard let ContextID, swift_c_unregister_context(ContextID) != 0 else { return }
    _ = ContextBox.consume(ContextID.pointee.swift_ctx)
    releaseContextStruct(ContextID)
}

@c @implementation
public func cmsGetContextUserData(_ ContextID: cmsContext?) -> UnsafeMutableRawPointer? {
    swift_c_resolve_context(ContextID)?.pointee.user_data
}

// -- alarm codes -------------------------------------------------------

@c @implementation
public func cmsSetAlarmCodesTHR(
    _ ContextID: cmsContext?,
    _ AlarmCodes: UnsafePointer<cmsUInt16Number>?
) {
    guard let AlarmCodes else { return }
    let incoming = UnsafeBufferPointer(start: AlarmCodes, count: Context.maximumChannels)
    Context.resolve(ContextID).update { $0.alarmCodes = Array(incoming) }
}

@c @implementation
public func cmsGetAlarmCodesTHR(
    _ ContextID: cmsContext?,
    _ AlarmCodes: UnsafeMutablePointer<cmsUInt16Number>?
) {
    guard let AlarmCodes else { return }
    let codes = Context.resolve(ContextID).chunks.alarmCodes
    _ = UnsafeMutableBufferPointer(start: AlarmCodes, count: Context.maximumChannels)
        .update(fromContentsOf: codes)
}

@c @implementation
public func cmsSetAlarmCodes(_ NewAlarm: UnsafePointer<cmsUInt16Number>?) {
    cmsSetAlarmCodesTHR(nil, NewAlarm)
}

@c @implementation
public func cmsGetAlarmCodes(_ NewAlarm: UnsafeMutablePointer<cmsUInt16Number>?) {
    cmsGetAlarmCodesTHR(nil, NewAlarm)
}

// -- adaptation state --------------------------------------------------

@c @implementation
public func cmsSetAdaptationStateTHR(_ ContextID: cmsContext?, _ d: cmsFloat64Number) -> cmsFloat64Number {
    // Always answers the previous value, and only stores a new one when
    // it is not negative — which is how a caller reads the setting
    // without disturbing it.
    Context.resolve(ContextID).update { chunks in
        let previous = chunks.adaptationState
        if d >= 0.0 { chunks.adaptationState = d }
        return previous
    }
}

@c @implementation
public func cmsSetAdaptationState(_ d: cmsFloat64Number) -> cmsFloat64Number {
    cmsSetAdaptationStateTHR(nil, d)
}
