import LittleCMS
import Testing

@Suite
struct MD5Tests {
    static func hex(_ input: String) -> String {
        var md5 = MD5()
        md5.update(Array(input.utf8))
        let digits = Array("0123456789abcdef")
        return String(md5.finish().flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0xF)]] })
    }

    /// The seven vectors in RFC 1321, appendix A.5.
    @Test(arguments: [
        ("", "d41d8cd98f00b204e9800998ecf8427e"),
        ("a", "0cc175b9c0f1b6a831c399e269772661"),
        ("abc", "900150983cd24fb0d6963f7d28e17f72"),
        ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
        (
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            "d174ab98d277d9f5a5611c2c9f419d9f"
        ),
        (
            "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
            "57edf4a22be3c955ac49da2e2107b67a"
        ),
    ])
    func rfc1321Vectors(input: String, expected: String) {
        #expect(Self.hex(input) == expected)
    }

    /// The block boundary is where a streaming hash goes wrong, so every
    /// length either side of 56 (the padding threshold) and 64 (the block)
    /// is checked against a single-shot hash of the same bytes.
    @Test
    func chunkingDoesNotChangeTheDigest() {
        let message = (0..<200).map { UInt8($0 % 251) }

        for length in 0...200 {
            let whole = Array(message.prefix(length))

            var single = MD5()
            single.update(whole)
            let expected = single.finish()

            for chunk in [1, 7, 55, 56, 57, 63, 64, 65] {
                var streamed = MD5()
                var offset = 0
                while offset < whole.count {
                    let end = min(offset + chunk, whole.count)
                    streamed.update(whole[offset..<end])
                    offset = end
                }
                #expect(streamed.finish() == expected, "length \(length), chunk \(chunk)")
            }
        }
    }
}
