"""Exercise the real beta lane without signing, uploading, or contacting services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
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

SUBMISSION_HARNESS = HARNESS.split("begin\n  $lanes.fetch(:beta)")[0] + r'''
module UI
  def self.success(*); end
end
RemoteBuild = Struct.new(:id)
RemoteVersion = Struct.new(:id, :version_string, :platform, :app_store_state) do
  def get_build; RemoteBuild.new(ENV.fetch("SELECTED_BUILD", "recorded-build")); end
end
$version = RemoteVersion.new("version-id", "1.0", "IOS", ENV.fetch("STORE_STATE", "PREPARE_FOR_SUBMISSION"))
module Spaceship
  module ConnectAPI
    class App
      def self.find(*); new; end
      def get_app_store_versions; [$version]; end
    end
    class AppStoreVersion
      def self.get(**); $version; end
    end
  end
end
def read_release_receipt(*arguments)
  record("receipt-read", arguments)
  {"state" => ENV.fetch("RECEIPT_STATE", "uploaded"), "build" => {"version" => "1.0", "number" => 3}}
end
def wait_for_release_build(build)
  record("exact-build", build)
  RemoteBuild.new("recorded-build")
end
def deliver(**arguments)
  record("submit", arguments)
  $version.app_store_state = ENV.fetch("AFTER_STATE", "WAITING_FOR_REVIEW")
end
def write_release_receipt(path, receipt); record("receipt-write", receipt); end
begin
  $lanes.fetch(:submit_review).call(receipt: "/fixture/receipt.json")
rescue => error
  failure = error.message
end
puts JSON.generate(calls: $calls, failure: failure)
'''

RECEIPT_HARNESS = HARNESS.split("begin\n  $lanes.fetch(:beta)")[0] + r'''
module UI
  def self.message(*); end
end
def build_for_app_store
  record("build")
  {ipa: ARGV.fetch(2), archive: "/tested.xcarchive", sentry_receipt: "/tested-receipt",
   version: "1.0", number: 3}
end
def uploaded_release_build(build)
  record("lookup", build)
  ENV["REMOTE_EXISTS"] == "1"
end
def wait_for_release_build(build); record("processing", build); end
begin
  $lanes.fetch(:beta).call(receipt: ARGV.fetch(1))
rescue => error
  failure = error.message
end
puts JSON.generate(calls: $calls, failure: failure)
'''

SCREENSHOT_HARNESS = HARNESS.split("begin\n  $lanes.fetch(:beta)")[0] + r'''
module UI
  def self.message(*); end
end
Object.send(:remove_const, :MARKETEER_EXPORT_DIRECTORY)
MARKETEER_EXPORT_DIRECTORY = ARGV.fetch(1)
def marketeer_cli; "/fixture/marketeer"; end
def sh(*arguments)
  record("render", arguments)
  output = arguments[arguments.index("--out") + 1]
  FileUtils.mkdir_p(output)
  count = ENV["EMPTY_RENDER"] == "1" ? 0 : 20
  count.times { |index| File.write(File.join(output, "#{index}.png"), "fixture") }
end
def deliver(**arguments); record("upload", arguments); end
begin
  $lanes.fetch(:upload_screenshots).call(apply: ENV["APPLY"] == "1")
rescue => error
  failure = error.message
end
puts JSON.generate(calls: $calls, failure: failure)
'''


class ScreenshotReleaseTests(unittest.TestCase):
    def run_screenshots(self, **environment):
        env = {key: value for key, value in os.environ.items()
               if key not in {"FAIL_AT", "APPLY", "EMPTY_RENDER"}}
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["ruby", "-e", SCREENSHOT_HARNESS, str(ROOT / "fastlane/Fastfile"),
                 str(Path(directory) / "screenshots")],
                capture_output=True, text=True, check=True, env=dict(env, **environment),
            )
        return json.loads(result.stdout)

    def test_dry_run_renders_every_required_size_without_upload(self):
        result = self.run_screenshots()
        self.assertIsNone(result["failure"])
        self.assertEqual([call["name"] for call in result["calls"]], ["render"])
        arguments = result["calls"][0]["arguments"]
        self.assertEqual(arguments[1], "export")
        self.assertEqual(arguments[arguments.index("--sizes") + 1], "6.9,6.5,6.3,6.1")
        self.assertEqual(Path(arguments[arguments.index("--out") + 1]).name, "en-US")

    def test_upload_uses_rendered_pixels_and_waits_for_processing(self):
        result = self.run_screenshots(APPLY="1")
        self.assertIsNone(result["failure"])
        self.assertEqual([call["name"] for call in result["calls"]], ["render", "upload"])
        render, upload = [call["arguments"] for call in result["calls"]]
        self.assertEqual(Path(upload["screenshots_path"]) / "en-US",
                         Path(render[render.index("--out") + 1]))
        self.assertTrue(upload["overwrite_screenshots"])
        self.assertGreater(upload["screenshot_processing_timeout"], 0)
        self.assertTrue(upload["skip_binary_upload"])
        self.assertTrue(upload["skip_metadata"])
        self.assertFalse(upload["submit_for_review"])

    def test_render_and_upload_failures_stop_the_lane(self):
        for stage in ["render", "upload"]:
            with self.subTest(stage=stage):
                result = self.run_screenshots(APPLY="1", FAIL_AT=stage)
                self.assertIsNotNone(result["failure"])
                if stage == "render":
                    self.assertNotIn("upload", [call["name"] for call in result["calls"]])

    def test_empty_render_cannot_erase_remote_screenshots(self):
        result = self.run_screenshots(APPLY="1", EMPTY_RENDER="1")
        self.assertIn("rendered 0", result["failure"])
        self.assertNotIn("upload", [call["name"] for call in result["calls"]])


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
            "build", "validate", "sentry:check", "ci", "production",
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

    def test_release_archive_failures_stop_before_the_expensive_quality_gate(self):
        for stage in ["build", "validate"]:
            with self.subTest(stage=stage):
                result = self.run_lane(FAIL_AT=stage)
                self.assertIsNotNone(result["failure"])
                self.assertNotIn("ci", [call["name"] for call in result["calls"]])

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

    def test_processing_timeout_retains_upload_receipt_and_resumes_exact_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "app.ipa"
            ipa.write_bytes(b"validated archive")
            receipt = Path(directory) / "receipt.json"

            def run(**variables):
                env = {key: value for key, value in os.environ.items()
                       if key not in {"FAIL_AT", "DIRTY_AT", "CHANGE_AT", "REMOTE_EXISTS"}}
                result = subprocess.run(
                    ["ruby", "-e", RECEIPT_HARNESS, str(ROOT / "fastlane/Fastfile"),
                     str(receipt), str(ipa)], capture_output=True, text=True, check=True,
                    env=dict(env, **variables),
                )
                return json.loads(result.stdout)

            failed_quality = run(FAIL_AT="ci")
            self.assertIsNotNone(failed_quality["failure"])
            self.assertEqual(json.loads(receipt.read_text())["state"], "validated")
            self.assertNotIn("upload", [call["name"] for call in failed_quality["calls"]])

            interrupted = run(FAIL_AT="processing")
            self.assertIsNotNone(interrupted["failure"])
            self.assertNotIn("build", [call["name"] for call in interrupted["calls"]])
            self.assertIn("ci", [call["name"] for call in interrupted["calls"]])
            upload = next(call["arguments"] for call in interrupted["calls"] if call["name"] == "upload")
            self.assertTrue(upload["skip_waiting_for_build_processing"])
            self.assertEqual(json.loads(receipt.read_text())["state"], "uploaded")
            self.assertNotIn("sentry:deploy", [call["name"] for call in interrupted["calls"]])

            awaiting_visibility = run(FAIL_AT="processing", REMOTE_EXISTS="0")
            self.assertIsNotNone(awaiting_visibility["failure"])
            pending_names = [call["name"] for call in awaiting_visibility["calls"]]
            self.assertIn("processing", pending_names)
            self.assertNotIn("build", pending_names)
            self.assertNotIn("upload", pending_names)
            self.assertNotIn("sentry:deploy", pending_names)
            self.assertEqual(json.loads(receipt.read_text())["state"], "uploaded")

            resumed = run(REMOTE_EXISTS="1")
            self.assertIsNone(resumed["failure"])
            names = [call["name"] for call in resumed["calls"]]
            self.assertNotIn("build", names)
            self.assertNotIn("upload", names)
            self.assertLess(names.index("processing"), names.index("sentry:deploy"))
            checked = next(call["arguments"] for call in resumed["calls"] if call["name"] == "processing")
            self.assertEqual((checked["version"], checked["number"], checked["ipa"]), ("1.0", 3, str(ipa)))


class AppReviewSubmissionTests(unittest.TestCase):
    def run_submission(self, **environment):
        result = subprocess.run(
            ["ruby", "-e", SUBMISSION_HARNESS, str(ROOT / "fastlane/Fastfile")],
            capture_output=True, text=True, check=True, env=dict(os.environ, **environment),
        )
        return json.loads(result.stdout)

    def test_submits_exact_build_and_confirms_state_with_manual_release(self):
        result = self.run_submission()
        self.assertIsNone(result["failure"])
        submit = next(call["arguments"] for call in result["calls"] if call["name"] == "submit")
        self.assertEqual(submit["build_number"], "3")
        self.assertEqual(submit["app_version"], "1.0")
        self.assertTrue(submit["skip_binary_upload"])
        self.assertTrue(submit["submit_for_review"])
        self.assertFalse(submit["automatic_release"])
        self.assertEqual(result["calls"][-1]["arguments"]["app_store_state"], "WAITING_FOR_REVIEW")

    def test_unconfirmed_upload_and_different_selected_build_refuse(self):
        for env in [{"RECEIPT_STATE": "validated"},
                    {"STORE_STATE": "IN_REVIEW", "SELECTED_BUILD": "someone-elses-build"},
                    {"CHANGE_AT": "2"}]:
            with self.subTest(env=env):
                result = self.run_submission(**env)
                self.assertIsNotNone(result["failure"])
                self.assertNotIn("submit", [call["name"] for call in result["calls"]])

    def test_already_submitted_exact_build_is_idempotent(self):
        result = self.run_submission(STORE_STATE="IN_REVIEW")
        self.assertIsNone(result["failure"])
        self.assertNotIn("submit", [call["name"] for call in result["calls"]])

    def test_submission_error_or_unconfirmed_remote_state_has_no_success_receipt(self):
        for env in [{"FAIL_AT": "submit"}, {"AFTER_STATE": "READY_FOR_REVIEW"}]:
            with self.subTest(env=env):
                result = self.run_submission(**env)
                self.assertIsNotNone(result["failure"])
                self.assertNotIn("receipt-write", [call["name"] for call in result["calls"]])

    def test_real_receipt_reader_rejects_changed_ipa_and_revision(self):
        harness = HARNESS.split("$calls = []")[0] + r'''
begin
  value = read_release_receipt(ARGV.fetch(1), ARGV.fetch(2))
rescue => error
  failure = error.message
end
puts JSON.generate(failure: failure)
'''
        with tempfile.TemporaryDirectory() as directory:
            import hashlib
            ipa = Path(directory) / "app.ipa"
            ipa.write_bytes(b"validated archive")
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(json.dumps({"revision": "tested", "build": {"ipa": str(ipa)},
                                           "ipa_sha256": hashlib.sha256(ipa.read_bytes()).hexdigest()}))
            def read(revision):
                output = subprocess.run(["ruby", "-e", harness, str(ROOT / "fastlane/Fastfile"),
                                         str(receipt), revision], capture_output=True, text=True, check=True)
                return json.loads(output.stdout)["failure"]
            self.assertIsNone(read("tested"))
            self.assertIn("another commit", read("different"))
            ipa.write_bytes(b"replaced archive")
            self.assertIn("missing or changed", read("tested"))


if __name__ == "__main__":
    unittest.main()
