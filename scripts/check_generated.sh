#!/bin/sh
# check_generated.sh - assert the committed generated files are current
#
# api.json, symbols.txt, and lcms2_stubs.c are committed so the build does
# not depend on running Python, but a committed generated file can silently
# go stale.  This regenerates everything into a scratch copy of the tree
# and diffs; any drift fails.

set -e

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/scripts" "$work/Sources/CLCMS2"
cp -R "$repo/scripts/gen_api.py" "$repo/scripts/gen_stubs.py" \
      "$repo/scripts/reference_exports.txt" "$repo/scripts/implemented.txt" \
      "$work/scripts/"
cp -R "$repo/Sources/CLCMS2/include" "$work/Sources/CLCMS2/include"

python3 "$work/scripts/gen_api.py" > /dev/null
python3 "$work/scripts/gen_stubs.py" > /dev/null

status=0
for file in scripts/api.json scripts/symbols.txt Sources/CLCMS2/gen/lcms2_stubs.c; do
    if ! diff -u "$repo/$file" "$work/$file" > /dev/null 2>&1; then
        echo "stale generated file: $file (rerun the generators and commit)" >&2
        diff -u "$repo/$file" "$work/$file" | head -20 >&2 || true
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "generated files are current"
fi

python3 "$(dirname "$0")/gen_pixel_types.py" --check || status=1

exit "$status"

