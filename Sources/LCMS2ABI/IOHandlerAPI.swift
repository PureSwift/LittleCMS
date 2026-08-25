import CLCMS2
import LittleCMSCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The stream abstraction the whole format rests on.
//
// cmsIOHANDLER is a published layout, not an opaque handle: the plugin
// header declares every field and its five function pointers, and callers
// build their own to read a profile from wherever they keep it.  So these
// are real C structs with real C function pointers, allocated through the
// library's own allocator, and the engine never sees one — what it will
// see, when the profile reader arrives, is bytes.
//
// Each backend keeps its state behind `stream`, as the reference does.
// The state types are ours, so their layout is free; the handler's is not.

private struct NullStream {
    var pointer: cmsUInt32Number
}

private struct MemoryStream {
    var block: UnsafeMutablePointer<cmsUInt8Number>?
    var size: cmsUInt32Number
    var pointer: cmsUInt32Number
    var freeBlockOnClose: Bool
}

@inline(__always)
private func state<T>(_ io: UnsafeMutablePointer<cmsIOHANDLER>, as _: T.Type) -> UnsafeMutablePointer<T>? {
    io.pointee.stream?.assumingMemoryBound(to: T.self)
}

/// Allocates a zeroed handler through the library's allocator, as the
/// reference does — so a memory-handler plugin would see these too.
private func allocateHandler(_ context: cmsContext?) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsIOHANDLER>.size)) else {
        return nil
    }
    return raw.assumingMemoryBound(to: cmsIOHANDLER.self)
}

// -- the NULL handler --------------------------------------------------
//
// Counts bytes instead of storing them.  A profile is serialized across
// one of these first, to learn how large it is, and then for real.

private func nullRead(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: cmsUInt32Number,
    _ count: cmsUInt32Number
) -> cmsUInt32Number {
    guard let io, let s = state(io, as: NullStream.self) else { return 0 }
    s.pointee.pointer &+= size &* count
    return count
}

private func nullSeek(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ offset: cmsUInt32Number) -> cmsBool {
    guard let io, let s = state(io, as: NullStream.self) else { return 0 }
    s.pointee.pointer = offset
    return 1
}

private func nullTell(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsUInt32Number {
    guard let io, let s = state(io, as: NullStream.self) else { return 0 }
    return s.pointee.pointer
}

private func nullWrite(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ size: cmsUInt32Number,
    _ pointer: UnsafeRawPointer?
) -> cmsBool {
    guard let io, let s = state(io, as: NullStream.self) else { return 0 }
    // Refuses what would wrap the counter rather than reporting a smaller
    // profile than was written.
    if size > cmsUInt32Number.max &- s.pointee.pointer { return 0 }
    s.pointee.pointer &+= size
    if s.pointee.pointer > io.pointee.UsedSpace {
        io.pointee.UsedSpace = s.pointee.pointer
    }
    return 1
}

private func nullClose(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io else { return 0 }
    let context = io.pointee.ContextID
    _cmsFree(context, io.pointee.stream)
    _cmsFree(context, UnsafeMutableRawPointer(io))
    return 1
}

@c @implementation
public func cmsOpenIOhandlerFromNULL(_ ContextID: cmsContext?) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    guard let io = allocateHandler(ContextID) else { return nil }
    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<NullStream>.size)) else {
        _cmsFree(ContextID, UnsafeMutableRawPointer(io))
        return nil
    }

    io.pointee.ContextID = ContextID
    io.pointee.stream = raw
    io.pointee.UsedSpace = 0
    io.pointee.ReportedSize = 0
    io.pointee.PhysicalFile.0 = 0
    io.pointee.Read = nullRead
    io.pointee.Seek = nullSeek
    io.pointee.Close = nullClose
    io.pointee.Tell = nullTell
    io.pointee.Write = nullWrite
    return io
}

// -- the memory handler ------------------------------------------------

private func memoryRead(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: cmsUInt32Number,
    _ count: cmsUInt32Number
) -> cmsUInt32Number {
    guard let io, let s = state(io, as: MemoryStream.self) else { return 0 }

    if size == 0 || count == 0 { return 0 }

    let length = size &* count
    // The order of these is the reference's, and it matters: the division
    // catches a product that wrapped, and the last comparison is written
    // so that it cannot wrap itself.
    guard length / count == size,
          let buffer,
          length <= s.pointee.size,
          s.pointee.pointer <= s.pointee.size &- length,
          let block = s.pointee.block
    else {
        report(cmsUInt32Number(cmsERROR_READ), "Read from memory error", to: io.pointee.ContextID)
        return 0
    }

    memmove(buffer, block + Int(s.pointee.pointer), Int(length))
    s.pointee.pointer &+= length
    return count
}

private func memorySeek(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ offset: cmsUInt32Number) -> cmsBool {
    guard let io, let s = state(io, as: MemoryStream.self) else { return 0 }
    if offset > s.pointee.size { return 0 }
    s.pointee.pointer = offset
    return 1
}

private func memoryTell(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsUInt32Number {
    guard let io, let s = state(io, as: MemoryStream.self) else { return 0 }
    return s.pointee.pointer
}

private func memoryWrite(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ size: cmsUInt32Number,
    _ pointer: UnsafeRawPointer?
) -> cmsBool {
    guard let io, let s = state(io, as: MemoryStream.self), let pointer else {
        if let io {
            report(cmsUInt32Number(cmsERROR_WRITE), "Write to memory error", to: io.pointee.ContextID)
        }
        return 0
    }

    if size == 0 { return 1 }   // writing nothing is allowed and does nothing

    guard size <= s.pointee.size,
          s.pointee.pointer <= s.pointee.size &- size,
          let block = s.pointee.block
    else {
        report(cmsUInt32Number(cmsERROR_WRITE), "Write to memory error", to: io.pointee.ContextID)
        return 0
    }

    memmove(block + Int(s.pointee.pointer), pointer, Int(size))
    s.pointee.pointer &+= size
    if s.pointee.pointer > io.pointee.UsedSpace {
        io.pointee.UsedSpace = s.pointee.pointer
    }
    return 1
}

private func memoryClose(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io, let s = state(io, as: MemoryStream.self) else { return 0 }
    let context = io.pointee.ContextID
    if s.pointee.freeBlockOnClose {
        _cmsFree(context, s.pointee.block)
    }
    _cmsFree(context, UnsafeMutableRawPointer(s))
    _cmsFree(context, UnsafeMutableRawPointer(io))
    return 1
}

@c @implementation
public func cmsOpenIOhandlerFromMem(
    _ ContextID: cmsContext?,
    _ Buffer: UnsafeMutableRawPointer?,
    _ size: cmsUInt32Number,
    _ AccessMode: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    guard let AccessMode else { return nil }

    let mode = AccessMode.pointee
    // An unknown mode is refused before anything is allocated.  The
    // reference leaks its handler here; not reproducing that is not a
    // behavioural difference, only a smaller one.
    guard mode == UInt8(ascii: "r") || mode == UInt8(ascii: "w") else {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unknown access mode '\(Character(UnicodeScalar(UInt8(bitPattern: mode))))'",
            to: ContextID
        )
        return nil
    }

    guard let io = allocateHandler(ContextID) else { return nil }
    guard let rawState = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<MemoryStream>.size)) else {
        _cmsFree(ContextID, UnsafeMutableRawPointer(io))
        return nil
    }
    let s = rawState.assumingMemoryBound(to: MemoryStream.self)

    if mode == UInt8(ascii: "r") {
        // Reading copies the caller's bytes, so the caller may free them
        // as soon as this returns.
        guard let Buffer else {
            report(cmsUInt32Number(cmsERROR_READ), "Couldn't read profile from NULL pointer", to: ContextID)
            _cmsFree(ContextID, rawState)
            _cmsFree(ContextID, UnsafeMutableRawPointer(io))
            return nil
        }
        guard let block = _cmsMalloc(ContextID, size) else {
            report(cmsUInt32Number(cmsERROR_READ), "Couldn't allocate \(size) bytes for profile", to: ContextID)
            _cmsFree(ContextID, rawState)
            _cmsFree(ContextID, UnsafeMutableRawPointer(io))
            return nil
        }
        memmove(block, Buffer, Int(size))
        s.pointee.block = block.assumingMemoryBound(to: cmsUInt8Number.self)
        s.pointee.freeBlockOnClose = true
        s.pointee.size = size
        s.pointee.pointer = 0
        io.pointee.ReportedSize = size
    } else {
        // Writing goes straight into the caller's buffer, which stays
        // theirs to free.
        guard let Buffer else {
            report(cmsUInt32Number(cmsERROR_WRITE), "Couldn't write profile to NULL pointer", to: ContextID)
            _cmsFree(ContextID, rawState)
            _cmsFree(ContextID, UnsafeMutableRawPointer(io))
            return nil
        }
        s.pointee.block = Buffer.assumingMemoryBound(to: cmsUInt8Number.self)
        s.pointee.freeBlockOnClose = false
        s.pointee.size = size
        s.pointee.pointer = 0
        io.pointee.ReportedSize = 0
    }

    io.pointee.ContextID = ContextID
    io.pointee.stream = rawState
    io.pointee.UsedSpace = 0
    io.pointee.PhysicalFile.0 = 0
    io.pointee.Read = memoryRead
    io.pointee.Seek = memorySeek
    io.pointee.Close = memoryClose
    io.pointee.Tell = memoryTell
    io.pointee.Write = memoryWrite
    return io
}

// -- the file handler --------------------------------------------------
//
// `stream` is the FILE* itself here, so both the named-file and the
// caller's-stream constructors share these five.

private func fileRead(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ buffer: UnsafeMutableRawPointer?,
    _ size: cmsUInt32Number,
    _ count: cmsUInt32Number
) -> cmsUInt32Number {
    guard let io, let file = io.pointee.stream else { return 0 }
    let read = cmsUInt32Number(fread(buffer, Int(size), Int(count), file.assumingMemoryBound(to: FILE.self)))
    if read != count {
        report(
            cmsUInt32Number(cmsERROR_FILE),
            "Read error. Got \(read &* size) bytes, block should be of \(count &* size) bytes",
            to: io.pointee.ContextID
        )
        return 0
    }
    return read
}

private func fileSeek(_ io: UnsafeMutablePointer<cmsIOHANDLER>?, _ offset: cmsUInt32Number) -> cmsBool {
    guard let io, let file = io.pointee.stream else { return 0 }
    if fseek(file.assumingMemoryBound(to: FILE.self), Int(offset), SEEK_SET) != 0 {
        report(cmsUInt32Number(cmsERROR_FILE), "Seek error; probably corrupted file", to: io.pointee.ContextID)
        return 0
    }
    return 1
}

private func fileTell(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsUInt32Number {
    guard let io, let file = io.pointee.stream else { return 0 }
    let position = ftell(file.assumingMemoryBound(to: FILE.self))
    if position == -1 {
        report(cmsUInt32Number(cmsERROR_FILE), "Tell error; probably corrupted file", to: io.pointee.ContextID)
        return 0
    }
    return cmsUInt32Number(truncatingIfNeeded: position)
}

private func fileWrite(
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ size: cmsUInt32Number,
    _ buffer: UnsafeRawPointer?
) -> cmsBool {
    guard let io, let file = io.pointee.stream else { return 0 }
    if size == 0 { return 1 }   // writing nothing is allowed and writes nothing
    io.pointee.UsedSpace &+= size
    return fwrite(buffer, Int(size), 1, file.assumingMemoryBound(to: FILE.self)) == 1 ? 1 : 0
}

private func fileClose(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io, let file = io.pointee.stream else { return 0 }
    // Closes the stream even when it came from the caller, which is what
    // the reference does.
    if fclose(file.assumingMemoryBound(to: FILE.self)) != 0 { return 0 }
    _cmsFree(io.pointee.ContextID, UnsafeMutableRawPointer(io))
    return 1
}

private func installFileVTable(_ io: UnsafeMutablePointer<cmsIOHANDLER>) {
    io.pointee.Read = fileRead
    io.pointee.Seek = fileSeek
    io.pointee.Close = fileClose
    io.pointee.Tell = fileTell
    io.pointee.Write = fileWrite
}

@c @implementation
public func cmsOpenIOhandlerFromFile(
    _ ContextID: cmsContext?,
    _ FileName: UnsafePointer<CChar>?,
    _ AccessMode: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    guard let FileName, let AccessMode else { return nil }

    // The mode string is validated a character at a time, as the
    // reference validates it: one of r or w, optionally with e for
    // close-on-exec, and a second r or w is an error rather than a
    // silent last-one-wins.
    var access: CChar = 0
    var closeOnExec = false
    var cursor = AccessMode
    while cursor.pointee != 0 {
        switch cursor.pointee {
        case CChar(UInt8(ascii: "r")), CChar(UInt8(ascii: "w")):
            if access == 0 {
                access = cursor.pointee
            } else {
                report(
                    cmsUInt32Number(cmsERROR_FILE),
                    "Access mode already specified '\(Character(UnicodeScalar(UInt8(bitPattern: cursor.pointee))))'",
                    to: ContextID
                )
                return nil
            }
        case CChar(UInt8(ascii: "e")):
            closeOnExec = true
        default:
            report(
                cmsUInt32Number(cmsERROR_FILE),
                "Wrong access mode '\(Character(UnicodeScalar(UInt8(bitPattern: cursor.pointee))))'",
                to: ContextID
            )
            return nil
        }
        cursor += 1
    }

    let reading = access == CChar(UInt8(ascii: "r"))
    let mode = (reading ? "rb" : "wb") + (closeOnExec ? "e" : "")

    guard let file = mode.withCString({ fopen(FileName, $0) }) else {
        let name = String(cString: FileName)
        report(
            cmsUInt32Number(cmsERROR_FILE),
            reading ? "File '\(name)' not found" : "Couldn't create '\(name)'",
            to: ContextID
        )
        return nil
    }

    guard let io = allocateHandler(ContextID) else {
        fclose(file)
        return nil
    }

    if reading {
        let length = cmsfilelength(file)
        if length < 0 {
            fclose(file)
            _cmsFree(ContextID, UnsafeMutableRawPointer(io))
            report(
                cmsUInt32Number(cmsERROR_FILE),
                "Cannot get size of file '\(String(cString: FileName))'",
                to: ContextID
            )
            return nil
        }
        io.pointee.ReportedSize = cmsUInt32Number(truncatingIfNeeded: length)
    } else {
        io.pointee.ReportedSize = 0
    }

    io.pointee.ContextID = ContextID
    io.pointee.stream = UnsafeMutableRawPointer(file)
    io.pointee.UsedSpace = 0

    // The originating path, truncated to the field and always terminated.
    withUnsafeMutableBytes(of: &io.pointee.PhysicalFile) { field in
        let capacity = field.count - 1
        var index = 0
        while index < capacity, FileName[index] != 0 {
            field[index] = UInt8(bitPattern: FileName[index])
            index += 1
        }
        field[index] = 0
    }

    installFileVTable(io)
    return io
}

@c @implementation
public func cmsOpenIOhandlerFromStream(
    _ ContextID: cmsContext?,
    _ Stream: UnsafeMutablePointer<FILE>?
) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    guard let Stream else { return nil }

    let size = cmsfilelength(Stream)
    if size < 0 {
        report(cmsUInt32Number(cmsERROR_FILE), "Cannot get size of stream", to: ContextID)
        return nil
    }

    guard let io = allocateHandler(ContextID) else { return nil }

    io.pointee.ContextID = ContextID
    io.pointee.stream = UnsafeMutableRawPointer(Stream)
    io.pointee.UsedSpace = 0
    io.pointee.ReportedSize = cmsUInt32Number(truncatingIfNeeded: size)
    io.pointee.PhysicalFile.0 = 0
    installFileVTable(io)
    return io
}

@c @implementation
public func cmsCloseIOhandler(_ io: UnsafeMutablePointer<cmsIOHANDLER>?) -> cmsBool {
    guard let io, let close = io.pointee.Close else { return 0 }
    return close(io)
}

@c @implementation
public func cmsfilelength(_ f: UnsafeMutablePointer<FILE>?) -> CLong {
    guard let f else { return -1 }

    let position = ftell(f)
    if position == -1 { return -1 }
    if fseek(f, 0, SEEK_END) != 0 { return -1 }
    let length = ftell(f)
    if fseek(f, position, SEEK_SET) != 0 { return -1 }
    return length
}
