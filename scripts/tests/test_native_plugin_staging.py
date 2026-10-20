import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from native_plugin_staging import prune, stage


class NativePluginStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.app_plugins = root / "Threading.app/Contents/PlugIns"
        self.staged_plugins = root / "native-plugin-input"
        self.app_plugins.mkdir(parents=True)

    def add_bundle(self, name: str):
        bundle = self.app_plugins / name
        (bundle / "Contents").mkdir(parents=True)
        (bundle / "Contents/Info.plist").write_bytes(name.encode())

    def test_stage_replaces_stale_copies_and_prunes_every_exported_bundle(self):
        self.add_bundle("DeviceLogsPlugin.bundle")
        self.add_bundle("DevicesPlugin.bundle")
        self.add_bundle("T3NavigatorPlugin.bundle")
        (self.app_plugins / "ThreadingTests.xctest").mkdir()
        (self.staged_plugins / "RemovedPlugin.bundle").mkdir(parents=True)

        stage(self.app_plugins, self.staged_plugins)
        self.assertEqual(
            sorted(path.name for path in self.staged_plugins.iterdir()),
            ["DeviceLogsPlugin.bundle", "DevicesPlugin.bundle", "T3NavigatorPlugin.bundle"],
        )
        for plugin in self.app_plugins.glob("*.bundle"):
            self.assertEqual(
                (self.staged_plugins / plugin.name / "Contents/Info.plist").read_bytes(),
                (plugin / "Contents/Info.plist").read_bytes(),
            )

        prune(self.app_plugins, self.staged_plugins)
        self.assertEqual(list(self.app_plugins.glob("*.bundle")), [])
        self.assertTrue((self.app_plugins / "ThreadingTests.xctest").is_dir())

    def test_prune_refuses_a_bundle_added_after_stage(self):
        self.add_bundle("DeviceLogsPlugin.bundle")
        stage(self.app_plugins, self.staged_plugins)
        self.add_bundle("DevicesPlugin.bundle")

        with self.assertRaisesRegex(ValueError, "changed after staging"):
            prune(self.app_plugins, self.staged_plugins)
        self.assertEqual(len(list(self.app_plugins.glob("*.bundle"))), 2)

    def test_stage_refuses_symlinked_bundle(self):
        self.add_bundle("DeviceLogsPlugin.bundle")
        (self.app_plugins / "LinkedPlugin.bundle").symlink_to(
            self.app_plugins / "DeviceLogsPlugin.bundle", target_is_directory=True
        )
        with self.assertRaisesRegex(ValueError, "regular native plugin bundles"):
            stage(self.app_plugins, self.staged_plugins)


if __name__ == "__main__":
    unittest.main()
