import CLCMS2
import LittleCMSCore

/// The engine's MD5 state behind a `cmsHANDLE`.
final class MD5Box: HandleBox {
    var digest = MD5()
    let context: cmsContext?

    init(context: cmsContext?) {
        self.context = context
    }
}

@c @implementation
public func cmsMD5alloc(_ ContextID: cmsContext?) -> cmsHANDLE? {
    // The reference returns NULL when its allocator fails.  Ours cannot
    // report that: a Swift allocation failure is a trap, not a nil.
    MD5Box.handle(for: MD5Box(context: ContextID))
}

@c @implementation
public func cmsMD5add(
    _ Handle: cmsHANDLE?,
    _ buf: UnsafePointer<cmsUInt8Number>?,
    _ len: cmsUInt32Number
) {
    guard let box = MD5Box.borrow(Handle) else { return }
    guard let buf, len > 0 else { return }
    box.digest.update(UnsafeBufferPointer(start: buf, count: Int(len)))
}

@c @implementation
public func cmsMD5finish(_ ProfileID: UnsafeMutablePointer<cmsProfileID>?, _ Handle: cmsHANDLE?) {
    // Destroys the object, as the reference does, so the handle must be
    // consumed whether or not there is anywhere to put the answer.
    guard let box = MD5Box.consume(Handle) else { return }
    guard let ProfileID else { return }
    let digest = box.digest.finish()
    withUnsafeMutableBytes(of: &ProfileID.pointee.ID8) { destination in
        digest.withUnsafeBytes { destination.copyMemory(from: $0) }
    }
}
