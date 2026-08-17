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

/// Which type a tag is written as.  Only the XYZ tags carry a decision
/// function in the reference today, and it ignores both its arguments,
/// so the answer is always the first supported type.
func typeToWrite(for sig: cmsTagSignature) -> cmsTagTypeSignature? {
    tagDescriptor(for: sig)?.supportedTypes.first
}
