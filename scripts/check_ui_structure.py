#!/usr/bin/env python3
"""Inventory and ratchet AppKit structure outside the macOS design adapter.

This is a source-level ceiling, not a claim that the remaining sites are portable. The report
names the files to migrate; the check keeps ordinary product work from adding more direct
view/controller ownership, constraint construction, or backend drawing in feature code.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
import re
import sys


CATEGORIES = ("controllers", "platform_views", "constraints", "drawing")
DECLARATION = re.compile(
    r"\bclass\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*<[^>{}]*>)?\s*:\s*"
    r"(?:AppKit\s*\.\s*)?(NS[A-Za-z0-9_]+)\b"
)
NATIVE_VIEW = re.compile(r"NS[A-Za-z0-9_]*(?:View|Control|Button|Field|Scroller)$")
CONSTRAINT = re.compile(
    r"\bNSLayoutConstraint\s*(?:\.\s*(?:activate|constraints)\s*\(|\()"
    r"|\.\s*constraint\s*\("
)
DRAWING = re.compile(
    r"\boverride\s+func\s+draw\s*\(|\b(?:NSBezierPath|NSGraphicsContext|CGContext)\b"
)


def executable_text(source: str) -> str:
    """Blank comments and strings, preserving newlines for useful source locations.

    Swift's raw and multiline strings contain examples of the exact APIs this checker finds.
    Nested block comments are legal Swift, so a single regex substitution is not sufficient.
    """
    result = list(source)
    index = 0

    def blank(start: int, end: int) -> None:
        for offset in range(start, end):
            if result[offset] != "\n":
                result[offset] = " "

    while index < len(source):
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
            blank(start, index)
            continue
        if source.startswith("/*", index):
            index += 2
            depth = 1
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            blank(start, index)
            continue

        hashes = 0
        while index + hashes < len(source) and source[index + hashes] == "#":
            hashes += 1
        quote = index + hashes
        if quote < len(source) and source[quote] == '"':
            triple = source.startswith('"""', quote)
            delimiter = ('"""' if triple else '"') + ("#" * hashes)
            index = quote + (3 if triple else 1)
            while index < len(source):
                if source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                if hashes == 0 and source[index] == "\\":
                    index += 2
                else:
                    index += 1
            blank(start, min(index, len(source)))
            continue
        index += 1
    return "".join(result)


def classify(source: str) -> Counter[str]:
    code = executable_text(source)
    controllers = 0
    views = 0
    for base in DECLARATION.findall(code):
        if base.endswith("Controller"):
            controllers += 1
        elif base in {"NSWindow", "NSPanel"} or NATIVE_VIEW.fullmatch(base):
            views += 1
    return Counter({
        "controllers": controllers,
        "platform_views": views,
        "constraints": len(CONSTRAINT.findall(code)),
        "drawing": len(DRAWING.findall(code)),
    })


def inventory(root: Path) -> tuple[Counter[str], dict[str, dict[str, int]]]:
    source_root = root / "Sources" / "Threading"
    design_root = source_root / "UI" / "Design"
    totals: Counter[str] = Counter()
    files: dict[str, dict[str, int]] = {}
    for path in sorted(source_root.rglob("*.swift")):
        if path.is_relative_to(design_root):
            continue
        counts = classify(path.read_text(encoding="utf-8"))
        if any(counts.values()):
            relative = path.relative_to(root).as_posix()
            files[relative] = {name: counts[name] for name in CATEGORIES if counts[name]}
            totals.update(counts)
    return totals, files


def violations(actual: Counter[str], baseline: dict[str, int]) -> list[str]:
    errors = []
    for category in CATEGORIES:
        old, new = baseline[category], actual[category]
        if new > old:
            errors.append(f"{category}: {new} sites exceed the {old}-site ceiling")
        elif new < old:
            errors.append(f"{category}: {new} sites remain; lower the {old}-site ceiling")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--report", action="store_true", help="list affected files and counts")
    args = parser.parse_args()
    root = args.repository.resolve()
    baseline = json.loads((root / "scripts/config/ui-structure-baseline.json").read_text())
    totals, files = inventory(root)
    for category in CATEGORIES:
        print(f"ui-structure: {category}: {totals[category]} sites in "
              f"{sum(category in counts for counts in files.values())} files")
    if args.report:
        for path, counts in files.items():
            print(f"  {path}: " + ", ".join(f"{name}={count}" for name, count in counts.items()))
    failures = violations(totals, baseline)
    for failure in failures:
        print(f"ui-structure: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
