#!/usr/bin/env python3
"""Add symbol names to scripts/implemented.txt and regenerate the stubs.

Retiring a stub is a two-step edit that is easy to get half right: the
name must be listed here, and the stub table regenerated, or the link
fails on a duplicate symbol.  This does both, keeps the header comment
block of implemented.txt exactly as it is, and keeps the names sorted.

    scripts/mark_implemented.py cmsCreateTransform cmsDoTransform ...
"""

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LISTING = REPO / "scripts" / "implemented.txt"


def main(names):
    lines = LISTING.read_text().split("\n")
    header = [l for l in lines if l.startswith("#") or l == ""]
    # The header is everything up to the first bare name; blank lines
    # inside it are kept, blank lines after the names are not.
    body_start = next(i for i, l in enumerate(lines) if l and not l.startswith("#"))
    header = lines[:body_start]
    listed = {l for l in lines[body_start:] if l and not l.startswith("#")}
    added = [n for n in names if n not in listed]
    listed.update(names)
    LISTING.write_text("\n".join(header + sorted(listed)) + "\n")
    subprocess.check_call([sys.executable, str(REPO / "scripts" / "gen_stubs.py")])
    print(f"added {len(added)}: {' '.join(added)}")
    print(f"implemented: {len(listed)}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
