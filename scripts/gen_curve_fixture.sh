#!/bin/sh
# gen_curve_fixture.sh - record what the reference's parametric curves answer
#
# The parametric evaluator is reached only through a curve object, and the
# curve object is not implemented yet, so there is nothing for a
# differential program to drive.  This records the reference's answers into
# a Swift fixture instead, so the evaluator is measured against observed
# values rather than remembered ones.  It is generated from a reference
# built by scripts/build_reference.sh, and committed.
#
# The values come back through cmsEvalToneCurveFloat, which for a curve
# built this way is the evaluator plus an infinity clamp and a narrowing to
# float — the test applies both.
#
# usage: gen_curve_fixture.sh [reference-prefix]

set -e

root=$(cd "$(dirname "$0")/.." && pwd)
prefix="${1:-$root/build/reference}"
output="$root/Tests/LittleCMSTests/ParametricFixture.swift"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cc -I"$prefix/include" "$root/scripts/gen_curve_fixture.c" \
   -L"$prefix/lib" -llcms2 -o "$work/gen"

DYLD_LIBRARY_PATH="$prefix/lib" LD_LIBRARY_PATH="$prefix/lib" "$work/gen" > "$output"

echo "wrote $output ($(grep -c '^    (' "$output") rows)"
