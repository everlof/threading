"""Runner failure contracts, without Docker or a Swift toolchain.

Run: python3 -m unittest discover -s Spikes/linux-appkit/tests
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SPIKE = Path(__file__).resolve().parents[1]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.spike = self.root / "Spikes" / "linux-appkit"
        self.spike.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        for name in ("build.sh", "coreslice.sh", "sweep.sh"):
            shutil.copy2(SPIKE / name, self.spike / name)
        self.command("dpkg", "exit 0")
        self.command("pkg-config", "echo fixture")
        self.write(self.spike / "vendor-core.sh", "exit 0")

    def write(self, path, body):
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(0o755)

    def command(self, name, body):
        self.write(self.bin / name, body)

    def run_script(self, name, *arguments):
        return subprocess.run(
            ["bash", str(self.spike / name), *arguments], env=self.env,
            capture_output=True, text=True, timeout=10,
        )

    def container_shell(self):
        # Exercise the actual heredoc, with substituted external commands.
        self.command("docker", '''printf "%s\\n" "$@" > docker-args
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -e ]]; then shift; export "$1"; fi
    shift
done
bash -s''')

    def test_build_propagates_container_failure(self):
        self.command("docker", 'echo "daemon unavailable" >&2; exit 42')
        result = self.run_script("build.sh")
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("builds clean", result.stdout)
        self.assertIn("daemon unavailable", result.stderr)

    def test_ui_build_selects_product_and_mounts_dependencies(self):
        self.command("docker", 'printf "%s\\n" "$@" > docker-args; echo "Build complete!"')
        result = self.run_script("build.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.spike / "docker-args").read_text().splitlines()
        self.assertIn(str(self.spike) + "/../..:/repo", args)
        self.assertEqual(args[-4:], ["swift", "build", "--product", "Harness"])
        self.assertIn("builds clean", result.stdout)

    def test_core_failure_preserves_full_log_and_never_runs(self):
        self.container_shell()
        self.command("swift", '''echo "$*" >> swift-calls
for ((i=0; i<100; i++)); do echo "diagnostic $i"; done
echo "no such module CryptoKit" >&2
exit 23''')
        result = self.run_script("coreslice.sh")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual((self.spike / "swift-calls").read_text(), "build --product CoreSliceHarness\n")
        self.assertIn("no such module CryptoKit", (self.spike / "out/coreslice-build.log").read_text())
        self.assertFalse((self.spike / "out/coreslice-run.log").exists())

    def test_core_runs_built_binary_and_propagates_runtime_failure(self):
        self.container_shell()
        self.command("swift", 'echo "$*" >> swift-calls; [[ "$1" == build ]] && exit 0; exit 17')
        result = self.run_script("coreslice.sh")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual((self.spike / "swift-calls").read_text().splitlines(),
                         ["build --product CoreSliceHarness", "run --skip-build CoreSliceHarness"])

    def test_core_refuses_drift_before_starting_docker(self):
        self.write(self.spike / "vendor-core.sh", "exit 9")
        self.command("docker", "touch docker-started")
        result = self.run_script("coreslice.sh")
        self.assertEqual(result.returncode, 9)
        self.assertFalse((self.spike / "docker-started").exists())

    def test_sweep_does_not_replace_report_after_build_failure(self):
        self.container_shell()
        self.command("swift", 'echo "build failed" >&2; exit 23')
        out = self.spike / "out"
        out.mkdir()
        report = out / "sweep.tsv"
        report.write_text("previous measurement\n")
        result = self.run_script("sweep.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build failed", result.stderr)
        self.assertEqual(report.read_text(), "previous measurement\n")

    def test_sweep_refuses_missing_module_after_successful_build(self):
        self.container_shell()
        self.command("swift", '[[ "$*" == "build --show-bin-path" ]] && echo nonexistent; exit 0')
        result = self.run_script("sweep.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing AppKit module", result.stderr)
        self.assertFalse((self.spike / "out/sweep.tsv").exists())

    def sqlite_sources(self):
        for directory in ("CoreSlice", "SQLiteHarness"):
            target = self.spike / "Sources" / directory
            target.mkdir(parents=True)
            for name in ("SQLiteDatabase", "ThreadingLogger"):
                (target / (name + ".swift")).write_text("verified source\n")

    def test_sqlite_selects_product_architecture_and_separate_logs(self):
        self.sqlite_sources()
        self.container_shell()
        self.command("swift", 'echo "$*" >> swift-calls')
        result = self.run_script("coreslice.sh", "--sqlite")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.spike / "swift-calls").read_text().splitlines(),
                         ["build --product SQLiteHarness", "run --skip-build SQLiteHarness"])
        self.assertTrue((self.spike / "out/sqlite-run.log").exists())
        self.assertFalse((self.spike / "out/coreslice-run.log").exists())
        self.assertIn("--platform\nlinux/arm64\n", (self.spike / "docker-args").read_text())

    def test_sqlite_refuses_modified_wrapper_before_docker(self):
        self.sqlite_sources()
        (self.spike / "Sources/SQLiteHarness/SQLiteDatabase.swift").write_text("modified")
        self.command("docker", "touch docker-started")
        result = self.run_script("coreslice.sh", "--sqlite")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.spike / "docker-started").exists())

    def test_core_refuses_unknown_arguments(self):
        result = self.run_script("coreslice.sh", "--unknown")
        self.assertEqual(result.returncode, 64)
