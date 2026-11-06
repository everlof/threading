"""Launch policy regressions; no Playwright install or browser download required."""

import importlib.util
from pathlib import Path
import types
import unittest
from unittest.mock import MagicMock, patch


SCRIPT = (Path(__file__).resolve().parents[2]
          / "Sources/Threading/Resources/BrowserAutomation/playwright_bridge.py")
SPEC = importlib.util.spec_from_file_location("playwright_bridge_security", SCRIPT)
bridge = importlib.util.module_from_spec(SPEC)
api = types.ModuleType("playwright.sync_api")
api.Error = RuntimeError
api.TimeoutError = TimeoutError
api.expect = MagicMock()
api.sync_playwright = MagicMock()
with patch.dict("sys.modules", {"playwright.sync_api": api}):
    SPEC.loader.exec_module(bridge)


class PlaywrightLaunchSecurityTests(unittest.TestCase):
    def setUp(self):
        self.runtime = MagicMock()
        self.factory = patch.object(bridge, "sync_playwright")
        self.factory.start().return_value.__enter__.return_value = self.runtime
        self.addCleanup(self.factory.stop)
        self.request = {"steps": [{"action": "snapshot"}]}
        self.attached = dict(self.request, user_data_dir="/tmp/test-profile",
                             allowed_origins=["https://example.com"])

    def assert_safe_launch_failure(self, entry, request, launcher):
        launcher.side_effect = RuntimeError("sandbox or browser unavailable")
        with self.assertRaisesRegex(RuntimeError, "sandbox or browser unavailable"):
            entry(request)
        # Failure propagates; there must be no retry against an unsandboxed/cached browser.
        self.assertEqual(launcher.call_count, 1)
        self.assertEqual(launcher.call_args.kwargs["channel"], "chrome")
        self.assertIs(launcher.call_args.kwargs["chromium_sandbox"], True)

    def test_isolated_launch_uses_sandboxed_stable_chrome_and_fails_closed(self):
        self.assert_safe_launch_failure(
            bridge.run, self.request, self.runtime.chromium.launch)

    def test_request_cannot_override_isolated_browser_or_sandbox(self):
        request = dict(self.request, channel="chromium", chromium_sandbox=False,
                       args=["--no-sandbox"])
        self.assert_safe_launch_failure(
            bridge.run, request, self.runtime.chromium.launch)
        self.assertNotIn("args", self.runtime.chromium.launch.call_args.kwargs)

    def test_attached_launch_uses_sandboxed_stable_chrome_and_fails_closed(self):
        self.assert_safe_launch_failure(
            bridge.run_attached, self.attached,
            self.runtime.chromium.launch_persistent_context)

    def test_attached_launch_refuses_alternate_or_empty_channels(self):
        for channel in ("", "chromium", "chrome-for-testing", "chrome-beta", None):
            with self.subTest(channel=channel):
                with self.assertRaisesRegex(ValueError, "installed stable Chrome"):
                    bridge.run_attached(dict(self.attached, channel=channel))
        self.runtime.chromium.launch_persistent_context.assert_not_called()

    def test_other_engines_keep_their_native_launch_options(self):
        for engine in ("firefox", "webkit"):
            with self.subTest(engine=engine):
                launcher = getattr(self.runtime, engine).launch
                launcher.side_effect = RuntimeError("engine unavailable")
                with self.assertRaisesRegex(RuntimeError, "engine unavailable"):
                    bridge.run(dict(self.request, engine=engine))
                launcher.assert_called_once_with(headless=True)


if __name__ == "__main__":
    unittest.main()
