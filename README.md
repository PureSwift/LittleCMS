# LittleCMS

A reimplementation of [Little CMS 2](https://www.littlecms.com) in Swift, with
two faces over one engine:

- **`LittleCMS`** — a Swift color-management library: ICC profiles, tag
  access, tone curves, pipelines, and color transforms, with no C dependency
  and no Foundation.
- **`liblcms2`** — the same engine behind the published lcms2 C API, built as
  a drop-in shared library: a program compiled against Little CMS 2.19 can
  link or `dlopen` this one unchanged.

The reference for both is Little CMS **2.19** by Marti Maria Saguer.  The
public headers are vendored verbatim under `Sources/CLCMS2/include/` and
carry their own license in [`LICENSE.lcms2`](LICENSE.lcms2); every exported
function is bound to the vendored declaration, so the ABI cannot drift from
what clients were compiled against.

Little CMS upstream is actively maintained — this project exists for the
Swift ecosystem (a native library with value types and typed errors, usable
from Embedded Swift), not as a rescue.

## Status

Complete.  The shared library exports the full 382-symbol lcms2 surface
with a real implementation behind every one; the generated-stub machinery
that carried the port is gone.  Conformance is measured by differential
tests against the reference library, byte for byte, and by the reference's
own testbed (`testcms2`) compiled unmodified against this library, which
passes in full (any check it fails would have to be listed in
[`Conformance/known-testbed-failures.txt`](Conformance/known-testbed-failures.txt),
which is empty).

| Area | Status |
|---|---|
| Export table (382 symbols) | complete |
| Profiles, tag types, curves, pipelines, transforms, formatters, optimizer | bit-exact vs reference |
| Virtual profiles, intents, gamut/black point, named colours, MLU, dictionaries | bit-exact vs reference |
| CGATS/IT8, PostScript, gamut boundary descriptor, CIECAM02 | bit-exact vs reference |
| Plugin registration (all twelve kinds) | bit-exact vs reference |

## Using it from Swift

`LittleCMS` is the Swift API; nothing in it names a C type or a `TYPE_`
macro, and failures are thrown rather than logged.

```swift
import LittleCMS

let transform = try Transform(
    from: .sRGB(),                              format: .rgb8,
    to:   try Profile(contentsOfFile: "press.icc"), format: .cmyk8,
    intent: .relativeColorimetric,
    options: [.blackPointCompensation]
)

let cmyk = try transform.convert(rgbBytes)
```

Profiles describe themselves, tone curves evaluate and invert, and a
transform is safe to share across threads once built:

```swift
let profile = try Profile(data: iccBytes)
profile.profileDescription       // "sRGB built-in"
profile.colorSpace == .rgb       // true
profile.supports(.saturation)    // true

let curve = try ToneCurve(gamma: 2.2)
curve.evaluate(Float(0.5))       // 0.2176…
try curve.reversed().evaluate(0.2176)  // ≈ 0.5
```

Tags are read and written by shape, since what a tag holds is decided by
its signature and Swift cannot type a subscript on that.  A tag asked for
as the wrong shape answers nil rather than reinterpreting bytes:

```swift
for tag in profile.tags { print(tag) }        // wtpt, rXYZ, rTRC, desc, …

profile.tags.xyz(.mediaWhitePoint)            // CIEXYZ?
profile.tags.curve(.redTRC)                   // ToneCurve?
profile.tags.text(.copyright, language: "de") // String?
profile.tags.xyz(.profileDescription)         // nil — not an XYZ tag

try profile.tags.set(.profileDescription, text: "My Profile")
try profile.tags.link(.greenTRC, to: .redTRC)
try profile.tags.remove(.calibrationDateTime)
let bytes = try profile.save()
```

Anything without a named shape is still reachable exactly as the file
holds it, with `profile.tags.rawData(_:)`.

Two modules sit underneath: `LittleCMSCore` is the engine (the arithmetic
and value types, no Foundation, Embedded-clean), and `LCMS2ABI` is the C
surface.  A Swift program needs neither — `import LittleCMS` re-exports
the colorimetry types it uses.

## Building

The Swift library and tests:

```sh
swift build
swift test
```

The package builds three modules: `LittleCMS` (the Swift API),
`LittleCMSCore` (the engine), and `LCMS2ABI` (the C surface, also built
as a dynamic `lcms2` product for local iteration).

The installable C library (install name, soname, and export list are not
expressible in SwiftPM, so the shipping artifact comes from CMake):

```sh
cmake --preset release
cmake --build build/release
ctest --test-dir build/release
```

The conformance suites compare against the reference library, built at the
pinned version with floating-point contraction disabled — Swift's
arithmetic never fuses a multiply-add and a stock C build does, which puts
the two a last bit apart on doubles and puts a stock build a last bit away
from itself between arm64 and x86-64:

```sh
./scripts/build_reference.sh
PKG_CONFIG_PATH=$PWD/build/reference/lib/pkgconfig cmake --preset release
```

## License

The Swift implementation is MIT ([`LICENSE`](LICENSE)).  The vendored lcms2
headers are MIT, © 1998–2026 Marti Maria Saguer ([`LICENSE.lcms2`](LICENSE.lcms2)).
