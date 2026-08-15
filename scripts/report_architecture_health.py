#!/usr/bin/env python3
"""Report the small set of structural metrics used by the architecture health ledger."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


UI_FRAMEWORKS = {
    "AppKit",
    "BorderBeamKit",
    "LabelMorph",
    "SwiftTerm",
    "SwiftUI",
    "ThinkingOrbs",
    "WebKit",
}


def swift_files(directory: Path) -> list[Path]:
    return sorted(directory.rglob("*.swift"))


def line_count(paths: list[Path]) -> int:
    return sum(len(path.read_text(encoding="utf-8").splitlines()) for path in paths)


def matching_files(paths: list[Path], pattern: re.Pattern[str]) -> tuple[int, int]:
    occurrences = 0
    files = 0
    for path in paths:
        matches = pattern.findall(path.read_text(encoding="utf-8"))
        if matches:
            occurrences += len(matches)
            files += 1
    return occurrences, files


def controller_dependencies(core_files: list[Path], ui_files: list[Path]) -> tuple[int, int]:
    declaration = re.compile(
        r"\b(?:final\s+)?class\s+"
        r"([A-Z][A-Za-z0-9]*(?:ViewController|WindowController|Controller))\b"
    )
    names: set[str] = set()
    for path in ui_files:
        names.update(declaration.findall(path.read_text(encoding="utf-8")))
    if not names:
        return 0, 0

    use = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(names))) + r")\b")
    occurrences = 0
    files = 0
    for path in core_files:
        path_occurrences = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            # This is a dependency inventory, not a Swift parser. Discard ordinary line comments
            # so architectural notes do not look like executable edges.
            code = line.split("//", 1)[0]
            path_occurrences += len(use.findall(code))
        if path_occurrences:
            occurrences += path_occurrences
            files += 1
    return occurrences, files


def ui_framework_imports(paths: list[Path]) -> tuple[int, int]:
    import_pattern = re.compile(r"^import\s+([A-Za-z][A-Za-z0-9_]*)\s*$", re.MULTILINE)
    occurrences = 0
    files = 0
    for path in paths:
        imports = import_pattern.findall(path.read_text(encoding="utf-8"))
        matching = sum(module in UI_FRAMEWORKS for module in imports)
        if matching:
            occurrences += matching
            files += 1
    return occurrences, files


def authority_files(paths: list[Path], type_name: str) -> list[Path]:
    declaration = re.compile(rf"\b(?:class|extension)\s+{re.escape(type_name)}\b")
    return [
        path
        for path in paths
        if declaration.search(path.read_text(encoding="utf-8"))
    ]


def render(root: Path) -> str:
    source_root = root / "Sources" / "Threading"
    domain_root = root / "Packages" / "ThreadingDomain" / "Sources" / "ThreadingDomain"
    source_files = swift_files(source_root)
    domain_files = swift_files(domain_root)
    core_files = swift_files(source_root / "Core")
    model_files = swift_files(source_root / "Models")
    ui_files = swift_files(source_root / "UI")
    test_files = swift_files(root / "Tests" / "ThreadingTests")

    shared_count, shared_files = matching_files(
        source_files,
        re.compile(r"\bstatic\s+(?:let|var)\s+shared\b"),
    )
    project_store_count, project_store_files = matching_files(
        source_files,
        re.compile(r"\bProjectStore\.shared\b"),
    )
    app_delegate_count, app_delegate_files = matching_files(
        core_files,
        re.compile(r"\bAppDelegate\.shared\b"),
    )
    controller_count, controller_files = controller_dependencies(core_files, ui_files)
    framework_count, framework_files = ui_framework_imports(core_files + model_files)
    main_window_files = authority_files(source_files, "MainWindowController")
    tool_coordinator_files = authority_files(source_files, "AgentToolCoordinator")
    tool_extension_files = sorted(
        (source_root / "UI" / "Windows").glob("AgentToolCoordinator+*.swift")
    )

    rows = [
        ("Threading Swift files", len(source_files), "files"),
        ("Threading Swift lines", line_count(source_files), "lines"),
        ("ThreadingDomain Swift files", len(domain_files), "Foundation-only files"),
        ("ThreadingDomain Swift lines", line_count(domain_files), "compiler-isolated lines"),
        ("Shared declarations", shared_count, f"across {shared_files} files"),
        (
            "ProjectStore.shared references",
            project_store_count,
            f"across {project_store_files} files",
        ),
        (
            "Core AppDelegate.shared references",
            app_delegate_count,
            f"across {app_delegate_files} files",
        ),
        (
            "Core concrete-controller references",
            controller_count,
            f"across {controller_files} files",
        ),
        (
            "Core/Models UI-framework imports",
            framework_count,
            f"across {framework_files} files",
        ),
        (
            "MainWindowController authority",
            line_count(main_window_files),
            f"across {len(main_window_files)} files",
        ),
        (
            "AgentToolCoordinator authority",
            line_count(tool_coordinator_files),
            f"across {len(tool_coordinator_files)} files",
        ),
        (
            "AgentToolCoordinator capability extensions",
            line_count(tool_extension_files),
            f"across {len(tool_extension_files)} files",
        ),
        ("ThreadingTests Swift files", len(test_files), "manually registered"),
    ]

    width = max(len(label) for label, _, _ in rows)
    return "\n".join(
        f"{label:<{width}}  {value:>8,}  {detail}" for label, value, detail in rows
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "repository",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    arguments = parser.parse_args()
    print(render(arguments.repository.resolve()))


if __name__ == "__main__":
    main()
