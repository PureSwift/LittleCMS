import LittleCMS
import Testing

@Suite
struct VersionTests {
    @Test
    func encodedCMMVersionMatchesLittleCMS219() {
        #expect(Version.encodedCMM == 2190)
    }
}
