#!/usr/bin/env python3
"""Keep live transcript selection separate from checkout storage destinations."""

from __future__ import annotations

import re
import sys
from pathlib import Path


STORAGE_OWNERS = {
    "Core/Agent/SessionTranscript.swift",  # the initial-location fallback
    "Core/Agent/SessionMigration.swift",  # destination account and checkout
    "Core/Session/SessionCheckoutCoordinator.swift",  # destination checkout
}
LOCATION_OWNERS = {
    "Core/Agent/ClaudeTranscriptLocations.swift",  # bounded location state
    "Core/Agent/AgentRuntime.swift",  # hooks, discard and observation ownership
    "Core/Agent/SessionTranscript.swift",  # one source selection decision
}


def violations(relative: str, source: str) -> list[str]:
    # Remove comments so documenting the forbidden spelling does not require an exemption.
    source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.DOTALL)
    failures = []
    if relative not in STORAGE_OWNERS and re.search(r"\bClaudeTranscript\s*\.\s*storageURL\b", source):
        failures.append(f"{relative}: select a read source through SessionTranscript; storageURL is a destination")
    if relative not in LOCATION_OWNERS and re.search(r"\bClaudeTranscriptLocations\b", source):
        failures.append(f"{relative}: live location state belongs to the runtime and SessionTranscript resolver")
    return failures


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    sources = root / "Sources/Threading"
    if not sources.is_dir():
        print(f"transcript-boundary: missing source tree {sources}", file=sys.stderr)
        return 1
    failures = []
    for path in sorted(sources.rglob("*.swift")):
        failures.extend(violations(path.relative_to(sources).as_posix(), path.read_text(encoding="utf-8")))
    for failure in failures:
        print(f"transcript-boundary: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
