#!/usr/bin/env python3
"""Agent mail between two controller stores, through real processes: a ptyd-hosted agent asks an
agent on another "host", which is woken by the mail, replies, and the asker continues. A busy
agent is told about urgent mail by the hook command while it runs. The transport between the
stores is the controller's own mail-rpc, run directly instead of through ssh."""
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
import json, os, pathlib, subprocess, sys, tempfile, time, traceback, uuid
def report(kind, value, tb):
    pathlib.Path("provider-error-%s.txt" % sys.argv[1]).write_text("".join(traceback.format_exception(kind, value, tb)))
sys.excepthook = report
def tool(request):
    with tempfile.NamedTemporaryFile(mode="w", dir=os.getcwd()) as f:
        json.dump(request, f); f.flush()
        result = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent", f.name],
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
def notice(event):
    result = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent-notice", event],
                            input='{"hook_event_name":"x"}', capture_output=True, text=True, timeout=10)
    assert result.returncode == 0
    return result.stdout.strip()
mode = sys.argv[1]
work = tool({"context": {}})["work"]
if mode == "ask":
    if not work["checkpoint"]:
        tool({"mailAsk": {"to": os.environ["MAIL_TO"], "id": str(uuid.uuid4()), "text": "Which region should we deploy to?", "checkpoint": "Asked the reviewer"}})
    else:
        answer = tool({"questions": {"after": 0}})["questions"]["items"][0]["answer"]
        inbox = tool({"mailInbox": {"after": 0}})["inbox"]["items"]
        tool({"mailAck": {"ids": [item["message"]["envelope"]["id"] for item in inbox]}})
        tool({"finish": {"payload": "Deploy to " + answer}})
elif mode == "reply":
    inbox = tool({"mailInbox": {"after": 0}})["inbox"]["items"]
    asked = [item for item in inbox if item["message"]["envelope"].get("questionID")][0]
    assert "Sent by that agent" in asked["header"]
    sender = asked["message"]["envelope"]["sender"]
    tool({"mailSend": {"to": sender, "id": str(uuid.uuid4()), "text": "eu-north-1", "replyTo": asked["message"]["envelope"]["id"], "priority": "normal"}})
    tool({"mailAck": {"ids": [asked["message"]["envelope"]["id"]]}})
    tool({"finish": {"payload": "Answered"}})
elif mode == "busy":
    pathlib.Path("busy-started").write_text("1")
    deadline = time.time() + 20
    output = ""
    while time.time() < deadline and not output:
        output = notice("post-tool-use")
        time.sleep(0.05)
    pathlib.Path("busy-notice.json").write_text(output)
    assert notice("post-tool-use") == ""   # announced once
    stop = notice("stop")
    pathlib.Path("busy-stop.json").write_text(stop)
    assert notice("stop") == ""            # blocks a stop once per message
    try:
        tool({"finish": {"payload": "too early"}})
        raise AssertionError("finish succeeded with unread urgent mail")
    except AssertionError as error:
        if "finish succeeded" in str(error): raise
    inbox = tool({"mailInbox": {"after": 0}})["inbox"]["items"]
    tool({"mailAck": {"ids": [item["message"]["envelope"]["id"] for item in inbox]}})
    tool({"finish": {"payload": "Read: " + inbox[0]["message"]["envelope"]["text"]}})
'''


class Host:
    def __init__(self, test, name):
        self.test = test
        self.root = test.root / name
        self.root.mkdir(mode=0o700)
        self.db = self.root / "controller.db"
        self.id = self.call("host")["id"]

    def file(self, name, text):
        path = self.root / name
        path.write_text(text)
        return str(path)

    def call(self, *args, ok=True, stdin=None):
        result = subprocess.run([CONTROLLER, "--database", str(self.db), *args], capture_output=True,
                                text=True, timeout=30, input=stdin)
        if not ok: return result
        self.test.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def recipe(self, mode, environment=None):
        env = {"PATH": "/usr/bin:/bin", "TERM": "xterm-256color"}
        env.update(environment or {})
        return self.file("recipe-%s.json" % mode, json.dumps({
            "socketPath": str(self.test.socket), "executable": sys.executable,
            "arguments": [str(self.test.root / "provider.py"), mode], "directory": str(self.root),
            "environment": env, "recipients": ["group:ops"], "destination": "fixture.drafts",
        }))


class MailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mail-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.socket = self.root / "p.sock"
        self.log = open(self.root / "ptyd.log", "wb")
        self.daemon = subprocess.Popen([PTYD, "--socket", str(self.socket), "--state", str(self.root / "pty")],
                                       stdout=self.log, stderr=self.log)
        self.wait(lambda: self.socket.exists())
        (self.root / "provider.py").write_text(PROVIDER)
        self.mac, self.vps = Host(self, "mac"), Host(self, "vps")
        # The Mac reaches the VPS; the VPS cannot reach the Mac.
        transport = [CONTROLLER, "--database", str(self.vps.db), "mail-rpc", "--peer", self.mac.id]
        self.mac.call("mail-peer-set", self.vps.id, "0", "vps-1", self.mac.file("peer.json", json.dumps({"transport": transport, "push": True, "pull": True})))
        self.vps.call("mail-peer-set", self.mac.id, "0", "laptop", self.vps.file("peer.json", json.dumps({"transport": None, "push": False, "pull": False})))

    def tearDown(self):
        try:
            for host in (self.mac, self.vps):
                for worker in host.call("workers")["items"]:
                    for work in host.call("works", worker["id"])["items"]:
                        for launch in host.call("launches", work["id"])["items"]:
                            if launch["state"] in ("running", "dispatching"):
                                host.call("launch-stop", launch["executionID"], ok=False)
        finally:
            self.daemon.terminate()
            try: self.daemon.wait(timeout=10)
            except subprocess.TimeoutExpired: self.daemon.kill(); self.daemon.wait()
            self.log.close()
            self.temp.cleanup()

    def wait(self, operation, seconds=15):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.05)
        errors = "".join(p.read_text() for p in self.root.rglob("provider-error-*.txt"))
        self.fail("Timed out waiting for fixture state: " + (errors or "no provider exception"))

    def worker(self, host, name, key):
        worker = str(uuid.uuid4())
        host.call("worker-add", worker, name)
        work = host.call("enqueue", worker, key, host.file("task-" + key, "Fixture task")) if key else None
        return worker, host.call("mail-address", worker), work

    def test_question_crosses_hosts_wakes_the_recipient_and_its_reply_continues_the_asker(self):
        asker, asker_address, ask_work = self.worker(self.mac, "Release manager", "release:1")
        reviewer, reviewer_address, _ = self.worker(self.vps, "Reviewer", None)
        self.vps.call("mail-grant-set", reviewer_address, self.mac.id + "/*", "0", "ask", "normal")
        self.vps.call("worker-set-sources", reviewer, "0", "request,event")
        policy = self.vps.call("worker-configure", reviewer, "0", "1", self.vps.recipe("reply"))
        self.vps.call("worker-enable", reviewer, str(policy["revision"]))

        launch = self.mac.call("launch", asker, self.mac.recipe("ask", {"MAIL_TO": reviewer_address}))
        self.wait(lambda: self.mac.call("work", ask_work["id"])["state"] == "waiting")
        self.wait(lambda: self.mac.call("launch-status", launch["executionID"])["presence"] == "stopped")
        held = self.mac.call("mail-outbound", self.vps.id)
        self.assertEqual(len(held), 1)
        self.assertEqual(held[0]["sender"], asker_address)

        self.assertEqual(self.mac.call("mail-sync")["pushed"], 1)
        self.assertEqual(self.mac.call("mail-outbound", self.vps.id), [])
        self.assertEqual(len(self.vps.call("mailbox", reviewer_address)["items"]), 1)

        # The reviewer was idle: the mail admits one task and the same tick launches it.
        cycle = self.vps.call("supervisor-tick")
        self.assertEqual(len(cycle["woken"]), 1)
        self.assertEqual(len(cycle["started"]), 1)
        reply_work = self.vps.call("works", reviewer)["items"][0]
        self.wait(lambda: self.vps.call("work", reply_work["id"])["state"] == "completed")

        # The VPS holds the reply until the Mac pulls it; the pull answers the question.
        self.assertEqual(self.mac.call("mail-sync")["pulled"], 1)
        self.assertEqual(self.mac.call("work", ask_work["id"])["state"], "queued")
        question = self.mac.call("questions", ask_work["id"])["items"][0]
        self.assertEqual(question["answer"], "eu-north-1")
        self.assertEqual(question["answeredBy"], "agent:" + reviewer_address)

        resumed = self.mac.call("launch", asker, self.mac.recipe("ask", {"MAIL_TO": reviewer_address}))
        delivery = self.wait(lambda: self.mac.call("deliveries")["items"])
        self.assertEqual(delivery[0]["payload"], "Deploy to eu-north-1")
        self.wait(lambda: self.mac.call("launch-status", resumed["executionID"])["presence"] == "stopped")
        # The next pull acknowledges the reply's page, and the VPS records it as handed over.
        self.mac.call("mail-sync")
        sent = self.vps.call("mail-history", asker_address)["items"]
        self.assertEqual([m["state"] for m in sent], ["forwarded"])

    def test_a_busy_agent_is_told_about_urgent_mail_and_cannot_finish_before_reading_it(self):
        busy, busy_address, busy_work = self.worker(self.vps, "Builder", "build:1")
        session = "%s/session/%s" % (self.vps.id, uuid.uuid4())
        self.vps.call("mail-register", session, "Operator console")
        self.vps.call("mail-grant-set", busy_address, session, "0", "notify", "interrupt")
        launch = self.vps.call("launch", busy, self.vps.recipe("busy"))
        self.wait(lambda: (self.vps.root / "busy-started").exists())
        self.vps.call("mail-send", session, busy_address, str(uuid.uuid4()), self.vps.file("m", "BODY: stop the deploy"), "interrupt")
        delivery = self.wait(lambda: self.vps.call("deliveries")["items"])
        self.assertEqual(delivery[0]["payload"], "Read: BODY: stop the deploy")
        hook = json.loads((self.vps.root / "busy-notice.json").read_text())
        context = hook["hookSpecificOutput"]["additionalContext"]
        self.assertEqual(hook["hookSpecificOutput"]["hookEventName"], "PostToolUse")
        self.assertIn("Operator console", context)
        self.assertIn("urgent", context)
        self.assertNotIn("stop the deploy", context)   # a notice never carries the body
        stop = json.loads((self.vps.root / "busy-stop.json").read_text())
        self.assertEqual(stop["decision"], "block")
        self.wait(lambda: self.vps.call("launch-status", launch["executionID"])["presence"] == "stopped")

    def test_a_session_on_this_host_gets_only_mail_tools_from_agent_mcp(self):
        _, worker_address, _ = self.worker(self.vps, "Builder", "build:1")
        session = "%s/session/%s" % (self.vps.id, uuid.uuid4())
        self.vps.call("mail-register", session, "Remote Claude session")
        credential = self.vps.call("mail-credential", session)
        self.vps.call("mail-grant-set", worker_address, session, "0", "notify", "normal")
        env = {"PATH": "/usr/bin:/bin", "THREADING_CONTROLLER_DATABASE": str(self.vps.db),
               "THREADING_MAILBOX_ADDRESS": session, "THREADING_MAILBOX_CREDENTIAL": credential}
        lines = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "mail_send", "arguments": {"to": worker_address, "id": str(uuid.uuid4()), "text": "Session hello"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "work_context", "arguments": {}}},
        ]
        result = subprocess.run([CONTROLLER, "agent-mcp"], input="".join(json.dumps(l) + "\n" for l in lines),
                                capture_output=True, text=True, timeout=15, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = {r["id"]: r for r in map(json.loads, result.stdout.splitlines())}
        self.assertEqual({t["name"] for t in replies[2]["result"]["tools"]}, {"mail_send", "mail_inbox", "mail_ack", "mail_directory"})
        self.assertFalse(replies[3]["result"]["isError"])
        self.assertTrue(replies[4]["result"]["isError"])
        self.assertEqual([i["message"]["envelope"]["text"] for i in self.vps.call("mailbox", worker_address)["items"]], ["Session hello"])
        # The notice hook works for a session too, and says nothing when there is nothing new.
        notice = subprocess.run([CONTROLLER, "agent-notice", "session-start"], input="{}", capture_output=True, text=True, timeout=15, env=env)
        self.assertEqual((notice.returncode, notice.stdout), (0, ""))

    def test_the_receiving_end_refuses_unknown_peers_and_spoofed_senders(self):
        stranger = str(uuid.uuid4())
        request = json.dumps({"pull": {"after": 0}})
        self.assertNotEqual(self.vps.call("mail-rpc", "--peer", stranger, ok=False, stdin=request).returncode, 0)
        _, recipient, _ = self.worker(self.vps, "Reviewer", None)
        self.vps.call("mail-grant-set", recipient, "*", "0", "notify", "normal")
        forged = {"id": str(uuid.uuid4()), "sender": "%s/worker/%s" % (uuid.uuid4(), uuid.uuid4()), "senderName": "x",
                  "recipient": recipient, "text": "forged", "priority": "normal", "chainID": str(uuid.uuid4()),
                  "depth": 0, "sentAt": "2026-10-03T00:00:00Z"}
        result = self.vps.call("mail-rpc", "--peer", self.mac.id, stdin=json.dumps({"push": {"from": self.mac.id, "messages": [forged]}}))
        self.assertEqual(result["results"][0]["outcome"], "refused")
        self.assertEqual(result["host"], self.vps.id)
        # A transport that reaches the wrong host is refused by the caller.
        wrong = [CONTROLLER, "--database", str(self.mac.db), "mail-rpc", "--peer", self.vps.id]
        self.mac.call("mail-peer-set", self.vps.id, "1", "vps-1", self.mac.file("peer2.json", json.dumps({"transport": wrong, "push": True, "pull": True})))
        self.assertTrue(self.mac.call("mail-sync")["issues"])


if __name__ == "__main__":
    unittest.main()
