import Testing

@testable import LittleCMS

// The corrections applied between two profiles across the PCS.

@Suite struct IntentTests {
    @Test func blackPointCompensationPinsBothEnds() {
        // The layer must take the source black to the destination black
        // and leave D50 where it is: those two constraints define it.
        let blackIn = CIEXYZ(x: 0.010, y: 0.012, z: 0.009)
        let blackOut = CIEXYZ(x: 0.002, y: 0.003, z: 0.001)
        let layer = IntentArithmetic.blackPointCompensation(from: blackIn, to: blackOut)

        func apply(_ c: CIEXYZ) -> CIEXYZ {
            let v = layer.matrix.evaluate(Vector3(c.x, c.y, c.z))
            return CIEXYZ(x: v.x + layer.offset.x, y: v.y + layer.offset.y, z: v.z + layer.offset.z)
        }
        let mappedBlack = apply(blackIn)
        #expect((mappedBlack.x - blackOut.x).magnitude < 1e-12)
        #expect((mappedBlack.y - blackOut.y).magnitude < 1e-12)
        #expect((mappedBlack.z - blackOut.z).magnitude < 1e-12)

        let mappedWhite = apply(.d50)
        #expect((mappedWhite.x - CIEXYZ.d50.x).magnitude < 1e-12)
        #expect((mappedWhite.y - CIEXYZ.d50.y).magnitude < 1e-12)
        #expect((mappedWhite.z - CIEXYZ.d50.z).magnitude < 1e-12)

        #expect(!layer.isEmpty)
    }

    @Test func identityLayerIsEmptyAndNearIdentityIsToo() {
        #expect(XYZLayer.identity.isEmpty)
        // The threshold is a summed distance of 0.002.
        var nearly = XYZLayer.identity
        nearly.offset = Vector3(0.0005, 0.0005, 0.0005)
        #expect(nearly.isEmpty)
        nearly.offset = Vector3(0.001, 0.001, 0.001)
        #expect(!nearly.isEmpty)
    }

    @Test func fullyAdaptedAbsoluteIntentIsAWhiteScaling() {
        let whiteIn = CIEXYZ(x: 0.95, y: 1.0, z: 1.09)
        let whiteOut = CIEXYZ.d50
        let m = IntentArithmetic.absoluteIntent(
            adaptationState: 1.0,
            whiteIn: whiteIn, adaptationIn: .identity,
            whiteOut: whiteOut, adaptationOut: .identity
        )
        #expect(m != nil)
        #expect(m?[0][0] == whiteIn.x / whiteOut.x)
        #expect(m?[1][1] == 1.0)
        #expect(m?[2][2] == whiteIn.z / whiteOut.z)
        #expect(m?[0][1] == 0)
    }

    @Test func sameWhiteAndAdaptationIsIdentityWhenPartlyAdapted() {
        // Identity CHADs both imply D50, and equal whites scale by one, so
        // any adaptation state between the ends answers identity.
        let m = IntentArithmetic.absoluteIntent(
            adaptationState: 0.5,
            whiteIn: .d50, adaptationIn: .identity,
            whiteOut: .d50, adaptationOut: .identity
        )
        #expect(m == .identity)
    }

    @Test func d50AdaptationTemperature() {
        // Identity adaptation means the white was D50 already, whose
        // correlated temperature is close to 5000K.
        let t = IntentArithmetic.temperature(ofAdaptation: .identity)
        #expect(t > 4990 && t < 5010)
    }

    @Test func rec709PrimariesGiveTheKnownMatrix() {
        // The sRGB/Rec.709 primaries under D65, adapted to D50: the matrix
        // every sRGB profile carries, to the precision a profile stores.
        let primaries = RGBPrimaries(
            red: CIExyY(x: 0.64, y: 0.33, yLuminance: 1),
            green: CIExyY(x: 0.30, y: 0.60, yLuminance: 1),
            blue: CIExyY(x: 0.15, y: 0.06, yLuminance: 1)
        )
        let d65 = CIExyY(x: 0.3127, y: 0.3290, yLuminance: 1)
        guard let m = primaries.transferMatrix(whitePoint: d65) else {
            Issue.record("no matrix")
            return
        }
        #expect((m[0][0] - 0.4360).magnitude < 0.001)
        #expect((m[1][1] - 0.7169).magnitude < 0.001)
        #expect((m[2][2] - 0.7141).magnitude < 0.001)
        // The rows sum to D50.
        #expect((m[0][0] + m[0][1] + m[0][2] - 0.9642).magnitude < 0.001)
        #expect((m[1][0] + m[1][1] + m[1][2] - 1.0).magnitude < 0.001)
        #expect((m[2][0] + m[2][1] + m[2][2] - 0.8249).magnitude < 0.001)
    }
}
