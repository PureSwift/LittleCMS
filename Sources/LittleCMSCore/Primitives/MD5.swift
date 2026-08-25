// MD5, as the reference uses it: the profile ID an ICC profile carries in
// its header is the MD5 of the profile with three header fields zeroed.
//
// This is RFC 1321 unmodified — the reference's cmsmd5.c is the usual
// public-domain implementation, whose byte reversal is compiled only on
// big-endian hosts, leaving the standard little-endian word order
// everywhere else.  Its use here is a checksum, never a security claim:
// MD5 is broken for collision resistance, and the ICC specification
// requires it regardless.

/// Streaming MD5.
public struct MD5 {
    private var state: (UInt32, UInt32, UInt32, UInt32) = (
        0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476
    )
    /// Message length in bits, which is what the padding encodes.  The
    /// reference keeps this as two 32-bit words and lets it wrap; the
    /// wider counter is the same arithmetic without the seam.
    private var bitCount: UInt64 = 0
    private var block = [UInt8]()

    public init() {
        block.reserveCapacity(64)
    }

    public mutating func update(_ bytes: some Collection<UInt8>) {
        bitCount &+= UInt64(bytes.count) &* 8

        var remaining = bytes[...]
        while !remaining.isEmpty {
            let wanted = 64 - block.count
            let taking = min(wanted, remaining.count)
            let split = remaining.index(remaining.startIndex, offsetBy: taking)
            block.append(contentsOf: remaining[..<split])
            remaining = remaining[split...]

            if block.count == 64 {
                compress()
                block.removeAll(keepingCapacity: true)
            }
        }
    }

    /// The sixteen digest bytes, with the padding the standard prescribes:
    /// a one bit, zeroes up to the last eight bytes of a block, then the
    /// message length in bits, little-endian.
    public consuming func finish() -> [UInt8] {
        let length = bitCount

        block.append(0x80)
        if block.count > 56 {
            while block.count < 64 { block.append(0) }
            compress()
            block.removeAll(keepingCapacity: true)
        }
        while block.count < 56 { block.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            block.append(UInt8(truncatingIfNeeded: length >> UInt64(shift)))
        }
        compress()

        var digest = [UInt8]()
        digest.reserveCapacity(16)
        for word in [state.0, state.1, state.2, state.3] {
            for shift in stride(from: 0, through: 24, by: 8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return digest
    }

    private mutating func compress() {
        var w = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let base = i * 4
            w[i] = UInt32(block[base])
                | UInt32(block[base + 1]) << 8
                | UInt32(block[base + 2]) << 16
                | UInt32(block[base + 3]) << 24
        }

        var a = state.0
        var b = state.1
        var c = state.2
        var d = state.3

        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i {
            case 0..<16:
                f = d ^ (b & (c ^ d))
                g = i
            case 16..<32:
                f = c ^ (d & (b ^ c))
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }

            f = f &+ a &+ md5Constants[i] &+ w[g]
            a = d
            d = c
            c = b
            b = b &+ (f << md5Shifts[i] | f >> (32 - md5Shifts[i]))
        }

        state.0 &+= a
        state.1 &+= b
        state.2 &+= c
        state.3 &+= d
    }
}

/// `floor(abs(sin(i + 1)) * 2^32)`, the standard's table.
private let md5Constants: [UInt32] = [
    0xD76A_A478, 0xE8C7_B756, 0x2420_70DB, 0xC1BD_CEEE,
    0xF57C_0FAF, 0x4787_C62A, 0xA830_4613, 0xFD46_9501,
    0x6980_98D8, 0x8B44_F7AF, 0xFFFF_5BB1, 0x895C_D7BE,
    0x6B90_1122, 0xFD98_7193, 0xA679_438E, 0x49B4_0821,
    0xF61E_2562, 0xC040_B340, 0x265E_5A51, 0xE9B6_C7AA,
    0xD62F_105D, 0x0244_1453, 0xD8A1_E681, 0xE7D3_FBC8,
    0x21E1_CDE6, 0xC337_07D6, 0xF4D5_0D87, 0x455A_14ED,
    0xA9E3_E905, 0xFCEF_A3F8, 0x676F_02D9, 0x8D2A_4C8A,
    0xFFFA_3942, 0x8771_F681, 0x6D9D_6122, 0xFDE5_380C,
    0xA4BE_EA44, 0x4BDE_CFA9, 0xF6BB_4B60, 0xBEBF_BC70,
    0x289B_7EC6, 0xEAA1_27FA, 0xD4EF_3085, 0x0488_1D05,
    0xD9D4_D039, 0xE6DB_99E5, 0x1FA2_7CF8, 0xC4AC_5665,
    0xF429_2244, 0x432A_FF97, 0xAB94_23A7, 0xFC93_A039,
    0x655B_59C3, 0x8F0C_CC92, 0xFFEF_F47D, 0x8584_5DD1,
    0x6FA8_7E4F, 0xFE2C_E6E0, 0xA301_4314, 0x4E08_11A1,
    0xF753_7E82, 0xBD3A_F235, 0x2AD7_D2BB, 0xEB86_D391,
]

private let md5Shifts: [UInt32] = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]
