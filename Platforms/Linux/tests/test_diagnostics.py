"""Privacy and size contracts for the support artifacts distributed to alpha testers."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

PLATFORM = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("diagnostics", PLATFORM / "collect-diagnostics.py")
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.output = self.root / "reports"
        self.output.mkdir()
        self.environment = patch.dict(os.environ, {
            "THREADING_LINUX_DATA_DIR": str(self.data), "SENTINEL_SECRET": "never-collect-this",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_default_report_has_no_logs_accounts_database_or_environment(self):
        for name in ("daemon.log", "threading.db", "auth.json", "session.jsonl"):
            (self.data / name).write_text("private-content")
        directory, archive = diagnostics.collect(self.output, False, PLATFORM)
        report = json.loads((directory / "report.json").read_text())
        self.assertFalse(report["logs_included"])
        with tarfile.open(archive) as source:
            names = [Path(item.name).name for item in source.getmembers() if item.isfile()]
        self.assertEqual(sorted(names), ["READ-ME.txt", "report.json"])
        self.assertNotIn("private-content", (directory / "report.json").read_text())
        self.assertNotIn("never-collect-this", (directory / "report.json").read_text())

    def test_logs_are_bounded_and_common_credentials_are_redacted(self):
        (self.data / "daemon.log").write_text("x" * (diagnostics.LOG_BYTES * 3) +
            '\nAuthorization: Bearer example-secret\n{"access_token":"token-value"}\n' +
            str(Path.home()) + "/project\n")
        directory, _ = diagnostics.collect(self.output, True, PLATFORM)
        excerpt = (directory / "daemon.log").read_text()
        self.assertLessEqual(len(excerpt), diagnostics.LOG_BYTES + 64)
        self.assertIn("[REDACTED]", excerpt)
        self.assertNotIn("example-secret", excerpt)
        self.assertNotIn("token-value", excerpt)
        self.assertNotIn(str(Path.home()), excerpt)

    def test_symlinks_and_fifos_are_refused_without_blocking(self):
        private = self.root / "private"
        private.write_text("not-a-log")
        (self.data / "daemon.log").symlink_to(private)
        os.mkfifo(self.data / "app-diagnostic.log")
        directory, _ = diagnostics.collect(self.output, True, PLATFORM)
        self.assertFalse((directory / "daemon.log").exists())
        self.assertFalse((directory / "app-diagnostic.log").exists())

    def test_diagnostic_launcher_preserves_exit_and_bounds_output(self):
        launcher = self.root / "run-diagnostic.py"
        shutil.copy2(PLATFORM / launcher.name, launcher)
        fake = self.root / "run-app.sh"
        fake.write_text(f"#!{sys.executable}\nimport os,sys\n"
                        "assert sys.argv[1:] == ['project with spaces']\n"
                        "for _ in range(400): os.write(1, b'x' * 8192)\n"
                        "raise SystemExit(7)\n")
        fake.chmod(0o755)
        result = subprocess.run([sys.executable, str(launcher), "project with spaces"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 7, result.stderr)
        for name in ("app-diagnostic.log", "app-diagnostic.log.1"):
            self.assertLessEqual((self.data / name).stat().st_size, 1024 * 1024)
            self.assertEqual((self.data / name).stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
