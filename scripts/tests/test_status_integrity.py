#!/usr/bin/env python3
"""Regression tests for the badge/loader status-integrity boundary."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts/check_status_integrity.py"


class StatusIntegrityCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.seed_contract()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, source: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def run_checker(self, repository: Optional[Path] = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(repository or self.root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def seed_contract(self) -> None:
        self.write("CLAUDE.md", "docs/architecture/status-integrity.md\n")
        self.write("docs/architecture/status-integrity.md", "# Status integrity\n")
        self.write(
            "scripts/config/status-integrity.json",
            json.dumps({"schemaVersion": 1, "progressViewMaximumByFile": {}}),
        )
        self.write(
            "Sources/Threading/Core/Session/SessionReadReceipts.swift",
            "case unknown\nguard let loaded = loadPersisted()\nif savePersisted(state) {}\n"
            "enum SessionReadReceiptPersistence {}\n",
        )
        self.write(
            "Sources/Threading/Core/Agent/AgentRuntime.swift",
            "NotificationCenter.default.post(SessionAttentionDidChange(sessionID: id))\n",
        )
        self.write(
            "Sources/Threading/Core/Remote/RemoteSessionMirrorRegistry.swift",
            "appEvents.observe(SessionAttentionDidChange.self)\n"
            "appEvents.observe(SessionRuntimeDidChange.self)\n"
            "RemoteCatalogueStreamHelloDTO(\n"
            "update.framed(streamID: streamID, sequence: sequence)\n"
            "RemoteSessionVisitedDTO(\n",
        )
        self.write(
            "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteWireDTO.swift",
            "RemoteSessionAttentionKnowledge\nRemoteCatalogueStreamHelloDTO\n"
            "public let streamID: String?\npublic let sequence: UInt64?\n"
            "RemoteSessionVisitedDTO\npublic let receiptCommitted: Bool\n",
        )
        self.write(
            "Sources/ThreadingMobile/RemoteAppModel.swift",
            "struct MobileCatalogueStreamFence {}\nlet revision = update.revision\n"
            "catalogueStreamFence.accepts(update)\nfunc acceptSessionVisit() {\n"
            "_ = visit.receiptCommitted\n}\nfunc applyingCanonicalVisit() {}\n",
        )
        self.write("Sources/ThreadingMobile/SessionDetailView.swift", "onSessionVisited\n")
        self.write(
            "Sources/ThreadingMobile/RemoteSessionConnection.swift",
            'if type == "sessionVisited" {}\ncase "sessionVisited":\nlastSessionVisit = visit\n',
        )

    def test_clean_contract_passes(self) -> None:
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_new_progress_view_requires_an_explicit_ratchet_edit(self) -> None:
        self.write("Sources/ThreadingMobile/NewLoader.swift", "let body = ProgressView()\n")
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a ratchet entry", result.stdout)

    def test_receipt_load_cannot_collapse_failure_into_empty(self) -> None:
        path = "Sources/Threading/Core/Session/SessionReadReceipts.swift"
        self.write(path, (self.root / path).read_text() + "loadPersisted() ?? [:]\n")
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("loadPersisted() ??", result.stdout)

    def test_only_agent_runtime_may_publish_receipt_edges(self) -> None:
        self.write(
            "Sources/Threading/UI/Feature.swift",
            "NotificationCenter.default.post(SessionAttentionDidChange(sessionID: id))\n",
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("outside AgentRuntime", result.stdout)

    def test_a_remote_row_copy_must_keep_attention_proof(self) -> None:
        path = "Sources/ThreadingMobile/RemoteAppModel.swift"
        self.write(
            path,
            (self.root / path).read_text()
            + "let copy = RemoteSessionSummaryDTO(id: session.id, state: session.state)\n",
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("without its attention proof", result.stdout)

    def test_visit_fields_stay_scoped_away_from_other_revision_frames(self) -> None:
        path = "Sources/ThreadingMobile/RemoteSessionConnection.swift"
        self.write(path, 'case "sessionVisited":\nlastSessionVisit = visit\n')
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn('if type == "sessionVisited"', result.stdout)

    def test_direct_visit_requires_committed_receipt_proof(self) -> None:
        path = "Sources/ThreadingMobile/RemoteAppModel.swift"
        self.write(
            path,
            (self.root / path).read_text().replace("_ = visit.receiptCommitted\n", ""),
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("visit.receiptCommitted", result.stdout)

    def test_the_shipped_repository_passes(self) -> None:
        result = self.run_checker(REPOSITORY)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
