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

# A probe must answer the same way twice.  Comparing two builds says
# nothing if either one's output depends on something other than the
# library: the clock, uninitialized memory, an address, an iteration
# order.  Such a probe passes or fails by luck, and the failure arrives
# later, on another machine, looking like a real divergence.
#
# One extra run of each is cheap next to the hours that costs.  Both are
# checked, because a reference that is not deterministic makes the
# comparison meaningless in exactly the same way.
#
# The second pass waits out a second first.  Without that, a probe that
# prints the wall clock -- the failure this check exists for, and one
# that has bitten three times -- is only caught when the two runs happen
# to straddle a second boundary, which is a coin flip.  A second per
# differential is a fair price for turning that into a certainty.
sleep 1.1 2>/dev/null || sleep 2

"$ours" "$@" > "$work/ours.again" 2>&1
echo "exit $?" >> "$work/ours.again"
"$reference" "$@" > "$work/reference.again" 2>&1
echo "exit $?" >> "$work/reference.again"

for build in ours reference; do
    if ! cmp -s "$work/$build.out" "$work/$build.again"; then
        echo "the $build probe is not deterministic: two runs disagree." >&2
        echo "something outside the library is reaching its output --" >&2
        echo "the clock, uninitialized memory, an address, an ordering." >&2
        diff -u --text "$work/$build.out" "$work/$build.again" | head -n 20 >&2
        exit 1
    fi
done

# Byte equality is the question; the diff only exists to say where.
#
# `--text` is not optional: a probe that prints a NUL byte makes diff
# decide the files are binary, and binary mode emits no +/- lines at all.
# The extraction below would then find nothing to report and the run
# would pass while the two builds disagreed.  That is not hypothetical —
# it happened, and it is why the `cmp` below is the authority and the
# diff is only the explanation.
diff -u --text "$work/reference.out" "$work/ours.out" > "$work/diff" || true

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

# The authority on whether the two builds agree is whether their bytes
# are the same.  If they are not, something must have been extracted to
# report; finding nothing means the extraction failed, not that the
# builds agree, and that must fail loudly rather than pass quietly.
if ! cmp -s "$work/reference.out" "$work/ours.out"; then
    if [ ! -s "$work/changes" ]; then
        echo "outputs differ but no differences could be extracted;" >&2
        echo "the comparison is broken, not passing" >&2
        cat "$work/diff" >&2
        exit 1
    fi
elif [ -s "$work/changes" ]; then
    echo "outputs are byte-identical but differences were extracted;" >&2
    echo "the comparison is broken" >&2
    exit 1
fi

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
