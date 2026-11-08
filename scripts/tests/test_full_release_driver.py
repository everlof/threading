"""Release orchestration refusal/retry contracts; never contacts publishing services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("release_all", Path(__file__).parents[1] / "release_all.py")
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)


class FullReleaseDriverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root_patch = patch.object(driver, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        for args in [("init", "-b", "master"), ("config", "user.email", "test@example.invalid"),
                     ("config", "user.name", "Fixture"), ("config", "core.hooksPath", "/dev/null"),
                     ("remote", "add", "origin", "git@github.com:everlof/threading.git")]:
            driver.git(*args)
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "CHANGELOG.md").write_text("## [0.11.0]\nFixture release\n")
        driver.git("add", ".")
        driver.git("commit", "-m", "fixture")
        self.release = driver.Release("v0.11.0")
        self.events = patch.object(self.release, "event")
        self.events.start()
        self.addCleanup(self.events.stop)

    def test_tree_includes_untracked_content_without_staging_and_survives_commit(self):
        old = driver.checkout_tree()
        (self.root / "new").write_text("new input")
        tree = driver.checkout_tree()
        self.assertNotEqual(old, tree)
        self.assertEqual(driver.git("diff", "--cached"), "")
        self.release.commit("tested fixture", driver.git("rev-parse", "HEAD"), tree)
        self.assertEqual(driver.git("rev-parse", "HEAD^{tree}"), tree)
        self.assertEqual(driver.checkout_tree(), tree)

    def test_changed_content_refuses_commit(self):
        revision, tree = driver.git("rev-parse", "HEAD"), driver.checkout_tree()
        (self.root / "late").write_text("concurrent edit")
        with self.assertRaisesRegex(driver.ReleaseError, "changed during"):
            self.release.commit("must not commit", revision, tree)
        self.assertEqual(driver.git("rev-parse", "HEAD"), revision)

    def test_changed_submodule_source_invalidates_an_unchanged_gitlink(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for arguments in [("init",), ("config", "user.email", "test@example.invalid"),
                              ("config", "user.name", "Fixture"),
                              ("config", "core.hooksPath", "/dev/null")]:
                driver.git("-C", str(source), *arguments)
            (source / "source.swift").write_text("let value = 1\n")
            driver.git("-C", str(source), "add", ".")
            driver.git("-C", str(source), "commit", "-m", "child fixture")
            driver.git("-c", "protocol.file.allow=always", "submodule", "add", str(source), "vendor")
            driver.git("commit", "-m", "record child")
            revision, tree = driver.git("rev-parse", "HEAD"), driver.checkout_tree()
            self.release.assert_snapshot(revision, tree)

            (self.root / "vendor/source.swift").write_text("let value = 2\n")
            self.assertEqual(driver.checkout_tree(), tree)
            with self.assertRaisesRegex(driver.ReleaseError, "Submodule source changed"):
                self.release.assert_snapshot(revision, tree)

    def test_locked_or_sleeping_desktop_refuses_visible_tests(self):
        for state in [{"locked": True, "asleep": False}, {"locked": False, "asleep": True}]:
            with self.subTest(state=state), patch.object(driver, "capture", return_value=json.dumps(state)):
                with self.assertRaisesRegex(driver.ReleaseError, "Unlock and wake"):
                    driver.require_visible_desktop()
        with patch.object(driver, "capture", return_value='{"locked": false, "asleep": false}'):
            driver.require_visible_desktop()

    def test_explicit_mobile_destination_needs_no_simulator_mutation(self):
        with patch.dict(os.environ, {"THREADING_MOBILE_TEST_DESTINATION": "platform=iOS Simulator,id=chosen"}, clear=True), \
             patch.object(driver, "capture") as capture:
            self.assertEqual(driver.mobile_test_destination(), "platform=iOS Simulator,id=chosen")
            capture.assert_not_called()

    def test_mobile_destination_creates_its_own_device_then_reuses_its_receipt(self):
        runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
        device = {"name": "Threading Release Tests", "udid": "personal", "isAvailable": True,
                  "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}
        catalogue = {"runtimes": [{"identifier": runtime, "platform": "iOS", "version": "27.2", "isAvailable": True}],
                     "devices": {runtime: [device]}}
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(driver, "capture", side_effect=[json.dumps(catalogue), "owned"]) as capture:
            self.assertEqual(driver.mobile_test_destination(), "platform=iOS Simulator,id=owned")
            self.assertEqual(capture.call_args.args,
                             ("xcrun", "simctl", "create", "Threading Release Tests", device["deviceTypeIdentifier"], runtime))
        catalogue["devices"][runtime].append(dict(device, udid="owned"))
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(driver, "capture", return_value=json.dumps(catalogue)) as capture:
            self.assertEqual(driver.mobile_test_destination(), "platform=iOS Simulator,id=owned")
            self.assertEqual(capture.call_count, 1)

    def test_unavailable_mobile_runtime_refuses_before_creating_a_device(self):
        catalogue = {"runtimes": [{"identifier": "old", "platform": "iOS", "version": "26.0", "isAvailable": False}],
                     "devices": {"old": [{"isAvailable": True, "udid": "stale",
                                           "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}]}}
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(driver, "capture", return_value=json.dumps(catalogue)) as capture:
            with self.assertRaisesRegex(driver.ReleaseError, "Install an iPhone"):
                driver.mobile_test_destination()
            self.assertEqual(capture.call_count, 1)

    def test_failed_gate_never_commits_or_publishes(self):
        (self.root / "new").write_text("change")
        original = driver.git("rev-parse", "HEAD")
        with patch.object(self.release, "validate", side_effect=driver.ReleaseError("gate failed")), \
             patch.object(self.release, "publish_components") as publish:
            with self.assertRaisesRegex(driver.ReleaseError, "gate failed"):
                self.release.run(commit_all=True, submit_review=True, verify_only=False)
            publish.assert_not_called()
        self.assertEqual(driver.git("rev-parse", "HEAD"), original)

    def test_ui_omission_is_explicit_preserves_failure_and_keeps_other_gates(self):
        real_capture = driver.capture

        def capture(*command, **kwargs):
            if command[0] in {"docker", "xcodebuild"}:
                return "fixture version"
            return real_capture(*command, **kwargs)

        with patch.object(driver, "capture", side_effect=capture), \
             patch.object(self.release, "step") as step:
            self.release.validate()
            self.assertIn("ui", [call.args[0] for call in step.call_args_list])
            step.reset_mock()
            self.release.omit_ui_reason = "User requested no further UI runs"
            failed = {"status": "failed", "log": "prior-ui.log"}
            self.release.state["steps"]["ui"] = failed
            self.release.validate()
        self.assertEqual([call.args[0] for call in step.call_args_list],
                         ["linux-runners", "proxy", "linux-bundle", "quality"])
        recorded = json.loads(self.release.state_path.read_text())
        self.assertEqual(recorded["steps"]["ui"], failed)
        self.assertEqual(recorded["ui_omission"]["reason"], self.release.omit_ui_reason)

    def test_dirty_checkout_requires_explicit_commit_scope(self):
        (self.root / "new").write_text("change")
        with patch.object(self.release, "validate") as validate:
            with self.assertRaisesRegex(driver.ReleaseError, "--commit-all"):
                self.release.run(commit_all=False, submit_review=True, verify_only=False)
            validate.assert_not_called()

    def test_failed_child_is_not_cached_and_changed_input_runs_again(self):
        with self.assertRaises(driver.ReleaseError):
            self.release.step("gate", [sys.executable, "-c", "raise SystemExit(7)"], "tree")
        self.assertEqual(self.release.state["steps"]["gate"]["exit_code"], 7)
        marker = self.root / "build/count"
        command = [sys.executable, "-c", f"from pathlib import Path; p=Path({str(marker)!r}); p.write_text(p.read_text()+'x' if p.exists() else 'x')"]
        self.release.step("gate", command, "tree")
        self.release.step("gate", command, "tree")
        self.assertEqual(marker.read_text(), "x")
        self.release.step("gate", command, "changed-tree")
        self.assertEqual(marker.read_text(), "xx")
        resumed = driver.Release("v0.11.0")
        self.assertEqual(resumed.state["steps"]["gate"]["status"], "passed")

    def test_macos_failure_prevents_ios_upload_and_review(self):
        revision, tree = driver.git("rev-parse", "HEAD"), driver.checkout_tree()
        calls = []

        def step(name, *args, **kwargs):
            calls.append(name)
            if name == "macos":
                raise driver.ReleaseError("notary failed")

        with patch.object(self.release, "validate", return_value=(revision, tree)), \
             patch.object(self.release, "publish_components", return_value=revision), \
             patch.object(self.release, "step", side_effect=step):
            with self.assertRaisesRegex(driver.ReleaseError, "notary failed"):
                self.release.run(commit_all=False, submit_review=True, verify_only=False)
        self.assertEqual(calls, ["macos"])

    def test_success_orders_mac_before_exact_ios_receipt_and_review(self):
        revision, tree = driver.git("rev-parse", "HEAD"), driver.checkout_tree()
        with patch.object(self.release, "validate", return_value=(revision, tree)), \
             patch.object(self.release, "publish_components", return_value=revision), \
             patch.object(self.release, "step") as step:
            self.release.run(commit_all=False, submit_review=True, verify_only=False)
        self.assertEqual([call.args[0] for call in step.call_args_list],
                         ["macos", "public-sdk", "ios", "metadata", "screenshots", "review"])
        upload = step.call_args_list[2].args[1][-1]
        submit = step.call_args_list[5].args[1][-1]
        self.assertEqual(upload, submit)
        self.assertTrue(upload.startswith("receipt:"))


if __name__ == "__main__":
    unittest.main()
