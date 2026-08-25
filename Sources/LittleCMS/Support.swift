import CLCMS2
import LCMS2ABI
import Synchronization

// Every wrapper object owns one of these: a private `cmsContext` whose
// error logger stows the report where the next throw can find it.  The
// raw context never escapes the module, so its user-data slot is free
// to carry the capture box.

final class CaptureContext: @unchecked Sendable {
    let raw: cmsContext?
    private let last = Mutex<CMSError?>(nil)

    init() {
        raw = cmsCreateContext(nil, nil)
        if let raw {
            raw.pointee.user_data = Unmanaged.passUnretained(self).toOpaque()
            cmsSetLogErrorHandlerTHR(raw, captureLogger)
        }
    }

    deinit {
        if let raw { cmsDeleteContext(raw) }
    }

    func record(_ error: CMSError) {
        last.withLock { $0 = error }
    }

    /// The captured error, or a generic one when the library refused
    /// without reporting.
    func take(or fallback: String) -> CMSError {
        let captured = last.withLock { error in
            let taken = error
            error = nil
            return taken
        }
        return captured ?? CMSError(code: .undefined, message: fallback)
    }
}

private func captureLogger(
    _ context: cmsContext?, _ code: cmsUInt32Number, _ text: UnsafePointer<CChar>?
) {
    guard let context, let box = context.pointee.user_data else { return }
    let capture = Unmanaged<CaptureContext>.fromOpaque(box).takeUnretainedValue()
    capture.record(CMSError(
        code: CMSError.Code(rawValue: code) ?? .undefined,
        message: text.map { String(cString: $0) } ?? ""
    ))
}

/// A three-byte locale field from however much of a string fits.
func localeField(_ text: String?) -> [CChar] {
    var field: [CChar] = [0, 0, 0]
    if let text {
        for (i, byte) in text.utf8.prefix(2).enumerated() { field[i] = CChar(bitPattern: byte) }
    }
    return field
}
