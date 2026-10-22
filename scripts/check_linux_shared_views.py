#!/usr/bin/env python3
"""Keep Linux from rebuilding shared UI classes or laying out menu rows again.

The named classes are migration debt. Removing one requires shrinking this list; adding
another fails the build even when a different Linux view was removed in the same change.
"""

from pathlib import Path
import re
import sys

from check_ui_structure import executable_text


DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
EXPECTED_DUPLICATES: set[str] = set()
HOST_RENDER_LEAVES = {"LinuxActivityBeamHostView", "MorphingLabel"}
VIEW_DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*NSView\b")
CLASS_BASE = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)")
MENU_ROW_FRAME = re.compile(r"\b(?:row|separator)\.frame\s*=")
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
        for name in VIEW_DECLARATION.findall(executable_text(path.read_text(encoding="utf-8")))
    }
    for name in sorted(host_views - HOST_RENDER_LEAVES):
        print(f"linux-shared-views: new Linux NSView {name} needs a shared UI review", file=sys.stderr)
    for name in sorted(HOST_RENDER_LEAVES - host_views):
        print(f"linux-shared-views: {name} was removed; update the host leaf list", file=sys.stderr)
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
    print(f"linux-shared-views: {len(duplicates)} named duplicate classes remain")
    return 1 if (added or removed or host_views != HOST_RENDER_LEAVES
                 or shared_view_subclasses or frame_assignments) else 0


if __name__ == "__main__":
    raise SystemExit(main())
