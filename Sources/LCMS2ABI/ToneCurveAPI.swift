import CLCMS2
import LittleCMSCore

// Tone curves.
//
// Unlike every other object so far, a curve is not an engine object
// behind an opaque handle: its layout is fixed by the reference, because
// the reference's own testbed reaches through it — reading the
// interpolation parameters, indexing Table16, writing to it, and looking
// at a segment's type — on curves this library allocated.  So the storage
// is C, laid out as cmsstruct_abi.h says, allocated through the library's
// allocator, and the engine supplies only the arithmetic: the parametric
// evaluator and the one-dimensional interpolation.
//
// Two of the accessors hand out interior pointers with the curve's
// lifetime, which is why the storage cannot move once built.

/// Where the reference puts a segment's domain when it means "everywhere".
/// A float constant in the reference, so its double value is this.
private let minusInfinity = Double(Float(-1e22))
private let plusInfinity = Double(Float(1e22))

/// The evaluator installed in every parametric segment.  A plain C
/// function pointer, as the field's type requires, forwarding to the
/// engine.
private func evaluateParametric(
    _ type: cmsInt32Number,
    _ params: UnsafePointer<cmsFloat64Number>?,
    _ r: cmsFloat64Number
) -> cmsFloat64Number {
    guard let params else { return 0 }
    return ParametricCurve.evaluate(type: type, params: params, at: r)
}

/// `GetParametricCurveByType`: who evaluates a parametric type and how
/// many parameters it takes — a plugin's collection first, then the
/// built-in types.  Nil for a type nobody knows.
func parametricEvaluator(
    for type: cmsInt32Number, context: cmsContext?
) -> (evaluator: cmsParametricCurveEvaluator, parameterCount: Int)? {
    if let found = PluginRegistry.resolve(context).parametricCurve(for: type) {
        return (found.collection.evaluator, Int(found.collection.types[found.index].parameterCount))
    }
    if let count = ParametricCurve.parameterCount(forType: type) {
        return (evaluateParametric, count)
    }
    return nil
}

@inline(__always)
private func allocate<T>(_ context: cmsContext?, _ count: Int, _: T.Type) -> UnsafeMutablePointer<T>? {
    guard count > 0 else { return nil }
    guard let raw = _cmsCalloc(context, cmsUInt32Number(count), cmsUInt32Number(MemoryLayout<T>.stride))
    else { return nil }
    return raw.assumingMemoryBound(to: T.self)
}

/// Builds the interpolation parameters a curve's tables are read through.
///
/// The exported `_cmsComputeInterpParams` is still a stub — it has to
/// serve every dimensionality, and the rest arrive with the pipelines —
/// so curves construct the one-dimensional case they need directly.  The
/// struct is the published layout either way, since the testbed reads it.
private func makeInterpolationParameters(
    _ context: cmsContext?,
    samples: cmsUInt32Number,
    table: UnsafeRawPointer?,
    flags: cmsUInt32Number
) -> UnsafeMutablePointer<cmsInterpParams>? {
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsInterpParams>.size))
    else { return nil }
    let p = raw.assumingMemoryBound(to: cmsInterpParams.self)

    p.pointee.ContextID = context
    p.pointee.dwFlags = flags
    p.pointee.nInputs = 1
    p.pointee.nOutputs = 1
    p.pointee.Table = table

    withUnsafeMutablePointer(to: &p.pointee.nSamples) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self, capacity: 1) { $0[0] = samples }
    }
    withUnsafeMutablePointer(to: &p.pointee.Domain) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self, capacity: 1) {
            $0[0] = samples > 0 ? samples - 1 : 0
        }
    }
    // opta[0] is the output channel count, which for a curve is one.
    withUnsafeMutablePointer(to: &p.pointee.opta) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self, capacity: 1) { $0[0] = 1 }
    }

    // The kernel a caller — the optimizer's prelinearisation, a plugin —
    // may invoke through the parameters directly; and a plugin's, when
    // the context has one that answers for one channel.
    guard installInterpolation(p, context: context) else {
        _cmsFree(context, raw)
        return nil
    }

    return p
}

@inline(__always)
private func domain(of p: UnsafePointer<cmsInterpParams>) -> cmsUInt32Number {
    withUnsafePointer(to: p.pointee.Domain) { field in
        field.withMemoryRebound(to: cmsUInt32Number.self, capacity: 1) { $0[0] }
    }
}

/// `EvalSegmentedFn`: finds the segment whose domain contains `r` and
/// evaluates it, walking the segments backwards as the reference does.
private func evaluateSegmented(_ curve: UnsafePointer<cmsToneCurve>, _ r: cmsFloat64Number) -> cmsFloat64Number {
    let count = Int(curve.pointee.nSegments)
    guard count > 0, let segments = curve.pointee.Segments else { return minusInfinity }

    var index = count - 1
    while index >= 0 {
        let segment = segments[index]
        if r > Double(segment.x0) && r <= Double(segment.x1) {
            var out: cmsFloat64Number

            if segment.Type == 0 {
                // A sampled segment: rescale into the segment's own
                // domain and interpolate its points.
                let span = Double(segment.x1) - Double(segment.x0)
                let position = Float((r - Double(segment.x0)) / span)

                guard let interp = curve.pointee.SegInterp?[index],
                      let points = segment.SampledPoints
                else { return minusInfinity }

                // The reference points the parameters at the segment's
                // samples here rather than at build time, so the same
                // shape is kept.
                interp.pointee.Table = UnsafeRawPointer(points)
                if hasBuiltinLerpFloat(interp) {
                    out = Double(Interpolation1D.lookup(position, table: points, domain: domain(of: interp)))
                } else {
                    // A plugin's kernel, through the pointer as the
                    // reference always goes.
                    var input = position
                    var result: cmsFloat32Number = 0
                    interp.pointee.Interpolation.LerpFloat?(&input, &result, interp)
                    out = Double(result)
                }
            } else {
                guard let evaluator = curve.pointee.Evals?[index] else { return minusInfinity }
                out = withUnsafePointer(to: segment.Params) { params in
                    params.withMemoryRebound(to: cmsFloat64Number.self, capacity: 10) {
                        evaluator(segment.Type, $0, r)
                    }
                }
            }

            if out.isInfinite { return out > 0 ? plusInfinity : minusInfinity }
            return out
        }
        index -= 1
    }

    return minusInfinity
}

/// `AllocateToneCurveStruct`.
private func allocateCurve(
    _ context: cmsContext?,
    entries: cmsUInt32Number,
    segmentCount: cmsUInt32Number,
    segments: UnsafePointer<cmsCurveSegment>?,
    values: UnsafePointer<cmsUInt16Number>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    // Huge tables are allowed and then refused by the operations that
    // cannot hold them; this is the limit the reference sets.
    if entries > 65530 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Couldn't create tone curve of more than 65530 entries",
            to: context
        )
        return nil
    }
    if entries == 0 && segmentCount == 0 {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Couldn't create tone curve with zero segments and no table",
            to: context
        )
        return nil
    }

    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsToneCurve>.size)) else {
        return nil
    }
    let curve = raw.assumingMemoryBound(to: cmsToneCurve.self)

    func fail() -> UnsafeMutablePointer<cmsToneCurve>? {
        freeCurve(curve)
        return nil
    }

    if segmentCount > 0 {
        guard let s = allocate(context, Int(segmentCount), cmsCurveSegment.self) else { return fail() }
        curve.pointee.Segments = s
        guard let e = allocate(context, Int(segmentCount), cmsParametricCurveEvaluator?.self) else {
            return fail()
        }
        curve.pointee.Evals = e
    }
    curve.pointee.nSegments = segmentCount

    if entries > 0 {
        guard let t = allocate(context, Int(entries), cmsUInt16Number.self) else { return fail() }
        curve.pointee.Table16 = t
    }
    curve.pointee.nEntries = entries

    if let values, entries > 0 {
        curve.pointee.Table16!.update(from: values, count: Int(entries))
    }

    if let segments, segmentCount > 0 {
        guard let interp = allocate(
            context, Int(segmentCount), UnsafeMutablePointer<cmsInterpParams>?.self
        ) else { return fail() }
        curve.pointee.SegInterp = interp

        for i in 0..<Int(segmentCount) {
            // Type zero marks a sampled segment, which needs its own
            // interpolation parameters.
            if segments[i].Type == 0 {
                curve.pointee.SegInterp![i] = makeInterpolationParameters(
                    context,
                    samples: segments[i].nGridPoints,
                    table: nil,
                    flags: cmsUInt32Number(CMS_LERP_FLAGS_FLOAT)
                )
            }

            curve.pointee.Segments![i] = segments[i]

            if segments[i].Type == 0, let points = segments[i].SampledPoints {
                let bytes = cmsUInt32Number(MemoryLayout<cmsFloat32Number>.stride) * segments[i].nGridPoints
                guard let copy = _cmsDupMem(context, points, bytes) else { return fail() }
                curve.pointee.Segments![i].SampledPoints =
                    copy.assumingMemoryBound(to: cmsFloat32Number.self)
            } else {
                curve.pointee.Segments![i].SampledPoints = nil
            }

            if let found = parametricEvaluator(for: segments[i].Type, context: context) {
                curve.pointee.Evals![i] = found.evaluator
            }
        }
    }

    guard let params = makeInterpolationParameters(
        context,
        samples: curve.pointee.nEntries,
        table: UnsafeRawPointer(curve.pointee.Table16),
        flags: cmsUInt32Number(CMS_LERP_FLAGS_16BITS)
    ) else { return fail() }
    curve.pointee.InterpParams = params

    return curve
}

/// The body of `cmsFreeToneCurve`, reachable from the partly-built state
/// the allocator unwinds through.
private func freeCurve(_ curve: UnsafeMutablePointer<cmsToneCurve>) {
    // The context lives on the interpolation parameters in the reference,
    // so a curve that failed before those exist frees against the global
    // one — which is where its memory came from anyway.
    let context = curve.pointee.InterpParams?.pointee.ContextID

    if let params = curve.pointee.InterpParams {
        _cmsFree(context, UnsafeMutableRawPointer(params))
    }
    if let table = curve.pointee.Table16 {
        _cmsFree(context, UnsafeMutableRawPointer(table))
    }

    if let segments = curve.pointee.Segments {
        for i in 0..<Int(curve.pointee.nSegments) {
            if let points = segments[i].SampledPoints {
                _cmsFree(context, UnsafeMutableRawPointer(points))
            }
            if let interp = curve.pointee.SegInterp?[i] {
                _cmsFree(context, UnsafeMutableRawPointer(interp))
            }
        }
        _cmsFree(context, UnsafeMutableRawPointer(segments))
        if let interp = curve.pointee.SegInterp {
            _cmsFree(context, UnsafeMutableRawPointer(interp))
        }
    }

    if let evals = curve.pointee.Evals {
        _cmsFree(context, UnsafeMutableRawPointer(evals))
    }

    _cmsFree(context, UnsafeMutableRawPointer(curve))
}

// -- building ----------------------------------------------------------

@c @implementation
public func cmsBuildSegmentedToneCurve(
    _ ContextID: cmsContext?,
    _ nSegments: cmsUInt32Number,
    _ Segments: UnsafePointer<cmsCurveSegment>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let Segments else { return nil }

    // An identity curve needs only two points; everything else gets the
    // reference's 4096.
    var gridPoints: cmsUInt32Number = 4096
    if nSegments == 1 && Segments[0].Type == 1 {
        let gamma = withUnsafePointer(to: Segments[0].Params) { params in
            params.withMemoryRebound(to: cmsFloat64Number.self, capacity: 10) { $0[0] }
        }
        if abs(gamma - 1.0) < 0.001 { gridPoints = 2 }
    }

    guard let curve = allocateCurve(
        ContextID, entries: gridPoints, segmentCount: nSegments, segments: Segments, values: nil
    ) else { return nil }

    // The 16-bit table is an approximation of the floating point curve,
    // kept for the 8- and 16-bit transform paths.
    for i in 0..<Int(gridPoints) {
        let r = Double(i) / Double(gridPoints - 1)
        let value = evaluateSegmented(curve, r)
        curve.pointee.Table16![i] = quickSaturateWord(value * 65535.0)
    }

    return curve
}

@c @implementation
public func cmsBuildParametricToneCurve(
    _ ContextID: cmsContext?,
    _ Type: cmsInt32Number,
    _ Params: UnsafePointer<cmsFloat64Number>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let Params else { return nil }
    guard let count = parametricEvaluator(for: Type, context: ContextID)?.parameterCount else {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Invalid parametric curve type \(Type)",
            to: ContextID
        )
        return nil
    }

    var segment = cmsCurveSegment()
    segment.x0 = cmsFloat32Number(minusInfinity)
    segment.x1 = cmsFloat32Number(plusInfinity)
    segment.Type = Type
    withUnsafeMutablePointer(to: &segment.Params) { field in
        field.withMemoryRebound(to: cmsFloat64Number.self, capacity: 10) { p in
            for i in 0..<count { p[i] = Params[i] }
        }
    }

    return cmsBuildSegmentedToneCurve(ContextID, 1, &segment)
}

@c @implementation
public func cmsBuildGamma(
    _ ContextID: cmsContext?,
    _ Gamma: cmsFloat64Number
) -> UnsafeMutablePointer<cmsToneCurve>? {
    var gamma = Gamma
    return cmsBuildParametricToneCurve(ContextID, 1, &gamma)
}

@c @implementation
public func cmsBuildTabulatedToneCurve16(
    _ ContextID: cmsContext?,
    _ nEntries: cmsUInt32Number,
    _ values: UnsafePointer<cmsUInt16Number>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    allocateCurve(ContextID, entries: nEntries, segmentCount: 0, segments: nil, values: values)
}

@c @implementation
public func cmsBuildTabulatedToneCurveFloat(
    _ ContextID: cmsContext?,
    _ nEntries: cmsUInt32Number,
    _ values: UnsafePointer<cmsFloat32Number>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard nEntries > 0, let values else { return nil }

    // Three segments: constant below zero, the samples across the unit
    // interval, constant above one.  A segmented curve has to begin and
    // end with a function segment.
    var segments = [cmsCurveSegment](repeating: cmsCurveSegment(), count: 3)

    func setParams(_ index: Int, _ values: [cmsFloat64Number]) {
        withUnsafeMutablePointer(to: &segments[index].Params) { field in
            field.withMemoryRebound(to: cmsFloat64Number.self, capacity: 10) { p in
                for (i, v) in values.enumerated() { p[i] = v }
            }
        }
    }

    segments[0].x0 = cmsFloat32Number(minusInfinity)
    segments[0].x1 = 0
    segments[0].Type = 6
    setParams(0, [1, 0, 0, Double(values[0]), 0])

    segments[1].x0 = 0
    segments[1].x1 = 1.0
    segments[1].Type = 0
    segments[1].nGridPoints = nEntries
    segments[1].SampledPoints = UnsafeMutablePointer(mutating: values)

    segments[2].x0 = 1.0
    segments[2].x1 = cmsFloat32Number(plusInfinity)
    segments[2].Type = 6
    setParams(2, [1, 0, 0, Double(values[Int(nEntries) - 1]), 0])

    return cmsBuildSegmentedToneCurve(ContextID, 3, &segments)
}

@c @implementation
public func cmsDupToneCurve(
    _ Src: UnsafePointer<cmsToneCurve>?
) -> UnsafeMutablePointer<cmsToneCurve>? {
    guard let Src else { return nil }
    return allocateCurve(
        Src.pointee.InterpParams?.pointee.ContextID,
        entries: Src.pointee.nEntries,
        segmentCount: Src.pointee.nSegments,
        segments: Src.pointee.Segments,
        values: Src.pointee.Table16
    )
}

@c @implementation
public func cmsFreeToneCurve(_ Curve: UnsafeMutablePointer<cmsToneCurve>?) {
    guard let Curve else { return }
    freeCurve(Curve)
}

@c @implementation
public func cmsFreeToneCurveTriple(_ Curve: UnsafeMutablePointer<UnsafeMutablePointer<cmsToneCurve>?>?) {
    guard let Curve else { return }
    for i in 0..<3 {
        if let one = Curve[i] { freeCurve(one) }
        Curve[i] = nil
    }
}

// -- evaluating --------------------------------------------------------

@c @implementation
public func cmsEvalToneCurve16(
    _ Curve: UnsafePointer<cmsToneCurve>?,
    _ v: cmsUInt16Number
) -> cmsUInt16Number {
    guard let Curve, let params = Curve.pointee.InterpParams,
          let table = params.pointee.Table?.assumingMemoryBound(to: cmsUInt16Number.self)
    else { return 0 }
    if hasBuiltinLerp16(params) {
        return Interpolation1D.lookup(v, table: table, domain: domain(of: params))
    }
    var input = v
    var out: cmsUInt16Number = 0
    params.pointee.Interpolation.Lerp16?(&input, &out, params)
    return out
}

@c @implementation
public func cmsEvalToneCurveFloat(
    _ Curve: UnsafePointer<cmsToneCurve>?,
    _ v: cmsFloat32Number
) -> cmsFloat32Number {
    guard let Curve else { return 0 }

    // A curve with no segments is the 16-bit table and nothing else, so
    // the answer carries that table's precision.
    if Curve.pointee.nSegments == 0 {
        let input = quickSaturateWord(Double(v) * 65535.0)
        return cmsFloat32Number(cmsEvalToneCurve16(Curve, input)) / 65535.0
    }

    return cmsFloat32Number(evaluateSegmented(Curve, Double(v)))
}

// -- inspecting --------------------------------------------------------

@c @implementation
public func cmsGetToneCurveEstimatedTableEntries(_ t: UnsafePointer<cmsToneCurve>?) -> cmsUInt32Number {
    t?.pointee.nEntries ?? 0
}

@c @implementation
public func cmsGetToneCurveEstimatedTable(
    _ t: UnsafePointer<cmsToneCurve>?
) -> UnsafePointer<cmsUInt16Number>? {
    // An interior pointer with the curve's lifetime, which is why the
    // table is allocated once and never moved.
    guard let table = t?.pointee.Table16 else { return nil }
    return UnsafePointer(table)
}

@c @implementation
public func cmsGetToneCurveSegment(
    _ n: cmsInt32Number,
    _ t: UnsafePointer<cmsToneCurve>?
) -> UnsafePointer<cmsCurveSegment>? {
    guard let t, n >= 0, cmsUInt32Number(n) < t.pointee.nSegments,
          let segments = t.pointee.Segments
    else { return nil }
    return UnsafePointer(segments + Int(n))
}

@c @implementation
public func cmsGetToneCurveParametricType(_ t: UnsafePointer<cmsToneCurve>?) -> cmsInt32Number {
    // Only a single-segment curve has a type worth reporting.
    guard let t, t.pointee.nSegments == 1, let segments = t.pointee.Segments else { return 0 }
    return segments[0].Type
}

@c @implementation
public func cmsIsToneCurveMultisegment(_ t: UnsafePointer<cmsToneCurve>?) -> cmsBool {
    guard let t else { return 0 }
    return t.pointee.nSegments > 1 ? 1 : 0
}
