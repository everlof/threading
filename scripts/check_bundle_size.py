#!/usr/bin/env python3
"""Keep Threading.app from growing without anyone deciding that it should.

Measures an exported, thinned app bundle component by component — on disk, and compressed the way
the zip Sparkle serves compresses it — and compares each component with a reviewed baseline.
Growth past a noise allowance, or a new embedded payload the baseline has never seen, fails.
Shrinking never fails; it prints the command that locks the saving in.

Why a ratchet rather than a budget: the bundle went from 54.5 MB to roughly 125 MB between
2026-08-22 and 2026-10-17 while a written rule ("add any new embedded binary over ~5 MB to the
table first", docs/decisions/bundle-size-levers.md §4) said every large addition should have been
recorded. Nothing did, because nothing measured. A regenerated baseline is a diff somebody has to
commit, which is the review the written rule could not force.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
MEBIBYTE = 1024 * 1024
# A top-level item at least this large is a component of its own; smaller siblings are summed
# into one bucket per directory, so a baseline stays readable while every byte still belongs to
# exactly one component.
INDIVIDUAL_COMPONENT_BYTES = 1 * MEBIBYTE
SMALL_ITEMS_LABEL = "(items under 1 MiB)"
# Directories whose top-level entries are measured one by one. Everything else under Contents/
# (Info.plist, _CodeSignature, the provisioning profile, Library/) is one component.
ITEMIZED_DIRECTORIES = (
    "Contents/MacOS",
    "Contents/Frameworks",
    "Contents/PlugIns",
    "Contents/Helpers",
    "Contents/Resources",
)
OTHER_CONTENTS_LABEL = "Contents/(everything else)"
# Identical sources do not always produce identical bytes (signatures, timestamps, the order a
# linker happened to see objects in), so a component may exceed its baseline by the larger of
# these before the gate calls it growth.
ABSOLUTE_ALLOWANCE_BYTES = 128 * 1024
RELATIVE_ALLOWANCE = 0.01
# Raw deflate at zlib's default level is what `ditto -c -k` writes for each member of the zip.
DEFLATE_LEVEL = 6
RAW_DEFLATE_WINDOW_BITS = -15
READ_CHUNK_BYTES = 1 * MEBIBYTE


@dataclass(frozen=True)
class Measurement:
    disk_bytes: int = 0
    compressed_bytes: int = 0

    def __add__(self, other: "Measurement") -> "Measurement":
        return Measurement(
            self.disk_bytes + other.disk_bytes,
            self.compressed_bytes + other.compressed_bytes,
        )

    def as_json(self) -> Dict[str, int]:
        return {"diskBytes": self.disk_bytes, "compressedBytes": self.compressed_bytes}


def compressed_size(path: Path) -> int:
    compressor = zlib.compressobj(DEFLATE_LEVEL, zlib.DEFLATED, RAW_DEFLATE_WINDOW_BITS)
    total = 0
    with path.open("rb") as handle:
        while chunk := handle.read(READ_CHUNK_BYTES):
            total += len(compressor.compress(chunk))
    return total + len(compressor.flush())


def regular_files(root: Path) -> Iterable[Path]:
    """Every regular file under root, never following a symlink.

    A framework's Versions/Current and top-level aliases are symlinks to one real binary; counting
    through them would measure it two or three times.
    """
    if root.is_symlink():
        return
    if root.is_file():
        yield root
        return
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        subdirectories.sort()
        for name in sorted(files):
            path = Path(directory) / name
            if not path.is_symlink() and path.is_file():
                yield path


def measure_tree(root: Path) -> Measurement:
    total = Measurement()
    for path in regular_files(root):
        total = total + Measurement(path.stat().st_size, compressed_size(path))
    return total


def measure_bundle(app: Path) -> Dict[str, Measurement]:
    """Splits the bundle into components that together cover every regular file exactly once."""
    contents = app / "Contents"
    if not contents.is_dir():
        raise ValueError(f"{app} is not an app bundle: it has no Contents directory")

    components: Dict[str, Measurement] = {}
    itemized = {app / directory for directory in ITEMIZED_DIRECTORIES}
    for directory_name in ITEMIZED_DIRECTORIES:
        directory = app / directory_name
        if not directory.is_dir():
            continue
        small_items = Measurement()
        for entry in sorted(directory.iterdir()):
            measurement = measure_tree(entry)
            if measurement.disk_bytes >= INDIVIDUAL_COMPONENT_BYTES:
                components[f"{directory_name}/{entry.name}"] = measurement
            else:
                small_items = small_items + measurement
        if small_items.disk_bytes:
            components[f"{directory_name}/{SMALL_ITEMS_LABEL}"] = small_items

    other = Measurement()
    for entry in sorted(contents.iterdir()):
        if entry not in itemized:
            other = other + measure_tree(entry)
    if other.disk_bytes:
        components[OTHER_CONTENTS_LABEL] = other
    return components


def total(components: Mapping[str, Measurement]) -> Measurement:
    result = Measurement()
    for measurement in components.values():
        result = result + measurement
    return result


def allowance(baseline_bytes: int) -> int:
    return max(ABSOLUTE_ALLOWANCE_BYTES, int(baseline_bytes * RELATIVE_ALLOWANCE))


def megabytes(byte_count: int) -> str:
    return f"{byte_count / 1_000_000:.2f} MB"


def signed_megabytes(byte_count: int) -> str:
    return f"{'+' if byte_count >= 0 else '−'}{abs(byte_count) / 1_000_000:.2f} MB"


def compare(
    observed: Mapping[str, Measurement],
    baseline: Mapping[str, Measurement],
) -> Tuple[List[str], List[str]]:
    """Returns (violations, notes). Only growth and unseen payloads are violations."""
    violations: List[str] = []
    notes: List[str] = []
    for name in sorted(observed):
        actual = observed[name]
        allowed = baseline.get(name)
        if allowed is None:
            violations.append(
                f"{name}: new embedded payload, {megabytes(actual.disk_bytes)} on disk, "
                f"{megabytes(actual.compressed_bytes)} compressed"
            )
            continue
        for label, actual_bytes, allowed_bytes in (
            ("on disk", actual.disk_bytes, allowed.disk_bytes),
            ("compressed", actual.compressed_bytes, allowed.compressed_bytes),
        ):
            if actual_bytes > allowed_bytes + allowance(allowed_bytes):
                violations.append(
                    f"{name}: grew {signed_megabytes(actual_bytes - allowed_bytes)} {label}, "
                    f"{megabytes(allowed_bytes)} → {megabytes(actual_bytes)}"
                )
        if actual.compressed_bytes < allowed.compressed_bytes - allowance(
            allowed.compressed_bytes
        ):
            notes.append(
                f"{name}: shrank {signed_megabytes(actual.compressed_bytes - allowed.compressed_bytes)}"
                " compressed"
            )
    for name in sorted(set(baseline) - set(observed)):
        notes.append(f"{name}: gone (baseline had {megabytes(baseline[name].disk_bytes)} on disk)")
    return violations, notes


def report_lines(
    observed: Mapping[str, Measurement],
    baseline: Optional[Mapping[str, Measurement]],
) -> List[str]:
    name_width = max([len(name) for name in observed] + [len("total")])
    header = f"{'component':<{name_width}}  {'on disk':>10}  {'compressed':>10}"
    if baseline is not None:
        header += f"  {'vs baseline':>12}"
    lines = [header]
    ordered = sorted(observed.items(), key=lambda item: item[1].compressed_bytes, reverse=True)
    for name, measurement in ordered:
        line = (
            f"{name:<{name_width}}  {megabytes(measurement.disk_bytes):>10}  "
            f"{megabytes(measurement.compressed_bytes):>10}"
        )
        if baseline is not None:
            previous = baseline.get(name)
            delta = (
                "new"
                if previous is None
                else signed_megabytes(measurement.compressed_bytes - previous.compressed_bytes)
            )
            line += f"  {delta:>12}"
        lines.append(line)
    whole = total(observed)
    summary = (
        f"{'total':<{name_width}}  {megabytes(whole.disk_bytes):>10}  "
        f"{megabytes(whole.compressed_bytes):>10}"
    )
    if baseline is not None:
        summary += (
            f"  {signed_megabytes(whole.compressed_bytes - total(baseline).compressed_bytes):>12}"
        )
    lines.append(summary)
    return lines


def baseline_document(
    components: Mapping[str, Measurement],
    measured_from: str,
) -> Dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "description": (
            "Per-component size of the exported, arm64-thinned Threading.app, on disk and as raw "
            "deflate (what ditto -c -k writes). Lower sizes are accepted; growth past the noise "
            "allowance, or a new component, requires an intentional baseline update. See "
            "docs/architecture/releasing.md#the-bundle-size-ratchet."
        ),
        "measuredFrom": measured_from,
        "components": {name: components[name].as_json() for name in sorted(components)},
    }


def load_baseline(path: Path) -> Dict[str, Measurement]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError("unsupported bundle size baseline schema")
    components = document.get("components")
    if not isinstance(components, dict):
        raise ValueError("bundle size baseline components must be an object")

    result: Dict[str, Measurement] = {}
    for name, raw in components.items():
        if not isinstance(name, str) or not isinstance(raw, dict):
            raise ValueError("bundle size baseline entries must map names to size objects")
        disk_bytes = raw.get("diskBytes")
        compressed_bytes = raw.get("compressedBytes")
        for value in (disk_bytes, compressed_bytes):
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"invalid sizes for {name}")
        result[name] = Measurement(disk_bytes, compressed_bytes)
    return result


def write_baseline(path: Path, components: Mapping[str, Measurement], measured_from: str) -> None:
    path.write_text(
        json.dumps(baseline_document(components, measured_from), indent=2) + "\n",
        encoding="utf-8",
    )


def parse_arguments(arguments: Sequence[str]) -> argparse.Namespace:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path, help="the exported, thinned Threading.app")
    parser.add_argument(
        "--baseline",
        type=Path,
        default=script_directory / "bundle_size_baseline.json",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--write-baseline",
        metavar="MEASURED_FROM",
        help="replace the baseline with this bundle's sizes; the argument says what was measured "
        "(commit, configuration, how it was built) so a later reader can reproduce it",
    )
    mode.add_argument(
        "--report",
        action="store_true",
        help="print the measurement and never fail; compares with the baseline when it exists",
    )
    mode.add_argument(
        "--summary",
        action="store_true",
        help="print one line with the bundle's total size and never fail",
    )
    return parser.parse_args(arguments)


def main(arguments: Sequence[str]) -> int:
    options = parse_arguments(arguments)
    try:
        observed = measure_bundle(options.app)
        whole = total(observed)

        if options.summary:
            print(
                f"{megabytes(whole.disk_bytes)} on disk, "
                f"{megabytes(whole.compressed_bytes)} compressed"
            )
            return 0

        if options.write_baseline is not None:
            write_baseline(options.baseline, observed, options.write_baseline)
            print(
                f"bundle-size: wrote {len(observed)} components, "
                f"{megabytes(whole.disk_bytes)} on disk, "
                f"{megabytes(whole.compressed_bytes)} compressed"
            )
            return 0

        baseline: Optional[Dict[str, Measurement]] = None
        if options.baseline.is_file():
            baseline = load_baseline(options.baseline)
        elif not options.report:
            raise ValueError(f"no baseline at {options.baseline}")

        for line in report_lines(observed, baseline):
            print(f"  {line}")
        if baseline is None:
            return 0

        violations, notes = compare(observed, baseline)
        for note in notes:
            print(f"bundle-size: note: {note}")
        if violations and not options.report:
            for violation in violations:
                print(f"bundle-size: {violation}", file=sys.stderr)
            print(
                "bundle-size: shrink it, or — if the growth is intended — record why in "
                "docs/decisions/bundle-size-levers.md §2 and regenerate the baseline with "
                "--write-baseline from this exported bundle",
                file=sys.stderr,
            )
            return 1
        for violation in violations:
            print(f"bundle-size: over baseline: {violation}")
        if notes and not violations:
            print(
                "bundle-size: smaller than the baseline — lock the saving in with "
                "--write-baseline so it cannot be spent silently"
            )
        print(
            f"bundle-size: {'clean' if not violations else 'over baseline'} — "
            f"{megabytes(whole.disk_bytes)} on disk, {megabytes(whole.compressed_bytes)} compressed"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"bundle-size: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
