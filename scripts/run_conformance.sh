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
ours_status=$?
echo "exit $ours_status" >> "$work/ours.out"
"$reference" "$@" > "$work/reference.out" 2>&1
reference_status=$?
echo "exit $reference_status" >> "$work/reference.out"

# A probe killed by a signal fails even when both builds die the same way.
# Agreement is only evidence when the question was answered: two crashed
# probes produce identical truncated output and would otherwise pass,
# which is how a probe that dereferences a null the reference hands it
# can look like conformance.
crashed=0
for s in "$ours_status" "$reference_status"; do
    if [ "$s" -ge 128 ]; then crashed=1; fi
done
if [ "$crashed" -eq 1 ]; then
    echo "probe died on a signal (ours $ours_status, reference $reference_status);" >&2
    echo "the comparison below is not evidence of anything" >&2
    tail -n 5 "$work/ours.out" >&2
    exit 1
fi

diff -u "$work/reference.out" "$work/ours.out" > "$work/diff" || true

# Content lines of the diff only.  The two file headers are dropped by
# position rather than by pattern: an output line that itself begins with
# `---` or `+++` is a real difference, and filtering those by shape would
# hide exactly the differences a diff-shaped output format produces.
# Hunk marks start with `@`, so `^[+-]` never picks them up.
tail -n +3 "$work/diff" | grep -E '^[+-]' > "$work/changes" || true

# Markers: the first field of each non-comment, non-empty line, written
# once to a file.  Never re-expanded through the shell — a marker
# containing a glob character would otherwise become a filename.
grep -Ev '^[[:space:]]*(#|$)' "$known" | awk '{print $1}' > "$work/markers"

status=0

if [ -s "$work/changes" ]; then
    if [ -s "$work/markers" ]; then
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

# Self-invalidation: every marker must still match something, so the file
# of accepted differences cannot outlive the differences it accepts.
while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    if ! grep -F -q -- "$marker" "$work/changes" 2>/dev/null; then
        echo "stale known-difference marker: $marker (matches nothing; remove it)" >&2
        status=1
    fi
done < "$work/markers"

if [ "$status" -eq 0 ]; then
    echo "conformance: output and exit status match the reference"
fi

exit "$status"
