#!/bin/sh
# run_conformance.sh - diff one conformance program's two builds
#
# The claim being tested is that a C client built for lcms2 behaves the same
# against this library as against the reference, so the program is compiled
# twice from identical source and everything observable is compared: stdout
# and the exit status both.
#
# Differences on lines carrying a marker from the known-differences file are
# reported and accepted; a marker that matches nothing FAILS, so the file of
# accepted differences cannot outlive the differences it accepts.
#
# usage: run_conformance.sh <ours> <reference> <known-differences> [args...]

set -u

ours="$1"; reference="$2"; known="$3"
shift 3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

"$ours" "$@" > "$work/ours.out" 2>&1
echo "exit $?" >> "$work/ours.out"
"$reference" "$@" > "$work/reference.out" 2>&1
echo "exit $?" >> "$work/reference.out"

diff -u "$work/reference.out" "$work/ours.out" > "$work/diff" || true

# Content lines of the diff only: changes, not the file headers or hunk marks.
grep -E '^[+-]' "$work/diff" | grep -Ev '^(\+\+\+|---)' > "$work/changes" || true

# Markers: first word of each non-comment, non-empty line.
markers=$(grep -Ev '^[[:space:]]*(#|$)' "$known" | awk '{print $1}')

status=0

if [ -s "$work/changes" ]; then
    if [ -n "$markers" ]; then
        printf '%s\n' $markers > "$work/markers"
        grep -F -v -f "$work/markers" "$work/changes" > "$work/unaccepted" || true
    else
        cp "$work/changes" "$work/unaccepted"
    fi
    if [ -s "$work/unaccepted" ]; then
        echo "output differs from the reference:" >&2
        cat "$work/diff" >&2
        status=1
    else
        echo "accepted differences:" >&2
        cat "$work/changes" >&2
    fi
fi

# Self-invalidation: every marker must still match something.
for marker in $markers; do
    if ! grep -F -q "$marker" "$work/changes" 2>/dev/null; then
        echo "stale known-difference marker: $marker (matches nothing; remove it)" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "conformance: output and exit status match the reference"
fi

exit "$status"
