#!/usr/bin/env python3
"""Trigger sources through real processes: the resident supervisor polls an approved probe (the
shipped file_drop.py example), a matched event admits event work for a worker exactly once, a
secret reaches the probe by name, and editing the probe stops the source until re-approved."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER = os.path.abspath(sys.argv[1])
del sys.argv[1]
EXAMPLES = Path(__file__).resolve().parents[2] / "Packages/ThreadingController/Examples/Probes"


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="src-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"; self.state.mkdir(mode=0o700)
        self.db = self.state / "controller.db"
        self.drop = self.root / "drop"; self.drop.mkdir()
        self.probe = self.root / "file_drop.py"
        shutil.copy(EXAMPLES / "file_drop.py", self.probe)
        self.worker = str(uuid.uuid4())
        self.call("worker-add", self.worker, "Intake")
        self.call("worker-set-sources", self.worker, "0", "request,event")
        self.supervisor = None

    def tearDown(self):
        if self.supervisor and self.supervisor.poll() is None:
            self.supervisor.terminate(); self.supervisor.wait(timeout=15)
        self.temp.cleanup()

    def file(self, name, text):
        path = self.root / name
        path.write_text(text)
        return str(path)

    def call(self, *args, ok=True):
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True, text=True, timeout=60)
        if not ok: return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def wait(self, operation, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.1)
        self.fail("Timed out waiting for fixture state")

    def configure(self, executable, script, environment, secrets=None):
        source = str(uuid.uuid4())
        spec = {"name": "Drop folder", "executable": executable, "script": script, "arguments": [script] if script else [],
                "environment": environment, "secrets": secrets or {}, "intervalSeconds": 60, "timeoutSeconds": 10, "limit": 10}
        configured = self.call("source-configure", source, "0", self.file("spec-%s.json" % source, json.dumps(spec)))
        approved = self.call("source-approve", source, str(configured["revision"]), configured["hash"])
        return source, approved

    def test_resident_supervisor_polls_matches_once_and_an_edit_stops_the_source(self):
        source, approved = self.configure(sys.executable, str(self.probe), {"DROP_DIRECTORY": str(self.drop), "PATH": "/usr/bin:/bin"})
        enabled = self.call("source-enable", source, str(approved["revision"]))
        trigger = str(uuid.uuid4())
        rule = {"name": "Invoices", "sourceID": source, "workerID": self.worker,
                "match": [{"field": "extension", "op": "equals", "value": "pdf"}],
                "instruction": "File the invoice described in the request."}
        configured = self.call("trigger-configure", trigger, "0", self.file("rule.json", json.dumps(rule)))
        self.call("trigger-enable", trigger, str(configured["revision"]))
        (self.drop / "invoice-1.pdf").write_text("Invoice 1123, total 400 SEK")
        (self.drop / "notes.txt").write_text("not an invoice")

        self.supervisor = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "200"],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        works = self.wait(lambda: self.call("works", self.worker)["items"])
        self.assertEqual(len(works), 1)
        self.assertEqual(works[0]["source"], "event")
        request = json.loads(works[0]["request"])
        self.assertEqual(request["event"]["id"], "invoice-1.pdf")
        self.assertIn("Invoice 1123", request["event"]["evidence"])
        events = self.call("source-events", source)["items"]
        self.assertEqual(sorted(e["event"]["id"] for e in events), ["invoice-1.pdf", "notes.txt"])
        self.supervisor.terminate(); self.supervisor.wait(timeout=15)

        # A manual poll sees nothing new; nothing is admitted twice.
        self.assertEqual(self.call("source-poll", source), [])
        self.assertEqual(len(self.call("works", self.worker)["items"]), 1)
        self.assertEqual(self.call("source", source)["health"]["state"], "healthy")

        # Editing the probe stops it before it runs: no new events, health says why.
        (self.drop / "invoice-2.pdf").write_text("Invoice 1124")
        self.probe.write_text(self.probe.read_text() + "\n# edited\n")
        self.assertEqual(self.call("source-poll", source, ok=False).returncode, 0)
        status = self.call("source", source)
        self.assertEqual(status["health"]["state"], "changed")
        self.assertEqual(len(self.call("source-events", source)["items"]), 2)
        self.assertNotEqual(self.call("source-approve", source, str(status["revision"]), status["hash"], ok=False).returncode, 0)

    def test_a_secret_reaches_the_probe_by_name_only(self):
        probe = self.file("secret.sh", '#!/bin/sh\nread request\nprintf \'{"event":{"id":"s","fields":{"length":%s}}}\\n\' "${#TOKEN}"\necho \'{"cursor":"done"}\'\n')
        os.chmod(probe, 0o700)
        self.call("secret-set", "probe-token", self.file("token", "s3cret-value\n"))
        secret_file = self.state / "secrets" / "probe-token"
        self.assertEqual(oct(secret_file.stat().st_mode & 0o777), "0o600")
        source, approved = self.configure(probe, None, {"PATH": "/usr/bin:/bin"}, {"TOKEN": "probe-token"})
        events = self.call("source-poll", source)
        self.assertEqual(events[0]["event"]["fields"]["length"], 12)
        self.assertNotIn("s3cret", json.dumps(self.call("source", source)))
        # A secret the store cannot read fails the poll with a reason, and the cursor stays put.
        secret_file.unlink()
        self.call("source-poll", source)
        status = self.call("source", source)
        self.assertEqual(status["health"]["state"], "failed")
        self.assertIn("secret_unavailable", status["health"]["detail"])
        self.assertEqual(status["cursor"], "done")


if __name__ == "__main__":
    unittest.main()
