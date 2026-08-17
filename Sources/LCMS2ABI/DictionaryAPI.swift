import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Dictionaries and profile sequence descriptions.
//
// Both hand the caller structures to walk rather than handles to ask, so
// both are C memory with the layout the vendored headers publish.  A
// dictionary entry is an intrusive list node the client follows through
// `Next`; a sequence is an array the client indexes and writes into,
// swapping in its own strings before the tag is saved.
//
// That second one decides the ownership rule: freeing a sequence frees
// the strings hanging off it, whoever put them there.

// -- profile sequence descriptions --------------------------------------

@c @implementation
public func cmsAllocProfileSequenceDescription(
    _ ContextID: cmsContext?,
    _ n: cmsUInt32Number
) -> UnsafeMutablePointer<cmsSEQ>? {
    // A devicelink chaining more profiles than this is not a real
    // profile, and the count comes off the wire, so the reference caps
    // it rather than trusting it.
    if n == 0 || n > 255 { return nil }

    guard let raw = _cmsMallocZero(ContextID, cmsUInt32Number(MemoryLayout<cmsSEQ>.size))
    else { return nil }
    let seq = raw.assumingMemoryBound(to: cmsSEQ.self)

    guard let entries = _cmsCalloc(
        ContextID, n, cmsUInt32Number(MemoryLayout<cmsPSEQDESC>.stride)
    ) else {
        _cmsFree(ContextID, raw)
        return nil
    }

    seq.pointee.ContextID = ContextID
    seq.pointee.seq = entries.assumingMemoryBound(to: cmsPSEQDESC.self)
    seq.pointee.n = n
    return seq
}

@c @implementation
public func cmsFreeProfileSequenceDescription(_ pseq: UnsafeMutablePointer<cmsSEQ>?) {
    guard let pseq else { return }
    let context = pseq.pointee.ContextID

    if let entries = pseq.pointee.seq {
        for i in 0..<Int(pseq.pointee.n) {
            // Whatever is hanging here now, including strings the caller
            // attached after the sequence was made.
            cmsMLUfree(entries[i].Manufacturer)
            cmsMLUfree(entries[i].Model)
            cmsMLUfree(entries[i].Description)
        }
        _cmsFree(context, UnsafeMutableRawPointer(entries))
    }

    _cmsFree(context, UnsafeMutableRawPointer(pseq))
}

@c @implementation
public func cmsDupProfileSequenceDescription(
    _ pseq: UnsafePointer<cmsSEQ>?
) -> UnsafeMutablePointer<cmsSEQ>? {
    guard let pseq else { return nil }
    let context = pseq.pointee.ContextID

    guard let raw = _cmsMallocZero(context, cmsUInt32Number(MemoryLayout<cmsSEQ>.size))
    else { return nil }
    let copy = raw.assumingMemoryBound(to: cmsSEQ.self)
    copy.pointee.ContextID = context

    guard let entries = _cmsCalloc(
        context, pseq.pointee.n, cmsUInt32Number(MemoryLayout<cmsPSEQDESC>.stride)
    ) else {
        _cmsFree(context, raw)
        return nil
    }
    copy.pointee.seq = entries.assumingMemoryBound(to: cmsPSEQDESC.self)
    copy.pointee.n = pseq.pointee.n

    guard let source = pseq.pointee.seq else { return copy }
    for i in 0..<Int(pseq.pointee.n) {
        copy.pointee.seq[i].attributes = source[i].attributes
        copy.pointee.seq[i].deviceMfg = source[i].deviceMfg
        copy.pointee.seq[i].deviceModel = source[i].deviceModel
        copy.pointee.seq[i].ProfileID = source[i].ProfileID
        copy.pointee.seq[i].technology = source[i].technology

        // The strings are duplicated, not shared: the copy has to
        // survive the original being freed.
        copy.pointee.seq[i].Manufacturer = cmsMLUdup(source[i].Manufacturer)
        copy.pointee.seq[i].Model = cmsMLUdup(source[i].Model)
        copy.pointee.seq[i].Description = cmsMLUdup(source[i].Description)
    }

    return copy
}

// -- dictionaries --------------------------------------------------------

@inline(__always)
private func dictionary(_ handle: cmsHANDLE?) -> UnsafeMutablePointer<_cms_dict_struct>? {
    handle?.assumingMemoryBound(to: _cms_dict_struct.self)
}

/// Copies a wide string into the library's own memory, or nothing when
/// there is nothing to copy.
private func duplicate(_ string: UnsafePointer<wchar_t>?, _ context: cmsContext?) -> UnsafeMutablePointer<wchar_t>? {
    guard let string else { return nil }

    var length = 0
    while string[length] != 0 { length += 1 }

    let bytes = cmsUInt32Number((length + 1) * MemoryLayout<wchar_t>.stride)
    guard let raw = _cmsMalloc(context, bytes) else { return nil }
    let copy = raw.assumingMemoryBound(to: wchar_t.self)
    for i in 0...length { copy[i] = string[i] }
    return copy
}

@c @implementation
public func cmsDictAlloc(_ ContextID: cmsContext?) -> cmsHANDLE? {
    guard let raw = _cmsMallocZero(
        ContextID, cmsUInt32Number(MemoryLayout<_cms_dict_struct>.size)
    ) else { return nil }

    let dict = raw.assumingMemoryBound(to: _cms_dict_struct.self)
    dict.pointee.ContextID = ContextID
    dict.pointee.head = nil
    return raw
}

@c @implementation
public func cmsDictFree(_ hDict: cmsHANDLE?) {
    guard let dict = dictionary(hDict) else { return }
    let context = dict.pointee.ContextID

    var entry = dict.pointee.head
    while let current = entry {
        cmsMLUfree(current.pointee.DisplayName)
        cmsMLUfree(current.pointee.DisplayValue)
        if let name = current.pointee.Name { _cmsFree(context, UnsafeMutableRawPointer(name)) }
        if let value = current.pointee.Value { _cmsFree(context, UnsafeMutableRawPointer(value)) }

        // Read the link before the node holding it goes away.
        let next = current.pointee.Next
        _cmsFree(context, UnsafeMutableRawPointer(current))
        entry = next
    }

    _cmsFree(context, UnsafeMutableRawPointer(dict))
}

@c @implementation
public func cmsDictAddEntry(
    _ hDict: cmsHANDLE?,
    _ Name: UnsafePointer<wchar_t>?,
    _ Value: UnsafePointer<wchar_t>?,
    _ DisplayName: UnsafePointer<cmsMLU>?,
    _ DisplayValue: UnsafePointer<cmsMLU>?
) -> cmsBool {
    guard let dict = dictionary(hDict), Name != nil else { return 0 }
    let context = dict.pointee.ContextID

    guard let raw = _cmsMallocZero(
        context, cmsUInt32Number(MemoryLayout<cmsDICTentry>.size)
    ) else { return 0 }
    let entry = raw.assumingMemoryBound(to: cmsDICTentry.self)

    entry.pointee.DisplayName = cmsMLUdup(DisplayName)
    entry.pointee.DisplayValue = cmsMLUdup(DisplayValue)
    entry.pointee.Name = duplicate(Name, context)
    entry.pointee.Value = duplicate(Value, context)

    // Prepended, which is why walking the list gives the entries back in
    // the reverse of the order they were added.
    entry.pointee.Next = dict.pointee.head
    dict.pointee.head = entry
    return 1
}

@c @implementation
public func cmsDictGetEntryList(_ hDict: cmsHANDLE?) -> UnsafePointer<cmsDICTentry>? {
    guard let dict = dictionary(hDict), let head = dict.pointee.head else { return nil }
    return UnsafePointer(head)
}

@c @implementation
public func cmsDictNextEntry(_ e: UnsafePointer<cmsDICTentry>?) -> UnsafePointer<cmsDICTentry>? {
    guard let next = e?.pointee.Next else { return nil }
    return UnsafePointer(next)
}

@c @implementation
public func cmsDictDup(_ hDict: cmsHANDLE?) -> cmsHANDLE? {
    guard let source = dictionary(hDict) else { return nil }
    guard let copy = cmsDictAlloc(source.pointee.ContextID) else { return nil }

    // The list is walked forwards and each entry prepended, so the copy
    // comes out in the reverse of the source's order — which is the
    // order they were originally added.  The reference does the same.
    var entry = source.pointee.head
    while let current = entry {
        if cmsDictAddEntry(
            copy,
            current.pointee.Name,
            current.pointee.Value,
            current.pointee.DisplayName,
            current.pointee.DisplayValue
        ) == 0 {
            cmsDictFree(copy)
            return nil
        }
        entry = current.pointee.Next
    }

    return copy
}
