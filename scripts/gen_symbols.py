#!/usr/bin/env python3
"""Emit the link-time export controls from scripts/symbols.txt.

One input, two formats:

  lcms2.exp   Mach-O -exported_symbols_list: one name per line, with the
              leading underscore the Mach-O symbol table adds.

  lcms2.vers  ELF version script: a single anonymous node listing the
              exported names exactly, everything else local.  Anonymous is
              required for `local: *`, and correct here because the
              reference liblcms2.so.2 exports unversioned symbols — a named
              node would stamp versions that clients would then require.

              The Swift patterns in the local list are not redundant with
              the `*` beside them.  A `@inlinable` function that the
              optimizer does not inline away is emitted as a shared
              definition with default visibility, and those reached the
              dynamic symbol table through `local: *` — five of them, on
              Linux, where Mach-O's allowlist had refused them silently.
              Naming the shapes catches them.

Exact names rather than cms*/_cms* globs, so symbols.txt stays the single
source of truth for the export list, the version script, and
check_exports.sh alike.

usage: gen_symbols.py <output-directory>
"""

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    names = [
        line.strip()
        for line in (REPO / "scripts" / "symbols.txt").read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]

    (out / "lcms2.exp").write_text("".join(f"_{name}\n" for name in names))

    # Everything Swift emits, by shape: mangled names, the runtime's own
    # symbols, and the metadata section markers.
    internal = [
        "$s*", "_$s*",
        "$S*", "_$S*",
        "swift_*", "_swift*", "__swift*",
        "__start_swift*", "__stop_swift*",
    ]

    script = ["{", "global:"]
    script += [f"    {name};" for name in names]
    script += ["local:"]
    # Unquoted on purpose: a quoted name in a version script is matched
    # literally, and these have to glob.
    script += [f"    {pattern};" for pattern in internal]
    script += ["    *;", "};", ""]
    (out / "lcms2.vers").write_text("\n".join(script))

    print(f"gen_symbols: {len(names)} names -> {out / 'lcms2.exp'}, {out / 'lcms2.vers'}")


if __name__ == "__main__":
    main()
