#!/usr/bin/env python3
"""Package the portable native plugin SDK beside a Threading release."""

from pathlib import Path
import argparse
import re
import subprocess
import sys
import tempfile
import zipfile

from export_plugin_sdk import PACKAGES, export


def archive(version: str, output_directory: Path) -> Path:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) is None:
        raise ValueError("version must contain only dotted digits")
    output_directory.mkdir(parents=True, exist_ok=True)
    name = f"ThreadingPluginSDK-{version}"
    destination = output_directory / f"{name}.zip"
    with tempfile.TemporaryDirectory(prefix=".plugin-sdk-archive-", dir=output_directory) as temporary:
        staged = Path(temporary) / name
        export(staged)
        candidate = Path(temporary) / f"{name}.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(staged), str(candidate)],
                       check=True)
        with zipfile.ZipFile(candidate) as source:
            members = set(source.namelist())
            required = {f"{name}/README.md", f"{name}/LICENSE", f"{name}/SDK_VERSION.json"}
            required.update(f"{name}/{package}/Package.swift" for package in PACKAGES)
            required.update({
                f"{name}/Packages/ThreadingPluginKit/Tools/build-plugin.sh",
                f"{name}/Plugins/DeviceLogsPlugin/Sources/DeviceLogsPlugin/DeviceLogsPluginEntry.swift",
            })
            if not required.issubset(members):
                raise ValueError(f"SDK archive is missing {sorted(required - members)}")
        candidate.replace(destination)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("output_directory", type=Path)
    arguments = parser.parse_args()
    try:
        print(archive(arguments.version, arguments.output_directory.resolve()))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"plugin-sdk archive: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
