#!/usr/bin/env python3
"""Add a test source file to the ThreadingTests target.

The app target uses an Xcode 16 synchronized folder, so anything dropped under `Sources/`
joins the build automatically. **The test target does not** — it carries an explicit file
list, and a new test file left out of it compiles nowhere, runs nowhere, and reports nothing.
That failure is silent and looks exactly like a passing suite, which is how it was found.

Usage:
    add_test_file.py ConversationTimelineTests.swift [more.swift ...]
"""

import hashlib
import re
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent / "Threading.xcodeproj" / "project.pbxproj"

# The four places a test file has to appear, discovered by diffing the file against itself
# after adding one through Xcode.
GROUP_ID = "20A00C033DC1347FA758CD10"        # unused; kept for orientation
SOURCES_PHASE = "2B94BD9027B7FD53BB982AFA"   # PBXSourcesBuildPhase of ThreadingTests
TESTS_GROUP_PATH = "path = Tests/ThreadingTests;"


def object_id(seed):
    """A stable 24-hex-character identifier, so re-running is idempotent."""
    return hashlib.sha256(seed.encode()).hexdigest()[:24].upper()


def add(text, filename):
    file_ref = object_id("ref:" + filename)
    build_file = object_id("build:" + filename)

    if filename in text:
        print(f"  {filename}: already present")
        return text

    # 1. PBXBuildFile
    text = text.replace(
        "/* End PBXBuildFile section */",
        f"\t\t{build_file} /* {filename} in Sources */ = {{isa = PBXBuildFile; "
        f"fileRef = {file_ref} /* {filename} */; }};\n"
        "/* End PBXBuildFile section */",
        1,
    )

    # 2. PBXFileReference
    text = text.replace(
        "/* End PBXFileReference section */",
        f"\t\t{file_ref} /* {filename} */ = {{isa = PBXFileReference; includeInIndex = 1; "
        f'lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = "<group>"; }};\n'
        "/* End PBXFileReference section */",
        1,
    )

    # 3. The Tests group's children, so the file is visible in Xcode's navigator.
    group = re.search(
        r"(children = \(\n)((?:\t+[0-9A-F]{24} /\* [^\n]*\n)+)(\t+\);\n\t+name = Tests;)",
        text,
    )
    if group:
        text = (
            text[: group.end(2)]
            + f"\t\t\t\t{file_ref} /* {filename} */,\n"
            + text[group.end(2) :]
        )

    # 4. The Sources build phase — the one that actually decides whether it compiles.
    phase = re.search(
        rf"{SOURCES_PHASE} /\* Sources \*/ = \{{.*?files = \(\n(.*?)\t+\);",
        text,
        re.DOTALL,
    )
    if not phase:
        sys.exit(f"Could not find the ThreadingTests sources phase ({SOURCES_PHASE})")

    text = (
        text[: phase.end(1)]
        + f"\t\t\t\t{build_file} /* {filename} in Sources */,\n"
        + text[phase.end(1) :]
    )

    print(f"  {filename}: added")
    return text


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    text = PROJECT.read_text()
    for filename in sys.argv[1:]:
        text = add(text, Path(filename).name)
    PROJECT.write_text(text)


if __name__ == "__main__":
    main()
