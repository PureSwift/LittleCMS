import LittleCMS
import Testing

@Suite
struct FieldCodecTests {
    @Test
    func elementsAreAlignedToFourBytes() {
        #expect(ICCField.alignedLength(0) == 0)
        #expect(ICCField.alignedLength(1) == 4)
        #expect(ICCField.alignedLength(3) == 4)
        #expect(ICCField.alignedLength(4) == 4)
        #expect(ICCField.alignedLength(5) == 8)

        #expect(ICCField.paddingAfter(0) == 0)
        #expect(ICCField.paddingAfter(1) == 3)
        #expect(ICCField.paddingAfter(2) == 2)
        #expect(ICCField.paddingAfter(3) == 1)
        #expect(ICCField.paddingAfter(4) == 0)
    }

    /// The reference decides this in `double`, having promoted the float,
    /// and the nearest float to 1e20 is larger than 1e20 — so the value
    /// that reads as exactly 1e20 in `Float` is refused.  This is the one
    /// case the differential caught.
    @Test
    func theMagnitudeLimitIsJudgedAsTheReferenceJudgesIt() {
        #expect(ICCField.isAcceptable(Float(bitPattern: 0x60AD_78EC)) == false)
        #expect(ICCField.isAcceptable(1e19) == true)
    }

    @Test
    func onlyZeroAndNormalValuesAreAccepted() {
        #expect(ICCField.isAcceptable(0.0))
        #expect(ICCField.isAcceptable(-0.0))
        #expect(ICCField.isAcceptable(1.0))
        #expect(ICCField.isAcceptable(-1.0))

        #expect(!ICCField.isAcceptable(.infinity))
        #expect(!ICCField.isAcceptable(-.infinity))
        #expect(!ICCField.isAcceptable(.nan))
        #expect(!ICCField.isAcceptable(.greatestFiniteMagnitude))
        // Subnormal: representable, but not something a profile should carry.
        #expect(!ICCField.isAcceptable(Float(bitPattern: 1)))
    }
}
