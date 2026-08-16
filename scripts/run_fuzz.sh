#!/bin/sh
# run_fuzz.sh - differential fuzzing, both libraries over the same input
#
# The shape: a generator makes randomized inputs (profiles, pixel buffers,
# curves) from a printed seed, both libraries consume each one, and every
# observable — parsed values, transformed bytes, error outcomes — is
# compared.  The seed is printed first so a failing batch is exactly
# reproducible; in CI the seed is the run id.
#
# The fuzzers arrive with the parsers they feed (the profile container and
# the tag serializers, Phase 8).  Until then this holds the interface so CI
# wiring does not churn: run_fuzz.sh <build-dir> [count] [seed]

set -u

build="${1:?usage: run_fuzz.sh <build-dir> [count] [seed]}"
count="${2:-1000}"
seed="${3:-$$}"

echo "fuzz seed: $seed  (count: $count)"

if [ ! -d "$build" ]; then
    echo "run_fuzz.sh: no such build directory: $build" >&2
    exit 2
fi

# No parser exists to feed yet.  This is a scaffold, and it says so rather
# than printing a green line that measured nothing.
echo "run_fuzz.sh: no fuzz targets exist yet (they arrive with the profile parser)"
exit 0
