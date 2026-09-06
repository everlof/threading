from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / "check_transcript_boundaries.py"
SPEC = importlib.util.spec_from_file_location("transcript_boundaries", CHECKER)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class TranscriptBoundaryTests(unittest.TestCase):
    def test_replay_cannot_recompute_a_checkout_storage_path(self):
        self.assertTrue(CHECK.violations("Core/Agent/TranscriptReplay.swift", """
            ClaudeTranscript
                .storageURL(sessionID: id, account: account, in: project)
        """))

    def test_a_new_feature_cannot_bypass_the_source_resolver(self):
        self.assertTrue(CHECK.violations("UI/Views/NewFeature.swift", """
            let location = ClaudeTranscriptLocations.shared.url(for: session, account: account)
        """))

    def test_features_can_request_a_source(self):
        self.assertFalse(CHECK.violations("Core/Agent/TranscriptReplay.swift", """
            let request = SessionTranscript.readRequest(sessionID: id, for: session, in: project, account: account)
        """))

    def test_only_destination_owners_and_the_resolver_may_compute_storage(self):
        for owner in CHECK.STORAGE_OWNERS:
            self.assertFalse(CHECK.violations(owner, "ClaudeTranscript.storageURL(sessionID: id)"))
        self.assertTrue(CHECK.violations("UI/Views/SessionMigration.swift", "ClaudeTranscript.storageURL(sessionID: id)"))

    def test_comments_can_explain_the_boundary(self):
        self.assertFalse(CHECK.violations("Core/Agent/TranscriptReplay.swift", """
            // ClaudeTranscript.storageURL is not a read source.
            /* ClaudeTranscriptLocations is owned by the runtime. */
        """))


if __name__ == "__main__":
    unittest.main()
