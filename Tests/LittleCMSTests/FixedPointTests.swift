import LittleCMS
import Testing

/// The behaviour the conformance suite cannot measure, because the
/// reference's own behaviour there is undefined and platform-dependent.
/// See the note in Conformance/primprobe.c.
@Suite
struct FixedPointOverflowTests {
    @Test
    func encodingSaturatesInsteadOfWrapping() {
        // Each of these overflows the 15.16 encoding.  The reference gives
        // these answers on arm64 and different ones on x86-64; ours are
        // these everywhere.
        #expect(S15Fixed16.fromDouble(32768.0) == Int32.max)
        #expect(S15Fixed16.fromDouble(65535.0) == Int32.max)
        #expect(S15Fixed16.fromDouble(65536.0) == Int32.max)
        #expect(S15Fixed16.fromDouble(1e300) == Int32.max)
        #expect(S15Fixed16.fromDouble(.infinity) == Int32.max)

        #expect(S15Fixed16.fromDouble(-65536.0) == Int32.min)
        #expect(S15Fixed16.fromDouble(-32768.0000152588) == Int32.min)
        #expect(S15Fixed16.fromDouble(-1e300) == Int32.min)
        #expect(S15Fixed16.fromDouble(-.infinity) == Int32.min)
    }

    @Test
    func notANumberEncodesAsZero() {
        #expect(S15Fixed16.fromDouble(.nan) == 0)
    }

    @Test
    func theRangeEdgesStillEncodeExactly() {
        // The largest and smallest values that do fit, which the
        // differential suite also covers.
        #expect(S15Fixed16.fromDouble(-32768.0) == Int32.min)
        #expect(S15Fixed16.toDouble(S15Fixed16.fromDouble(1.0)) == 1.0)
        #expect(S15Fixed16.toDouble(S15Fixed16.fromDouble(0.5)) == 0.5)
    }
}
