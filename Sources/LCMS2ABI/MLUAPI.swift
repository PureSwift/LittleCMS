import CLCMS2
import LittleCMS

// The multi-localized string tag, and the widest platform seam in the
// library.
//
// `wchar_t` is four bytes here and two on Windows, while the format and
// the engine both hold UTF-16, so the conversion belongs at the boundary
// and nowhere else.  The reference stores UTF-16 internally too and widens
// on the way out, so a character outside the basic plane is a surrogate
// pair in storage and stays one on the way through — this does the same,
// because a client comparing lengths would notice anything else.

/// The engine's table behind a `cmsMLU*`.
final class MLUBox: HandleBox {
    let mlu: MultiLocalizedUnicode
    let context: cmsContext?

    init(_ mlu: MultiLocalizedUnicode, context: cmsContext?) {
        self.mlu = mlu
        self.context = context
    }
}

/// The box behind a handle the caller has already checked.  The tag
/// layer reaches the translations directly, because the on-disk form is
/// a directory of them rather than anything the accessors expose.
@inline(__always)
func mluBox(_ mlu: UnsafeMutablePointer<cmsMLU>) -> MLUBox {
    Unmanaged<MLUBox>.fromOpaque(UnsafeRawPointer(mlu)).takeUnretainedValue()
}

@inline(__always)
private func box(_ mlu: UnsafeMutablePointer<cmsMLU>?) -> MLUBox? {
    guard let mlu else { return nil }
    return Unmanaged<MLUBox>.fromOpaque(UnsafeRawPointer(mlu)).takeUnretainedValue()
}

@inline(__always)
private func handle(_ box: MLUBox) -> UnsafeMutablePointer<cmsMLU> {
    MLUBox.handle(for: box).assumingMemoryBound(to: cmsMLU.self)
}

@c @implementation
public func cmsMLUalloc(
    _ ContextID: cmsContext?,
    _ nItems: cmsUInt32Number
) -> UnsafeMutablePointer<cmsMLU>? {
    // nItems is a hint about how many translations are coming, not a
    // limit: the reference grows the directory as needed.
    handle(MLUBox(MultiLocalizedUnicode(capacity: Int(nItems)), context: ContextID))
}

@c @implementation
public func cmsMLUfree(_ mlu: UnsafeMutablePointer<cmsMLU>?) {
    guard let mlu else { return }
    _ = MLUBox.consume(UnsafeMutableRawPointer(mlu))
}

@c @implementation
public func cmsMLUdup(_ mlu: UnsafePointer<cmsMLU>?) -> UnsafeMutablePointer<cmsMLU>? {
    guard let source = box(UnsafeMutablePointer(mutating: mlu)) else { return nil }
    return handle(MLUBox(MultiLocalizedUnicode(copying: source.mlu), context: source.context))
}

// -- setting ------------------------------------------------------------

@c @implementation
public func cmsMLUsetWide(
    _ mlu: UnsafeMutablePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ WideString: UnsafePointer<wchar_t>?
) -> cmsBool {
    guard let box = box(mlu), let WideString else { return 0 }

    // Narrowing from the platform's wide character into the UTF-16 the
    // format stores: anything outside the basic plane becomes the
    // surrogate pair it is stored as.
    var text: [UInt16] = []
    var cursor = WideString
    while cursor.pointee != 0 {
        let scalar = UInt32(bitPattern: Int32(cursor.pointee))
        if let unicode = Unicode.Scalar(scalar) {
            text.append(contentsOf: Array(String(unicode).utf16))
        } else {
            // Not a scalar the platform can name; the reference copies
            // the code unit through regardless.
            text.append(UInt16(truncatingIfNeeded: scalar))
        }
        cursor += 1
    }

    return box.mlu.set(
        text,
        language: LocaleCode(twoCharacters: LanguageCode),
        country: LocaleCode(twoCharacters: CountryCode)
    ) ? 1 : 0
}

@c @implementation
public func cmsMLUsetASCII(
    _ mlu: UnsafeMutablePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ ASCIIString: UnsafePointer<CChar>?
) -> cmsBool {
    guard let box = box(mlu), let ASCIIString else { return 0 }

    var text: [UInt16] = []
    var cursor = ASCIIString
    while cursor.pointee != 0 {
        text.append(UInt16(UInt8(bitPattern: cursor.pointee)))
        cursor += 1
    }

    return box.mlu.set(
        text,
        language: LocaleCode(twoCharacters: LanguageCode),
        country: LocaleCode(twoCharacters: CountryCode)
    ) ? 1 : 0
}

@c @implementation
public func cmsMLUsetUTF8(
    _ mlu: UnsafeMutablePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ UTF8String: UnsafePointer<CChar>?
) -> cmsBool {
    guard let box = box(mlu), let UTF8String else { return 0 }

    let text = Array(String(cString: UTF8String).utf16)
    return box.mlu.set(
        text,
        language: LocaleCode(twoCharacters: LanguageCode),
        country: LocaleCode(twoCharacters: CountryCode)
    ) ? 1 : 0
}

// -- getting ------------------------------------------------------------
//
// All three share one protocol: a null buffer asks how much room the
// answer needs, and a buffer too small takes as much as fits and is still
// terminated.  The count returned always includes the terminator.

@inline(__always)
private func found(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ language: UnsafePointer<CChar>?,
    _ country: UnsafePointer<CChar>?
) -> Translation? {
    guard let box = box(UnsafeMutablePointer(mutating: mlu)) else { return nil }
    return box.mlu.lookup(
        language: LocaleCode(twoCharacters: language),
        country: LocaleCode(twoCharacters: country)
    )
}

@c @implementation
public func cmsMLUgetWide(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<wchar_t>?,
    _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let entry = found(mlu, LanguageCode, CountryCode) else { return 0 }

    // The reference measures in bytes of its own storage, so the count
    // is code units either way.
    let units = entry.text.count
    let bytes = cmsUInt32Number((units + 1) * MemoryLayout<wchar_t>.size)

    guard let Buffer else { return bytes }
    if BufferSize == 0 { return 0 }

    var writable = Int(BufferSize) / MemoryLayout<wchar_t>.size
    if writable == 0 { return 0 }
    writable = min(writable - 1, units)

    for i in 0..<writable {
        Buffer[i] = wchar_t(entry.text[i])
    }
    Buffer[writable] = 0
    return cmsUInt32Number((writable + 1) * MemoryLayout<wchar_t>.size)
}

@c @implementation
public func cmsMLUgetASCII(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<CChar>?,
    _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let entry = found(mlu, LanguageCode, CountryCode) else { return 0 }

    var length = entry.text.count
    guard let Buffer else { return cmsUInt32Number(length + 1) }
    if BufferSize == 0 { return 0 }

    if BufferSize < cmsUInt32Number(length + 1) {
        length = Int(BufferSize) - 1
    }

    for i in 0..<length {
        // Anything that will not fit in a byte becomes a question mark,
        // and the boundary is 0xFF rather than 0x80.
        let unit = entry.text[i]
        Buffer[i] = unit < 0xFF ? CChar(bitPattern: UInt8(unit)) : CChar(UInt8(ascii: "?"))
    }
    Buffer[length] = 0
    return cmsUInt32Number(length + 1)
}

@c @implementation
public func cmsMLUgetUTF8(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ Buffer: UnsafeMutablePointer<CChar>?,
    _ BufferSize: cmsUInt32Number
) -> cmsUInt32Number {
    guard let entry = found(mlu, LanguageCode, CountryCode) else { return 0 }

    // The reference's encoder stops at the first NUL, whatever the stored
    // length says; a translation read from a profile usually carries one.
    let units = entry.text.prefix { $0 != 0 }
    let utf8 = Array(String(decoding: units, as: UTF16.self).utf8)
    guard let Buffer else { return cmsUInt32Number(utf8.count + 1) }
    if BufferSize == 0 { return 0 }

    let length = min(utf8.count, Int(BufferSize) - 1)
    for i in 0..<length {
        Buffer[i] = CChar(bitPattern: utf8[i])
    }
    Buffer[length] = 0
    return cmsUInt32Number(length + 1)
}

// -- inspecting ---------------------------------------------------------

@c @implementation
public func cmsMLUtranslationsCount(_ mlu: UnsafePointer<cmsMLU>?) -> cmsUInt32Number {
    guard let box = box(UnsafeMutablePointer(mutating: mlu)) else { return 0 }
    return cmsUInt32Number(box.mlu.translations.count)
}

@c @implementation
public func cmsMLUtranslationsCodes(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ idx: cmsUInt32Number,
    _ LanguageCode: UnsafeMutablePointer<CChar>?,
    _ CountryCode: UnsafeMutablePointer<CChar>?
) -> cmsBool {
    guard let box = box(UnsafeMutablePointer(mutating: mlu)),
          Int(idx) < box.mlu.translations.count
    else { return 0 }

    let entry = box.mlu.translations[Int(idx)]
    write(entry.language, to: LanguageCode)
    write(entry.country, to: CountryCode)
    return 1
}

@c @implementation
public func cmsMLUgetTranslation(
    _ mlu: UnsafePointer<cmsMLU>?,
    _ LanguageCode: UnsafePointer<CChar>?,
    _ CountryCode: UnsafePointer<CChar>?,
    _ ObtainedLanguage: UnsafeMutablePointer<CChar>?,
    _ ObtainedCountry: UnsafeMutablePointer<CChar>?
) -> cmsBool {
    guard let entry = found(mlu, LanguageCode, CountryCode) else { return 0 }
    write(entry.language, to: ObtainedLanguage)
    write(entry.country, to: ObtainedCountry)
    return 1
}

/// Writes a code as the two characters the caller's buffer expects.  The
/// buffers are declared `char[3]` and the reference fills two of them
/// without a terminator, so this does the same.
@inline(__always)
private func write(_ code: LocaleCode, to buffer: UnsafeMutablePointer<CChar>?) {
    guard let buffer else { return }
    let (first, second) = code.characters
    buffer[0] = CChar(bitPattern: first)
    buffer[1] = CChar(bitPattern: second)
}
