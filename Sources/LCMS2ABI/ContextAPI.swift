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
        guard let id, let box = id.pointee.swift_ctx else { return .global }
        return Unmanaged<ContextBox>.fromOpaque(box).takeUnretainedValue().context
    }
}

@c @implementation
public func cmsCreateContext(_ Plugin: UnsafeMutableRawPointer?, _ UserData: UnsafeMutableRawPointer?) -> cmsContext? {
    // The reference registers the plugins before returning the context,
    // and returns NULL if that fails.  Registration is not implemented,
    // so a caller asking for it gets that same failure rather than a
    // context that quietly ignored what it was given.
    if Plugin != nil {
        report(
            cmsUInt32Number(cmsERROR_NOT_SUITABLE),
            "cmsCreateContext: plugin registration is not implemented",
            to: nil
        )
        return nil
    }

    let handle = UnsafeMutablePointer<_cmsContext_struct>.allocate(capacity: 1)
    handle.initialize(to: _cmsContext_struct(
        error_logger: nil,
        user_data: UserData,
        swift_ctx: ContextBox.handle(for: ContextBox(copying: nil))
    ))
    return handle
}

@c @implementation
public func cmsDupContext(_ ContextID: cmsContext?, _ NewUserData: UnsafeMutableRawPointer?) -> cmsContext? {
    let source = Context.resolve(ContextID)

    // The copy keeps the original's user data unless given its own, and
    // inherits its logger: the reference duplicates every chunk, and
    // those two are chunks like the rest.
    let userData = NewUserData ?? ContextID?.pointee.user_data
    let logger = ContextID?.pointee.error_logger

    let handle = UnsafeMutablePointer<_cmsContext_struct>.allocate(capacity: 1)
    handle.initialize(to: _cmsContext_struct(
        error_logger: logger,
        user_data: userData,
        swift_ctx: ContextBox.handle(for: ContextBox(copying: source))
    ))
    return handle
}

@c @implementation
public func cmsDeleteContext(_ ContextID: cmsContext?) {
    // Deleting the global context is not a thing: the reference has
    // nothing to unlink for it either.
    guard let ContextID else { return }
    _ = ContextBox.consume(ContextID.pointee.swift_ctx)
    ContextID.deinitialize(count: 1)
    ContextID.deallocate()
}

@c @implementation
public func cmsGetContextUserData(_ ContextID: cmsContext?) -> UnsafeMutableRawPointer? {
    ContextID?.pointee.user_data
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
    UnsafeMutableBufferPointer(start: AlarmCodes, count: Context.maximumChannels)
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
