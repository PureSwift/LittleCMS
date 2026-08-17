import CLCMS2
import LittleCMS

// Reading and writing the fields an ICC profile is made of.
//
// Every one of these goes through the handler's own Read or Write, never
// around it, because the handler may be the caller's: a client that builds
// a cmsIOHANDLER over its own storage expects these to drive it.
//
// A null destination is legal on the readers and means "consume the field
// and discard it", which is how the reference skips over what it does not
// need.  That is why each reads into a local first.

@inline(__always)
private func read<T>(_ io: UnsafeMutablePointer<cmsIOHANDLER>, _ value: inout T) -> Bool {
    guard let readFn = io.pointee.Read else { return false }
    return withUnsafeMutableBytes(of: &value) { bytes in
        readFn(io, bytes.baseAddress, cmsUInt32Number(bytes.count), 1) == 1
    }
}

@inline(__always)
private func write<T>(_ io: UnsafeMutablePointer<cmsIOHANDLER>, _ value: T) -> Bool {
    guard let writeFn = io.pointee.Write else { return false }
    var copy = value
    return withUnsafeBytes(of: &copy) { bytes in
        writeFn(io, cmsUInt32Number(bytes.count), bytes.baseAddress) != 0
    }
}

// -- readers -----------------------------------------------------------

@c @implementation
public func _cmsReadUInt8Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsUInt8Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt8Number = 0
    guard read(io, &tmp) else { return 0 }
    n?.pointee = tmp
    return 1
}

@c @implementation
public func _cmsReadUInt16Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsUInt16Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt16Number = 0
    guard read(io, &tmp) else { return 0 }
    n?.pointee = adjustEndianness(tmp)
    return 1
}

@c @implementation
public func _cmsReadUInt16Array(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: cmsUInt32Number,
    _ Array: UnsafeMutablePointer<cmsUInt16Number>?
) -> cmsBool {
    guard let io else { return 0 }
    for index in 0..<Int(n) {
        let slot = Array.map { $0 + index }
        if _cmsReadUInt16Number(io, slot) == 0 { return 0 }
    }
    return 1
}

@c @implementation
public func _cmsReadUInt32Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsUInt32Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt32Number = 0
    guard read(io, &tmp) else { return 0 }
    n?.pointee = adjustEndianness(tmp)
    return 1
}

@c @implementation
public func _cmsReadFloat32Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsFloat32Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt32Number = 0
    guard read(io, &tmp) else { return 0 }

    guard let n else { return 1 }
    let value = Float(bitPattern: adjustEndianness(tmp))
    n.pointee = value
    // Written into the destination either way — the reference stores
    // before it judges — but a value the format should not contain still
    // fails the read.
    return ICCField.isAcceptable(value) ? 1 : 0
}

@c @implementation
public func _cmsReadUInt64Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsUInt64Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt64Number = 0
    guard read(io, &tmp) else { return 0 }
    n?.pointee = cmsUInt64Number(adjustEndianness(UInt64(tmp)))
    return 1
}

@c @implementation
public func _cmsRead15Fixed16Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsFloat64Number>?
) -> cmsBool {
    guard let io else { return 0 }
    var tmp: cmsUInt32Number = 0
    guard read(io, &tmp) else { return 0 }
    n?.pointee = S15Fixed16.toDouble(Int32(bitPattern: adjustEndianness(tmp)))
    return 1
}

@c @implementation
public func _cmsReadXYZNumber(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ XYZ: UnsafeMutablePointer<cmsCIEXYZ>?
) -> cmsBool {
    guard let io else { return 0 }
    var encoded = cmsEncodedXYZNumber()
    guard read(io, &encoded) else { return 0 }

    guard let XYZ else { return 1 }
    @inline(__always)
    func decode(_ raw: cmsS15Fixed16Number) -> cmsFloat64Number {
        S15Fixed16.toDouble(Int32(bitPattern: adjustEndianness(UInt32(bitPattern: raw))))
    }
    XYZ.pointee.X = decode(encoded.X)
    XYZ.pointee.Y = decode(encoded.Y)
    XYZ.pointee.Z = decode(encoded.Z)
    return 1
}

// -- writers -----------------------------------------------------------

@c @implementation
public func _cmsWriteUInt8Number(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ n: cmsUInt8Number) -> cmsBool {
    guard let io else { return 0 }
    return write(io, n) ? 1 : 0
}

@c @implementation
public func _cmsWriteUInt16Number(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ n: cmsUInt16Number) -> cmsBool {
    guard let io else { return 0 }
    return write(io, adjustEndianness(n)) ? 1 : 0
}

@c @implementation
public func _cmsWriteUInt16Array(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: cmsUInt32Number,
    _ Array: UnsafePointer<cmsUInt16Number>?
) -> cmsBool {
    guard let io, let Array else { return 0 }
    for index in 0..<Int(n) where _cmsWriteUInt16Number(io, Array[index]) == 0 {
        return 0
    }
    return 1
}

@c @implementation
public func _cmsWriteUInt32Number(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ n: cmsUInt32Number) -> cmsBool {
    guard let io else { return 0 }
    return write(io, adjustEndianness(n)) ? 1 : 0
}

@c @implementation
public func _cmsWriteFloat32Number(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ n: cmsFloat32Number) -> cmsBool {
    guard let io else { return 0 }
    return write(io, adjustEndianness(n.bitPattern)) ? 1 : 0
}

@c @implementation
public func _cmsWriteUInt64Number(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ n: UnsafeMutablePointer<cmsUInt64Number>?
) -> cmsBool {
    guard let io, let n else { return 0 }
    return write(io, cmsUInt64Number(adjustEndianness(UInt64(n.pointee)))) ? 1 : 0
}

@c @implementation
public func _cmsWrite15Fixed16Number(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ n: cmsFloat64Number) -> cmsBool {
    guard let io else { return 0 }
    let fixed = UInt32(bitPattern: S15Fixed16.fromDouble(n))
    return write(io, adjustEndianness(fixed)) ? 1 : 0
}

@c @implementation
public func _cmsWriteXYZNumber(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ XYZ: UnsafePointer<cmsCIEXYZ>?
) -> cmsBool {
    guard let io, let XYZ else { return 0 }

    @inline(__always)
    func encode(_ value: cmsFloat64Number) -> cmsS15Fixed16Number {
        cmsS15Fixed16Number(bitPattern: adjustEndianness(UInt32(bitPattern: S15Fixed16.fromDouble(value))))
    }
    var encoded = cmsEncodedXYZNumber()
    encoded.X = encode(XYZ.pointee.X)
    encoded.Y = encode(XYZ.pointee.Y)
    encoded.Z = encode(XYZ.pointee.Z)
    return write(io, encoded) ? 1 : 0
}

// -- element framing ---------------------------------------------------

@c @implementation
public func _cmsReadTypeBase(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsTagTypeSignature {
    guard let io else { return cmsTagTypeSignature(0) }
    var base = _cmsTagBase()
    guard read(io, &base) else { return cmsTagTypeSignature(0) }
    return cmsTagTypeSignature(adjustEndianness(base.sig.rawValue))
}

@c @implementation
public func _cmsWriteTypeBase(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ sig: cmsTagTypeSignature) -> cmsBool {
    guard let io else { return 0 }
    var base = _cmsTagBase()
    base.sig = cmsTagTypeSignature(adjustEndianness(sig.rawValue))
    base.reserved = (0, 0, 0, 0)
    return write(io, base) ? 1 : 0
}

/// Consumes the padding that separates one element from the next.
@c @implementation
public func _cmsReadAlignment(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io, let tell = io.pointee.Tell, let readFn = io.pointee.Read else { return 0 }

    let padding = ICCField.paddingAfter(tell(io))
    if padding == 0 { return 1 }
    if padding > 4 { return 0 }

    var buffer: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    return withUnsafeMutableBytes(of: &buffer) { bytes in
        readFn(io, bytes.baseAddress, padding, 1) == 1 ? 1 : 0
    }
}

/// Writes the padding that separates one element from the next.
@c @implementation
public func _cmsWriteAlignment(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io, let tell = io.pointee.Tell, let writeFn = io.pointee.Write else { return 0 }

    let padding = ICCField.paddingAfter(tell(io))
    if padding == 0 { return 1 }
    if padding > 4 { return 0 }

    var buffer: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    return withUnsafeBytes(of: &buffer) { bytes in
        writeFn(io, padding, bytes.baseAddress) != 0 ? 1 : 0
    }
}
