#!/usr/bin/env python3
"""Controller execution recovery against the real CLI and a real, isolated ptyd.

Each case reproduces a failure that used to strand work: a ptyd crash or restart, a fork
failure, a store held busy past the busy timeout, an exit seen only by a human watcher while the
supervisor was down, a recovery command without its fence, and an old process writing after a
newer one migrated the store. All state lives in a private temporary directory.
"""
import json
import os
from pathlib import Path
import resource
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER, PTYD = map(os.path.abspath, sys.argv[1:3])
del sys.argv[1:3]

PROVIDER = r'''
import os, subprocess, sys, tempfile, time, json
mode = sys.argv[1]
if mode == "hold":
    time.sleep(120)
elif mode == "fail":
    time.sleep(1)
    print("provider failed: quota", flush=True)
    sys.exit(3)
'''
REPLY_SECONDS = 20


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        # Short: Darwin's socket address holds 104 bytes.
        self.temp = tempfile.TemporaryDirectory(prefix="rcv-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.db = self.root / "controller.db"
        self.socket = self.root / "p.sock"
        self.log = open(self.root / "ptyd.log", "ab")
        self.children = []
        self.daemon = None
        self.worker = str(uuid.uuid4())
        self.file("provider.py", PROVIDER)

    def tearDown(self):
        try:
            for child in self.children:
                if child.poll() is None:
                    child.kill(); child.wait(timeout=10)
        finally:
            self.stop_daemon()
            subprocess.run(["pkill", "-f", str(self.root / "provider.py")])
            self.log.close()
            self.temp.cleanup()

    # MARK: - Fixture

    def start_daemon(self, nproc=None):
        def limit():
            if nproc is not None:
                resource.setrlimit(resource.RLIMIT_NPROC, (nproc, nproc))
        self.socket.unlink(missing_ok=True)
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")],
                                       stdout=self.log, stderr=self.log, preexec_fn=limit)
        self.wait(lambda: self.socket.exists())

    def crash_daemon(self):
        self.daemon.send_signal(signal.SIGKILL)
        self.daemon.wait(timeout=10)

    def stop_daemon(self):
        if self.daemon and self.daemon.poll() is None:
            self.daemon.terminate()
            try: self.daemon.wait(timeout=10)
            except subprocess.TimeoutExpired: self.daemon.kill(); self.daemon.wait()

    def file(self, name, text):
        path = self.root / name
        path.write_text(text)
        return str(path)

    def call(self, *args, ok=True):
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True,
                                text=True, timeout=REPLY_SECONDS)
        if not ok: return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def rpc(self, command, *values):
        request = {"command": command, "arguments": [{"value": value} for value in values]}
        return subprocess.run([CONTROLLER, "--database", str(self.db), "owner-rpc"], input=json.dumps(request),
                              capture_output=True, text=True, timeout=REPLY_SECONDS)

    def recipe(self, mode="hold"):
        return self.file("recipe-%s.json" % mode, json.dumps({
            "socketPath": str(self.socket), "executable": sys.executable,
            "arguments": [str(self.root / "provider.py"), mode], "directory": str(self.root),
            "environment": {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
            "recipients": ["group:ops"], "destination": "recovery.drafts"}))

    def seed(self, key="task:1"):
        if not self.call("workers")["items"]:
            self.call("worker-add", self.worker, "Recovery fixture")
        return self.call("enqueue", self.worker, key, self.file("task-" + key.replace(":", "-"), "Fixture"))

    def enable(self, mode):
        policy = self.call("worker-configure", self.worker, "0", "1", self.recipe(mode))
        return self.call("worker-enable", self.worker, str(policy["revision"]))

    def wait(self, operation, seconds=REPLY_SECONDS):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.05)
        self.fail("timed out waiting for fixture state")

    # MARK: - ptyd loss and exit evidence

    def test_ptyd_crash_and_double_restart_confirm_the_loss_and_release_the_slot(self):
        self.start_daemon()
        work = self.seed()
        launch = self.call("launch", self.worker, self.recipe("hold"))
        self.assertEqual(launch["state"], "running")
        # Two restarts before anybody looks: the second daemon no longer reports the incident
        # in its `lost` frame, so only the retained receipt can prove the stop.
        self.crash_daemon(); self.start_daemon()
        self.crash_daemon(); self.start_daemon()
        status = self.call("launch-status", launch["executionID"])
        self.assertEqual(status["presence"], "stopped")
        self.assertEqual(status["launch"]["state"], "stopped")
        self.assertEqual(status["launch"]["failure"]["stage"], "host")
        self.assertEqual(status["launch"]["failure"]["reason"], "lost")
        self.assertEqual(self.call("work", work["id"])["state"], "interrupted", "a loss is never an automatic retry")
        self.assertIsNone(self.call("claim", self.worker))
        self.assertEqual(self.call("active-launches")["items"], [], "the slot is released")
        self.assertEqual(self.call("launch-occupancy")["unresolved"], 0)
        self.assertNotIn("process_unresolved", json.dumps(self.call("supervisor-tick")))

    def test_an_exit_seen_by_a_watcher_survives_supervisor_downtime(self):
        self.start_daemon()
        self.seed()
        launch = self.call("launch", self.worker, self.recipe("fail"))
        watcher = subprocess.Popen([PTYD, "attach", launch["executionID"], "--socket", str(self.socket)],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(watcher)
        # Longer than ptyd's five-second retention for an exit somebody saw.
        time.sleep(8)
        status = self.call("launch-status", launch["executionID"])
        self.assertEqual(status["presence"], "stopped")
        self.assertEqual(status["launch"]["exitStatus"], 3)
        self.assertEqual(status["launch"]["failure"]["reason"], "nonzero_exit")
        self.assertIn("provider failed: quota", status["launch"]["outputTail"])
        self.assertNotIn("xterm-256color", json.dumps(status), "recipe values never reach status output")

    def test_a_fork_failure_is_definite_and_requeues_without_pausing(self):
        if os.geteuid() == 0: self.skipTest("RLIMIT_NPROC does not bind root")
        self.start_daemon(nproc=1)
        work = self.seed()
        result = self.call("launch", self.worker, self.recipe("hold"), ok=False)
        self.assertNotEqual(result.returncode, 0)
        launch = self.call("launches", work["id"])["items"][0]
        self.assertEqual(launch["state"], "stopped", "a definite refusal never stays dispatching")
        self.assertEqual(launch["failure"]["stage"], "spawn")
        self.assertEqual(launch["failure"]["reason"], "spawn_failed")
        self.assertIsNotNone(launch["failure"].get("errorNumber"))
        self.assertEqual(self.call("work", work["id"])["state"], "queued", "no process started, so the work waits again")

    # MARK: - Supervisor robustness

    def test_the_resident_supervisor_survives_a_store_held_past_the_busy_timeout(self):
        self.start_daemon()
        work = self.seed()
        self.enable("hold")
        supervisor = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "100"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(supervisor)
        self.wait(lambda: self.call("launches", work["id"])["items"])
        second = self.seed("task:2")
        connection = sqlite3.connect(str(self.db), timeout=0, isolation_level=None)
        connection.execute("BEGIN IMMEDIATE")
        # The busy timeout is three seconds per write, and one pass makes several writes, so the
        # lock must outlast a whole pass for the per-item path to meet it.
        time.sleep(12)
        connection.execute("ROLLBACK"); connection.close()
        time.sleep(1)
        self.assertIsNone(supervisor.poll(), "a busy store is retried, not a reason to exit")
        policy = self.call("worker-policy", self.worker)
        self.call("worker-pause", self.worker, str(policy["revision"]))
        supervisor.send_signal(signal.SIGTERM)
        output, errors = supervisor.communicate(timeout=REPLY_SECONDS)
        self.assertEqual(supervisor.returncode, 0, errors)
        self.assertIn("storage_error: 5", output)
        self.assertEqual(self.call("work", second["id"])["state"], "queued")

    def test_an_old_supervisor_stops_writing_after_a_newer_build_migrates(self):
        self.start_daemon()
        self.seed()
        supervisor = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "100"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.children.append(supervisor)
        time.sleep(0.5)
        version = json.loads(subprocess.check_output([CONTROLLER, "--version"]))
        with sqlite3.connect(str(self.db)) as connection:
            connection.execute("PRAGMA user_version=%d" % (int(version["schema"]) + 1))
        self.wait(lambda: supervisor.poll() is not None)
        _, errors = supervisor.communicate(timeout=REPLY_SECONDS)
        self.assertNotEqual(supervisor.returncode, 0)
        self.assertIn("unsupported_schema", errors)

    # MARK: - Owner repair

    def test_owner_rpc_repairs_are_available_and_fenced(self):
        self.start_daemon()
        work = self.seed()
        prepared = self.call("launch-prepare", self.worker, self.recipe("hold"))
        execution = prepared["executionID"]
        self.assertNotEqual(self.rpc("launch-confirm-stopped", execution).returncode, 0, "the fence is required")
        self.assertNotEqual(self.rpc("launch-confirm-stopped", execution, "running").returncode, 0, "a stale fence conflicts")
        self.assertNotEqual(self.rpc("interrupt", execution).returncode, 0, "refused while the launch is unresolved")
        dispatched = self.rpc("launch-dispatch", execution)
        self.assertEqual(dispatched.returncode, 0, dispatched.stderr)
        self.assertEqual(json.loads(dispatched.stdout)["state"], "running")
        self.assertNotEqual(self.rpc("launch-dispatch", execution).returncode, 0, "one spawn right")
        confirmed = self.rpc("launch-confirm-stopped", execution, "running")
        self.assertEqual(confirmed.returncode, 0, confirmed.stderr)
        self.assertEqual(json.loads(confirmed.stdout)["failure"]["reason"], "confirmed_stopped")
        self.assertEqual(self.call("work", work["id"])["state"], "interrupted")
        version = json.loads(self.rpc("version").stdout)
        self.assertIn("launch-repair", version["features"])
        host = json.loads(self.rpc("host").stdout)
        self.assertEqual(host["schema"], version["schema"])
        self.assertIn("host-receipts", host["features"])


if __name__ == "__main__":
    unittest.main()
