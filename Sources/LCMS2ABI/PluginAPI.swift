import CLCMS2
import LittleCMS

// Plugin registration.
//
// A plugin is a chain of structs each naming what it replaces; the
// library walks the chain and installs each.  The memory handler goes
// into the context struct itself — the allocator consults it on a
// pointer read — and every other kind goes into the context's
// PluginRegistry, which the lookup sites ask before their built-in
// tables.

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

/// Installs one plugin of any kind but the memory handler.  False when
/// the plugin is missing something it must have, which is what the
/// reference answers too.
private func install(_ p: UnsafeMutablePointer<cmsPluginBase>, in registry: PluginRegistry) -> Bool {
    let raw = UnsafeMutableRawPointer(p)
    switch Int32(bitPattern: p.pointee.Type) {
    case cmsPluginInterpolationSig:
        // One factory per context: the newest replaces the last.
        registry.interpolators = raw.assumingMemoryBound(to: cmsPluginInterpolation.self).pointee.InterpolatorsFactory

    case cmsPluginParametricCurveSig:
        let plugin = raw.assumingMemoryBound(to: cmsPluginParametricCurves.self).pointee
        guard let evaluator = plugin.Evaluator else { return false }
        let n = min(Int(plugin.nFunctions), Int(MAX_TYPES_IN_LCMS_PLUGIN))
        var types: [(type: cmsUInt32Number, parameterCount: cmsUInt32Number)] = []
        withUnsafeBytes(of: plugin.FunctionTypes) { t in
            withUnsafeBytes(of: plugin.ParameterCount) { c in
                let tt = t.bindMemory(to: cmsUInt32Number.self)
                let cc = c.bindMemory(to: cmsUInt32Number.self)
                for i in 0..<n { types.append((tt[i], cc[i])) }
            }
        }
        registry.parametricCurves.insert(ParametricCurveCollection(evaluator: evaluator, types: types), at: 0)

    case cmsPluginFormattersSig:
        guard let factory = raw.assumingMemoryBound(to: cmsPluginFormatters.self).pointee.FormattersFactory else { return false }
        registry.formatterFactories.insert(factory, at: 0)

    case cmsPluginTagTypeSig:
        registry.tagTypes.insert(raw.assumingMemoryBound(to: cmsPluginTagType.self).pointee.Handler, at: 0)

    case cmsPluginMultiProcessElementSig:
        registry.mpeTypes.insert(raw.assumingMemoryBound(to: cmsPluginMultiProcessElement.self).pointee.Handler, at: 0)

    case cmsPluginTagSig:
        let plugin = raw.assumingMemoryBound(to: cmsPluginTag.self).pointee
        registry.tags[plugin.Signature] = TagDescriptor(plugin.Descriptor)

    case cmsPluginRenderingIntentSig:
        let plugin = raw.assumingMemoryBound(to: cmsPluginRenderingIntent.self)
        guard let link = plugin.pointee.Link else { return false }
        let description = withUnsafeBytes(of: plugin.pointee.Description) { bytes in
            PluginRegistry.copyDescription(bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        registry.intents.insert(PluginIntent(intent: plugin.pointee.Intent, link: link, description: description), at: 0)

    case cmsPluginOptimizationSig:
        guard let optimize = raw.assumingMemoryBound(to: cmsPluginOptimization.self).pointee.OptimizePtr else { return false }
        registry.optimizations.insert(optimize, at: 0)

    case cmsPluginTransformSig:
        guard let factory = raw.assumingMemoryBound(to: cmsPluginTransform.self).pointee.factories.xform else { return false }
        // A factory declared against a version before 2.8 answers with a
        // one-scanline function and gets an adaptor.
        registry.transforms.insert(TransformFactoryEntry(factory: factory, legacy: p.pointee.ExpectedVersion < 2080), at: 0)

    case cmsPluginMutexSig:
        let plugin = raw.assumingMemoryBound(to: cmsPluginMutex.self).pointee
        guard let create = plugin.CreateMutexPtr, let destroy = plugin.DestroyMutexPtr,
              let lock = plugin.LockMutexPtr, let unlock = plugin.UnlockMutexPtr
        else { return false }
        registry.mutex = MutexHooks(create: create, destroy: destroy, lock: lock, unlock: unlock)

    case cmsPluginParalellizationSig:
        let plugin = raw.assumingMemoryBound(to: cmsPluginParalellization.self).pointee
        guard let scheduler = plugin.SchedulerFn else { return false }
        registry.parallelization = ParallelizationHooks(
            maxWorkers: plugin.MaxWorkers, workerFlags: plugin.WorkerFlags, scheduler: scheduler
        )

    default:
        return false
    }
    return true
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
            if !install(p, in: PluginRegistry.resolve(id)) { return 0 }
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

/// Back to the defaults for every kind.
@c @implementation
public func cmsUnregisterPluginsTHR(_ ContextID: cmsContext?) {
    _ = installMemoryHandler(ContextID, nil)
    PluginRegistry.resolve(ContextID).reset()
}

@c @implementation
public func cmsUnregisterPlugins() {
    cmsUnregisterPluginsTHR(nil)
}
