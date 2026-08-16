// Embedded Swift ships a Synchronization module that vends atomics but no
// Mutex, so the condition has to name the feature rather than the module:
// `canImport` succeeds there and the type is still missing.
#if !hasFeature(Embedded) && canImport(Synchronization)
import Synchronization
#endif

// The context: a set of settings a caller can vary independently of every
// other caller, plus the global one that a null context ID means.
//
// The reference keeps these as "chunks", one per subsystem, in a pool
// allocated from the context's own arena, and duplicates them one by one.
// Here they are stored properties of a value, so duplicating a context is
// copying that value and the snapshot semantics fall out rather than being
// arranged: what `cmsDupContext` promises is that later changes to the
// original are not seen by the copy.

/// A settings context.  `Context.global` is what a null `cmsContext` means.
public final class Context: @unchecked Sendable {
    /// Everything a context carries that a caller can change.  Grows as
    /// subsystems arrive: the plugin registries land here.
    public struct Chunks: Sendable {
        /// The 16-bit values marking out-of-gamut pixels in a proofing
        /// transform.  Sixteen of them, one per channel.
        public var alarmCodes: [UInt16]
        /// How completely to adapt to the destination white point in the
        /// absolute colorimetric intent.
        public var adaptationState: Double

        public init() {
            alarmCodes = Context.defaultAlarmCodes
            adaptationState = Context.defaultAdaptationState
        }
    }

    /// `DEFAULT_ALARM_CODES_VALUE`: mid-grey in the first three channels.
    public static let defaultAlarmCodes: [UInt16] =
        [0x7F00, 0x7F00, 0x7F00] + [UInt16](repeating: 0, count: 13)

    /// `DEFAULT_OBSERVER_ADAPTATION_STATE`: fully adapted.
    public static let defaultAdaptationState = 1.0

    /// The number of channels an alarm-code array carries, `cmsMAXCHANNELS`.
    public static let maximumChannels = 16

    private let storage: LockedCell<Chunks>

    /// A context with the default settings, or a snapshot of another.
    public init(copying source: Context? = nil) {
        storage = LockedCell(source?.chunks ?? Chunks())
    }

    /// The context every null `cmsContext` resolves to.
    ///
    /// Process-global mutable state, exactly as in the reference — the
    /// difference being that the reference exports its storage and this
    /// does not, so the representation stays ours.
    public static let global = Context()

    /// Reads the settings.
    public var chunks: Chunks {
        storage.withLock { $0 }
    }

    /// Changes the settings, returning whatever the change produced.
    @discardableResult
    public func update<Result: Sendable>(_ body: (inout Chunks) -> Result) -> Result {
        storage.withLock(body)
    }
}

/// One mutable value behind one lock.
///
/// The engine's whole concurrency story: the objects the C API calls
/// single-threaded stay unsynchronized, and the few that are genuinely
/// shared — a context, a profile's tag directory, a transform's cache —
/// each hold one of these.
final class LockedCell<Value: Sendable>: @unchecked Sendable {
    // The condition names the feature, not the module: Embedded Swift
    // ships a Synchronization that vends atomics without a Mutex, so
    // `canImport` alone succeeds there and the type is still missing.
    #if !hasFeature(Embedded) && canImport(Synchronization)
    // A class, because a mutex cannot be copied and so cannot be a
    // stored property of a struct that can be.
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { value in body(&value) }
    }
    #else
    // Freestanding targets without the synchronization library are
    // single-threaded by construction: there is no scheduler to preempt
    // this and no second core to race it.
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        body(&value)
    }
    #endif
}
