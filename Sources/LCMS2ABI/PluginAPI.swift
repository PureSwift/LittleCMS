import CLCMS2
import LittleCMS

// Plugin registration.
//
// A plugin is a chain of structs each naming what it replaces; the
// library walks the chain and installs each.  Of the twelve kinds the
// reference accepts, the memory handler is installed here — its
// functions go into the context struct and the allocator consults them
// — and the rest are refused with a report, since the tables they would
// extend (tag types, formatters, intents, stages, curves, interpolation,
// optimizations, transforms, mutexes, parallelization) are not open to
// extension yet.  A caller learns that at registration, not at use.

/// The memory handler's functions installed on a context — or all
/// cleared, back to the built-in allocator.  The three required ones
/// are the plugin's; the other three fall back to defaults built on
/// them when the plugin leaves them out.
private func installMemoryHandler(_ ContextID: cmsContext?, _ plugin: UnsafeMutablePointer<cmsPluginMemHandler>?) -> Bool {
    let ctx = swift_c_resolve_context(ContextID)!
    guard let plugin else {
        ctx.pointee.malloc_fn = nil
        ctx.pointee.free_fn = nil
        ctx.pointee.realloc_fn = nil
        ctx.pointee.malloc_zero_fn = nil
        ctx.pointee.calloc_fn = nil
        ctx.pointee.dup_fn = nil
        return true
    }
    guard let m = plugin.pointee.MallocPtr, let f = plugin.pointee.FreePtr, let r = plugin.pointee.ReallocPtr
    else { return false }
    ctx.pointee.malloc_fn = unsafeBitCast(m, to: UnsafeMutableRawPointer.self)
    ctx.pointee.free_fn = unsafeBitCast(f, to: UnsafeMutableRawPointer.self)
    ctx.pointee.realloc_fn = unsafeBitCast(r, to: UnsafeMutableRawPointer.self)
    ctx.pointee.malloc_zero_fn = plugin.pointee.MallocZeroPtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
    ctx.pointee.calloc_fn = plugin.pointee.CallocPtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
    ctx.pointee.dup_fn = plugin.pointee.DupPtr.map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
    return true
}

/// The memory handler in a chain, if any: it has to be found before the
/// rest, since a context's own storage is allocated through it.
func findMemoryPlugin(_ chain: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<cmsPluginMemHandler>? {
    var plugin = chain?.assumingMemoryBound(to: cmsPluginBase.self)
    while let p = plugin {
        if Int32(bitPattern: p.pointee.Magic) == cmsPluginMagicNumber && Int32(bitPattern: p.pointee.Type) == cmsPluginMemHandlerSig
            && p.pointee.ExpectedVersion <= cmsUInt32Number(LCMS_VERSION)
        {
            return UnsafeMutableRawPointer(p).assumingMemoryBound(to: cmsPluginMemHandler.self)
        }
        plugin = p.pointee.Next
    }
    return nil
}

/// Copies the memory hooks of one context struct to another, for
/// cmsDupContext.
func copyMemoryHooks(from source: cmsContext?, to destination: UnsafeMutablePointer<_cmsContext_struct>) {
    let s = swift_c_resolve_context(source)!
    destination.pointee.malloc_fn = s.pointee.malloc_fn
    destination.pointee.free_fn = s.pointee.free_fn
    destination.pointee.realloc_fn = s.pointee.realloc_fn
    destination.pointee.malloc_zero_fn = s.pointee.malloc_zero_fn
    destination.pointee.calloc_fn = s.pointee.calloc_fn
    destination.pointee.dup_fn = s.pointee.dup_fn
}

private func pluginTypeName(_ type: cmsUInt32Number) -> String {
    switch Int32(bitPattern: type) {
    case cmsPluginInterpolationSig: return "interpolation"
    case cmsPluginTagTypeSig: return "tag type"
    case cmsPluginTagSig: return "tag"
    case cmsPluginFormattersSig: return "formatter"
    case cmsPluginRenderingIntentSig: return "rendering intent"
    case cmsPluginParametricCurveSig: return "parametric curve"
    case cmsPluginMultiProcessElementSig: return "multi-process element"
    case cmsPluginOptimizationSig: return "optimization"
    case cmsPluginTransformSig: return "transform"
    case cmsPluginMutexSig: return "mutex"
    case cmsPluginParalellizationSig: return "parallelization"
    default: return ""
    }
}

@c @implementation
public func cmsPluginTHR(_ id: cmsContext?, _ Plug_in: UnsafeMutableRawPointer?) -> cmsBool {
    var plugin = Plug_in?.assumingMemoryBound(to: cmsPluginBase.self)
    while let p = plugin {
        if Int32(bitPattern: p.pointee.Magic) != cmsPluginMagicNumber {
            report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unrecognized plugin", to: id)
            return 0
        }
        if p.pointee.ExpectedVersion > cmsUInt32Number(LCMS_VERSION) {
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "plugin needs Little CMS \(p.pointee.ExpectedVersion), current version is \(LCMS_VERSION)", to: id
            )
            return 0
        }

        switch Int32(bitPattern: p.pointee.Type) {
        case cmsPluginMemHandlerSig:
            if !installMemoryHandler(id, UnsafeMutableRawPointer(p).assumingMemoryBound(to: cmsPluginMemHandler.self)) {
                return 0
            }
        case cmsPluginInterpolationSig, cmsPluginTagTypeSig, cmsPluginTagSig, cmsPluginFormattersSig,
             cmsPluginRenderingIntentSig, cmsPluginParametricCurveSig, cmsPluginMultiProcessElementSig,
             cmsPluginOptimizationSig, cmsPluginTransformSig, cmsPluginMutexSig, cmsPluginParalellizationSig:
            report(
                cmsUInt32Number(cmsERROR_NOT_SUITABLE),
                "\(pluginTypeName(p.pointee.Type)) plugins are not implemented", to: id
            )
            return 0
        default:
            let hex = String(p.pointee.Type, radix: 16, uppercase: true)
            report(cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION), "Unrecognized plugin type '\(hex)'", to: id)
            return 0
        }
        plugin = p.pointee.Next
    }
    return 1
}

@c @implementation
public func cmsPlugin(_ Plugin: UnsafeMutableRawPointer?) -> cmsBool {
    cmsPluginTHR(nil, Plugin)
}

/// Back to the defaults for every kind — which here means the built-in
/// allocator, the others never having been replaced.
@c @implementation
public func cmsUnregisterPluginsTHR(_ ContextID: cmsContext?) {
    _ = installMemoryHandler(ContextID, nil)
}

@c @implementation
public func cmsUnregisterPlugins() {
    cmsUnregisterPluginsTHR(nil)
}
