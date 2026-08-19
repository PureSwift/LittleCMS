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
    /// Reads one object, reporting how many elements it found.  Only a
    /// plugin's reader looks at `version`; the built-in ones read the
    /// same bytes whatever the profile claims.
    let read: @Sendable (
        _ context: cmsContext?,
        _ io: UnsafeMutablePointer<cmsIOHANDLER>,
        _ items: inout cmsUInt32Number,
        _ sizeOfTag: cmsUInt32Number,
        _ version: cmsUInt32Number
    ) -> UnsafeMutableRawPointer?
    /// `version` is the profile's encoded ICC version.  Only the types
    /// that embed another type need it — a profile sequence writes its
    /// descriptions in whichever text form the version calls for — but
    /// it has to be threaded to all of them to reach those.
    let write: @Sendable (
        _ context: cmsContext?,
        _ io: UnsafeMutablePointer<cmsIOHANDLER>,
        _ object: UnsafeMutableRawPointer,
        _ items: cmsUInt32Number,
        _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    cmsContext?, UnsafeMutablePointer<cmsIOHANDLER>, inout cmsUInt32Number, cmsUInt32Number, cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    { context, io, items, sizeOfTag, _ in
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
            cmsUInt32Number, cmsUInt32Number
        ) -> UnsafeMutableRawPointer?,
        write: @escaping @Sendable (
            cmsContext?, UnsafeMutablePointer<cmsIOHANDLER>, UnsafeMutableRawPointer,
            cmsUInt32Number, cmsUInt32Number
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
        write: { _, io, object, _, _ in
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

    // The three plain integer arrays: no built-in tag is stored as one,
    // but a plugin's tag may be, and a profile may carry one.  As many
    // elements as the tag's length holds.
    add(
        cmsSigUInt8ArrayType,
        read: { context, io, items, sizeOfTag, _ in
            items = 0
            let n = sizeOfTag
            guard let raw = _cmsCalloc(context, n, 1) else { return nil }
            let values = raw.assumingMemoryBound(to: cmsUInt8Number.self)
            for i in 0..<Int(n) where _cmsReadUInt8Number(io, values + i) == 0 {
                _cmsFree(context, raw)
                return nil
            }
            items = n
            return raw
        },
        write: { _, io, object, n, _ in
            let values = object.assumingMemoryBound(to: cmsUInt8Number.self)
            for i in 0..<Int(n) where _cmsWriteUInt8Number(io, values[i]) == 0 { return false }
            return true
        },
        duplicate: dupArray(cmsUInt8Number.self)
    )

    add(
        cmsSigUInt32ArrayType,
        read: { context, io, items, sizeOfTag, _ in
            items = 0
            let n = sizeOfTag / 4
            guard let raw = _cmsCalloc(context, n, 4) else { return nil }
            let values = raw.assumingMemoryBound(to: cmsUInt32Number.self)
            for i in 0..<Int(n) where _cmsReadUInt32Number(io, values + i) == 0 {
                _cmsFree(context, raw)
                return nil
            }
            items = n
            return raw
        },
        write: { _, io, object, n, _ in
            let values = object.assumingMemoryBound(to: cmsUInt32Number.self)
            for i in 0..<Int(n) where _cmsWriteUInt32Number(io, values[i]) == 0 { return false }
            return true
        },
        duplicate: dupArray(cmsUInt32Number.self)
    )

    add(
        cmsSigUInt64ArrayType,
        read: { context, io, items, sizeOfTag, _ in
            items = 0
            let n = sizeOfTag / 8
            guard let raw = _cmsCalloc(context, n, 8) else { return nil }
            let values = raw.assumingMemoryBound(to: cmsUInt64Number.self)
            for i in 0..<Int(n) where _cmsReadUInt64Number(io, values + i) == 0 {
                _cmsFree(context, raw)
                return nil
            }
            items = n
            return raw
        },
        write: { _, io, object, n, _ in
            let values = object.assumingMemoryBound(to: cmsUInt64Number.self)
            for i in 0..<Int(n) where _cmsWriteUInt64Number(io, values + i) == 0 { return false }
            return true
        },
        duplicate: dupArray(cmsUInt64Number.self)
    )

    add(
        cmsSigS15Fixed16ArrayType,
        read: readFixedArray { io, slot in _cmsRead15Fixed16Number(io, slot) != 0 },
        write: { _, io, object, n, _ in
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
        write: { _, io, object, n, _ in
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
        write: { _, io, object, _, _ in
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
    table[cmsSigLut8Type] = lut8TagType
    table[cmsSigLut16Type] = lut16TagType
    table[cmsSigLutAtoBType] = lutAtoBTagType
    table[cmsSigLutBtoAType] = lutBtoATagType
    table.merge(structuralTagTypes) { existing, _ in existing }
    table[cmsSigNamedColor2Type] = namedColorTagType
    table[cmsSigVcgtType] = vcgtTagType
    table[cmsSigDictType] = dictionaryTagType
    table[cmsSigProfileSequenceDescType] = profileSequenceTagType
    table[cmsSigProfileSequenceIdType] = profileSequenceIDTagType
    table.merge(printingTagTypes) { existing, _ in existing }
    table.merge(remainingTagTypes) { existing, _ in existing }
    table[cmsSigMultiProcessElementType] = mpeTagType

    return table
}()

/// The serializer for a type: a plugin's if one is registered on the
/// context, else the built-in one.
func tagTypeHandler(for signature: cmsTagTypeSignature, context: cmsContext?) -> TagTypeHandler? {
    if let plugin = PluginRegistry.resolve(context).tagType(for: signature) { return plugin }
    return tagTypeHandlers[signature]
}

/// Whether a tag may be stored as this type.  A tag the library does not
/// know refuses everything, which is how an unknown tag is reported.
func isTypeSupported(_ sig: cmsTagSignature, _ type: cmsTagTypeSignature, context: cmsContext?) -> Bool {
    guard let descriptor = tagDescriptor(for: sig, context: context) else { return false }
    return descriptor.supportedTypes.contains(type)
}

/// Which type a tag is written as.  A descriptor that carries a decision
/// function is asked -- the profile version and the object both matter,
/// because a curve that cannot be expressed parametrically is written as
/// a table even on a version that would prefer the parametric form.
func typeToWrite(
    for sig: cmsTagSignature, version: cmsFloat64Number, data: UnsafeRawPointer, context: cmsContext?
) -> cmsTagTypeSignature? {
    guard let descriptor = tagDescriptor(for: sig, context: context) else { return nil }
    if let decide = descriptor.decide { return decide(version, data) }
    return descriptor.supportedTypes.first
}

// -- the curve types ---------------------------------------------------------

/// `curv`: a count, then either nothing (linear), one 8.8 gamma, or that
/// many 16-bit table entries.  So the same type spells three different
/// things and the count is what distinguishes them.
@Sendable private func readCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
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
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
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

// -- the 8-bit LUT type --------------------------------------------------------

/// `uipow`: `n * a^b`, or the all-ones marker if that overflows.  This is
/// what stops a malformed profile claiming a table larger than any file.
private func tableSize(
    _ outputs: cmsUInt32Number, _ points: cmsUInt32Number, _ inputs: cmsUInt32Number
) -> cmsUInt32Number? {
    if points == 0 || outputs == 0 { return 0 }
    var result: cmsUInt32Number = 1
    for _ in 0..<inputs {
        result = result &* points
        if result > cmsUInt32Number.max / points { return nil }
    }
    let total = result &* outputs
    if result != total / outputs { return nil }
    return total
}

@inline(__always) private func from8To16(_ v: UInt8) -> cmsUInt16Number {
    cmsUInt16Number(v) << 8 | cmsUInt16Number(v)
}

@inline(__always) private func from16To8(_ v: cmsUInt16Number) -> UInt8 {
    UInt8(truncatingIfNeeded: (cmsUInt32Number(v) &* 65281 &+ 8_388_608) >> 24)
}

/// Reads `channels` tables of 256 bytes each and inserts them as one
/// tone-curve stage.  The curves are freed here: the stage copies them.
private func read8BitTables(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ lut: UnsafeMutablePointer<cmsPipeline>, _ channels: cmsUInt32Number
) -> Bool {
    if channels == 0 || channels > cmsUInt32Number(cmsMAXCHANNELS) { return false }
    guard let read = io.pointee.Read else { return false }

    var tables = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: Int(channels))
    defer { for t in tables { cmsFreeToneCurve(t) } }

    for i in 0..<Int(channels) {
        guard let curve = cmsBuildTabulatedToneCurve16(context, 256, nil) else { return false }
        tables[i] = curve
    }

    var bytes = [UInt8](repeating: 0, count: 256)
    for i in 0..<Int(channels) {
        let got = bytes.withUnsafeMutableBufferPointer { buffer in
            read(io, buffer.baseAddress, 256, 1)
        }
        if got != 1 { return false }
        guard let table = tables[i]?.pointee.Table16 else { return false }
        for j in 0..<256 { table[j] = from8To16(bytes[j]) }
    }

    guard let stage = cmsStageAllocToneCurves(context, channels, &tables) else { return false }
    return cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0
}

/// Writes `channels` tables of 256 bytes.  A missing stage writes
/// nothing at all, and an identity ramp is written as the identity
/// rather than sampled — the reference recognises it by its shape.
private func write8BitTables(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ channels: cmsUInt32Number, _ tables: UnsafeMutablePointer<_cmsStageToneCurvesData>?
) -> Bool {
    guard let tables, let curves = tables.pointee.TheCurves else { return true }

    for i in 0..<Int(channels) {
        guard let curve = curves[i], let table = curve.pointee.Table16 else { return false }

        if curve.pointee.nEntries == 2 && table[0] == 0 && table[1] == 65535 {
            for j in 0..<256 {
                if _cmsWriteUInt8Number(io, UInt8(j)) == 0 { return false }
            }
            continue
        }
        // Anything else has to already be 256 entries: this type has no
        // room to say how long its tables are.
        if curve.pointee.nEntries != 256 {
            report(
                cmsUInt32Number(cmsERROR_RANGE),
                "LUT8 needs 256 entries on prelinearization", to: context
            )
            return false
        }
        for j in 0..<256 {
            if _cmsWriteUInt8Number(io, from16To8(table[j])) == 0 { return false }
        }
    }
    return true
}

/// `mft1`: a matrix, input curves, a CLUT and output curves, in that
/// order, assembled into a pipeline.  Everything is eight bits wide on
/// disk and widened on the way in, so a value that was 0xFF becomes
/// 0xFFFF rather than 0xFF00 — the byte is replicated, not shifted.
@Sendable private func readLUT8(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var inputs: cmsUInt8Number = 0
    var outputs: cmsUInt8Number = 0
    var points: cmsUInt8Number = 0
    if _cmsReadUInt8Number(io, &inputs) == 0 { return nil }
    if _cmsReadUInt8Number(io, &outputs) == 0 { return nil }
    if _cmsReadUInt8Number(io, &points) == 0 { return nil }
    // One grid point cannot be interpolated; zero means no CLUT at all.
    if points == 1 { return nil }
    if _cmsReadUInt8Number(io, nil) == 0 { return nil }   // padding

    if inputs == 0 || cmsUInt32Number(inputs) > cmsUInt32Number(cmsMAXCHANNELS) { return nil }
    if outputs == 0 || cmsUInt32Number(outputs) > cmsUInt32Number(cmsMAXCHANNELS) { return nil }

    guard let lut = cmsPipelineAlloc(context, cmsUInt32Number(inputs), cmsUInt32Number(outputs))
    else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsPipelineFree(lut)
        return nil
    }

    var matrix = [cmsFloat64Number](repeating: 0, count: 9)
    for i in 0..<9 where _cmsRead15Fixed16Number(io, &matrix[i]) == 0 { return fail() }

    // The matrix is only meaningful for three inputs, and an identity
    // one is dropped rather than carried as a stage that does nothing.
    if inputs == 3 {
        let isIdentity = matrix.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: cmsMAT3.self, capacity: 1) {
                _cmsMAT3isIdentity($0) != 0
            }
        }
        if !isIdentity {
            guard let stage = cmsStageAllocMatrix(context, 3, 3, matrix, nil),
                  cmsPipelineInsertStage(lut, cmsAT_BEGIN, stage) != 0
            else { return fail() }
        }
    }

    if !read8BitTables(context, io, lut, cmsUInt32Number(inputs)) { return fail() }

    guard let entries = tableSize(
        cmsUInt32Number(outputs), cmsUInt32Number(points), cmsUInt32Number(inputs)
    ) else { return fail() }

    if entries > 0 {
        guard let widened = _cmsCalloc(context, entries, 2),
              let bytes = _cmsMalloc(context, entries),
              let read = io.pointee.Read
        else { return fail() }
        defer {
            _cmsFree(context, widened)
            _cmsFree(context, bytes)
        }

        if read(io, bytes, entries, 1) != 1 { return fail() }
        let source = bytes.assumingMemoryBound(to: UInt8.self)
        let table = widened.assumingMemoryBound(to: cmsUInt16Number.self)
        for i in 0..<Int(entries) { table[i] = from8To16(source[i]) }

        guard let stage = cmsStageAllocCLut16bit(
            context, cmsUInt32Number(points), cmsUInt32Number(inputs),
            cmsUInt32Number(outputs), table
        ), cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0 else { return fail() }
    }

    if !read8BitTables(context, io, lut, cmsUInt32Number(outputs)) { return fail() }

    items = 1
    return UnsafeMutableRawPointer(lut)
}

/// Taking the pipeline apart again.  The four stages must appear in this
/// order and nothing else may be present — a pipeline that has been
/// optimized or extended cannot be spelled in this type.
private struct DisassembledLUT {
    var matrix: UnsafeMutablePointer<_cmsStageMatrixData>?
    var input: UnsafeMutablePointer<_cmsStageToneCurvesData>?
    var clut: UnsafeMutablePointer<_cmsStageCLutData>?
    var output: UnsafeMutablePointer<_cmsStageToneCurvesData>?
}

private func disassemble(
    _ lut: UnsafeMutablePointer<cmsPipeline>, _ context: cmsContext?, as name: StaticString
) -> DisassembledLUT? {
    var parts = DisassembledLUT()
    var stage = cmsPipelineGetPtrToFirstStage(lut)

    if stage == nil {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "empty \(name) is not supported", to: context
        )
        return nil
    }

    if let s = stage, cmsStageType(s) == cmsSigMatrixElemType {
        if cmsStageInputChannels(s) != 3 || cmsStageOutputChannels(s) != 3 { return nil }
        parts.matrix = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageMatrixData.self)
        stage = cmsStageNext(s)
    }
    if let s = stage, cmsStageType(s) == cmsSigCurveSetElemType {
        parts.input = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self)
        stage = cmsStageNext(s)
    }
    if let s = stage, cmsStageType(s) == cmsSigCLutElemType {
        parts.clut = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageCLutData.self)
        stage = cmsStageNext(s)
    }
    if let s = stage, cmsStageType(s) == cmsSigCurveSetElemType {
        parts.output = cmsStageData(s)?.assumingMemoryBound(to: _cmsStageToneCurvesData.self)
        stage = cmsStageNext(s)
    }

    if stage != nil {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "LUT is not suitable to be saved as \(name)", to: context
        )
        return nil
    }
    return parts
}

/// The grid must be square: this type stores one node count for every
/// dimension, so a granular CLUT cannot be written as one.
private func uniformGridPoints(
    _ parts: DisassembledLUT, _ lut: UnsafeMutablePointer<cmsPipeline>, _ context: cmsContext?
) -> cmsUInt32Number? {
    guard let clut = parts.clut, let params = clut.pointee.Params else { return 0 }
    return withUnsafeBytes(of: params.pointee.nSamples) { raw -> cmsUInt32Number? in
        let samples = raw.bindMemory(to: cmsUInt32Number.self)
        let points = samples[0]
        for i in 1..<Int(cmsPipelineInputChannels(lut)) where samples[i] != points {
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "LUT with different samples per dimension not suitable to be saved as LUT16",
                to: context
            )
            return nil
        }
        return points
    }
}

@Sendable private func writeLUT8(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let lut = object.assumingMemoryBound(to: cmsPipeline.self)
    guard let parts = disassemble(lut, context, as: "LUT8"),
          let points = uniformGridPoints(parts, lut, context)
    else { return false }

    let inputs = cmsPipelineInputChannels(lut)
    let outputs = cmsPipelineOutputChannels(lut)

    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: inputs)) == 0 { return false }
    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: outputs)) == 0 { return false }
    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: points)) == 0 { return false }
    if _cmsWriteUInt8Number(io, 0) == 0 { return false }   // padding

    // No matrix stage means the identity is written out: the field is
    // not optional in the format.
    if let matrix = parts.matrix, let values = matrix.pointee.Double {
        for i in 0..<9 where _cmsWrite15Fixed16Number(io, values[i]) == 0 { return false }
    } else {
        let identity: [cmsFloat64Number] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for v in identity where _cmsWrite15Fixed16Number(io, v) == 0 { return false }
    }

    if !write8BitTables(context, io, inputs, parts.input) { return false }

    guard let entries = tableSize(outputs, points, inputs) else { return false }
    if entries > 0, let clut = parts.clut, let table = clut.pointee.Tab.T {
        for i in 0..<Int(entries) {
            if _cmsWriteUInt8Number(io, from16To8(table[i])) == 0 { return false }
        }
    }

    return write8BitTables(context, io, outputs, parts.output)
}

let lut8TagType = TagTypeHandler(
    signature: cmsSigLut8Type,
    read: readLUT8, write: writeLUT8,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsPipelineDup(pointer.assumingMemoryBound(to: cmsPipeline.self)))
    },
    free: { _, object in cmsPipelineFree(object.assumingMemoryBound(to: cmsPipeline.self)) }
)

// -- the 16-bit LUT type --------------------------------------------------------

/// Unlike the 8-bit form, this one says how long its curve tables are —
/// so they need not be 256 entries, and an empty table (zero entries) is
/// a Little CMS extension meaning "no stage at all".
private func read16BitTables(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ lut: UnsafeMutablePointer<cmsPipeline>,
    _ channels: cmsUInt32Number, _ entries: cmsUInt32Number
) -> Bool {
    if entries == 0 { return true }
    // One entry cannot be interpolated, and a huge count is a malformed
    // profile rather than a large one.
    if entries < 2 { return false }
    if channels > cmsUInt32Number(cmsMAXCHANNELS) { return false }

    var tables = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: Int(channels))
    defer { for t in tables { cmsFreeToneCurve(t) } }

    for i in 0..<Int(channels) {
        guard let curve = cmsBuildTabulatedToneCurve16(context, entries, nil) else { return false }
        tables[i] = curve
        if _cmsReadUInt16Array(io, entries, curve.pointee.Table16) == 0 { return false }
    }

    // Inserted even when it is the identity: recognising that is the
    // optimizer's job, not the reader's.
    guard let stage = cmsStageAllocToneCurves(context, channels, &tables) else { return false }
    return cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0
}

@Sendable private func readLUT16(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var inputs: cmsUInt8Number = 0
    var outputs: cmsUInt8Number = 0
    var points: cmsUInt8Number = 0
    if _cmsReadUInt8Number(io, &inputs) == 0 { return nil }
    if _cmsReadUInt8Number(io, &outputs) == 0 { return nil }
    if _cmsReadUInt8Number(io, &points) == 0 { return nil }
    if _cmsReadUInt8Number(io, nil) == 0 { return nil }   // padding

    if inputs == 0 || cmsUInt32Number(inputs) > cmsUInt32Number(cmsMAXCHANNELS) { return nil }
    if outputs == 0 || cmsUInt32Number(outputs) > cmsUInt32Number(cmsMAXCHANNELS) { return nil }

    guard let lut = cmsPipelineAlloc(context, cmsUInt32Number(inputs), cmsUInt32Number(outputs))
    else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsPipelineFree(lut)
        return nil
    }

    var matrix = [cmsFloat64Number](repeating: 0, count: 9)
    for i in 0..<9 where _cmsRead15Fixed16Number(io, &matrix[i]) == 0 { return fail() }

    if inputs == 3 {
        let isIdentity = matrix.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: cmsMAT3.self, capacity: 1) {
                _cmsMAT3isIdentity($0) != 0
            }
        }
        if !isIdentity {
            guard let stage = cmsStageAllocMatrix(context, 3, 3, matrix, nil),
                  cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0
            else { return fail() }
        }
    }

    var inputEntries: cmsUInt16Number = 0
    var outputEntries: cmsUInt16Number = 0
    if _cmsReadUInt16Number(io, &inputEntries) == 0 { return fail() }
    if _cmsReadUInt16Number(io, &outputEntries) == 0 { return fail() }
    if inputEntries > 0x7FFF || outputEntries > 0x7FFF { return fail() }
    if points == 1 { return fail() }

    if !read16BitTables(
        context, io, lut, cmsUInt32Number(inputs), cmsUInt32Number(inputEntries)
    ) { return fail() }

    guard let entries = tableSize(
        cmsUInt32Number(outputs), cmsUInt32Number(points), cmsUInt32Number(inputs)
    ) else { return fail() }

    if entries > 0 {
        guard let raw = _cmsCalloc(context, entries, 2) else { return fail() }
        defer { _cmsFree(context, raw) }
        let table = raw.assumingMemoryBound(to: cmsUInt16Number.self)
        if _cmsReadUInt16Array(io, entries, table) == 0 { return fail() }

        guard let stage = cmsStageAllocCLut16bit(
            context, cmsUInt32Number(points), cmsUInt32Number(inputs),
            cmsUInt32Number(outputs), table
        ), cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0 else { return fail() }
    }

    if !read16BitTables(
        context, io, lut, cmsUInt32Number(outputs), cmsUInt32Number(outputEntries)
    ) { return fail() }

    items = 1
    return UnsafeMutableRawPointer(lut)
}

@Sendable private func writeLUT16(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let lut = object.assumingMemoryBound(to: cmsPipeline.self)
    guard let parts = disassemble(lut, context, as: "LUT16"),
          let points = uniformGridPoints(parts, lut, context)
    else { return false }

    let inputs = cmsPipelineInputChannels(lut)
    let outputs = cmsPipelineOutputChannels(lut)

    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: inputs)) == 0 { return false }
    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: outputs)) == 0 { return false }
    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: points)) == 0 { return false }
    if _cmsWriteUInt8Number(io, 0) == 0 { return false }   // padding

    if let matrix = parts.matrix, let values = matrix.pointee.Double {
        for i in 0..<9 where _cmsWrite15Fixed16Number(io, values[i]) == 0 { return false }
    } else {
        let identity: [cmsFloat64Number] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for v in identity where _cmsWrite15Fixed16Number(io, v) == 0 { return false }
    }

    // Table lengths come from the first curve of each set; a missing set
    // is written as the two-entry ramp that means the identity.
    func entryCount(_ set: UnsafeMutablePointer<_cmsStageToneCurvesData>?) -> cmsUInt16Number {
        guard let set, let curves = set.pointee.TheCurves, let first = curves[0]
        else { return 2 }
        return cmsUInt16Number(truncatingIfNeeded: first.pointee.nEntries)
    }
    if _cmsWriteUInt16Number(io, entryCount(parts.input)) == 0 { return false }
    if _cmsWriteUInt16Number(io, entryCount(parts.output)) == 0 { return false }

    func writeTables(
        _ set: UnsafeMutablePointer<_cmsStageToneCurvesData>?, _ channels: cmsUInt32Number
    ) -> Bool {
        guard let set, let curves = set.pointee.TheCurves else {
            for _ in 0..<Int(channels) {
                if _cmsWriteUInt16Number(io, 0) == 0 { return false }
                if _cmsWriteUInt16Number(io, 0xFFFF) == 0 { return false }
            }
            return true
        }
        for i in 0..<Int(set.pointee.nCurves) {
            guard let curve = curves[i], let table = curve.pointee.Table16 else { return false }
            for j in 0..<Int(curve.pointee.nEntries) {
                if _cmsWriteUInt16Number(io, table[j]) == 0 { return false }
            }
        }
        return true
    }

    if !writeTables(parts.input, inputs) { return false }

    guard let entries = tableSize(outputs, points, inputs) else { return false }
    if entries > 0, let clut = parts.clut, let table = clut.pointee.Tab.T {
        if _cmsWriteUInt16Array(io, entries, table) == 0 { return false }
    }

    return writeTables(parts.output, outputs)
}

let lut16TagType = TagTypeHandler(
    signature: cmsSigLut16Type,
    read: readLUT16, write: writeLUT16,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsPipelineDup(pointer.assumingMemoryBound(to: cmsPipeline.self)))
    },
    free: { _, object in cmsPipelineFree(object.assumingMemoryBound(to: cmsPipeline.self)) }
)

// -- the v4 LUT types -----------------------------------------------------------

// mAB and mBA store five optional elements, each at its own offset from
// the start of the tag, so any of them may be absent and they may sit in
// any order in the file.  The pipeline they build is always in the
// order the name says: A, CLUT, M, matrix, B going one way, and B,
// matrix, M, CLUT, A coming back.
//
// Every offset is measured from the tag base, which is eight bytes
// before the point where a type handler starts reading — the type
// signature and its reserved word have already been consumed.

private let tagBaseSize = cmsUInt32Number(MemoryLayout<_cmsTagBase>.size)

/// A curve stored inline, as either of the two curve types.
private func readEmbeddedCurve(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>
) -> UnsafeMutablePointer<cmsToneCurve>? {
    let base = _cmsReadTypeBase(io)
    var items: cmsUInt32Number = 0
    switch base {
    case cmsSigCurveType:
        return readCurve(context, io, &items, 0, 0)?.assumingMemoryBound(to: cmsToneCurve.self)
    case cmsSigParametricCurveType:
        return readParametricCurve(context, io, &items, 0, 0)?
            .assumingMemoryBound(to: cmsToneCurve.self)
    default:
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown curve type '\(signatureText(base.rawValue))'", to: context
        )
        return nil
    }
}

private func readSetOfCurves(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ offset: cmsUInt32Number, _ count: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    if count > cmsUInt32Number(cmsMAXCHANNELS) { return nil }
    guard let seek = io.pointee.Seek, seek(io, offset) != 0 else { return nil }

    var curves = [UnsafeMutablePointer<cmsToneCurve>?](repeating: nil, count: Int(count))
    // Freed unconditionally: the stage copies them, and on failure they
    // are all that was built.
    defer { for c in curves { cmsFreeToneCurve(c) } }

    for i in 0..<Int(count) {
        guard let curve = readEmbeddedCurve(context, io) else { return nil }
        curves[i] = curve
        // Each curve is padded to a four-byte boundary.
        if _cmsReadAlignment(io) == 0 { return nil }
    }
    return cmsStageAllocToneCurves(context, count, &curves)
}

private func readEmbeddedMatrix(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>, _ offset: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    guard let seek = io.pointee.Seek, seek(io, offset) != 0 else { return nil }
    var matrix = [cmsFloat64Number](repeating: 0, count: 9)
    var offsets = [cmsFloat64Number](repeating: 0, count: 3)
    for i in 0..<9 where _cmsRead15Fixed16Number(io, &matrix[i]) == 0 { return nil }
    // Unlike the v2 forms, this one always carries an offset vector.
    for i in 0..<3 where _cmsRead15Fixed16Number(io, &offsets[i]) == 0 { return nil }
    return cmsStageAllocMatrix(context, 3, 3, matrix, offsets)
}

/// The grid here is granular — a node count per dimension — and the
/// samples are one or two bytes wide, said by a precision byte.
private func readEmbeddedCLUT(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ offset: cmsUInt32Number, _ inputs: cmsUInt32Number, _ outputs: cmsUInt32Number
) -> UnsafeMutablePointer<cmsStage>? {
    guard let seek = io.pointee.Seek, seek(io, offset) != 0,
          let read = io.pointee.Read
    else { return nil }

    var packed = [UInt8](repeating: 0, count: Int(cmsMAXCHANNELS))
    let got = packed.withUnsafeMutableBufferPointer { buffer in
        read(io, buffer.baseAddress, cmsUInt32Number(cmsMAXCHANNELS), 1)
    }
    if got != 1 { return nil }

    var points = [cmsUInt32Number](repeating: 0, count: Int(cmsMAXCHANNELS))
    for i in 0..<Int(cmsMAXCHANNELS) {
        if packed[i] == 1 { return nil }   // cannot interpolate one node
        points[i] = cmsUInt32Number(packed[i])
    }

    var precision: cmsUInt8Number = 0
    if _cmsReadUInt8Number(io, &precision) == 0 { return nil }
    for _ in 0..<3 where _cmsReadUInt8Number(io, nil) == 0 { return nil }

    guard let clut = cmsStageAllocCLut16bitGranular(context, points, inputs, outputs, nil)
    else { return nil }
    guard let data = cmsStageData(clut)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let table = data.pointee.Tab.T
    else {
        cmsStageFree(clut)
        return nil
    }

    switch precision {
    case 1:
        for i in 0..<Int(data.pointee.nEntries) {
            var byte: UInt8 = 0
            if read(io, &byte, 1, 1) != 1 {
                cmsStageFree(clut)
                return nil
            }
            table[i] = from8To16(byte)
        }
    case 2:
        if _cmsReadUInt16Array(io, data.pointee.nEntries, table) == 0 {
            cmsStageFree(clut)
            return nil
        }
    default:
        cmsStageFree(clut)
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown precision of '\(precision)'", to: context
        )
        return nil
    }
    return clut
}

/// The five offsets, in the order the directory stores them.
private struct ElementOffsets {
    var b: cmsUInt32Number = 0
    var matrix: cmsUInt32Number = 0
    var m: cmsUInt32Number = 0
    var clut: cmsUInt32Number = 0
    var a: cmsUInt32Number = 0
}

private func readElementDirectory(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>
) -> (inputs: cmsUInt8Number, outputs: cmsUInt8Number, offsets: ElementOffsets)? {
    var inputs: cmsUInt8Number = 0
    var outputs: cmsUInt8Number = 0
    if _cmsReadUInt8Number(io, &inputs) == 0 { return nil }
    if _cmsReadUInt8Number(io, &outputs) == 0 { return nil }
    if _cmsReadUInt16Number(io, nil) == 0 { return nil }   // padding

    var offsets = ElementOffsets()
    if _cmsReadUInt32Number(io, &offsets.b) == 0 { return nil }
    if _cmsReadUInt32Number(io, &offsets.matrix) == 0 { return nil }
    if _cmsReadUInt32Number(io, &offsets.m) == 0 { return nil }
    if _cmsReadUInt32Number(io, &offsets.clut) == 0 { return nil }
    if _cmsReadUInt32Number(io, &offsets.a) == 0 { return nil }

    // Note the bound: unlike the v2 forms this one refuses the maximum
    // itself rather than allowing it.
    if inputs == 0 || cmsUInt32Number(inputs) >= cmsUInt32Number(cmsMAXCHANNELS) { return nil }
    if outputs == 0 || cmsUInt32Number(outputs) >= cmsUInt32Number(cmsMAXCHANNELS) { return nil }
    return (inputs, outputs, offsets)
}

@Sendable private func readLUTAtoB(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let tell = io.pointee.Tell else { return nil }
    let base = tell(io) - tagBaseSize

    guard let (inputs, outputs, offsets) = readElementDirectory(io) else { return nil }
    guard let lut = cmsPipelineAlloc(context, cmsUInt32Number(inputs), cmsUInt32Number(outputs))
    else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsPipelineFree(lut)
        return nil
    }
    func add(_ stage: UnsafeMutablePointer<cmsStage>?) -> Bool {
        cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0
    }

    // A curves take the input width, everything after the CLUT takes
    // the output width.
    if offsets.a != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.a, cmsUInt32Number(inputs)))
        else { return fail() }
    }
    if offsets.clut != 0 {
        guard add(readEmbeddedCLUT(
            context, io, base + offsets.clut,
            cmsUInt32Number(inputs), cmsUInt32Number(outputs)
        )) else { return fail() }
    }
    if offsets.m != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.m, cmsUInt32Number(outputs)))
        else { return fail() }
    }
    if offsets.matrix != 0 {
        guard add(readEmbeddedMatrix(context, io, base + offsets.matrix)) else { return fail() }
    }
    if offsets.b != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.b, cmsUInt32Number(outputs)))
        else { return fail() }
    }

    items = 1
    return UnsafeMutableRawPointer(lut)
}

@Sendable private func readLUTBtoA(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let tell = io.pointee.Tell else { return nil }
    let base = tell(io) - tagBaseSize

    guard let (inputs, outputs, offsets) = readElementDirectory(io) else { return nil }
    guard let lut = cmsPipelineAlloc(context, cmsUInt32Number(inputs), cmsUInt32Number(outputs))
    else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsPipelineFree(lut)
        return nil
    }
    func add(_ stage: UnsafeMutablePointer<cmsStage>?) -> Bool {
        cmsPipelineInsertStage(lut, cmsAT_END, stage) != 0
    }

    // Reversed: B first, and everything before the CLUT is input-wide.
    if offsets.b != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.b, cmsUInt32Number(inputs)))
        else { return fail() }
    }
    if offsets.matrix != 0 {
        guard add(readEmbeddedMatrix(context, io, base + offsets.matrix)) else { return fail() }
    }
    if offsets.m != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.m, cmsUInt32Number(inputs)))
        else { return fail() }
    }
    if offsets.clut != 0 {
        guard add(readEmbeddedCLUT(
            context, io, base + offsets.clut,
            cmsUInt32Number(inputs), cmsUInt32Number(outputs)
        )) else { return fail() }
    }
    if offsets.a != 0 {
        guard add(readSetOfCurves(context, io, base + offsets.a, cmsUInt32Number(outputs)))
        else { return fail() }
    }

    items = 1
    return UnsafeMutableRawPointer(lut)
}

/// A curve set, each curve written as whichever of the two curve types
/// can actually hold it.  A tabulated or inverted curve falls back to
/// the table form even on a version 4 profile, because the parametric
/// form has no way to spell either.
private func writeSetOfCurves(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ stage: UnsafeMutablePointer<cmsStage>
) -> Bool {
    guard let data = cmsStageData(stage)?
        .assumingMemoryBound(to: _cmsStageToneCurvesData.self),
        let curves = data.pointee.TheCurves
    else { return false }

    for i in 0..<Int(cmsStageOutputChannels(stage)) {
        guard let curve = curves[i] else { return false }

        var type = cmsSigParametricCurveType
        let segments = curve.pointee.Segments
        if curve.pointee.nSegments == 0 {
            type = cmsSigCurveType                       // 16-bit tabulated
        } else if curve.pointee.nSegments == 3, let segments, segments[1].Type == 0 {
            type = cmsSigCurveType                       // floating-point tabulated
        } else if let segments, segments[0].Type < 0 {
            type = cmsSigCurveType                       // inverted
        }

        if _cmsWriteTypeBase(io, type) == 0 { return false }
        let object = UnsafeMutableRawPointer(curve)
        let ok = type == cmsSigCurveType
            ? writeCurve(context, io, object, 1, 0)
            : writeParametricCurve(context, io, object, 1, 0)
        if !ok { return false }
        if _cmsWriteAlignment(io) == 0 { return false }
    }
    return true
}

private func writeEmbeddedMatrix(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>, _ stage: UnsafeMutablePointer<cmsStage>
) -> Bool {
    guard let data = cmsStageData(stage)?.assumingMemoryBound(to: _cmsStageMatrixData.self),
          let values = data.pointee.Double
    else { return false }

    let elements = Int(cmsStageInputChannels(stage)) * Int(cmsStageOutputChannels(stage))
    for i in 0..<elements where _cmsWrite15Fixed16Number(io, values[i]) == 0 { return false }

    // The offset vector is not optional here: a stage without one
    // writes zeroes rather than nothing.
    for i in 0..<Int(cmsStageOutputChannels(stage)) {
        let offset = data.pointee.Offset.map { $0[i] } ?? 0
        if _cmsWrite15Fixed16Number(io, offset) == 0 { return false }
    }
    return true
}

private func writeEmbeddedCLUT(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ precision: cmsUInt8Number, _ stage: UnsafeMutablePointer<cmsStage>
) -> Bool {
    guard let data = cmsStageData(stage)?.assumingMemoryBound(to: _cmsStageCLutData.self),
          let params = data.pointee.Params, let write = io.pointee.Write
    else { return false }

    if data.pointee.HasFloatValues != 0 {
        report(
            cmsUInt32Number(cmsERROR_NOT_SUITABLE),
            "Cannot save floating point data, CLUT are 8 or 16 bit only", to: context
        )
        return false
    }

    // The grid is a full-width array of bytes, zero past the inputs.
    var points = [UInt8](repeating: 0, count: Int(cmsMAXCHANNELS))
    withUnsafeBytes(of: params.pointee.nSamples) { raw in
        let samples = raw.bindMemory(to: cmsUInt32Number.self)
        for i in 0..<Int(params.pointee.nInputs) {
            points[i] = UInt8(truncatingIfNeeded: samples[i])
        }
    }
    let wrote = points.withUnsafeBufferPointer { buffer in
        write(io, cmsUInt32Number(cmsMAXCHANNELS), buffer.baseAddress)
    }
    if wrote == 0 { return false }

    if _cmsWriteUInt8Number(io, precision) == 0 { return false }
    for _ in 0..<3 where _cmsWriteUInt8Number(io, 0) == 0 { return false }

    guard let table = data.pointee.Tab.T else { return false }
    switch precision {
    case 1:
        for i in 0..<Int(data.pointee.nEntries) {
            if _cmsWriteUInt8Number(io, from16To8(table[i])) == 0 { return false }
        }
    case 2:
        if _cmsWriteUInt16Array(io, data.pointee.nEntries, table) == 0 { return false }
    default:
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown precision of '\(precision)'", to: context
        )
        return false
    }
    return _cmsWriteAlignment(io) != 0
}

/// The four layouts either type accepts, tried in turn.  Nothing is
/// filled in unless a whole shape matches, which is what makes trying
/// them one after another safe.
private struct LUTElements {
    var a: UnsafeMutablePointer<cmsStage>?
    var clut: UnsafeMutablePointer<cmsStage>?
    var m: UnsafeMutablePointer<cmsStage>?
    var matrix: UnsafeMutablePointer<cmsStage>?
    var b: UnsafeMutablePointer<cmsStage>?
}

/// Writes the header, the elements, and then goes back and fills in the
/// directory — the offsets are not knowable until the elements have
/// been laid down.
private func writeElementDirectory(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ lut: UnsafeMutablePointer<cmsPipeline>, _ parts: LUTElements,
    order: [WritableElement]
) -> Bool {
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek else { return false }
    let base = tell(io) - tagBaseSize

    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: cmsPipelineInputChannels(lut))) == 0 {
        return false
    }
    if _cmsWriteUInt8Number(io, UInt8(truncatingIfNeeded: cmsPipelineOutputChannels(lut))) == 0 {
        return false
    }
    if _cmsWriteUInt16Number(io, 0) == 0 { return false }

    let directory = tell(io)
    for _ in 0..<5 where _cmsWriteUInt32Number(io, 0) == 0 { return false }

    var offsets = ElementOffsets()
    let precision: cmsUInt8Number = pipelineSavesAs8Bits(UnsafeRawPointer(lut)) ? 1 : 2

    for element in order {
        switch element {
        case .a:
            guard let stage = parts.a else { continue }
            offsets.a = tell(io) - base
            if !writeSetOfCurves(context, io, stage) { return false }
        case .clut:
            guard let stage = parts.clut else { continue }
            offsets.clut = tell(io) - base
            if !writeEmbeddedCLUT(context, io, precision, stage) { return false }
        case .m:
            guard let stage = parts.m else { continue }
            offsets.m = tell(io) - base
            if !writeSetOfCurves(context, io, stage) { return false }
        case .matrix:
            guard let stage = parts.matrix else { continue }
            offsets.matrix = tell(io) - base
            if !writeEmbeddedMatrix(io, stage) { return false }
        case .b:
            guard let stage = parts.b else { continue }
            offsets.b = tell(io) - base
            if !writeSetOfCurves(context, io, stage) { return false }
        }
    }

    let end = tell(io)
    if seek(io, directory) == 0 { return false }
    for value in [offsets.b, offsets.matrix, offsets.m, offsets.clut, offsets.a]
    where _cmsWriteUInt32Number(io, value) == 0 { return false }
    return seek(io, end) != 0
}

private enum WritableElement { case a, clut, m, matrix, b }

/// Whether the pipeline's stages are exactly these types in this order,
/// and if so the stages themselves.
///
/// This is what `cmsPipelineCheckAndRetreiveStages` does for a C client.
/// Swift cannot call a C variadic at all, and does not need to: the
/// matching is a comparison over the chain, and doing it here keeps the
/// answer in Swift types rather than out-parameters.
private func matchStages(
    _ lut: UnsafeMutablePointer<cmsPipeline>, _ types: [cmsStageSignature]
) -> [UnsafeMutablePointer<cmsStage>]? {
    if Int(cmsPipelineStageCount(lut)) != types.count { return nil }

    var found: [UnsafeMutablePointer<cmsStage>] = []
    var stage = cmsPipelineGetPtrToFirstStage(lut)
    for type in types {
        guard let s = stage, cmsStageType(s) == type else { return nil }
        found.append(s)
        stage = cmsStageNext(s)
    }
    return found
}

/// Tries the four shapes this type accepts, in the reference's order.
/// Nothing is assigned unless a whole shape matches, which is what makes
/// trying them one after another safe.
private func matchShapes(
    _ lut: UnsafeMutablePointer<cmsPipeline>, forwards: Bool
) -> LUTElements? {
    var parts = LUTElements()
    let curves = cmsSigCurveSetElemType
    let matrix = cmsSigMatrixElemType
    let clut = cmsSigCLutElemType

    // An empty pipeline is accepted and writes no elements at all.
    if cmsPipelineStageCount(lut) == 0 { return parts }

    if let m = matchStages(lut, [curves]) {
        parts.b = m[0]
        return parts
    }

    if forwards {
        // M, matrix, B
        if let m = matchStages(lut, [curves, matrix, curves]) {
            parts.m = m[0]; parts.matrix = m[1]; parts.b = m[2]
            return parts
        }
        // A, CLUT, B
        if let m = matchStages(lut, [curves, clut, curves]) {
            parts.a = m[0]; parts.clut = m[1]; parts.b = m[2]
            return parts
        }
        // A, CLUT, M, matrix, B
        if let m = matchStages(lut, [curves, clut, curves, matrix, curves]) {
            parts.a = m[0]; parts.clut = m[1]; parts.m = m[2]
            parts.matrix = m[3]; parts.b = m[4]
            return parts
        }
    } else {
        // B, matrix, M
        if let m = matchStages(lut, [curves, matrix, curves]) {
            parts.b = m[0]; parts.matrix = m[1]; parts.m = m[2]
            return parts
        }
        // B, CLUT, A
        if let m = matchStages(lut, [curves, clut, curves]) {
            parts.b = m[0]; parts.clut = m[1]; parts.a = m[2]
            return parts
        }
        // B, matrix, M, CLUT, A
        if let m = matchStages(lut, [curves, matrix, curves, clut, curves]) {
            parts.b = m[0]; parts.matrix = m[1]; parts.m = m[2]
            parts.clut = m[3]; parts.a = m[4]
            return parts
        }
    }
    return nil
}

@Sendable private func writeLUTAtoB(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let lut = object.assumingMemoryBound(to: cmsPipeline.self)
    guard let parts = matchShapes(lut, forwards: true) else {
        report(
            cmsUInt32Number(cmsERROR_NOT_SUITABLE),
            "LUT is not suitable to be saved as LutAToB", to: context
        )
        return false
    }
    return writeElementDirectory(
        context, io, lut, parts, order: [.a, .clut, .m, .matrix, .b]
    )
}

@Sendable private func writeLUTBtoA(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let lut = object.assumingMemoryBound(to: cmsPipeline.self)
    guard let parts = matchShapes(lut, forwards: false) else {
        report(
            cmsUInt32Number(cmsERROR_NOT_SUITABLE),
            "LUT is not suitable to be saved as LutBToA", to: context
        )
        return false
    }
    return writeElementDirectory(
        context, io, lut, parts, order: [.a, .clut, .m, .matrix, .b]
    )
}

private let pipelineDuplicate: @Sendable (cmsContext?, UnsafeRawPointer, cmsUInt32Number)
    -> UnsafeMutableRawPointer? = { _, pointer, _ in
        UnsafeMutableRawPointer(cmsPipelineDup(pointer.assumingMemoryBound(to: cmsPipeline.self)))
    }
private let pipelineFree: @Sendable (cmsContext?, UnsafeMutableRawPointer) -> Void = { _, object in
    cmsPipelineFree(object.assumingMemoryBound(to: cmsPipeline.self))
}

let lutAtoBTagType = TagTypeHandler(
    signature: cmsSigLutAtoBType, read: readLUTAtoB, write: writeLUTAtoB,
    duplicate: pipelineDuplicate, free: pipelineFree
)

let lutBtoATagType = TagTypeHandler(
    signature: cmsSigLutBtoAType, read: readLUTBtoA, write: writeLUTBtoA,
    duplicate: pipelineDuplicate, free: pipelineFree
)

// -- the measurement and viewing-condition structs -------------------------------

@Sendable private func readMeasurement(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var mc = cmsICCMeasurementConditions()
    if _cmsReadUInt32Number(io, &mc.Observer) == 0 { return nil }
    if _cmsReadXYZNumber(io, &mc.Backing) == 0 { return nil }
    if _cmsReadUInt32Number(io, &mc.Geometry) == 0 { return nil }
    if _cmsRead15Fixed16Number(io, &mc.Flare) == 0 { return nil }
    if _cmsReadUInt32Number(io, &mc.IlluminantType) == 0 { return nil }
    items = 1
    return _cmsDupMem(
        context, &mc, cmsUInt32Number(MemoryLayout<cmsICCMeasurementConditions>.size)
    )
}

@Sendable private func writeMeasurement(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let mc = object.assumingMemoryBound(to: cmsICCMeasurementConditions.self)
    if _cmsWriteUInt32Number(io, mc.pointee.Observer) == 0 { return false }
    if _cmsWriteXYZNumber(io, &mc.pointee.Backing) == 0 { return false }
    if _cmsWriteUInt32Number(io, mc.pointee.Geometry) == 0 { return false }
    if _cmsWrite15Fixed16Number(io, mc.pointee.Flare) == 0 { return false }
    return _cmsWriteUInt32Number(io, mc.pointee.IlluminantType) != 0
}

@Sendable private func readViewingConditions(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMallocZero(
        context, cmsUInt32Number(MemoryLayout<cmsICCViewingConditions>.size)
    ) else { return nil }
    let vc = raw.assumingMemoryBound(to: cmsICCViewingConditions.self)

    func fail() -> UnsafeMutableRawPointer? {
        _cmsFree(context, raw)
        return nil
    }
    if _cmsReadXYZNumber(io, &vc.pointee.IlluminantXYZ) == 0 { return fail() }
    if _cmsReadXYZNumber(io, &vc.pointee.SurroundXYZ) == 0 { return fail() }
    if _cmsReadUInt32Number(io, &vc.pointee.IlluminantType) == 0 { return fail() }
    items = 1
    return raw
}

@Sendable private func writeViewingConditions(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let vc = object.assumingMemoryBound(to: cmsICCViewingConditions.self)
    if _cmsWriteXYZNumber(io, &vc.pointee.IlluminantXYZ) == 0 { return false }
    if _cmsWriteXYZNumber(io, &vc.pointee.SurroundXYZ) == 0 { return false }
    return _cmsWriteUInt32Number(io, vc.pointee.IlluminantType) != 0
}

/// `cicp`: four bytes naming a video signal, and nothing else — a tag of
/// any other length is refused rather than read short.
@Sendable private func readVideoSignal(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    if sizeOfTag != 4 { return nil }
    guard let raw = _cmsCalloc(
        context, 1, cmsUInt32Number(MemoryLayout<cmsVideoSignalType>.size)
    ) else { return nil }
    let cicp = raw.assumingMemoryBound(to: cmsVideoSignalType.self)

    func fail() -> UnsafeMutableRawPointer? {
        _cmsFree(context, raw)
        return nil
    }
    if _cmsReadUInt8Number(io, &cicp.pointee.ColourPrimaries) == 0 { return fail() }
    if _cmsReadUInt8Number(io, &cicp.pointee.TransferCharacteristics) == 0 { return fail() }
    if _cmsReadUInt8Number(io, &cicp.pointee.MatrixCoefficients) == 0 { return fail() }
    if _cmsReadUInt8Number(io, &cicp.pointee.VideoFullRangeFlag) == 0 { return fail() }
    items = 1
    return raw
}

@Sendable private func writeVideoSignal(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let cicp = object.assumingMemoryBound(to: cmsVideoSignalType.self)
    if _cmsWriteUInt8Number(io, cicp.pointee.ColourPrimaries) == 0 { return false }
    if _cmsWriteUInt8Number(io, cicp.pointee.TransferCharacteristics) == 0 { return false }
    if _cmsWriteUInt8Number(io, cicp.pointee.MatrixCoefficients) == 0 { return false }
    return _cmsWriteUInt8Number(io, cicp.pointee.VideoFullRangeFlag) != 0
}

/// `clrt`: a colorant table, which is a named-colour list where each
/// entry carries a 32-byte name and its PCS coordinates and nothing
/// else.  The name is truncated at 32 bytes on the way out, so a longer
/// one set through the named-colour API does not survive a save.
@Sendable private func readColorantTable(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var count: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    if count > cmsUInt32Number(cmsMAXCHANNELS) {
        report(cmsUInt32Number(cmsERROR_RANGE), "Too many colorants '\(count)'", to: context)
        return nil
    }

    guard let list = cmsAllocNamedColorList(context, count, 0, "", ""),
          let read = io.pointee.Read
    else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsFreeNamedColorList(list)
        return nil
    }

    var name = [CChar](repeating: 0, count: 34)
    var pcs = [cmsUInt16Number](repeating: 0, count: 3)
    for _ in 0..<Int(count) {
        let got = name.withUnsafeMutableBufferPointer { buffer in
            read(io, buffer.baseAddress, 32, 1)
        }
        if got != 1 { return fail() }
        name[32] = 0
        if _cmsReadUInt16Array(io, 3, &pcs) == 0 { return fail() }
        if cmsAppendNamedColor(list, &name, &pcs, nil) == 0 { return fail() }
    }

    items = 1
    return UnsafeMutableRawPointer(list)
}

@Sendable private func writeColorantTable(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let list = object.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
    let count = cmsNamedColorCount(list)

    if _cmsWriteUInt32Number(io, count) == 0 { return false }

    for i in 0..<count {
        var name = [CChar](repeating: 0, count: Int(cmsMAX_PATH))
        var pcs = [cmsUInt16Number](repeating: 0, count: 3)
        if cmsNamedColorInfo(list, i, &name, nil, nil, &pcs, nil) == 0 { return false }
        name[32] = 0

        let wrote = name.withUnsafeBufferPointer { buffer in
            write(io, 32, buffer.baseAddress)
        }
        if wrote == 0 { return false }
        if _cmsWriteUInt16Array(io, 3, &pcs) == 0 { return false }
    }
    return true
}

let structuralTagTypes: [cmsTagTypeSignature: TagTypeHandler] = [
    cmsSigMeasurementType: TagTypeHandler(
        signature: cmsSigMeasurementType,
        read: readMeasurement, write: writeMeasurement,
        duplicate: { context, pointer, _ in
            _cmsDupMem(
                context, pointer,
                cmsUInt32Number(MemoryLayout<cmsICCMeasurementConditions>.size)
            )
        },
        free: freePlainBlock
    ),
    cmsSigViewingConditionsType: TagTypeHandler(
        signature: cmsSigViewingConditionsType,
        read: readViewingConditions, write: writeViewingConditions,
        duplicate: { context, pointer, _ in
            _cmsDupMem(
                context, pointer, cmsUInt32Number(MemoryLayout<cmsICCViewingConditions>.size)
            )
        },
        free: freePlainBlock
    ),
    cmsSigcicpType: TagTypeHandler(
        signature: cmsSigcicpType,
        read: readVideoSignal, write: writeVideoSignal,
        duplicate: { context, pointer, _ in
            _cmsDupMem(context, pointer, cmsUInt32Number(MemoryLayout<cmsVideoSignalType>.size))
        },
        free: freePlainBlock
    ),
    cmsSigColorantTableType: TagTypeHandler(
        signature: cmsSigColorantTableType,
        read: readColorantTable, write: writeColorantTable,
        duplicate: { _, pointer, _ in
            UnsafeMutableRawPointer(cmsDupNamedColorList(
                UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self))
            ))
        },
        free: { _, object in
            cmsFreeNamedColorList(object.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self))
        }
    ),
]

// -- the named-colour type --------------------------------------------------------

/// `ncl2`: a list-wide prefix and suffix, then one entry per colour with
/// a 32-byte root name, its PCS coordinates and its device colorants.
///
/// The name a client sees is prefix + root + suffix, but only the root
/// is stored per entry — which is why every colour in a list shares the
/// other two.  All three are cut to 32 bytes.
@Sendable private func readNamedColor(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var vendorFlag: cmsUInt32Number = 0
    var count: cmsUInt32Number = 0
    var coordinates: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &vendorFlag) == 0 { return nil }
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    if _cmsReadUInt32Number(io, &coordinates) == 0 { return nil }

    guard let read = io.pointee.Read else { return nil }
    var prefix = [CChar](repeating: 0, count: 33)
    var suffix = [CChar](repeating: 0, count: 33)
    let gotPrefix = prefix.withUnsafeMutableBufferPointer { read(io, $0.baseAddress, 32, 1) }
    if gotPrefix != 1 { return nil }
    let gotSuffix = suffix.withUnsafeMutableBufferPointer { read(io, $0.baseAddress, 32, 1) }
    if gotSuffix != 1 { return nil }
    prefix[31] = 0
    suffix[31] = 0

    guard let list = cmsAllocNamedColorList(context, count, coordinates, &prefix, &suffix)
    else {
        report(cmsUInt32Number(cmsERROR_RANGE), "Too many named colors '\(count)'", to: context)
        return nil
    }

    func fail() -> UnsafeMutableRawPointer? {
        cmsFreeNamedColorList(list)
        return nil
    }

    if coordinates > cmsUInt32Number(cmsMAXCHANNELS) {
        report(
            cmsUInt32Number(cmsERROR_RANGE),
            "Too many device coordinates '\(coordinates)'", to: context
        )
        return fail()
    }

    var root = [CChar](repeating: 0, count: 33)
    var pcs = [cmsUInt16Number](repeating: 0, count: 3)
    var colorant = [cmsUInt16Number](repeating: 0, count: Int(cmsMAXCHANNELS))
    for _ in 0..<Int(count) {
        for i in 0..<colorant.count { colorant[i] = 0 }
        let got = root.withUnsafeMutableBufferPointer { read(io, $0.baseAddress, 32, 1) }
        if got != 1 { return fail() }
        root[32] = 0   // a name that fills the field is still terminated

        if _cmsReadUInt16Array(io, 3, &pcs) == 0 { return fail() }
        if coordinates > 0, _cmsReadUInt16Array(io, coordinates, &colorant) == 0 { return fail() }
        if cmsAppendNamedColor(list, &root, &pcs, &colorant) == 0 { return fail() }
    }

    items = 1
    return UnsafeMutableRawPointer(list)
}

@Sendable private func writeNamedColor(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let list = object.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
    let box = namedColorBox(list)
    let count = cmsNamedColorCount(list)
    let coordinates = cmsUInt32Number(box.list.colorantCount)

    // The vendor flag is always written as zero: nothing sets it.
    if _cmsWriteUInt32Number(io, 0) == 0 { return false }
    if _cmsWriteUInt32Number(io, count) == 0 { return false }
    if _cmsWriteUInt32Number(io, coordinates) == 0 { return false }

    func writeFixed(_ bytes: [UInt8]) -> Bool {
        var field = [UInt8](repeating: 0, count: 32)
        for i in 0..<min(32, bytes.count) { field[i] = bytes[i] }
        return field.withUnsafeBufferPointer { write(io, 32, $0.baseAddress) } != 0
    }
    if !writeFixed(box.list.prefix) { return false }
    if !writeFixed(box.list.suffix) { return false }

    for i in 0..<count {
        var root = [CChar](repeating: 0, count: Int(cmsMAX_PATH))
        var pcs = [cmsUInt16Number](repeating: 0, count: 3)
        var colorant = [cmsUInt16Number](repeating: 0, count: Int(cmsMAXCHANNELS))
        if cmsNamedColorInfo(list, i, &root, nil, nil, &pcs, &colorant) == 0 { return false }
        root[32] = 0

        let wrote = root.withUnsafeBufferPointer { write(io, 32, $0.baseAddress) }
        if wrote == 0 { return false }
        if _cmsWriteUInt16Array(io, 3, &pcs) == 0 { return false }
        if coordinates > 0, _cmsWriteUInt16Array(io, coordinates, &colorant) == 0 { return false }
    }
    return true
}

let namedColorTagType = TagTypeHandler(
    signature: cmsSigNamedColor2Type,
    read: readNamedColor, write: writeNamedColor,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsDupNamedColorList(
            UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self))
        ))
    },
    free: { _, object in
        cmsFreeNamedColorList(object.assumingMemoryBound(to: cmsNAMEDCOLORLIST.self))
    }
)

// -- the video card gamma type ----------------------------------------------------

/// `vcgt` comes in two flavours and is handed to the caller as three
/// tone curves either way — an array of three `cmsToneCurve*`, not a
/// single object, which is the only tag type shaped like that.
///
/// The flavour codes are private to the reference's cmstypes.c and
/// appear in no header.
private let vcgtTableFlavour: cmsUInt32Number = 0
private let vcgtFormulaFlavour: cmsUInt32Number = 1

@Sendable private func readVCGT(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var flavour: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &flavour) == 0 { return nil }

    guard let raw = _cmsCalloc(
        context, 3, cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsToneCurve>?>.stride)
    ) else { return nil }
    let curves = raw.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)

    func fail() -> UnsafeMutableRawPointer? {
        for i in 0..<3 { cmsFreeToneCurve(curves[i]) }
        _cmsFree(context, raw)
        return nil
    }

    switch flavour {
    case vcgtTableFlavour:
        var channels: cmsUInt16Number = 0
        var elements: cmsUInt16Number = 0
        var bytes: cmsUInt16Number = 0
        if _cmsReadUInt16Number(io, &channels) == 0 { return fail() }
        if channels != 3 {
            report(
                cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                "Unsupported number of channels for VCGT '\(channels)'", to: context
            )
            return fail()
        }
        if _cmsReadUInt16Number(io, &elements) == 0 { return fail() }
        if _cmsReadUInt16Number(io, &bytes) == 0 { return fail() }

        // Adobe once wrote a one-byte depth for what is plainly a
        // two-byte table; the tag's own length gives it away.
        if elements == 256 && bytes == 1 && sizeOfTag == 1576 { bytes = 2 }

        for n in 0..<3 {
            guard let curve = cmsBuildTabulatedToneCurve16(
                context, cmsUInt32Number(elements), nil
            ) else { return fail() }
            curves[n] = curve
            guard let table = curve.pointee.Table16 else { return fail() }

            switch bytes {
            case 1:
                for i in 0..<Int(elements) {
                    var v: cmsUInt8Number = 0
                    if _cmsReadUInt8Number(io, &v) == 0 { return fail() }
                    table[i] = from8To16(v)
                }
            case 2:
                if _cmsReadUInt16Array(io, cmsUInt32Number(elements), table) == 0 {
                    return fail()
                }
            default:
                report(
                    cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
                    "Unsupported bit depth for VCGT '\(Int(bytes) * 8)'", to: context
                )
                return fail()
            }
        }

    case vcgtFormulaFlavour:
        // The stored form is Y = (Max - Min) * X^Gamma + Min, which is
        // parametric type 5 with most of its parameters zero.
        for n in 0..<3 {
            var gamma: cmsFloat64Number = 0
            var minimum: cmsFloat64Number = 0
            var maximum: cmsFloat64Number = 0
            if _cmsRead15Fixed16Number(io, &gamma) == 0 { return fail() }
            if _cmsRead15Fixed16Number(io, &minimum) == 0 { return fail() }
            if _cmsRead15Fixed16Number(io, &maximum) == 0 { return fail() }

            var params = [cmsFloat64Number](repeating: 0, count: 10)
            params[0] = gamma
            params[1] = pow(maximum - minimum, 1.0 / gamma)
            params[5] = minimum

            guard let curve = cmsBuildParametricToneCurve(context, 5, &params)
            else { return fail() }
            curves[n] = curve
        }

    default:
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unsupported tag type for VCGT '\(flavour)'", to: context
        )
        return fail()
    }

    items = 1
    return raw
}

@Sendable private func writeVCGT(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let curves = object.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)

    // The formula form is used only when all three curves are that
    // exact parametric shape; anything else is sampled into a table.
    let allFormula = (0..<3).allSatisfy { cmsGetToneCurveParametricType(curves[$0]) == 5 }

    if allFormula {
        if _cmsWriteUInt32Number(io, vcgtFormulaFlavour) == 0 { return false }
        for i in 0..<3 {
            guard let segments = curves[i]?.pointee.Segments else { return false }
            let (gamma, minimum, maximum) = withUnsafeBytes(of: segments[0].Params) { raw -> (Double, Double, Double) in
                let p = raw.bindMemory(to: cmsFloat64Number.self)
                let g = p[0]
                let low = p[5]
                return (g, low, pow(p[1], g) + low)
            }
            if _cmsWrite15Fixed16Number(io, gamma) == 0 { return false }
            if _cmsWrite15Fixed16Number(io, minimum) == 0 { return false }
            if _cmsWrite15Fixed16Number(io, maximum) == 0 { return false }
        }
        return true
    }

    // Always 256 words, whatever the curves actually hold.
    if _cmsWriteUInt32Number(io, vcgtTableFlavour) == 0 { return false }
    if _cmsWriteUInt16Number(io, 3) == 0 { return false }
    if _cmsWriteUInt16Number(io, 256) == 0 { return false }
    if _cmsWriteUInt16Number(io, 2) == 0 { return false }

    for i in 0..<3 {
        for j in 0..<256 {
            let x = cmsFloat32Number(cmsFloat64Number(j) / 255.0)
            let v = cmsEvalToneCurveFloat(curves[i], x)
            if _cmsWriteUInt16Number(
                io, quickSaturateWord(cmsFloat64Number(v) * 65535.0)
            ) == 0 { return false }
        }
    }
    return true
}

let vcgtTagType = TagTypeHandler(
    signature: cmsSigVcgtType,
    read: readVCGT, write: writeVCGT,
    duplicate: { context, pointer, _ in
        let source = pointer.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)
        guard let raw = _cmsCalloc(
            context, 3, cmsUInt32Number(MemoryLayout<UnsafeMutablePointer<cmsToneCurve>?>.stride)
        ) else { return nil }
        let copy = raw.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)
        for i in 0..<3 {
            guard let one = cmsDupToneCurve(source[i]) else {
                for j in 0..<i { cmsFreeToneCurve(copy[j]) }
                _cmsFree(context, raw)
                return nil
            }
            copy[i] = one
        }
        return raw
    },
    free: { context, object in
        let curves = object.assumingMemoryBound(to: UnsafeMutablePointer<cmsToneCurve>?.self)
        for i in 0..<3 { cmsFreeToneCurve(curves[i]) }
        _cmsFree(context, object)
    }
)

// -- the dictionary type ------------------------------------------------------

// `meta` is a directory of fixed-width records followed by the data they
// point at.  A record is always a name and a value, and optionally a
// display name and a display value, so the record length says which of
// the four columns are present: 16, 24 or 32 bytes.
//
// An offset of zero does not mean "the start of the tag" — it means the
// string is absent, which the ICC proposal that introduced this type
// spells out.  So a dictionary can carry a key with no value.
//
// Strings on disk are UTF-16; `wchar_t` is four bytes on the platforms
// this builds for, so both directions convert rather than copy.

private struct DictionaryColumn {
    var offsets: [cmsUInt32Number]
    var sizes: [cmsUInt32Number]

    init(count: Int) {
        offsets = [cmsUInt32Number](repeating: 0, count: count)
        sizes = [cmsUInt32Number](repeating: 0, count: count)
    }
}

private func readOneElement(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>, _ column: inout DictionaryColumn,
    _ i: Int, _ base: cmsUInt32Number
) -> Bool {
    var offset: cmsUInt32Number = 0
    var size: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &offset) == 0 { return false }
    if _cmsReadUInt32Number(io, &size) == 0 { return false }
    // Zero stays zero: it is the marker, not a position.
    column.offsets[i] = offset == 0 ? 0 : offset + base
    column.sizes[i] = size
    return true
}

private func readOneWideString(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ column: DictionaryColumn, _ i: Int
) -> UnsafeMutablePointer<wchar_t>?? {
    if column.offsets[i] == 0 { return .some(nil) }   // absent, and that is not a failure
    guard let seek = io.pointee.Seek, seek(io, column.offsets[i]) != 0 else { return nil }

    let characters = Int(column.sizes[i]) / 2
    if characters > 0x7FFFF { return nil }

    guard let raw = _cmsMallocZero(
        context, cmsUInt32Number((characters + 1) * MemoryLayout<wchar_t>.stride)
    ) else { return nil }
    let string = raw.assumingMemoryBound(to: wchar_t.self)

    for k in 0..<characters {
        var unit: cmsUInt16Number = 0
        if _cmsReadUInt16Number(io, &unit) == 0 {
            _cmsFree(context, raw)
            return nil
        }
        string[k] = wchar_t(unit)
    }
    string[characters] = 0
    return .some(string)
}

private func readOneMLU(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ column: DictionaryColumn, _ i: Int
) -> UnsafeMutablePointer<cmsMLU>?? {
    if column.offsets[i] == 0 || column.sizes[i] == 0 { return .some(nil) }
    guard let seek = io.pointee.Seek, seek(io, column.offsets[i]) != 0 else { return nil }

    var items: cmsUInt32Number = 0
    guard let raw = readMLU(context, io, &items, column.sizes[i], 0) else { return nil }
    return .some(raw.assumingMemoryBound(to: cmsMLU.self))
}

@Sendable private func readDictionary(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let tell = io.pointee.Tell else { return nil }
    let base = tell(io) - tagBaseSize

    // Tracked as a signed count so that a claim larger than the tag is
    // caught rather than wrapping into a very large unsigned number.
    var remaining = cmsInt32Number(bitPattern: sizeOfTag)

    var count: cmsUInt32Number = 0
    var length: cmsUInt32Number = 0
    remaining -= 4
    if remaining < 0 { return nil }
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    remaining -= 4
    if remaining < 0 { return nil }
    if _cmsReadUInt32Number(io, &length) == 0 { return nil }

    if length != 16 && length != 24 && length != 32 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown record length in dictionary '\(length)'", to: context
        )
        return nil
    }

    guard let dict = cmsDictAlloc(context) else { return nil }
    func fail() -> UnsafeMutableRawPointer? {
        cmsDictFree(dict)
        return nil
    }

    let n = Int(count)
    var names = DictionaryColumn(count: n)
    var values = DictionaryColumn(count: n)
    var displayNames = DictionaryColumn(count: n)
    var displayValues = DictionaryColumn(count: n)

    for i in 0..<n {
        remaining -= 16
        if remaining < 0 { return fail() }
        if !readOneElement(io, &names, i, base) { return fail() }
        if !readOneElement(io, &values, i, base) { return fail() }

        if length > 16 {
            remaining -= 8
            if remaining < 0 { return fail() }
            if !readOneElement(io, &displayNames, i, base) { return fail() }
        }
        if length > 24 {
            remaining -= 8
            if remaining < 0 { return fail() }
            if !readOneElement(io, &displayValues, i, base) { return fail() }
        }
    }

    for i in 0..<n {
        guard let name = readOneWideString(context, io, names, i),
              let value = readOneWideString(context, io, values, i)
        else { return fail() }
        defer {
            if let name { _cmsFree(context, name) }
            if let value { _cmsFree(context, value) }
        }

        var displayName: UnsafeMutablePointer<cmsMLU>?
        var displayValue: UnsafeMutablePointer<cmsMLU>?
        if length > 16 {
            guard let read = readOneMLU(context, io, displayNames, i) else { return fail() }
            displayName = read
        }
        if length > 24 {
            guard let read = readOneMLU(context, io, displayValues, i) else { return fail() }
            displayValue = read
        }
        defer {
            cmsMLUfree(displayName)
            cmsMLUfree(displayValue)
        }

        // A record with no name or no value at all is corruption, not
        // the absent-string case the offsets encode.
        guard let name, let value else {
            report(
                cmsUInt32Number(cmsERROR_CORRUPTION_DETECTED),
                "Bad dictionary Name/Value", to: context
            )
            return fail()
        }

        if cmsDictAddEntry(dict, name, value, displayName, displayValue) == 0 {
            return fail()
        }
    }

    items = 1
    return UnsafeMutableRawPointer(dict)
}

@Sendable private func writeDictionary(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek else { return false }
    let dict = cmsHANDLE(object)
    let base = tell(io) - tagBaseSize

    // The record length is decided by what any entry carries, so one
    // entry with a display name widens every record in the tag.
    var count = 0
    var anyDisplayName = false
    var anyDisplayValue = false
    var entry = cmsDictGetEntryList(dict)
    while let e = entry {
        if e.pointee.DisplayName != nil { anyDisplayName = true }
        if e.pointee.DisplayValue != nil { anyDisplayValue = true }
        count += 1
        entry = cmsDictNextEntry(e)
    }

    var length: cmsUInt32Number = 16
    if anyDisplayName { length += 8 }
    if anyDisplayValue { length += 8 }

    if _cmsWriteUInt32Number(io, cmsUInt32Number(count)) == 0 { return false }
    if _cmsWriteUInt32Number(io, length) == 0 { return false }

    let directory = tell(io)
    var names = DictionaryColumn(count: count)
    var values = DictionaryColumn(count: count)
    var displayNames = DictionaryColumn(count: count)
    var displayValues = DictionaryColumn(count: count)

    func writeDirectory() -> Bool {
        for i in 0..<count {
            if _cmsWriteUInt32Number(io, names.offsets[i]) == 0 { return false }
            if _cmsWriteUInt32Number(io, names.sizes[i]) == 0 { return false }
            if _cmsWriteUInt32Number(io, values.offsets[i]) == 0 { return false }
            if _cmsWriteUInt32Number(io, values.sizes[i]) == 0 { return false }
            if length > 16 {
                if _cmsWriteUInt32Number(io, displayNames.offsets[i]) == 0 { return false }
                if _cmsWriteUInt32Number(io, displayNames.sizes[i]) == 0 { return false }
            }
            if length > 24 {
                if _cmsWriteUInt32Number(io, displayValues.offsets[i]) == 0 { return false }
                if _cmsWriteUInt32Number(io, displayValues.sizes[i]) == 0 { return false }
            }
        }
        return true
    }

    // A placeholder, so the data that follows lands where the real
    // offsets will say it does.
    if !writeDirectory() { return false }

    func writeWideString(
        _ column: inout DictionaryColumn, _ i: Int, _ string: UnsafeMutablePointer<wchar_t>?
    ) -> Bool {
        let before = tell(io)
        guard let string else {
            column.offsets[i] = 0
            column.sizes[i] = 0
            return true
        }
        column.offsets[i] = before - base

        var k = 0
        while string[k] != 0 { k += 1 }
        for j in 0..<k {
            let unit = cmsUInt16Number(truncatingIfNeeded: string[j])
            if _cmsWriteUInt16Number(io, unit) == 0 { return false }
        }
        column.sizes[i] = tell(io) - before
        return true
    }

    func writeDisplay(
        _ column: inout DictionaryColumn, _ i: Int, _ mlu: UnsafeMutablePointer<cmsMLU>?
    ) -> Bool {
        guard let mlu else {
            column.offsets[i] = 0
            column.sizes[i] = 0
            return true
        }
        let before = tell(io)
        column.offsets[i] = before - base
        if !writeMLU(context, io, UnsafeMutableRawPointer(mlu), 1, 0) { return false }
        column.sizes[i] = tell(io) - before
        return true
    }

    entry = cmsDictGetEntryList(dict)
    for i in 0..<count {
        guard let e = entry else { return false }
        if !writeWideString(&names, i, e.pointee.Name) { return false }
        if !writeWideString(&values, i, e.pointee.Value) { return false }
        if e.pointee.DisplayName != nil {
            if !writeDisplay(&displayNames, i, e.pointee.DisplayName) { return false }
        }
        if e.pointee.DisplayValue != nil {
            if !writeDisplay(&displayValues, i, e.pointee.DisplayValue) { return false }
        }
        entry = cmsDictNextEntry(e)
    }

    let end = tell(io)
    if seek(io, directory) == 0 { return false }
    if !writeDirectory() { return false }
    return seek(io, end) != 0
}

let dictionaryTagType = TagTypeHandler(
    signature: cmsSigDictType,
    read: readDictionary, write: writeDictionary,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsDictDup(cmsHANDLE(mutating: pointer)))
    },
    free: { _, object in cmsDictFree(cmsHANDLE(object)) }
)

// -- the profile sequence type --------------------------------------------------

/// A description embedded inside another type, which may be any of the
/// three text forms — so a sequence written by an older tool and one
/// written by a newer one both read.
private func readEmbeddedText(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ into: inout UnsafeMutablePointer<cmsMLU>?, _ sizeOfTag: cmsUInt32Number
) -> Bool {
    let base = _cmsReadTypeBase(io)
    var items: cmsUInt32Number = 0

    let read: UnsafeMutableRawPointer?
    switch base {
    case cmsSigTextType:
        read = readText(context, io, &items, sizeOfTag, 0)
    case cmsSigTextDescriptionType:
        read = readTextDescription(context, io, &items, sizeOfTag, 0)
    case cmsSigMultiLocalizedUnicodeType:
        read = readMLU(context, io, &items, sizeOfTag, 0)
    default:
        return false
    }

    guard let read else { return false }
    // The allocator gives every slot an empty container, so whatever is
    // already there is replaced rather than leaked.
    cmsMLUfree(into)
    into = read.assumingMemoryBound(to: cmsMLU.self)
    return true
}

/// Written as the flat description before version 4 and as the
/// multi-localized form from 4 on — so the same sequence changes shape
/// with the profile it is stored in.
private func saveDescription(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ version: cmsUInt32Number, _ description: UnsafeMutablePointer<cmsMLU>?
) -> Bool {
    // A slot with no description is written as an empty one rather than
    // refused: cmsAllocProfileSequenceDescription leaves all three null,
    // so a sequence that nobody filled in is the normal case.  An empty
    // container produces the same bytes either writer would for null.
    var temporary: UnsafeMutablePointer<cmsMLU>?
    defer { cmsMLUfree(temporary) }

    let text: UnsafeMutablePointer<cmsMLU>
    if let description {
        text = description
    } else {
        guard let empty = cmsMLUalloc(context, 0) else { return false }
        temporary = empty
        text = empty
    }

    if version < 0x0400_0000 {
        if _cmsWriteTypeBase(io, cmsSigTextDescriptionType) == 0 { return false }
        return writeTextDescription(context, io, UnsafeMutableRawPointer(text), 1, version)
    }
    if _cmsWriteTypeBase(io, cmsSigMultiLocalizedUnicodeType) == 0 { return false }
    return writeMLU(context, io, UnsafeMutableRawPointer(text), 1, version)
}

@Sendable private func readProfileSequence(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    var remaining = sizeOfTag

    var count: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }
    if remaining < 4 { return nil }
    remaining -= 4

    guard let sequence = cmsAllocProfileSequenceDescription(context, count) else { return nil }
    sequence.pointee.n = count

    func fail() -> UnsafeMutableRawPointer? {
        cmsFreeProfileSequenceDescription(sequence)
        return nil
    }

    guard let entries = withUnsafeMutablePointer(to: &sequence.pointee.seq, { $0 }).pointee
    else { return fail() }

    for i in 0..<Int(count) {
        let entry = entries + i
        if _cmsReadUInt32Number(io, &entry.pointee.deviceMfg) == 0 { return fail() }
        if remaining < 4 { return fail() }
        remaining -= 4

        if _cmsReadUInt32Number(io, &entry.pointee.deviceModel) == 0 { return fail() }
        if remaining < 4 { return fail() }
        remaining -= 4

        if _cmsReadUInt64Number(io, &entry.pointee.attributes) == 0 { return fail() }
        if remaining < 8 { return fail() }
        remaining -= 8

        let technology = withUnsafeMutablePointer(to: &entry.pointee.technology) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: cmsUInt32Number.self)
        }
        if _cmsReadUInt32Number(io, technology) == 0 { return fail() }
        if remaining < 4 { return fail() }
        remaining -= 4

        if !readEmbeddedText(context, io, &entry.pointee.Manufacturer, remaining) {
            return fail()
        }
        if !readEmbeddedText(context, io, &entry.pointee.Model, remaining) {
            return fail()
        }
    }

    items = 1
    return UnsafeMutableRawPointer(sequence)
}

@Sendable private func writeProfileSequence(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number, _ version: cmsUInt32Number
) -> Bool {
    let sequence = object.assumingMemoryBound(to: cmsSEQ.self)
    guard let entries = sequence.pointee.seq else { return false }

    // The version the profile is being written as decides the form the
    // embedded descriptions take.
    if _cmsWriteUInt32Number(io, sequence.pointee.n) == 0 { return false }

    for i in 0..<Int(sequence.pointee.n) {
        let entry = entries + i
        if _cmsWriteUInt32Number(io, entry.pointee.deviceMfg) == 0 { return false }
        if _cmsWriteUInt32Number(io, entry.pointee.deviceModel) == 0 { return false }
        if _cmsWriteUInt64Number(io, &entry.pointee.attributes) == 0 { return false }
        if _cmsWriteUInt32Number(io, entry.pointee.technology.rawValue) == 0 { return false }

        if !saveDescription(context, io, version, entry.pointee.Manufacturer) { return false }
        if !saveDescription(context, io, version, entry.pointee.Model) { return false }
    }
    return true
}

let profileSequenceTagType = TagTypeHandler(
    signature: cmsSigProfileSequenceDescType,
    read: readProfileSequence, write: writeProfileSequence,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsDupProfileSequenceDescription(
            UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsSEQ.self))
        ))
    },
    free: { _, object in
        cmsFreeProfileSequenceDescription(object.assumingMemoryBound(to: cmsSEQ.self))
    }
)

// -- the profile sequence identifier type ----------------------------------------

/// `psid` is the same sequence structure reached through a position
/// table: a directory of offset and size pairs, then the elements.  That
/// indirection is what lets each element be a different length, which a
/// description embedded in it certainly is.
@Sendable private func readProfileSequenceID(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek, let read = io.pointee.Read
    else { return nil }
    let base = tell(io) - tagBaseSize

    var count: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &count) == 0 { return nil }

    // The directory is two words per element; a count claiming more than
    // the file can hold is refused before anything is allocated.
    let position = tell(io)
    if (io.pointee.ReportedSize - position) / 8 < count { return nil }

    guard let sequence = cmsAllocProfileSequenceDescription(context, count) else { return nil }
    func fail() -> UnsafeMutableRawPointer? {
        cmsFreeProfileSequenceDescription(sequence)
        return nil
    }
    guard let entries = sequence.pointee.seq else { return fail() }

    var offsets = [cmsUInt32Number](repeating: 0, count: Int(count))
    var sizes = [cmsUInt32Number](repeating: 0, count: Int(count))
    for i in 0..<Int(count) {
        if _cmsReadUInt32Number(io, &offsets[i]) == 0 { return fail() }
        if _cmsReadUInt32Number(io, &sizes[i]) == 0 { return fail() }
        offsets[i] += base
    }

    for i in 0..<Int(count) {
        if seek(io, offsets[i]) == 0 { return fail() }
        let entry = entries + i

        let got = withUnsafeMutableBytes(of: &entry.pointee.ProfileID) { buffer in
            read(io, buffer.baseAddress, 16, 1)
        }
        if got != 1 { return fail() }
        if !readEmbeddedText(context, io, &entry.pointee.Description, sizes[i]) {
            return fail()
        }
    }

    items = 1
    return UnsafeMutableRawPointer(sequence)
}

@Sendable private func writeProfileSequenceID(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number,
    _ version: cmsUInt32Number
) -> Bool {
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek, let write = io.pointee.Write
    else { return false }
    let sequence = object.assumingMemoryBound(to: cmsSEQ.self)
    guard let entries = sequence.pointee.seq else { return false }

    let base = tell(io) - tagBaseSize
    let count = Int(sequence.pointee.n)

    if _cmsWriteUInt32Number(io, sequence.pointee.n) == 0 { return false }

    let directory = tell(io)
    for _ in 0..<count {
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
    }

    var offsets = [cmsUInt32Number](repeating: 0, count: count)
    var sizes = [cmsUInt32Number](repeating: 0, count: count)

    for i in 0..<count {
        let before = tell(io)
        offsets[i] = before - base
        let entry = entries + i

        let wrote = withUnsafeBytes(of: entry.pointee.ProfileID) { buffer in
            write(io, 16, buffer.baseAddress)
        }
        if wrote == 0 { return false }
        if !saveDescription(context, io, version, entry.pointee.Description) { return false }

        sizes[i] = tell(io) - before
    }

    let end = tell(io)
    if seek(io, directory) == 0 { return false }
    for i in 0..<count {
        if _cmsWriteUInt32Number(io, offsets[i]) == 0 { return false }
        if _cmsWriteUInt32Number(io, sizes[i]) == 0 { return false }
    }
    return seek(io, end) != 0
}

let profileSequenceIDTagType = TagTypeHandler(
    signature: cmsSigProfileSequenceIdType,
    read: readProfileSequenceID, write: writeProfileSequenceID,
    duplicate: { _, pointer, _ in
        UnsafeMutableRawPointer(cmsDupProfileSequenceDescription(
            UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsSEQ.self))
        ))
    },
    free: { _, object in
        cmsFreeProfileSequenceDescription(object.assumingMemoryBound(to: cmsSEQ.self))
    }
)

// -- undercolour removal and screening -------------------------------------------

/// `bfd`: two sampled curves back to back, then a description whose
/// length is whatever is left of the tag — there is no count for it, so
/// the tag's own size is the only thing that says where the text ends.
@Sendable private func readUcrBg(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsUcrBg>.size)),
          let read = io.pointee.Read
    else { return nil }
    let n = raw.assumingMemoryBound(to: cmsUcrBg.self)

    func fail() -> UnsafeMutableRawPointer? {
        cmsFreeToneCurve(n.pointee.Ucr)
        cmsFreeToneCurve(n.pointee.Bg)
        cmsMLUfree(n.pointee.Desc)
        _cmsFree(context, raw)
        return nil
    }

    var remaining = cmsInt32Number(bitPattern: sizeOfTag)

    func readCurve(
        into slot: inout UnsafeMutablePointer<cmsToneCurve>?
    ) -> Bool {
        if remaining < 4 { return false }
        var count: cmsUInt32Number = 0
        if _cmsReadUInt32Number(io, &count) == 0 { return false }
        remaining -= 4

        guard let curve = cmsBuildTabulatedToneCurve16(context, count, nil) else { return false }
        slot = curve
        if remaining < cmsInt32Number(bitPattern: count &* 2) { return false }
        if _cmsReadUInt16Array(io, count, curve.pointee.Table16) == 0 { return false }
        remaining -= cmsInt32Number(bitPattern: count &* 2)
        return true
    }

    if !readCurve(into: &n.pointee.Ucr) { return fail() }
    if !readCurve(into: &n.pointee.Bg) { return fail() }

    if remaining < 0 || remaining > 32000 { return fail() }

    guard let description = cmsMLUalloc(context, 1) else { return fail() }
    n.pointee.Desc = description

    let length = cmsUInt32Number(remaining)
    guard let text = _cmsMalloc(context, length + 1) else { return fail() }
    defer { _cmsFree(context, text) }

    if length > 0, read(io, text, 1, length) != length { return fail() }
    text.assumingMemoryBound(to: CChar.self)[Int(length)] = 0
    _ = cmsMLUsetASCII(
        description, cmsNoLanguage, cmsNoCountry, text.assumingMemoryBound(to: CChar.self)
    )

    items = 1
    return raw
}

@Sendable private func writeUcrBg(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number,
    _ version: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let value = object.assumingMemoryBound(to: cmsUcrBg.self)
    guard let ucr = value.pointee.Ucr, let bg = value.pointee.Bg else { return false }

    if _cmsWriteUInt32Number(io, ucr.pointee.nEntries) == 0 { return false }
    if _cmsWriteUInt16Array(io, ucr.pointee.nEntries, ucr.pointee.Table16) == 0 { return false }
    if _cmsWriteUInt32Number(io, bg.pointee.nEntries) == 0 { return false }
    if _cmsWriteUInt16Array(io, bg.pointee.nEntries, bg.pointee.Table16) == 0 { return false }

    // The text carries no length of its own; it simply runs to the end.
    let size = cmsMLUgetASCII(value.pointee.Desc, cmsNoLanguage, cmsNoCountry, nil, 0)
    guard let text = _cmsMalloc(context, size) else { return false }
    defer { _cmsFree(context, text) }

    let got = cmsMLUgetASCII(
        value.pointee.Desc, cmsNoLanguage, cmsNoCountry,
        text.assumingMemoryBound(to: CChar.self), size
    )
    if got != size { return false }
    return write(io, size, text) != 0
}

/// `scrn`: a flag word, a channel count, and three numbers per channel.
/// A count past the ceiling is **clamped rather than refused**, so a
/// malformed tag reads back shorter than it claimed.
@Sendable private func readScreening(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsScreening>.size))
    else { return nil }
    let sc = raw.assumingMemoryBound(to: cmsScreening.self)

    func fail() -> UnsafeMutableRawPointer? {
        _cmsFree(context, raw)
        return nil
    }

    if _cmsReadUInt32Number(io, &sc.pointee.Flag) == 0 { return fail() }
    if _cmsReadUInt32Number(io, &sc.pointee.nChannels) == 0 { return fail() }

    if sc.pointee.nChannels > cmsUInt32Number(cmsMAXCHANNELS) - 1 {
        sc.pointee.nChannels = cmsUInt32Number(cmsMAXCHANNELS) - 1
    }

    let ok = withUnsafeMutableBytes(of: &sc.pointee.Channels) { buffer -> Bool in
        let channels = buffer.baseAddress!.assumingMemoryBound(to: cmsScreeningChannel.self)
        for i in 0..<Int(sc.pointee.nChannels) {
            if _cmsRead15Fixed16Number(io, &channels[i].Frequency) == 0 { return false }
            if _cmsRead15Fixed16Number(io, &channels[i].ScreenAngle) == 0 { return false }
            if _cmsReadUInt32Number(io, &channels[i].SpotShape) == 0 { return false }
        }
        return true
    }
    if !ok { return fail() }

    items = 1
    return raw
}

@Sendable private func writeScreening(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number,
    _ version: cmsUInt32Number
) -> Bool {
    let sc = object.assumingMemoryBound(to: cmsScreening.self)
    if _cmsWriteUInt32Number(io, sc.pointee.Flag) == 0 { return false }
    if _cmsWriteUInt32Number(io, sc.pointee.nChannels) == 0 { return false }

    return withUnsafeBytes(of: sc.pointee.Channels) { buffer -> Bool in
        let channels = buffer.baseAddress!.assumingMemoryBound(to: cmsScreeningChannel.self)
        for i in 0..<Int(sc.pointee.nChannels) {
            if _cmsWrite15Fixed16Number(io, channels[i].Frequency) == 0 { return false }
            if _cmsWrite15Fixed16Number(io, channels[i].ScreenAngle) == 0 { return false }
            if _cmsWriteUInt32Number(io, channels[i].SpotShape) == 0 { return false }
        }
        return true
    }
}

let printingTagTypes: [cmsTagTypeSignature: TagTypeHandler] = [
    cmsSigUcrBgType: TagTypeHandler(
        signature: cmsSigUcrBgType, read: readUcrBg, write: writeUcrBg,
        duplicate: { context, pointer, _ in
            let source = pointer.assumingMemoryBound(to: cmsUcrBg.self)
            guard let raw = _cmsMallocZero(
                context, cmsUInt32Number(MemoryLayout<cmsUcrBg>.size)
            ) else { return nil }
            let copy = raw.assumingMemoryBound(to: cmsUcrBg.self)
            copy.pointee.Ucr = cmsDupToneCurve(source.pointee.Ucr)
            copy.pointee.Bg = cmsDupToneCurve(source.pointee.Bg)
            copy.pointee.Desc = cmsMLUdup(source.pointee.Desc)
            return raw
        },
        free: { context, object in
            let value = object.assumingMemoryBound(to: cmsUcrBg.self)
            cmsFreeToneCurve(value.pointee.Ucr)
            cmsFreeToneCurve(value.pointee.Bg)
            cmsMLUfree(value.pointee.Desc)
            _cmsFree(context, object)
        }
    ),
    cmsSigScreeningType: TagTypeHandler(
        signature: cmsSigScreeningType, read: readScreening, write: writeScreening,
        duplicate: { context, pointer, _ in
            _cmsDupMem(context, pointer, cmsUInt32Number(MemoryLayout<cmsScreening>.size))
        },
        free: freePlainBlock
    ),
]

// -- the PostScript rendering-dictionary names -----------------------------------

/// `crdi`: five counted strings, filed in one container under a made-up
/// language of `PS` and section codes for a country.  They are not
/// locales at all — the multi-localized container is being used as a
/// five-slot record.
private let crdInfoSections = ["nm", "#0", "#1", "#2", "#3"]

@Sendable private func readCrdInfo(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let mlu = cmsMLUalloc(context, 5), let read = io.pointee.Read else { return nil }

    func fail() -> UnsafeMutableRawPointer? {
        cmsMLUfree(mlu)
        return nil
    }

    var remaining = sizeOfTag
    for section in crdInfoSections {
        if remaining < 4 { return fail() }
        var count: cmsUInt32Number = 0
        if _cmsReadUInt32Number(io, &count) == 0 { return fail() }
        if count > cmsUInt32Number.max - 4 { return fail() }
        if remaining < count + 4 { return fail() }

        guard let text = _cmsMalloc(context, count + 1) else { return fail() }
        defer { _cmsFree(context, text) }

        if count > 0, read(io, text, 1, count) != count { return fail() }
        text.assumingMemoryBound(to: CChar.self)[Int(count)] = 0
        _ = cmsMLUsetASCII(mlu, "PS", section, text.assumingMemoryBound(to: CChar.self))

        remaining -= count + 4
    }

    items = 1
    return UnsafeMutableRawPointer(mlu)
}

@Sendable private func writeCrdInfo(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number,
    _ version: cmsUInt32Number
) -> Bool {
    guard let write = io.pointee.Write else { return false }
    let mlu = object.assumingMemoryBound(to: cmsMLU.self)

    for section in crdInfoSections {
        let size = cmsMLUgetASCII(mlu, "PS", section, nil, 0)
        guard let text = _cmsMalloc(context, size) else { return false }
        defer { _cmsFree(context, text) }

        if _cmsWriteUInt32Number(io, size) == 0 { return false }
        if cmsMLUgetASCII(
            mlu, "PS", section, text.assumingMemoryBound(to: CChar.self), size
        ) == 0 { return false }
        if write(io, size, text) == 0 { return false }
    }
    return true
}

// -- the HDR calibration type ------------------------------------------------------

/// `MHC2`: three curves and a 3x4 matrix, each reached through an offset
/// so the matrix can be omitted when it is the identity.  Each curve
/// block is preceded by a type signature and a filler word that the
/// reader steps over rather than checking.
@Sendable private func readMHC2(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ items: inout cmsUInt32Number, _ sizeOfTag: cmsUInt32Number, _ version: cmsUInt32Number
) -> UnsafeMutableRawPointer? {
    items = 0
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek else { return nil }
    let base = tell(io) - tagBaseSize

    guard let raw = _cmsCalloc(context, 1, cmsUInt32Number(MemoryLayout<cmsMHC2Type>.size))
    else { return nil }
    let mhc2 = raw.assumingMemoryBound(to: cmsMHC2Type.self)

    func fail() -> UnsafeMutableRawPointer? {
        _cmsFree(context, mhc2.pointee.RedCurve)
        _cmsFree(context, mhc2.pointee.GreenCurve)
        _cmsFree(context, mhc2.pointee.BlueCurve)
        _cmsFree(context, raw)
        return nil
    }

    if _cmsReadUInt32Number(io, &mhc2.pointee.CurveEntries) == 0 { return fail() }
    if mhc2.pointee.CurveEntries > 4096 { return fail() }

    let entries = mhc2.pointee.CurveEntries
    let width = cmsUInt32Number(MemoryLayout<cmsFloat64Number>.size)
    mhc2.pointee.RedCurve = _cmsCalloc(context, entries, width)?
        .assumingMemoryBound(to: cmsFloat64Number.self)
    mhc2.pointee.GreenCurve = _cmsCalloc(context, entries, width)?
        .assumingMemoryBound(to: cmsFloat64Number.self)
    mhc2.pointee.BlueCurve = _cmsCalloc(context, entries, width)?
        .assumingMemoryBound(to: cmsFloat64Number.self)
    guard mhc2.pointee.RedCurve != nil, mhc2.pointee.GreenCurve != nil,
          mhc2.pointee.BlueCurve != nil
    else { return fail() }

    if _cmsRead15Fixed16Number(io, &mhc2.pointee.MinLuminance) == 0 { return fail() }
    if _cmsRead15Fixed16Number(io, &mhc2.pointee.PeakLuminance) == 0 { return fail() }

    var matrixOffset: cmsUInt32Number = 0
    var redOffset: cmsUInt32Number = 0
    var greenOffset: cmsUInt32Number = 0
    var blueOffset: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &matrixOffset) == 0 { return fail() }
    if _cmsReadUInt32Number(io, &redOffset) == 0 { return fail() }
    if _cmsReadUInt32Number(io, &greenOffset) == 0 { return fail() }
    if _cmsReadUInt32Number(io, &blueOffset) == 0 { return fail() }

    func readDoubles(
        at position: cmsUInt32Number, _ count: Int, _ into: UnsafeMutablePointer<cmsFloat64Number>
    ) -> Bool {
        let here = tell(io)
        if seek(io, position) == 0 { return false }
        for i in 0..<count where _cmsRead15Fixed16Number(io, into + i) == 0 { return false }
        return seek(io, here) != 0
    }

    let matrix = withUnsafeMutableBytes(of: &mhc2.pointee.XYZ2XYZmatrix) {
        $0.baseAddress!.assumingMemoryBound(to: cmsFloat64Number.self)
    }
    if matrixOffset == 0 {
        // Absent means the identity, which is written out as an
        // augmented 3x4 with a zero translation column.
        for i in 0..<12 { matrix[i] = 0 }
        matrix[0] = 1.0
        matrix[5] = 1.0
        matrix[10] = 1.0
    } else if !readDoubles(at: base + matrixOffset, 12, matrix) {
        return fail()
    }

    // Each table is preceded by a type signature and a filler word.
    if !readDoubles(at: base + redOffset + 8, Int(entries), mhc2.pointee.RedCurve!) {
        return fail()
    }
    if !readDoubles(at: base + greenOffset + 8, Int(entries), mhc2.pointee.GreenCurve!) {
        return fail()
    }
    if !readDoubles(at: base + blueOffset + 8, Int(entries), mhc2.pointee.BlueCurve!) {
        return fail()
    }

    items = 1
    return raw
}

@Sendable private func writeMHC2(
    _ context: cmsContext?, _ io: UnsafeMutablePointer<cmsIOHANDLER>,
    _ object: UnsafeMutableRawPointer, _ items: cmsUInt32Number,
    _ version: cmsUInt32Number
) -> Bool {
    guard let tell = io.pointee.Tell, let seek = io.pointee.Seek else { return false }
    let mhc2 = object.assumingMemoryBound(to: cmsMHC2Type.self)
    let base = tell(io) - tagBaseSize

    if _cmsWriteUInt32Number(io, mhc2.pointee.CurveEntries) == 0 { return false }
    if _cmsWrite15Fixed16Number(io, mhc2.pointee.MinLuminance) == 0 { return false }
    if _cmsWrite15Fixed16Number(io, mhc2.pointee.PeakLuminance) == 0 { return false }

    let directory = tell(io)
    for _ in 0..<4 where _cmsWriteUInt32Number(io, 0) == 0 { return false }

    func writeDoubles(_ count: Int, _ from: UnsafePointer<cmsFloat64Number>) -> Bool {
        for i in 0..<count where _cmsWrite15Fixed16Number(io, from[i]) == 0 { return false }
        return true
    }

    var matrixOffset: cmsUInt32Number = 0
    let identity = withUnsafeBytes(of: mhc2.pointee.XYZ2XYZmatrix) { raw -> Bool in
        let m = raw.bindMemory(to: cmsFloat64Number.self)
        for row in 0..<3 {
            for column in 0..<4 {
                let expected: cmsFloat64Number = row == column ? 1.0 : 0.0
                if m[row * 4 + column] != expected { return false }
            }
        }
        return true
    }
    if !identity {
        matrixOffset = tell(io) - base
        let ok = withUnsafeBytes(of: mhc2.pointee.XYZ2XYZmatrix) { raw in
            writeDoubles(12, raw.bindMemory(to: cmsFloat64Number.self).baseAddress!)
        }
        if !ok { return false }
    }

    var offsets = [cmsUInt32Number](repeating: 0, count: 3)
    let curves = [mhc2.pointee.RedCurve, mhc2.pointee.GreenCurve, mhc2.pointee.BlueCurve]
    for (i, curve) in curves.enumerated() {
        guard let curve else { return false }
        offsets[i] = tell(io) - base
        // The signature and filler the reader steps over.
        if _cmsWriteUInt32Number(io, cmsSigS15Fixed16ArrayType.rawValue) == 0 { return false }
        if _cmsWriteUInt32Number(io, 0) == 0 { return false }
        if !writeDoubles(Int(mhc2.pointee.CurveEntries), curve) { return false }
    }

    let end = tell(io)
    if seek(io, directory) == 0 { return false }
    if _cmsWriteUInt32Number(io, matrixOffset) == 0 { return false }
    for value in offsets where _cmsWriteUInt32Number(io, value) == 0 { return false }
    return seek(io, end) != 0
}

let remainingTagTypes: [cmsTagTypeSignature: TagTypeHandler] = [
    cmsSigCrdInfoType: TagTypeHandler(
        signature: cmsSigCrdInfoType, read: readCrdInfo, write: writeCrdInfo,
        duplicate: { _, pointer, _ in
            UnsafeMutableRawPointer(cmsMLUdup(
                UnsafeMutablePointer(mutating: pointer.assumingMemoryBound(to: cmsMLU.self))
            ))
        },
        free: { _, object in cmsMLUfree(object.assumingMemoryBound(to: cmsMLU.self)) }
    ),
    cmsSigMHC2Type: TagTypeHandler(
        signature: cmsSigMHC2Type, read: readMHC2, write: writeMHC2,
        duplicate: { context, pointer, _ in
            let source = pointer.assumingMemoryBound(to: cmsMHC2Type.self)
            guard let raw = _cmsDupMem(
                context, pointer, cmsUInt32Number(MemoryLayout<cmsMHC2Type>.size)
            ) else { return nil }
            let copy = raw.assumingMemoryBound(to: cmsMHC2Type.self)
            let bytes = source.pointee.CurveEntries
                * cmsUInt32Number(MemoryLayout<cmsFloat64Number>.size)
            copy.pointee.RedCurve = _cmsDupMem(context, source.pointee.RedCurve, bytes)?
                .assumingMemoryBound(to: cmsFloat64Number.self)
            copy.pointee.GreenCurve = _cmsDupMem(context, source.pointee.GreenCurve, bytes)?
                .assumingMemoryBound(to: cmsFloat64Number.self)
            copy.pointee.BlueCurve = _cmsDupMem(context, source.pointee.BlueCurve, bytes)?
                .assumingMemoryBound(to: cmsFloat64Number.self)
            return raw
        },
        free: { context, object in
            let value = object.assumingMemoryBound(to: cmsMHC2Type.self)
            _cmsFree(context, value.pointee.RedCurve)
            _cmsFree(context, value.pointee.GreenCurve)
            _cmsFree(context, value.pointee.BlueCurve)
            _cmsFree(context, object)
        }
    ),
]
