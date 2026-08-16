#!/bin/sh
# check_exports.sh - assert the built library exports exactly the lcms2 API
#
# Being a drop-in replacement means the dynamic symbol table has to match the
# reference build's: every published function present, and nothing else exposed.
# A missing symbol breaks clients at load time; an extra one lets a client bind
# to an internal detail that is free to change — and a Swift library has a lot
# of internal detail ($s mangles, runtime metadata) that must never leak.
#
# usage: check_exports.sh <library> [expected-symbol-list]

set -e

library="$1"
expected="${2:-$(dirname "$0")/symbols.txt}"

if [ -z "$library" ] || [ ! -f "$library" ]; then
    echo "check_exports.sh: no such library: $library" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every defined external symbol, whatever its type, with the Mach-O leading
# underscore removed.  Not just text: the reference exports no data at all,
# so a data symbol appearing here is a leak the type filter would hide —
# and the engine's globals are exactly the kind of thing that leaks.
case "$(uname -s)" in
Darwin)
    nm -gU "$library" | awk 'NF >= 3 { print substr($3, 2) }' \
        | sort -u > "$work/actual"
    ;;
*)
    nm --dynamic --defined-only --format=posix "$library" \
        | awk '$2 != "U" { sub(/@.*/, "", $1); print $1 }' \
        | sort -u > "$work/actual"
    ;;
esac

grep -v '^#' "$expected" | grep -v '^[[:space:]]*$' | sort -u > "$work/expected"

missing=$(comm -23 "$work/expected" "$work/actual")
extra=$(comm -13 "$work/expected" "$work/actual")

status=0

if [ -n "$missing" ]; then
    echo "missing exports:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    status=1
fi

if [ -n "$extra" ]; then
    echo "unexpected exports:" >&2
    echo "$extra" | sed 's/^/  /' >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "exports match: $(wc -l < "$work/expected" | tr -d ' ') symbols"
fi

exit "$status"
