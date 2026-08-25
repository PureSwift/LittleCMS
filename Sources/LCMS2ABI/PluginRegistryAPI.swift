import CLCMS2
import LittleCMSCore

// The plugin registries: what a context has had added to it.
//
// The reference keeps one chunk per plugin kind on every context, each a
// linked list searched newest-first before the built-in table, and copies
// the lists when a context is duplicated.  Here that is one object per
// context holding the same lists, with the global context's registry a
// process-wide static.  Every lookup site asks the registry first and
// falls back to its built-in table, which is the reference's search
// order exactly.
//
// The registries are written at registration and read after; like the
// reference, registration is not synchronised against use.

/// A parametric-curve plugin: an evaluator and the types it serves,
/// with each type's parameter count.
struct ParametricCurveCollection {
    let evaluator: cmsParametricCurveEvaluator
    let types: [(type: cmsUInt32Number, parameterCount: cmsUInt32Number)]

    /// The position of a type in the collection, matched by magnitude
    /// as the reference does: a negative type is the inverse of the
    /// positive one and shares its evaluator.
    func index(of type: cmsInt32Number) -> Int? {
        let magnitude = cmsUInt32Number(type.magnitude)
        return types.firstIndex { $0.type == magnitude }
    }
}

/// A rendering intent a plugin added.
struct PluginIntent {
    let intent: cmsUInt32Number
    let link: cmsIntentFn
    /// The description as a C string that lives as long as the registry
    /// entry, since cmsGetSupportedIntents hands the pointer out.
    let description: UnsafeMutablePointer<CChar>
}

/// A transform factory a plugin added, and whether it answers in the
/// one-scanline style that predates 2.6.
struct TransformFactoryEntry {
    let factory: _cmsTransform2Factory
    let legacy: Bool
}

struct MutexHooks {
    let create: _cmsCreateMutexFnPtrType
    let destroy: _cmsDestroyMutexFnPtrType
    let lock: _cmsLockMutexFnPtrType
    let unlock: _cmsUnlockMutexFnPtrType
}

struct ParallelizationHooks {
    let maxWorkers: cmsInt32Number
    let workerFlags: cmsUInt32Number
    let scheduler: _cmsTransform2Fn
}

final class PluginRegistry: @unchecked Sendable {
    /// The global context's registry.
    static let global = PluginRegistry()

    var interpolators: cmsInterpFnFactory?
    /// Newest first, as the reference searches them.
    var parametricCurves: [ParametricCurveCollection] = []
    var formatterFactories: [cmsFormatterFactory] = []
    var tagTypes: [cmsTagTypeHandler] = []
    var mpeTypes: [cmsTagTypeHandler] = []
    var tags: [cmsTagSignature: TagDescriptor] = [:]
    var intents: [PluginIntent] = []
    var optimizations: [_cmsOPToptimizeFn] = []
    var transforms: [TransformFactoryEntry] = []
    var mutex: MutexHooks?
    var parallelization: ParallelizationHooks?

    init() {}

    /// A duplicate context starts with everything its source had.
    func copy() -> PluginRegistry {
        let r = PluginRegistry()
        r.interpolators = interpolators
        r.parametricCurves = parametricCurves
        r.formatterFactories = formatterFactories
        r.tagTypes = tagTypes
        r.mpeTypes = mpeTypes
        r.tags = tags
        r.intents = intents.map { PluginIntent(intent: $0.intent, link: $0.link, description: PluginRegistry.copyDescription($0.description)) }
        r.optimizations = optimizations
        r.transforms = transforms
        r.mutex = mutex
        r.parallelization = parallelization
        return r
    }

    /// Back to the built-ins for every kind.
    func reset() {
        interpolators = nil
        parametricCurves = []
        formatterFactories = []
        tagTypes = []
        mpeTypes = []
        tags = [:]
        intents = []
        optimizations = []
        transforms = []
        mutex = nil
        parallelization = nil
    }

    /// The registry of a context — the global one for the null context
    /// and for any pointer that is not a context we made.
    static func resolve(_ id: cmsContext?) -> PluginRegistry {
        guard let box = swift_c_resolve_context(id)?.pointee.swift_ctx else { return .global }
        return Unmanaged<ContextBox>.fromOpaque(box).takeUnretainedValue().plugins
    }

    static func copyDescription(_ text: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
        p.initialize(repeating: 0, count: 256)
        var i = 0
        while i < 255 && text[i] != 0 {
            p[i] = text[i]
            i += 1
        }
        return p
    }

    // -- lookups -------------------------------------------------------

    func parametricCurve(for type: cmsInt32Number) -> (collection: ParametricCurveCollection, index: Int)? {
        for c in parametricCurves {
            if let i = c.index(of: type) { return (c, i) }
        }
        return nil
    }

    func tagType(for signature: cmsTagTypeSignature) -> TagTypeHandler? {
        guard let handler = tagTypes.first(where: { $0.Signature == signature }) else { return nil }
        return TagTypeHandler(wrapping: handler)
    }

    func mpeType(for signature: cmsTagTypeSignature) -> TagTypeHandler? {
        guard let handler = mpeTypes.first(where: { $0.Signature == signature }) else { return nil }
        return TagTypeHandler(wrapping: handler)
    }

    func intent(_ code: cmsUInt32Number) -> PluginIntent? {
        intents.first { $0.intent == code }
    }
}

extension TagTypeHandler {
    /// A plugin's handler as one of ours: each operation calls the
    /// plugin's function with a copy of its struct carrying the calling
    /// context and profile version, which is what the plugin reads
    /// `self->ContextID` and `self->ICCVersion` from.
    init(wrapping handler: cmsTagTypeHandler) {
        // The struct is plain data — signature, function pointers, and two
        // fields overwritten per call — so a closure may carry a copy.
        let handler = SendableBox(handler)
        self.init(
            signature: handler.value.Signature,
            read: { context, io, items, sizeOfTag, version in
                guard let read = handler.value.ReadPtr else { return nil }
                var local = handler.value
                local.ContextID = context
                local.ICCVersion = version
                return read(&local, io, &items, sizeOfTag)
            },
            write: { context, io, object, items, version in
                guard let write = handler.value.WritePtr else { return false }
                var local = handler.value
                local.ContextID = context
                local.ICCVersion = version
                return write(&local, io, object, items) != 0
            },
            duplicate: { context, object, count in
                guard let dup = handler.value.DupPtr else { return nil }
                var local = handler.value
                local.ContextID = context
                return dup(&local, object, count)
            },
            free: { context, object in
                guard let free = handler.value.FreePtr else { return }
                var local = handler.value
                local.ContextID = context
                free(&local, object)
            }
        )
    }
}

extension TagDescriptor {
    /// A plugin's descriptor as one of ours.
    init(_ d: cmsTagDescriptor) {
        var types: [cmsTagTypeSignature] = []
        let n = min(Int(d.nSupportedTypes), Int(MAX_TYPES_IN_LCMS_PLUGIN))
        withUnsafeBytes(of: d.SupportedTypes) { raw in
            raw.withMemoryRebound(to: cmsTagTypeSignature.self) { list in
                for i in 0..<n { types.append(list[i]) }
            }
        }
        let decideFn = d.DecideType
        var decide: (@Sendable (cmsFloat64Number, UnsafeRawPointer) -> cmsTagTypeSignature)? = nil
        if let fn = decideFn {
            decide = { version, data in fn(version, data) }
        }
        self.init(elementCount: d.ElemCount, supportedTypes: types, decide: decide)
    }
}

/// A plain-data C struct made capturable by a Sendable closure.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
