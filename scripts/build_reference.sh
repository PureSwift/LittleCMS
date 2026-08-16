#!/bin/sh
# build_reference.sh - build the reference lcms2 the conformance suite measures against
#
# Two things make a stock distribution build the wrong thing to compare
# against.  It is whatever version the distribution froze, where this
# library implements the ABI of the version its vendored headers came from.
# And it is compiled with floating-point contraction on, which is the C
# compiler's default: `a*b + c*d` becomes a fused multiply-add with one
# rounding instead of two.  Swift never contracts — its arithmetic is
# IEEE-strict and reproducible — so a stock reference disagrees with this
# library in the last bit of a double, and disagrees with *itself* between
# arm64, which has the instruction, and baseline x86-64, which does not.
#
# Contraction is unspecified, so comparing against it would measure the
# compiler rather than this library.  Built this way, every remaining
# difference is ours.
#
# usage: build_reference.sh [prefix] [tag]

set -e

prefix="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/reference}"
tag="${2:-lcms2.19}"

work="$prefix/src"

if [ ! -d "$work" ]; then
    echo "fetching Little-CMS $tag"
    mkdir -p "$(dirname "$work")"
    git clone --quiet --depth 1 --branch "$tag" \
        https://github.com/mm2/Little-CMS.git "$work"
fi

cd "$work"
./configure --prefix="$prefix" CFLAGS="-O2 -ffp-contract=off" > /dev/null
make -j"$( (nproc || sysctl -n hw.ncpu || echo 4) 2>/dev/null )" > /dev/null
make install > /dev/null

echo "reference installed in $prefix"
echo
echo "configure the build against it with:"
echo "  PKG_CONFIG_PATH=$prefix/lib/pkgconfig cmake --preset release"
