// Byte-order adjustment.
//
// ICC files are big-endian, so these turn a field as it sits in the file
// into one the host can read, and back.  The reference names them
// "adjust", not "swap", because on a big-endian host they do nothing.

/// The engine's own byte order, decided by the compiler rather than by a
/// list of platform names.
@inlinable
public var hostIsBigEndian: Bool {
    UInt16(0x0102).bigEndian == 0x0102
}

@inlinable
public func adjustEndianness(_ word: UInt16) -> UInt16 {
    hostIsBigEndian ? word : word.byteSwapped
}

@inlinable
public func adjustEndianness(_ value: UInt32) -> UInt32 {
    hostIsBigEndian ? value : value.byteSwapped
}

@inlinable
public func adjustEndianness(_ value: UInt64) -> UInt64 {
    hostIsBigEndian ? value : value.byteSwapped
}
