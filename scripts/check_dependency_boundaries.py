#!/usr/bin/env python3
"""Reject upward Core dependencies on application and concrete UI types."""

from __future__ import annotations

import collections
import pathlib
import re
import sys


APPLICATION_TYPES = {"AppDelegate", "MainWindowController"}

# Existing concrete-controller debt is explicit and ratcheted. A lower count fails too so the
# allowlist is reduced in the same coherent slice that removes a dependency.
ALLOWED_CORE_UI_REFERENCES = {
    ("Core/Agent/AgentRuntime.swift", "AgentSessionViewController"): 4,
    ("Core/Agent/AgentRuntime.swift", "ConversationViewController"): 4,
    ("Core/Agent/LimitRecoveryCoordinator.swift", "AgentSessionViewController"): 5,
    ("Core/Agent/SessionContextHandoff.swift", "ConversationViewController"): 1,
    ("Core/Remote/RemoteSessionMirrorRegistry.swift", "ConversationViewController"): 1,
    ("Core/Session/ProjectTerminalRuntime.swift", "ProjectTerminalViewController"): 4,
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
