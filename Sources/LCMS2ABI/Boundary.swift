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
