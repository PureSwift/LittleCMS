import CLCMS2
import LittleCMS

// What happens to a pipeline between linking and use.
//
// The optimizer rewrites a pipeline into a faster equivalent — a
// resampled CLUT, a joined matrix-shaper, an 8-bit prelinearised table —
// and those rewrites change the answers slightly, which is why
// cmsFLAGS_NOOPTIMIZE exists.  This file holds the part that runs
// regardless of that flag — removing identity stages and cancelling
// facing pairs of conversions, which change no answer — and the shell
// that dispatches to the schemes in OptimizationSchemesAPI.swift.

@inline(__always)
private func pipeline(_ p: UnsafeMutablePointer<cmsPipeline>?) -> PipelineBox? {
    guard let p else { return nil }
    return Unmanaged<PipelineBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

@inline(__always)
private func stage(_ p: UnsafeMutablePointer<cmsStage>?) -> StageBox? {
    guard let p else { return nil }
    return Unmanaged<StageBox>.fromOpaque(UnsafeRawPointer(p)).takeUnretainedValue()
}

/// Installs a 16-bit evaluator and its private data on a pipeline.  The
/// evaluator replaces walking the stages; the hooks say how the data is
/// released and copied with the pipeline, and either may be nil.
@c @implementation
public func _cmsPipelineSetOptimizationParameters(
    _ Lut: UnsafeMutablePointer<cmsPipeline>?,
    _ Eval16: _cmsPipelineEval16Fn?,
    _ PrivateData: UnsafeMutableRawPointer?,
    _ FreePrivateDataFn: _cmsFreeUserDataFn?,
    _ DupPrivateDataFn: _cmsDupUserDataFn?
) {
    guard let box = pipeline(Lut) else { return }
    box.eval16 = Eval16
    box.optimizationData = PrivateData
    box.freeOptimizationData = FreePrivateDataFn
    box.dupOptimizationData = DupPrivateDataFn
}

// -- the rewrites that change nothing -----------------------------------------

/// Removes every stage implementing the given operation.
private func remove1Op(_ box: PipelineBox, _ op: cmsStageSignature) -> Bool {
    var any = false
    var i = 0
    while i < box.stages.count {
        if stage(box.stages[i])?.implements == op {
            cmsStageFree(box.stages.remove(at: i))
            any = true
        } else {
            i += 1
        }
    }
    return any
}

/// Removes every adjacent pair where the first implements `op1` and the
/// second `op2` — a conversion followed by its inverse.
private func remove2Op(_ box: PipelineBox, _ op1: cmsStageSignature, _ op2: cmsStageSignature) -> Bool {
    var any = false
    var i = 0
    while i + 1 < box.stages.count {
        if stage(box.stages[i])?.implements == op1 && stage(box.stages[i + 1])?.implements == op2 {
            cmsStageFree(box.stages.remove(at: i + 1))
            cmsStageFree(box.stages.remove(at: i))
            any = true
        } else {
            i += 1
        }
    }
    return any
}

/// The reference's `CloseEnoughFloat`: within a hundred-thousandth.
@inline(__always)
private func closeEnoughFloat(_ a: cmsFloat64Number, _ b: cmsFloat64Number) -> Bool {
    (b - a).magnitude < cmsFloat64Number(Float(0.00001))
}

private func isFloatMatrixIdentity(_ m: cmsMAT3) -> Bool {
    var identity = cmsMAT3()
    _cmsMAT3identity(&identity)
    return withUnsafePointer(to: m) { a in
        withUnsafePointer(to: identity) { b in
            a.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { x in
                b.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) { y in
                    (0..<9).allSatisfy { closeEnoughFloat(x[$0], y[$0]) }
                }
            }
        }
    }
}

/// Two adjacent 3x3 matrices without offsets become their product, or
/// nothing at all when the product is identity.  Any pair that does not
/// fit that shape stops the pass — the reference returns at the first
/// such pair rather than stepping over it.
private func multiplyMatrix(_ box: PipelineBox) -> Bool {
    var any = false
    var i = 0
    while i + 1 < box.stages.count {
        let first = box.stages[i]
        let second = box.stages[i + 1]
        guard stage(first)?.implements == cmsSigMatrixElemType,
              stage(second)?.implements == cmsSigMatrixElemType
        else {
            i += 1
            continue
        }
        guard let m1 = cmsStageData(first)?.assumingMemoryBound(to: _cmsStageMatrixData.self),
              let m2 = cmsStageData(second)?.assumingMemoryBound(to: _cmsStageMatrixData.self)
        else { return false }

        if m1.pointee.Offset != nil || m2.pointee.Offset != nil
            || cmsStageInputChannels(first) != 3 || cmsStageOutputChannels(first) != 3
            || cmsStageInputChannels(second) != 3 || cmsStageOutputChannels(second) != 3
        {
            return false
        }

        var result = cmsMAT3()
        m2.pointee.Double.withMemoryRebound(to: cmsMAT3.self, capacity: 1) { a in
            m1.pointee.Double.withMemoryRebound(to: cmsMAT3.self, capacity: 1) { b in
                _cmsMAT3per(&result, a, b)
            }
        }

        cmsStageFree(box.stages.remove(at: i + 1))
        cmsStageFree(box.stages.remove(at: i))

        if !isFloatMatrixIdentity(result) {
            let product = withUnsafePointer(to: &result) {
                $0.withMemoryRebound(to: cmsFloat64Number.self, capacity: 9) {
                    cmsStageAllocMatrix(box.context, 3, 3, $0, nil)
                }
            }
            guard let product else { return false }
            box.stages.insert(product, at: i)
        }
        any = true
    }
    return any
}

/// `PreOptimize`: repeats the cancellations until a pass changes
/// nothing.  Runs whether or not optimization is wanted, because it
/// changes no answer.
func preOptimize(_ lut: UnsafeMutablePointer<cmsPipeline>?) -> Bool {
    guard let box = pipeline(lut) else { return false }
    var anyOpt = false
    var opt: Bool
    repeat {
        opt = false
        opt = remove1Op(box, cmsSigIdentityElemType) || opt
        opt = remove2Op(box, cmsSigXYZ2LabElemType, cmsSigLab2XYZElemType) || opt
        opt = remove2Op(box, cmsSigLab2XYZElemType, cmsSigXYZ2LabElemType) || opt
        opt = remove2Op(box, cmsSigLabV4toV2, cmsSigLabV2toV4) || opt
        opt = remove2Op(box, cmsSigLabV2toV4, cmsSigLabV4toV2) || opt
        opt = remove2Op(box, cmsSigLab2FloatPCS, cmsSigFloatPCS2Lab) || opt
        opt = remove2Op(box, cmsSigXYZ2FloatPCS, cmsSigFloatPCS2XYZ) || opt
        opt = multiplyMatrix(box) || opt
        if opt { anyOpt = true }
    } while opt

    // The chain's ends may have moved; the pipeline's counts follow
    // them, and the links are the array's.
    box.relink()
    if !box.stages.isEmpty { box.bless() }
    return anyOpt
}

/// The optimizer's entry point.  Cancels what can be cancelled, then —
/// unless told not to — would try the plugin and built-in schemes; with
/// none of the latter present yet, a pipeline that survives the
/// cancellations is evaluated as it stands.
@c @implementation
public func _cmsOptimizePipeline(
    _ ContextID: cmsContext?,
    _ PtrLut: UnsafeMutablePointer<UnsafeMutablePointer<cmsPipeline>?>?,
    _ Intent: cmsUInt32Number,
    _ InputFormat: UnsafeMutablePointer<cmsUInt32Number>?,
    _ OutputFormat: UnsafeMutablePointer<cmsUInt32Number>?,
    _ dwFlags: UnsafeMutablePointer<cmsUInt32Number>?
) -> cmsBool {
    guard let PtrLut, let lut = PtrLut.pointee, let box = pipeline(lut), let dwFlags
    else { return 0 }

    // A CLUT was asked for outright.
    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_FORCE_CLUT) != 0 {
        _ = preOptimize(lut)
        guard let InputFormat, let OutputFormat else { return 0 }
        return optimizeByResampling(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) ? 1 : 0
    }

    if box.stages.isEmpty {
        _cmsPipelineSetOptimizationParameters(lut, fastIdentity16, UnsafeMutableRawPointer(lut), nil, nil)
        return 1
    }

    // A named colour pipeline is left alone.
    for s in box.stages where cmsStageType(s) == cmsSigNamedColorElemType {
        return 0
    }

    let anySuccess = preOptimize(lut)

    if box.stages.isEmpty {
        _cmsPipelineSetOptimizationParameters(lut, fastIdentity16, UnsafeMutableRawPointer(lut), nil, nil)
        return 1
    }

    if dwFlags.pointee & cmsUInt32Number(cmsFLAGS_NOOPTIMIZE) != 0 {
        return 0
    }

    // A plugin's schemes first, newest first; then the built-in ones,
    // in order of preference.  The first that applies wins.
    guard let InputFormat, let OutputFormat else { return anySuccess ? 1 : 0 }
    for optimize in PluginRegistry.resolve(ContextID).optimizations {
        if optimize(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) != 0 { return 1 }
    }
    if optimizeByJoiningCurves(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) { return 1 }
    if optimizeMatrixShaper(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) { return 1 }
    if optimizeByComputingLinearization(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) { return 1 }
    if optimizeByResampling(PtrLut, Intent, InputFormat, OutputFormat, dwFlags) { return 1 }

    // Only the simple cancellations succeeded.
    return anySuccess ? 1 : 0
}
