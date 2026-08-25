import CLCMS2
import LittleCMSCore

// The multi-process-element tag type: a pipeline stored as a sequence
// of elements, each with its own type and its own encoding — segmented
// float curves, a float matrix with offsets, a float CLUT — reached
// through a position table.  It is how the DToB and BToD tags hold
// their floating-point pipelines.

private let tagBaseSize = cmsUInt32Number(MemoryLayout<_cmsTagBase>.size)
private let minusInfinity = Float(-1e22)
private let plusInfinity = Float(1e22)

@inline(__always)
private func tell(_ io: UnsafeMutablePointer<cmsIOHANDLER>) -> cmsUInt32Number {
    io.pointee.Tell?(io) ?? 0
}

@inline(__always)
private func seek(_ io: UnsafeMutablePointer<cmsIOHANDLER>, _ offset: cmsUInt32Number) -> Bool {
    io.pointee.Seek?(io, offset) != 0
}

// -- segmented curves ---------------------------------------------------------------

/// A segmented curve: the break points, then per segment either a
/// formula (one of three types, with 4 or 5 parameters) or a sampled
/// table whose first point is implied and filled in from the previous
/// segment afterwards.
private func readSegmentedCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>
) -> UnsafeMutablePointer<cmsToneCurve>? {
    var elementSig: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &elementSig) == 0 { return nil }
    if elementSig != cmsSigSegmentedCurve.rawValue { return nil }
    if _cmsReadUInt32Number(io, nil) == 0 { return nil }

    var nSegments: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &nSegments) == 0 { return nil }
    if _cmsReadUInt16Number(io, nil) == 0 { return nil }
    if nSegments < 1 { return nil }
    let count = Int(nSegments)

    var segments = [cmsCurveSegment](repeating: cmsCurveSegment(), count: count)
    defer {
        for s in segments { if let points = s.SampledPoints { _cmsFree(context, points) } }
    }

    var previousBreak = minusInfinity
    for i in 0..<(count - 1) {
        segments[i].x0 = previousBreak
        if _cmsReadFloat32Number(io, &segments[i].x1) == 0 { return nil }
        previousBreak = segments[i].x1
    }
    segments[count - 1].x0 = previousBreak
    segments[count - 1].x1 = plusInfinity

    for i in 0..<count {
        if _cmsReadUInt32Number(io, &elementSig) == 0 { return nil }
        if _cmsReadUInt32Number(io, nil) == 0 { return nil }

        switch elementSig {
        case cmsSigFormulaCurveSeg.rawValue:
            var type: cmsUInt16Number = 0
            let paramsByType = [4, 5, 5]
            if _cmsReadUInt16Number(io, &type) == 0 { return nil }
            if _cmsReadUInt16Number(io, nil) == 0 { return nil }
            segments[i].Type = cmsInt32Number(type) + 6
            if type > 2 { return nil }
            var read = [Float](repeating: 0, count: paramsByType[Int(type)])
            for j in 0..<read.count {
                if _cmsReadFloat32Number(io, &read[j]) == 0 { return nil }
            }
            withUnsafeMutableBytes(of: &segments[i].Params) { params in
                let p = params.bindMemory(to: cmsFloat64Number.self)
                for j in 0..<read.count { p[j] = Double(read[j]) }
            }

        case cmsSigSampledCurveSeg.rawValue:
            var stored: cmsUInt32Number = 0
            if _cmsReadUInt32Number(io, &stored) == 0 { return nil }
            let n = stored + 1
            segments[i].nGridPoints = n
            guard let points = _cmsCalloc(context, n, cmsUInt32Number(MemoryLayout<cmsFloat32Number>.stride))?
                .assumingMemoryBound(to: cmsFloat32Number.self)
            else { return nil }
            segments[i].SampledPoints = points
            points[0] = 0
            for j in 1..<Int(n) {
                if _cmsReadFloat32Number(io, points + j) == 0 { return nil }
            }

        default:
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "Unknown curve element type '\(signatureText(elementSig))' found.", to: context
            )
            return nil
        }
    }

    guard let curve = cmsBuildSegmentedToneCurve(context, nSegments == 0 ? 0 : cmsUInt32Number(count), &segments)
    else { return nil }

    // A sampled segment's first point is where the curve arrives from
    // the segment before.
    for i in 0..<count {
        if curve.pointee.Segments[i].Type == 0, let points = curve.pointee.Segments[i].SampledPoints {
            points[0] = cmsEvalToneCurveFloat(curve, curve.pointee.Segments[i].x0)
        }
    }
    return curve
}

private func writeSegmentedCurve(_ io: UnsafeMutablePointer<cmsIOHANDLER>, _ g: UnsafeMutablePointer<cmsToneCurve>) -> Bool {
    let nSegments = Int(g.pointee.nSegments)
    guard let segments = g.pointee.Segments else { return false }

    if _cmsWriteUInt32Number(io, cmsSigSegmentedCurve.rawValue) == 0 { return false }
    if _cmsWriteUInt32Number(io, 0) == 0 { return false }
    if _cmsWriteUInt16Number(io, cmsUInt16Number(nSegments)) == 0 { return false }
    if _cmsWriteUInt16Number(io, 0) == 0 { return false }

    for i in 0..<max(nSegments - 1, 0) {
        if _cmsWriteFloat32Number(io, segments[i].x1) == 0 { return false }
    }

    for i in 0..<nSegments {
        var segment = segments[i]
        if segment.Type == 0 {
            if _cmsWriteUInt32Number(io, cmsSigSampledCurveSeg.rawValue) == 0 { return false }
            if _cmsWriteUInt32Number(io, 0) == 0 { return false }
            if _cmsWriteUInt32Number(io, segment.nGridPoints &- 1) == 0 { return false }
            for j in 1..<Int(segment.nGridPoints) {
                if _cmsWriteFloat32Number(io, segment.SampledPoints[j]) == 0 { return false }
            }
        } else {
            let paramsByType = [4, 5, 5]
            if _cmsWriteUInt32Number(io, cmsSigFormulaCurveSeg.rawValue) == 0 { return false }
            if _cmsWriteUInt32Number(io, 0) == 0 { return false }
            let type = Int(segment.Type) - 6
            if type > 2 || type < 0 { return false }
            if _cmsWriteUInt16Number(io, cmsUInt16Number(type)) == 0 { return false }
            if _cmsWriteUInt16Number(io, 0) == 0 { return false }
            let ok = withUnsafeBytes(of: &segment.Params) { params -> Bool in
                let p = params.bindMemory(to: cmsFloat64Number.self)
                for j in 0..<paramsByType[type] {
                    if _cmsWriteFloat32Number(io, cmsFloat32Number(p[j])) == 0 { return false }
                }
                return true
            }
            if !ok { return false }
        }
    }
    return true
}

// -- the element types ------------------------------------------------------------------

/// A set of segmented curves, one per channel, through a position table.
@Sendable private func readMPECurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    let base = tell(io) - tagBaseSize
    var inputChans: cmsUInt16Number = 0, outputChans: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &inputChans) == 0 { return nil }
    if _cmsReadUInt16Number(io, &outputChans) == 0 { return nil }
    if inputChans != outputChans { return nil }
    let n = Int(inputChans)

    var curves = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: n)
    defer { for c in curves { cmsFreeToneCurve(c) } }

    // The position table: offsets and sizes, then each element in turn.
    var offsets = [cmsUInt32Number](repeating: 0, count: n)
    for i in 0..<n {
        if _cmsReadUInt32Number(io, &offsets[i]) == 0 { return nil }
        if _cmsReadUInt32Number(io, nil) == 0 { return nil }
        offsets[i] += base
    }
    for i in 0..<n {
        if !seek(io, offsets[i]) { return nil }
        curves[i] = readSegmentedCurve(context, io)
        if curves[i] == nil { return nil }
    }

    guard let mpe = cmsStageAllocToneCurves(context, cmsUInt32Number(inputChans), &curves) else { return nil }
    items = 1
    return UnsafeMutableRawPointer(mpe)
}

@Sendable private func writeMPECurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let mpe = object.assumingMemoryBound(to: cmsStage.self)
    guard let data = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self),
          let curves = data.pointee.TheCurves
    else { return false }
    let base = tell(io) - tagBaseSize
    let n = Int(cmsStageInputChannels(mpe))

    if _cmsWriteUInt16Number(io, cmsUInt16Number(n)) == 0 { return false }
    if _cmsWriteUInt16Number(io, cmsUInt16Number(n)) == 0 { return false }

    let directory = tell(io)
    for _ in 0..<n {
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
    }
    var offsets = [cmsUInt32Number](repeating: 0, count: n)
    var sizes = [cmsUInt32Number](repeating: 0, count: n)
    for i in 0..<n {
        let before = tell(io)
        offsets[i] = before - base
        guard let curve = curves[i], writeSegmentedCurve(io, curve) else { return false }
        sizes[i] = tell(io) - before
    }
    let end = tell(io)
    if !seek(io, directory) { return false }
    for i in 0..<n {
        if _cmsWriteUInt32Number(io, offsets[i]) == 0 { return false }
        if _cmsWriteUInt32Number(io, sizes[i]) == 0 { return false }
    }
    return seek(io, end)
}

/// A float matrix with offsets.
@Sendable private func readMPEMatrix(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var inputChans: cmsUInt16Number = 0, outputChans: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &inputChans) == 0 { return nil }
    if _cmsReadUInt16Number(io, &outputChans) == 0 { return nil }
    if Int(inputChans) >= maximumChannels || Int(outputChans) >= maximumChannels { return nil }

    let nElems = Int(inputChans) * Int(outputChans)
    var matrix = [cmsFloat64Number](repeating: 0, count: nElems)
    var offsets = [cmsFloat64Number](repeating: 0, count: Int(outputChans))
    for i in 0..<nElems {
        var v: Float = 0
        if _cmsReadFloat32Number(io, &v) == 0 { return nil }
        matrix[i] = Double(v)
    }
    for i in 0..<Int(outputChans) {
        var v: Float = 0
        if _cmsReadFloat32Number(io, &v) == 0 { return nil }
        offsets[i] = Double(v)
    }
    guard let mpe = cmsStageAllocMatrix(context, cmsUInt32Number(outputChans), cmsUInt32Number(inputChans), &matrix, &offsets)
    else { return nil }
    items = 1
    return UnsafeMutableRawPointer(mpe)
}

@Sendable private func writeMPEMatrix(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let mpe = object.assumingMemoryBound(to: cmsStage.self)
    guard let data = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageMatrixData.self),
          let values = data.pointee.Double
    else { return false }
    let inputs = Int(cmsStageInputChannels(mpe)), outputs = Int(cmsStageOutputChannels(mpe))

    if _cmsWriteUInt16Number(io, cmsUInt16Number(inputs)) == 0 { return false }
    if _cmsWriteUInt16Number(io, cmsUInt16Number(outputs)) == 0 { return false }
    for i in 0..<(inputs * outputs) {
        if _cmsWriteFloat32Number(io, cmsFloat32Number(values[i])) == 0 { return false }
    }
    for i in 0..<outputs {
        let offset = data.pointee.Offset.map { cmsFloat32Number($0[i]) } ?? 0
        if _cmsWriteFloat32Number(io, offset) == 0 { return false }
    }
    return true
}

/// A float CLUT: sixteen grid-size bytes (the spec's count, whatever the
/// channel maximum), then the table.
@Sendable private func readMPEClut(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var inputChans: cmsUInt16Number = 0, outputChans: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &inputChans) == 0 { return nil }
    if _cmsReadUInt16Number(io, &outputChans) == 0 { return nil }
    if inputChans == 0 || Int(inputChans) >= maximumChannels { return nil }
    if outputChans == 0 || Int(outputChans) >= maximumChannels { return nil }

    var dimensions8 = [UInt8](repeating: 0, count: 16)
    guard let read = io.pointee.Read, read(io, &dimensions8, 1, 16) == 16 else { return nil }

    let nMaxGrids = min(Int(inputChans), Int(MAX_INPUT_DIMENSIONS))
    var gridPoints = [cmsUInt32Number](repeating: 0, count: Int(MAX_INPUT_DIMENSIONS))
    for i in 0..<nMaxGrids {
        if dimensions8[i] == 1 { return nil }   // impossible: none, or at least two
        gridPoints[i] = cmsUInt32Number(dimensions8[i])
    }

    guard let mpe = cmsStageAllocCLutFloatGranular(context, &gridPoints, cmsUInt32Number(inputChans), cmsUInt32Number(outputChans), nil)
    else { return nil }
    guard let clut = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let table = clut.pointee.Tab.TFloat
    else {
        cmsStageFree(mpe)
        return nil
    }
    for i in 0..<Int(clut.pointee.nEntries) {
        if _cmsReadFloat32Number(io, table + i) == 0 {
            cmsStageFree(mpe)
            return nil
        }
    }
    items = 1
    return UnsafeMutableRawPointer(mpe)
}

@Sendable private func writeMPEClut(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let mpe = object.assumingMemoryBound(to: cmsStage.self)
    guard let clut = cmsStageData(mpe)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = clut.pointee.Params
    else { return false }
    let inputs = Int(cmsStageInputChannels(mpe))
    if inputs > Int(MAX_INPUT_DIMENSIONS) { return false }
    if clut.pointee.HasFloatValues == 0 { return false }
    guard let table = clut.pointee.Tab.TFloat else { return false }

    if _cmsWriteUInt16Number(io, cmsUInt16Number(inputs)) == 0 { return false }
    if _cmsWriteUInt16Number(io, cmsUInt16Number(cmsStageOutputChannels(mpe))) == 0 { return false }

    var dimensions8 = [UInt8](repeating: 0, count: 16)
    withUnsafeBytes(of: &params.pointee.nSamples) { samples in
        let s = samples.bindMemory(to: cmsUInt32Number.self)
        for i in 0..<inputs { dimensions8[i] = UInt8(truncatingIfNeeded: s[i]) }
    }
    guard let write = io.pointee.Write, write(io, 16, &dimensions8) != 0 else { return false }

    for i in 0..<Int(clut.pointee.nEntries) {
        if _cmsWriteFloat32Number(io, table[i]) == 0 { return false }
    }
    return true
}

/// The element types the MPE tag knows: the two ACS markers are read as
/// nothing, and the three real ones each have a handler.
private let mpeElementHandlers: [cmsUInt32Number: TagTypeHandler?] = [
    cmsSigBAcsElemType.rawValue: nil,
    cmsSigEAcsElemType.rawValue: nil,
    cmsSigCurveSetElemType.rawValue: TagTypeHandler(
        signature: cmsTagTypeSignature(rawValue: cmsSigCurveSetElemType.rawValue),
        read: readMPECurve, write: writeMPECurve,
        duplicate: { _, p, _ in UnsafeMutableRawPointer(cmsStageDup(UnsafeMutablePointer(mutating: p.assumingMemoryBound(to: cmsStage.self)))) },
        free: { _, o in cmsStageFree(o.assumingMemoryBound(to: cmsStage.self)) }
    ),
    cmsSigMatrixElemType.rawValue: TagTypeHandler(
        signature: cmsTagTypeSignature(rawValue: cmsSigMatrixElemType.rawValue),
        read: readMPEMatrix, write: writeMPEMatrix,
        duplicate: { _, p, _ in UnsafeMutableRawPointer(cmsStageDup(UnsafeMutablePointer(mutating: p.assumingMemoryBound(to: cmsStage.self)))) },
        free: { _, o in cmsStageFree(o.assumingMemoryBound(to: cmsStage.self)) }
    ),
    cmsSigCLutElemType.rawValue: TagTypeHandler(
        signature: cmsTagTypeSignature(rawValue: cmsSigCLutElemType.rawValue),
        read: readMPEClut, write: writeMPEClut,
        duplicate: { _, p, _ in UnsafeMutableRawPointer(cmsStageDup(UnsafeMutablePointer(mutating: p.assumingMemoryBound(to: cmsStage.self)))) },
        free: { _, o in cmsStageFree(o.assumingMemoryBound(to: cmsStage.self)) }
    ),
]

// -- the tag type -------------------------------------------------------------------

/// The pipeline: channel counts, an element count, a position table, and
/// each element with its type signature.
@Sendable private func readMPE(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    let base = tell(io) - tagBaseSize
    var inputChans: cmsUInt16Number = 0, outputChans: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &inputChans) == 0 { return nil }
    if _cmsReadUInt16Number(io, &outputChans) == 0 { return nil }
    if inputChans == 0 || Int(inputChans) >= maximumChannels { return nil }
    if outputChans == 0 || Int(outputChans) >= maximumChannels { return nil }

    guard let lut = cmsPipelineAlloc(context, cmsUInt32Number(inputChans), cmsUInt32Number(outputChans)) else { return nil }
    func fail() -> UnsafeMutableRawPointer? {
        cmsPipelineFree(lut)
        return nil
    }

    var elementCount: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &elementCount) == 0 { return fail() }

    // The directory: two words per element; a count claiming more than
    // the file can hold is refused before anything is read.
    let position = tell(io)
    if (io.pointee.ReportedSize &- position) / 8 < elementCount { return fail() }
    let n = Int(elementCount)
    var offsets = [cmsUInt32Number](repeating: 0, count: n)
    var sizes = [cmsUInt32Number](repeating: 0, count: n)
    for i in 0..<n {
        if _cmsReadUInt32Number(io, &offsets[i]) == 0 { return fail() }
        if _cmsReadUInt32Number(io, &sizes[i]) == 0 { return fail() }
        offsets[i] += base
    }

    for i in 0..<n {
        if !seek(io, offsets[i]) { return fail() }
        var elementSig: cmsUInt32Number = 0
        if _cmsReadUInt32Number(io, &elementSig) == 0 { return fail() }
        if _cmsReadUInt32Number(io, nil) == 0 { return fail() }

        // A plugin's element types come first; the two placeholder
        // elements are known and read as nothing.
        let entry: TagTypeHandler?
        if let plugin = PluginRegistry.resolve(context).mpeType(for: cmsTagTypeSignature(rawValue: elementSig)) {
            entry = plugin
        } else if let builtin = mpeElementHandlers[elementSig] {
            entry = builtin
        } else {
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "Unknown MPE type '\(signatureText(elementSig))' found.", to: context
            )
            return fail()
        }
        if let handler = entry {
            var got: cmsUInt32Number = 0
            let stage = handler.read(context, io, &got, sizes[i], version)?.assumingMemoryBound(to: cmsStage.self)
            if cmsPipelineInsertStage(lut, cmsAT_END, stage) == 0 { return fail() }
        }
    }

    if inputChans != cmsPipelineInputChannels(lut) || outputChans != cmsPipelineOutputChannels(lut) {
        return fail()
    }
    items = 1
    return UnsafeMutableRawPointer(lut)
}

@Sendable private func writeMPE(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let lut = object.assumingMemoryBound(to: cmsPipeline.self)
    let base = tell(io) - tagBaseSize
    let elemCount = Int(cmsPipelineStageCount(lut))

    if _cmsWriteUInt16Number(io, cmsUInt16Number(cmsPipelineInputChannels(lut))) == 0 { return false }
    if _cmsWriteUInt16Number(io, cmsUInt16Number(cmsPipelineOutputChannels(lut))) == 0 { return false }
    if _cmsWriteUInt32Number(io, cmsUInt32Number(elemCount)) == 0 { return false }

    let directory = tell(io)
    for _ in 0..<elemCount {
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
    }

    var offsets = [cmsUInt32Number](repeating: 0, count: elemCount)
    var sizes = [cmsUInt32Number](repeating: 0, count: elemCount)
    var element = cmsPipelineGetPtrToFirstStage(lut)
    for i in 0..<elemCount {
        guard let elem = element else { return false }
        offsets[i] = tell(io) - base
        let elementSig = cmsStageType(elem).rawValue

        guard let handler = PluginRegistry.resolve(context).mpeType(for: cmsTagTypeSignature(rawValue: elementSig))
                ?? mpeElementHandlers[elementSig].flatMap({ $0 })
        else {
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "Found unknown MPE type '\(signatureText(elementSig))'", to: context
            )
            return false
        }
        let before = tell(io)
        if _cmsWriteUInt32Number(io, elementSig) == 0 { return false }
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
        if !handler.write(context, io, UnsafeMutableRawPointer(elem), 1, version) { return false }
        if _cmsWriteAlignment(io) == 0 { return false }
        sizes[i] = tell(io) - before
        element = cmsStageNext(elem)
    }

    let end = tell(io)
    if !seek(io, directory) { return false }
    for i in 0..<elemCount {
        if _cmsWriteUInt32Number(io, offsets[i]) == 0 { return false }
        if _cmsWriteUInt32Number(io, sizes[i]) == 0 { return false }
    }
    return seek(io, end)
}

let mpeTagType = TagTypeHandler(
    signature: cmsSigMultiProcessElementType,
    read: readMPE, write: writeMPE,
    duplicate: { _, p, _ in
        UnsafeMutableRawPointer(cmsPipelineDup(UnsafeMutablePointer(mutating: p.assumingMemoryBound(to: cmsPipeline.self))))
    },
    free: { _, o in cmsPipelineFree(o.assumingMemoryBound(to: cmsPipeline.self)) }
)
