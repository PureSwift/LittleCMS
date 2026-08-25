// swift-tools-version: 6.3

import PackageDescription

// This package builds two things from one engine.
//
// `LittleCMS` is a Swift color-management library with a Swift API and no C
// dependencies.  The C library built by CMakeLists.txt is the same engine
// behind the published lcms2 C API, built so that a program compiled against
// Little CMS 2 can link or load it unchanged.  `LittleCMS` is that engine
// itself — profiles, tag serialization, tone curves, pipelines, transforms —
// rather than a separate wrapper around it; nothing sits between it and a
// Swift client.
//
// SwiftPM drives development, the Swift library, and the test suites.  The
// shipping C library is built by CMakeLists.txt, because the install name,
// soname and export list that make substitution work are not expressible here.

let package = Package(
    name: "LittleCMS",
    // Only Apple platforms need saying, and this is not a floor we chose: it is
    // as far back as `Span` back-deploys.  Everywhere else the standard library
    // ships with the compiler, and the C library built by CMakeLists.txt sets
    // its own deployment target independently of this.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LittleCMS", targets: ["LittleCMS"]),

        // For iterating on the C surface locally; the artifact that gets
        // installed comes from the CMake build, because the install name,
        // soname and export list that make substitution work are not
        // expressible here.
        .library(name: "lcms2", type: .dynamic, targets: ["LCMS2ABI"]),
    ],
    targets: [
        // The published C API, the completed control structures, and the
        // parts of the implementation that have to be C: error dispatch
        // and the three variadic entry points.
        .target(
            name: "CLCMS2",
            path: "Sources/CLCMS2",
            publicHeadersPath: "include"
        ),

        // One `@c @implementation` function per published entry point,
        // bound to the declaration in the vendored header so the exported
        // ABI cannot drift from what clients were compiled against.
        .target(
            name: "LCMS2ABI",
            dependencies: ["CLCMS2", "LittleCMSCore"],
            path: "Sources/LCMS2ABI"
        ),

        // The engine: the arithmetic and value types everything above is
        // built on.  No Foundation, and no knowledge of the C API.
        .target(
            name: "LittleCMSCore",
            path: "Sources/LittleCMSCore"
        ),

        // The Swift API: profiles, tone curves, transforms as Swift types
        // with typed errors, layered over the same machinery the C surface
        // exports.
        .target(
            name: "LittleCMS",
            dependencies: ["LittleCMSCore", "LCMS2ABI"],
            path: "Sources/LittleCMS"
        ),

        // Depends on CLCMS2 as well as the engine: some of what the engine
        // must guarantee is agreement with a C layout, and the only honest
        // way to check that is against the imported C type itself.
        //
        // LCMS2ABI comes along because CLCMS2 is not standalone: the three
        // variadics are C, and one of them walks a pipeline through the
        // exported accessors, which the boundary defines.  Linking the C
        // floor without the boundary leaves those undefined.
        // Exercises the public Swift API alone, as a client would.
        .testTarget(
            name: "LittleCMSAPITests",
            dependencies: ["LittleCMS"],
            path: "Tests/LittleCMSAPITests"
        ),

        .testTarget(
            name: "LittleCMSTests",
            dependencies: ["LittleCMS", "LittleCMSCore", "CLCMS2", "LCMS2ABI"],
            path: "Tests/LittleCMSTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
