#!/usr/bin/env python3
"""Every file under Sources/ThreadingMobile belongs to the iPhone app and to nothing else.

`Sources/` is one Xcode 16 synchronized folder, which is what makes adding a file to the Mac app
free — and what silently adds an iPhone file to it too. The Mac target's
`membershipExceptions` is the only thing keeping the two apart, and it is maintained by hand, so
the failure is always the same: somebody writes a new `Mobile…View.swift`, forgets the list, and
the Mac target compiles it.

It fails in two ways and only one of them is loud.

  * **Loud.** The file uses something that exists on iOS alone and the Mac build stops.
    `MobileThemeCacheStore.swift` did this: `MobileDiagnostics` lives in a file that *is*
    excepted, so the Mac target compiled a call to a symbol it could not see. The branch tip did
    not build.
  * **Quiet, and worse.** The file happens to compile on macOS, so nothing says anything and it
    ships. Six Swift files were in the Mac binary this way. The asset catalogue was too: 58
    iPhone app icons in `Assets.car`, plus a second definition of the only two images the Mac
    actually reads. `TerminalFixtures/marketing-*-tui.json` — recorded iPhone marketing screens —
    were sitting in `Threading.app/Contents/Resources`.

A test cannot see any of this: membership is a property of the project file, and the symptom is
either a build that already failed or a bundle nobody inspects. So it is a build lint, and it
runs from the same phase as its siblings.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MOBILE_SOURCES = Path("Sources/ThreadingMobile")
PROJECT_FILE = Path("Threading.xcodeproj/project.pbxproj")

# The Mac target's exception set. Named by the entry that can only be its own: the Mac app's
# Info.plist. Matching on that rather than on an object id keeps this working across the
# renumbering Xcode does whenever the project is edited in the IDE.
MAC_TARGET_MARKER = "Threading/Resources/Info.plist"

EXCEPTION_BLOCK = re.compile(r"membershipExceptions = \(\n(.*?)\n\t*\);", re.DOTALL)


def exception_sets(project: str) -> list[set[str]]:
    sets = []
    for match in EXCEPTION_BLOCK.finditer(project):
        entries = {
            line.strip().rstrip(",").strip('"')
            for line in match.group(1).splitlines()
            if line.strip()
        }
        sets.append(entries)
    return sets


def mac_exceptions(project: str) -> set[str] | None:
    for entries in exception_sets(project):
        if MAC_TARGET_MARKER in entries:
            return entries
    return None


# Folders Xcode treats as one item rather than as a folder full of members. An asset catalogue
# is excepted by naming the catalogue; a plain folder is not — each file inside it is its own
# build file, and naming the folder excludes nothing. That difference is not visible in the
# project file and cost a round trip to find: `ThreadingMobile/TerminalFixtures` sat in the list
# while both recordings went on being copied into `Threading.app/Contents/Resources`.
BUNDLE_SUFFIXES = (".xcassets", ".bundle", ".lproj", ".xcdatamodeld", ".docc", ".intentdefinition")


def mobile_entries(root: Path) -> set[str]:
    """Every path the Mac target's list has to name, at the granularity Xcode accepts."""

    def walk(directory: Path, prefix: str) -> set[str]:
        found: set[str] = set()
        for child in sorted(directory.iterdir()):
            if child.name.startswith("."):
                continue
            name = f"{prefix}/{child.name}"
            if child.is_dir() and not child.name.endswith(BUNDLE_SUFFIXES):
                found |= walk(child, name)
            else:
                found.add(name)
        return found

    return walk(root / MOBILE_SOURCES, "ThreadingMobile")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

    project_path = root / PROJECT_FILE
    if not project_path.is_file():
        print(f"target-membership: {PROJECT_FILE} is missing", file=sys.stderr)
        return 1
    if not (root / MOBILE_SOURCES).is_dir():
        print(f"target-membership: {MOBILE_SOURCES} is missing", file=sys.stderr)
        return 1

    excepted = mac_exceptions(project_path.read_text())
    if excepted is None:
        print(
            "target-membership: no exception set names "
            f"{MAC_TARGET_MARKER}, so the Mac target's list could not be found",
            file=sys.stderr,
        )
        return 1

    missing = sorted(mobile_entries(root) - excepted)
    if not missing:
        return 0

    print(
        "target-membership: these belong to ThreadingMobile and are being built into the Mac"
        " app:",
        file=sys.stderr,
    )
    for entry in missing:
        print(f"    {entry}", file=sys.stderr)
    print(
        "  Add each one to membershipExceptions in the Threading target's"
        " PBXFileSystemSynchronizedBuildFileExceptionSet (the set naming"
        f" {MAC_TARGET_MARKER}). A whole directory is one entry.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
