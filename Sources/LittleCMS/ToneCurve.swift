import CLCMS2
import LCMS2ABI
import LittleCMSCore

/// A one-dimensional response curve: a gamma exponent, a sampled table,
/// or one of the ICC parametric families.
public final class ToneCurve {
    let context: CaptureContext
    let handle: UnsafeMutablePointer<cmsToneCurve>

    init(context: CaptureContext, handle: UnsafeMutablePointer<cmsToneCurve>) {
        self.context = context
        self.handle = handle
    }

    deinit {
        cmsFreeToneCurve(handle)
    }

    private convenience init(
        _ context: CaptureContext,
        _ handle: UnsafeMutablePointer<cmsToneCurve>?,
        or fallback: String
    ) throws {
        guard let handle else { throw context.take(or: fallback) }
        self.init(context: context, handle: handle)
    }

    /// A pure power curve.
    public convenience init(gamma: Double) throws {
        let context = CaptureContext()
        try self.init(context, cmsBuildGamma(context.raw, gamma), or: "couldn't build gamma curve")
    }

    /// A curve sampled at equally spaced 16-bit points.
    public convenience init(table: [UInt16]) throws {
        let context = CaptureContext()
        let handle = table.withUnsafeBufferPointer {
            cmsBuildTabulatedToneCurve16(context.raw, cmsUInt32Number($0.count), $0.baseAddress)
        }
        try self.init(context, handle, or: "couldn't build tabulated curve")
    }

    /// A curve sampled at equally spaced floating-point values in 0...1.
    public convenience init(samples: [Float]) throws {
        let context = CaptureContext()
        let handle = samples.withUnsafeBufferPointer {
            cmsBuildTabulatedToneCurveFloat(context.raw, cmsUInt32Number($0.count), $0.baseAddress)
        }
        try self.init(context, handle, or: "couldn't build sampled curve")
    }

    /// One of the ICC parametric families; `type` and the parameter
    /// list are as `cmsBuildParametricToneCurve` defines them, negative
    /// types being the inverses.
    public convenience init(parametricType type: Int32, parameters: [Double]) throws {
        let context = CaptureContext()
        // The evaluator reads up to ten parameters whatever the type
        // uses, so the storage must hold ten.
        var params = parameters
        if params.count < 10 { params.append(contentsOf: repeatElement(0, count: 10 - params.count)) }
        let handle = params.withUnsafeBufferPointer {
            cmsBuildParametricToneCurve(context.raw, type, $0.baseAddress)
        }
        try self.init(context, handle, or: "couldn't build parametric curve")
    }

    /// The functional inverse, sampled at `sampleCount` points.
    public func reversed(sampleCount: Int = 4096) throws -> ToneCurve {
        // The new curve is allocated on this curve's context, so it
        // shares the capture box — which also keeps that context alive
        // for as long as either curve needs freeing against it.
        guard let handle = cmsReverseToneCurveEx(cmsUInt32Number(sampleCount), handle) else {
            throw context.take(or: "couldn't reverse curve")
        }
        return ToneCurve(context: context, handle: handle)
    }

    public func evaluate(_ value: Float) -> Float {
        cmsEvalToneCurveFloat(handle, value)
    }

    public func evaluate(_ value: UInt16) -> UInt16 {
        cmsEvalToneCurve16(handle, value)
    }

    public var isLinear: Bool { cmsIsToneCurveLinear(handle) != 0 }
    public var isMonotonic: Bool { cmsIsToneCurveMonotonic(handle) != 0 }
    public var isDescending: Bool { cmsIsToneCurveDescending(handle) != 0 }

    /// The exponent of the closest pure power curve, or nil when the
    /// curve is not close to one within `precision`.
    public func estimatedGamma(precision: Double = 0.01) -> Double? {
        let gamma = cmsEstimateGamma(handle, precision)
        return gamma < 0 ? nil : gamma
    }
}
