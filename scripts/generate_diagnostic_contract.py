#!/usr/bin/env python3
"""Generate the native and Worker projections of the diagnostic wire contract."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
import textwrap
from pathlib import Path
from typing import Any


EVENT_SOURCES = {"iOSClient", "browserClient"}
REPORT_SOURCES = {"iOSClient", "macOSHost"}
FIELD_VALIDATIONS = {
    "token",
    "unsignedInteger",
    "peerPseudonym",
    "sessionPseudonym",
    "originDigest",
}
SWIFT_IDENTIFIER = re.compile(r"^[a-z][A-Za-z0-9]*$")


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_contract(path: Path) -> dict[str, Any]:
    contract = json.loads(path.read_text(encoding="utf-8"))
    if set(contract) != {"schemaVersion", "events", "fields", "extraFields"}:
        raise ValueError("contract root must contain only schemaVersion, events, fields, extraFields")
    if contract["schemaVersion"] != 1:
        raise ValueError("unsupported diagnostic contract schemaVersion")
    validate_entries(contract["events"], "events", {"name", "clientUploadSources", "description"})
    validate_entries(contract["fields"], "fields", {"name", "validation", "description"})
    validate_entries(contract["extraFields"], "extraFields", {"name", "reportSources", "description"})
    for event in contract["events"]:
        validate_sources(event, "clientUploadSources", EVENT_SOURCES)
    for field in contract["fields"]:
        if field["validation"] not in FIELD_VALIDATIONS:
            raise ValueError(f"unknown validation for {field['name']}: {field['validation']}")
    for field in contract["extraFields"]:
        validate_sources(field, "reportSources", REPORT_SOURCES)
        if not field["reportSources"]:
            raise ValueError(f"extra field {field['name']} must allow at least one report source")
    return contract


def validate_entries(entries: Any, name: str, allowed_keys: set[str]) -> None:
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"{name} must be a non-empty array")
    seen: set[str] = set()
    required = allowed_keys - {"description"}
    for entry in entries:
        if not isinstance(entry, dict) or not required.issubset(entry) or not set(entry).issubset(allowed_keys):
            raise ValueError(f"invalid {name} entry: {entry!r}")
        identifier = entry["name"]
        if not isinstance(identifier, str) or not SWIFT_IDENTIFIER.fullmatch(identifier):
            raise ValueError(f"{name} name is not a Swift/wire identifier: {identifier!r}")
        if identifier in seen:
            raise ValueError(f"duplicate {name} name: {identifier}")
        seen.add(identifier)
        if "description" in entry and (
            not isinstance(entry["description"], str) or not entry["description"].strip()
        ):
            raise ValueError(f"invalid description for {identifier}")


def validate_sources(entry: dict[str, Any], key: str, allowed: set[str]) -> None:
    sources = entry[key]
    if not isinstance(sources, list) or len(sources) != len(set(sources)):
        raise ValueError(f"{entry['name']}.{key} must be a unique array")
    unknown = set(sources) - allowed
    if unknown:
        raise ValueError(f"{entry['name']}.{key} contains unknown sources: {sorted(unknown)}")


def fingerprint(contract: dict[str, Any]) -> str:
    # Fingerprints describe wire behavior, not manifest prose or presentation order. Keeping
    # descriptions and array ordering out also prevents a documentation-only regeneration from
    # making reports look as though they crossed a behavioral contract revision.
    semantic_contract = {
        "schemaVersion": contract["schemaVersion"],
        "events": sorted(
            (
                {
                    "name": entry["name"],
                    "clientUploadSources": sorted(entry["clientUploadSources"]),
                }
                for entry in contract["events"]
            ),
            key=lambda entry: entry["name"],
        ),
        "fields": sorted(
            (
                {"name": entry["name"], "validation": entry["validation"]}
                for entry in contract["fields"]
            ),
            key=lambda entry: entry["name"],
        ),
        "extraFields": sorted(
            (
                {
                    "name": entry["name"],
                    "reportSources": sorted(entry["reportSources"]),
                }
                for entry in contract["extraFields"]
            ),
            key=lambda entry: entry["name"],
        ),
    }
    canonical = json.dumps(
        semantic_contract,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def swift_docs(description: str | None, indent: str = "    ") -> list[str]:
    if not description:
        return []
    return [f"{indent}/// {line}" for line in textwrap.wrap(description, width=92)]


def swift_cases(entries: list[dict[str, Any]]) -> list[str]:
    lines: list[str] = []
    for entry in entries:
        lines.extend(swift_docs(entry.get("description")))
        lines.append(f"    case {entry['name']}")
    return lines


def swift_set(name: str, entries: list[dict[str, Any]]) -> list[str]:
    cases = [f".{entry['name']}" for entry in entries]
    lines = [f"    private static let {name}: Set<Self> = ["]
    current = "        "
    for case in cases:
        addition = case + ", "
        if len(current) + len(addition) > 96:
            lines.append(current.rstrip())
            current = "        "
        current += addition
    if current.strip():
        lines.append(current.rstrip(" ,"))
    lines.append("    ]")
    return lines


def render_swift(contract: dict[str, Any], digest: str) -> str:
    events = contract["events"]
    fields = contract["fields"]
    extras = contract["extraFields"]
    ios_events = [entry for entry in events if "iOSClient" in entry["clientUploadSources"]]
    browser_events = [entry for entry in events if "browserClient" in entry["clientUploadSources"]]
    ios_extras = [entry for entry in extras if "iOSClient" in entry["reportSources"]]
    mac_extras = [entry for entry in extras if "macOSHost" in entry["reportSources"]]

    lines = [
        "// Generated by scripts/generate_diagnostic_contract.py. DO NOT EDIT.",
        "// Edit Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json instead.",
        "",
        "import Foundation",
        "",
        "/// The content-free event vocabulary accepted by native diagnostics and the public intake.",
        "public enum RemoteDiagnosticEvent: String, Codable, CaseIterable, Hashable, Sendable {",
        *swift_cases(events),
        "",
        *swift_set("iOSClientUploadEvents", ios_events),
        "",
        *swift_set("browserClientUploadEvents", browser_events),
        "",
        "    public func allowsClientUpload(from source: RemoteDiagnosticSource) -> Bool {",
        "        switch source {",
        "        case .iOSClient: Self.iOSClientUploadEvents.contains(self)",
        "        case .browserClient: Self.browserClientUploadEvents.contains(self)",
        "        case .macOSHost: false",
        "        }",
        "    }",
        "}",
        "",
        "public enum RemoteDiagnosticFieldValidation: String, Codable, Hashable, Sendable {",
        *[f"    case {value}" for value in sorted(FIELD_VALIDATIONS)],
        "}",
        "",
        "/// Safe structural field names. Their value policy is generated from the same contract.",
        "public enum RemoteDiagnosticField: String, CaseIterable, Hashable, Sendable {",
        *swift_cases(fields),
        "",
        "    public var validation: RemoteDiagnosticFieldValidation {",
        "        switch self {",
    ]
    for validation in sorted(FIELD_VALIDATIONS):
        matching = [entry for entry in fields if entry["validation"] == validation]
        joined = ", ".join(f".{entry['name']}" for entry in matching)
        lines.append(f"        case {joined}: .{validation}")
    lines.extend([
        "        }",
        "    }",
        "}",
        "",
        "/// Optional, explicitly consented report context with generated platform scope.",
        "public enum RemoteDiagnosticExtraField: String, CaseIterable, Hashable, Sendable {",
        *swift_cases(extras),
        "",
        *swift_set("iOSClientReportFields", ios_extras),
        "",
        *swift_set("macOSHostReportFields", mac_extras),
        "",
        "    public func allowsReportSource(_ source: RemoteDiagnosticSource) -> Bool {",
        "        switch source {",
        "        case .iOSClient: Self.iOSClientReportFields.contains(self)",
        "        case .macOSHost: Self.macOSHostReportFields.contains(self)",
        "        case .browserClient: false",
        "        }",
        "    }",
        "}",
        "",
        "public enum RemoteDiagnosticContract {",
        f"    public static let schemaVersion = {contract['schemaVersion']}",
        f"    public static let fingerprint = \"{digest}\"",
        "}",
        "",
    ])
    return "\n".join(lines)


def typescript_array(entries: list[dict[str, Any]], indent: str = "  ") -> list[str]:
    return [f'{indent}"{entry["name"]}",' for entry in entries]


def render_typescript(contract: dict[str, Any], digest: str) -> str:
    events = contract["events"]
    fields = contract["fields"]
    extras = contract["extraFields"]
    ios_events = [entry for entry in events if "iOSClient" in entry["clientUploadSources"]]
    browser_events = [
        entry for entry in events if "browserClient" in entry["clientUploadSources"]
    ]
    ios_extras = [entry for entry in extras if "iOSClient" in entry["reportSources"]]
    mac_extras = [entry for entry in extras if "macOSHost" in entry["reportSources"]]
    lines = [
        "// Generated by scripts/generate_diagnostic_contract.py. DO NOT EDIT.",
        "// Edit Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json instead.",
        "",
        "export type DiagnosticFieldValidation =",
        *[
            f'  | "{value}"'
            for value in sorted(FIELD_VALIDATIONS)
        ],
        "",
        f"export const diagnosticContractSchemaVersion = {contract['schemaVersion']} as const;",
        f'export const diagnosticContractFingerprint = "{digest}";',
        "",
        "export const diagnosticEvents = new Set<string>([",
        *typescript_array(events),
        "]);",
        "",
        "const iOSClientDiagnosticEvents = new Set<string>([",
        *typescript_array(ios_events),
        "]);",
        "",
        "const browserClientDiagnosticEvents = new Set<string>([",
        *typescript_array(browser_events),
        "]);",
        "",
        "export const diagnosticEventsByRecordSource = new Map<string, ReadonlySet<string>>([",
        '  ["iOSClient", iOSClientDiagnosticEvents],',
        '  ["browserClient", browserClientDiagnosticEvents],',
        '  ["macOSHost", diagnosticEvents],',
        "]);",
        "",
        "export const diagnosticFieldValidation = new Map<string, DiagnosticFieldValidation>([",
        *[
            f'  ["{entry["name"]}", "{entry["validation"]}"],'
            for entry in fields
        ],
        "]);",
        "",
        "const iOSClientAdditionalDetailFields = new Set<string>([",
        *typescript_array(ios_extras),
        "]);",
        "",
        "const macOSHostAdditionalDetailFields = new Set<string>([",
        *typescript_array(mac_extras),
        "]);",
        "",
        "export const additionalDetailFieldsByReportSource = new Map<string, ReadonlySet<string>>([",
        '  ["iOSClient", iOSClientAdditionalDetailFields],',
        '  ["macOSHost", macOSHostAdditionalDetailFields],',
        "]);",
        "",
    ]
    return "\n".join(lines)


def compare(path: Path, expected: str) -> bool:
    actual = path.read_text(encoding="utf-8") if path.exists() else ""
    if actual == expected:
        return True
    print(f"diagnostic-contract: generated file is stale: {path}", file=sys.stderr)
    for line in difflib.unified_diff(
        actual.splitlines(), expected.splitlines(), fromfile=str(path), tofile="generated"
    ):
        print(line, file=sys.stderr)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail when generated files are stale")
    parser.add_argument("--root", type=Path, default=repository_root())
    args = parser.parse_args()
    root = args.root.resolve()
    contract_path = root / "Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json"
    swift_path = root / (
        "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteDiagnosticContract.generated.swift"
    )
    typescript_path = root / (
        "Service/ThreadingControlPlane/src/issue-report-contract.generated.ts"
    )

    try:
        contract = read_contract(contract_path)
        digest = fingerprint(contract)
        outputs = {
            swift_path: render_swift(contract, digest),
            typescript_path: render_typescript(contract, digest),
        }
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"diagnostic-contract: {error}", file=sys.stderr)
        return 1

    if args.check:
        return 0 if all(compare(path, output) for path, output in outputs.items()) else 1
    for path, output in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output, encoding="utf-8")
        print(path.relative_to(root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
