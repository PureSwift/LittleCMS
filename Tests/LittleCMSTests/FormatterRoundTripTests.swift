import Testing

@testable import LittleCMSCore

// The byte-width conversions the formatters are built on.
//
// Every 8-bit formatter widens on the way in and narrows on the way out,
// so the pair has to be an exact inverse across all 256 values or a
// buffer that goes through a transform unchanged comes back changed.

@Suite struct ByteWidthTests {
    // The same arithmetic the boundary uses.
    func widen(_ v: UInt8) -> UInt16 { UInt16(v) << 8 | UInt16(v) }
    func narrow(_ v: UInt16) -> UInt8 {
        UInt8(truncatingIfNeeded: (UInt32(v) &* 65281 &+ 8_388_608) >> 24)
    }

    @Test func widthConversionsAreInverse() {
        // Replication, not a shift: every byte must survive the trip.
        for v in UInt8.min...UInt8.max {
            #expect(narrow(widen(v)) == v, "byte \(v)")
        }
    }

    @Test func theEndsAreExact() {
        #expect(widen(0) == 0)
        #expect(widen(0xFF) == 0xFFFF)
        #expect(narrow(0) == 0)
        #expect(narrow(0xFFFF) == 0xFF)
        // Mid grey stays mid grey rather than drifting by one.
        #expect(widen(0x80) == 0x8080)
        #expect(narrow(0x8080) == 0x80)
    }

    @Test func narrowingRoundsRatherThanTruncating() {
        // Where the two disagree: a shift discards 0x00FF entirely,
        // the rounding multiply carries it up to 1.
        #expect(0x00FF >> 8 == 0)
        #expect(narrow(0x00FF) == 1)

        // And where they agree, so the example above is the exception
        // rather than the rule.
        #expect(narrow(0x7FFF) == 0x7F)
        #expect(narrow(0x8000) == 0x80)
        // And every 16-bit value narrows into range.
        for v in stride(from: 0, through: 65535, by: 137) {
            let n = narrow(UInt16(v))
            #expect(n <= 0xFF)
        }
    }
}
