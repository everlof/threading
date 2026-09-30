"""Exercise release credential selection with a fake CLI and synthetic tokens only."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "sentry-release.sh"


class SentryReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "checkout"
        (self.root / "scripts").mkdir(parents=True)
        self.script = self.root / "scripts/sentry-release.sh"
        shutil.copy2(SCRIPT, self.script)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.calls = self.directory / "calls.jsonl"
        cli = self.bin / "sentry-cli"
        cli.write_text(f"#!{sys.executable}\n" + '''
import configparser, json, os, pathlib, sys
args = sys.argv[1:]
token = os.environ.get("SENTRY_AUTH_TOKEN")
if token is None:
    config = configparser.ConfigParser()
    config.read(".sentryclirc")
    token = config.get("auth", "token", fallback="")
with open(os.environ["FIXTURE_CALLS"], "a") as stream:
    stream.write(json.dumps({"args": args, "cwd": os.getcwd(),
        "authorized": token == os.environ["FIXTURE_EXPECTED_TOKEN"],
        "url": os.environ.get("SENTRY_URL"),
        "properties": os.environ.get("SENTRY_PROPERTIES")}) + "\\n")
if token != os.environ["FIXTURE_EXPECTED_TOKEN"]:
    sys.exit(1)
if args[:2] == ["projects", "list"]:
    if os.environ.get("FIXTURE_WRONG_ORG"):
        print("Using organization other rather than manually-configured organization threading")
    print("| ID | Slug | Team | Name |")
    print("| 123 | " + os.environ.get("FIXTURE_PROJECT", "threading-macos") + " | Team | Mac |")
elif args[:2] == ["releases", "info"]:
    sys.exit(1)
elif args[:2] == ["deploys", "list"]:
    print("| production |")
''')
        cli.chmod(0o700)
        security = self.bin / "security"
        security.write_text(f"#!{sys.executable}\n" + '''
import os, sys
if sys.argv[1:7] != ["find-generic-password", "-s", "codes.threading.release.sentry",
                      "-a", "threading", "-w"]:
    sys.exit(2)
if os.environ.get("FIXTURE_KEYCHAIN_TOKEN"):
    print(os.environ["FIXTURE_KEYCHAIN_TOKEN"])
else:
    sys.exit(44)
''')
        security.chmod(0o700)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("SENTRY_", "FIXTURE_")) and key != "CI"}
        self.env.update(PATH=f"{self.bin}:{self.env['PATH']}",
                        FIXTURE_CALLS=str(self.calls), FIXTURE_EXPECTED_TOKEN="local-fixture")

    def local_config(self):
        path = self.root / ".sentryclirc"
        path.write_text("[auth]\ntoken=local-fixture\n")
        path.chmod(0o600)

    def run_script(self, *arguments):
        return subprocess.run(["bash", str(self.script), *arguments], cwd=self.directory,
                              env=self.env, capture_output=True, text=True, check=False)

    def recorded_calls(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def assert_checked(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded_calls()
        self.assertEqual([call["args"] for call in calls],
                         [["projects", "list", "--org", "threading"]])
        self.assertTrue(calls[0]["authorized"])
        self.assertEqual(Path(calls[0]["cwd"]).resolve(), self.root.resolve())
        self.assertNotIn("fixture", result.stdout + result.stderr)

    def test_local_config_wins_over_unrelated_global_credentials_from_any_directory(self):
        self.local_config()
        self.env.update(SENTRY_AUTH_TOKEN="other-fixture", SENTRY_URL="https://other.invalid",
                        SENTRY_PROPERTIES="other.properties")
        self.assert_checked(self.run_script("check"))
        self.assertIsNone(self.recorded_calls()[0]["url"])
        self.assertIsNone(self.recorded_calls()[0]["properties"])

    def test_local_config_works_without_an_environment_token(self):
        self.local_config()
        self.assert_checked(self.run_script("check"))

    def test_keychain_recovers_a_checkout_without_local_config_despite_an_ambient_token(self):
        self.env.update(FIXTURE_KEYCHAIN_TOKEN="local-fixture", SENTRY_AUTH_TOKEN="other-fixture",
                        SENTRY_URL="https://other.invalid", SENTRY_PROPERTIES="other.properties")
        self.assert_checked(self.run_script("check"))
        self.assertEqual(self.recorded_calls()[0]["url"], "https://sentry.io")
        self.assertIsNone(self.recorded_calls()[0]["properties"])

    def test_repository_config_takes_precedence_over_a_stale_keychain_item(self):
        self.local_config()
        self.env["FIXTURE_KEYCHAIN_TOKEN"] = "old-fixture"
        self.assert_checked(self.run_script("check"))

    def test_ci_uses_its_injected_token_even_if_a_local_config_exists(self):
        self.local_config()
        self.env.update(CI="true", SENTRY_AUTH_TOKEN="ci-fixture",
                        FIXTURE_EXPECTED_TOKEN="ci-fixture", FIXTURE_KEYCHAIN_TOKEN="local-fixture")
        self.assert_checked(self.run_script("check"))

    def test_environment_token_works_without_a_local_file(self):
        self.env.update(SENTRY_AUTH_TOKEN="env-fixture", FIXTURE_EXPECTED_TOKEN="env-fixture")
        self.assert_checked(self.run_script("check"))

    def test_ci_does_not_recover_credentials_from_the_local_keychain(self):
        self.env.update(CI="true", FIXTURE_KEYCHAIN_TOKEN="local-fixture")
        result = self.run_script("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_missing_credentials_fail_before_the_cli(self):
        result = self.run_script("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_mismatched_organization_still_fails_closed(self):
        self.local_config()
        self.env["FIXTURE_WRONG_ORG"] = "1"
        result = self.run_script("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bound to a different organization", result.stderr)
        self.assertEqual(len(self.recorded_calls()), 1)

    def test_missing_project_still_fails_closed(self):
        self.local_config()
        self.env["FIXTURE_PROJECT"] = "another-project"
        result = self.run_script("check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not visible", result.stderr)

    def test_prepare_uses_one_credential_and_preserves_caller_relative_artifact_paths(self):
        self.local_config()
        self.env["SENTRY_AUTH_TOKEN"] = "other-fixture"
        contents = self.directory / "Fixture.app/Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "codes.threading", "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "1.2.3"}))
        debug_files = self.directory / "symbols"
        (debug_files / "Fixture.dSYM").mkdir(parents=True)
        result = self.run_script("prepare", "--app", "Fixture.app", "--debug-files", "symbols",
                                 "--output", "receipt.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded_calls()
        self.assertEqual([call["args"][:2] for call in calls], [
            ["projects", "list"], ["releases", "info"], ["releases", "new"],
            ["debug-files", "upload"], ["releases", "set-commits"], ["releases", "finalize"]])
        self.assertTrue(all(call["authorized"] for call in calls))
        self.assertEqual(Path(calls[3]["args"][-1]).resolve(), debug_files.resolve())
        self.assertEqual((self.directory / "receipt.txt").read_text(),
                         "codes.threading@1.2.3+1.2.3\n")

    def test_deploy_uses_local_credentials_and_does_not_duplicate_an_existing_deploy(self):
        self.local_config()
        self.env["SENTRY_AUTH_TOKEN"] = "other-fixture"
        (self.directory / "receipt.txt").write_text("codes.threading@1.2.3+1.2.3\n")
        result = self.run_script("deploy", "--release-file", "receipt.txt",
                                 "--environment", "production")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.recorded_calls()
        self.assertEqual([call["args"][:2] for call in calls],
                         [["projects", "list"], ["deploys", "list"]])
        self.assertTrue(all(call["authorized"] for call in calls))


if __name__ == "__main__":
    unittest.main()
