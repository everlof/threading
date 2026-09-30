#!/usr/bin/env python3
"""Exercise the real owner CLI and the RPC carried by SSH; never use a live database."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid

binary = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="controller-automations-") as root:
    os.chmod(root, 0o700)
    base = [binary, "--database", str(pathlib.Path(root) / "controller.db")]

    def call(command, arguments):
        request = {"command": command, "arguments": arguments}
        completed = subprocess.run(base + ["owner-rpc"], input=json.dumps(request), text=True,
                                   capture_output=True, timeout=15, check=True)
        return json.loads(completed.stdout)

    def val(value):
        return {"value": str(value)}

    worker, automation = str(uuid.uuid4()), str(uuid.uuid4())
    call("worker-add", [val(worker), val("Reports")])
    spec = {"name": "Morning report", "workerID": worker, "instruction": "Summarize yesterday",
            "schedule": {"kind": "daily", "timeZone": "Europe/Stockholm", "hour": 9},
            "missedPolicy": "skip", "archiveOnSuccess": True}
    created = call("automation-configure", [val(automation), val(0), {"text": json.dumps(spec)}])
    assert created["revision"] == 1 and not created["enabled"]
    active = call("automation-enable", [val(automation), val(1)])
    assert active["enabled"] and active["nextRunAt"]
    listed = call("automations", [])
    assert listed["items"][0]["id"] == automation
    inspected = call("automation", [val(automation)])
    assert inspected["spec"]["schedule"]["timeZone"] == "Europe/Stockholm"
    first = call("automation-run", [val(automation), val(2), val("request-1")])
    retry = call("automation-run", [val(automation), val(2), val("request-1")])
    assert first == retry and first["admission"] == "enqueued"
    runs = call("automation-runs", [val(automation)])
    assert len(runs["items"]) == 1 and not runs["items"][0]["archived"]
    paused = call("automation-pause", [val(automation), val(2)])
    assert not paused["enabled"]
    deleted = call("automation-delete", [val(automation), val(3)])
    assert deleted["deleted"]
    assert len(call("automation-runs", [val(automation)])["items"]) == 1
print("Controller automation CLI/RPC lifecycle passed")
