#!/usr/bin/env python3
"""Keep Linux from adding a second class for an existing Threading UI component.

The named classes are migration debt. Removing one requires shrinking this list; adding
another fails the build even when a different Linux view was removed in the same change.
"""

from pathlib import Path
import re
import sys

from check_ui_structure import executable_text


DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:")
EXPECTED_DUPLICATES: set[str] = set()
HOST_RENDER_LEAVES = {"LinuxActivityBeamHostView", "MorphingLabel", "SessionMenuSurface"}
VIEW_DECLARATION = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*NSView\b")


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
    print(f"linux-shared-views: {len(duplicates)} named duplicate classes remain")
    return 1 if added or removed or host_views != HOST_RENDER_LEAVES else 0


if __name__ == "__main__":
    raise SystemExit(main())
