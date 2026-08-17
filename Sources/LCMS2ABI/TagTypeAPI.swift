import CLCMS2
import LittleCMS

// Tag types: the serializers that turn a tag's bytes into an object and
// back.
//
// The ownership rule is the one `cmsReadTag` publishes and nothing else
// in the library repeats: **the pointer belongs to the profile**.  It
// stays valid until `cmsCloseProfile`, repeated reads of the same tag
// return the same pointer, and a caller who frees it has broken the
// profile.  So the profile holds a materialized object per tag slot, and
// reading twice reads the cache the second time.
//
// This file carries the machinery and the fixed-size value types.  The
// curve, LUT and multi-localized types follow.

/// One serializer.  The reference reaches these through a struct of
/// function pointers a plugin can add to; there is no plugin support, so
/// here it is a table of closures with the same four operations.
struct TagTypeHandler: Sendable {
    let signature: cmsTagTypeSignature
    /// Reads one object, reporting how many elements it found.
    let read: @Sendable (
        _ context: cmsContext?,
        _ io: UnsafeMutablePointer<cmsIOHANDLER>,
        _ items: inout cmsUInt32Number,
        _ sizeOfTag: cmsUInt32Number
    ) -> UnsafeMutableRawPointer?
    let write: @Sendable (
        _ context: cmsContext?,
        _ io: UnsafeMutablePointer<cmsIOHANDLER>,
        _ object: UnsafeMutableRawPointer,
        _ items: cmsUInt32Number
    ) -> Bool
    let duplicate: @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
        -> UnsafeMutableRawPointer?
    let free: @Sendable (cmsContext?, UnsafeMutableRawPointer) -> Void
}

/// Frees a block that came from the library's allocator.  Most types
/// hold exactly one such block and nothing else.
@Sendable private func freePlainBlock(_ context: cmsContext?, _ object: UnsafeMutableRawPointer) {
    _cmsFree(context, object)
}

// -- the fixed-size value types --------------------------------------------

@Sendable private func readXYZ(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsCIEXYZ>.size))
    else { return nil }
    if _cmsReadXYZNumber(io, raw.assumingMemoryBound(to: cmsCIEXYZ.self)) == 0 {
        _cmsFree(context, raw)
        return nil
    }
    items = 1
    return raw
}

@Sendable private func readChromaticity(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsCIExyYTRIPLE>.size))
    else { return nil }
    let chrm = raw.assumingMemoryBound(to: cmsCIExyYTRIPLE.self)

    func fail() -> UnsafeMutableRawPointer? {
        _cmsFree(context, raw)
        return nil
    }

    var channels: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &channels) == 0 { return fail() }

    // Early lcms1 wrote a leading zero here; the tag is recognisable by
    // its length, so the count is read again rather than refused.
    if channels == 0 && sizeOfTag == 32 {
        if _cmsReadUInt16Number(io, nil) == 0 { return fail() }
        if _cmsReadUInt16Number(io, &channels) == 0 { return fail() }
    }
    if channels != 3 { return fail() }

    var table: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &table) == 0 { return fail() }

    // Only x and y are stored; Y is always one.
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Red.x) == 0 { return fail() }
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Red.y) == 0 { return fail() }
    chrm.pointee.Red.Y = 1.0
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Green.x) == 0 { return fail() }
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Green.y) == 0 { return fail() }
    chrm.pointee.Green.Y = 1.0
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Blue.x) == 0 { return fail() }
    if _cmsRead15Fixed16Number(io, &chrm.pointee.Blue.y) == 0 { return fail() }
    chrm.pointee.Blue.Y = 1.0

    items = 1
    return raw
}

@Sendable private func writeChromaticity(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    let chrm = object.assumingMemoryBound(to: cmsCIExyYTRIPLE.self)
    if _cmsWriteUInt16Number(io, 3) == 0 { return false }    // channels
    if _cmsWriteUInt16Number(io, 0) == 0 { return false }    // table

    func one(_ x: cmsFloat64Number, _ y: cmsFloat64Number) -> Bool {
        if _cmsWriteUInt32Number(io, cmsUInt32Number(bitPattern: _cmsDoubleTo15Fixed16(x))) == 0 {
            return false
        }
        return _cmsWriteUInt32Number(io, cmsUInt32Number(bitPattern: _cmsDoubleTo15Fixed16(y))) != 0
    }

    return one(chrm.pointee.Red.x, chrm.pointee.Red.y)
        && one(chrm.pointee.Green.x, chrm.pointee.Green.y)
        && one(chrm.pointee.Blue.x, chrm.pointee.Blue.y)
}

/// Both fixed-point array types land in memory as an array of doubles;
/// only the encoding on disk differs, and how many entries there are is
/// the tag's length divided by four.
private func readFixedArray(
    scale: @escaping @Sendable (
        UnsafeMutablePointer<cmsIOHANDLER>, UnsafeMutablePointer<cmsFloat64Number>
    ) -> Bool
) -> @Sendable (
    cmsContext?, UnsafeMutablePointer<cmsIOHANDLER>, inout cmsUInt32Number, cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    { context, io, items, sizeOfTag in
        items = 0
        let n = sizeOfTag / cmsUInt32Number(MemoryLayout<cmsUInt32Number>.size)
        guard let raw = _cmsCalloc(
            context, n, cmsUInt32Number(MemoryLayout<cmsFloat64Number>.size)
        ) else { return nil }
        let values = raw.assumingMemoryBound(to: cmsFloat64Number.self)

        for i in 0..<Int(n) where !scale(io, values + i) {
            _cmsFree(context, raw)
            return nil
        }
        items = n
        return raw
    }
}

@Sendable private func readSignature(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMalloc(context, cmsUInt32Number(MemoryLayout<cmsSignature>.size))
    else { return nil }
    // The reference leaks this block when the read fails.  A leak is not
    // observable through the ABI, so it is not reproduced.
    if _cmsReadUInt32Number(io, raw.assumingMemoryBound(to: cmsUInt32Number.self)) == 0 {
        _cmsFree(context, raw)
        return nil
    }
    items = 1
    return raw
}

@Sendable private func readDateTime(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMalloc(context, cmsUInt32Number(MemoryLayout<tm>.size)),
          let read = io.pointee.Read
    else { return nil }

    var timestamp = cmsDateTimeNumber()
    let got = withUnsafeMutableBytes(of: &timestamp) { buffer in
        read(io, buffer.baseAddress, cmsUInt32Number(MemoryLayout<cmsDateTimeNumber>.size), 1)
    }
    if got != 1 {
        _cmsFree(context, raw)
        return nil
    }
    _cmsDecodeDateTimeNumber(&timestamp, raw.assumingMemoryBound(to: tm.self))
    items = 1
    return raw
}

@Sendable private func writeDateTime(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    var timestamp = cmsDateTimeNumber()
    _cmsEncodeDateTimeNumber(&timestamp, object.assumingMemoryBound(to: tm.self))
    return withUnsafeBytes(of: &timestamp) { buffer in
        write(io, cmsUInt32Number(MemoryLayout<cmsDateTimeNumber>.size), buffer.baseAddress)
    } != 0
}

/// The colorant order is always a full-width array; `0xFF` marks the end
/// of the colorants actually present, which is why the block is filled
/// with `0xFF` before the stored ones are read over it.
@Sendable private func readColorantOrder(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var count: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    if count > cmsUInt32Number(cmsMAXCHANNELS) { return nil }

    guard let raw = _cmsCalloc(context, cmsUInt32Number(cmsMAXCHANNELS), 1),
          let read = io.pointee.Read
    else { return nil }
    UnsafeMutableRawBufferPointer(start: raw, count: Int(cmsMAXCHANNELS))
        .initializeMemory(as: UInt8.self, repeating: 0xFF)

    if read(io, raw, 1, count) != count {
        _cmsFree(context, raw)
        return nil
    }
    items = 1
    return raw
}

@Sendable private func writeColorantOrder(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let order = object.assumingMemoryBound(to: cmsUInt8Number.self)

    // The length is however many entries are not the end marker — which
    // counts them wherever they are, not up to the first marker.
    var count: cmsUInt32Number = 0
    for i in 0..<Int(cmsMAXCHANNELS) where order[i] != 0xFF { count += 1 }

    if _cmsWriteUInt32Number(io, count) == 0 { return false }
    return write(io, count, order) != 0
}

/// `cmsICCData` ends in a flexible array, so the block is one allocation
/// sized to the payload and the length is not on disk — it is whatever
/// the tag had left after the flag.
@Sendable private func readData(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    let headerSize = cmsUInt32Number(MemoryLayout<cmsUInt32Number>.size)
    if sizeOfTag < headerSize { return nil }
    let payload = sizeOfTag - headerSize
    if payload > cmsUInt32Number(Int32.max) { return nil }

    guard let raw = _cmsMalloc(
        context, cmsUInt32Number(MemoryLayout<cmsICCData>.size) + payload - 1
    ), let read = io.pointee.Read else { return nil }
    let block = raw.assumingMemoryBound(to: cmsICCData.self)

    block.pointee.len = payload
    if _cmsReadUInt32Number(io, &block.pointee.flag) == 0 {
        _cmsFree(context, raw)
        return nil
    }
    let bytes = raw + MemoryLayout<cmsICCData>.offset(of: \.data)!
    if read(io, bytes, 1, payload) != payload {
        _cmsFree(context, raw)
        return nil
    }
    items = 1
    return raw
}

@Sendable private func writeData(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let block = object.assumingMemoryBound(to: cmsICCData.self)
    if _cmsWriteUInt32Number(io, block.pointee.flag) == 0 { return false }
    let bytes = object + MemoryLayout<cmsICCData>.offset(of: \.data)!
    return write(io, block.pointee.len, bytes) != 0
}

/// Plain text arrives as a multi-localized container with one entry
/// under no language and no country — so a client reads `desc` and
/// `cprt` the same way whichever of the three text types the profile
/// used.
@Sendable private func readText(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let mlu = cmsMLUalloc(context, 1) else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsMLUfree(mlu)
        return nil
    }

    // Room for the terminator the stored text does not carry.
    if sizeOfTag == cmsUInt32Number.max { return fail() }
    guard let text = _cmsMalloc(context, sizeOfTag + 1), let read = io.pointee.Read
    else { return fail() }
    defer { _cmsFree(context, text) }

    if read(io, text, 1, sizeOfTag) != sizeOfTag { return fail() }
    text.assumingMemoryBound(to: CChar.self)[Int(sizeOfTag)] = 0

    if cmsMLUsetASCII(
        mlu, cmsNoLanguage, cmsNoCountry, text.assumingMemoryBound(to: CChar.self)
    ) == 0 { return fail() }

    items = 1
    return UnsafeMutableRawPointer(mlu)
}

@Sendable private func writeText(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let mlu = object.assumingMemoryBound(to: cmsMLU.self)

    // The reported size counts the terminator, and the terminator is
    // written out with the text.
    let size = cmsMLUgetASCII(mlu, cmsNoLanguage, cmsNoCountry, nil, 0)
    if size == 0 { return false }

    guard let text = _cmsMalloc(context, size) else { return false }
    defer { _cmsFree(context, text) }

    _ = cmsMLUgetASCII(
        mlu, cmsNoLanguage, cmsNoCountry, text.assumingMemoryBound(to: CChar.self), size
    )
    return write(io, size, text) != 0
}

// -- the registry ------------------------------------------------------------

private let tagTypeHandlers: [cmsTagTypeSignature: TagTypeHandler] = {
    var table: [cmsTagTypeSignature: TagTypeHandler] = [:]

    func add(
        _ signature: cmsTagTypeSignature,
        read: @escaping @Sendable (
            cmsContext?, UnsafeMutablePointer<cmsIOHANDLER>, inout cmsUInt32Number,
            cmsUInt32Number
        ) -> UnsafeMutableRawPointer?,
        write: @escaping @Sendable (
            cmsContext?, UnsafeMutablePointer<cmsIOHANDLER>, UnsafeMutableRawPointer,
            cmsUInt32Number
        ) -> Bool,
        duplicate: @escaping @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
            -> UnsafeMutableRawPointer?,
        free: @escaping @Sendable (cmsContext?, UnsafeMutableRawPointer) -> Void = freePlainBlock
    ) {
        table[signature] = TagTypeHandler(
            signature: signature, read: read, write: write,
            duplicate: duplicate, free: free
        )
    }

    /// The commonest duplicate: one block of a fixed size.
    func dupFixed<T>(_ type: T.Type) -> @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
        -> UnsafeMutableRawPointer? {
        { context, pointer, _ in
            _cmsDupMem(context, pointer, cmsUInt32Number(MemoryLayout<T>.size))
        }
    }

    /// An array whose length is the element count the descriptor gave.
    func dupArray<T>(_ type: T.Type) -> @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
        -> UnsafeMutableRawPointer? {
        { context, pointer, n in
            _cmsDupMem(context, pointer, n * cmsUInt32Number(MemoryLayout<T>.size))
        }
    }

    add(
        cmsSigXYZType, read: readXYZ,
        write: { _, io, object, _ in
            _cmsWriteXYZNumber(io, object.assumingMemoryBound(to: cmsCIEXYZ.self)) != 0
        },
        duplicate: dupFixed(cmsCIEXYZ.self)
    )
    // The type Corbis once wrote is read as an ordinary XYZ.  Nothing
    // ever writes it: DecideXYZtype always answers with the real one.
    table[cmsTagTypeSignature(0x17A5_05B8)] = table[cmsSigXYZType]

    add(
        cmsSigChromaticityType, read: readChromaticity, write: writeChromaticity,
        duplicate: dupFixed(cmsCIExyYTRIPLE.self)
    )

    add(
        cmsSigS15Fixed16ArrayType,
        read: readFixedArray { io, slot in _cmsRead15Fixed16Number(io, slot) != 0 },
        write: { _, io, object, n in
            let values = object.assumingMemoryBound(to: cmsFloat64Number.self)
            for i in 0..<Int(n) where _cmsWrite15Fixed16Number(io, values[i]) == 0 {
                return false
            }
            return true
        },
        duplicate: dupArray(cmsFloat64Number.self)
    )

    add(
        cmsSigU16Fixed16ArrayType,
        read: readFixedArray { io, slot in
            var v: cmsUInt32Number = 0
            if _cmsReadUInt32Number(io, &v) == 0 { return false }
            slot.pointee = cmsFloat64Number(v) / 65536.0
            return true
        },
        write: { _, io, object, n in
            let values = object.assumingMemoryBound(to: cmsFloat64Number.self)
            for i in 0..<Int(n) {
                let v = cmsUInt32Number((values[i] * 65536.0 + 0.5).rounded(.down))
                if _cmsWriteUInt32Number(io, v) == 0 { return false }
            }
            return true
        },
        duplicate: dupArray(cmsFloat64Number.self)
    )

    add(
        cmsSigSignatureType, read: readSignature,
        write: { _, io, object, _ in
            _cmsWriteUInt32Number(io, object.assumingMemoryBound(to: cmsUInt32Number.self).pointee) != 0
        },
        duplicate: dupArray(cmsSignature.self)
    )

    add(
        cmsSigDateTimeType, read: readDateTime, write: writeDateTime,
        duplicate: dupFixed(tm.self)
    )

    add(
        cmsSigColorantOrderType, read: readColorantOrder, write: writeColorantOrder,
        duplicate: { context, pointer, _ in
            _cmsDupMem(context, pointer, cmsUInt32Number(cmsMAXCHANNELS))
        }
    )

    add(
        cmsSigDataType, read: readData, write: writeData,
        duplicate: { context, pointer, _ in
            // The block's length lives inside it, so a copy has to read
            // it before it knows how much to copy.
            let block = pointer.assumingMemoryBound(to: cmsICCData.self)
            return _cmsDupMem(
                context, pointer,
                cmsUInt32Number(MemoryLayout<cmsICCData>.size) + block.pointee.len - 1
            )
        }
    )

    add(
        cmsSigTextType, read: readText, write: writeText,
        duplicate: { _, pointer, _ in
            UnsafeMutableRawPointer(cmsMLUdup(
                UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsMLU.self))
            ))
        },
        free: { _, object in cmsMLUfree(object.assumingMemoryBound(to: cmsMLU.self)) }
    )

    // The curve types live in their own table because they hold objects
    // rather than blocks; merged here so there is still one registry.
    table.merge(curveTagTypes) { existing, _ in existing }
    table[cmsSigMultiLocalizedUnicodeType] = mluTagType
    table[cmsSigTextDescriptionType] = textDescriptionTagType

    return table
}()

func tagTypeHandler(for signature: cmsTagTypeSignature) -> TagTypeHandler? {
    tagTypeHandlers[signature]
}

/// Whether a tag may be stored as this type.  A tag the library does not
/// know refuses everything, which is how an unknown tag is reported.
func isTypeSupported(_ sig: cmsTagSignature, _ type: cmsTagTypeSignature) -> Bool {
    guard let descriptor = tagDescriptor(for: sig) else { return false }
    return descriptor.supportedTypes.contains(type)
}

/// Which type a tag is written as.  A descriptor that carries a decision
/// function is asked -- the profile version and the object both matter,
/// because a curve that cannot be expressed parametrically is written as
/// a table even on a version that would prefer the parametric form.
func typeToWrite(
    for sig: cmsTagSignature, version: cmsFloat64Number, data: UnsafeRawPointer
) -> cmsTagTypeSignature? {
    guard let descriptor = tagDescriptor(for: sig) else { return nil }
    if let decide = descriptor.decide { return decide(version, data) }
    return descriptor.supportedTypes.first
}

// -- the curve types ---------------------------------------------------------

/// `curv`: a count, then either nothing (linear), one 8.8 gamma, or that
/// many 16-bit table entries.  So the same type spells three different
/// things and the count is what distinguishes them.
@Sendable private func readCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var count: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }

    switch count {
    case 0:
        // No entries at all means the identity ramp.
        var gamma = 1.0
        guard let curve = cmsBuildParametricToneCurve(context, 1, &gamma) else { return nil }
        items = 1
        return UnsafeMutableRawPointer(curve)

    case 1:
        // One entry is a gamma exponent in 8.8, not a table of one.
        var fixed: cmsUInt16Number = 0
        if _cmsReadUInt16Number(io, &fixed) == 0 { return nil }
        var gamma = _cms8Fixed8toDouble(fixed)
        guard let curve = cmsBuildParametricToneCurve(context, 1, &gamma) else { return nil }
        items = 1
        return UnsafeMutableRawPointer(curve)

    default:
        // A ceiling, so a malformed profile cannot claim a table that
        // would not fit in the file it came from.
        if count > 0x7FFF { return nil }
        guard let curve = cmsBuildTabulatedToneCurve16(context, count, nil) else { return nil }
        if _cmsReadUInt16Array(io, count, curve.pointee.Table16) == 0 {
            cmsFreeToneCurve(curve)
            return nil
        }
        items = 1
        return UnsafeMutableRawPointer(curve)
    }
}

@Sendable private func writeCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    let curve = object.assumingMemoryBound(to: cmsToneCurve.self)

    // A plain gamma keeps its exponent rather than being flattened into
    // a table, so a profile that stored 2.2 still says 2.2 afterwards.
    if curve.pointee.nSegments == 1, let segments = curve.pointee.Segments,
       segments[0].Type == 1 {
        let gamma = withUnsafeBytes(of: segments[0].Params) { params in
            params.load(as: cmsFloat64Number.self)
        }
        if _cmsWriteUInt32Number(io, 1) == 0 { return false }
        return _cmsWriteUInt16Number(io, _cmsDoubleTo8Fixed8(gamma)) != 0
    }

    if _cmsWriteUInt32Number(io, curve.pointee.nEntries) == 0 { return false }
    return _cmsWriteUInt16Array(io, curve.pointee.nEntries, curve.pointee.Table16) != 0
}

/// How many parameters each ICC parametric form carries, indexed by the
/// type as it appears on disk (zero-based) — one behind the numbering
/// `cmsBuildParametricToneCurve` uses.
private let parametricParameterCounts = [1, 3, 4, 5, 7]

@Sendable private func readParametricCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var type: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &type) == 0 { return nil }
    if _cmsReadUInt16Number(io, nil) == 0 { return nil }   // reserved

    // Only the five ICC forms can appear here; the library's own extra
    // types have no on-disk spelling.
    if type > 4 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown parametric curve type '\(type)'", to: context
        )
        return nil
    }

    var params = [cmsFloat64Number](repeating: 0, count: 10)
    for i in 0..<parametricParameterCounts[Int(type)] {
        if _cmsRead15Fixed16Number(io, &params[i]) == 0 { return nil }
    }

    guard let curve = cmsBuildParametricToneCurve(context, cmsInt32Number(type) + 1, &params)
    else { return nil }
    items = 1
    return UnsafeMutableRawPointer(curve)
}

@Sendable private func writeParametricCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    let curve = object.assumingMemoryBound(to: cmsToneCurve.self)
    guard let segments = curve.pointee.Segments else { return false }
    let type = segments[0].Type

    if curve.pointee.nSegments > 1 || type < 1 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Multisegment or Inverted parametric curves cannot be written", to: context
        )
        return false
    }
    if type > 5 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unsupported parametric curve", to: context
        )
        return false
    }

    if _cmsWriteUInt16Number(io, cmsUInt16Number(type - 1)) == 0 { return false }
    if _cmsWriteUInt16Number(io, 0) == 0 { return false }    // reserved

    return withUnsafeBytes(of: segments[0].Params) { raw -> Bool in
        let params = raw.bindMemory(to: cmsFloat64Number.self)
        for i in 0..<parametricParameterCounts[Int(type) - 1] {
            if _cmsWrite15Fixed16Number(io, params[i]) == 0 { return false }
        }
        return true
    }
}

/// Registered separately from the table above, because a curve is an
/// object with its own lifetime rather than a block of bytes.
let curveTagTypes: [cmsTagTypeSignature: TagTypeHandler] = {
    let duplicate: @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
        -> UnsafeMutableRawPointer? = { _, pointer, _ in
            UnsafeMutableRawPointer(cmsDupToneCurve(
                UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsToneCurve.self))
            ))
        }
    let free: @Sendable (cmsContext?, UnsafeMutableRawPointer) -> Void = { _, object in
        cmsFreeToneCurve(object.assumingMemoryBound(to: cmsToneCurve.self))
    }

    let curve = TagTypeHandler(
        signature: cmsSigCurveType, read: readCurve, write: writeCurve,
        duplicate: duplicate, free: free
    )
    return [
        cmsSigCurveType: curve,
        // The malformed curve type Monaco once wrote reads as an
        // ordinary one; DecideCurveType never produces it.
        cmsTagTypeSignature(0x9478_EE00): curve,
        cmsSigParametricCurveType: TagTypeHandler(
            signature: cmsSigParametricCurveType,
            read: readParametricCurve, write: writeParametricCurve,
            duplicate: duplicate, free: free
        ),
    ]
}()

// -- the multi-localized type -------------------------------------------------

/// `mluc`: a directory of language/country pairs, each naming a length
/// and an offset into one pooled block of UTF-16 that follows.
///
/// The reference stores that pool verbatim inside its MLU and writes it
/// back untouched.  Ours holds each translation separately, so the pool
/// is rebuilt by laying the strings out in order — which reproduces what
/// the reference itself emits, since it appends each string once and
/// refuses a repeated language and country pair.  A profile whose pool
/// has strings sharing bytes, or ordered differently from its directory,
/// therefore re-emits with the same strings but not the same bytes.
@Sendable private func readMLU(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var count: cmsUInt32Number = 0
    var recordLength: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    if _cmsReadUInt32Number(io, &recordLength) == 0 { return nil }

    if recordLength != 12 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "multiLocalizedUnicodeType of len != 12 is not supported.", to: context
        )
        return nil
    }

    // The directory is fixed-width, and the tag base has already been
    // consumed, so an offset is measured from before it.
    let headerSize = 12 &* count &+ cmsUInt32Number(MemoryLayout<_cmsTagBase>.size)

    struct Entry { var language: UInt16; var country: UInt16; var start: Int; var bytes: Int }
    var entries: [Entry] = []
    entries.reserveCapacity(Int(count))
    var largest = 0

    for _ in 0..<Int(count) {
        var language: cmsUInt16Number = 0
        var country: cmsUInt16Number = 0
        var length: cmsUInt32Number = 0
        var offset: cmsUInt32Number = 0
        if _cmsReadUInt16Number(io, &language) == 0 { return nil }
        if _cmsReadUInt16Number(io, &country) == 0 { return nil }
        if _cmsReadUInt32Number(io, &length) == 0 { return nil }
        if _cmsReadUInt32Number(io, &offset) == 0 { return nil }

        // An odd offset cannot index UTF-16, so such a profile is
        // refused rather than read crooked.
        if offset & 1 != 0 { return nil }
        if offset < headerSize &+ 8 { return nil }
        if offset &+ length < length || offset &+ length > sizeOfTag &+ 8 { return nil }

        let start = Int(offset - headerSize - 8)
        entries.append(
            Entry(language: language, country: country, start: start, bytes: Int(length))
        )
        largest = max(largest, start + Int(length))
    }

    // Everything after the directory, read as one block.
    var pool = [UInt16](repeating: 0, count: largest / 2)
    if largest > 0 {
        if largest & 1 != 0 { return nil }
        let ok = pool.withUnsafeMutableBufferPointer { buffer -> Bool in
            for i in 0..<buffer.count {
                var unit: cmsUInt16Number = 0
                if _cmsReadUInt16Number(io, &unit) == 0 { return false }
                buffer[i] = unit
            }
            return true
        }
        if !ok { return nil }
    }

    guard let mlu = cmsMLUalloc(context, count) else { return nil }
    for entry in entries {
        let from = entry.start / 2
        let to = min(from + entry.bytes / 2, pool.count)
        let text = from <= to ? Array(pool[from..<to]) : []
        if !mluBox(mlu).mlu.set(
            text,
            language: LocaleCode(rawValue: entry.language),
            country: LocaleCode(rawValue: entry.country)
        ) {
            // A repeated pair is refused, as everywhere else.
            cmsMLUfree(mlu)
            return nil
        }
    }

    items = 1
    return UnsafeMutableRawPointer(mlu)
}

@Sendable private func writeMLU(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    let translations = mluBox(object.assumingMemoryBound(to: cmsMLU.self)).mlu.translations

    if _cmsWriteUInt32Number(io, cmsUInt32Number(translations.count)) == 0 { return false }
    if _cmsWriteUInt32Number(io, 12) == 0 { return false }

    let headerSize = 12 * cmsUInt32Number(translations.count)
        + cmsUInt32Number(MemoryLayout<_cmsTagBase>.size)

    var offset = headerSize + 8
    for translation in translations {
        let length = cmsUInt32Number(translation.text.count * 2)
        if _cmsWriteUInt16Number(io, translation.language.rawValue) == 0 { return false }
        if _cmsWriteUInt16Number(io, translation.country.rawValue) == 0 { return false }
        if _cmsWriteUInt32Number(io, length) == 0 { return false }
        if _cmsWriteUInt32Number(io, offset) == 0 { return false }
        offset += length
    }

    for translation in translations {
        for unit in translation.text {
            if _cmsWriteUInt16Number(io, unit) == 0 { return false }
        }
    }
    return true
}

let mluTagType = TagTypeHandler(
    signature: cmsSigMultiLocalizedUnicodeType,
    read: readMLU, write: writeMLU,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsMLUdup(
            UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsMLU.self))
        ))
    },
    free: { _, object in cmsMLUfree(object.assumingMemoryBound(to: cmsMLU.self)) }
)

// -- the legacy description type ----------------------------------------------

/// `desc`: what a version 2 profile keeps a description in — the same
/// text three times over, as ASCII, as UTF-16, and as a Macintosh
/// ScriptCode block that has been dead long enough that the reference
/// writes zeroes into it and skips it on the way back.
///
/// The specification admits the layout is misaligned: the Unicode
/// fields follow the ASCII text immediately, so they only land on a
/// four-byte boundary when the ASCII length happens to be a multiple of
/// four.  Readers are expected to cope rather than reject, and the
/// reference pads the *tag* to length instead of the fields.
@Sendable private func readTextDescription(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var remaining = sizeOfTag
    if remaining < 4 { return nil }

    var asciiCount: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &asciiCount) == 0 { return nil }
    if asciiCount > 0x7FFFF { return nil }
    remaining -= 4
    if remaining < asciiCount { return nil }

    guard let mlu = cmsMLUalloc(context, 2), let read = io.pointee.Read else { return nil }

    guard let text = _cmsMalloc(context, asciiCount + 1) else {
        cmsMLUfree(mlu)
        return nil
    }
    if read(io, text, 1, asciiCount) != asciiCount {
        _cmsFree(context, text)
        cmsMLUfree(mlu)
        return nil
    }
    remaining -= asciiCount
    text.assumingMemoryBound(to: CChar.self)[Int(asciiCount)] = 0

    let stored = cmsMLUsetASCII(
        mlu, cmsNoLanguage, cmsNoCountry, text.assumingMemoryBound(to: CChar.self)
    )
    _cmsFree(context, text)
    if stored == 0 {
        cmsMLUfree(mlu)
        return nil
    }

    // From here everything is best-effort: profiles in the wild stop
    // early, and this type also appears nested inside others, so a short
    // tag yields the ASCII alone rather than nothing.
    func done() -> UnsafeMutableRawPointer? {
        items = 1
        return UnsafeMutableRawPointer(mlu)
    }

    if remaining < 8 { return done() }
    var unicodeCode: cmsUInt32Number = 0
    var unicodeCount: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &unicodeCode) == 0 { return done() }
    if _cmsReadUInt32Number(io, &unicodeCount) == 0 { return done() }
    remaining -= 8

    if unicodeCount == 0 || unicodeCount > 0x7FFFF || remaining < unicodeCount * 2 {
        return done()
    }

    var wide = [UInt16](repeating: 0, count: Int(unicodeCount))
    let readWide = wide.withUnsafeMutableBufferPointer { buffer -> Bool in
        for i in 0..<buffer.count {
            var unit: cmsUInt16Number = 0
            if _cmsReadUInt16Number(io, &unit) == 0 { return false }
            buffer[i] = unit
        }
        return true
    }
    if !readWide { return done() }

    // Stored under the marker pair version 2 uses for its one Unicode
    // string, which is not a real language and country.
    _ = mluBox(mlu).mlu.set(
        wide,
        language: LocaleCode(rawValue: v2UnicodeCode),
        country: LocaleCode(rawValue: v2UnicodeCode)
    )
    remaining -= unicodeCount * 2

    // The ScriptCode block, read only to step over it.
    if remaining >= 2 + 1 + 67 {
        var scriptCode: cmsUInt16Number = 0
        var scriptCount: cmsUInt8Number = 0
        if _cmsReadUInt16Number(io, &scriptCode) == 0 { return done() }
        if _cmsReadUInt8Number(io, &scriptCount) == 0 { return done() }
        var skip: cmsUInt8Number = 0
        for _ in 0..<67 where read(io, &skip, 1, 1) == 0 { return done() }
    }

    return done()
}

@Sendable private func writeTextDescription(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let mlu = object.assumingMemoryBound(to: cmsMLU.self)

    // The ASCII text decides every length here, including the Unicode
    // one — the two are written the same number of characters long
    // whatever the wide string actually holds.
    let reported = cmsMLUgetASCII(mlu, cmsNoLanguage, cmsNoCountry, nil, 0)

    var ascii = [CChar](repeating: 0, count: Int(max(reported, 1)))
    var wide = [UInt16](repeating: 0, count: Int(max(reported, 1)))
    if reported > 0 {
        _ = ascii.withUnsafeMutableBufferPointer { buffer in
            cmsMLUgetASCII(mlu, cmsNoLanguage, cmsNoCountry, buffer.baseAddress, reported)
        }
        if let translation = mluBox(mlu).mlu.lookup(
            language: LocaleCode(rawValue: v2UnicodeCode),
            country: LocaleCode(rawValue: v2UnicodeCode)
        ) {
            for (i, unit) in translation.text.prefix(wide.count).enumerated() { wide[i] = unit }
        }
    }

    // The stored length is the text up to its terminator, plus it.
    var textLength = 0
    while textLength < ascii.count && ascii[textLength] != 0 { textLength += 1 }
    let length = cmsUInt32Number(textLength + 1)

    // 8 for the type base, then the three blocks and the dead one.
    let required = 8 + 4 + length + 4 + 4 + 2 * length + 2 + 1 + 67
    let aligned = ICCField.alignedLength(required)

    if _cmsWriteUInt32Number(io, length) == 0 { return false }
    let wroteAscii = ascii.withUnsafeBufferPointer { buffer in
        write(io, length, buffer.baseAddress)
    }
    if wroteAscii == 0 { return false }

    if _cmsWriteUInt32Number(io, 0) == 0 { return false }        // language code
    if _cmsWriteUInt32Number(io, length) == 0 { return false }
    for i in 0..<Int(length) {
        let unit = i < wide.count ? wide[i] : 0
        if _cmsWriteUInt16Number(io, unit) == 0 { return false }
    }

    if _cmsWriteUInt16Number(io, 0) == 0 { return false }         // ScriptCode code
    if _cmsWriteUInt8Number(io, 0) == 0 { return false }          // ScriptCode count

    var filler = [UInt8](repeating: 0, count: 68)
    let wroteFiller = filler.withUnsafeMutableBufferPointer { buffer in
        write(io, 67, buffer.baseAddress)
    }
    if wroteFiller == 0 { return false }

    if aligned > required {
        let padded = filler.withUnsafeMutableBufferPointer { buffer in
            write(io, aligned - required, buffer.baseAddress)
        }
        if padded == 0 { return false }
    }
    return true
}

/// `cmsV2Unicode`, the marker pair a version 2 description files its one
/// wide string under.  The header spells it `"\xff\xff"`, so it is not a
/// language and country at all — it is two bytes chosen not to collide
/// with one.
private let v2UnicodeCode: UInt16 = 0xFFFF

let textDescriptionTagType = TagTypeHandler(
    signature: cmsSigTextDescriptionType,
    read: readTextDescription, write: writeTextDescription,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsMLUdup(
            UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsMLU.self))
        ))
    },
    free: { _, object in cmsMLUfree(object.assumingMemoryBound(to: cmsMLU.self)) }
)
