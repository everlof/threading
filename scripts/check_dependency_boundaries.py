#!/usr/bin/env python3
"""Reject upward Core dependencies on application and concrete UI types."""

from __future__ import annotations

import collections
import pathlib
import re
import sys


APPLICATION_TYPES = {"AppDelegate", "MainWindowController"}

# Core owns typed runtime capabilities; concrete application/UI types have no allowed debt.
ALLOWED_CORE_UI_REFERENCES: dict[tuple[str, str], int] = {}

# A controller-returning lookup is still an upward dependency when Swift infers the return type
# and the concrete controller name never appears in the caller.
CONTROLLER_LOOKUP = re.compile(r"\bcontroller\s*\(\s*for\b")
ALLOWED_CORE_CONTROLLER_LOOKUPS: dict[str, tuple[str, re.Pattern[str], int]] = {}

# Remote transport consumes typed application capabilities. It must not regain the terminal
# implementation even through a value whose name contains no controller.
FORBIDDEN_REMOTE_RUNTIME_PATTERNS = {
    "TerminalSession": re.compile(r"\bTerminalSession\b"),
}

CLASS_DECLARATION = re.compile(
    r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*(?:ViewController|WindowController|Controller))\b"
)


def executable_text(path: pathlib.Path) -> str:
    """Discard line comments before counting dependency-bearing identifiers."""
    return "\n".join(line.split("//", 1)[0] for line in path.read_text().splitlines())


def main() -> int:
    repository = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    source = repository / "Sources" / "Threading"
    core = source / "Core"
    ui = source / "UI"

    concrete_ui_types: set[str] = set()
    for path in ui.rglob("*.swift"):
        concrete_ui_types.update(CLASS_DECLARATION.findall(executable_text(path)))

    counts: collections.Counter[tuple[str, str]] = collections.Counter()
    failures: list[str] = []
    forbidden_types = APPLICATION_TYPES | concrete_ui_types
    for path in core.rglob("*.swift"):
        relative = path.relative_to(source).as_posix()
        text = executable_text(path)
        for type_name in forbidden_types:
            count = len(re.findall(rf"\b{re.escape(type_name)}\b", text))
            if count:
                counts[(relative, type_name)] = count

        lookup_text = text
        allowance = ALLOWED_CORE_CONTROLLER_LOOKUPS.get(relative)
        if allowance is not None:
            label, pattern, expected = allowance
            observed = len(pattern.findall(lookup_text))
            if observed != expected:
                failures.append(
                    f"{relative}: {label} appears {observed} time(s); allowed debt is {expected}"
                )
            lookup_text = pattern.sub("", lookup_text)
        if CONTROLLER_LOOKUP.search(lookup_text):
            failures.append(
                f"{relative}: Core must not use a controller-returning lookup; inject a typed "
                "runtime capability"
            )

        if relative.startswith("Core/Remote/"):
            for label, pattern in FORBIDDEN_REMOTE_RUNTIME_PATTERNS.items():
                if pattern.search(text):
                    failures.append(
                        f"{relative}: remote transport must not use {label}; inject a typed "
                        "application capability"
                    )

    for (relative, type_name), count in sorted(counts.items()):
        allowed = ALLOWED_CORE_UI_REFERENCES.get((relative, type_name), 0)
        if count > allowed:
            failures.append(
                f"{relative}: {type_name} appears {count} time(s); allowed debt is {allowed}"
            )
        elif count < allowed:
            failures.append(
                f"{relative}: {type_name} fell to {count}; ratchet allowed debt down from {allowed}"
            )

    for (relative, type_name), allowed in sorted(ALLOWED_CORE_UI_REFERENCES.items()):
        if (relative, type_name) not in counts:
            failures.append(
                f"{relative}: {type_name} fell to 0; remove its allowed debt of {allowed}"
            )

    for relative, (label, _, expected) in sorted(ALLOWED_CORE_CONTROLLER_LOOKUPS.items()):
        if not (source / relative).exists():
            failures.append(
                f"{relative}: {label} fell to 0; remove its allowed debt of {expected}"
            )

    if failures:
        for failure in failures:
            print(f"dependency-boundary: {failure}", file=sys.stderr)
        return 1

    print(
        "dependency-boundary: clean "
        f"({sum(counts.values())} ratcheted concrete-controller references remain)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
