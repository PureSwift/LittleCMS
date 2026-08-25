import CLCMS2
import LittleCMSCore

// The Phase-0 proof symbol: the one exported function whose value crosses
// engine → boundary → C client, so a probe calling it through dlsym proves
// the whole chain — Swift runtime initialization in the shared library
// included — before any color code exists.

@c @implementation
public func cmsGetEncodedCMMversion() -> CInt {
    CInt(Version.encodedCMM)
}
