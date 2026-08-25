import Testing
@testable import LittleCMSCore

@Suite struct CIECAM02Tests {
    private var conditions: ViewingConditions {
        ViewingConditions(whitePoint: .d50, yb: 20, la: 20, surround: Surround.average.rawValue, d: ViewingConditions.calculateD)
    }

    @Test func whiteIsLightest() {
        let model = CIECAM02(conditions)
        let white = model.forward(.d50)
        #expect(abs(white.j - 100) < 1e-9)
        // The published CAT02/HPE matrices are not exact inverses, so the
        // white keeps a little chroma in this model — as it does in the
        // reference.  Well under two units.
        #expect(white.c < 2)
        #expect(model.forward(CIEXYZ(x: 0.2, y: 0.2, z: 0.2)).j < white.j)
    }

    @Test func roundTrip() {
        // The model inverts to about 1e-5 in XYZ, which is what the
        // reference achieves too (the differential probe prints the worst
        // case); this is a sanity floor, not a precision claim.
        let model = CIECAM02(conditions)
        let colours = [CIEXYZ(x: 0.3, y: 0.4, z: 0.2), CIEXYZ(x: 0.05, y: 0.02, z: 0.09), CIEXYZ(x: 0.7, y: 0.5, z: 0.1)]
        for xyz in colours {
            let back = model.reverse(model.forward(xyz))
            #expect(abs(back.x - xyz.x) < 1e-4)
            #expect(abs(back.y - xyz.y) < 1e-4)
            #expect(abs(back.z - xyz.z) < 1e-4)
        }
    }

    @Test func surroundsDiffer() {
        let xyz = CIEXYZ(x: 0.3, y: 0.4, z: 0.2)
        var dim = conditions
        dim.surround = Surround.dim.rawValue
        let a = CIECAM02(conditions).forward(xyz)
        let b = CIECAM02(dim).forward(xyz)
        #expect(a.j != b.j)
        #expect(a.h >= 0 && a.h < 360)
    }

    @Test func givenDegreeOfAdaptationIsKept() {
        var fixed = conditions
        fixed.d = 1.0
        let xyz = CIEXYZ(x: 0.3, y: 0.4, z: 0.2)
        #expect(CIECAM02(fixed).forward(xyz).j != CIECAM02(conditions).forward(xyz).j)
    }
}
