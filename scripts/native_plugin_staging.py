#!/usr/bin/env python3
"""Stage the exported native bundles, then remove exactly those bundles from the app.

The export's bundle set is the source of truth. Staging clears an earlier release's copies,
and pruning refuses a changed set instead of accidentally shipping a newly added plugin.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path


MAXIMUM_PLUGINS = 32


def bundles(directory: Path) -> list[Path]:
    found = sorted(directory.glob("*.bundle")) if directory.is_dir() else []
    if not 1 <= len(found) <= MAXIMUM_PLUGINS or any(
        not path.is_dir() or path.is_symlink() for path in found
    ):
        raise ValueError("expected 1–32 regular native plugin bundles")
    return found


def stage(app_plugins: Path, destination: Path) -> None:
    exported = bundles(app_plugins)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for plugin in exported:
        subprocess.run(
            ("ditto", str(plugin), str(destination / plugin.name)), check=True
        )
    if [path.name for path in bundles(destination)] != [
        path.name for path in exported
    ]:
        raise ValueError("the staged native plugin set differs from the export")


def prune(app_plugins: Path, staged_plugins: Path) -> None:
    staged = bundles(staged_plugins)
    exported = bundles(app_plugins)
    if [path.name for path in exported] != [path.name for path in staged]:
        raise ValueError("the exported native plugin set changed after staging")
    for plugin in exported:
        shutil.rmtree(plugin)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("stage", "prune"))
    parser.add_argument("app_plugins", type=Path)
    parser.add_argument("staged_plugins", type=Path)
    args = parser.parse_args()
    if args.action == "stage":
        stage(args.app_plugins, args.staged_plugins)
    else:
        prune(args.app_plugins, args.staged_plugins)


if __name__ == "__main__":
    main()
