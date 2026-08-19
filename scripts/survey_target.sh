#!/bin/sh
# survey_target.sh - triage a candidate C library for Swift reimplementation
#
# Answers the Step 0 gate questions with measurements instead of guesses, and
# emits the two files Phase 0 starts from: symbols.txt and an ownership-audit
# skeleton with one row per exported function.
#
# usage: survey_target.sh <library.so|dylib> [header-directory] [output-directory]
#
#   survey_target.sh /usr/lib/x86_64-linux-gnu/libfoo.so.3 /usr/include/foo out/

set -e

library="$1"
headers="$2"
output="${3:-.}"

if [ -z "$library" ] || [ ! -f "$library" ]; then
    echo "usage: survey_target.sh <library> [header-directory] [output-directory]" >&2
    exit 2
fi

mkdir -p "$output"

# -- exported functions ------------------------------------------------------

case "$(uname -s)" in
Darwin)
    nm -gU "$library" | awk '$2 == "T" { print substr($3, 2) }' | sort -u > "$output/symbols.txt"
    ;;
*)
    nm --dynamic --defined-only --format=posix "$library" \
        | awk '$2 == "T" { sub(/@.*/, "", $1); print $1 }' | sort -u > "$output/symbols.txt"
    ;;
esac

count=$(wc -l < "$output/symbols.txt" | tr -d ' ')

echo "== gate 2: size =="
echo "exported functions: $count"
if [ "$count" -lt 150 ]; then
    echo "  tractable — weeks, not quarters"
elif [ "$count" -lt 600 ]; then
    echo "  a real project — phase it"
elif [ "$count" -lt 1000 ]; then
    echo "  large — consider scoping to a subset with its own soname"
else
    echo "  VERY LARGE — this is probably several libraries in one; scope down or decline"
fi
echo

# -- soname and dependencies -------------------------------------------------

echo "== linkage =="
if command -v readelf >/dev/null 2>&1; then
    readelf -d "$library" 2>/dev/null | grep -E 'SONAME|NEEDED' | sed 's/^/  /' || true
elif command -v otool >/dev/null 2>&1; then
    otool -L "$library" | sed 's/^/  /'
fi
echo

# -- gate 1: exposed structs -------------------------------------------------

if [ -n "$headers" ] && [ -d "$headers" ]; then
    echo "== gate 1: are the public data structures opaque? =="
    # A struct defined in a public header with named fields is one consumers can
    # walk, which means its layout is part of the ABI and a Swift engine cannot
    # own that data.
    defined=$(grep -h 'typedef struct' "$headers"/*.h 2>/dev/null | grep -c '{' || true)
    opaque=$(grep -h 'typedef struct' "$headers"/*.h 2>/dev/null | grep -c ';' || true)
    echo "  structs defined in public headers: $defined"
    echo "  opaque struct typedefs:            $opaque"
    if [ "${defined:-0}" -gt 5 ]; then
        echo "  This count alone does not decide the gate — classify them by hand:"
        echo
        echo "    HARMLESS: plain value types and wire/packet formats the caller fills in"
        echo "    and passes by pointer. You reproduce the layout once and move on."
        echo
        echo "    FATAL: structs the library allocates, hands back, and expects the caller"
        echo "    to traverse or mutate (node->children, ctx->state). Then the C layout is"
        echo "    the contract, the engine cannot own that data, and there is no"
        echo "    engine/ABI seam to build on. Decline or scope to a different library."
        echo
        echo "  The test: does any exported function RETURN a pointer to one of these,"
        echo "  or does the caller only ever pass one in?"
        grep -hn 'typedef struct' "$headers"/*.h 2>/dev/null | grep '{' | head -20 | sed 's/^/    /'
    fi
    echo

    echo "== gate 4: header licensing =="
    grep -h 'SPDX-License-Identifier' "$headers"/*.h 2>/dev/null | sort -u | sed 's/^/  /' || \
        echo "  no SPDX tags; read the license headers by hand"
    echo

    echo "== variadic functions (these must stay C) =="
    grep -hE '^[a-zA-Z_].*\(.*\.\.\..*\)' "$headers"/*.h 2>/dev/null | sed 's/^/  /' || echo "  none found"
    echo
fi

# -- ownership audit skeleton ------------------------------------------------

audit="$output/ownership.md"
{
    echo "# Ownership audit"
    echo
    echo "One row per exported function. Fill this in before implementing anything;"
    echo "it cannot be reconstructed from the headers later."
    echo
    echo "| symbol | returns | who frees | lifetime | error convention | notes |"
    echo "|---|---|---|---|---|---|"
    while read -r sym; do
        echo "| \`$sym\` | | | | | |"
    done < "$output/symbols.txt"
} > "$audit"

echo "== written =="
echo "  $output/symbols.txt      ($count symbols)"
echo "  $audit                   (skeleton — fill it in)"
echo
echo "Still to check by hand:"
echo "  gate 3 — who links this? reverse-dependency count, and whether the"
echo "           project's own binaries use the shared library or an internal archive"
echo "  gate 5 — is upstream maintained? recent releases, open CVEs, maintainer status"
