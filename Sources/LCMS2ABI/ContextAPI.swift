import CLCMS2
import LittleCMS

/// The engine context behind a `cmsContext`.
final class ContextBox: HandleBox {
    let context: Context

    init(copying source: Context?) {
        context = Context(copying: source)
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

@c @implementation
public func cmsCreateContext(_ Plugin: UnsafeMutableRawPointer?, _ UserData: UnsafeMutableRawPointer?) -> cmsContext? {
    let handle = UnsafeMutablePointer<_cmsContext_struct>.allocate(capacity: 1)
    handle.initialize(to: _cmsContext_struct())
    handle.pointee.user_data = UserData
    handle.pointee.swift_ctx = ContextBox.handle(for: ContextBox(copying: nil))
    swift_c_register_context(handle)

    // The reference registers the plugins before returning the context,
    // and returns NULL if that fails.  The memory handler, when the chain
    // has one, goes in first: it is what the context's own storage is
    // allocated through.
    if let Plugin {
        if let memory = findMemoryPlugin(Plugin) {
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

    let handle = UnsafeMutablePointer<_cmsContext_struct>.allocate(capacity: 1)
    handle.initialize(to: _cmsContext_struct())
    handle.pointee.error_logger = logger
    handle.pointee.user_data = userData
    handle.pointee.swift_ctx = ContextBox.handle(for: ContextBox(copying: source))
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
    ContextID.deinitialize(count: 1)
    ContextID.deallocate()
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
