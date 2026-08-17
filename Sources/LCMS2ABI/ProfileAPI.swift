import CLCMS2
import LittleCMS

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The profile container: the 128-byte header, the tag directory, and the
// bytes behind each tag.  Nothing here decodes a tag payload — that is
// the tag-type layer, and until it exists a tag is an offset and a size.
//
// _cmsICCPROFILE is declared in lcms2_internal.h, not in either shipped
// header, and the upstream testbed never reaches into it.  So unlike the
// stage data blocks, the profile carries no layout obligation at all: it
// is an ordinary Swift object behind an opaque handle.

/// What a tag is allowed to be serialized as.  Only the shape matters
/// here — the reference compares two descriptors to decide whether two
/// tags sharing a byte range are the same tag under two names.
struct TagDescriptor {
    let elementCount: cmsUInt32Number
    let supportedTypes: [cmsTagTypeSignature]
}

private let tagDescriptors: [cmsTagSignature: TagDescriptor] = {
    func d(
        _ elements: cmsUInt32Number, _ types: [Int32]
    ) -> TagDescriptor {
        TagDescriptor(
            elementCount: elements,
            supportedTypes: types.map { cmsTagTypeSignature(UInt32(bitPattern: $0)) }
        )
    }

    // Transcribed from the reference's SupportedTags, using the C
    // constants rather than their numeric values so a mistyped
    // signature fails to compile instead of failing to match.
    let lut16 = Int32(bitPattern: cmsSigLut16Type.rawValue)
    let lut8 = Int32(bitPattern: cmsSigLut8Type.rawValue)
    let lutAtoB = Int32(bitPattern: cmsSigLutAtoBType.rawValue)
    let lutBtoA = Int32(bitPattern: cmsSigLutBtoAType.rawValue)
    let xyz = Int32(bitPattern: cmsSigXYZType.rawValue)
    // These two are private to the reference's cmstypes.c — they name
    // the malformed types two shipping products once wrote, and appear
    // in no header, so there is no constant to refer to.
    let corbisXYZ = Int32(bitPattern: UInt32(0x17A5_05B8))    // cmsCorbisBrokenXYZtype
    let curve = Int32(bitPattern: cmsSigCurveType.rawValue)
    let parametric = Int32(bitPattern: cmsSigParametricCurveType.rawValue)
    let monacoCurve = Int32(bitPattern: UInt32(0x9478_EE00))  // cmsMonacoBrokenCurveType
    let text = Int32(bitPattern: cmsSigTextType.rawValue)
    let textDescription = Int32(bitPattern: cmsSigTextDescriptionType.rawValue)
    let mlu = Int32(bitPattern: cmsSigMultiLocalizedUnicodeType.rawValue)
    let dateTime = Int32(bitPattern: cmsSigDateTimeType.rawValue)
    let s15 = Int32(bitPattern: cmsSigS15Fixed16ArrayType.rawValue)
    let signature = Int32(bitPattern: cmsSigSignatureType.rawValue)
    let data = Int32(bitPattern: cmsSigDataType.rawValue)
    let mpe = Int32(bitPattern: cmsSigMultiProcessElementType.rawValue)
    let colorantTable = Int32(bitPattern: cmsSigColorantTableType.rawValue)

    var table: [cmsTagSignature: TagDescriptor] = [:]

    for tag in [cmsSigAToB0Tag, cmsSigAToB1Tag, cmsSigAToB2Tag] {
        table[tag] = d(1, [lut16, lutAtoB, lut8])
    }
    for tag in [cmsSigBToA0Tag, cmsSigBToA1Tag, cmsSigBToA2Tag,
                cmsSigGamutTag, cmsSigPreview0Tag, cmsSigPreview1Tag, cmsSigPreview2Tag] {
        table[tag] = d(1, [lut16, lutBtoA, lut8])
    }
    for tag in [cmsSigRedColorantTag, cmsSigGreenColorantTag, cmsSigBlueColorantTag] {
        table[tag] = d(1, [xyz, corbisXYZ])
    }
    for tag in [cmsSigRedTRCTag, cmsSigGreenTRCTag, cmsSigBlueTRCTag] {
        table[tag] = d(1, [curve, parametric, monacoCurve])
    }
    for tag in [cmsSigCalibrationDateTimeTag, cmsSigDateTimeTag] {
        table[tag] = d(1, [dateTime])
    }
    table[cmsSigCharTargetTag] = d(1, [text])
    table[cmsSigChromaticAdaptationTag] = d(9, [s15])
    table[cmsSigChromaticityTag] = d(1, [Int32(bitPattern: cmsSigChromaticityType.rawValue)])
    table[cmsSigColorantOrderTag] = d(1, [Int32(bitPattern: cmsSigColorantOrderType.rawValue)])
    table[cmsSigColorantTableTag] = d(1, [colorantTable])
    table[cmsSigColorantTableOutTag] = d(1, [colorantTable])
    table[cmsSigCopyrightTag] = d(1, [text, mlu, textDescription])
    for tag in [cmsSigDeviceMfgDescTag, cmsSigDeviceModelDescTag,
                cmsSigProfileDescriptionTag, cmsSigViewingCondDescTag] {
        table[tag] = d(1, [textDescription, mlu, text])
    }
    table[cmsSigGrayTRCTag] = d(1, [curve, parametric])
    table[cmsSigLuminanceTag] = d(1, [xyz])
    table[cmsSigMediaBlackPointTag] = d(1, [xyz, corbisXYZ])
    table[cmsSigMediaWhitePointTag] = d(1, [xyz, corbisXYZ])
    table[cmsSigNamedColor2Tag] = d(1, [Int32(bitPattern: cmsSigNamedColor2Type.rawValue)])
    for tag in [cmsSigColorimetricIntentImageStateTag,
                cmsSigPerceptualRenderingIntentGamutTag,
                cmsSigSaturationRenderingIntentGamutTag,
                cmsSigTechnologyTag] {
        table[tag] = d(1, [signature])
    }
    table[cmsSigMeasurementTag] = d(1, [Int32(bitPattern: cmsSigMeasurementType.rawValue)])
    for tag in [cmsSigPs2CRD0Tag, cmsSigPs2CRD1Tag, cmsSigPs2CRD2Tag, cmsSigPs2CRD3Tag,
                cmsSigPs2CSATag, cmsSigPs2RenderingIntentTag] {
        table[tag] = d(1, [data])
    }
    for tag in [cmsSigDToB0Tag, cmsSigDToB1Tag, cmsSigDToB2Tag, cmsSigDToB3Tag,
                cmsSigBToD0Tag, cmsSigBToD1Tag, cmsSigBToD2Tag, cmsSigBToD3Tag] {
        table[tag] = d(1, [mpe])
    }
    table[cmsSigProfileSequenceDescTag] =
        d(1, [Int32(bitPattern: cmsSigProfileSequenceDescType.rawValue)])
    table[cmsSigScreeningDescTag] = d(1, [textDescription])
    table[cmsSigViewingConditionsTag] =
        d(1, [Int32(bitPattern: cmsSigViewingConditionsType.rawValue)])
    table[cmsSigUcrBgTag] = d(1, [Int32(bitPattern: cmsSigUcrBgType.rawValue)])
    table[cmsSigCrdInfoTag] = d(1, [Int32(bitPattern: cmsSigCrdInfoType.rawValue)])
    table[cmsSigScreeningTag] = d(1, [Int32(bitPattern: cmsSigScreeningType.rawValue)])
    table[cmsSigVcgtTag] = d(1, [Int32(bitPattern: cmsSigVcgtType.rawValue)])
    table[cmsSigMetaTag] = d(1, [Int32(bitPattern: cmsSigDictType.rawValue)])
    table[cmsSigProfileSequenceIdTag] =
        d(1, [Int32(bitPattern: cmsSigProfileSequenceIdType.rawValue)])
    table[cmsSigProfileDescriptionMLTag] = d(1, [mlu])
    table[cmsSigArgyllArtsTag] = d(9, [s15])
    table[cmsSigcicpTag] = d(1, [Int32(bitPattern: cmsSigcicpType.rawValue)])
    table[cmsSigMHC2Tag] = d(1, [Int32(bitPattern: cmsSigMHC2Type.rawValue)])

    return table
}()

/// `CompatibleTypes`: two tags that occupy the same bytes are the same
/// tag under two names only if they could have been serialized the same
/// way.  An unknown tag matches nothing, including another unknown one.
private func compatible(_ a: cmsTagSignature, _ b: cmsTagSignature) -> Bool {
    guard let first = tagDescriptors[a], let second = tagDescriptors[b] else { return false }
    guard first.elementCount == second.elementCount,
          first.supportedTypes.count == second.supportedTypes.count
    else { return false }
    return first.supportedTypes == second.supportedTypes
}

// -- the profile ----------------------------------------------------------

final class ProfileBox: HandleBox {
    let context: cmsContext?
    var io: UnsafeMutablePointer<cmsIOHANDLER>?
    var isWrite = false

    var created = tm()
    var cmm: cmsUInt32Number = 0
    var version: cmsUInt32Number = 0
    var deviceClass = cmsProfileClassSignature(0)
    var colorSpace = cmsColorSpaceSignature(0)
    var pcs = cmsColorSpaceSignature(0)
    var renderingIntent: cmsUInt32Number = 0
    var platform = cmsPlatformSignature(0)
    var flags: cmsUInt32Number = 0
    var manufacturer: cmsUInt32Number = 0
    var model: cmsUInt32Number = 0
    var attributes: cmsUInt64Number = 0
    var creator: cmsUInt32Number = 0
    var profileID = cmsProfileID()

    // The directory is a fixed-width table in the reference, and one
    // accessor reads the slot one past the end, so the width is part of
    // the behaviour rather than an implementation detail.
    var tagCount = 0
    var tagNames = [cmsTagSignature](repeating: cmsTagSignature(0), count: maximumTagTableEntries)
    var tagLinked = [cmsTagSignature](repeating: cmsTagSignature(0), count: maximumTagTableEntries)
    var tagOffsets = [cmsUInt32Number](repeating: 0, count: maximumTagTableEntries)
    var tagSizes = [cmsUInt32Number](repeating: 0, count: maximumTagTableEntries)

    var mutex: UnsafeMutableRawPointer?

    init(context: cmsContext?) {
        self.context = context
    }

    /// `SearchOneTag`, and the link-following loop around it.
    func search(_ sig: cmsTagSignature, followLinks: Bool) -> Int? {
        var target = sig
        while true {
            var found: Int?
            for i in 0..<tagCount where tagNames[i] == target {
                found = i
                break
            }
            guard let n = found else { return nil }
            if !followLinks { return n }
            let linked = tagLinked[n]
            if linked == cmsTagSignature(0) { return n }
            target = linked
        }
    }
}

@inline(__always)
private func profile(_ h: cmsHPROFILE?) -> ProfileBox? {
    guard let h else { return nil }
    return Unmanaged<ProfileBox>.fromOpaque(h).takeUnretainedValue()
}

// -- creation and destruction ---------------------------------------------

@c @implementation
public func cmsCreateProfilePlaceholder(_ ContextID: cmsContext?) -> cmsHPROFILE? {
    let box = ProfileBox(context: ContextID)

    box.version = 0x0210_0000
    // Created by Little CMS, and claiming to be it: a plugin that checks
    // the CMM signature has to see the same answer.
    box.cmm = cmsUInt32Number(lcmsSignature)
    box.creator = cmsUInt32Number(lcmsSignature)
    box.platform = cmsSigMacintosh
    box.deviceClass = cmsSigDisplayClass

    var now = time_t()
    time(&now)
    guard gmtime_r(&now, &box.created) != nil else { return nil }

    box.mutex = _cmsCreateMutex(ContextID)
    return ProfileBox.handle(for: box)
}

@c @implementation
public func cmsCloseProfile(_ hProfile: cmsHPROFILE?) -> cmsBool {
    guard let hProfile, let box = profile(hProfile) else { return 0 }
    var result: cmsBool = 1

    if let io = box.io {
        result &= cmsCloseIOhandler(io)
        box.io = nil
    }
    _cmsDestroyMutex(box.context, box.mutex)

    _ = ProfileBox.consume(hProfile)
    return result
}

@c @implementation
public func cmsGetProfileContextID(_ hProfile: cmsHPROFILE?) -> cmsContext? {
    profile(hProfile)?.context
}

@c @implementation
public func cmsGetProfileIOhandler(
    _ hProfile: cmsHPROFILE?
) -> UnsafeMutablePointer<cmsIOHANDLER>? {
    profile(hProfile)?.io
}

// -- reading the header ----------------------------------------------------

/// `_cmsReadHeader`.  Everything a profile claims about itself is
/// checked against what the file can actually hold: a tag that runs past
/// the end is dropped rather than trusted, and a size larger than the
/// file is cut down to the file.
private func readHeader(_ box: ProfileBox) -> Bool {
    guard let io = box.io, let read = io.pointee.Read else { return false }

    var header = cmsICCHeader()
    let got = withUnsafeMutableBytes(of: &header) { buffer in
        read(io, buffer.baseAddress, cmsUInt32Number(MemoryLayout<cmsICCHeader>.size), 1)
    }
    if got != 1 { return false }

    if _cmsAdjustEndianess32(header.magic) != cmsUInt32Number(iccMagicNumber) {
        report(
            cmsUInt32Number(cmsERROR_BAD_SIGNATURE),
            "not an ICC profile, invalid signature", to: box.context
        )
        return false
    }

    box.cmm = _cmsAdjustEndianess32(header.cmmId)
    box.deviceClass = cmsProfileClassSignature(_cmsAdjustEndianess32(header.deviceClass.rawValue))
    box.colorSpace = cmsColorSpaceSignature(_cmsAdjustEndianess32(header.colorSpace.rawValue))
    box.pcs = cmsColorSpaceSignature(_cmsAdjustEndianess32(header.pcs.rawValue))
    box.renderingIntent = _cmsAdjustEndianess32(header.renderingIntent)
    box.platform = cmsPlatformSignature(_cmsAdjustEndianess32(header.platform.rawValue))
    box.flags = _cmsAdjustEndianess32(header.flags)
    box.manufacturer = _cmsAdjustEndianess32(header.manufacturer)
    box.model = _cmsAdjustEndianess32(header.model)
    box.creator = _cmsAdjustEndianess32(header.creator)
    _cmsAdjustEndianess64(&box.attributes, &header.attributes)

    // The version is clamped on the disk bytes, before any swapping —
    // which is what makes the answer the same on either endianness.
    box.version = withUnsafeBytes(of: &header.version) { raw in
        validatedProfileVersion((raw[0], raw[1], raw[2], raw[3]))
    }

    if box.version > 0x0500_0000 {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unsupported profile version '0x\(String(box.version, radix: 16))'",
            to: box.context
        )
        return false
    }
    if !isValidDeviceClass(box.deviceClass.rawValue) {
        report(
            cmsUInt32Number(cmsERROR_UNKNOWN_EXTENSION),
            "Unsupported device class '0x\(String(box.deviceClass.rawValue, radix: 16))'",
            to: box.context
        )
        return false
    }

    var headerSize = _cmsAdjustEndianess32(header.size)
    if headerSize >= io.pointee.ReportedSize { headerSize = io.pointee.ReportedSize }

    _cmsDecodeDateTimeNumber(&header.date, &box.created)
    withUnsafeBytes(of: &header.profileID) { source in
        withUnsafeMutableBytes(of: &box.profileID) { destination in
            destination.copyMemory(from: source)
        }
    }

    var declared: cmsUInt32Number = 0
    if _cmsReadUInt32Number(io, &declared) == 0 { return false }
    if declared > cmsUInt32Number(maximumTagTableEntries) {
        report(cmsUInt32Number(cmsERROR_RANGE), "Too many tags (\(declared))", to: box.context)
        return false
    }

    box.tagCount = 0
    for _ in 0..<Int(declared) {
        var sig: cmsUInt32Number = 0
        var offset: cmsUInt32Number = 0
        var size: cmsUInt32Number = 0
        if _cmsReadUInt32Number(io, &sig) == 0 { return false }
        if _cmsReadUInt32Number(io, &offset) == 0 { return false }
        if _cmsReadUInt32Number(io, &size) == 0 { return false }

        // A tag that does not fall inside the file is skipped, not
        // refused: profiles in the wild carry them.
        if size == 0 || offset == 0 { continue }
        if offset &+ size > headerSize || offset &+ size < offset { continue }

        let n = box.tagCount
        box.tagNames[n] = cmsTagSignature(sig)
        box.tagOffsets[n] = offset
        box.tagSizes[n] = size

        // Two tags over the same bytes are one tag under two names, but
        // only if both could have been written the same way.
        for j in 0..<n where box.tagOffsets[j] == offset && box.tagSizes[j] == size {
            if compatible(box.tagNames[j], cmsTagSignature(sig)) {
                box.tagLinked[n] = box.tagNames[j]
            }
        }

        box.tagCount += 1
    }

    for i in 0..<box.tagCount {
        for j in 0..<box.tagCount where i != j && box.tagNames[i] == box.tagNames[j] {
            report(cmsUInt32Number(cmsERROR_RANGE), "Duplicate tag found", to: box.context)
            return false
        }
    }

    return true
}

// -- opening ---------------------------------------------------------------

@c @implementation
public func cmsOpenProfileFromIOhandlerTHR(
    _ ContextID: cmsContext?,
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?
) -> cmsHPROFILE? {
    guard let handle = cmsCreateProfilePlaceholder(ContextID), let box = profile(handle)
    else { return nil }
    box.io = io
    if !readHeader(box) {
        _ = cmsCloseProfile(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsOpenProfileFromIOhandler2THR(
    _ ContextID: cmsContext?,
    _ io: UnsafeMutablePointer<cmsIOHANDLER>?,
    _ write: cmsBool
) -> cmsHPROFILE? {
    guard let handle = cmsCreateProfilePlaceholder(ContextID), let box = profile(handle)
    else { return nil }
    box.io = io
    // Opened for writing, there is nothing to read: the header will be
    // whatever the caller sets before saving.
    if write != 0 {
        box.isWrite = true
        return handle
    }
    if !readHeader(box) {
        _ = cmsCloseProfile(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsOpenProfileFromFileTHR(
    _ ContextID: cmsContext?,
    _ lpFileName: UnsafePointer<CChar>?,
    _ sAccess: UnsafePointer<CChar>?
) -> cmsHPROFILE? {
    guard let handle = cmsCreateProfilePlaceholder(ContextID), let box = profile(handle)
    else { return nil }

    box.io = cmsOpenIOhandlerFromFile(ContextID, lpFileName, sAccess)
    if box.io == nil {
        _ = cmsCloseProfile(handle)
        return nil
    }

    if let sAccess, sAccess[0] == CChar(UInt8(ascii: "W")) || sAccess[0] == CChar(UInt8(ascii: "w")) {
        box.isWrite = true
        return handle
    }
    if !readHeader(box) {
        _ = cmsCloseProfile(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsOpenProfileFromMemTHR(
    _ ContextID: cmsContext?,
    _ MemPtr: UnsafeRawPointer?,
    _ dwSize: cmsUInt32Number
) -> cmsHPROFILE? {
    guard let handle = cmsCreateProfilePlaceholder(ContextID), let box = profile(handle)
    else { return nil }

    box.io = cmsOpenIOhandlerFromMem(
        ContextID, UnsafeMutableRawPointer(mutating: MemPtr), dwSize, "r"
    )
    if box.io == nil {
        _ = cmsCloseProfile(handle)
        return nil
    }
    if !readHeader(box) {
        _ = cmsCloseProfile(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsOpenProfileFromStreamTHR(
    _ ContextID: cmsContext?,
    _ ICCProfile: UnsafeMutablePointer<FILE>?,
    _ sAccess: UnsafePointer<CChar>?
) -> cmsHPROFILE? {
    guard let handle = cmsCreateProfilePlaceholder(ContextID), let box = profile(handle)
    else { return nil }

    box.io = cmsOpenIOhandlerFromStream(ContextID, ICCProfile)
    if box.io == nil {
        _ = cmsCloseProfile(handle)
        return nil
    }
    if let sAccess, sAccess[0] == CChar(UInt8(ascii: "W")) || sAccess[0] == CChar(UInt8(ascii: "w")) {
        box.isWrite = true
        return handle
    }
    if !readHeader(box) {
        _ = cmsCloseProfile(handle)
        return nil
    }
    return handle
}

@c @implementation
public func cmsOpenProfileFromFile(
    _ ICCProfile: UnsafePointer<CChar>?,
    _ sAccess: UnsafePointer<CChar>?
) -> cmsHPROFILE? {
    cmsOpenProfileFromFileTHR(nil, ICCProfile, sAccess)
}

@c @implementation
public func cmsOpenProfileFromMem(
    _ MemPtr: UnsafeRawPointer?,
    _ dwSize: cmsUInt32Number
) -> cmsHPROFILE? {
    cmsOpenProfileFromMemTHR(nil, MemPtr, dwSize)
}

@c @implementation
public func cmsOpenProfileFromStream(
    _ ICCProfile: UnsafeMutablePointer<FILE>?,
    _ sAccess: UnsafePointer<CChar>?
) -> cmsHPROFILE? {
    cmsOpenProfileFromStreamTHR(nil, ICCProfile, sAccess)
}

// -- the tag directory ------------------------------------------------------

@c @implementation
public func cmsGetTagCount(_ hProfile: cmsHPROFILE?) -> cmsInt32Number {
    guard let box = profile(hProfile) else { return -1 }
    return cmsInt32Number(box.tagCount)
}

@c @implementation
public func cmsGetTagSignature(
    _ hProfile: cmsHPROFILE?,
    _ n: cmsUInt32Number
) -> cmsTagSignature {
    guard let box = profile(hProfile) else { return cmsTagSignature(0) }
    // The bound is `>`, not `>=`: asking for the slot one past the last
    // tag reads the table's next entry, which is zero on a profile that
    // has only ever been read.  Reproduced rather than tightened.
    if Int(n) > box.tagCount { return cmsTagSignature(0) }
    if Int(n) >= maximumTagTableEntries { return cmsTagSignature(0) }
    return box.tagNames[Int(n)]
}

@c @implementation
public func cmsGetTagOffsetAndSize(
    _ hProfile: cmsHPROFILE?,
    _ n: cmsUInt32Number,
    _ offset: UnsafeMutablePointer<cmsUInt32Number>?,
    _ size: UnsafeMutablePointer<cmsUInt32Number>?
) -> cmsBool {
    guard let box = profile(hProfile) else { return 0 }
    if Int(n) > box.tagCount { return 0 }
    if Int(n) >= maximumTagTableEntries { return 0 }
    offset?.pointee = box.tagOffsets[Int(n)]
    size?.pointee = box.tagSizes[Int(n)]
    return 1
}

@c @implementation
public func cmsIsTag(_ hProfile: cmsHPROFILE?, _ sig: cmsTagSignature) -> cmsBool {
    guard let box = profile(hProfile) else { return 0 }
    return box.search(sig, followLinks: false) != nil ? 1 : 0
}

@c @implementation
public func cmsTagLinkedTo(
    _ hProfile: cmsHPROFILE?,
    _ sig: cmsTagSignature
) -> cmsTagSignature {
    guard let box = profile(hProfile), let i = box.search(sig, followLinks: false)
    else { return cmsTagSignature(0) }
    return box.tagLinked[i]
}

/// Reads a tag's bytes as they sit in the file.  Nothing has been
/// decoded yet, so every tag takes the on-disk path; the reference also
/// serializes tags held in memory, which cannot arise until a tag can be
/// held in memory.
@c @implementation
public func cmsReadRawTag(
    _ hProfile: cmsHPROFILE?,
    _ sig: cmsTagSignature,
    _ data: UnsafeMutableRawPointer?,
    _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let box = profile(hProfile) else { return 0 }
    if data != nil && BufferSize == 0 { return 0 }
    if _cmsLockMutex(box.context, box.mutex) == 0 { return 0 }
    defer { _cmsUnlockMutex(box.context, box.mutex) }

    guard let i = box.search(sig, followLinks: true) else { return 0 }

    guard let data else { return box.tagSizes[i] }

    guard let io = box.io, let seek = io.pointee.Seek, let read = io.pointee.Read
    else { return 0 }

    var size = box.tagSizes[i]
    if BufferSize < size { size = BufferSize }
    if seek(io, box.tagOffsets[i]) == 0 { return 0 }
    if read(io, data, 1, size) == 0 { return 0 }
    return size
}

// -- header accessors --------------------------------------------------------

@c @implementation
public func cmsGetColorSpace(_ hProfile: cmsHPROFILE?) -> cmsColorSpaceSignature {
    profile(hProfile)?.colorSpace ?? cmsColorSpaceSignature(0)
}

@c @implementation
public func cmsSetColorSpace(_ hProfile: cmsHPROFILE?, _ sig: cmsColorSpaceSignature) {
    profile(hProfile)?.colorSpace = sig
}

@c @implementation
public func cmsGetPCS(_ hProfile: cmsHPROFILE?) -> cmsColorSpaceSignature {
    profile(hProfile)?.pcs ?? cmsColorSpaceSignature(0)
}

@c @implementation
public func cmsSetPCS(_ hProfile: cmsHPROFILE?, _ pcs: cmsColorSpaceSignature) {
    profile(hProfile)?.pcs = pcs
}

@c @implementation
public func cmsGetDeviceClass(_ hProfile: cmsHPROFILE?) -> cmsProfileClassSignature {
    profile(hProfile)?.deviceClass ?? cmsProfileClassSignature(0)
}

@c @implementation
public func cmsSetDeviceClass(_ hProfile: cmsHPROFILE?, _ sig: cmsProfileClassSignature) {
    profile(hProfile)?.deviceClass = sig
}

@c @implementation
public func cmsGetHeaderRenderingIntent(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.renderingIntent ?? 0
}

@c @implementation
public func cmsSetHeaderRenderingIntent(_ hProfile: cmsHPROFILE?, _ RenderingIntent: cmsUInt32Number) {
    profile(hProfile)?.renderingIntent = RenderingIntent
}

@c @implementation
public func cmsGetHeaderFlags(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.flags ?? 0
}

@c @implementation
public func cmsSetHeaderFlags(_ hProfile: cmsHPROFILE?, _ Flags: cmsUInt32Number) {
    profile(hProfile)?.flags = Flags
}

@c @implementation
public func cmsGetHeaderManufacturer(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.manufacturer ?? 0
}

@c @implementation
public func cmsSetHeaderManufacturer(_ hProfile: cmsHPROFILE?, _ manufacturer: cmsUInt32Number) {
    profile(hProfile)?.manufacturer = manufacturer
}

@c @implementation
public func cmsGetHeaderModel(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.model ?? 0
}

@c @implementation
public func cmsSetHeaderModel(_ hProfile: cmsHPROFILE?, _ model: cmsUInt32Number) {
    profile(hProfile)?.model = model
}

@c @implementation
public func cmsGetHeaderCreator(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.creator ?? 0
}

@c @implementation
public func cmsGetHeaderCMM(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.cmm ?? 0
}

@c @implementation
public func cmsGetHeaderAttributes(
    _ hProfile: cmsHPROFILE?,
    _ Flags: UnsafeMutablePointer<cmsUInt64Number>?
) {
    guard let box = profile(hProfile) else { return }
    Flags?.pointee = box.attributes
}

@c @implementation
public func cmsSetHeaderAttributes(_ hProfile: cmsHPROFILE?, _ Flags: cmsUInt64Number) {
    profile(hProfile)?.attributes = Flags
}

@c @implementation
public func cmsGetHeaderProfileID(
    _ hProfile: cmsHPROFILE?,
    _ ProfileID: UnsafeMutablePointer<cmsUInt8Number>?
) {
    guard let box = profile(hProfile), let ProfileID else { return }
    withUnsafeBytes(of: box.profileID) { source in
        UnsafeMutableRawBufferPointer(start: ProfileID, count: 16)
            .copyMemory(from: source)
    }
}

@c @implementation
public func cmsSetHeaderProfileID(
    _ hProfile: cmsHPROFILE?,
    _ ProfileID: UnsafeMutablePointer<cmsUInt8Number>?
) {
    guard let box = profile(hProfile), let ProfileID else { return }
    withUnsafeMutableBytes(of: &box.profileID) { destination in
        destination.copyMemory(from: UnsafeRawBufferPointer(start: ProfileID, count: 16))
    }
}

@c @implementation
public func cmsGetHeaderCreationDateTime(
    _ hProfile: cmsHPROFILE?,
    _ Dest: UnsafeMutablePointer<tm>?
) -> cmsBool {
    guard let box = profile(hProfile), let Dest else { return 0 }
    Dest.pointee = box.created
    return 1
}

/// The version crosses between the packed nibbles on disk and the
/// decimal a caller reads: 0x4200000 and 4.2 are the same number.
@c @implementation
public func cmsGetProfileVersion(_ hProfile: cmsHPROFILE?) -> cmsFloat64Number {
    guard let box = profile(hProfile) else { return 0 }
    return cmsFloat64Number(baseToBase(box.version >> 16, from: 16, to: 10)) / 100.0
}

@c @implementation
public func cmsSetProfileVersion(_ hProfile: cmsHPROFILE?, _ Version: cmsFloat64Number) {
    guard let box = profile(hProfile) else { return }
    box.version = baseToBase(
        cmsUInt32Number((Version * 100.0 + 0.5).rounded(.down)), from: 10, to: 16
    ) << 16
}

@c @implementation
public func cmsGetEncodedICCversion(_ hProfile: cmsHPROFILE?) -> cmsUInt32Number {
    profile(hProfile)?.version ?? 0
}

@c @implementation
public func cmsSetEncodedICCversion(_ hProfile: cmsHPROFILE?, _ Version: cmsUInt32Number) {
    profile(hProfile)?.version = Version
}

// -- colour space arithmetic -------------------------------------------------

/// How many channels a colour space carries.  The `MCHn` and `ncolor`
/// spellings of the same width both answer the same.
@c @implementation
public func cmsChannelsOfColorSpace(_ ColorSpace: cmsColorSpaceSignature) -> cmsInt32Number {
    switch ColorSpace {
    case cmsSigMCH1Data, cmsSig1colorData, cmsSigGrayData: return 1
    case cmsSigMCH2Data, cmsSig2colorData: return 2
    case cmsSigXYZData, cmsSigLabData, cmsSigLuvData, cmsSigYCbCrData, cmsSigYxyData,
         cmsSigRgbData, cmsSigHsvData, cmsSigHlsData, cmsSigCmyData,
         cmsSigMCH3Data, cmsSig3colorData: return 3
    case cmsSigLuvKData, cmsSigCmykData, cmsSigMCH4Data, cmsSig4colorData: return 4
    case cmsSigMCH5Data, cmsSig5colorData: return 5
    case cmsSigMCH6Data, cmsSig6colorData: return 6
    case cmsSigMCH7Data, cmsSig7colorData: return 7
    case cmsSigMCH8Data, cmsSig8colorData: return 8
    case cmsSigMCH9Data, cmsSig9colorData: return 9
    case cmsSigMCHAData, cmsSig10colorData: return 10
    case cmsSigMCHBData, cmsSig11colorData: return 11
    case cmsSigMCHCData, cmsSig12colorData: return 12
    case cmsSigMCHDData, cmsSig13colorData: return 13
    case cmsSigMCHEData, cmsSig14colorData: return 14
    case cmsSigMCHFData, cmsSig15colorData: return 15
    default: return -1
    }
}

// -- the date-time field -----------------------------------------------------

@c @implementation
public func _cmsDecodeDateTimeNumber(
    _ Source: UnsafePointer<cmsDateTimeNumber>?,
    _ Dest: UnsafeMutablePointer<tm>?
) {
    guard let Source, let Dest else { return }
    Dest.pointee.tm_sec = Int32(_cmsAdjustEndianess16(Source.pointee.seconds))
    Dest.pointee.tm_min = Int32(_cmsAdjustEndianess16(Source.pointee.minutes))
    Dest.pointee.tm_hour = Int32(_cmsAdjustEndianess16(Source.pointee.hours))
    Dest.pointee.tm_mday = Int32(_cmsAdjustEndianess16(Source.pointee.day))
    Dest.pointee.tm_mon = Int32(_cmsAdjustEndianess16(Source.pointee.month)) - 1
    Dest.pointee.tm_year = Int32(_cmsAdjustEndianess16(Source.pointee.year)) - 1900
    // Not computed from the rest: the reference marks them unknown.
    Dest.pointee.tm_wday = -1
    Dest.pointee.tm_yday = -1
    Dest.pointee.tm_isdst = 0
}

@c @implementation
public func _cmsEncodeDateTimeNumber(
    _ Dest: UnsafeMutablePointer<cmsDateTimeNumber>?,
    _ Source: UnsafePointer<tm>?
) {
    guard let Dest, let Source else { return }
    Dest.pointee.seconds = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_sec))
    Dest.pointee.minutes = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_min))
    Dest.pointee.hours = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_hour))
    Dest.pointee.day = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_mday))
    Dest.pointee.month = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_mon + 1))
    Dest.pointee.year = _cmsAdjustEndianess16(cmsUInt16Number(truncatingIfNeeded: Source.pointee.tm_year + 1900))
}
