#!/usr/bin/env python3
"""Finds types that are Foundation-only but live in a file that is not.

Swift's unit for imports is the **file**. One AppKit-bearing declaration makes the whole file
AppKit-bearing for everyone who needs anything else in it — and `check_module_boundaries.py`
cannot see that, because it enforces direction between *modules* while most of Threading is still
one app target. Inside that target, file co-location is the real granularity, and nothing checks
it.

The core slice ran into this three times in a row:

  * `TerminalThemeID`, a Foundation-only string wrapper, sits in `Models/TerminalTheme.swift`
    beside the theme's colours and its `asSwiftTermColors()` bridge — so persisting a project
    reaches AppKit *and* SwiftTerm.
  * `AppSettingsDidChange` sits in a 31-line `SettingsEvents.swift` whose last four lines declare
    `ProfileDidChange`, carrying an AppKit-bearing `TerminalProfile`.
  * `LimitRecoveryPolicy`, persisted on `Project`, is co-located with the code that posts those
    settings notifications.

Each was a few lines in the wrong file, and each one alone was enough to stop a headless build.
This counts how many more there are, so slice 2 can be planned as a list of splits rather than
discovered one compile error at a time.

Heuristic, and stated as one: a declaration is a *candidate* when its own source text mentions no
symbol from the file's non-Foundation imports. It cannot see through a typealias or an extension
in another file, so treat the output as a worklist to confirm, never as a patch to apply.

    ./split-candidates.py [repo-root]
"""
import pathlib
import re
import sys
from collections import Counter

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
LAYERS = ["Sources/Threading/Models", "Sources/Threading/Core", "Sources/Threading/Application"]

# Importing any of these is what makes a file unportable.
HEAVY = {
    "AppKit": ("NS", "CA", "CG"),
    "SwiftTerm": ("Terminal", "Color", "TerminalView", "LocalProcess"),
    "AVFoundation": ("AV",),
    "CoreImage": ("CI",),
    "ImageIO": ("CG", "kCG"),
    "PDFKit": ("PDF",),
    "UserNotifications": ("UN",),
    "Security": ("Sec", "kSec", "errSec"),
    "IOKit": ("IO", "kIO"),
    "ServiceManagement": ("SM",),
    "Sparkle": ("SU", "SPU"),
    "MetricKit": ("MX",),
    "CoreGraphics": ("CG", "kCG"),
    "CoreText": ("CT", "kCT"),
}

IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
TOP_LEVEL = re.compile(
    r"^(?:public |internal |package |final |open |@\w+(?:\([^)]*\))?\s*)*"
    r"(struct|enum|class|actor|protocol|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)


def declarations(text: str):
    """Top-level declarations and their source ranges, by brace counting from column zero."""
    lines = text.split("\n")
    found = []
    index = 0
    while index < len(lines):
        match = TOP_LEVEL.match(lines[index])
        if not match:
            index += 1
            continue
        start = index
        depth = lines[index].count("{") - lines[index].count("}")
        index += 1
        while index < len(lines) and depth > 0:
            depth += lines[index].count("{") - lines[index].count("}")
            index += 1
        found.append((match.group(1), match.group(2), start + 1, index, "\n".join(lines[start:index])))
    return found


def main() -> None:
    candidates = []
    poisoned_files = 0
    by_framework = Counter()

    for layer in LAYERS:
        base = ROOT / layer
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="replace")
            imports = set(IMPORT.findall(text))
            heavy = imports & HEAVY.keys()
            if not heavy:
                continue
            poisoned_files += 1
            prefixes = tuple(prefix for name in heavy for prefix in HEAVY[name])
            symbol = re.compile(r"\b(?:" + "|".join(sorted(set(prefixes), key=len, reverse=True)) + r")[A-Z][A-Za-z0-9_]*")

            clean = []
            for kind, name, first, last, body in declarations(text):
                if kind == "extension":
                    continue
                if symbol.search(body):
                    continue
                if any(framework in body for framework in heavy):
                    continue
                clean.append((kind, name, first, last))

            if clean:
                candidates.append((path.relative_to(ROOT), sorted(heavy), clean))
                for framework in heavy:
                    by_framework[framework] += 1

    total_types = sum(len(clean) for _, _, clean in candidates)
    print(f"{poisoned_files} files import a framework with no Linux story")
    print(f"{len(candidates)} of them also declare types that appear to need none — {total_types} types\n")

    print("by framework, files with at least one candidate:")
    for framework, count in by_framework.most_common():
        print(f"  {count:4d}  {framework}")

    print("\nthe worklist, largest first:")
    for path, heavy, clean in sorted(candidates, key=lambda row: -len(row[2]))[:30]:
        print(f"\n  {path}  [{', '.join(heavy)}]")
        for kind, name, first, last in clean[:8]:
            print(f"      lines {first:5d}-{last:<5d} {kind} {name}")
        if len(clean) > 8:
            print(f"      … and {len(clean) - 8} more")

    print("\nHeuristic. Confirm each before moving it; see this file's header.")


if __name__ == "__main__":
    main()
