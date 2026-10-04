#!/usr/bin/env python3
"""Exercise the real controller executable, fresh process per call and disposable local state."""
import concurrent.futures
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

BINARY = str(Path(sys.argv.pop(1)).resolve())


class ControllerCLI(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="threading-controller-cli-")
        self.root = Path(self.temporary.name)
        self.database = self.root / "controller.db"
        self.worker = str(uuid.uuid4())

    def tearDown(self):
        self.temporary.cleanup()

    def run_cli(self, *args, success=True):
        result = subprocess.run([BINARY, "--database", str(self.database), *args],
                                capture_output=True, text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        return result.stderr

    def text(self, content):
        path = self.root / str(uuid.uuid4())
        path.write_text(content)
        return str(path)

    def seed(self):
        self.run_cli("worker-add", self.worker, "Fixture")
        return self.run_cli("enqueue", self.worker, "event:1", self.text("Produce draft"))

    def test_owner_rpc_transports_text_without_shell_or_shared_files(self):
        self.run_cli("worker-add", self.worker, "Fixture")
        instruction = "A quoted ' value; $(touch /tmp/forbidden)\nline two"
        request = {"command": "enqueue", "arguments": [
            {"value": self.worker}, {"value": "rpc:1"}, {"text": instruction}]}
        result = subprocess.run([BINARY, "--database", str(self.database), "owner-rpc"],
                                input=json.dumps(request), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["instruction"], instruction)
        self.assertFalse(list(self.root.glob("rpc-*")))
        for bad in [{"command": "supervise", "arguments": []},
                    {"command": "enqueue", "arguments": [{"text": "x", "value": "x"}]},
                    {"command": "enqueue", "arguments": [{"text": "x" * 32769}]}]:
            result = subprocess.run([BINARY, "--database", str(self.database), "owner-rpc"],
                                    input=json.dumps(bad), capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(result.stdout)
            self.assertFalse(list(self.root.glob("rpc-*")))

    def test_owner_rpc_configures_worker_with_revision_fencing(self):
        self.run_cli("worker-add", self.worker, "Remote worker")
        recipe = {"socketPath": str(self.root / "pty.sock"), "executable": "/bin/true",
                  "arguments": [], "environment": {}, "directory": str(self.root),
                  "recipients": ["group:operations"], "destination": "opaque.result"}
        request = {"command": "worker-configure", "arguments": [
            {"value": self.worker}, {"value": "0"}, {"value": "1"}, {"text": json.dumps(recipe)}]}
        for expected in [0, 1]:
            result = subprocess.run([BINARY, "--database", str(self.database), "owner-rpc"],
                                    input=json.dumps(request), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, expected, result.stderr)
            if expected == 0:
                self.assertFalse(json.loads(result.stdout)["enabled"])
            self.assertFalse(list(self.root.glob("rpc-*")))

    def test_question_restart_resume_and_durable_receipt(self):
        work = self.seed()
        claim = self.run_cli("claim", self.worker)
        question = self.run_cli("ask", claim["execution"]["id"], str(uuid.uuid4()), "group:ops",
                                self.text("Audience?"), self.text("Prepared"))
        self.assertIsNone(self.run_cli("claim", self.worker))
        self.run_cli("answer", question["id"], "person:outsider", "-", self.text("No"), success=False)
        self.run_cli("answer", question["id"], "person:owner", "group:ops", self.text("Operations"))
        resumed = self.run_cli("claim", self.worker)
        self.assertEqual(resumed["work"]["id"], work["id"])
        self.assertEqual(resumed["work"]["checkpoint"], "Prepared")
        self.assertNotEqual(resumed["execution"]["id"], claim["execution"]["id"])
        delivery = self.run_cli("finish", resumed["execution"]["id"], "draft", self.text("Report"))
        self.assertEqual(delivery["state"], "pending")
        attempt = self.run_cli("delivery-begin", delivery["id"])
        self.run_cli("delivery-begin", delivery["id"], success=False)
        self.run_cli("delivery-uncertain", delivery["id"], attempt["attemptID"])
        settled = self.run_cli("delivery-ack", delivery["id"], attempt["attemptID"], self.text("destination:123"))
        self.assertEqual(settled["state"], "delivered")

    def test_concurrent_processes_claim_once(self):
        self.seed()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            claims = list(pool.map(lambda _: self.run_cli("claim", self.worker), range(4)))
        self.assertEqual(sum(claim is not None for claim in claims), 1)

    def test_large_file_invalid_utf8_and_fifo_refuse_without_hanging(self):
        self.run_cli("worker-add", self.worker, "Fixture")
        self.run_cli("enqueue", self.worker, "huge", self.text("x" * 32769), success=False)
        invalid = self.root / "invalid"
        invalid.write_bytes(b"\xff")
        self.run_cli("enqueue", self.worker, "invalid", str(invalid), success=False)
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        self.run_cli("enqueue", self.worker, "fifo", str(fifo), success=False)
        self.assertEqual(self.run_cli("works", self.worker)["items"], [])

    def test_symlink_input_and_database_refuse(self):
        self.run_cli("worker-add", self.worker, "Fixture")
        link = self.root / "link"
        link.symlink_to(self.text("data"))
        self.run_cli("enqueue", self.worker, "link", str(link), success=False)
        original = self.database
        self.database = self.root / "linked.db"
        self.database.symlink_to(original)
        self.run_cli("events", success=False)

    def test_private_directory_and_new_files(self):
        self.seed()
        self.assertEqual(self.database.stat().st_mode & 0o077, 0)
        os.chmod(self.root, 0o755)
        self.assertIn("owner_only", self.run_cli("events", success=False))

    def test_unknown_schema_and_corrupt_payload_preserved(self):
        work = self.seed()
        with sqlite3.connect(self.database) as connection:
            connection.execute("UPDATE record SET payload='invalid' WHERE kind='work' AND id=?", (work["id"],))
        self.run_cli("claim", self.worker, success=False)
        with sqlite3.connect(self.database) as connection:
            self.assertEqual(connection.execute("SELECT state FROM record WHERE kind='work'").fetchone()[0], "queued")
            connection.execute("PRAGMA user_version=999")
        self.assertIn("unsupported_schema", self.run_cli("events", success=False))

    def rpc(self, command, *arguments, success=True):
        request = {"command": command, "arguments": list(arguments)}
        result = subprocess.run([BINARY, "--database", str(self.database), "owner-rpc"],
                                input=json.dumps(request), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return json.loads(result.stdout) if success else result.stderr

    def test_dependencies_order_claims_and_cancellation_cascades(self):
        first = self.seed()
        after = self.run_cli("enqueue", self.worker, "event:2", self.text("After the first"), first["id"])
        self.assertEqual(after["dependsOn"], [first["id"]])
        independent = self.rpc("enqueue-request", {"value": self.worker}, {"value": "event:3"},
                               {"text": "Independent"}, {"text": "{}"})
        self.assertEqual(self.run_cli("claim", self.worker)["work"]["id"], first["id"])
        self.assertEqual(self.run_cli("claim", self.worker)["work"]["id"], independent["id"])
        self.assertIsNone(self.run_cli("claim", self.worker))
        root = self.run_cli("enqueue", self.worker, "event:4", self.text("Root"))
        child = self.rpc("enqueue", {"value": self.worker}, {"value": "event:5"}, {"text": "Child"}, {"value": root["id"]})
        self.run_cli("work-cancel", root["id"])
        cancelled = self.run_cli("work", child["id"])
        self.assertEqual((cancelled["state"], cancelled["cancelReason"]), ("cancelled", "dependency_cancelled: " + root["id"]))
        self.assertIn("dependency_cancelled", self.run_cli("enqueue", self.worker, "event:6", self.text("Late"), root["id"], success=False))

    def test_owner_memory_delete_forget_and_prune_over_owner_rpc(self):
        self.run_cli("worker-add", self.worker, "Fixture")
        key = {"value": "note"}
        written = self.rpc("memory-put", {"value": self.worker}, key, {"value": "0"}, {"text": "PRIVATE-NOTE"})
        self.assertEqual(written["provenance"]["actor"], "owner")
        self.rpc("memory-delete", {"value": self.worker}, key, {"value": "0"}, success=False)
        deleted = self.rpc("memory-delete", {"value": self.worker}, key, {"value": "1"})
        self.assertEqual((deleted["state"], deleted["revision"]), ("deleted", 2))
        self.assertEqual(self.rpc("memory-list", {"value": self.worker})["items"], [])
        forgotten = self.rpc("memory-forget", {"value": self.worker}, key)
        self.assertEqual(forgotten["state"], "forgotten")
        history = self.rpc("memory-history", {"value": self.worker}, key)["items"]
        self.assertEqual([item["content"] for item in history], ["", "", ""])
        self.assertNotIn(b"PRIVATE-NOTE", self.database.read_bytes())
        self.assertIn("prune_too_recent", self.rpc("prune", {"value": "--before"}, {"value": "2999-01-01"}, success=False))
        pruned = self.rpc("prune", {"value": "--before"}, {"value": "2000-01-01"})
        self.assertEqual((pruned["events"], pruned["more"]), (0, False))
        self.rpc("prune", {"value": "--before"}, {"value": "yesterday"}, success=False)

    def test_unknown_command_missing_args_and_bad_cursor(self):
        self.run_cli("unexpected", success=False)
        self.run_cli("enqueue", success=False)
        self.run_cli("events", "-1", success=False)


if __name__ == "__main__":
    unittest.main()
