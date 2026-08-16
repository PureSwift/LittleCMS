#!/usr/bin/env python3
"""Extract the exported lcms2 API from the vendored headers.

The extraction is preprocessor-driven, never a regex over raw header text:
defining HAVE_FUNC_ATTRIBUTE_VISIBILITY makes the vendored lcms2.h expand
CMSAPI to `__attribute__((visibility("default")))`, so after `cc -E -P`
every exported declaration — and nothing else — begins with that attribute.
Comments and inactive conditionals vanish in preprocessing, which is the
point: lcms2.h contains a commented-out declaration that a text scan would
count and the compiler does not.

Three inputs, unified here:
  1. lcms2.h            — the public API
  2. lcms2_plugin.h     — the plugin API (includes lcms2.h; the new names)
  3. lcms2_unshipped.h  — our transcription of the exported-but-unheadered
                          symbols (includes both; the new names)

The extracted name set must equal scripts/reference_exports.txt — the nm
listing of the reference library — exactly.  Anything exported but not
declared means lcms2_unshipped.h is missing a symbol; anything declared but
not exported means a vendoring or transcription error.

Outputs (committed; scripts/check_generated.sh keeps them honest):
  scripts/api.json     — name, return type, parameters, origin per symbol
  scripts/symbols.txt  — the export list, sorted, one name per line
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INCLUDE = REPO / "Sources" / "CLCMS2" / "include"
MARKER = '__attribute__((visibility("default")))'

# CMS_NO_REGISTER_KEYWORD empties CMSREGISTER so parameter lists come out
# identical regardless of how the host compiler feels about `register`.
CPP_DEFINES = ["-DHAVE_FUNC_ATTRIBUTE_VISIBILITY=1", "-DCMS_NO_REGISTER_KEYWORD=1"]

EXPECTED_VARIADICS = {
    "cmsPipelineCheckAndRetreiveStages",
    "cmsSignalError",
    "_cmsIOPrintf",
}


def compiler() -> str:
    """The C compiler to preprocess with.

    Not hardcoded to `cc`: the Swift CI containers ship clang without the
    `cc` alias, and a caller with a cross toolchain sets CC.
    """
    candidates = [os.environ.get("CC"), "cc", "clang", "gcc"]
    for candidate in candidates:
        if candidate and shutil.which(candidate):
            return candidate
    sys.exit("gen_api: no C compiler found (looked for $CC, cc, clang, gcc)")


def preprocess(source: str) -> str:
    """Run the C preprocessor over a translation unit built from `source`."""
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as tu:
        tu.write(source)
        path = tu.name
    try:
        result = subprocess.run(
            [compiler(), "-E", "-P", f"-I{INCLUDE}", *CPP_DEFINES, path],
            capture_output=True,
            text=True,
            check=True,
        )
    finally:
        Path(path).unlink()
    return result.stdout


def declarations(preprocessed: str) -> list[dict]:
    """Scan for marker-prefixed declarations by balanced-paren walk."""
    found = []
    index = 0
    while True:
        start = preprocessed.find(MARKER, index)
        if start < 0:
            break
        # Walk to the terminating `;`, balancing parentheses so function-pointer
        # parameters do not end the scan early.
        cursor = start + len(MARKER)
        depth = 0
        top_open = -1
        top_close = -1
        while cursor < len(preprocessed):
            char = preprocessed[cursor]
            if char == "(":
                if depth == 0 and top_open < 0:
                    top_open = cursor
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0 and top_close < 0 <= top_open:
                    top_close = cursor
            elif char == ";" and depth == 0:
                break
            cursor += 1
        if top_open < 0 or top_close < 0:
            sys.exit(f"gen_api: marker at offset {start} is not a function declaration")
        head = normalize(preprocessed[start + len(MARKER) : top_open])
        name_match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", head)
        if not name_match:
            sys.exit(f"gen_api: cannot find a name in declaration head {head!r}")
        name = name_match.group(1)
        parameters = normalize(preprocessed[top_open + 1 : top_close])
        found.append(
            {
                "name": name,
                "return": head[: name_match.start()].strip(),
                "parameters": parameters,
                "variadic": parameters.endswith("..."),
            }
        )
        index = cursor
    return found


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def main() -> None:
    units = [
        ("lcms2.h", '#include "lcms2.h"\n'),
        ("lcms2_plugin.h", '#include "lcms2.h"\n#include "lcms2_plugin.h"\n'),
        (
            "lcms2_unshipped.h",
            '#include "lcms2.h"\n#include "lcms2_plugin.h"\n#include "lcms2_unshipped.h"\n',
        ),
    ]
    api: dict[str, dict] = {}
    seen: set[str] = set()
    for header, source in units:
        for record in declarations(preprocess(source)):
            if record["name"] in seen:
                continue
            record["header"] = header
            api[record["name"]] = record
            seen.add(record["name"])

    reference = set((REPO / "scripts" / "reference_exports.txt").read_text().split())
    declared = set(api)
    if declared != reference:
        missing = sorted(reference - declared)
        extra = sorted(declared - reference)
        sys.exit(
            "gen_api: declaration set does not match the reference exports\n"
            f"  exported but undeclared (lcms2_unshipped.h is missing them): {missing}\n"
            f"  declared but unexported (vendoring/transcription error): {extra}"
        )

    public = sum(1 for name in api if not name.startswith("_"))
    internal = len(api) - public
    if (public, internal) != (299, 83):
        sys.exit(f"gen_api: expected 299 public + 83 internal, found {public} + {internal}")

    variadics = {name for name, record in api.items() if record["variadic"]}
    if variadics != EXPECTED_VARIADICS:
        sys.exit(f"gen_api: variadic set changed: {sorted(variadics)}")

    ordered = [api[name] for name in sorted(api)]
    (REPO / "scripts" / "api.json").write_text(
        json.dumps(ordered, indent=2, sort_keys=True) + "\n"
    )
    (REPO / "scripts" / "symbols.txt").write_text("".join(f"{name}\n" for name in sorted(api)))
    print(f"gen_api: {len(api)} symbols ({public} public, {internal} internal)")


if __name__ == "__main__":
    main()
