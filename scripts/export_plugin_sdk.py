#!/usr/bin/env python3
"""Export the native plugin SDK and Device Logs as a self-contained source tree.

The in-repository DesignKit shares source with the app through symlinks. External authors cannot
clone that package alone, so this snapshot resolves those links while keeping the package layout
that DeviceLogsPlugin and the public PluginKit example build against.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PACKAGES = (
    "Packages/ThreadingPluginKit",
    "Packages/ThreadingDesignKit",
    "Packages/ThreadingDomain",
    "Packages/ThreadingRemoteKit",
    "Packages/ThreadingExtensionKit",
    "Packages/Vendor/SwiftTerm",
    "Packages/Vendor/BorderBeamKit",
    "Packages/Vendor/ThinkingOrbs",
    "Packages/Vendor/LabelMorph",
    "Packages/Vendor/TimberLineParser",
    "Plugins/DeviceLogsPlugin",
)
OMIT = {".build", ".git", ".swiftpm", "DerivedData", ".DS_Store"}


def copy_source(source: Path, destination: Path) -> None:
    def excluded(directory: str, names: list[str]) -> list[str]:
        for name in names:
            path = Path(directory) / name
            if path.is_symlink():
                resolved = path.resolve(strict=True)
                if not resolved.is_relative_to(ROOT) or not resolved.is_file():
                    raise ValueError(f"symlink escapes the checkout or is not a file: {path}")
        return [name for name in names if name in OMIT]

    shutil.copytree(
        source, destination,
        symlinks=False,
        ignore=excluded,
    )


def api_version() -> int:
    source = (ROOT / "Packages/ThreadingPluginKit/Sources/ThreadingPluginKit/ThreadingNativePlugin.swift")
    match = re.search(r"public static let version = (\d+)", source.read_text())
    if match is None:
        raise ValueError("could not read ThreadingPluginAPI.version")
    return int(match.group(1))


def checkout_revision() -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()


def checkout_is_dirty() -> bool:
    return bool(subprocess.check_output(
        ["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=normal"], text=True
    ))


def export(destination: Path) -> None:
    if any(destination == ROOT / package or destination.is_relative_to(ROOT / package)
           for package in PACKAGES):
        raise ValueError("output directory cannot be inside a copied package")
    if destination.exists():
        if any(destination.iterdir()):
            raise ValueError(f"output directory is not empty: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".threading-plugin-sdk-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "sdk"
        staged.mkdir()
        for relative in PACKAGES:
            source = ROOT / relative
            if not source.is_dir():
                raise ValueError(f"missing SDK source: {source}")
            target = staged / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            copy_source(source, target)
        shutil.copy2(ROOT / "LICENSE", staged / "LICENSE")
        version = api_version()
        revision = checkout_revision()
        dirty = checkout_is_dirty()
        (staged / "SDK_VERSION.json").write_text(json.dumps({
            "pluginAPIVersion": version,
            "sourceRevision": revision,
            "hasUncommittedChanges": dirty,
            "packages": list(PACKAGES),
        }, indent=2) + "\n")
        (staged / "README.md").write_text(f"""# Threading native plugin SDK

This source snapshot contains PluginKit API v{version}, ThreadingDesignKit, their package
dependencies, and the Device Logs plugin as a complete native example. It was exported from
Threading revision `{revision}`{' with uncommitted changes' if dirty else ''}.

Start with `Packages/ThreadingPluginKit/README.md`. From this directory, run
`swift test --package-path Plugins/DeviceLogsPlugin` to build the first-party example without
the Threading application checkout. `Packages/ThreadingPluginKit/Tools/build-plugin.sh` produces
an installable bundle for a plugin you have authored.

ThreadingPluginKit is the host's dynamic binary contract. Device Logs statically links its own
ThreadingDesignKit and parser, so an externally built plugin does not depend on the host's private
Swift ABI. The host still checks the plugin's declared API generation and requires explicit
approval of each third-party native build. See the included GPL-3.0 `LICENSE`; vendored libraries
retain their own license files.
""")
        for path in staged.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"unresolved SDK symlink: {path}")
        if destination.exists():
            destination.rmdir()
        staged.replace(destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="empty directory for the portable SDK snapshot")
    arguments = parser.parse_args()
    try:
        export(arguments.output.resolve())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"plugin-sdk export: {error}", file=sys.stderr)
        return 1
    print(arguments.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
