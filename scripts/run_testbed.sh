#!/bin/sh
# run_testbed.sh - drive the upstream testbed against our library
#
# Until the engine is complete, the contract is inverted: the run must FAIL
# — the stubs abort — and the failure must be attributable, carrying the
# "is not implemented" report rather than a crash with no explanation.  A
# ctest PASS_REGULAR_EXPRESSION cannot express this, because an abnormal
# exit outranks a matching regex.
#
# The day the testbed starts passing for real, this script flips to
# requiring success.
#
# usage: run_testbed.sh <testcms2-binary> <working-directory>

set -u

binary="$1"
workdir="$2"

cd "$workdir" || exit 2

output=$("$binary" 2>&1)
status=$?
printf '%s\n' "$output"

if [ "$status" -eq 0 ]; then
    echo "testbed unexpectedly succeeded: flip run_testbed.sh to require success" >&2
    exit 1
fi

case "$output" in
*"is not implemented"*)
    echo "testbed died loudly and attributably (exit $status)"
    exit 0
    ;;
*)
    echo "testbed died without attribution (exit $status)" >&2
    exit 1
    ;;
esac
