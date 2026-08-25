import CLCMS2
import LittleCMSCore
import Testing

/// The engine mirrors several C layouts that the plugin header publishes,
/// and the boundary rebinds memory between the two rather than copying
/// field by field.  That is only sound while the layouts agree, so the
/// agreement is measured here rather than assumed — on every platform CI
/// builds for, since padding and alignment are what would differ.
@Suite
struct LayoutTests {
    @Test
    func vector3MatchesCmsVEC3() {
        #expect(MemoryLayout<Vector3>.size == MemoryLayout<cmsVEC3>.size)
        #expect(MemoryLayout<Vector3>.stride == MemoryLayout<cmsVEC3>.stride)
        #expect(MemoryLayout<Vector3>.alignment == MemoryLayout<cmsVEC3>.alignment)
    }

    @Test
    func matrix3MatchesCmsMAT3() {
        #expect(MemoryLayout<Matrix3>.size == MemoryLayout<cmsMAT3>.size)
        #expect(MemoryLayout<Matrix3>.stride == MemoryLayout<cmsMAT3>.stride)
        #expect(MemoryLayout<Matrix3>.alignment == MemoryLayout<cmsMAT3>.alignment)
    }

    /// Field order too, not just the total size: a vector whose components
    /// were permuted would still have the right size.
    @Test
    func vector3ComponentsSitWhereCExpectsThem() {
        var c = cmsVEC3()
        c.n = (1.0, 2.0, 3.0)

        let swift = withUnsafeBytes(of: &c) { bytes in
            bytes.loadUnaligned(as: Vector3.self)
        }
        #expect(swift == Vector3(1.0, 2.0, 3.0))
    }

    @Test
    func matrix3RowsSitWhereCExpectsThem() {
        var c = cmsMAT3()
        c.v = (
            cmsVEC3(n: (1.0, 2.0, 3.0)),
            cmsVEC3(n: (4.0, 5.0, 6.0)),
            cmsVEC3(n: (7.0, 8.0, 9.0))
        )

        let swift = withUnsafeBytes(of: &c) { bytes in
            bytes.loadUnaligned(as: Matrix3.self)
        }
        #expect(swift[0] == Vector3(1.0, 2.0, 3.0))
        #expect(swift[1] == Vector3(4.0, 5.0, 6.0))
        #expect(swift[2] == Vector3(7.0, 8.0, 9.0))
    }
}
