"""Exercise publication and release refusal with real Git and isolated build/download doubles."""

from __future__ import annotations

import dataclasses
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "remote_components", REPOSITORY / "scripts/check_remote_components.py"
)
gate = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = gate
SPEC.loader.exec_module(gate)

BUILD = """#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "--arch all" ]]
[[ "$MARKETING_VERSION" == 0.0.0 && "$CURRENT_PROJECT_VERSION" == 0.0.0 ]]
[[ "$THREADING_SOURCE_REVISION" == "$(git rev-parse HEAD)" ]]
echo build >> "$TEST_EVENTS"
[[ "${FAIL_BUILD:-0}" == 0 ]] || exit 1
for arch in arm64 amd64; do
  mkdir -p "build/linux/$arch"
  for binary in threading-ptyd threading-mcp-bridge; do
    printf '%s-%s-binary' "$binary" "$arch" > "build/linux/$arch/$binary"
  done
done
if [[ "${MUTATE_BUILD:-0}" == 1 ]]; then
  echo '// changed during the build' >> Targets/PTYHost/main.swift
fi
"""

GH = """#!/usr/bin/env python3
import os, pathlib, shutil, sys
args = sys.argv[1:]
store = pathlib.Path(os.environ["TEST_RELEASES"])
with open(os.environ["TEST_EVENTS"], "a") as log:
    log.write("gh " + " ".join(args) + "\\n")
if args[0] == "api":
    print(args[1].split("/")[-1])
    sys.exit(0)
tag = args[2]
release = store / tag
if args[1] == "view":
    sys.exit(0 if release.exists() else 1)
if args[1] == "create":
    if release.exists():
        sys.exit("refusing to overwrite an existing release")
    release.mkdir()
    for arg in args[3:]:
        path = pathlib.Path(arg)
        if path.is_file():
            shutil.copy2(path, release / path.name)
    sys.exit(1 if os.environ.get("INTERRUPT_AFTER_UPLOAD") == "1" else 0)
if args[1] == "download":
    asset = args[args.index("--pattern") + 1]
    output = args[args.index("--output") + 1]
    shutil.copy2(release / asset, output)
    sys.exit(0)
sys.exit("unexpected gh command")
"""

SITECUSTOMIZE = """
import os, pathlib, urllib.parse, urllib.request
def public_download(url, timeout):
    parts = urllib.parse.urlparse(url).path.split("/")
    return (pathlib.Path(os.environ["TEST_RELEASES"]) / parts[-2] / parts[-1]).open("rb")
urllib.request.urlopen = public_download
"""


class RemoteComponentsTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.root = self.directory / "repository"
        self.root.mkdir()
        self.events = self.directory / "events"
        self.store = self.directory / "releases"
        self.store.mkdir()
        self.tools = self.directory / "tools"
        self.tools.mkdir()
        (self.tools / "gh").write_text(GH)
        (self.tools / "gh").chmod(0o755)
        (self.tools / "sitecustomize.py").write_text(SITECUSTOMIZE)
        self.environment = {
            **os.environ,
            "PATH": f"{self.tools}:{os.environ['PATH']}",
            "PYTHONPATH": str(self.tools),
            "THREADING_REPO": "everlof/threading",
            "TEST_RELEASES": str(self.store),
            "TEST_EVENTS": str(self.events),
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
        for name in ("check_remote_components.py", "publish_remote_components.sh",
                     "release.sh", "release_tag_policy.sh"):
            self.write(f"scripts/{name}", (REPOSITORY / "scripts" / name).read_text())
        self.write("scripts/test-ptyd-linux.sh", BUILD).chmod(0o755)
        self.write("scripts/linux/toolchain.sh", "toolchain=v1\n")
        self.write("Targets/PTYHost/main.swift", "// daemon\n")
        self.write("Targets/PTYHost/Package.swift",
                   '.package(path: "../../Packages/Client")\n')
        self.write("Targets/MCPBridge/Package.swift", "// bridge\n")
        self.write("Targets/MCPBridge/main.swift", "// bridge\n")
        self.write("Packages/Client/Package.swift", '.package(path: "../Domain")\n')
        self.write("Packages/Client/Sources/client.swift", "// client\n")
        self.write("Packages/Domain/Package.swift", "// no dependencies\n")
        self.write("Packages/Domain/Sources/domain.swift", "// domain\n")
        self.write("Tests/shared.swift", "// shared daemon test\n")
        link = self.root / "Targets/PTYHost/Tests/Shared.swift"
        link.parent.mkdir()
        link.symlink_to("../../../Tests/shared.swift")
        self.write(".gitignore", "build/\n")
        self.write(str(gate.MANIFEST), (REPOSITORY / gate.MANIFEST).read_text().replace(
            "remote-components-fe551bcd036f", "remote-components-000000000000"
        ))
        self.git("init", "-q")
        self.commit()

    def write(self, path, source):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        return target

    def git(self, *args):
        result = subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
            cwd=self.root, env=self.environment, capture_output=True, text=True, check=True,
        )
        return result.stdout.strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def publish(self, *args, **env):
        return subprocess.run(
            ["bash", "scripts/publish_remote_components.sh", *args],
            cwd=self.root, env={**self.environment, **env}, capture_output=True, text=True,
        )

    def checked_publish(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = gate.read_manifest(self.root / gate.MANIFEST, "everlof/threading")
        self.commit()
        return manifest

    def test_publish_tests_both_architectures_and_pins_the_actual_public_bytes(self):
        manifest = self.checked_publish()
        gate.check_sources(self.root, manifest)
        for component in manifest.components:
            gate.verify_asset(component, self.store / manifest.tag / component.asset)
        events = self.events.read_text()
        self.assertEqual(events.count("\nbuild\n"), 1)
        self.assertIn("--prerelease --latest=false", events)
        self.assertIn("--target " + gate.revision(self.root, manifest.tag.removeprefix(
            "remote-components-")), events)
        self.assertTrue((self.store / manifest.tag / "RemoteHostComponentManifest.swift").is_file())

    def test_app_only_release_reuses_the_existing_components_without_build_or_upload(self):
        manifest = self.checked_publish()
        self.write("Sources/app.swift", "// unrelated app change\n")
        self.commit()
        self.events.write_text("")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reusing", result.stdout)
        self.assertEqual(self.events.read_text(), "")
        self.assertEqual(gate.read_manifest(self.root / gate.MANIFEST, "everlof/threading"), manifest)

    def test_each_dependency_recipe_and_symlinked_test_invalidates_the_pin(self):
        manifest = self.checked_publish()
        baseline = self.git("rev-parse", "HEAD")
        paths = [
            "Targets/PTYHost/main.swift", "Targets/MCPBridge/main.swift",
            "Packages/Client/Sources/client.swift", "Packages/Domain/Sources/domain.swift",
            "Packages/Domain/Sources/new.swift", "scripts/linux/toolchain.sh",
            "scripts/test-ptyd-linux.sh", "Tests/shared.swift",
        ]
        for path in paths:
            with self.subTest(path=path):
                self.write(path, "// changed\n")
                self.commit()
                with self.assertRaisesRegex(gate.ComponentError, "is stale"):
                    gate.check_sources(self.root, manifest)
                self.git("reset", "--hard", baseline)

    def test_deleted_source_and_new_transitive_dependency_invalidate_the_pin(self):
        manifest = self.checked_publish()
        (self.root / "Targets/PTYHost/main.swift").unlink()
        self.commit()
        with self.assertRaisesRegex(gate.ComponentError, "main.swift"):
            gate.check_sources(self.root, manifest)
        self.write("Packages/Domain/Package.swift", '.package(path: "../NewDependency")\n')
        self.write("Packages/NewDependency/Package.swift", "// leaf\n")
        self.write("Packages/NewDependency/Sources/value.swift", "// value\n")
        commit = self.commit()
        self.assertIn("Packages/NewDependency/Sources/value.swift", gate.input_entries(self.root, commit))
        with self.assertRaisesRegex(gate.ComponentError, "NewDependency"):
            gate.check_sources(self.root, manifest)

    def test_unknown_external_dependency_fails_closed(self):
        self.write("Packages/Domain/Package.swift", '.package(url: "https://example.invalid", from: "1.0.0")')
        commit = self.commit()
        with self.assertRaisesRegex(gate.ComponentError, "cannot inventory"):
            gate.input_entries(self.root, commit)

    def test_broken_test_symlink_fails_closed(self):
        (self.root / "Tests/shared.swift").unlink()
        commit = self.commit()
        with self.assertRaises(gate.ComponentError):
            gate.input_entries(self.root, commit)

    def test_manifest_and_head_must_still_match_the_validated_commit(self):
        self.checked_publish()
        head = self.git("rev-parse", "HEAD")
        gate.assert_committed_manifest(self.root, head)
        with (self.root / gate.MANIFEST).open("a") as stream:
            stream.write("// a concurrent edit\n")
        with self.assertRaisesRegex(gate.ComponentError, "manifest differs from HEAD"):
            gate.assert_committed_manifest(self.root, head)
        self.commit()
        with self.assertRaisesRegex(gate.ComponentError, "HEAD moved"):
            gate.assert_snapshot(self.root, head)

    def test_uncommitted_and_untracked_inputs_cannot_be_published(self):
        for path in ("Packages/Domain/Package.swift", "Packages/Client/Sources/new.swift"):
            with self.subTest(path=path):
                self.write(path, "// dirty\n")
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("commit them first", result.stderr)
        self.assertFalse(self.events.exists())

    def test_failed_tests_or_checkout_mutation_leave_the_previous_manifest_untouched(self):
        original = (self.root / gate.MANIFEST).read_bytes()
        for environment in ({"FAIL_BUILD": "1"}, {"MUTATE_BUILD": "1"}):
            with self.subTest(environment=environment):
                result = self.publish(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.root / gate.MANIFEST).read_bytes(), original)
                self.assertNotIn("gh release create", self.events.read_text())
                self.assertEqual(list(self.store.iterdir()), [])

    def test_retry_after_upload_recovers_verified_manifest_without_rebuilding(self):
        original = (self.root / gate.MANIFEST).read_bytes()
        interrupted = self.publish(INTERRUPT_AFTER_UPLOAD="1")
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertEqual((self.root / gate.MANIFEST).read_bytes(), original)
        self.events.write_text("")
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("recovered", result.stdout)
        self.assertNotIn("\nbuild\n", self.events.read_text())
        self.assertNotIn("gh release create", self.events.read_text())

    def test_reuse_refuses_missing_and_changed_public_downloads(self):
        manifest = self.checked_publish()
        path = self.store / manifest.tag / manifest.components[0].asset
        path.write_bytes(b"invalid public bytes")
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)
        path.unlink()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)

    def test_skip_build_is_available_only_for_a_dry_run(self):
        result = self.publish("--skip-build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --no-upload", result.stderr)
        self.assertFalse(self.events.exists())

    def test_dry_run_never_claims_to_have_published(self):
        result = self.publish("--no-upload")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no assets published", result.stdout)
        self.assertEqual(list(self.store.iterdir()), [])
        result = self.publish("--check")
        self.assertNotEqual(result.returncode, 0)

    def test_asset_and_binary_hashes_are_both_checked(self):
        data = gzip.compress(b"a static executable", mtime=0)
        component = gate.Component(
            "daemon", "arm64", "threading-ptyd-arm64.gz",
            hashlib.sha256(data).hexdigest(), len(data),
            hashlib.sha256(b"a static executable").hexdigest(),
        )
        path = self.directory / component.asset
        path.write_bytes(data)
        gate.verify_asset(component, path)
        for field, value, message in [
            ("asset_size", len(data) + 1, "size"),
            ("asset_hash", "0" * 64, "compressed SHA-256"),
            ("binary_hash", "0" * 64, "binary SHA-256"),
        ]:
            with self.subTest(field=field), self.assertRaisesRegex(gate.ComponentError, message):
                gate.verify_asset(dataclasses.replace(component, **{field: value}), path)
        with mock.patch.object(gate, "MAX_BINARY_BYTES", 2):
            with self.assertRaisesRegex(gate.ComponentError, "size limit"):
                gate.verify_asset(component, path)

    def test_downloads_are_public_bounded_and_checked_against_the_manifest(self):
        data = gzip.compress(b"binary", mtime=0)
        component = gate.Component("daemon", "arm64", "threading-ptyd-arm64.gz",
                                   hashlib.sha256(data).hexdigest(), len(data),
                                   hashlib.sha256(b"binary").hexdigest())
        manifest = gate.Manifest("remote-components-123456789abc",
                                 "https://github.com/everlof/threading/releases/download/", (component,))
        with mock.patch.object(gate.urllib.request, "urlopen", return_value=io.BytesIO(data)) as download:
            gate.check_downloads(manifest)
        download.assert_called_once_with(manifest.base_url + manifest.tag + "/" + component.asset,
                                         timeout=30)
        with mock.patch.object(gate.urllib.request, "urlopen", return_value=io.BytesIO(data + b"x")):
            with self.assertRaisesRegex(gate.ComponentError, "exceeds"):
                gate.check_downloads(manifest)

    def test_missing_duplicate_or_malformed_manifest_entries_are_refused(self):
        path = self.root / gate.MANIFEST
        original = path.read_text()
        for source in (
            original.replace("kind: .bridge", "kind: .daemon"),
            original.replace('architecture: .amd64', 'architecture: .arm64'),
            original.replace("assetByteCount:", "missingByteCount:"),
            original.replace("https://github.com/everlof/threading/", "https://example.invalid/"),
        ):
            with self.subTest(source=source[:80]):
                path.write_text(source)
                with self.assertRaises(gate.ComponentError):
                    gate.read_manifest(path, "everlof/threading")

    def test_each_notarized_channel_stops_before_archive_even_when_quality_checks_are_skipped(self):
        for channel in ("release", "beta", "nightly"):
            result = subprocess.run(
                ["bash", "scripts/release.sh", "--notarize", "--channel", channel],
                cwd=self.root, env={**self.environment, "THREADING_SKIP_RELEASE_CHECKS": "1"},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("remote components:", result.stderr)
            self.assertNotIn("Archiving", result.stdout)
            self.assertNotIn("Running the Mac release quality gate", result.stdout)

    def test_all_publication_paths_gate_components_before_mutation(self):
        check = 'python3 "$ROOT/scripts/check_remote_components.py"'
        driver = (REPOSITORY / "scripts/publish_local_release.sh").read_text()
        self.assertLess(driver.index(check), driver.index(
            'push_outer_ref "$HEAD_COMMIT:refs/heads/$RELEASE_BRANCH"'))
        publisher = (REPOSITORY / "scripts/publish_release.sh").read_text()
        self.assertLess(publisher.index(check), publisher.index('gh release upload "$TAG"'))
        nightly = (REPOSITORY / ".github/workflows/nightly.yml").read_text()
        self.assertLess(nightly.index("python3 scripts/check_remote_components.py"),
                        nightly.index("gh release upload nightly"))
        self.assertIn("test_remote_components.py", (REPOSITORY / "scripts/ci.sh").read_text())


if __name__ == "__main__":
    unittest.main()
