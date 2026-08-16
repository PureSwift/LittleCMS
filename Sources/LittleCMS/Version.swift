/// The Little CMS version this engine implements.
public enum Version {
    /// The version in the reference library's encoding:
    /// `major × 1000 + minor × 10 + patch`.
    ///
    /// This is the value `cmsGetEncodedCMMversion` reports, and the value
    /// `cmsPlugin` compares a plugin's `ExpectedVersion` against — reporting
    /// anything other than the version the vendored headers carry would make
    /// the C library reject every existing plugin.
    public static let encodedCMM: UInt32 = 2190
}
