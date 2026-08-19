import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The mutex the plugin interface exposes.
//
// A client can replace these through a mutex plugin, which is how an
// application with its own threading brings its own primitive; each
// call asks the context's registry first.  Without one this is the
// reference's default: one pthread mutex per call, allocated through the
// library's own allocator so that a plugin replacing that allocator sees
// these too.
//
// The reference returns NULL from create only when there is no mutex
// implementation at all, and NULL then means "no locking needed" — a
// success, not a failure.  Its default does have one, so this does too.

@c @implementation
public func _cmsCreateMutex(_ ContextID: cmsContext?) -> UnsafeMutableRawPointer? {
    if let hooks = PluginRegistry.resolve(ContextID).mutex { return hooks.create(ContextID) }
    guard let block = _cmsMalloc(ContextID, cmsUInt32Number(MemoryLayout<pthread_mutex_t>.size)) else {
        return nil
    }
    let mutex = block.assumingMemoryBound(to: pthread_mutex_t.self)
    pthread_mutex_init(mutex, nil)
    return block
}

@c @implementation
public func _cmsDestroyMutex(_ ContextID: cmsContext?, _ mtx: UnsafeMutableRawPointer?) {
    if let hooks = PluginRegistry.resolve(ContextID).mutex {
        hooks.destroy(ContextID, mtx)
        return
    }
    guard let mtx else { return }
    pthread_mutex_destroy(mtx.assumingMemoryBound(to: pthread_mutex_t.self))
    _cmsFree(ContextID, mtx)
}

@c @implementation
public func _cmsLockMutex(_ ContextID: cmsContext?, _ mtx: UnsafeMutableRawPointer?) -> cmsBool {
    if let hooks = PluginRegistry.resolve(ContextID).mutex {
        return hooks.lock(ContextID, mtx)
    }
    guard let mtx else { return 1 }
    return pthread_mutex_lock(mtx.assumingMemoryBound(to: pthread_mutex_t.self)) == 0 ? 1 : 0
}

@c @implementation
public func _cmsUnlockMutex(_ ContextID: cmsContext?, _ mtx: UnsafeMutableRawPointer?) {
    if let hooks = PluginRegistry.resolve(ContextID).mutex {
        hooks.unlock(ContextID, mtx)
        return
    }
    guard let mtx else { return }
    pthread_mutex_unlock(mtx.assumingMemoryBound(to: pthread_mutex_t.self))
}
