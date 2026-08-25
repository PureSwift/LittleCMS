// The parts of the ICC header that are arithmetic rather than plumbing.
//
// The 128-byte header itself is a published layout, so it is read as C
// memory at the boundary; what lives here is the decoding that has a
// right and a wrong answer independent of where the bytes came from.

/// `MAX_TABLE_TAG`: the tag directory is a fixed-size table, and a
/// profile claiming more tags than this is refused rather than grown.
public let maximumTagTableEntries = 100

/// An ICC signature is four characters packed big-endian.  Spelled from
/// the characters rather than as a hex constant: a mistyped hex digit
/// looks like every other hex digit, and these are all four bytes long.
@inlinable
public func iccSignature(_ code: StaticString) -> UInt32 {
    precondition(code.utf8CodeUnitCount == 4)
    let bytes = code.utf8Start
    return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
        | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

/// `'acsp'`, the signature every ICC profile carries.
public let iccMagicNumber = iccSignature("acsp")

/// The header is always exactly this long, whatever the profile says
/// its total size is.
public let iccHeaderSize = 128

/// `_validatedVersion`: the version field is clamped into the shape a
/// version number can actually have, rather than being rejected.
///
/// The bytes are the four as they sit on disk, most significant first,
/// which is why the reference can do this before byte-swapping and get
/// the same answer on either endianness.  Byte 0 is the major version,
/// byte 1 holds minor and revision as two BCD nibbles, and the last two
/// bytes are reserved — a profile that puts anything there loses it.
public func validatedProfileVersion(_ bytes: (UInt8, UInt8, UInt8, UInt8)) -> UInt32 {
    var major = bytes.0
    if major > 0x09 { major = 0x09 }

    var high = bytes.1 & 0xF0
    var low = bytes.1 & 0x0F
    if high > 0x90 { high = 0x90 }
    if low > 0x09 { low = 0x09 }

    return UInt32(major) << 24 | UInt32(high | low) << 16
}

/// Whether a profile class is one the library will open.  Zero is
/// allowed because older versions of the reference wrote it.
public func isValidDeviceClass(_ signature: UInt32) -> Bool {
    if signature == 0 { return true }
    return validDeviceClasses.contains(signature)
}

@usableFromInline
let validDeviceClasses: [UInt32] = [
    iccSignature("scnr"),   // input
    iccSignature("mntr"),   // display
    iccSignature("prtr"),   // output
    iccSignature("link"),
    iccSignature("abst"),   // abstract
    iccSignature("spac"),   // colour space
    iccSignature("nmcl"),   // named colour
    iccSignature("cenc"),   // colour encoding space
    iccSignature("mid "),   // multiplex identification
    iccSignature("mlnk"),   // multiplex link
    iccSignature("mvis"),   // multiplex visualization
]

/// `BaseToBase`: reads the digits of `input` in one base and replays
/// them in another.  This is how the version number crosses between the
/// packed BCD on disk and the decimal a caller asks for, so 0x4200000
/// and 4.2 are the same number spelled two ways.
public func baseToBase(_ input: UInt32, from baseIn: UInt32, to baseOut: UInt32) -> UInt32 {
    var digits = [UInt8](repeating: 0, count: 100)
    var remaining = input
    var length = 0
    while remaining > 0 && length < 100 {
        digits[length] = UInt8(remaining % baseIn)
        remaining /= baseIn
        length += 1
    }

    var result: UInt32 = 0
    var i = length - 1
    while i >= 0 {
        result = result &* baseOut &+ UInt32(digits[i])
        i -= 1
    }
    return result
}
