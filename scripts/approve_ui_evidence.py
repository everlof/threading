#!/usr/bin/env python3
"""Apply explicitly approved UI evidence decisions to the checked-in baseline directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
REPORT_KIND = "threading-ui-evidence-report"
DECISIONS_KIND = "threading-ui-evidence-decisions"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_object(path: Path, expected_kind: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read {path}: {error}") from error
    if (
        not isinstance(payload, dict)
        or payload.get("schemaVersion") != SCHEMA_VERSION
        or payload.get("kind") != expected_kind
    ):
        raise ValueError(f"unsupported {expected_kind} document: {path}")
    return payload


def safe_relative(value: Any, context: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context}: baselineRelative must be non-empty text")
    result = Path(value)
    if result.is_absolute() or not result.parts or ".." in result.parts:
        raise ValueError(f"{context}: unsafe baseline path {value!r}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--decisions", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Refuse a decisions file that omits any changed, new, or unbaselined artifact.",
    )
    arguments = parser.parse_args()

    try:
        report_root = arguments.report.expanduser().resolve()
        if report_root.is_file():
            report_root = report_root.parent
        report = load_object(report_root / "evidence.json", REPORT_KIND)
        decisions = load_object(arguments.decisions.expanduser().resolve(), DECISIONS_KIND)
        supplied_baseline_root = arguments.baseline.expanduser()
        if (
            not supplied_baseline_root.exists()
            or not supplied_baseline_root.is_dir()
            or supplied_baseline_root.is_symlink()
        ):
            raise ValueError(
                "baseline root must be an existing, non-symlink directory: "
                f"{supplied_baseline_root}"
            )
        baseline_root = supplied_baseline_root.resolve()
        if report.get("platform") != decisions.get("platform"):
            raise ValueError("decision platform does not match the evidence report")
        if report.get("reportID") != decisions.get("reportID"):
            raise ValueError("decisions belong to a different evidence run")

        artifacts: dict[str, dict[str, Any]] = {}
        for entry in report.get("entries", []):
            if not isinstance(entry, dict):
                raise ValueError("report entry is not an object")
            for artifact in entry.get("artifacts", []):
                if not isinstance(artifact, dict) or not isinstance(artifact.get("id"), str):
                    raise ValueError("report artifact is malformed")
                identifier = artifact["id"]
                if identifier in artifacts:
                    raise ValueError(f"duplicate report artifact {identifier!r}")
                artifacts[identifier] = artifact

        raw_decisions = decisions.get("decisions")
        if not isinstance(raw_decisions, list):
            raise ValueError("decisions must be a list")
        reviewed: set[str] = set()
        approved: list[tuple[Path, Path]] = []
        for index, decision in enumerate(raw_decisions):
            context = f"decision {index + 1}"
            if not isinstance(decision, dict):
                raise ValueError(f"{context} is not an object")
            identifier = decision.get("artifactID")
            if not isinstance(identifier, str) or identifier not in artifacts:
                raise ValueError(f"{context}: unknown artifact {identifier!r}")
            if identifier in reviewed:
                raise ValueError(f"{context}: duplicate artifact decision {identifier!r}")
            reviewed.add(identifier)
            verdict = decision.get("decision")
            if verdict not in {"approve", "investigate", "reject"}:
                raise ValueError(f"{context}: unsupported decision {verdict!r}")
            artifact = artifacts[identifier]
            relative = safe_relative(artifact.get("baselineRelative"), context)
            if decision.get("baselineRelative") != relative.as_posix():
                raise ValueError(f"{context}: baseline target does not match the report")
            expected_hash = artifact.get("currentSHA256")
            if decision.get("currentSHA256") != expected_hash:
                raise ValueError(f"{context}: current image hash does not match the report")
            if verdict != "approve":
                continue
            current_asset = safe_relative(artifact.get("current"), context)
            current = report_root / current_asset
            if not current.resolve().is_relative_to(report_root):
                raise ValueError(f"{context}: current asset escapes the report root")
            if not current.is_file() or current.is_symlink():
                raise ValueError(f"{context}: current report asset is missing: {current}")
            if sha256(current) != expected_hash:
                raise ValueError(f"{context}: current report asset changed after review")
            destination = baseline_root / relative
            if not destination.resolve().is_relative_to(baseline_root):
                raise ValueError(f"{context}: baseline target escapes the baseline root")
            if destination.exists() and (not destination.is_file() or destination.is_symlink()):
                raise ValueError(f"{context}: baseline target is not a regular file")
            approved.append((current, destination))

        actionable = {
            identifier
            for identifier, artifact in artifacts.items()
            if artifact.get("comparison") != "accepted"
        }
        missing = sorted(actionable - reviewed)
        if arguments.require_complete and missing:
            raise ValueError(
                f"decisions omit {len(missing)} actionable artifact(s): {', '.join(missing[:8])}"
            )
        for source, destination in approved:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        print(f"Approved {len(approved)} baseline image(s) in {baseline_root}")
        nonapproved = len(reviewed) - len(approved)
        if nonapproved:
            print(f"Left {nonapproved} investigated/rejected image(s) unchanged")
        return 0
    except (OSError, ValueError) as error:
        print(f"error: could not approve UI evidence: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
