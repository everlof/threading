#!/usr/bin/env python3
"""Keep compiler-layer modules within their declared import direction."""

from __future__ import annotations

import pathlib
import re
import sys


MODULE_IMPORTS = {
    "ThreadingDomain": {"Foundation"},
}
IMPORT = re.compile(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\b", re.MULTILINE)


def main() -> int:
    repository = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    failures: list[str] = []

    for module, allowed in MODULE_IMPORTS.items():
        root = repository / "Packages" / module / "Sources" / module
        for path in sorted(root.rglob("*.swift")):
            imports = set(IMPORT.findall(path.read_text()))
            for imported in sorted(imports - allowed):
                failures.append(
                    f"{path.relative_to(repository)} imports {imported}; "
                    f"{module} allows only {', '.join(sorted(allowed))}"
                )

    if failures:
        for failure in failures:
            print(f"module-boundary: {failure}", file=sys.stderr)
        return 1

    print("module-boundary: clean (ThreadingDomain is Foundation-only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
