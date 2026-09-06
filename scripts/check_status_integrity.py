#!/usr/bin/env python3
"""Guard the cross-layer contract behind badges and indeterminate loaders.

The detailed reasons and change gate live in docs/architecture/status-integrity.md. This checker
keeps the mechanically enforceable parts from drifting: receipt persistence cannot become an
empty/default success, receipt publication has one owner, copied remote rows retain receipt proof,
the catalogue keeps its stream fence and direct visit settlement, and raw ProgressView sites may
decline but may not spread without an explicit policy edit.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Optional


CONFIG = Path("scripts/config/status-integrity.json")
DOC = "docs/architecture/status-integrity.md"
PROGRESS_VIEW = re.compile(r"\bProgressView\s*\(")
ATTENTION_POST = re.compile(
    r"NotificationCenter\.default\.post\s*\(\s*SessionAttentionDidChange\s*\(",
    re.MULTILINE,
)


def read(path: Path, failures: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        failures.append(f"status-integrity: cannot read {path}: {error}")
        return ""


def balanced_call_bodies(source: str, call: str) -> list[str]:
    """Return balanced call bodies; sufficient for labelled Swift initializer checks."""
    result: list[str] = []
    start = 0
    needle = call + "("
    while True:
        found = source.find(needle, start)
        if found < 0:
            return result
        index = found + len(needle)
        depth = 1
        quote: Optional[str] = None
        escaped = False
        while index < len(source) and depth:
            character = source[index]
            if quote:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
            # Swift string and character literals both use double quotes. Treating apostrophes
            # as delimiters makes an ordinary comment such as "client's row" swallow the rest
            # of an initializer and lets the copy check fail open.
            elif character == '"':
                quote = character
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        if depth == 0:
            result.append(source[found + len(needle):index - 1])
        start = max(index, found + len(needle))


def require_tokens(
    relative: str,
    source: str,
    tokens: list[str],
    failures: list[str],
) -> None:
    for token in tokens:
        if token not in source:
            failures.append(f"status-integrity: {relative} lost required contract `{token}`")


def check(root: Path) -> list[str]:
    failures: list[str] = []
    claude = read(root / "CLAUDE.md", failures)
    if DOC not in claude:
        failures.append(f"status-integrity: CLAUDE.md must index {DOC}")
    if not (root / DOC).is_file():
        failures.append(f"status-integrity: missing {DOC}")

    try:
        policy = json.loads(read(root / CONFIG, failures))
    except json.JSONDecodeError as error:
        failures.append(f"status-integrity: invalid {CONFIG}: {error}")
        policy = {}
    if policy.get("schemaVersion") != 1:
        failures.append("status-integrity: status-integrity.json schemaVersion must be 1")
    maxima = policy.get("progressViewMaximumByFile", {})
    if not isinstance(maxima, dict):
        failures.append("status-integrity: progressViewMaximumByFile must be an object")
        maxima = {}

    mobile_root = root / "Sources/ThreadingMobile"
    actual: dict[str, int] = {}
    if mobile_root.is_dir():
        for path in mobile_root.rglob("*.swift"):
            count = len(PROGRESS_VIEW.findall(read(path, failures)))
            if count:
                actual[path.relative_to(root).as_posix()] = count
    for relative, count in sorted(actual.items()):
        maximum = maxima.get(relative)
        if not isinstance(maximum, int) or maximum < 0:
            failures.append(
                f"status-integrity: {relative} adds {count} ProgressView site(s) without a ratchet entry"
            )
        elif count > maximum:
            failures.append(
                f"status-integrity: {relative} has {count} ProgressView site(s), above its {maximum} ceiling"
            )
    for relative, maximum in maxima.items():
        if not isinstance(relative, str) or not relative.startswith("Sources/ThreadingMobile/"):
            failures.append(f"status-integrity: invalid ProgressView ratchet path {relative!r}")
        if not isinstance(maximum, int) or maximum < 0:
            failures.append(f"status-integrity: invalid ProgressView ceiling for {relative!r}")

    receipt_relative = "Sources/Threading/Core/Session/SessionReadReceipts.swift"
    receipt = read(root / receipt_relative, failures)
    require_tokens(
        receipt_relative,
        receipt,
        [
            "case unknown",
            "guard let loaded = loadPersisted()",
            "if savePersisted(state)",
            "SessionReadReceiptPersistence",
        ],
        failures,
    )
    for pattern in ("loadPersisted() ??", "_ = savePersisted", "_ = readReceipts.recordAttention"):
        if pattern in receipt:
            failures.append(f"status-integrity: {receipt_relative} fails open through `{pattern}`")

    sources = root / "Sources"
    post_owners: list[str] = []
    if sources.is_dir():
        for path in sources.rglob("*.swift"):
            if ATTENTION_POST.search(read(path, failures)):
                post_owners.append(path.relative_to(root).as_posix())
    expected_owner = "Sources/Threading/Core/Agent/AgentRuntime.swift"
    if expected_owner not in post_owners:
        failures.append("status-integrity: AgentRuntime must publish the receipt-ledger edge")
    for owner in post_owners:
        if owner != expected_owner:
            failures.append(
                f"status-integrity: {owner} publishes SessionAttentionDidChange outside AgentRuntime"
            )

    registry_relative = "Sources/Threading/Core/Remote/RemoteSessionMirrorRegistry.swift"
    registry = read(root / registry_relative, failures)
    require_tokens(
        registry_relative,
        registry,
        [
            "appEvents.observe(SessionAttentionDidChange.self)",
            "appEvents.observe(SessionRuntimeDidChange.self)",
            "RemoteCatalogueStreamHelloDTO(",
            "update.framed(streamID: streamID, sequence: sequence)",
            "RemoteSessionVisitedDTO(",
        ],
        failures,
    )

    wire_relative = "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift"
    wire = read(root / wire_relative, failures)
    require_tokens(
        wire_relative,
        wire,
        [
            "RemoteSessionAttentionKnowledge",
            "RemoteCatalogueStreamHelloDTO",
            "public let streamID: String?",
            "public let sequence: UInt64?",
            "RemoteSessionVisitedDTO",
            "public let receiptCommitted: Bool",
        ],
        failures,
    )

    model_relative = "Sources/ThreadingMobile/RemoteAppModel.swift"
    model = read(root / model_relative, failures)
    require_tokens(
        model_relative,
        model,
        [
            "struct MobileCatalogueStreamFence",
            "let revision = update.revision",
            "catalogueStreamFence.accepts(update)",
            "func acceptSessionVisit(",
            "visit.receiptCommitted",
            "func applyingCanonicalVisit(",
        ],
        failures,
    )
    for body in balanced_call_bodies(model, "RemoteSessionSummaryDTO"):
        if "state: session.state" in body and "attention: session.attention" not in body:
            failures.append(
                "status-integrity: RemoteAppModel copies a session row without its attention proof"
            )

    detail_relative = "Sources/ThreadingMobile/SessionDetailView.swift"
    detail = read(root / detail_relative, failures)
    if "onSessionVisited" not in detail:
        failures.append("status-integrity: SessionDetailView lost direct visit settlement")

    connection_relative = "Sources/ThreadingMobile/RemoteSessionConnection.swift"
    connection = read(root / connection_relative, failures)
    require_tokens(
        connection_relative,
        connection,
        [
            'if type == "sessionVisited"',
            'case "sessionVisited"',
            "lastSessionVisit = visit",
        ],
        failures,
    )

    return failures


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1])
    failures = check(root.resolve())
    if failures:
        print("\n".join(failures))
        return 1
    print("status-integrity: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
