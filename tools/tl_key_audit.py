"""Mirror of `headless_p1_checks.tlLiteralKeys` as a quick pre-build audit.

Reads `assets/translation.json` and reports every `.tl` / `.tlParams` literal in
the scanned directories that has no `zh_CN` entry. The real assertion runs inside
the app (`edit-check`); this script exists so the gap is visible without a build.
"""

import glob
import json
import os
import re
import sys

# Same regex as `_tlLiteral` in lib/headless_p1_checks.dart.
RX = re.compile(r"""(['"])((?:[^'"\\]|\\.)*?)\1\s*\.tl(?:Params)?\b""")


def main() -> int:
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    table_path = os.path.join(root, "assets", "translation.json")
    with open(table_path, encoding="utf-8") as handle:
        table = json.load(handle)
    zh = table.get("zh_CN", {})

    files = sorted(glob.glob(os.path.join(root, "lib", "pages", "translation_studio", "*.dart")))
    files.append(os.path.join(root, "lib", "pages", "comic_details_page", "glossary_editor.dart"))

    total = 0
    for path in files:
        if not os.path.exists(path):
            print(f"--- {path}: <missing file>")
            total += 1
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        missing = []
        for match in RX.finditer(source):
            key = match.group(2)
            if not key or len(key) <= 2:
                continue
            if key not in zh and key not in missing:
                missing.append(key)
        rel = os.path.relpath(path, root)
        print(f"--- {rel}: {len(missing)} missing")
        for key in missing:
            print(f"    MISSING: {key!r}")
        total += len(missing)

    print(f"TOTAL MISSING = {total}")
    return 1 if total else 0


if __name__ == "__main__":
    raise SystemExit(main())
