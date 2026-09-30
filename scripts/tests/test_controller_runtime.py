#!/usr/bin/env python3
"""Real CLI -> shared PTY client -> isolated ptyd -> execution-scoped tool process."""
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER, PTYD = map(os.path.abspath, sys.argv[1:3])
del sys.argv[1:3]

PROVIDER = r'''
import json, os, pathlib, select, subprocess, sys, tempfile, time, traceback, uuid
def report(kind, value, tb):
    pathlib.Path("provider-error.txt").write_text("".join(traceback.format_exception(kind, value, tb)))
sys.excepthook = report
def tool(request):
    with tempfile.NamedTemporaryFile(mode="w", dir=os.getcwd()) as f:
        json.dump(request, f); f.flush()
        result = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent", f.name],
                                check=True, capture_output=True, text=True, timeout=10)
        return json.loads(result.stdout)
work = tool({"context": {}})["work"]
if sys.argv[1] == "mcp":
    server = subprocess.Popen([os.environ["THREADING_CONTROLLER_BIN"], "agent-mcp"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def rpc(method, params=None, identifier=9007199254740993):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None: message["params"] = params
        if identifier is not None: message["id"] = identifier
        wire = (json.dumps(message) + "\n").encode()
        server.stdin.write(wire[:9]); server.stdin.flush()
        server.stdin.write(wire[9:]); server.stdin.flush()
        if identifier is None: return
        assert select.select([server.stdout], [], [], 5)[0], "MCP response timeout"
        reply = json.loads(server.stdout.readline())
        assert reply["id"] == identifier
        return reply
    assert "error" in rpc("tools/list")
    assert rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                              "clientInfo": {"name": "fixture", "version": "1"}})["result"]["protocolVersion"] == "2025-11-25"
    rpc("notifications/initialized", identifier=None)
    assert {tool["name"] for tool in rpc("tools/list")["result"]["tools"]} == {"work_context", "work_questions", "work_checkpoint", "work_ask", "work_finish", "memory_get", "memory_put", "knowledge_get", "knowledge_put"}
    assert rpc("tools/call", {"name": "knowledge_get", "arguments": {"spaceID": str(uuid.uuid4()), "key": "private"}})["result"]["isError"]
    assert rpc("tools/call", {"name": "work_context", "arguments": {"workerID": str(uuid.uuid4())}})["result"]["isError"]
    assert not rpc("tools/call", {"name": "work_context", "arguments": {}})["result"]["isError"]
    assert not rpc("tools/call", {"name": "work_finish", "arguments": {"payload": "MCP draft"}})["result"]["isError"]
    assert rpc("tools/call", {"name": "memory_put", "arguments": {"key": "stale", "expectedRevision": 0, "content": "Forbidden"}})["result"]["isError"]
    server.stdin.close()
    assert server.wait(timeout=5) == 0
elif sys.argv[1] == "hold":
    time.sleep(60)
elif sys.argv[1] in ("question", "auto"):
    if not work["checkpoint"]:
        tool({"memoryPut": {"key": "note", "expectedRevision": 0, "content": "Remembered"}})
        tool({"ask": {"id": str(uuid.uuid4()), "text": "Which audience?", "checkpoint": "Analysis saved"}})
        # Intentionally linger: an immediate human answer must not overlap this process.
        if sys.argv[1] == "question": time.sleep(60)
    else:
        assert tool({"questions": {"after": 0}})["questions"]["items"][0]["answer"] == "Team"
        assert tool({"memoryGet": {"key": "note"}})["memory"]["content"] == "Remembered"
        tool({"finish": {"payload": "Draft for Team"}})
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        # A short path also exercises Darwin's 104-byte socket address limit.
        self.temp = tempfile.TemporaryDirectory(prefix="ctl-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.db = self.root / "controller.db"
        self.socket = self.root / "p.sock"
        self.log = open(self.root / "ptyd.log", "wb")
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")],
                                       stdout=self.log, stderr=self.log)
        self.wait(lambda: self.socket.exists())
        self.worker = str(uuid.uuid4())
        self.supervisors = []
        self.call("worker-add", self.worker, "Runtime fixture")
        self.work = self.call("enqueue", self.worker, "fixture:1", self.file("task", "Fixture"))
        self.file("provider.py", PROVIDER)

    def tearDown(self):
        try:
            for supervisor in self.supervisors:
                if supervisor.poll() is None: supervisor.terminate(); supervisor.wait(timeout=15)
            for work in self.call("works", self.worker)["items"]:
                for launch in self.call("launches", work["id"])["items"]:
                    if launch["state"] in ("running", "dispatching"):
                        self.call("launch-stop", launch["executionID"], ok=False)
        finally:
            self.daemon.terminate()
            try: self.daemon.wait(timeout=10)
            except subprocess.TimeoutExpired: self.daemon.kill(); self.daemon.wait()
            self.log.close()
            self.temp.cleanup()

    def file(self, name, text):
        path = self.root / name
        path.write_text(text)
        return str(path)

    def call(self, *args, ok=True):
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True,
                                text=True, timeout=15)
        if not ok: return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def recipe(self, mode="hold", executable=None):
        return self.file("recipe.json", json.dumps({
            "socketPath": str(self.socket), "executable": executable or sys.executable,
            "arguments": [str(self.root / "provider.py"), mode], "directory": str(self.root),
            "environment": {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
            "recipients": ["group:ops"], "destination": "fixture.drafts",
        }))

    def wait(self, operation):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.03)
        error = self.root / "provider-error.txt"
        self.fail("Timed out waiting for fixture state: " + (error.read_text() if error.exists() else "no provider exception"))

    def test_detached_process_and_single_dispatch(self):
        launch = self.call("launch", self.worker, self.recipe())
        self.assertNotIn("spec", launch)
        self.assertNotIn("credential", json.dumps(launch).lower())
        self.assertEqual(launch["state"], "running")
        self.assertEqual(self.call("launch-status", launch["executionID"])["presence"], "running")
        self.assertNotEqual(self.call("launch-dispatch", launch["executionID"], ok=False).returncode, 0)
        stopped = self.call("launch-stop", launch["executionID"])
        self.assertEqual(stopped["state"], "stopped")
        self.assertEqual(self.call("work", self.work["id"])["state"], "interrupted")

    def test_async_question_continuation_memory_and_result(self):
        launch = self.call("launch", self.worker, self.recipe("question"))
        questions = self.wait(lambda: self.call("questions", self.work["id"])["items"])
        self.call("answer", questions[0]["id"], "person:alice", "group:ops", self.file("answer", "Team"))
        self.assertIsNone(self.call("launch", self.worker, self.recipe("question")))
        self.call("launch-stop", launch["executionID"])
        resumed = self.call("launch", self.worker, self.recipe("question"))
        self.assertNotEqual(launch["executionID"], resumed["executionID"])
        deliveries = self.wait(lambda: self.call("deliveries")["items"])
        self.assertEqual(deliveries[0]["destination"], "fixture.drafts")
        self.assertEqual(deliveries[0]["payload"], "Draft for Team")
        self.assertEqual(deliveries[0]["state"], "pending")
        self.wait(lambda: self.call("launch-status", resumed["executionID"])["presence"] == "stopped")

    def test_exit_zero_is_not_completion(self):
        launch = self.call("launch", self.worker, self.recipe("exit"))
        self.wait(lambda: self.call("launch-status", launch["executionID"])["presence"] == "stopped")
        self.assertEqual(self.call("work", self.work["id"])["state"], "interrupted")
        self.assertEqual(self.call("deliveries")["items"], [])

    def test_refused_executable_has_no_automatic_retry(self):
        result = self.call("launch", self.worker, self.recipe(executable="/nonexistent/controller-fixture"), ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.call("work", self.work["id"])["state"], "interrupted")
        self.assertIsNone(self.call("claim", self.worker))

    def test_scoped_stdio_mcp_inside_real_pty(self):
        launch = self.call("launch", self.worker, self.recipe("mcp"))
        deliveries = self.wait(lambda: self.call("deliveries")["items"])
        self.assertEqual(deliveries[0]["payload"], "MCP draft")
        self.wait(lambda: self.call("launch-status", launch["executionID"])["presence"] == "stopped")
        self.assertEqual(self.call("memory-get", self.worker, "stale"), None)

    def test_daemon_restart_does_not_turn_absence_into_a_retry(self):
        launch = self.call("launch", self.worker, self.recipe())
        self.daemon.kill()
        self.daemon.wait(timeout=5)
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")],
                                       stdout=self.log, stderr=self.log)
        def observation():
            result = self.call("launch-status", launch["executionID"], ok=False)
            return json.loads(result.stdout) if result.returncode == 0 else None
        status = self.wait(observation)
        self.assertEqual(status["presence"], "absent")
        self.assertEqual(status["launch"]["state"], "running")
        self.assertEqual(self.call("work", self.work["id"])["state"], "running")
        self.assertIsNone(self.call("claim", self.worker))
        self.assertNotEqual(self.call("launch-dispatch", launch["executionID"], ok=False).returncode, 0)

    def start_supervisor(self):
        child = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "100"],
                                 stdout=self.log, stderr=self.log)
        self.supervisors.append(child)
        return child

    def test_supervisor_restarts_and_automatically_continues_answered_work(self):
        policy = self.call("worker-configure", self.worker, "0", "1", self.recipe("auto"))
        self.assertFalse(policy["enabled"])
        self.assertNotIn("spec", policy)
        self.call("worker-enable", self.worker, str(policy["revision"]))
        supervisor = self.start_supervisor()
        question = self.wait(lambda: self.call("questions", self.work["id"])["items"])[0]
        self.wait(lambda: self.call("launches", self.work["id"])["items"][0]["state"] == "stopped")
        self.assertNotEqual(self.call("supervisor-tick", ok=False).returncode, 0)
        supervisor.terminate(); supervisor.wait(timeout=10)
        self.call("answer", question["id"], "person:a", "group:ops", self.file("answer", "Team"))
        self.start_supervisor()
        self.wait(lambda: self.call("deliveries")["items"])
        self.wait(lambda: self.call("launches", self.work["id"])["items"][-1]["state"] == "stopped")
        self.assertEqual(len(self.call("launches", self.work["id"])["items"]), 2)
        self.assertEqual(self.call("work", self.work["id"])["state"], "completed")

    def test_supervisor_runs_due_automation_without_a_mac_client(self):
        policy = self.call("worker-configure", self.worker, "0", "1", self.recipe("mcp"))
        self.call("worker-enable", self.worker, str(policy["revision"]))
        automation_id = str(uuid.uuid4())
        spec = {"name": "Scheduled report", "workerID": self.worker, "instruction": "Produce a draft",
                "schedule": {"kind": "interval", "timeZone": "UTC", "intervalMinutes": 60},
                "missedPolicy": "latest", "archiveOnSuccess": True}
        value = self.call("automation-configure", automation_id, "0", self.file("automation.json", json.dumps(spec)))
        self.call("automation-enable", automation_id, str(value["revision"]))
        # Advance only this isolated fixture's clock deadline; the shipping supervisor owns all admission and launch work.
        due = time.time() - 1
        with sqlite3.connect(self.db) as connection:
            raw = connection.execute("SELECT payload FROM record WHERE kind='automation' AND id=?", (automation_id,)).fetchone()[0]
            value = json.loads(raw); value["nextRunAt"] = due - 978307200
            connection.execute("UPDATE record SET payload=? WHERE kind='automation' AND id=?", (json.dumps(value), automation_id))
            connection.execute("UPDATE automation_due SET due=? WHERE id=?", (int(due * 1000), automation_id))
        supervisor = self.start_supervisor()
        run = self.wait(lambda: self.call("automation-runs", automation_id)["items"])[0]["run"]
        self.wait(lambda: self.call("work", run["workID"])["state"] == "completed")
        self.wait(lambda: self.call("launches", run["workID"])["items"][-1]["state"] == "stopped")
        supervisor.terminate(); supervisor.wait(timeout=10)
        self.call("supervisor-tick")
        history = self.call("automation-runs", automation_id)["items"]
        self.assertEqual(len(history), 1)
        self.assertEqual(history[0]["result"], "MCP draft")
        self.assertFalse(history[0]["archived"], "unconfirmed result delivery must stay visible")
        self.assertGreater(self.call("automation", automation_id)["nextRunAt"], due - 978307200)

    def test_supervisor_pause_and_restart_preserve_live_child_and_slot(self):
        self.call("worker-configure", self.worker, "0", "1", self.recipe("hold"))
        policy = self.call("worker-enable", self.worker, "1")
        other = self.call("enqueue", self.worker, "fixture:2", self.file("task2", "Another"))
        supervisor = self.start_supervisor()
        launch = self.wait(lambda: self.call("launches", self.work["id"])["items"])[0]
        self.wait(lambda: self.call("launches", self.work["id"])["items"][0]["state"] == "running")
        supervisor.terminate(); supervisor.wait(timeout=10)
        self.assertEqual(self.call("launch-status", launch["executionID"])["presence"], "running")
        self.call("worker-pause", self.worker, str(policy["revision"]))
        self.call("supervisor-tick")
        self.assertEqual(self.call("launch-status", launch["executionID"])["presence"], "running")
        self.call("launch-stop", launch["executionID"])
        self.call("supervisor-tick")
        self.assertEqual(self.call("work", other["id"])["state"], "queued")
        self.assertEqual(self.call("work", self.work["id"])["state"], "interrupted")
        self.call("worker-enable", self.worker, "3")
        self.start_supervisor()
        self.wait(lambda: self.call("launches", other["id"])["items"])
        self.assertEqual(len(self.call("launches", self.work["id"])["items"]), 1)

    def test_supervisor_refusal_pauses_worker_without_draining_queue(self):
        self.call("worker-configure", self.worker, "0", "1", self.recipe(executable="/nonexistent/provider"))
        self.call("worker-enable", self.worker, "1")
        other = self.call("enqueue", self.worker, "fixture:2", self.file("task2", "Another"))
        cycle = self.call("supervisor-tick")
        self.assertEqual(cycle["issues"][0]["code"], "worker_paused_after_spawn_refusal")
        self.assertFalse(self.call("worker-policy", self.worker)["enabled"])
        self.call("supervisor-tick")
        self.assertEqual(self.call("work", other["id"])["state"], "queued")

    def test_unavailable_hosts_do_not_starve_a_healthy_worker(self):
        for index in range(2):
            worker = str(uuid.uuid4())
            self.call("worker-add", worker, "Unavailable fixture")
            self.call("enqueue", worker, "task", self.file("unavailable-task", "Wait for recovery"))
            recipe = json.loads(Path(self.recipe()).read_text())
            recipe["socketPath"] = str(self.root / ("missing%d.sock" % index))
            self.call("worker-configure", worker, "0", "1", self.file("missing-recipe", json.dumps(recipe)))
            self.call("worker-enable", worker, "1")
        self.call("worker-configure", self.worker, "0", "1", self.recipe("hold"))
        self.call("worker-enable", self.worker, "1")
        self.start_supervisor()
        self.wait(lambda: self.call("launches", self.work["id"])["items"])


if __name__ == "__main__": unittest.main()
