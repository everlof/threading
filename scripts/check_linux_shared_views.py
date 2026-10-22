#!/usr/bin/env python3
"""Keep Linux from rebuilding shared UI classes or laying out menu rows again.

No platform-only shared-source view leaves remain; adding one fails the build.
"""

from __future__ import annotations

import re
import sys
from bisect import bisect_right
from pathlib import Path

from check_ui_structure import executable_text


DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
EXPECTED_DUPLICATES: set[str] = set()
HOST_RENDER_LEAVES = {"LinuxActivityBeamHostView", "MorphingLabel"}
PLATFORM_VIEW_LEAVES: set[str] = set()
CLASS_BASE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)")
VIEW_BASES = {
    "NSView", "NSStackView", "NSScrollView", "NSClipView", "NSTableView",
    "NSTableRowView", "NSTableCellView", "NSOutlineView", "NSControl", "NSButton",
    "NSTextField", "NSTextView", "NSImageView", "ThemedControl", "ThemedScrollView",
}
MENU_ROW_FRAME = re.compile(r"\b(?:row|separator)\.frame\s*=")
MENU_PLACEMENT_FRAME = re.compile(
    r"\b(?:configurationMenu|speedMenu|choiceSurface|sessionMenuFrame|"
    r"actionMenuFrame|accountMenuFrame)(?:\.frame)?\s*=\s*NSRect\s*\("
)
MENU_HOST_FILES = (
    "WorkspaceConversationPane.swift",
    "WorkspacePlaceholderPane.swift",
    "WorkspacePaneChrome.swift",
    "WindowHarness.swift",
)


def classes(in_directory: Path, *, skip_links: bool = False, recursive: bool = False) -> dict[str, Path]:
    result = {}
    paths = in_directory.rglob("*.swift") if recursive else in_directory.glob("*.swift")
    for path in sorted(paths):
        if skip_links and path.is_symlink():
            continue
        for name in DECLARATION.findall(executable_text(path.read_text(encoding="utf-8"))):
            result[name] = path
    return result


def linux_only_view_classes(in_directory: Path) -> dict[str, Path]:
    """Find view types declared in Linux branches of otherwise shared UI sources."""
    result = {}
    for path in sorted(in_directory.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        if "os(Linux)" not in source:
            continue
        code = executable_text(source)
        branches: list[bool | None] = []
        linux_lines = []
        line_starts = []
        offset = 0
        for line in code.splitlines(keepends=True):
            line_starts.append(offset)
            offset += len(line)
            directive = line.strip()
            if directive.startswith("#if ") or directive.startswith("#elseif "):
                expression = directive.split(maxsplit=1)[1].replace(" ", "")
                linux_branch = expression == "os(Linux)"
                mac_branch = expression == "!os(Linux)"
                branch = linux_branch if linux_branch or mac_branch else None
                if directive.startswith("#if "):
                    branches.append(branch)
                elif branches:
                    branches[-1] = branch
            elif directive == "#else" and branches:
                if branches[-1] is not None:
                    branches[-1] = not branches[-1]
            elif directive == "#endif" and branches:
                branches.pop()
            linux_lines.append(True in branches)
        for match in CLASS_BASE.finditer(code):
            line_index = bisect_right(line_starts, match.start()) - 1
            if linux_lines[line_index] and match.group(2) in VIEW_BASES:
                result[match.group(1)] = path
    return result


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    mac = classes(root / "Sources/Threading/UI", recursive=True)
    linux_directory = root / "Platforms/Linux/Sources/WindowHarness"
    linux = classes(linux_directory, skip_links=True)
    duplicates = mac.keys() & linux.keys()
    added = duplicates - EXPECTED_DUPLICATES
    removed = EXPECTED_DUPLICATES - duplicates
    for name in sorted(added):
        print(f"linux-shared-views: {name} duplicates {mac[name]} in {linux[name]}", file=sys.stderr)
    for name in sorted(removed):
        print(f"linux-shared-views: {name} is shared; remove it from the debt list", file=sys.stderr)
    host_views = {
        name
        for path in linux_directory.glob("*.swift") if not path.is_symlink()
        for name, base in CLASS_BASE.findall(executable_text(path.read_text(encoding="utf-8")))
        if base in VIEW_BASES
    }
    for name in sorted(host_views - HOST_RENDER_LEAVES):
        print(f"linux-shared-views: new Linux view {name} needs a shared UI review", file=sys.stderr)
    for name in sorted(HOST_RENDER_LEAVES - host_views):
        print(f"linux-shared-views: {name} was removed; update the host leaf list", file=sys.stderr)
    platform_views = linux_only_view_classes(root / "Sources/Threading/UI")
    new_platform_views = platform_views.keys() - PLATFORM_VIEW_LEAVES
    removed_platform_views = PLATFORM_VIEW_LEAVES - platform_views.keys()
    for name in sorted(new_platform_views):
        print(f"linux-shared-views: new Linux-only view {name} in {platform_views[name]}; "
              "extend the AppKit shim or review it as a platform leaf", file=sys.stderr)
    for name in sorted(removed_platform_views):
        print(f"linux-shared-views: {name} is shared; remove it from the leaf list", file=sys.stderr)
    shared_view_subclasses = []
    for path in linux_directory.glob("*.swift"):
        if path.is_symlink():
            continue
        for name, base in CLASS_BASE.findall(executable_text(path.read_text(encoding="utf-8"))):
            if base in mac and base.endswith("View"):
                shared_view_subclasses.append((name, base, path))
                print(f"linux-shared-views: {name} subclasses shared {base} in {path}; "
                      "mount the shared view directly", file=sys.stderr)
    frame_assignments = []
    for name in MENU_HOST_FILES:
        path = linux_directory / name
        source = executable_text(path.read_text(encoding="utf-8"))
        for match in MENU_ROW_FRAME.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            frame_assignments.append((path, line))
            print(f"linux-shared-views: menu row frame in {path}:{line}; use the shared document",
                  file=sys.stderr)
        for match in MENU_PLACEMENT_FRAME.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            frame_assignments.append((path, line))
            print(f"linux-shared-views: menu panel frame in {path}:{line}; "
                  "use ThemedMenuLayout", file=sys.stderr)
    print(f"linux-shared-views: {len(duplicates)} named duplicate classes, "
          f"{len(platform_views)} Linux-only shared-source view leaves remain")
    return 1 if (added or removed or host_views != HOST_RENDER_LEAVES
                 or new_platform_views or removed_platform_views
                 or shared_view_subclasses or frame_assignments) else 0


if __name__ == "__main__":
    raise SystemExit(main())
