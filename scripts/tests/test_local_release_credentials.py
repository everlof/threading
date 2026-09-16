"""Credential recovery tests use only synthetic values and never the real Keychain."""

import importlib.util
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "local_release_credentials", Path(__file__).resolve().parents[1] / "local_release_credentials.py"
)
credentials = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(credentials)


class LocalReleaseCredentialsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "private" / "credentials.json"
        self.values = dict(profile="fixture", team_id=credentials.TEAM_ID,
                           apple_id="fixture@example.invalid", app_specific_password="fixture-only")

    def test_backup_is_private_and_round_trips(self):
        credentials.save_backup(self.values, self.path)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertEqual(credentials.load_backup("fixture", self.path), self.values)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_refuses_wrong_profile_and_world_readable_backup(self):
        credentials.save_backup(self.values, self.path)
        with self.assertRaises(ValueError):
            credentials.load_backup("another-profile", self.path)
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):
            credentials.load_backup("fixture", self.path)

    def test_refuses_symlink_without_overwriting_target(self):
        target = Path(self.temporary.name) / "target"
        target.write_text("unchanged")
        self.path.parent.mkdir()
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            credentials.save_backup(self.values, self.path)
        self.assertEqual(target.read_text(), "unchanged")

    @patch.object(credentials.subprocess, "run")
    def test_working_keychain_needs_no_local_file(self, run):
        run.return_value = subprocess.CompletedProcess([], 0)
        credentials.ensure_profile("fixture", self.path)
        self.assertEqual(run.call_count, 1)
        self.assertFalse(self.path.exists())

    @patch.object(credentials.subprocess, "run")
    def test_missing_profile_is_restored_with_validation(self, run):
        credentials.save_backup(self.values, self.path)
        run.side_effect = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0)]
        credentials.ensure_profile("fixture", self.path)
        command = run.call_args.args[0]
        self.assertIn("store-credentials", command)
        self.assertNotIn("--no-validate", command)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertEqual(credentials.load_backup("fixture", self.path), self.values)

    @patch.object(credentials.subprocess, "run")
    def test_validation_failure_does_not_disclose_secret_or_replace_backup(self, run):
        credentials.save_backup(self.values, self.path)
        run.return_value = subprocess.CompletedProcess([], 1, stderr="fixture-only")
        with self.assertRaises(ValueError) as raised:
            credentials.store_profile(self.values)
        self.assertNotIn(self.values["app_specific_password"], str(raised.exception))
        self.assertEqual(credentials.load_backup("fixture", self.path), self.values)


if __name__ == "__main__":
    unittest.main()
