#!/usr/bin/env python3
"""Keep compiler-layer modules within their declared import direction."""

from __future__ import annotations

import pathlib
import re
import sys


MODULE_BOUNDARIES = {
    "ControllerRuntime": (
        pathlib.Path("Targets/Controller/Sources/ControllerRuntime"),
        # Darwin/Glibc: the agent tool broker's Unix socket (bind, poll, peer credentials).
        {"Foundation", "Darwin", "Glibc", "ThreadingController", "ThreadingDomain", "ThreadingPTYClient",
         "ThreadingPTYHostKit", "ThreadingUsage"},
    ),
    "ThreadingController": (
        pathlib.Path("Packages/ThreadingController/Sources/ThreadingController"),
        # ThreadingUsage: one transcript parser for the Mac's Usage page and controller receipts
        # (docs/feature-drafts/agent-usage-ledger.md). Glibc/Musl: BoundedCommand's Linux cleanup
        # finds escaped descendants through /proc and signals them, which Foundation cannot express.
        {"Foundation", "CControllerSQLite", "ThreadingDomain", "ThreadingUsage", "Glibc", "Musl"},
    ),
    "ThreadingUsage": (
        pathlib.Path("Packages/ThreadingUsage/Sources/ThreadingUsage"),
        # The strict JSONL reader streams with POSIX reads and memmem on every platform.
        {"Foundation", "Darwin", "Glibc", "Musl"},
    ),
    "ThreadingDomain": (
        pathlib.Path("Packages/ThreadingDomain/Sources/ThreadingDomain"),
        {"Foundation"},
    ),
    "ThreadingPTYHostKit": (
        pathlib.Path("Packages/ThreadingPTYHostKit/Sources/ThreadingPTYHostKit"),
        {"Foundation", "ThreadingDomain"},
    ),
    "Threading/Application": (
        pathlib.Path("Sources/Threading/Application"),
        {
            "Foundation",
            "ThreadingDomain",
            "ThreadingExtensionKit",
            "ThreadingRemoteKit",
        },
    ),
}
IMPORT = re.compile(r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\b", re.MULTILINE)


def main() -> int:
    repository = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    failures: list[str] = []

    for module, (relative_root, allowed) in MODULE_BOUNDARIES.items():
        root = repository / relative_root
        if not root.is_dir():
            failures.append(f"{relative_root}: declared {module} source root is missing")
            continue
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

    print("module-boundary: clean (Domain and Application imports are approved)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
