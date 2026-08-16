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

Phase 0: the skeleton.  The shared library builds, exports the complete
382-symbol lcms2 surface, and fails loudly on everything not yet implemented.
The engine grows behind that surface incrementally; conformance is measured
by differential tests against the reference library, byte for byte.

| Area | Status |
|---|---|
| Export table (382 symbols) | complete, mostly stubs |
| Version reporting | implemented |
| Core color engine | in progress |
| CGATS/IT8, PostScript, plugins, GBD, CIECAM02 | stubbed |

## Building

The Swift library and tests:

```sh
swift build
swift test
```

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
