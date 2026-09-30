"""Runner failure contracts, without Docker or a Swift toolchain.

Run: python3 -m unittest discover -s Spikes/linux-appkit/tests
"""
import os
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
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
        self.assertEqual((self.spike / "swift-calls").read_text(),
                         "build -c debug --product CoreSliceHarness\n")
        self.assertIn("no such module CryptoKit", (self.spike / "out/coreslice-build.log").read_text())
        self.assertFalse((self.spike / "out/coreslice-run.log").exists())

    def test_core_runs_built_binary_and_propagates_runtime_failure(self):
        self.container_shell()
        self.command("swift", 'echo "$*" >> swift-calls; [[ "$1" == build ]] && exit 0; exit 17')
        result = self.run_script("coreslice.sh")
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual((self.spike / "swift-calls").read_text().splitlines(),
                         ["build -c debug --product CoreSliceHarness",
                          "run --skip-build -c debug CoreSliceHarness"])

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
                         ["build -c debug --product SQLiteHarness",
                          "run --skip-build -c debug SQLiteHarness"])
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

    def test_bundle_build_finishes_and_cleans_daemon_with_stdin_still_open(self):
        source = (SPIKE / "bundle-smoke.sh").read_text()
        build = source.split("<<'BUILD'\n", 1)[1].split("\nBUILD\n", 1)[0]
        artifact_bin = self.spike / "out/threading-linux-preview-ubuntu24.04-arm64/bin"
        artifact_bin.mkdir(parents=True)
        contract_bin = self.spike / "contract-bin"
        contract_bin.mkdir()
        self.env.update(RUNNER_FIXTURE_ROOT=str(self.root),
                        RUNNER_CONTRACT_BIN=str(contract_bin))
        self.command("apt-get", "exit 0")
        self.command("swift", '''if [[ "$*" == "build -c release --show-bin-path" ]]; then
    printf '%s\\n' "$RUNNER_CONTRACT_BIN"
fi''')
        self.command("timeout", '[[ "$1" == 30 ]] || exit 91; shift; exec "$@"')
        self.write(self.spike / "package-app.sh", 'touch "$RUNNER_FIXTURE_ROOT/packaged"')

        daemon = artifact_bin / "threading-ptyd"
        daemon.write_text(f"#!{sys.executable}\n" + '''import json
import os
from pathlib import Path
import signal
import socket
import sys

root = Path(os.environ['RUNNER_FIXTURE_ROOT'])
endpoint = sys.argv[sys.argv.index('--socket') + 1]
listener = socket.socket(socket.AF_UNIX)
listener.bind(endpoint)
listener.listen(1)
listener.settimeout(.1)

def stopped(signum, frame):
    (root / 'daemon-stopped').write_text(str(os.getpid()))
    listener.close()
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stopped)
(root / 'daemon-started').write_text(json.dumps({'pid': os.getpid(), 'socket': endpoint}))
while True:
    try:
        connection, _ = listener.accept()
    except TimeoutError:
        continue
    with connection:
        connection.sendall(str(os.getpid()).encode())
''')
        daemon.chmod(0o755)
        harness = contract_bin / "PortablePTYClientHarness"
        harness.write_text(f"#!{sys.executable}\n" + '''import json
import os
from pathlib import Path
import socket
import sys

root = Path(os.environ['RUNNER_FIXTURE_ROOT'])
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(2)
    connection.connect(sys.argv[1])
    pid = int(connection.recv(32))
assert pid == json.loads((root / 'daemon-started').read_text())['pid']
(root / 'harness-finished').write_text(str(pid))
''')
        harness.chmod(0o755)

        process = subprocess.Popen(["bash", "-s"], cwd=self.spike, env=self.env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            process.stdin.write(build + "\n")
            process.stdin.flush()
            # communicate() would close stdin and hide the container EOF-forwarding defect.
            # A completed harness must trigger the EXIT trap while this writer remains open.
            process.wait(timeout=8)
            self.assertFalse(process.stdin.closed)
            self.assertEqual(process.returncode, 0, process.stdout.read() + process.stderr.read())
            self.assertTrue((self.root / "packaged").exists())
            started = json.loads((self.root / "daemon-started").read_text())
            self.assertEqual((self.root / "harness-finished").read_text(), str(started["pid"]))
            self.assertEqual((self.root / "daemon-stopped").read_text(), str(started["pid"]))
            with self.assertRaises(ProcessLookupError):
                os.kill(started["pid"], 0)
            self.assertFalse(Path(started["socket"]).parent.exists())
        finally:
            # A regression leaves bash and its fixture daemon awaiting EOF. Own the process
            # group so even a failing assertion cannot leak either process into later tests.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()
            started_path = self.root / "daemon-started"
            if started_path.exists():
                # The regression path kills the group before bash can run its EXIT trap.
                # Remove only the temporary directory recorded by this fixture daemon.
                started = json.loads(started_path.read_text())
                shutil.rmtree(Path(started["socket"]).parent, ignore_errors=True)
