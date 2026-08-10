#!/usr/bin/env python3
"""Fail when an app test source is not compiled by the ThreadingTests target.

`Tests/ThreadingTests` is an ordinary Xcode group rather than a synchronized folder. A Swift
file can therefore sit beside the rest of the suite while every test command silently ignores
it. Keep the filesystem and the test target's explicit Sources phase in lockstep.
"""

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TEST_DIRECTORY = ROOT / "Tests" / "ThreadingTests"
PROJECT = ROOT / "Threading.xcodeproj" / "project.pbxproj"
SOURCES_PHASE = "2B94BD9027B7FD53BB982AFA"


def main() -> None:
    project = PROJECT.read_text()
    match = re.search(
        rf"{SOURCES_PHASE} /\* Sources \*/ = \{{.*?files = \(\n(.*?)\t+\);",
        project,
        re.DOTALL,
    )
    if not match:
        sys.exit(f"error: could not find ThreadingTests Sources phase {SOURCES_PHASE}")

    phase = match.group(1)
    files = sorted(path.name for path in TEST_DIRECTORY.glob("*.swift"))
    missing = [name for name in files if f"/* {name} in Sources */" not in phase]

    # Parse every source entry, not only entries that already look like Swift. The latter made a
    # typo such as `--help` invisible here while Xcode still treated it as a required build input.
    registered = set(re.findall(r"/\* ([^/\n]+) in Sources \*/", phase))
    stale = sorted(registered.difference(files))

    if missing or stale:
        if missing:
            print("error: test files absent from the ThreadingTests Sources phase:", file=sys.stderr)
            for name in missing:
                print(f"  {name}", file=sys.stderr)
            print(
                "Register them with scripts/add_test_file.py; unregistered tests execute zero cases.",
                file=sys.stderr,
            )
        if stale:
            print("error: ThreadingTests Sources entries have no test file:", file=sys.stderr)
            for name in stale:
                print(f"  {name}", file=sys.stderr)
        raise SystemExit(1)

    print(f"Test registration OK ({len(files)} Swift files)")


if __name__ == "__main__":
    main()
