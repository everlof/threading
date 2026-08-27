#!/usr/bin/env python3
"""Inspect Threading's share-safe mobile connectivity journal.

The hardware runner copies the iOS app's diagnostics directory after each fault.  This helper
keeps the evidence check independent from `devicectl`'s presentation output: a checkpoint only
passes when a new, structurally matching journal record exists.
"""

from __future__ import annotations

import argparse
import json
import stat
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Sequence


EMPTY_MARKER = "1970-01-01T00:00:00.000Z"
MAXIMUM_JOURNAL_FILES = 8
MAXIMUM_JOURNAL_BYTES = 8 * 1_024 * 1_024
MAXIMUM_RECORD_BYTES = 64 * 1_024


class JournalError(RuntimeError):
    """The copied journal is absent or structurally invalid."""


@dataclass(frozen=True)
class Record:
    timestamp: str
    event: str
    source: str
    level: str
    fields: dict[str, str]

    @classmethod
    def decode(cls, value: object, location: str) -> "Record":
        if not isinstance(value, dict):
            raise JournalError(f"{location}: record is not a JSON object")

        timestamp = value.get("timestamp")
        event = value.get("event")
        source = value.get("source")
        level = value.get("level")
        fields = value.get("fields")
        if not all(isinstance(item, str) for item in (timestamp, event, source, level)):
            raise JournalError(f"{location}: record metadata is missing or not text")
        if not isinstance(fields, dict) or not all(
            isinstance(key, str) and isinstance(field_value, str)
            for key, field_value in fields.items()
        ):
            raise JournalError(f"{location}: fields must be a string-to-string object")
        try:
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        except ValueError as error:
            raise JournalError(f"{location}: invalid timestamp {timestamp!r}") from error
        return cls(timestamp, event, source, level, fields)

    def json_value(self) -> dict[str, object]:
        return {
            "timestamp": self.timestamp,
            "source": self.source,
            "level": self.level,
            "event": self.event,
            "fields": self.fields,
        }


def load_records(directory: Path) -> list[Record]:
    if not directory.is_dir():
        raise JournalError(f"journal directory does not exist: {directory}")

    paths = sorted(directory.glob("remote-diagnostics-????-??-??.jsonl"))
    if not paths:
        raise JournalError(f"no remote diagnostics journals found below {directory}")
    if len(paths) > MAXIMUM_JOURNAL_FILES:
        raise JournalError(
            f"found {len(paths)} journals; refusing to read more than {MAXIMUM_JOURNAL_FILES}"
        )

    records: list[Record] = []
    for path in paths:
        try:
            metadata = path.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise JournalError(f"journal is not a regular file: {path}")
            with path.open("rb") as handle:
                truncated = metadata.st_size > MAXIMUM_JOURNAL_BYTES
                if truncated:
                    handle.seek(-MAXIMUM_JOURNAL_BYTES, 2)
                data = handle.read(MAXIMUM_JOURNAL_BYTES)
        except OSError as error:
            raise JournalError(f"cannot read {path}: {error}") from error
        lines = data.splitlines()
        if truncated and lines:
            lines = lines[1:]
        for line_number, encoded_line in enumerate(lines, start=1):
            if not encoded_line.strip():
                continue
            if len(encoded_line) > MAXIMUM_RECORD_BYTES:
                raise JournalError(
                    f"{path}:{line_number}: record exceeds {MAXIMUM_RECORD_BYTES} bytes"
                )
            location = f"{path}:{line_number}"
            try:
                line = encoded_line.decode("utf-8")
                value = json.loads(line)
            except UnicodeDecodeError as error:
                raise JournalError(f"{location}: record is not UTF-8") from error
            except json.JSONDecodeError as error:
                raise JournalError(f"{location}: invalid JSON: {error.msg}") from error
            records.append(Record.decode(value, location))
    return sorted(records, key=lambda record: record.timestamp)


def parse_field_constraints(values: Iterable[str]) -> dict[str, str]:
    constraints: dict[str, str] = {}
    for value in values:
        key, separator, expected = value.partition("=")
        if not separator or not key or not expected:
            raise JournalError(f"field constraint must be KEY=VALUE, got {value!r}")
        constraints[key] = expected
    return constraints


def matching_records(
    records: Iterable[Record],
    *,
    after: str,
    events: set[str],
    fields: dict[str, str],
    excluded_fields: dict[str, str],
) -> list[Record]:
    return [
        record
        for record in records
        if record.timestamp > after
        and (not events or record.event in events)
        and all(record.fields.get(key) == value for key, value in fields.items())
        and all(
            key in record.fields and record.fields[key] != value
            for key, value in excluded_fields.items()
        )
    ]


def command_marker(args: argparse.Namespace) -> int:
    records = load_records(args.directory)
    print(records[-1].timestamp if records else EMPTY_MARKER)
    return 0


def command_check(args: argparse.Namespace) -> int:
    records = load_records(args.directory)
    matches = matching_records(
        records,
        after=args.after,
        events=set(args.event),
        fields=parse_field_constraints(args.field),
        excluded_fields=parse_field_constraints(args.field_not),
    )
    if not matches:
        requested = ", ".join(args.event) if args.event else "any event"
        print(f"no new matching record after {args.after}: {requested}", file=sys.stderr)
        return 1
    print(json.dumps(matches[-1].json_value(), sort_keys=True))
    return 0


def command_timeline(args: argparse.Namespace) -> int:
    records = matching_records(
        load_records(args.directory),
        after=args.after,
        events=set(args.event),
        fields={},
        excluded_fields={},
    )
    for record in records:
        fields = " ".join(f"{key}={value}" for key, value in sorted(record.fields.items()))
        print(f"{record.timestamp} {record.level} {record.event} {fields}".rstrip())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    marker = subparsers.add_parser("marker", help="print the newest record timestamp")
    marker.add_argument("directory", type=Path)
    marker.set_defaults(run=command_marker)

    check = subparsers.add_parser("check", help="require a matching record after a marker")
    check.add_argument("directory", type=Path)
    check.add_argument("--after", default=EMPTY_MARKER)
    check.add_argument("--event", action="append", default=[])
    check.add_argument("--field", action="append", default=[], metavar="KEY=VALUE")
    check.add_argument("--field-not", action="append", default=[], metavar="KEY=VALUE")
    check.set_defaults(run=command_check)

    timeline = subparsers.add_parser("timeline", help="print compact records after a marker")
    timeline.add_argument("directory", type=Path)
    timeline.add_argument("--after", default=EMPTY_MARKER)
    timeline.add_argument("--event", action="append", default=[])
    timeline.set_defaults(run=command_timeline)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
        return args.run(args)
    except JournalError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
