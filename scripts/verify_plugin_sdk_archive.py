#!/usr/bin/env python3
"""Check a downloaded SDK zip before its source is built and loaded into Threading."""

from pathlib import Path, PurePosixPath
import argparse
import json
import re
import stat
import subprocess
import sys
import tempfile
import zipfile

from export_plugin_sdk import export


ROOT = Path(__file__).resolve().parent.parent
MAX_UNCOMPRESSED_BYTES = 200_000_000


def plugin_api_version() -> int:
    source = ROOT / "Packages/ThreadingPluginKit/Sources/ThreadingPluginKit/ThreadingNativePlugin.swift"
    match = re.search(r"public static let version = (\d+)", source.read_text())
    if match is None:
        raise ValueError("could not read this checkout's PluginKit API generation")
    return int(match.group(1))


def verify(archive: Path, version: str, revision: str, require_clean: bool = True) -> dict:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) is None:
        raise ValueError("version must contain only dotted digits")
    name = f"ThreadingPluginSDK-{version}"
    if archive.name != f"{name}.zip":
        raise ValueError(f"expected {name}.zip")

    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        members = [entry.filename for entry in entries]
        if len(members) != len(set(members)):
            raise ValueError("SDK zip contains duplicate members")
        if sum(entry.file_size for entry in entries) > MAX_UNCOMPRESSED_BYTES:
            raise ValueError("SDK zip exceeds the source-size limit")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                    or not path.parts or path.parts[0] != name):
                raise ValueError(f"unsafe SDK zip member: {entry.filename}")
            if stat.S_IFMT(entry.external_attr >> 16) == stat.S_IFLNK:
                raise ValueError(f"SDK zip contains a symlink: {entry.filename}")
        required = {
            f"{name}/SDK_VERSION.json",
            f"{name}/Packages/ThreadingPluginKit/Tools/build-plugin.sh",
            f"{name}/Plugins/DeviceLogsPlugin/Package.swift",
        }
        if not required.issubset(members):
            raise ValueError(f"SDK zip is missing {sorted(required - set(members))}")
        corrupt = source.testzip()
        if corrupt is not None:
            raise ValueError(f"corrupt SDK zip member: {corrupt}")
        manifest = json.loads(source.read(f"{name}/SDK_VERSION.json"))

    if not isinstance(manifest, dict):
        raise ValueError("SDK_VERSION.json is not an object")
    if manifest.get("pluginAPIVersion") != plugin_api_version():
        raise ValueError("SDK PluginKit API generation differs from this checkout")
    if manifest.get("sourceRevision") != revision:
        raise ValueError("SDK source revision differs from this checkout")
    if require_clean and manifest.get("hasUncommittedChanges") is not False:
        raise ValueError("SDK source was exported from an uncommitted worktree")

    # The manifest is self-reported. Compare every source byte with a fresh export of this
    # checkout so a stale or replaced release asset cannot claim the right revision.
    with tempfile.TemporaryDirectory(prefix="threading-plugin-sdk-verify-") as temporary:
        expected = Path(temporary) / name
        export(expected)
        expected_files = {
            path.relative_to(expected).as_posix(): path
            for path in expected.rglob("*") if path.is_file()
        }
        with zipfile.ZipFile(archive) as source:
            archive_files = {
                entry.filename[len(name) + 1:]: entry
                for entry in source.infolist() if not entry.is_dir()
            }
            if set(archive_files) != set(expected_files):
                missing = sorted(set(expected_files) - set(archive_files))
                extra = sorted(set(archive_files) - set(expected_files))
                raise ValueError(f"SDK source members differ from checkout: missing={missing[:5]}, extra={extra[:5]}")
            for relative, entry in archive_files.items():
                if source.read(entry) != expected_files[relative].read_bytes():
                    raise ValueError(f"SDK source differs from checkout: {relative}")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("version")
    arguments = parser.parse_args()
    try:
        revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
        verify(arguments.archive, arguments.version, revision)
    except (OSError, ValueError, json.JSONDecodeError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"plugin SDK verification: {error}", file=sys.stderr)
        return 1
    print(f"verified {arguments.archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
