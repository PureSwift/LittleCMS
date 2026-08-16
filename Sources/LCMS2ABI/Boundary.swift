import CLCMS2

// The conventions every exported entry point follows, established once.
//
// The engine throws typed errors and never sees the C API; functions here
// resolve handles, call the engine, and translate the outcome into the
// reference's conventions: report through the context's logger, then
// return NULL/FALSE/zero.  Nothing in Swift ever longjmps, and lcms2's
// contract never asks it to.

/// Reports a failure through the library's normal error path — the logger
/// of the given context, or the global context's when `context` is nil.
@usableFromInline
func report(_ code: cmsUInt32Number, _ message: String, to context: cmsContext?) {
    message.withCString { text in
        swift_c_signal_error(context, code, text)
    }
}

/// The box behind an opaque handle.
///
/// Every handle the C API hands out is a retained reference to one of
/// these, so the pointer a client holds keeps the engine object alive and
/// the API's own destroy function is what releases it.  One box class per
/// handle type, and a given handle type is always the same box however the
/// client obtained it — a `cmsToneCurve*` from a tag read is the same kind
/// of pointer as one from `cmsBuildGamma`, or the destroy functions would
/// have to guess.
protocol HandleBox: AnyObject {}

extension HandleBox {
    /// A new handle, owning a reference until it is passed back.
    static func handle(for box: Self) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(box).toOpaque()
    }

    /// The box a live handle refers to, without consuming the reference.
    static func borrow(_ handle: UnsafeMutableRawPointer?) -> Self? {
        guard let handle else { return nil }
        return Unmanaged<Self>.fromOpaque(handle).takeUnretainedValue()
    }

    /// The box a handle refers to, consuming the reference: the handle is
    /// dead once this returns, which is what a destroy function wants.
    static func consume(_ handle: UnsafeMutableRawPointer?) -> Self? {
        guard let handle else { return nil }
        return Unmanaged<Self>.fromOpaque(handle).takeRetainedValue()
    }
}
