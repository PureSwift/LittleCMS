import CLCMS2
import LittleCMS

// Named colour lists.
//
// Another opaque handle — the testbed does not reach inside — so the
// storage is Swift and the boundary only marshals names in and out.
//
// One accessor here is dangerous by design and stays that way:
// cmsNamedColorInfo copies with strcpy rather than strncpy, because, as
// the reference puts it, many applications pass small buffers.  A caller
// must provide 256 bytes for a name and 33 for each affix.  Narrowing
// that would be safer and would also be a different function.

final class NamedColorListBox: HandleBox {
    let list: NamedColorList
    let context: cmsContext?

    init(_ list: NamedColorList, context: cmsContext?) {
        self.list = list
        self.context = context
    }
}

/// The box behind a handle the caller has already checked.  The tag
/// layer needs the list-wide prefix, suffix and colorant count, which no
/// exported accessor returns on their own.
@inline(__always)
func namedColorBox(_ list: UnsafeMutablePointer<cmsNAMEDCOLORLIST>) -> NamedColorListBox {
    Unmanaged<NamedColorListBox>.fromOpaque(UnsafeRawPointer(list)).takeUnretainedValue()
}

@inline(__always)
private func box(_ v: UnsafePointer<cmsNAMEDCOLORLIST>?) -> NamedColorListBox? {
    guard let v else { return nil }
    return Unmanaged<NamedColorListBox>.fromOpaque(UnsafeRawPointer(v)).takeUnretainedValue()
}

@inline(__always)
private func handle(_ box: NamedColorListBox) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST> {
    NamedColorListBox.handle(for: box).assumingMemoryBound(to: cmsNAMEDCOLORLIST.self)
}

/// Reads a C string into bytes, stopping at the terminator or the limit.
private func bytes(_ string: UnsafePointer<CChar>?, limit: Int) -> [UInt8] {
    guard let string else { return [] }
    var result: [UInt8] = []
    var i = 0
    while i < limit, string[i] != 0 {
        result.append(UInt8(bitPattern: string[i]))
        i += 1
    }
    return result
}

/// Writes bytes back as a terminated C string.  The caller's buffer is
/// assumed large enough, which is this API's contract.
private func write(_ source: [UInt8], to buffer: UnsafeMutablePointer<CChar>?) {
    guard let buffer else { return }
    for (i, byte) in source.enumerated() {
        buffer[i] = CChar(bitPattern: byte)
    }
    buffer[source.count] = 0
}

@c @implementation
public func cmsAllocNamedColorList(
    _ ContextID: cmsContext?,
    _ n: cmsUInt32Number,
    _ ColorantCount: cmsUInt32Number,
    _ Prefix: UnsafePointer<CChar>?,
    _ Suffix: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST>? {
    guard let list = NamedColorList(
        colorantCount: Int(ColorantCount),
        prefix: bytes(Prefix, limit: NamedColorList.affixLength),
        suffix: bytes(Suffix, limit: NamedColorList.affixLength),
        reserving: Int(n)
    ) else { return nil }

    return handle(NamedColorListBox(list, context: ContextID))
}

@c @implementation
public func cmsFreeNamedColorList(_ v: UnsafeMutablePointer<cmsNAMEDCOLORLIST>?) {
    guard let v else { return }
    _ = NamedColorListBox.consume(UnsafeMutableRawPointer(v))
}

@c @implementation
public func cmsDupNamedColorList(
    _ v: UnsafePointer<cmsNAMEDCOLORLIST>?
) -> UnsafeMutablePointer<cmsNAMEDCOLORLIST>? {
    guard let source = box(v) else { return nil }
    return handle(NamedColorListBox(NamedColorList(copying: source.list), context: source.context))
}

@c @implementation
public func cmsAppendNamedColor(
    _ v: UnsafeMutablePointer<cmsNAMEDCOLORLIST>?,
    _ Name: UnsafePointer<CChar>?,
    _ PCS: UnsafeMutablePointer<cmsUInt16Number>?,
    _ Colorant: UnsafeMutablePointer<cmsUInt16Number>?
) -> cmsBool {
    guard let box = box(v) else { return 0 }

    let pcs: (UInt16, UInt16, UInt16)? = PCS.map { ($0[0], $0[1], $0[2]) }
    let colorant: [UInt16]? = Colorant.map { source in
        (0..<box.list.colorantCount).map { source[$0] }
    }

    box.list.append(
        name: Name.map { bytes($0, limit: maximumNameLength - 1) },
        pcs: pcs,
        colorant: colorant
    )
    return 1
}

@c @implementation
public func cmsNamedColorCount(_ v: UnsafePointer<cmsNAMEDCOLORLIST>?) -> cmsUInt32Number {
    guard let box = box(v) else { return 0 }
    return cmsUInt32Number(box.list.colors.count)
}

@c @implementation
public func cmsNamedColorIndex(
    _ v: UnsafePointer<cmsNAMEDCOLORLIST>?,
    _ Name: UnsafePointer<CChar>?
) -> cmsInt32Number {
    guard let box = box(v) else { return -1 }
    let wanted = bytes(Name, limit: maximumNameLength)
    guard let index = box.list.index(ofName: wanted) else { return -1 }
    return cmsInt32Number(index)
}

@c @implementation
public func cmsNamedColorInfo(
    _ NamedColorList: UnsafePointer<cmsNAMEDCOLORLIST>?,
    _ nColor: cmsUInt32Number,
    _ Name: UnsafeMutablePointer<CChar>?,
    _ Prefix: UnsafeMutablePointer<CChar>?,
    _ Suffix: UnsafeMutablePointer<CChar>?,
    _ PCS: UnsafeMutablePointer<cmsUInt16Number>?,
    _ Colorant: UnsafeMutablePointer<cmsUInt16Number>?
) -> cmsBool {
    guard let box = box(NamedColorList), Int(nColor) < box.list.colors.count else { return 0 }
    let color = box.list.colors[Int(nColor)]

    write(color.name, to: Name)
    write(box.list.prefix, to: Prefix)
    write(box.list.suffix, to: Suffix)

    if let PCS {
        PCS[0] = color.pcs.0
        PCS[1] = color.pcs.1
        PCS[2] = color.pcs.2
    }
    if let Colorant {
        // Only the channels this list carries, as the reference copies.
        for i in 0..<box.list.colorantCount { Colorant[i] = color.colorant[i] }
    }

    return 1
}

@c @implementation
public func cmsstrcasecmp(_ s1: UnsafePointer<CChar>?, _ s2: UnsafePointer<CChar>?) -> CInt {
    guard let s1, let s2 else { return s1 == nil && s2 == nil ? 0 : (s1 == nil ? -1 : 1) }
    return caselessCompare(
        bytes(s1, limit: Int.max),
        bytes(s2, limit: Int.max)
    )
}
