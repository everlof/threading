#!/usr/bin/env python3
"""Vendors whatever the core slice still needs, repeatedly, until it compiles or stops moving.

The interesting output is not that it succeeds — it is **how many files** it takes. "Open a
database, save a project graph, read it back" is one of the smallest useful operations Threading
performs, and the size of its transitive closure is the honest cost of delivery slice 2: a layer
is only independently compilable if the closure of a real operation is bounded.

Each round compiles, reads the unresolved type names out of the errors, finds where the repository
declares them, copies those files in verbatim, and goes again. It stops when the build is clean,
when a round adds nothing, or at the round limit — and reports which of those happened, because
"stopped adding files while still broken" is a different finding from "compiled".

    ./close.py [--max-rounds N]
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = (HERE / "../..").resolve()
DESTINATION = HERE / "Sources" / "CoreSlice"
MANIFEST = HERE / "coreslice.list"

MISSING = re.compile(r"cannot find type '([A-Za-z_][A-Za-z0-9_]*)' in scope")
MISSING_VALUE = re.compile(r"cannot find '([A-Za-z_][A-Za-z0-9_]*)' in scope")
SEARCH_ROOTS = ["Sources/Threading/Models", "Sources/Threading/Core", "Packages/ThreadingDomain"]


def declaration_pattern(name: str) -> re.Pattern:
    return re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:public\s+|internal\s+|package\s+|final\s+|open\s+)*"
        r"(?:struct|enum|class|actor|protocol|typealias)\s+" + re.escape(name) + r"\b",
        re.M,
    )


def find_declaration(name: str) -> pathlib.Path | None:
    pattern = declaration_pattern(name)
    for root in SEARCH_ROOTS:
        base = REPO / root
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            if "/.build/" in str(path) or "/Tests/" in str(path):
                continue
            try:
                if pattern.search(path.read_text(encoding="utf-8", errors="replace")):
                    return path
            except OSError:
                continue
    return None


def build() -> str:
    result = subprocess.run(
        ["./coreslice.sh"], cwd=HERE, capture_output=True, text=True, timeout=1800
    )
    return result.stdout + result.stderr


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-rounds", type=int, default=12)
    arguments = parser.parse_args()

    vendored = {line.strip() for line in MANIFEST.read_text().splitlines() if line.strip()}
    unresolvable: set[str] = set()
    copied_to: dict[str, str] = {}

    for round_number in range(1, arguments.max_rounds + 1):
        output = build()
        if "error:" not in output:
            print(f"\nround {round_number}: compiles. {len(vendored)} files vendored.")
            break

        names = set(MISSING.findall(output)) | set(MISSING_VALUE.findall(output))
        names -= unresolvable
        added = []
        for name in sorted(names):
            path = find_declaration(name)
            if path is None:
                unresolvable.add(name)
                continue
            relative = str(path.relative_to(REPO))
            if relative in vendored:
                continue
            # Two files in this repository are called Identifiers.swift — one in Models, one in
            # ThreadingDomain — and copying by basename silently overwrote the first with the
            # second, which showed up much later as a missing module rather than a lost file.
            # Collisions get their parent directory prefixed instead.
            target = DESTINATION / path.name
            if target.exists() and str(target) not in copied_to:
                target = DESTINATION / f"{path.parent.name}_{path.name}"
            shutil.copy2(path, target)
            copied_to[str(target)] = relative
            vendored.add(relative)
            added.append((name, relative))

        print(f"round {round_number}: {len(names)} unresolved, +{len(added)} files "
              f"({len(vendored)} total)")
        for name, relative in added:
            print(f"    {name:34s} {relative}")

        if not added:
            print(f"\nround {round_number}: stalled — nothing left to vendor, still failing.")
            if unresolvable:
                print("  no declaration found in the repository for:")
                for name in sorted(unresolvable)[:30]:
                    print(f"    {name}")
            errors = sorted(set(
                line.strip() for line in output.splitlines()
                if "error:" in line and "cannot find" not in line
            ))
            if errors:
                print("  other errors:")
                for line in errors[:15]:
                    print(f"    {line[:150]}")
            break
    else:
        print(f"\nhit the round limit with {len(vendored)} files vendored.")

    MANIFEST.write_text("\n".join(sorted(vendored)) + "\n")
    print(f"\nmanifest: {MANIFEST.relative_to(HERE)} ({len(vendored)} files)")


if __name__ == "__main__":
    main()
