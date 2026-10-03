#!/usr/bin/env python3
"""Usage receipts through real processes: an agent under ptyd writes a Claude-format transcript
under its execution id and finishes; the resident supervisor confirms the stop and writes the
receipt from the transcript through the shared adapters, attributed to the worker and task."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER, PTYD = map(os.path.abspath, sys.argv[1:3])
del sys.argv[1:3]

PROVIDER = r'''
import json, os, pathlib, subprocess, sys, tempfile
def tool(request):
    with tempfile.NamedTemporaryFile(mode="w", dir=os.getcwd()) as f:
        json.dump(request, f); f.flush()
        result = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent", f.name], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
home = pathlib.Path(sys.argv[1])
project = home / "projects" / "-work"
project.mkdir(parents=True, exist_ok=True)
session = os.environ["THREADING_EXECUTION_ID"]
lines = []
for n, (model, inp, out) in enumerate([("claude-sonnet-4-5", 1000, 200), ("claude-sonnet-4-5", 500, 100), ("claude-haiku-4-5", 50, 10)]):
    lines.append(json.dumps({"requestId": f"r{n}", "timestamp": "2026-10-03T10:00:00.000Z", "cwd": "/work", "sessionId": session,
                             "message": {"id": f"m{n}", "model": model, "usage": {"input_tokens": inp, "cache_read_input_tokens": 4000,
                                         "cache_creation_input_tokens": 0, "output_tokens": out}}}))
(project / (session + ".jsonl")).write_text("\n".join(lines) + "\n")
tool({"context": {}})
tool({"finish": {"payload": "Spent some tokens"}})
'''


class UsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="use-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.socket = self.root / "p.sock"
        self.log = open(self.root / "ptyd.log", "wb")
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")], stdout=self.log, stderr=self.log)
        self.wait(lambda: self.socket.exists())
        self.state = self.root / "state"; self.state.mkdir(mode=0o700)
        self.db = self.state / "controller.db"
        (self.root / "provider.py").write_text(PROVIDER)
        self.supervisor = None

    def tearDown(self):
        if self.supervisor and self.supervisor.poll() is None:
            self.supervisor.terminate(); self.supervisor.wait(timeout=15)
        self.daemon.terminate()
        try: self.daemon.wait(timeout=10)
        except subprocess.TimeoutExpired: self.daemon.kill(); self.daemon.wait()
        self.log.close()
        self.temp.cleanup()

    def call(self, *args):
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def wait(self, operation, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.1)
        self.fail("Timed out waiting for fixture state")

    def test_supervisor_writes_an_attributed_receipt_from_the_transcript(self):
        worker = str(uuid.uuid4())
        home = self.root / "claude-home"
        self.call("worker-add", worker, "Researcher")
        work = self.call("enqueue", worker, "task:1", str(self.write("task", "Research")))
        recipe = self.write("recipe.json", json.dumps({
            "socketPath": str(self.socket), "executable": sys.executable,
            "arguments": [str(self.root / "provider.py"), str(home)], "directory": str(self.root),
            "environment": {"PATH": "/usr/bin:/bin"}, "recipients": ["group:ops"], "destination": "drafts",
            "usage": {"runtime": "claude", "home": str(home), "account": "ops-login"}}))
        policy = self.call("worker-configure", worker, "0", "1", str(recipe))
        self.call("worker-enable", worker, str(policy["revision"]))
        self.supervisor = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "200"],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        receipts = self.wait(lambda: self.call("usage-receipts", worker)["items"])
        receipt = receipts[0]
        self.assertEqual(receipt["workID"], work["id"])
        self.assertEqual(receipt["coverage"], "complete")
        self.assertEqual(receipt["account"], "ops-login")
        cells = {c["model"]: c for c in receipt["cells"]}
        self.assertEqual(cells["claude-sonnet-4-5"]["tokens"]["uncachedInput"], 1500)
        self.assertEqual(cells["claude-sonnet-4-5"]["tokens"]["cachedInput"], 8000)
        self.assertEqual(cells["claude-sonnet-4-5"]["requests"], 2)
        self.assertGreater(cells["claude-sonnet-4-5"]["costUSD"], 0)   # priced from the shared catalogue
        day = receipt["endedAt"][:10]
        summary = self.call("usage-summary", day, day)["items"]
        self.assertEqual(sum(c["output"] for c in summary), 310)
        # Over its daily budget, the worker starts nothing new.
        self.call("worker-budget-set", worker, "0", "100")
        self.call("enqueue", worker, "task:2", str(self.write("task2", "More")))
        time.sleep(1.5)
        self.assertEqual(self.call("work", self.call("works", worker)["items"][1]["id"])["state"], "queued")

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        return path


if __name__ == "__main__":
    unittest.main()
