#!/usr/bin/env python3
"""The agent tool broker, through real processes: a resident `supervise` serves agent tools on its
socket, a ptyd-hosted child launched beside it receives no store path, its `agent` and `agent-mcp`
calls work through the socket, and another execution's credential, a mailbox claim with it, or an
owner command sent down the same socket is refused. The broker also outlives malformed, oversized
and slow clients without stalling supervision."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER, PTYD = map(os.path.abspath, sys.argv[1:3])
del sys.argv[1:3]
# This file exercises the broker; the same-account fallback must not be what makes it pass.
os.environ.pop("THREADING_CONTROLLER_LEGACY_AGENT_DATABASE", None)

PROVIDER = r'''
import json, os, pathlib, select, socket, subprocess, sys, tempfile, time, traceback
def report(kind, value, tb):
    pathlib.Path("provider-error-%s.txt" % os.environ.get("THREADING_EXECUTION_ID")).write_text(
        "".join(traceback.format_exception(kind, value, tb)))
sys.excepthook = report
me = os.environ["THREADING_EXECUTION_ID"]
def tool(request):
    with tempfile.NamedTemporaryFile(mode="w", dir=os.getcwd()) as f:
        json.dump(request, f); f.flush()
        result = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent", f.name],
                                capture_output=True, text=True, timeout=20)
        if result.returncode != 0: raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)
def raw(line):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(15)
        s.connect(os.environ["THREADING_CONTROLLER_AGENT_SOCKET"])
        s.sendall(line.encode() + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
        return json.loads(data)
# What this process was given: names only, plus whether any value names the store.
pathlib.Path("env-%s.json" % me).write_text(json.dumps({
    "names": sorted(os.environ), "valuesNamingStore": [k for k, v in os.environ.items() if "controller.db" in v]}))
work = tool({"context": {}})["work"]
mode = sys.argv[1]
if mode == "victim":
    pathlib.Path("victim.json").write_text(json.dumps({"id": me, "credential": os.environ["THREADING_EXECUTION_CREDENTIAL"]}))
    while not pathlib.Path("victim-go").exists(): time.sleep(0.05)
    # Its own credential still works after the probe tried to misuse it.
    tool({"checkpoint": {"text": "victim still served"}})
    tool({"finish": {"payload": "victim done"}})
elif mode == "probe":
    victim = json.loads(pathlib.Path("victim.json").read_text())
    mine = os.environ["THREADING_EXECUTION_CREDENTIAL"]
    results = {
        "victimIdMyCredential": raw(json.dumps({"execution": victim["id"], "credential": mine, "request": {"context": {}}})),
        "myIdVictimCredential": raw(json.dumps({"execution": me, "credential": victim["credential"], "request": {"context": {}}})),
        "victimFinish": raw(json.dumps({"execution": victim["id"], "credential": mine, "request": {"finish": {"payload": "stolen"}}})),
        "ownerCommand": raw(json.dumps({"command": "workers", "arguments": []})),
        "ownerRPC": raw(json.dumps({"execution": me, "credential": mine, "command": "worker-pause", "arguments": []})),
        "noCaller": raw(json.dumps({"credential": mine, "request": {"context": {}}})),
        "both": raw(json.dumps({"execution": me, "mailbox": "x", "credential": mine, "request": {"context": {}}})),
        "own": raw(json.dumps({"execution": me, "credential": mine, "request": {"context": {}}})),
    }
    pathlib.Path("probe.json").write_text(json.dumps(results))
    # agent-mcp through the broker.
    server = subprocess.Popen([os.environ["THREADING_CONTROLLER_BIN"], "agent-mcp"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def rpc(method, params=None, identifier=1):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None: message["params"] = params
        if identifier is not None: message["id"] = identifier
        server.stdin.write((json.dumps(message) + "\n").encode()); server.stdin.flush()
        if identifier is None: return
        assert select.select([server.stdout], [], [], 15)[0], "MCP response timeout"
        return json.loads(server.stdout.readline())
    rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}})
    rpc("notifications/initialized", identifier=None)
    assert not rpc("tools/call", {"name": "memory_put", "arguments": {"key": "probe", "expectedRevision": 0, "content": "via broker"}}, 2)["result"]["isError"]
    assert not rpc("tools/call", {"name": "work_finish", "arguments": {"payload": "probe done"}}, 3)["result"]["isError"]
    server.stdin.close()
    assert server.wait(timeout=10) == 0
elif mode == "exit":
    pass
'''


def exchange(path, payload, timeout=15):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(path)
        try: s.sendall(payload)
        except BrokenPipeError: pass  # an oversized request is answered and closed mid-send
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
        return json.loads(data) if data else None


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ctb-", dir="/tmp")
        self.root = Path(self.temp.name)
        os.chmod(self.root, 0o700)
        self.db = self.root / "controller.db"
        self.socket = self.root / "p.sock"
        self.broker = self.root / "agent.sock"
        self.log = open(self.root / "ptyd.log", "wb")
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")],
                                       stdout=self.log, stderr=self.log)
        self.wait(lambda: self.socket.exists())
        self.worker = str(uuid.uuid4())
        self.call("worker-add", self.worker, "Broker fixture")
        self.file("provider.py", PROVIDER)
        self.supervisor = None

    def tearDown(self):
        try:
            if self.supervisor and self.supervisor.poll() is None:
                self.supervisor.terminate(); self.supervisor.wait(timeout=20)
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
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True, text=True, timeout=20)
        if not ok: return result
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def recipe(self, mode):
        return self.file("recipe-%s.json" % mode, json.dumps({
            "socketPath": str(self.socket), "executable": sys.executable,
            "arguments": [str(self.root / "provider.py"), mode], "directory": str(self.root),
            "environment": {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"},
            "recipients": ["group:ops"], "destination": "fixture.drafts",
        }))

    def supervise(self):
        self.supervisor = subprocess.Popen([CONTROLLER, "--database", str(self.db), "supervise", "100",
                                            "--agent-socket", str(self.broker)],
                                           stdout=subprocess.DEVNULL, stderr=self.log)
        self.wait(lambda: self.broker.exists() and self.call("host").get("agentSocket") == str(self.broker))

    def wait(self, operation, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.05)
        errors = "".join(p.read_text() for p in self.root.glob("provider-error-*.txt"))
        self.fail("Timed out waiting for fixture state: " + (errors or "no provider exception"))

    def test_a_child_gets_no_store_path_and_cannot_borrow_another_executions_authority(self):
        self.supervise()
        self.assertEqual(stat.S_IMODE(os.stat(self.broker).st_mode), 0o660)
        host = self.call("host")
        self.assertIn("agent-broker", host["features"])
        self.assertIn("credential-digest", host["features"])

        self.call("enqueue", self.worker, "broker:victim", self.file("task-v", "Victim"))
        victim = self.call("launch", self.worker, self.recipe("victim"))
        self.wait(lambda: (self.root / "victim.json").exists())
        self.call("enqueue", self.worker, "broker:probe", self.file("task-p", "Probe"))
        probe = self.call("launch", self.worker, self.recipe("probe"))
        self.wait(lambda: self.call("launch-record", probe["executionID"])["state"] == "stopped")
        (self.root / "victim-go").touch()
        self.wait(lambda: self.call("launch-record", victim["executionID"])["state"] == "stopped")
        errors = "".join(p.read_text() for p in self.root.glob("provider-error-*.txt"))
        self.assertEqual(errors, "")

        for execution in (victim["executionID"], probe["executionID"]):
            seen = json.loads((self.root / ("env-%s.json" % execution)).read_text())
            self.assertIn("THREADING_CONTROLLER_AGENT_SOCKET", seen["names"])
            self.assertNotIn("THREADING_CONTROLLER_DATABASE", seen["names"])
            self.assertEqual(seen["valuesNamingStore"], [])

        results = json.loads((self.root / "probe.json").read_text())
        self.assertEqual(results["victimIdMyCredential"]["error"], "forbidden")
        self.assertEqual(results["myIdVictimCredential"]["error"], "forbidden")
        self.assertEqual(results["victimFinish"]["error"], "forbidden")
        self.assertEqual(results["noCaller"]["error"], "forbidden")
        self.assertEqual(results["both"]["error"], "forbidden")
        self.assertEqual(results["ownerCommand"]["error"], "invalid_request")
        # An owner verb beside a valid credential names no operation the broker knows.
        self.assertEqual(results["ownerRPC"]["error"], "invalid_input: broker_request")
        self.assertEqual(results["own"]["response"]["work"]["key"], "broker:probe")

        deliveries = {d["payload"] for d in self.call("deliveries")["items"]}
        self.assertEqual(deliveries, {"victim done", "probe done"})
        self.assertEqual(self.call("memory-get", self.worker, "probe")["content"], "via broker")

        # The store holds digests, never the plaintext the victim was given.
        leaked = json.loads((self.root / "victim.json").read_text())["credential"]
        connection = sqlite3.connect(self.db)
        try: payloads = [row[0] for row in connection.execute("SELECT payload FROM record WHERE kind='executionCredential'")]
        finally: connection.close()
        self.assertEqual(len(payloads), 2)
        self.assertTrue(all(json.loads(p).startswith("sha256:") for p in payloads))
        self.assertFalse(any(leaked in p for p in payloads))

        kinds = [event["kind"] for event in self.events()]
        self.assertIn("launch.agent_peer", kinds)
        self.assertIn("agent.broker_refused", kinds)
        self.assertNotIn("launch.legacy_agent_database", kinds)

    def events(self):
        items, after = [], 0
        while True:
            page = self.call("events", str(after))
            if not page["items"]: return items
            items += page["items"]; after = page["next"]

    def test_hostile_clients_neither_stall_supervision_nor_the_broker(self):
        self.supervise()
        path = str(self.broker)
        self.assertEqual(exchange(path, b"{not json\n")["error"], "invalid_request")
        self.assertEqual(exchange(path, b"x" * 400_000 + b"\n")["error"], "request_too_large")
        # More silent clients than the broker serves at once: the excess is told `busy` at once.
        slow = []
        for _ in range(40):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            slow.append(s)
        try:
            started = time.monotonic()
            self.assertEqual(exchange(path, b"{}\n", timeout=5)["error"], "busy")
            self.assertLess(time.monotonic() - started, 2)
            # Supervision keeps observing launches while every broker slot is held.
            self.call("enqueue", self.worker, "broker:exit", self.file("task-e", "Exit"))
            launched = self.call("launch", self.worker, self.recipe("exit"))
            self.wait(lambda: self.call("launch-record", launched["executionID"])["state"] == "stopped", seconds=8)
        finally:
            for s in slow: s.close()
        # Once the silent clients are gone, ordinary requests are served again promptly.
        reply = self.wait(lambda: (lambda r: r if r.get("error") != "busy" else None)(
            exchange(path, json.dumps({"execution": str(uuid.uuid4()), "credential": "x", "request": {"context": {}}}).encode() + b"\n")))
        self.assertIn(reply["error"], ("not_found", "forbidden"))
        self.assertIsNone(self.supervisor.poll())

    def test_without_a_broker_a_manual_launch_refuses_before_claiming_anything(self):
        work = self.call("enqueue", self.worker, "broker:none", self.file("task-n", "Nothing"))
        refused = self.call("launch", self.worker, self.recipe("exit"), ok=False)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("agent_broker_unavailable", refused.stderr)
        self.assertEqual(self.call("work", work["id"])["state"], "queued")
        self.assertNotIn("agentSocket", self.call("host"))
        # A supervisor that stopped withdraws its advertisement, so the next launch refuses too.
        self.supervise()
        self.supervisor.terminate(); self.supervisor.wait(timeout=20)
        self.assertFalse(self.broker.exists())
        self.assertNotIn("agentSocket", self.call("host"))
        self.assertIn("agent_broker_unavailable", self.call("launch", self.worker, self.recipe("exit"), ok=False).stderr)


if __name__ == "__main__":
    unittest.main()
