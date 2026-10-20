import base64
import hashlib
import json
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from package_native_plugins import host_identity, manifest_payload


class NativePluginManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "Threading.app"
        info = self.app / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "codes.threading",
            "CFBundleVersion": "2.3.4",
            "CFBundleExecutable": "Threading",
            "ThreadingBuildChannel": "release",
        }))
        self.executable = self.app / "Contents/MacOS/Threading"
        self.design_kit = self.app / "Contents/Frameworks/ThreadingDesignKit.framework/Versions/A/ThreadingDesignKit"
        self.plugin_kit = self.app / "Contents/Frameworks/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit"
        for path, content in (
            (self.executable, b"host build A"),
            (self.design_kit, b"design kit A"),
            (self.plugin_kit, b"plugin kit A"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

    def test_manifest_binds_every_shared_binary_to_exact_host_build(self):
        records = [{"bundleIdentifier": "codes.threading.plugin.devicelogs"}]
        payload = manifest_payload(self.app, records, "v2.3.4")
        parsed = json.loads(payload)

        self.assertEqual(parsed["schemaVersion"], 1)
        self.assertEqual(parsed["releaseTag"], "v2.3.4")
        self.assertEqual(parsed["plugins"], records)
        self.assertEqual(parsed["host"]["bundleVersion"], "2.3.4")
        self.assertEqual(
            parsed["host"]["executableSHA256"], hashlib.sha256(b"host build A").hexdigest()
        )

        for binary in (self.executable, self.design_kit, self.plugin_kit):
            original = payload
            binary.write_bytes(binary.read_bytes() + b" changed")
            self.assertNotEqual(manifest_payload(self.app, records, "v2.3.4"), original)

    def test_manifest_payload_bytes_are_deterministic(self):
        first = manifest_payload(self.app, [], "v2.3.4")
        second = manifest_payload(self.app, [], "v2.3.4")
        self.assertEqual(first, second)
        self.assertEqual(base64.b64decode(base64.b64encode(first)), first)

    def test_missing_shared_framework_refuses_manifest(self):
        self.design_kit.unlink()
        with self.assertRaisesRegex(ValueError, "shared native plugin frameworks"):
            host_identity(self.app)

    def test_release_tag_must_match_exported_channel_and_version(self):
        with self.assertRaisesRegex(ValueError, "release tag"):
            manifest_payload(self.app, [], "v2.3.5")
        with self.assertRaisesRegex(ValueError, "release tag"):
            manifest_payload(self.app, [], "nightly")


if __name__ == "__main__":
    unittest.main()
