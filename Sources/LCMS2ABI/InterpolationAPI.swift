import CLCMS2
import LittleCMSCore

// The interpolation parameters, and the function pointers a client
// invokes through them.
//
// cmsInterpParams is a published layout that plugins read in their hot
// loops, and the `Interpolation` member is a union of two function
// pointers a caller may call directly.  So the struct is C memory and the
// kernels are reachable as plain C functions — the engine holds the
// arithmetic, these are the addresses.

/// `MAX_INPUT_DIMENSIONS`, as a count rather than the macro's Int32.
private let maximumInputDimensions = Int(MAX_INPUT_DIMENSIONS)

/// The parameters' domain and stride tables, borrowed in place: the
/// grid holds pointers into the struct, which outlives the call.
@inline(__always)
private func grid(_ p: UnsafePointer<cmsInterpParams>) -> InterpolationGrid {
    let raw = UnsafeRawPointer(p)
    let domain = raw.advanced(by: MemoryLayout<cmsInterpParams>.offset(of: \.Domain)!)
        .assumingMemoryBound(to: UInt32.self)
    let opta = raw.advanced(by: MemoryLayout<cmsInterpParams>.offset(of: \.opta)!)
        .assumingMemoryBound(to: UInt32.self)
    return InterpolationGrid(
        domain: domain, opta: opta, inputs: Int(p.pointee.nInputs), outputs: Int(p.pointee.nOutputs)
    )
}

// The kernels as C function pointers.  One pair covers every shape,
// because the dispatch the reference does once at build time is cheap
// enough to do per call and keeps twenty-six entry points from existing.

func interpolate16(
    _ input: UnsafePointer<cmsUInt16Number>?,
    _ output: UnsafeMutablePointer<cmsUInt16Number>?,
    _ p: UnsafePointer<cmsInterpParams>?
) {
    guard let input, let output, let p,
          let table = p.pointee.Table?.assumingMemoryBound(to: cmsUInt16Number.self)
    else { return }

    let trilinear = (p.pointee.dwFlags & cmsUInt32Number(CMS_LERP_FLAGS_TRILINEAR)) != 0
    Interpolation.evaluate(input, output, table, grid(p), trilinear: trilinear)
}

func interpolateFloat(
    _ input: UnsafePointer<cmsFloat32Number>?,
    _ output: UnsafeMutablePointer<cmsFloat32Number>?,
    _ p: UnsafePointer<cmsInterpParams>?
) {
    guard let input, let output, let p,
          let table = p.pointee.Table?.assumingMemoryBound(to: cmsFloat32Number.self)
    else { return }

    let trilinear = (p.pointee.dwFlags & cmsUInt32Number(CMS_LERP_FLAGS_TRILINEAR)) != 0
    Interpolation.evaluate(input, output, table, grid(p), trilinear: trilinear)
}

/// Fills in the parameters for a grid whose inputs all have the same
/// number of nodes.  The extended form the reference also has is not
/// exported, so this is the only way in from C — but the CLUT stages
/// need it, so the work lives in `computeInterpParams` below and this is
/// the uniform case of it.
@c @implementation
public func _cmsComputeInterpParams(
    _ ContextID: cmsContext?,
    _ nSamples: cmsUInt32Number,
    _ InputChan: cmsUInt32Number,
    _ OutputChan: cmsUInt32Number,
    _ Table: UnsafeRawPointer?,
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsInterpParams>? {
    // The reference builds the full-width array and hands it on, so the
    // range check below happens after that — but it reads only the first
    // InputChan entries, which is what a too-wide request never reaches.
    var uniform = [cmsUInt32Number](repeating: nSamples, count: maximumInputDimensions)
    return computeInterpParams(ContextID, &uniform, InputChan, OutputChan, Table, dwFlags)
}

/// A grid may have a different node count per input.  Only the CLUT
/// stages build one of those, and nothing exported reaches it.
func computeInterpParams(
    _ ContextID: cmsContext?,
    _ nSamples: UnsafePointer<cmsUInt32Number>,
    _ InputChan: cmsUInt32Number,
    _ OutputChan: cmsUInt32Number,
    _ Table: UnsafeRawPointer?,
    _ dwFlags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsInterpParams>? {
    if Int(InputChan) > maximumInputDimensions {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Too many input channels (\(InputChan) channels, max=\(maximumInputDimensions))",
            to: ContextID
        )
        return nil
    }

    guard let raw = _cmsMallocZero(
        ContextID, cmsUInt32Number(MemoryLayout<cmsInterpParams>.size)
    ) else { return nil }
    let p = raw.assumingMemoryBound(to: cmsInterpParams.self)

    p.pointee.ContextID = ContextID
    p.pointee.dwFlags = dwFlags
    p.pointee.nInputs = InputChan
    p.pointee.nOutputs = OutputChan
    p.pointee.Table = Table

    let inputs = Int(InputChan)
    withUnsafeMutableBytes(of: &p.pointee.nSamples) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { values in
            for i in 0..<inputs { values[i] = nSamples[i] }
        }
    }
    withUnsafeMutableBytes(of: &p.pointee.Domain) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { values in
            for i in 0..<inputs { values[i] = nSamples[i] &- 1 }
        }
    }

    // opta[0] is the output channel count and each further entry
    // multiplies in the node count of one more input, counting from the
    // last — which is what makes a single index reach into the grid.
    withUnsafeMutableBytes(of: &p.pointee.opta) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self) { values in
            values[0] = OutputChan
            for i in 1..<max(inputs, 1) {
                values[i] = values[i - 1] &* nSamples[inputs - i]
            }
        }
    }

    guard installInterpolation(p, context: ContextID) else {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unsupported interpolation (\(InputChan)->\(OutputChan) channels)",
            to: ContextID
        )
        _cmsFree(ContextID, raw)
        return nil
    }

    return p
}

/// `_cmsSetInterpolationRoutine`: the kernel goes into the parameters —
/// a plugin's if the context has a factory that answers for this shape,
/// else the built-in one.  False when neither serves it.
func installInterpolation(_ p: UnsafeMutablePointer<cmsInterpParams>, context: cmsContext?) -> Bool {
    if let factory = PluginRegistry.resolve(context).interpolators {
        let plugin = factory(p.pointee.nInputs, p.pointee.nOutputs, p.pointee.dwFlags)
        // One member of the union is enough to check: both are pointers
        // in the same slot.
        if plugin.Lerp16 != nil {
            p.pointee.Interpolation = plugin
            return true
        }
    }

    guard Interpolation.isSupported(
        inputs: Int(p.pointee.nInputs), outputs: Int(p.pointee.nOutputs),
        trilinear: (p.pointee.dwFlags & cmsUInt32Number(CMS_LERP_FLAGS_TRILINEAR)) != 0
    ) else { return false }

    // The union holds either pointer; which one a caller reads is
    // decided by the flag it passed, and both occupy the same slot.
    if (p.pointee.dwFlags & cmsUInt32Number(CMS_LERP_FLAGS_FLOAT)) != 0 {
        p.pointee.Interpolation.LerpFloat = interpolateFloat
    } else {
        p.pointee.Interpolation.Lerp16 = interpolate16
    }
    return true
}

/// Whether the parameters carry the built-in 16-bit kernel, so a caller
/// on a hot path may take the direct route instead of the pointer.
@inline(__always)
func hasBuiltinLerp16(_ p: UnsafePointer<cmsInterpParams>) -> Bool {
    let builtin: @convention(c) (UnsafePointer<cmsUInt16Number>?, UnsafeMutablePointer<cmsUInt16Number>?, UnsafePointer<cmsInterpParams>?) -> Void = interpolate16
    return unsafeBitCast(p.pointee.Interpolation.Lerp16, to: UnsafeRawPointer?.self) == unsafeBitCast(builtin, to: UnsafeRawPointer?.self)
}

@inline(__always)
func hasBuiltinLerpFloat(_ p: UnsafePointer<cmsInterpParams>) -> Bool {
    let builtin: @convention(c) (UnsafePointer<cmsFloat32Number>?, UnsafeMutablePointer<cmsFloat32Number>?, UnsafePointer<cmsInterpParams>?) -> Void = interpolateFloat
    return unsafeBitCast(p.pointee.Interpolation.LerpFloat, to: UnsafeRawPointer?.self) == unsafeBitCast(builtin, to: UnsafeRawPointer?.self)
}

@c @implementation
public func _cmsFreeInterpParams(_ p: UnsafeMutablePointer<cmsInterpParams>?) {
    guard let p else { return }
    _cmsFree(p.pointee.ContextID, UnsafeMutableRawPointer(p))
}

/// How fine a grid to precalculate a transform onto.
///
/// A caller may name the number outright by packing it into bits 16-23
/// of the flags, and that wins over everything else.  Otherwise the
/// answer is a table indexed by channel count and by which of the two
/// precision flags is set — coarser for more channels, because the cost
/// is the count raised to that power.
@c @implementation
public func _cmsReasonableGridpointsByColorspace(
    _ Colorspace: cmsColorSpaceSignature,
    _ dwFlags: cmsUInt32Number
) -> cmsUInt32Number {
    // A grid size given explicitly in the flags.
    if dwFlags & 0x00FF_0000 != 0 {
        return (dwFlags >> 16) & 0xFF
    }

    let channels = cmsChannelsOf(Colorspace)

    if dwFlags & cmsUInt32Number(cmsFLAGS_HIGHRESPRECALC) != 0 {
        if channels > 4 { return 7 }        // hifi
        if channels == 4 { return 23 }      // CMYK
        return 49                           // RGB and the rest
    }

    if dwFlags & cmsUInt32Number(cmsFLAGS_LOWRESPRECALC) != 0 {
        if channels > 4 { return 6 }
        if channels == 1 { return 33 }      // monochrome gets *more*
        return 17
    }

    if channels > 4 { return 7 }
    if channels == 4 { return 17 }
    return 33
}
