#!/usr/bin/env python3
"""Agents under their own Unix user (Linux, run as root to create the users): ptyd runs as the
agent user with a group socket, the resident supervisor as the controller user with its store in
an owner-only directory. A launched agent cannot open the store, yet every tool it uses works
through the broker, and the broker records the agent's uid. This is the deployment
autonomous-controller.md ("Running agents as another Unix user") documents."""
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

CONTROLLER, PTYD = map(os.path.abspath, sys.argv[1:3])
del sys.argv[1:3]
os.environ.pop("THREADING_CONTROLLER_LEGACY_AGENT_DATABASE", None)
GROUP, CONTROLLER_USER, AGENT_USER = "thragents", "thrctl", "thragent"

PROVIDER = r'''
import json, os, pathlib, subprocess, sys, tempfile
result = {"uid": os.getuid(), "names": sorted(os.environ)}
try:
    open(sys.argv[1], "rb").close(); result["store"] = "opened"
except PermissionError:
    result["store"] = "permission_denied"
def tool(request):
    with tempfile.NamedTemporaryFile(mode="w", dir=os.getcwd()) as f:
        json.dump(request, f); f.flush()
        out = subprocess.run([os.environ["THREADING_CONTROLLER_BIN"], "agent", f.name], capture_output=True, text=True, timeout=20)
        if out.returncode != 0: raise RuntimeError(out.stderr)
        return json.loads(out.stdout)
try:
    result["work"] = tool({"context": {}})["work"]["key"]
    tool({"memoryPut": {"key": "who", "expectedRevision": 0, "content": "agent user"}})
    tool({"finish": {"payload": "done as %d" % os.getuid()}})
except Exception as error:
    result["toolError"] = str(error)
pathlib.Path("result.json").write_text(json.dumps(result))
'''


def ensure_account(name, group):
    try: pwd.getpwnam(name)
    except KeyError: subprocess.run(["useradd", "--no-create-home", "--shell", "/usr/sbin/nologin", "-G", group, name], check=True)
    return pwd.getpwnam(name)


class AgentUserTests(unittest.TestCase):
    def setUp(self):
        try: grp.getgrnam(GROUP)
        except KeyError: subprocess.run(["groupadd", GROUP], check=True)
        self.gid = grp.getgrnam(GROUP).gr_gid
        self.controller = ensure_account(CONTROLLER_USER, GROUP)
        self.agent = ensure_account(AGENT_USER, GROUP)
        self.temp = tempfile.TemporaryDirectory(prefix="cau-", dir="/tmp")
        self.root = Path(self.temp.name); os.chmod(self.root, 0o755)
        def directory(name, owner, mode, group=None):
            path = self.root / name; path.mkdir()
            os.chown(path, owner.pw_uid, group if group is not None else owner.pw_gid); os.chmod(path, mode)
            return path
        # The store: owner-only, the controller user's.
        self.store = directory("ctl", self.controller, 0o700)
        # Each side's rendezvous in its own setgid group directory.
        self.broker_dir = directory("broker", self.controller, 0o2750, self.gid)
        self.pty_dir = directory("pty", self.agent, 0o2750, self.gid)
        self.agent_state = directory("agent-state", self.agent, 0o700)
        self.work = directory("work", self.agent, 0o700)
        # One controller executable both users can run, as the agent copy --agent-binary names.
        self.bin = directory("bin", pwd.getpwuid(0), 0o755)
        shutil.copy2(CONTROLLER, self.bin / "threading-controller"); os.chmod(self.bin / "threading-controller", 0o755)
        (self.bin / "provider.py").write_text(PROVIDER); os.chmod(self.bin / "provider.py", 0o644)
        self.db = self.store / "controller.db"
        self.pty_socket = self.pty_dir / "ptyd.sock"
        self.broker = self.broker_dir / "agent.sock"
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=20)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        self.temp.cleanup()

    def as_user(self, user, *command, background=False):
        argv = ["runuser", "-u", user, "--", *command]
        if background:
            process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.processes.append(process); return process
        return subprocess.run(argv, capture_output=True, text=True, timeout=30)

    def call(self, *args):
        result = self.as_user(CONTROLLER_USER, str(self.bin / "threading-controller"), "--database", str(self.db), *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def wait(self, operation, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            value = operation()
            if value: return value
            time.sleep(0.1)
        self.fail("timed out")

    def test_an_agent_user_cannot_open_the_store_but_its_tools_work(self):
        self.as_user(AGENT_USER, PTYD, "--socket", str(self.pty_socket), "--state", str(self.agent_state / "host"),
                     "--group-socket", background=True)
        self.wait(lambda: self.pty_socket.exists())
        self.as_user(CONTROLLER_USER, str(self.bin / "threading-controller"), "--database", str(self.db), "supervise", "200",
                     "--agent-socket", str(self.broker), "--agent-binary", str(self.bin / "threading-controller"), background=True)
        self.wait(lambda: self.broker.exists() and self.call("host").get("agentSocket") == str(self.broker))
        self.assertEqual(os.stat(self.broker).st_gid, self.gid)
        self.assertEqual(os.stat(self.pty_socket).st_gid, self.gid)

        worker = str(uuid.uuid4())
        self.call("worker-add", worker, "Agent user fixture")
        task = self.root / "task"; task.write_text("Fixture"); os.chmod(task, 0o644)
        work = self.call("enqueue", worker, "agent-user:1", str(task))
        recipe = self.root / "recipe.json"
        recipe.write_text(json.dumps({
            "socketPath": str(self.pty_socket), "executable": sys.executable,
            "arguments": [str(self.bin / "provider.py"), str(self.db)], "directory": str(self.work),
            "environment": {"PATH": "/usr/bin:/bin"}, "recipients": ["group:ops"], "destination": "fixture.drafts"}))
        os.chmod(recipe, 0o644)
        launch = self.call("launch", worker, str(recipe))
        self.wait(lambda: (self.work / "result.json").exists())
        result = json.loads((self.work / "result.json").read_text())
        self.assertEqual(result["uid"], self.agent.pw_uid)
        self.assertEqual(result["store"], "permission_denied")
        self.assertNotIn("THREADING_CONTROLLER_DATABASE", result["names"])
        self.assertNotIn("toolError", result)
        self.assertEqual(result["work"], "agent-user:1")
        self.wait(lambda: self.call("launch-record", launch["executionID"])["state"] == "stopped")
        self.assertEqual([d["payload"] for d in self.call("deliveries")["items"]], ["done as %d" % self.agent.pw_uid])
        self.assertEqual(self.call("memory-get", worker, "who")["content"], "agent user")
        history = json.dumps(self.call("work-history", work["id"]))
        self.assertIn("peer uid %d" % self.agent.pw_uid, history)


if __name__ == "__main__":
    unittest.main()
