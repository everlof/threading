#!/usr/bin/env python3
"""Keep repository Swift diagnostics from growing while the Swift 6 migration proceeds."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
SWIFT_WARNING = re.compile(
    r"^(?P<path>.+?\.swift):(?P<line>[0-9]+):(?P<column>[0-9]+): "
    r"warning: (?P<message>.+)$"
)
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
SUCCESS_MARKERS = (
    "** BUILD SUCCEEDED **",
    "** TEST BUILD SUCCEEDED **",
    "** TEST SUCCEEDED **",
)
SWIFT_6_SUFFIX = "this is an error in the Swift 6 language mode"


@dataclass
class WarningCounts:
    warnings: int = 0
    swift6_language_mode: int = 0

    def add(self, message: str) -> None:
        self.warnings += 1
        if SWIFT_6_SUFFIX in message:
            self.swift6_language_mode += 1

    def as_json(self) -> Dict[str, int]:
        return {
            "warnings": self.warnings,
            "swift6LanguageMode": self.swift6_language_mode,
        }


def repository_relative(path_text: str, repository: Path) -> Optional[str]:
    path = Path(path_text)
    candidate = path if path.is_absolute() else repository / path
    try:
        return candidate.resolve().relative_to(repository.resolve()).as_posix()
    except ValueError:
        return None


def parse_logs(
    log_paths: Iterable[Path],
    repository: Path,
) -> Tuple[Dict[str, WarningCounts], bool]:
    counts: Dict[str, WarningCounts] = {}
    all_logs_succeeded = True
    for log_path in log_paths:
        # Swift batch compilation can print the same source diagnostic once for every primary
        # file in a frontend invocation. That repetition varies with batch partitioning and CPU
        # count, so it is not warning debt. Keep one exact source diagnostic per Xcode lane.
        seen_diagnostics = set()
        text = log_path.read_text(encoding="utf-8", errors="replace")
        all_logs_succeeded = all_logs_succeeded and any(
            marker in text for marker in SUCCESS_MARKERS
        )
        for raw_line in text.splitlines():
            line = ANSI_ESCAPE.sub("", raw_line).strip()
            match = SWIFT_WARNING.match(line)
            if match is None:
                continue
            relative_path = repository_relative(match.group("path"), repository)
            if relative_path is None:
                continue
            identity = (
                relative_path,
                match.group("line"),
                match.group("column"),
                match.group("message"),
            )
            if identity in seen_diagnostics:
                continue
            seen_diagnostics.add(identity)
            counts.setdefault(relative_path, WarningCounts()).add(match.group("message"))
    return counts, all_logs_succeeded


def totals(counts: Mapping[str, WarningCounts]) -> WarningCounts:
    return WarningCounts(
        warnings=sum(item.warnings for item in counts.values()),
        swift6_language_mode=sum(item.swift6_language_mode for item in counts.values()),
    )


def baseline_document(counts: Mapping[str, WarningCounts]) -> Dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "description": (
            "Per-file ceilings for Swift compiler warnings emitted by the canonical cold CI "
            "builds. Lower counts are accepted; increases require an intentional baseline update."
        ),
        "files": {
            path: counts[path].as_json()
            for path in sorted(counts)
        },
    }


def load_baseline(path: Path) -> Dict[str, WarningCounts]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("unsupported Swift warning baseline schema")
    files = document.get("files")
    if not isinstance(files, dict):
        raise ValueError("Swift warning baseline files must be an object")

    result: Dict[str, WarningCounts] = {}
    for source_path, raw_counts in files.items():
        if not isinstance(source_path, str) or not isinstance(raw_counts, dict):
            raise ValueError("Swift warning baseline entries must map paths to count objects")
        warning_count = raw_counts.get("warnings")
        swift6_count = raw_counts.get("swift6LanguageMode")
        if (
            not isinstance(warning_count, int)
            or isinstance(warning_count, bool)
            or not isinstance(swift6_count, int)
            or isinstance(swift6_count, bool)
            or swift6_count < 0
            or warning_count < swift6_count
        ):
            raise ValueError(f"invalid Swift warning counts for {source_path}")
        result[source_path] = WarningCounts(warning_count, swift6_count)
    return result


def ratchet_violations(
    observed: Mapping[str, WarningCounts],
    baseline: Mapping[str, WarningCounts],
) -> List[str]:
    violations: List[str] = []
    for source_path in sorted(observed):
        actual = observed[source_path]
        allowed = baseline.get(source_path, WarningCounts())
        if actual.warnings > allowed.warnings:
            violations.append(
                f"{source_path}: warnings grew from {allowed.warnings} to {actual.warnings}"
            )
        if actual.swift6_language_mode > allowed.swift6_language_mode:
            violations.append(
                f"{source_path}: Swift-6-mode diagnostics grew from "
                f"{allowed.swift6_language_mode} to {actual.swift6_language_mode}"
            )
    return violations


def write_baseline(path: Path, counts: Mapping[str, WarningCounts]) -> None:
    path.write_text(
        json.dumps(baseline_document(counts), indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=script_directory.parent,
        help="repository root used to normalize absolute compiler paths",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=script_directory / "swift_warning_baseline.json",
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="replace the baseline with the warnings in these successful cold-build logs",
    )
    parser.add_argument("logs", nargs="+", type=Path)
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    try:
        observed, all_logs_succeeded = parse_logs(options.logs, options.root)
        if not all_logs_succeeded:
            raise ValueError("each log must contain a successful xcodebuild completion marker")
        observed_totals = totals(observed)
        if options.write_baseline:
            write_baseline(options.baseline, observed)
            print(
                "swift-warning-ratchet: wrote "
                f"{observed_totals.warnings} warnings "
                f"({observed_totals.swift6_language_mode} Swift-6-mode)"
            )
            return 0

        baseline = load_baseline(options.baseline)
        violations = ratchet_violations(observed, baseline)
        if violations:
            for violation in violations:
                print(f"swift-warning-ratchet: {violation}", file=sys.stderr)
            print(
                "swift-warning-ratchet: fix the new diagnostics, or regenerate the baseline "
                "from a reviewed cold CI build",
                file=sys.stderr,
            )
            return 1

        baseline_totals = totals(baseline)
        print(
            "swift-warning-ratchet: clean — "
            f"{observed_totals.warnings}/{baseline_totals.warnings} warnings, "
            f"{observed_totals.swift6_language_mode}/"
            f"{baseline_totals.swift6_language_mode} Swift-6-mode"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"swift-warning-ratchet: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
