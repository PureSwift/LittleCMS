import Testing

@testable import LittleCMSCore

// The header arithmetic, pinned directly rather than only through the C
// API — these are the pieces the Embedded build also compiles, where no
// differential runs.

@Suite struct ProfileHeaderTests {
    @Test func signaturesArePackedBigEndian() {
        #expect(iccSignature("acsp") == 0x6163_7370)
        #expect(iccMagicNumber == 0x6163_7370)
        #expect(iccSignature("mntr") == 0x6D6E_7472)
        #expect(iccSignature("abst") == 0x6162_7374)
        #expect(iccSignature("mid ") == 0x6D69_6420)
    }

    @Test func deviceClassesAreTheElevenPlusZero() {
        // Zero is allowed because older versions of the reference wrote it.
        #expect(isValidDeviceClass(0))
        let classes: [UInt32] = [
            iccSignature("scnr"), iccSignature("mntr"), iccSignature("prtr"),
            iccSignature("link"), iccSignature("abst"), iccSignature("spac"),
            iccSignature("nmcl"), iccSignature("cenc"), iccSignature("mid "),
            iccSignature("mlnk"), iccSignature("mvis"),
        ]
        #expect(classes.count == 11)
        for code in classes {
            #expect(isValidDeviceClass(code), "\(String(code, radix: 16))")
        }
        #expect(!isValidDeviceClass(iccSignature("zzzz")))
        #expect(!isValidDeviceClass(iccSignature("acsp")))
    }

    @Test func versionIsClampedRatherThanRejected() {
        // Already legal: unchanged apart from the reserved bytes.
        #expect(validatedProfileVersion((0x02, 0x40, 0x00, 0x00)) == 0x0240_0000)
        // The reserved bytes are discarded whatever they hold.
        #expect(validatedProfileVersion((0x04, 0x30, 0xAB, 0xCD)) == 0x0430_0000)
        // Major above 9 clamps to 9.
        #expect(validatedProfileVersion((0xFF, 0x00, 0x00, 0x00)) == 0x0900_0000)
        // Each nibble of the second byte clamps on its own.
        #expect(validatedProfileVersion((0x02, 0x4F, 0x00, 0x00)) == 0x0249_0000)
        #expect(validatedProfileVersion((0x02, 0xF0, 0x00, 0x00)) == 0x0290_0000)
        #expect(validatedProfileVersion((0x02, 0xFF, 0x00, 0x00)) == 0x0299_0000)
    }

    @Test func versionCrossesBasesBothWays() {
        // 0x4200000 >> 16 is 0x420, whose digits read in decimal are 420,
        // which is 4.20 once divided by a hundred.
        #expect(baseToBase(0x420, from: 16, to: 10) == 420)
        #expect(baseToBase(420, from: 10, to: 16) == 0x420)
        #expect(baseToBase(0x210, from: 16, to: 10) == 210)
        #expect(baseToBase(0, from: 16, to: 10) == 0)
        #expect(baseToBase(0x215, from: 16, to: 10) == 215)
    }
}
