#!/usr/bin/env python3
"""Release both apps with compact output and durable, commit-bound checkpoints.

Agent entry point: docs/operations/full-release.md. No shell evaluation, credential output,
automatic failure repair, or implicit staging of unrelated work.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPO = "everlof/threading"
MANIFEST = "Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift"


class ReleaseError(Exception):
    pass


def capture(*command: str, env=None) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode:
        raise ReleaseError(f"{command[0]} failed: {result.stderr[-2000:].strip()}")
    return result.stdout.strip()


def git(*arguments: str, env=None) -> str:
    return capture("git", *arguments, env=env)


def checkout_tree() -> str:
    """Hash exactly what --commit-all would stage, without touching the real index."""
    with tempfile.TemporaryDirectory(prefix="threading-release-index-") as directory:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(directory) / "index"))
        git("read-tree", "HEAD", env=env)
        git("add", "-A", env=env)
        return git("write-tree", env=env)


def save_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def mobile_test_destination() -> str:
    explicit = os.environ.get("THREADING_MOBILE_TEST_DESTINATION") or os.environ.get("THREADING_CONNECTIVITY_SIMULATOR_DESTINATION")
    if explicit:
        return explicit
    catalogue = json.loads(capture("xcrun", "simctl", "list", "--json"))
    runtimes = {runtime["identifier"]: tuple(map(int, runtime["version"].split(".")))
                for runtime in catalogue["runtimes"]
                if runtime.get("platform") == "iOS" and runtime.get("isAvailable")}
    candidates = [(runtimes[runtime], runtime, device)
                  for runtime, devices in catalogue["devices"].items() if runtime in runtimes
                  for device in devices if device.get("isAvailable")
                  and device.get("deviceTypeIdentifier", "").startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-")]
    if not candidates:
        raise ReleaseError("Install an iPhone simulator runtime in Xcode before releasing")
    newest = max(candidate[0] for candidate in candidates)
    candidates = [candidate for candidate in candidates if candidate[0] == newest]
    receipt = ROOT / "build/full-release/simulator.json"
    recorded = json.loads(receipt.read_text()).get("udid") if receipt.exists() else None
    # A name alone is not ownership. Reuse only a device this driver recorded creating;
    # ordinary developer simulators supply a compatible hardware/runtime profile, never data.
    device_id = next((device["udid"] for _, _, device in candidates if device["udid"] == recorded), None)
    if device_id is None:
        _, runtime, profile = candidates[0]
        device_id = capture("xcrun", "simctl", "create", "Threading Release Tests",
                            profile["deviceTypeIdentifier"], runtime)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        save_json(receipt, {"udid": device_id, "runtime": runtime})
    return f"platform=iOS Simulator,id={device_id}"


def require_visible_desktop() -> None:
    probe = '''
import CoreGraphics
import Foundation
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { exit(1) }
let state = [
    "locked": session["CGSSessionScreenIsLocked"] as? Bool ?? false,
    "asleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0
]
print(String(data: try JSONSerialization.data(withJSONObject: state), encoding: .utf8)!)
'''
    state = json.loads(capture("xcrun", "swift", "-e", probe))
    if state["locked"] or state["asleep"]:
        raise ReleaseError("Unlock and wake this Mac before running the full release: visible-window tests require a visible desktop")


@contextmanager
def visible_test_session():
    require_visible_desktop()
    # Keep automatic display sleep from invalidating the later GUI gates. This does not
    # unlock the session or prevent a person from locking it, and changes no saved setting.
    awake = subprocess.Popen(["caffeinate", "-d", "-w", str(os.getpid())],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        yield
    finally:
        awake.terminate()
        awake.wait()


class Release:
    def __init__(self, tag: str, *, omit_ui_reason: str | None = None):
        self.tag = tag
        self.omit_ui_reason = omit_ui_reason
        self.directory = ROOT / "build/full-release" / tag
        self.directory.mkdir(parents=True, exist_ok=True)
        self.state_path = self.directory / "state.json"
        self.state = json.loads(self.state_path.read_text()) if self.state_path.exists() else {"tag": tag, "steps": {}}

    def event(self, **fields) -> None:
        print(json.dumps(fields), flush=True)

    def step(self, name: str, command: list[str], key: str, *, env=None, cache=True) -> None:
        previous = self.state["steps"].get(name, {})
        if cache and previous.get("status") == "passed" and previous.get("input") == key:
            self.event(step=name, status="already-passed")
            return
        log = self.directory / f"{name}-{time.time_ns()}.log"
        record = {"status": "running", "input": key, "log": str(log), "started": time.time()}
        self.state["steps"][name] = record
        save_json(self.state_path, self.state)
        self.event(step=name, status="running", log=str(log))
        with log.open("w") as stream:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while True:
                    try:
                        code = process.wait(timeout=45)
                        break
                    except subprocess.TimeoutExpired:
                        self.event(step=name, status="running", seconds=int(time.time() - record["started"]))
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                record["status"] = "interrupted"
                save_json(self.state_path, self.state)
                raise
        record.update(status="passed" if code == 0 else "failed", exit_code=code)
        save_json(self.state_path, self.state)
        self.event(step=name, status=record["status"], log=str(log))
        if code:
            # Keep diagnostics on disk; even failure output stays bounded for small agents.
            with log.open("rb") as stream:
                stream.seek(max(0, log.stat().st_size - 6000))
                tail = stream.read().decode("utf-8", errors="replace")
            print(tail, file=sys.stderr)
            raise ReleaseError(f"{name} failed ({code}); fix the cause and rerun the same command")

    def assert_snapshot(self, revision: str, tree: str) -> None:
        if git("rev-parse", "HEAD") != revision or checkout_tree() != tree:
            raise ReleaseError("Checkout changed during validation; rerun after other writers finish")
        # A gitlink hashes the child's commit, not edits inside its working directory.
        if git("submodule", "foreach", "--quiet", "git status --porcelain"):
            raise ReleaseError("Submodule source changed during validation; rerun after other writers finish")

    def validate(self) -> tuple[str, str]:
        capture("docker", "info", "--format", "{{.ServerVersion}}")
        revision, tree = git("rev-parse", "HEAD"), checkout_tree()
        key = tree + ":" + capture("xcodebuild", "-version") + ":" + os.environ.get("THREADING_MOBILE_TEST_DESTINATION", "")
        for name, command in [("linux-runners", ["python3", "-m", "unittest", "discover", "-s", "Platforms/Linux/tests"]),
                              ("proxy", ["python3", "scripts/test-proxy.py"]),
                              ("linux-bundle", ["Platforms/Linux/bundle-smoke.sh"]),
                              ("quality", ["scripts/ci.sh", "--full-release"]),
                              ("ui", ["scripts/test.sh", "ui"])]:
            if name == "ui" and self.omit_ui_reason:
                # An explicit user opt-out is a limitation, never a passing checkpoint.
                # Retain any failed run and its log beside the reason for not retrying it.
                self.state["ui_omission"] = {"input": key, "reason": self.omit_ui_reason}
                save_json(self.state_path, self.state)
                self.event(step=name, status="omitted", reason=self.omit_ui_reason)
                self.assert_snapshot(revision, tree)
                continue
            self.step(name, command, key)
            try:
                self.assert_snapshot(revision, tree)
            except ReleaseError:
                self.state["steps"][name]["status"] = "invalidated"
                save_json(self.state_path, self.state)
                raise
            if name == "ui" and self.state.pop("ui_omission", None) is not None:
                save_json(self.state_path, self.state)
        return revision, tree

    def commit(self, message: str, revision: str, tree: str) -> str:
        self.assert_snapshot(revision, tree)
        git("add", "-A")
        if git("write-tree") != tree:
            raise ReleaseError("Staged content differs from the tested content")
        self.step("commit", ["git", "commit", "-m", message], tree, cache=False)
        if git("rev-parse", "HEAD^{tree}") != tree or git("status", "--porcelain"):
            raise ReleaseError("Checkout changed while committing; stop other writers and rerun")
        return git("rev-parse", "HEAD")

    def publish_components(self, revision: str, tree: str) -> str:
        current = subprocess.run(["python3", "scripts/check_remote_components.py", "--local"],
                                 cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if current.returncode == 0:
            self.step("components-check", ["python3", "scripts/check_remote_components.py"], revision, cache=False)
            return revision
        # Component inputs must exist publicly before the component publisher can name them.
        # This narrowly scoped source publication follows both full quality and UI gates.
        self.step("fetch", ["git", "-c", "submodule.recurse=false", "fetch", "--no-recurse-submodules",
                            "--no-tags", "origin", "+refs/heads/master:refs/remotes/origin/master"], revision, cache=False)
        git("merge-base", "--is-ancestor", "origin/master", revision)
        self.assert_snapshot(revision, tree)
        if git("status", "--porcelain"):
            raise ReleaseError("Component source publication requires a clean checkout")
        self.step("component-source", ["git", "-c", "submodule.recurse=false", "push",
                                      "--recurse-submodules=no", "origin", f"{revision}:refs/heads/master"],
                  revision, env=dict(os.environ, THREADING_SKIP_TESTS="1"), cache=False)
        self.step("components", ["scripts/publish_remote_components.sh"], revision, cache=False)
        if not git("status", "--porcelain"):
            return revision
        changed = git("diff", "--name-only", "HEAD").splitlines()
        if changed != [MANIFEST] or git("ls-files", "--others", "--exclude-standard"):
            raise ReleaseError("Unexpected changes beside the generated component manifest")
        tested_revision, generated_tree = self.validate()
        return self.commit("Refresh verified remote host components", tested_revision, generated_tree)

    def run(self, *, commit_all: bool, submit_review: bool, verify_only: bool) -> None:
        if git("branch", "--show-current") != "master":
            raise ReleaseError("Use the master checkout")
        if git("remote", "get-url", "origin") not in {
            f"git@github.com:{REPO}.git", f"https://github.com/{REPO}.git", f"https://github.com/{REPO}"
        }:
            raise ReleaseError(f"origin must be {REPO}")
        if any(line[:1] in {"+", "-", "U"} for line in git("submodule", "status").splitlines()):
            raise ReleaseError("Submodules must be initialized at their recorded commits")
        if git("submodule", "foreach", "--quiet", "git status --porcelain"):
            raise ReleaseError("Commit submodule changes in their owning repositories first")
        if git("status", "--porcelain") and not (commit_all or verify_only):
            raise ReleaseError("Dirty checkout: commit it, or explicitly pass --commit-all")
        published = self.state["steps"].get("macos", {})
        if published.get("status") == "passed" and (
            published.get("input") != git("rev-parse", "HEAD") or git("status", "--porcelain")
        ):
            raise ReleaseError("This tag was already published from another source state; use a new release tag for changes")
        version = self.tag.removeprefix("v")
        if f"## [{version}]" not in (ROOT / "CHANGELOG.md").read_text():
            raise ReleaseError(f"Write CHANGELOG.md notes for {version} before running")
        revision, tree = self.validate()
        if verify_only:
            self.event(status="verified", revision=revision, tree=tree)
            return
        if git("status", "--porcelain"):
            revision = self.commit(f"Prepare Threading {version}", revision, tree)
        revision = self.publish_components(revision, tree)
        tree = git("rev-parse", "HEAD^{tree}")
        # Every existing publishing gate still runs. Checkpoints save agent tokens, not checks.
        self.assert_snapshot(revision, tree)
        self.step("macos", ["scripts/publish_local_release.sh", self.tag], revision)
        self.assert_snapshot(revision, tree)
        self.step("public-sdk", ["scripts/verify_published_plugin_sdk.sh", self.tag, version], revision)
        self.assert_snapshot(revision, tree)
        receipt = self.directory / "ios.json"
        fastlane = ["bundle", "exec", "fastlane", "ios"]
        lane_env = dict(os.environ, FASTLANE_SKIP_UPDATE_CHECK="1", FASTLANE_SKIP_DOCS="1",
                        FASTLANE_DISABLE_COLORS="1")
        self.step("ios", fastlane + ["beta", f"receipt:{receipt}"], revision, env=lane_env)
        self.assert_snapshot(revision, tree)
        if submit_review:
            self.step("metadata", fastlane + ["metadata"], revision, env=lane_env)
            self.assert_snapshot(revision, tree)
            self.step("screenshots", fastlane + ["upload_screenshots", "apply:true", "release_copy:true"],
                      revision, env=lane_env)
            self.assert_snapshot(revision, tree)
            self.step("review", fastlane + ["submit_review", f"receipt:{receipt}"], revision,
                      env=lane_env, cache=False)
        self.event(status="complete", commit=revision,
                   macos=f"https://github.com/{REPO}/releases/tag/{self.tag}",
                   ios_receipt=str(receipt), submitted=submit_review,
                   ui_verified=not bool(self.omit_ui_reason))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="new stable Mac tag, for example v0.11.0")
    parser.add_argument("--commit-all", action="store_true", help="commit all nonignored repo changes after tests")
    parser.add_argument("--submit-review", action="store_true", help="submit iOS to App Review, with manual release after approval")
    parser.add_argument("--verify-only", action="store_true", help="run quality and UI tests without committing or publishing")
    parser.add_argument("--status", action="store_true", help="print checkpoints without running anything")
    parser.add_argument("--omit-ui-reason", help="record an explicit user request to omit UI automation; never marks it passed")
    args = parser.parse_args()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag):
        parser.error("tag must be vX.Y.Z")
    if args.omit_ui_reason is not None and not args.omit_ui_reason.strip():
        parser.error("--omit-ui-reason requires the user's reason")
    release = Release(args.tag, omit_ui_reason=args.omit_ui_reason)
    if args.status:
        print(json.dumps(release.state, indent=2))
        return 0
    lock_path = ROOT / "build/full-release/driver.lock"
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ReleaseError("Another full release driver is running in this checkout")
        with visible_test_session():
            os.environ["THREADING_MOBILE_TEST_DESTINATION"] = mobile_test_destination()
            release.run(commit_all=args.commit_all, submit_review=args.submit_review, verify_only=args.verify_only)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ReleaseError, KeyboardInterrupt) as error:
        print(json.dumps({"status": "stopped", "reason": str(error) or "interrupted"}), file=sys.stderr)
        sys.exit(1)
