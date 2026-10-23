#!/usr/bin/env python3
"""The native plugin SDK must build from a checkout-free source snapshot."""

from pathlib import Path
import json
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
EXPORTER = ROOT / "scripts/export_plugin_sdk.py"
sys.path.insert(0, str(ROOT / "scripts"))
from export_plugin_sdk import copy_source  # noqa: E402
from verify_plugin_sdk_archive import verify  # noqa: E402


class PluginSDKExportTests(unittest.TestCase):
    def test_snapshot_materializes_shared_sources_and_keeps_local_dependencies_inside(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            destination = Path(temporary).resolve() / "sdk"
            subprocess.run([sys.executable, str(EXPORTER), str(destination)], check=True,
                           capture_output=True, text=True)

            self.assertFalse(any(path.is_symlink() for path in destination.rglob("*")))
            self.assertFalse(any(path.name == ".build" for path in destination.rglob("*")))
            shared = "Packages/ThreadingDesignKit/Sources/ThreadingDesignKit/Shared/AppThemeStyles+Tiger.swift"
            self.assertEqual((destination / shared).read_bytes(), (ROOT / shared).read_bytes())

            manifest = json.loads((destination / "SDK_VERSION.json").read_text())
            self.assertEqual(manifest["pluginAPIVersion"], 6)
            self.assertIn("Plugins/DeviceLogsPlugin", manifest["packages"])
            self.assertTrue((destination / "LICENSE").is_file())
            self.assertIn("PluginKit API v6", (destination / "README.md").read_text())

            for package in manifest["packages"]:
                for swift_manifest in (destination / package).rglob("Package.swift"):
                    for relative in re.findall(r'\.package\(path:\s*"([^"]+)"',
                                               swift_manifest.read_text()):
                        dependency = (swift_manifest.parent / relative).resolve()
                        self.assertTrue(dependency.is_relative_to(destination),
                                        f"{swift_manifest}: {relative} escapes the SDK")
                        self.assertTrue(dependency.is_dir(), f"missing {dependency}")

    def test_existing_output_is_left_alone(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            destination = Path(temporary) / "sdk"
            destination.mkdir()
            sentinel = destination / "keep"
            sentinel.write_text("original")
            result = subprocess.run([sys.executable, str(EXPORTER), str(destination)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "original")

    def test_symlinked_directory_cannot_copy_outside_checkout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            directory = Path(temporary)
            source = directory / "source"
            outside = directory / "outside"
            source.mkdir()
            outside.mkdir()
            (source / "linked").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                copy_source(source, directory / "copy")

    def test_release_archive_and_every_publisher_carry_the_sdk(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            result = subprocess.run([
                sys.executable, str(ROOT / "scripts/archive_plugin_sdk.py"), "0.0.0", temporary,
            ], capture_output=True, text=True, check=True)
            archive = Path(result.stdout.strip())
            with zipfile.ZipFile(archive) as source:
                self.assertIn("ThreadingPluginSDK-0.0.0/SDK_VERSION.json", source.namelist())
                recipe = source.read(
                    "ThreadingPluginSDK-0.0.0/Packages/ThreadingPluginKit/Tools/build-plugin.sh"
                )
                self.assertIn(b"--timestamp", recipe)
                self.assertIn(
                    "ThreadingPluginSDK-0.0.0/Plugins/DeviceLogsPlugin/Sources/DeviceLogsPlugin/DeviceLogsPluginEntry.swift",
                    source.namelist(),
                )
            revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                               text=True).strip()
            self.assertEqual(verify(archive, "0.0.0", revision, require_clean=False)["sourceRevision"],
                             revision)
            with self.assertRaisesRegex(ValueError, "source revision differs"):
                verify(archive, "0.0.0", "wrong-revision", require_clean=False)
            altered_directory = Path(temporary) / "altered"
            altered_directory.mkdir()
            altered = altered_directory / archive.name
            with zipfile.ZipFile(archive) as original, zipfile.ZipFile(altered, "w") as destination:
                for member in original.infolist():
                    contents = original.read(member)
                    if member.filename == "ThreadingPluginSDK-0.0.0/README.md":
                        contents += b"\nchanged after publication\n"
                    destination.writestr(member, contents)
            with self.assertRaisesRegex(ValueError, "SDK source differs from checkout: README.md"):
                verify(altered, "0.0.0", revision, require_clean=False)

        release = (ROOT / "scripts/release.sh").read_text()
        stable = (ROOT / "scripts/publish_release.sh").read_text()
        nightly = (ROOT / ".github/workflows/nightly.yml").read_text()
        self.assertIn("scripts/archive_plugin_sdk.py", release)
        self.assertIn('"$PLUGIN_SDK" "${PLUGIN_ARCHIVES[@]}"', stable)
        self.assertIn('"$plugin_sdk" \\', nightly)
        self.assertIn('ThreadingPluginSDK-$THREADING_VERSION.zip', nightly)

    def test_download_verifier_rejects_archive_path_escape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            archive = Path(temporary) / "ThreadingPluginSDK-0.0.0.zip"
            with zipfile.ZipFile(archive, "w") as destination:
                destination.writestr("../escape", "untrusted")
            with self.assertRaisesRegex(ValueError, "unsafe SDK zip member"):
                verify(archive, "0.0.0", "revision", require_clean=False)

    def test_download_verifier_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-test-") as temporary:
            archive = Path(temporary) / "ThreadingPluginSDK-0.0.0.zip"
            link = zipfile.ZipInfo("ThreadingPluginSDK-0.0.0/linked")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as destination:
                destination.writestr(link, "../escape")
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                verify(archive, "0.0.0", "revision", require_clean=False)


if __name__ == "__main__":
    unittest.main()
