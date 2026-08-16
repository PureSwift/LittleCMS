#!/bin/sh
# build_embedded.sh - the engine as a static library for a target with no operating system
#
# SwiftPM drives the desktop builds, but a bare-metal target has no Swift SDK
# bundle to hand it: what exists is the toolchain's own Embedded Swift
# standard library, shipped as one .swiftmodule per target triple.  So this
# drives swiftc directly — one module, whole-module, packed into a static
# archive.
#
# What comes out is half of a firmware: the color engine, expecting the
# platform to provide what Embedded Swift requires of it — an allocator
# (posix_memalign or malloc) — and nothing else.  The engine imports no
# Foundation and no C library, and keeping that true on every push is this
# script's job in CI.
#
# usage: build_embedded.sh [triple] [output-directory]
#        triples with a shipped stdlib live under $TOOLCHAIN/lib/swift/embedded

set -e

triple="${1:-armv7em-none-none-eabi}"
output="${2:-build/embedded/$triple}"

root=$(cd "$(dirname "$0")/.." && pwd)

# The toolchain is found through swiftc itself rather than guessed at, so
# whichever toolchain the caller has selected is the one whose embedded
# stdlib is used.
swiftc=$(xcrun --find swiftc 2>/dev/null) || swiftc=$(command -v swiftc) || {
    echo "build_embedded.sh: no swiftc on PATH" >&2
    exit 2
}
toolchain=$(dirname "$(dirname "$swiftc")")

has_stdlib() {
    [ -d "$1/lib/swift/embedded/$triple" ] || [ -d "$1/usr/lib/swift/embedded/$triple" ]
}

if ! has_stdlib "$toolchain"; then
    # Fall back to any installed toolchain that does ship it.  Both
    # locations, because a per-user install lands under the caller's home
    # directory while the swift.org .pkg installer places it system-wide.
    # Harmless where those directories do not exist: the Linux containers
    # carry the embedded stdlib in the toolchain found above.
    for candidate in "$HOME"/Library/Developer/Toolchains/*.xctoolchain \
                     /Library/Developer/Toolchains/*.xctoolchain; do
        if [ -d "$candidate/usr/lib/swift/embedded/$triple" ]; then
            swiftc="$candidate/usr/bin/swiftc"
            toolchain="$candidate"
            break
        fi
    done
fi

if ! has_stdlib "$toolchain"; then
    echo "build_embedded.sh: no toolchain with an embedded stdlib for $triple" >&2
    echo "  (looked in $toolchain and the installed toolchain directories)" >&2
    exit 2
fi

if ! "$swiftc" --version > /dev/null 2>&1; then
    echo "build_embedded.sh: $swiftc does not run" >&2
    exit 2
fi

mkdir -p "$output"

ar=$( (command -v llvm-ar || xcrun --find llvm-ar || command -v ar) 2>/dev/null | head -1 )

echo "building LittleCMS for $triple"
# shellcheck disable=SC2046
"$swiftc" -target "$triple" -enable-experimental-feature Embedded \
    -wmo -parse-as-library -O \
    -module-name LittleCMS \
    -emit-module -emit-module-path "$output/LittleCMS.swiftmodule" \
    -c -o "$output/LittleCMS.o" \
    $(find "$root/Sources/LittleCMS" -name '*.swift')

"$ar" rcs "$output/libLittleCMS.a" "$output/LittleCMS.o"

echo "wrote $output/libLittleCMS.a"
