"""Exercise the real beta lane without signing, uploading, or contacting services."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
require "json"
module CredentialsManager
  module AppfileConfig
    def self.try_fetch_value(key); "fixture"; end
  end
end
module UI
  def self.user_error!(message); raise message; end
end
$lanes = {}
def default_platform(*); end
def platform(*); yield; end
def desc(*); end
def lane(name, &block); $lanes[name] = block; end
load ARGV.fetch(0)
$calls = []
$checkout_reads = 0
def record(name, arguments = nil)
  $calls << {name: name, arguments: arguments}
  raise "fixture failure" if ENV["FAIL_AT"] == name
end
def testflight_checkout
  $checkout_reads += 1
  raise "dirty checkout" if ENV["DIRTY_AT"].to_i == $checkout_reads
  ENV["CHANGE_AT"].to_i == $checkout_reads ? "other-commit" : "tested-commit"
end
def sh(*arguments)
  if arguments.first == "env"
    raise "wrong Sentry destination" unless arguments[1..2] == ["SENTRY_ORG=threading", "SENTRY_PROJECT=threading-ios"]
    record("sentry:#{arguments[4]}", arguments.drop(5))
  else
    record(arguments.first == "node" ? "production" : "ci")
  end
end
def build_for_app_store
  record("build")
  {ipa: "tested.ipa", archive: "/tested.xcarchive", sentry_receipt: "/tested-receipt"}
end
def validate_app_store_build(build); record("validate", build); end
def asc_api_key; {}; end
def default_changelog; "fixture"; end
def upload_to_testflight(**arguments); record("upload", arguments); end
begin
  $lanes.fetch(:beta).call(allow_dirty: true)
rescue => error
  failure = error.message
end
puts JSON.generate(calls: $calls, failure: failure)
'''


class TestFlightReleaseTests(unittest.TestCase):
    def run_lane(self, **environment):
        env = {key: value for key, value in os.environ.items()
               if key not in {"FAIL_AT", "DIRTY_AT", "CHANGE_AT"}}
        env.update(environment)
        result = subprocess.run(
            ["ruby", "-e", HARNESS, str(ROOT / "fastlane/Fastfile")],
            capture_output=True, text=True, check=True, env=env,
        )
        return json.loads(result.stdout)

    def test_validated_archive_is_symbolicated_before_upload(self):
        result = self.run_lane()
        self.assertIsNone(result["failure"])
        calls = result["calls"]
        self.assertEqual([call["name"] for call in calls], [
            "sentry:check", "ci", "production", "build", "validate",
            "sentry:prepare", "upload", "sentry:deploy",
        ])
        self.assertEqual(calls[5]["arguments"], [
            "--app", "/tested.xcarchive/Products/Applications/ThreadingMobile.app",
            "--debug-files", "/tested.xcarchive/dSYMs", "--output", "/tested-receipt",
        ])
        self.assertEqual(calls[6]["arguments"]["ipa"], "tested.ipa")
        self.assertFalse(calls[6]["arguments"]["distribute_external"])
        self.assertEqual(calls[7]["arguments"], [
            "--release-file", "/tested-receipt", "--environment", "production",
        ])

    def test_failed_gate_prevents_upload(self):
        for gate in ["sentry:check", "ci", "production", "build", "validate", "sentry:prepare"]:
            with self.subTest(gate=gate):
                result = self.run_lane(FAIL_AT=gate)
                self.assertIsNotNone(result["failure"])
                self.assertNotIn("upload", [call["name"] for call in result["calls"]])

    def test_failed_upload_does_not_record_a_deploy(self):
        result = self.run_lane(FAIL_AT="upload")
        self.assertIsNotNone(result["failure"])
        self.assertNotIn("sentry:deploy", [call["name"] for call in result["calls"]])

    def test_dirty_or_changed_checkout_prevents_upload_even_with_old_bypass(self):
        for variable, reads in [("DIRTY_AT", range(1, 5)), ("CHANGE_AT", range(2, 5))]:
            for read in reads:
                with self.subTest(variable=variable, read=read):
                    result = self.run_lane(**{variable: str(read)})
                    self.assertIsNotNone(result["failure"])
                    self.assertNotIn("upload", [call["name"] for call in result["calls"]])


if __name__ == "__main__":
    unittest.main()
