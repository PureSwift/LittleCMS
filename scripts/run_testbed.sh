#!/bin/sh
# run_testbed.sh - drive the upstream testbed against our library
#
# The testbed runs to completion; what it still cannot do is listed, one
# check name per line, in a known-failures file.  The contract is exact in
# both directions: a listed check that passes is a stale entry and fails
# the run (so the list can only shrink honestly), and an unlisted check
# that fails is a regression.  When the list is empty the testbed's own
# exit status is required to be zero.
#
# Any "is not implemented" report or a run that never reaches the summary
# is a failure regardless of the list.
#
# usage: run_testbed.sh <testcms2-binary> <working-directory> <known-failures-file>

set -u

binary="$1"
workdir="$2"
known="$3"

cd "$workdir" || exit 2

output=$("$binary" 2>&1)
status=$?
printf '%s\n' "$output"

case "$output" in
*"is not implemented"*)
    echo "testbed hit an unimplemented entry point (exit $status)" >&2
    exit 1
    ;;
esac

case "$output" in
*"[Memory statistics]"*) ;;
*)
    echo "testbed did not run to completion (exit $status)" >&2
    exit 1
    ;;
esac

# "Checking <name> ...FAIL!" → <name>
failing=$(printf '%s\n' "$output" | sed -n 's/^Checking \(.*\) \.\.\.FAIL!$/\1/p' | sort)
expected=$(grep -v '^#' "$known" | grep -v '^[[:space:]]*$' | sort)

rc=0
for name in $(printf '%s\n' "$expected" | tr ' ' '\001'); do
    name=$(printf '%s' "$name" | tr '\001' ' ')
    if ! printf '%s\n' "$failing" | grep -Fxq -- "$name"; then
        echo "known-failure entry is stale (now passes): $name" >&2
        rc=1
    fi
done
printf '%s\n' "$failing" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    if ! printf '%s\n' "$expected" | grep -Fxq -- "$name"; then
        echo "unexpected testbed failure: $name" >&2
        exit 1
    fi
done || rc=1

if [ -z "$expected" ] && [ "$status" -ne 0 ]; then
    echo "testbed exited $status with no known failures listed" >&2
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    n=$(printf '%s\n' "$failing" | grep -c .)
    echo "testbed ran to completion; $n known failure(s), none unexpected, none stale"
fi
exit $rc
