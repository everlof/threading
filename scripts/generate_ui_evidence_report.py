#!/usr/bin/env python3
"""Build Threading's browsable component, surface, and journey evidence report."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import platform as host_platform
import re
import shutil
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
COMPONENT_METADATA_KIND = "threading-component-evidence"
JOURNEY_METADATA_KIND = "threading-ui-journey-report"
SAFE_ID = re.compile(r"^[a-z][a-z0-9-]*$")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAXIMUM_ARTIFACTS = 1_024
MAXIMUM_IMAGE_BYTES = 24 * 1024 * 1024
MAXIMUM_IMAGE_EDGE = 16_384
MAXIMUM_IMAGE_PIXELS = 64 * 1024 * 1024


@dataclass(frozen=True)
class Entry:
    identifier: str
    kind: str
    status: str
    priority: str
    title: str
    description: str
    states: tuple[str, ...]
    matrix: dict[str, tuple[str, ...]]
    source_path: str | None
    selectors: tuple[str, ...]
    source_command: str | None
    capture: dict[str, str] | None


@dataclass
class Artifact:
    identifier: str
    entry: Entry
    title: str
    variant: str
    description: str
    current: Path
    baseline_relative: Path
    tags: tuple[str, ...]
    result: str | None = None
    current_asset: str | None = None
    baseline_asset: str | None = None
    diff_asset: str | None = None
    comparison: str = "new"
    dimensions: tuple[int, int] | None = None
    baseline_dimensions: tuple[int, int] | None = None
    current_sha256: str | None = None
    baseline_sha256: str | None = None
    changed_pixels: int | None = None
    total_pixels: int | None = None
    difference_bounds: tuple[int, int, int, int] | None = None


def require_text(value: dict[str, Any], key: str, context: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result.strip():
        raise ValueError(f"{context}: {key!r} must be non-empty text")
    return result.strip()


def require_text_list(value: Any, context: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{context} must be a non-empty list")
    result: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise ValueError(f"{context} contains an empty or non-text value")
        result.append(item.strip())
    return tuple(result)


def load_manifest(path: Path) -> tuple[str, str, list[Entry]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read UI evidence manifest {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"unsupported UI evidence manifest schema in {path}")
    title = require_text(payload, "title", "manifest")
    platform_name = payload.get("platform", "macOS")
    if not isinstance(platform_name, str) or not platform_name.strip():
        raise ValueError("manifest platform must be non-empty text")
    raw_entries = payload.get("entries")
    if not isinstance(raw_entries, list) or not raw_entries:
        raise ValueError("manifest entries must be a non-empty list")

    entries: list[Entry] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_entries):
        context = f"manifest entry {index + 1}"
        if not isinstance(raw, dict):
            raise ValueError(f"{context} must be an object")
        identifier = require_text(raw, "id", context)
        if not SAFE_ID.fullmatch(identifier):
            raise ValueError(f"{context}: invalid id {identifier!r}")
        if identifier in seen:
            raise ValueError(f"duplicate manifest entry id {identifier!r}")
        seen.add(identifier)

        kind = require_text(raw, "kind", context)
        status = require_text(raw, "status", context)
        priority = require_text(raw, "priority", context)
        if kind not in {"component", "surface", "journey"}:
            raise ValueError(f"{identifier}: unsupported kind {kind!r}")
        if status not in {"implemented", "planned"}:
            raise ValueError(f"{identifier}: unsupported status {status!r}")
        if priority not in {"critical", "important", "supporting"}:
            raise ValueError(f"{identifier}: unsupported priority {priority!r}")

        raw_matrix = raw.get("matrix")
        if not isinstance(raw_matrix, dict) or not raw_matrix:
            raise ValueError(f"{identifier}: matrix must be a non-empty object")
        matrix = {
            require_nonempty_key(key, identifier): require_text_list(
                values, f"{identifier}.matrix.{key}"
            )
            for key, values in raw_matrix.items()
        }

        source_path: str | None = None
        selectors: tuple[str, ...] = ()
        source_command: str | None = None
        source = raw.get("source")
        if source is not None:
            if not isinstance(source, dict):
                raise ValueError(f"{identifier}: source must be an object")
            source_path = require_text(source, "path", f"{identifier}.source")
            if Path(source_path).is_absolute() or ".." in Path(source_path).parts:
                raise ValueError(f"{identifier}: source path must stay repository-relative")
            single = source.get("test")
            multiple = source.get("tests")
            command = source.get("command")
            contract_count = sum(value is not None for value in (single, multiple, command))
            if contract_count != 1:
                raise ValueError(
                    f"{identifier}: source must contain exactly one of test, tests, or command"
                )
            if single is not None:
                if not isinstance(single, str) or not single.strip():
                    raise ValueError(f"{identifier}: source.test must be non-empty text")
                selectors = (single.strip(),)
            elif multiple is not None:
                selectors = require_text_list(multiple, f"{identifier}.source.tests")
            elif not isinstance(command, str) or not command.strip():
                raise ValueError(f"{identifier}: source.command must be non-empty text")
            else:
                source_command = command.strip()

        capture: dict[str, str] | None = None
        raw_capture = raw.get("capture")
        if raw_capture is not None:
            if not isinstance(raw_capture, dict):
                raise ValueError(f"{identifier}: capture must be an object")
            supported = {
                key: value.strip()
                for key, value in raw_capture.items()
                if key in {"metadata", "glob", "journey"}
                and isinstance(value, str)
                and value.strip()
            }
            if len(supported) != 1 or len(raw_capture) != 1:
                raise ValueError(
                    f"{identifier}: capture must contain exactly one of metadata, glob, or journey"
                )
            capture = supported

        if status == "implemented" and (
            not source_path or not (selectors or source_command) or not capture
        ):
            raise ValueError(
                f"{identifier}: implemented evidence needs a source, test selector, and capture"
            )
        if kind == "journey" and capture and "journey" not in capture:
            raise ValueError(f"{identifier}: journey evidence must name a journey capture")
        if kind != "journey" and capture and "journey" in capture:
            raise ValueError(f"{identifier}: only journey evidence can name a journey capture")

        entries.append(Entry(
            identifier=identifier,
            kind=kind,
            status=status,
            priority=priority,
            title=require_text(raw, "title", context),
            description=require_text(raw, "description", context),
            states=require_text_list(raw.get("states"), f"{identifier}.states"),
            matrix=matrix,
            source_path=source_path,
            selectors=selectors,
            source_command=source_command,
            capture=capture,
        ))
    return title, platform_name.strip(), entries


def require_nonempty_key(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context}: matrix keys must be non-empty text")
    return value.strip()


def safe_relative_path(value: str, context: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"{context}: unsafe relative path {value!r}")
    return path


def ensure_regular_png(path: Path, context: str) -> tuple[int, int]:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{context}: image is missing or not a regular file: {path}")
    size = path.stat().st_size
    if size <= 24 or size > MAXIMUM_IMAGE_BYTES:
        raise ValueError(f"{context}: PNG size is outside the evidence bound: {size} bytes")
    with path.open("rb") as handle:
        header = handle.read(24)
    if header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise ValueError(f"{context}: not a PNG image: {path}")
    width, height = struct.unpack(">II", header[16:24])
    if width == 0 or height == 0:
        raise ValueError(f"{context}: PNG has empty dimensions: {path}")
    if (
        width > MAXIMUM_IMAGE_EDGE
        or height > MAXIMUM_IMAGE_EDGE
        or width * height > MAXIMUM_IMAGE_PIXELS
    ):
        raise ValueError(
            f"{context}: PNG dimensions exceed the evidence bound: {width}×{height}"
        )
    return width, height


def paeth_predictor(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def decoded_rgba(path: Path, context: str) -> tuple[int, int, bytes]:
    """Decode bounded 8/16-bit PNGs without making report generation depend on Pillow.

    Evidence images come from AppKit, UIKit, or simctl, but baselines can survive toolchain
    upgrades that choose a different lossless PNG encoding. Comparing decoded pixels keeps the
    approval contract pixel-perfect without treating metadata or compression changes as UI diffs.
    """
    width, height = ensure_regular_png(path, context)
    payload = path.read_bytes()
    offset = len(PNG_SIGNATURE)
    bit_depth: int | None = None
    color_type: int | None = None
    interlace: int | None = None
    palette: bytes | None = None
    transparency: bytes = b""
    compressed = bytearray()
    while offset + 12 <= len(payload):
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        chunk_type = payload[offset + 4:offset + 8]
        chunk_start = offset + 8
        chunk_end = chunk_start + length
        if chunk_end + 4 > len(payload):
            raise ValueError(f"{context}: truncated PNG chunk in {path}")
        chunk = payload[chunk_start:chunk_end]
        if chunk_type == b"IHDR":
            if len(chunk) != 13:
                raise ValueError(f"{context}: malformed PNG header in {path}")
            _, _, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", chunk
            )
            if compression != 0 or filtering != 0:
                raise ValueError(f"{context}: unsupported PNG compression/filter method")
        elif chunk_type == b"PLTE":
            palette = chunk
        elif chunk_type == b"tRNS":
            transparency = chunk
        elif chunk_type == b"IDAT":
            compressed.extend(chunk)
        elif chunk_type == b"IEND":
            break
        offset = chunk_end + 4

    if bit_depth not in {8, 16} or color_type not in {0, 2, 3, 4, 6} or interlace != 0:
        raise ValueError(
            f"{context}: evidence comparison requires a non-interlaced 8/16-bit PNG "
            f"(found depth={bit_depth}, color={color_type}, interlace={interlace})"
        )
    if color_type == 3 and bit_depth != 8:
        raise ValueError(f"{context}: indexed PNG comparison requires 8-bit palette entries")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    sample_bytes = bit_depth // 8
    bytes_per_pixel = channels * sample_bytes
    row_bytes = width * bytes_per_pixel
    try:
        filtered = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise ValueError(f"{context}: could not decompress PNG {path}: {error}") from error
    expected = height * (row_bytes + 1)
    if len(filtered) != expected:
        raise ValueError(
            f"{context}: decoded PNG data has {len(filtered)} bytes; expected {expected}"
        )

    rows: list[bytearray] = []
    cursor = 0
    previous = bytearray(row_bytes)
    for _ in range(height):
        filter_type = filtered[cursor]
        cursor += 1
        source = filtered[cursor:cursor + row_bytes]
        cursor += row_bytes
        row = bytearray(row_bytes)
        for index, value in enumerate(source):
            left = row[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = paeth_predictor(left, above, upper_left)
            else:
                raise ValueError(f"{context}: unsupported PNG row filter {filter_type}")
            row[index] = (value + predictor) & 0xFF
        rows.append(row)
        previous = row

    rgba = bytearray(width * height * 8)
    destination = 0
    for row in rows:
        def sample(offset: int) -> int:
            if bit_depth == 16:
                return struct.unpack(">H", row[offset:offset + 2])[0]
            return row[offset] * 257

        for source in range(0, len(row), bytes_per_pixel):
            if color_type == 6:
                red = sample(source)
                green = sample(source + sample_bytes)
                blue = sample(source + sample_bytes * 2)
                alpha = sample(source + sample_bytes * 3)
            elif color_type == 2:
                red = sample(source)
                green = sample(source + sample_bytes)
                blue = sample(source + sample_bytes * 2)
                alpha = 65535
                if len(transparency) == 6:
                    transparent = struct.unpack(">HHH", transparency)
                    if bit_depth == 8:
                        transparent = tuple(value * 257 for value in transparent)
                    if (red, green, blue) == transparent:
                        alpha = 0
            elif color_type == 4:
                red = green = blue = sample(source)
                alpha = sample(source + sample_bytes)
            elif color_type == 0:
                red = green = blue = sample(source)
                alpha = 65535
                if len(transparency) == 2:
                    transparent = struct.unpack(">H", transparency)[0]
                    if bit_depth == 8:
                        transparent *= 257
                    if red == transparent:
                        alpha = 0
            else:
                if palette is None:
                    raise ValueError(f"{context}: indexed PNG has no palette")
                palette_index = row[source]
                palette_offset = palette_index * 3
                if palette_offset + 3 > len(palette):
                    raise ValueError(f"{context}: indexed PNG palette entry is missing")
                red, green, blue = (
                    value * 257 for value in palette[palette_offset:palette_offset + 3]
                )
                alpha = (
                    transparency[palette_index] * 257
                    if palette_index < len(transparency) else 65535
                )
            rgba[destination:destination + 8] = struct.pack(">HHHH", red, green, blue, alpha)
            destination += 8
    return width, height, bytes(rgba)


def humanize_file(path: Path) -> str:
    text = path.stem.replace("_", " ").replace("-", " ")
    return re.sub(r"\s+", " ", text).strip().title()


def load_component_artifacts(entry: Entry, current: Path) -> list[Artifact]:
    assert entry.capture is not None
    relative_metadata = safe_relative_path(entry.capture["metadata"], entry.identifier)
    metadata_path = current / relative_metadata
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{entry.identifier}: invalid component metadata: {error}") from error
    if (
        not isinstance(payload, dict)
        or payload.get("schemaVersion") != SCHEMA_VERSION
        or payload.get("kind") != COMPONENT_METADATA_KIND
    ):
        raise ValueError(f"{entry.identifier}: unsupported component evidence metadata")
    raw_artifacts = payload.get("artifacts")
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        raise ValueError(f"{entry.identifier}: component metadata has no artifacts")
    if len(raw_artifacts) > MAXIMUM_ARTIFACTS:
        raise ValueError(f"{entry.identifier}: component metadata exceeds the artifact bound")

    artifacts: list[Artifact] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_artifacts):
        context = f"{entry.identifier} component artifact {index + 1}"
        if not isinstance(raw, dict) or raw.get("entryID") != entry.identifier:
            raise ValueError(f"{context}: wrong or missing entryID")
        identifier = require_text(raw, "id", context)
        if identifier in seen:
            raise ValueError(f"{context}: duplicate artifact id {identifier!r}")
        seen.add(identifier)
        image_relative = safe_relative_path(require_text(raw, "image", context), context)
        image = current / image_relative
        dimensions = ensure_regular_png(image, context)
        tags = require_text_list(raw.get("tags"), f"{context}.tags")
        artifacts.append(Artifact(
            identifier=identifier,
            entry=entry,
            title=require_text(raw, "title", context),
            variant=require_text(raw, "variant", context),
            description=require_text(raw, "description", context),
            current=image,
            baseline_relative=image_relative,
            tags=tags,
            dimensions=dimensions,
        ))
    return artifacts


def load_glob_artifacts(
    entry: Entry,
    current: Path,
    *,
    allow_empty: bool = False,
) -> list[Artifact]:
    assert entry.capture is not None
    pattern = entry.capture["glob"]
    if Path(pattern).is_absolute() or ".." in Path(pattern).parts:
        raise ValueError(f"{entry.identifier}: unsafe capture glob {pattern!r}")
    images = sorted(path for path in current.glob(pattern) if path.is_file())
    if not images:
        if allow_empty:
            return []
        raise ValueError(f"{entry.identifier}: capture glob matched no images: {pattern}")
    artifacts: list[Artifact] = []
    for image in images:
        relative = image.relative_to(current)
        dimensions = ensure_regular_png(image, entry.identifier)
        variant = humanize_file(relative)
        artifacts.append(Artifact(
            identifier=f"{entry.identifier}.{slug(relative.with_suffix('').as_posix())}",
            entry=entry,
            title=entry.title,
            variant=variant,
            description=f"{entry.description} This image is the {variant} variant.",
            current=image,
            baseline_relative=relative,
            tags=(entry.kind, entry.priority),
            dimensions=dimensions,
        ))
    return artifacts


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return result or "artifact"


def load_journey_documents(paths: list[Path]) -> dict[str, dict[str, Any]]:
    journeys: dict[str, dict[str, Any]] = {}
    for supplied in paths:
        path = supplied / "evidence.json" if supplied.is_dir() else supplied
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid journey evidence {path}: {error}") from error
        if (
            not isinstance(payload, dict)
            or payload.get("schemaVersion") != SCHEMA_VERSION
            or payload.get("kind") != JOURNEY_METADATA_KIND
        ):
            raise ValueError(f"unsupported journey evidence document {path}")
        tests = payload.get("tests")
        if not isinstance(tests, list):
            raise ValueError(f"journey evidence document has no tests: {path}")
        for test in tests:
            if not isinstance(test, dict):
                raise ValueError(f"journey evidence test is not an object: {path}")
            journey = require_text(test, "journey", str(path))
            if journey in journeys:
                raise ValueError(f"journey {journey!r} appeared in more than one report")
            copied = dict(test)
            copied["_root"] = str(path.parent)
            journeys[journey] = copied
    return journeys


def load_journey_artifacts(
    entry: Entry,
    journey_documents: dict[str, dict[str, Any]],
) -> list[Artifact]:
    assert entry.capture is not None
    journey_name = entry.capture["journey"]
    document = journey_documents.get(journey_name)
    if document is None:
        return []
    checkpoints = document.get("checkpoints")
    if not isinstance(checkpoints, list):
        raise ValueError(f"{entry.identifier}: journey checkpoints must be a list")
    root = Path(require_text(document, "_root", entry.identifier))
    artifacts: list[Artifact] = []
    for index, checkpoint in enumerate(checkpoints):
        context = f"{entry.identifier} checkpoint {index + 1}"
        if not isinstance(checkpoint, dict):
            raise ValueError(f"{context} must be an object")
        checkpoint_id = require_text(checkpoint, "checkpoint", context)
        source_relative = safe_relative_path(require_text(checkpoint, "image", context), context)
        image = root / source_relative
        dimensions = ensure_regular_png(image, context)
        baseline_relative = Path("journeys") / entry.identifier / f"{slug(checkpoint_id)}.png"
        artifacts.append(Artifact(
            identifier=f"{entry.identifier}.{slug(checkpoint_id)}",
            entry=entry,
            title=require_text(checkpoint, "title", context),
            variant=f"Checkpoint {checkpoint.get('order', index + 1)}",
            description=require_text(checkpoint, "description", context),
            current=image,
            baseline_relative=baseline_relative,
            tags=("journey", entry.priority),
            result=str(document.get("result", "Unknown")),
            dimensions=dimensions,
        ))
    return artifacts


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def compare_pixels(
    current: Path,
    baseline: Path,
    context: str,
) -> tuple[int, int, tuple[int, int, int, int] | None]:
    current_width, current_height, current_pixels = decoded_rgba(current, context)
    baseline_width, baseline_height, baseline_pixels = decoded_rgba(baseline, context)
    canvas_width = max(current_width, baseline_width)
    canvas_height = max(current_height, baseline_height)
    if (
        current_width == baseline_width
        and current_height == baseline_height
        and current_pixels == baseline_pixels
    ):
        return 0, canvas_width * canvas_height, None
    changed = 0
    minimum_x = canvas_width
    minimum_y = canvas_height
    maximum_x = -1
    maximum_y = -1
    for y in range(canvas_height):
        for x in range(canvas_width):
            current_offset = (y * current_width + x) * 8
            baseline_offset = (y * baseline_width + x) * 8
            current_pixel = (
                current_pixels[current_offset:current_offset + 8]
                if x < current_width and y < current_height
                else b"\x00" * 8
            )
            baseline_pixel = (
                baseline_pixels[baseline_offset:baseline_offset + 8]
                if x < baseline_width and y < baseline_height
                else b"\x00" * 8
            )
            if current_pixel == baseline_pixel:
                continue
            changed += 1
            minimum_x = min(minimum_x, x)
            minimum_y = min(minimum_y, y)
            maximum_x = max(maximum_x, x)
            maximum_y = max(maximum_y, y)
    bounds = None
    if changed:
        bounds = (minimum_x, minimum_y, maximum_x + 1, maximum_y + 1)
    return changed, canvas_width * canvas_height, bounds


def compare_and_optionally_accept(
    artifacts: list[Artifact],
    baseline: Path | None,
    accept_new: bool,
) -> int:
    accepted = 0
    if accept_new and baseline is None:
        raise ValueError("--accept-new-baselines requires --baseline")
    for artifact in artifacts:
        artifact.current_sha256 = sha256(artifact.current)
        if baseline is None:
            artifact.comparison = "unbaselined"
            continue
        baseline_image = baseline / artifact.baseline_relative
        if accept_new and not baseline_image.exists():
            baseline_image.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(artifact.current, baseline_image)
            accepted += 1
        if not baseline_image.exists():
            artifact.comparison = "new"
            continue
        artifact.baseline_dimensions = ensure_regular_png(baseline_image, artifact.identifier)
        artifact.baseline_sha256 = sha256(baseline_image)
        (
            artifact.changed_pixels,
            artifact.total_pixels,
            artifact.difference_bounds,
        ) = compare_pixels(
            artifact.current,
            baseline_image,
            artifact.identifier,
        )
        artifact.comparison = "accepted" if artifact.changed_pixels == 0 else "changed"
    return accepted


def copy_asset(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256(source) != sha256(destination):
            raise ValueError(f"two different artifacts map to {destination}")
        return
    shutil.copy2(source, destination)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_diff_png(current: Path, baseline: Path, destination: Path, context: str) -> None:
    current_width, current_height, current_pixels = decoded_rgba(current, context)
    baseline_width, baseline_height, baseline_pixels = decoded_rgba(baseline, context)
    width = max(current_width, baseline_width)
    height = max(current_height, baseline_height)
    rows = bytearray()
    unchanged = b"\x00\x00\x00\xff"
    changed = b"\xff\x40\xb0\xff"
    for y in range(height):
        rows.append(0)
        for x in range(width):
            current_offset = (y * current_width + x) * 8
            baseline_offset = (y * baseline_width + x) * 8
            current_pixel = (
                current_pixels[current_offset:current_offset + 8]
                if x < current_width and y < current_height
                else b"\x00" * 8
            )
            baseline_pixel = (
                baseline_pixels[baseline_offset:baseline_offset + 8]
                if x < baseline_width and y < baseline_height
                else b"\x00" * 8
            )
            rows.extend(unchanged if current_pixel == baseline_pixel else changed)
    payload = (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + png_chunk(b"IEND", b"")
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)


def stage_assets(artifacts: list[Artifact], baseline: Path | None, output: Path) -> None:
    for artifact in artifacts:
        current_relative = Path("assets/current") / artifact.baseline_relative
        copy_asset(artifact.current, output / current_relative)
        artifact.current_asset = current_relative.as_posix()
        if baseline is not None:
            baseline_image = baseline / artifact.baseline_relative
            if baseline_image.exists():
                baseline_relative = Path("assets/baseline") / artifact.baseline_relative
                copy_asset(baseline_image, output / baseline_relative)
                artifact.baseline_asset = baseline_relative.as_posix()
                if artifact.comparison == "changed":
                    diff_relative = Path("assets/diff") / artifact.baseline_relative
                    write_diff_png(
                        artifact.current,
                        baseline_image,
                        output / diff_relative,
                        artifact.identifier,
                    )
                    artifact.diff_asset = diff_relative.as_posix()


def render_matrix(entry: Entry) -> str:
    rows = []
    for key, values in entry.matrix.items():
        rows.append(
            f"<div><dt>{html.escape(key.title())}</dt>"
            f"<dd>{html.escape(' · '.join(values))}</dd></div>"
        )
    return f'<dl class="matrix">{"".join(rows)}</dl>'


def report_identity(artifacts: list[Artifact]) -> str:
    return hashlib.sha256(
        "\n".join(
            f"{artifact.identifier}:{artifact.current_sha256}"
            for artifact in artifacts
        ).encode("utf-8")
    ).hexdigest()[:16]


def render_artifact(artifact: Artifact, mode: str) -> str:
    assert artifact.current_asset is not None
    current = html.escape(artifact.current_asset)
    baseline = html.escape(artifact.baseline_asset or "")
    diff = html.escape(artifact.diff_asset or "")
    image_dimensions = ""
    if artifact.dimensions:
        width, height = artifact.dimensions
        image_dimensions = f' width="{width}" height="{height}"'
    controls = ""
    baseline_image = ""
    if artifact.baseline_asset:
        diff_control = (
            '<button type="button" data-mode="diff">Diff</button>'
            if artifact.diff_asset
            else ""
        )
        controls = (
            '<div class="compare-controls" role="group" aria-label="Image comparison">'
            '<button type="button" data-mode="current" class="active">Current</button>'
            '<button type="button" data-mode="baseline">Baseline</button>'
            f"{diff_control}</div>"
        )
        baseline_image = f'data-baseline="{baseline}" data-diff="{diff}"'
    result = f" · {html.escape(artifact.result)}" if artifact.result else ""
    dimensions = ""
    if artifact.dimensions:
        dimensions = f"{artifact.dimensions[0]}×{artifact.dimensions[1]} px"
    difference = ""
    if artifact.changed_pixels is not None and artifact.total_pixels:
        percentage = artifact.changed_pixels * 100 / artifact.total_pixels
        difference = (
            f" · {artifact.changed_pixels:,} changed pixels ({percentage:.4f}%)"
        )
        if artifact.difference_bounds:
            left, top, right, bottom = artifact.difference_bounds
            difference += f" · bounds {left},{top}–{right},{bottom}"
    workflow = ""
    if mode == "regression" and artifact.comparison != "accepted":
        workflow = (
            '<div class="decision-controls" role="group" aria-label="Review decision">'
            '<button type="button" data-decision="approve">Approve</button>'
            '<button type="button" data-decision="investigate">Investigate</button>'
            '<button type="button" data-decision="reject">Reject</button></div>'
        )
    elif mode == "review":
        workflow = '<button type="button" class="annotate">Annotate image</button>'
    return (
        f'<figure data-artifact-id="{html.escape(artifact.identifier)}" '
        f'data-current-sha256="{html.escape(artifact.current_sha256 or "")}" '
        f'data-baseline-relative="{html.escape(artifact.baseline_relative.as_posix())}" '
        f'data-status="{html.escape(artifact.comparison)}" '
        f'data-search="{html.escape((artifact.title + " " + artifact.variant + " " + artifact.description).lower())}">'
        f'<div class="image-stage" data-current="{current}" {baseline_image}>'
        f'<button class="image-button" type="button" aria-label="Enlarge {html.escape(artifact.title)}">'
        f'<img src="{current}" loading="lazy"{image_dimensions} alt="{html.escape(artifact.title + ": " + artifact.variant)}">'
        '</button>'
        '<p class="image-error" role="status" aria-live="polite" hidden>'
        'Image unavailable. Keep this report beside its assets directory.</p>'
        f'{controls}</div><figcaption>'
        f'<div class="caption-line"><span class="variant">{html.escape(artifact.variant)}</span>'
        f'<span class="verdict {html.escape(artifact.comparison)}">{html.escape(artifact.comparison.title())}{result}</span></div>'
        f'<h3>{html.escape(artifact.title)}</h3>'
        f'<p>{html.escape(artifact.description)}</p>'
        f'<small>{html.escape(dimensions + difference)}</small>{workflow}'
        '<ol class="annotation-list"></ol></figcaption></figure>'
    )


def render_report(
    title: str,
    platform_name: str,
    entries: list[Entry],
    artifacts_by_entry: dict[str, list[Artifact]],
    accepted_count: int,
    mode: str,
    fingerprint: dict[str, str],
) -> str:
    all_artifacts = [artifact for values in artifacts_by_entry.values() for artifact in values]
    identity = report_identity(all_artifacts)
    counts = {
        key: sum(artifact.comparison == key for artifact in all_artifacts)
        for key in ["accepted", "changed", "new", "unbaselined"]
    }
    implemented = sum(entry.status == "implemented" for entry in entries)
    planned = sum(entry.status == "planned" for entry in entries)
    generated = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")

    navigation: list[str] = []
    sections: list[str] = []
    for entry in entries:
        artifacts = artifacts_by_entry.get(entry.identifier, [])
        navigation.append(
            f'<a href="#{html.escape(entry.identifier)}" data-kind="{html.escape(entry.kind)}">'
            f'<span>{html.escape(entry.title)}</span><small>{len(artifacts) or entry.status.title()}</small></a>'
        )
        state_tags = "".join(f"<li>{html.escape(state)}</li>" for state in entry.states)
        figures = "".join(render_artifact(artifact, mode) for artifact in artifacts)
        if not artifacts:
            explanation = (
                "This coverage item is in the plan but has not been implemented yet."
                if entry.status == "planned"
                else "The item is implemented, but its evidence was not included in this run."
            )
            figures = f'<div class="empty"><strong>{entry.status.title()}</strong><p>{html.escape(explanation)}</p></div>'
        source = ""
        if entry.source_path:
            source_contract = " · ".join(entry.selectors) or entry.source_command or ""
            source = (
                f'<div class="source"><code>{html.escape(entry.source_path)}</code>'
                f'<span>{html.escape(source_contract)}</span></div>'
            )
        sections.append(
            f'<section id="{html.escape(entry.identifier)}" class="evidence-section" '
            f'data-kind="{html.escape(entry.kind)}" data-coverage="{html.escape(entry.status)}" '
            f'data-search="{html.escape((entry.title + " " + entry.description + " " + " ".join(entry.states)).lower())}">'
            '<header><div>'
            f'<span class="eyebrow">{html.escape(entry.kind)} · {html.escape(entry.priority)}</span>'
            f'<h2>{html.escape(entry.title)}</h2><p>{html.escape(entry.description)}</p></div>'
            f'<span class="coverage {html.escape(entry.status)}">{html.escape(entry.status.title())}</span></header>'
            f'<ul class="states">{state_tags}</ul>{render_matrix(entry)}{source}'
            f'<div class="artifact-grid">{figures}</div></section>'
        )

    acceptance_note = (
        f" · accepted {accepted_count} new baseline{'s' if accepted_count != 1 else ''}"
        if accepted_count else ""
    )
    workflow_label = "Regression approval" if mode == "regression" else "Design review"
    workflow_description = (
        "Exact decoded-pixel comparisons. Every changed or new image needs an exported decision."
        if mode == "regression"
        else "Browse accepted and changed images, attach point annotations, and export them for implementation."
    )
    fingerprint_rows = "".join(
        f"<span><strong>{html.escape(key)}:</strong> {html.escape(value)}</span>"
        for key, value in fingerprint.items()
    )
    initial_verdict = "actionable" if mode == "regression" else "all"
    workflow_controls = (
        '<button type="button" id="export-decisions">Export decisions.json</button>'
        '<label class="file-control">Import decisions<input id="import-decisions" type="file" accept="application/json" hidden></label>'
        if mode == "regression"
        else '<button type="button" id="export-annotations">Export annotations.json</button>'
             '<label class="file-control">Import annotations<input id="import-annotations" type="file" accept="application/json" hidden></label>'
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(workflow_label + " · " + title)}</title>
<style>
:root {{ color-scheme:dark; --bg:#0d1014; --sidebar:#11151b; --panel:#171c24; --raised:#202732;
  --text:#f0f3f6; --muted:#98a2b1; --line:#303946; --accent:#8ab8ff; --pass:#55d68a;
  --change:#ffbd59; --new:#74aaff; --planned:#b697ff; --danger:#ff7474; }}
* {{ box-sizing:border-box; }} html {{ scroll-behavior:smooth; }}
body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
button,input,select {{ font:inherit; }} .layout {{ display:grid; grid-template-columns:290px minmax(0,1fr); min-height:100vh; }}
aside {{ position:sticky; top:0; height:100vh; overflow:auto; padding:25px 20px; background:var(--sidebar); border-right:1px solid var(--line); }}
aside h1 {{ margin:0; font-size:21px; }} aside>p {{ margin:3px 0 18px; color:var(--muted); }}
.filters {{ display:grid; gap:8px; margin-bottom:19px; }} .filters input,.filters select {{ width:100%; color:var(--text); background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:8px 10px; }}
nav {{ display:grid; gap:4px; }} nav a {{ display:flex; justify-content:space-between; gap:8px; padding:8px 9px; color:inherit; text-decoration:none; border-radius:7px; }} nav a:hover {{ background:var(--raised); }} nav small {{ color:var(--muted); }}
.summary {{ margin-top:20px; padding-top:16px; border-top:1px solid var(--line); color:var(--muted); font-size:13px; }}
.workflow-links,.workflow-actions {{ display:flex; flex-wrap:wrap; gap:7px; margin-top:12px; }}
.workflow-links a,.workflow-actions button,.file-control,.annotate,.decision-controls button {{ padding:7px 10px; border:1px solid var(--line); border-radius:7px; background:var(--raised); color:var(--text); text-decoration:none; cursor:pointer; }}
.workflow-links a.active {{ border-color:var(--accent); color:var(--accent); }}
.fingerprint {{ display:flex; flex-wrap:wrap; gap:5px 14px; margin-top:10px; color:var(--muted); font-size:12px; }}
main {{ min-width:0; padding:34px clamp(20px,4vw,60px) 80px; }} .run-header,.evidence-section {{ max-width:1600px; margin-left:auto; margin-right:auto; }}
.run-header {{ margin-bottom:34px; }} .run-header h1 {{ margin:0 0 5px; font-size:31px; }} .run-header p {{ margin:0; color:var(--muted); }}
.evidence-section {{ margin-bottom:64px; scroll-margin-top:22px; }} .evidence-section>header {{ display:flex; justify-content:space-between; gap:20px; align-items:start; }}
.eyebrow {{ color:var(--accent); font-size:12px; font-weight:700; letter-spacing:.055em; text-transform:uppercase; }} h2 {{ margin:5px 0 5px; font-size:25px; }}
.evidence-section>header p {{ max-width:900px; margin:0; color:var(--muted); }} .coverage {{ border:1px solid currentColor; border-radius:999px; padding:5px 10px; font-size:12px; font-weight:700; }} .coverage.implemented {{ color:var(--pass); }} .coverage.planned {{ color:var(--planned); }}
.states {{ display:flex; flex-wrap:wrap; gap:6px; margin:15px 0 12px; padding:0; list-style:none; }} .states li {{ padding:4px 8px; background:var(--raised); border-radius:999px; color:#cbd2dc; font-size:12px; }}
.matrix {{ display:flex; flex-wrap:wrap; gap:8px 20px; margin:0 0 10px; }} .matrix div {{ display:flex; gap:7px; }} .matrix dt {{ color:var(--muted); }} .matrix dd {{ margin:0; }}
.source {{ display:flex; flex-wrap:wrap; gap:6px 14px; color:var(--muted); font-size:12px; }} .source code {{ color:#b6c9e8; }}
.artifact-grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,440px),1fr)); align-items:start; gap:18px; margin-top:18px; }}
figure {{ margin:0; overflow:hidden; border:1px solid var(--line); border-radius:12px; background:var(--panel); box-shadow:0 13px 35px #0004; }}
.image-stage {{ position:relative; display:grid; min-height:120px; place-items:center; background:#080a0d; }} .image-button {{ display:block; grid-area:1/1; width:100%; padding:0; border:0; background:transparent; cursor:zoom-in; }}
.image-stage.annotating {{ outline:2px solid var(--accent); outline-offset:-2px; }} .image-stage.annotating .image-button {{ cursor:crosshair; }}
.image-button img {{ display:block; width:100%; height:auto; }} .compare-controls {{ display:flex; gap:3px; position:absolute; right:9px; bottom:9px; padding:3px; border-radius:8px; background:#090c11dd; backdrop-filter:blur(8px); }}
.image-error {{ grid-area:1/1; z-index:1; max-width:34ch; margin:0; padding:22px; color:var(--danger); text-align:center; }} .image-stage.image-failed .image-button {{ visibility:hidden; }}
.annotation-marker {{ position:absolute; width:24px; height:24px; translate:-50% -50%; border:2px solid white; border-radius:50%; background:#0878f9; color:white; font-size:11px; font-weight:800; line-height:20px; text-align:center; pointer-events:none; box-shadow:0 2px 8px #000b; }}
.compare-controls button {{ padding:4px 7px; color:#dce3ec; border:0; border-radius:5px; background:transparent; cursor:pointer; font-size:11px; }} .compare-controls button.active {{ background:#ffffff25; color:white; }}
figcaption {{ padding:14px 16px 16px; }} .caption-line {{ display:flex; justify-content:space-between; gap:12px; align-items:center; }} .variant {{ color:var(--accent); font-size:12px; font-weight:700; }}
.verdict {{ padding:2px 7px; border-radius:999px; background:var(--raised); font-size:11px; font-weight:700; }} .verdict.accepted {{ color:var(--pass); }} .verdict.changed {{ color:var(--change); }} .verdict.new,.verdict.unbaselined {{ color:var(--new); }}
h3 {{ margin:5px 0 4px; font-size:17px; }} figcaption p {{ margin:0; color:var(--muted); }} figcaption small {{ display:block; margin-top:8px; color:#707b89; }}
.annotate,.decision-controls {{ margin-top:12px; }} .decision-controls {{ display:flex; flex-wrap:wrap; gap:6px; }} .decision-controls button.active {{ border-color:var(--accent); color:var(--accent); }}
.decision-controls button[data-decision="reject"].active {{ border-color:var(--danger); color:var(--danger); }} .decision-controls button[data-decision="approve"].active {{ border-color:var(--pass); color:var(--pass); }}
.annotation-list {{ margin:10px 0 0; padding-left:22px; color:var(--muted); }} .annotation-list button {{ margin-left:7px; border:0; background:transparent; color:var(--danger); cursor:pointer; }}
.empty {{ grid-column:1/-1; padding:18px; border:1px dashed var(--line); border-radius:10px; color:var(--muted); }} .empty strong {{ color:var(--text); }} .empty p {{ margin:4px 0 0; }}
dialog {{ width:min(96vw,1800px); max-width:none; padding:0; border:1px solid var(--line); border-radius:12px; background:#080a0d; color:var(--text); }} dialog::backdrop {{ background:#000d; }} dialog img {{ display:block; max-width:94vw; max-height:90vh; }} dialog button {{ position:fixed; top:14px; right:18px; width:38px; height:38px; border:1px solid #fff5; border-radius:20px; background:#111d; color:white; font-size:22px; cursor:pointer; }}
[hidden] {{ display:none !important; }}
@media(max-width:840px) {{ .layout {{ display:block; }} aside {{ position:relative; width:auto; height:auto; border-right:0; border-bottom:1px solid var(--line); }} nav {{ grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); }} main {{ padding-top:24px; }} }}
</style>
</head>
<body data-mode="{html.escape(mode)}" data-platform="{html.escape(platform_name)}"><div class="layout"><aside><h1>{html.escape(title)}</h1><p>{len(all_artifacts)} reviewable images</p>
<div class="filters"><input id="search" type="search" placeholder="Filter features and images" aria-label="Filter evidence">
<select id="kind" aria-label="Evidence kind"><option value="all">All evidence</option><option value="component">Components</option><option value="surface">Surfaces</option><option value="journey">Journeys</option></select>
<select id="verdict" aria-label="Comparison result"><option value="all">All comparisons</option><option value="actionable">Needs decision</option><option value="accepted">Accepted</option><option value="changed">Changed</option><option value="new">New</option><option value="unbaselined">No baseline configured</option></select></div>
<div class="workflow-links"><a href="review.html" class="{'active' if mode == 'review' else ''}">Design review</a><a href="regression.html" class="{'active' if mode == 'regression' else ''}">Regression approval</a></div>
<nav>{''.join(navigation)}</nav><div class="summary"><div>{implemented} implemented · {planned} planned</div><div>{counts['accepted']} accepted · {counts['changed']} changed · {counts['new']} new</div><div>{counts['unbaselined']} without baseline{html.escape(acceptance_note)}</div><div>{html.escape(generated)}</div></div></aside>
<main><header class="run-header"><span class="eyebrow">{html.escape(platform_name)} · {html.escape(workflow_label)}</span><h1>{html.escape(workflow_label)}</h1><p>{html.escape(workflow_description)}</p><div class="fingerprint">{fingerprint_rows}</div><div class="workflow-actions">{workflow_controls}</div></header>{''.join(sections)}</main></div>
<dialog id="lightbox"><button type="button" aria-label="Close">×</button><img alt="Selected UI evidence"></dialog>
<script>
const search=document.querySelector('#search'), kind=document.querySelector('#kind'), verdict=document.querySelector('#verdict');
verdict.value='{initial_verdict}';
function applyFilters(){{const query=search.value.trim().toLowerCase();document.querySelectorAll('.evidence-section').forEach(section=>{{const kindOK=kind.value==='all'||section.dataset.kind===kind.value;let visible=0;section.querySelectorAll('figure').forEach(figure=>{{const statusOK=verdict.value==='all'||figure.dataset.status===verdict.value||(verdict.value==='actionable'&&figure.dataset.status!=='accepted');const queryOK=!query||(section.dataset.search+' '+figure.dataset.search).includes(query);figure.hidden=!(kindOK&&statusOK&&queryOK);if(!figure.hidden)visible++;}});const empty=section.querySelector('.empty');if(empty)empty.hidden=!(kindOK&&(!query||section.dataset.search.includes(query)));section.hidden=!kindOK||(section.querySelectorAll('figure').length>0?visible===0:empty?.hidden);}});}}
[search,kind,verdict].forEach(control=>control.addEventListener('input',applyFilters));
const lightbox=document.querySelector('#lightbox'), lightboxImage=lightbox.querySelector('img');
function setImageAvailability(image,available){{const stage=image.closest('.image-stage'),message=stage.querySelector('.image-error');stage.classList.toggle('image-failed',!available);message.hidden=available;}}
document.querySelectorAll('.image-button img').forEach(image=>{{image.addEventListener('load',()=>setImageAvailability(image,true));image.addEventListener('error',()=>setImageAvailability(image,false));if(image.complete)setImageAvailability(image,image.naturalWidth>0);}});
document.querySelectorAll('.image-button').forEach(button=>button.addEventListener('click',event=>{{const stage=button.closest('.image-stage'), image=button.querySelector('img');if(stage.classList.contains('annotating')){{event.preventDefault();addAnnotation(event,button.closest('figure'));return;}}if(image.hidden)return;lightboxImage.src=image.src;lightboxImage.alt=image.alt;lightbox.showModal();}}));
lightbox.querySelector('button').addEventListener('click',()=>lightbox.close());lightbox.addEventListener('click',event=>{{if(event.target===lightbox)lightbox.close();}});
document.querySelectorAll('.compare-controls button').forEach(control=>control.addEventListener('click',()=>{{const stage=control.closest('.image-stage'),image=stage.querySelector('img');stage.querySelectorAll('.compare-controls button').forEach(button=>button.classList.toggle('active',button===control));image.src=control.dataset.mode==='baseline'?stage.dataset.baseline:control.dataset.mode==='diff'?stage.dataset.diff:stage.dataset.current;}}));
const storageKey='threading-ui-'+document.body.dataset.mode+'-'+document.body.dataset.platform+'-{identity}';
let decisions={{}}, annotations=[];
try{{const saved=JSON.parse(localStorage.getItem(storageKey)||'null');if(document.body.dataset.mode==='regression')decisions=saved||{{}};else annotations=Array.isArray(saved)?saved:[];}}catch(error){{}}
function persist(){{localStorage.setItem(storageKey,JSON.stringify(document.body.dataset.mode==='regression'?decisions:annotations));}}
function download(name,payload){{const blob=new Blob([JSON.stringify(payload,null,2)+'\\n'],{{type:'application/json'}}),link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000);}}
function renderDecisions(){{document.querySelectorAll('.decision-controls').forEach(group=>{{const figure=group.closest('figure'),selected=decisions[figure.dataset.artifactId]?.decision;group.querySelectorAll('button').forEach(button=>button.classList.toggle('active',button.dataset.decision===selected));}});}}
document.querySelectorAll('.decision-controls button').forEach(button=>button.addEventListener('click',()=>{{const figure=button.closest('figure');decisions[figure.dataset.artifactId]={{artifactID:figure.dataset.artifactId,currentSHA256:figure.dataset.currentSha256,baselineRelative:figure.dataset.baselineRelative,comparison:figure.dataset.status,decision:button.dataset.decision}};persist();renderDecisions();}}));
function renderAnnotations(){{document.querySelectorAll('.annotation-marker').forEach(marker=>marker.remove());document.querySelectorAll('.annotation-list').forEach(list=>list.replaceChildren());annotations.forEach((annotation,index)=>{{const figure=document.querySelector(`figure[data-artifact-id="${{CSS.escape(annotation.artifactID)}}"]`);if(!figure)return;const item=document.createElement('li'),isCurrent=annotation.currentSHA256===figure.dataset.currentSha256;item.textContent=`${{isCurrent?'':'Stale image · '}}${{annotation.severity}}: ${{annotation.description}}`;const remove=document.createElement('button');remove.type='button';remove.textContent='Remove';remove.addEventListener('click',()=>{{annotations.splice(index,1);persist();renderAnnotations();}});item.append(remove);figure.querySelector('.annotation-list').append(item);if(!isCurrent)return;const marker=document.createElement('span');marker.className='annotation-marker';marker.textContent=String(index+1);marker.style.left=`${{annotation.x*100}}%`;marker.style.top=`${{annotation.y*100}}%`;figure.querySelector('.image-stage').append(marker);}});}}
function addAnnotation(event,figure){{const image=figure.querySelector('.image-button img'),rect=image.getBoundingClientRect();figure.querySelector('.image-stage').classList.remove('annotating');const description=prompt('What should change?');if(!description?.trim())return;let severity=(prompt('Severity: polish, important, or critical','polish')||'polish').trim().toLowerCase();if(!['polish','important','critical'].includes(severity))severity='polish';annotations.push({{artifactID:figure.dataset.artifactId,currentSHA256:figure.dataset.currentSha256,x:Math.max(0,Math.min(1,(event.clientX-rect.left)/rect.width)),y:Math.max(0,Math.min(1,(event.clientY-rect.top)/rect.height)),description:description.trim(),severity,status:'open'}});persist();renderAnnotations();}}
document.querySelectorAll('.annotate').forEach(button=>button.addEventListener('click',()=>{{const stage=button.closest('figure').querySelector('.image-stage');document.querySelectorAll('.image-stage.annotating').forEach(other=>other.classList.remove('annotating'));stage.classList.add('annotating');button.textContent='Click a point on the image';}}));
async function importJSON(file,kind){{const payload=JSON.parse(await file.text());if(payload.schemaVersion!==1||payload.kind!==kind)throw new Error('Unsupported file');if(payload.reportID!=='{identity}'||payload.platform!==document.body.dataset.platform)throw new Error('This file belongs to a different report or platform');return payload;}}
document.querySelector('#export-decisions')?.addEventListener('click',()=>{{const actionable=[...document.querySelectorAll('figure')].filter(figure=>figure.dataset.status!=='accepted');const missing=actionable.filter(figure=>!decisions[figure.dataset.artifactId]);if(missing.length&&!confirm(`${{missing.length}} image(s) have no decision. Export the partial review?`))return;download('decisions.json',{{schemaVersion:1,kind:'threading-ui-evidence-decisions',reportID:'{identity}',platform:document.body.dataset.platform,decisions:Object.values(decisions)}});}});
document.querySelector('#import-decisions')?.addEventListener('change',async event=>{{try{{const payload=await importJSON(event.target.files[0],'threading-ui-evidence-decisions');decisions=Object.fromEntries(payload.decisions.map(item=>[item.artifactID,item]));persist();renderDecisions();}}catch(error){{alert(error.message);}}}});
document.querySelector('#export-annotations')?.addEventListener('click',()=>download('annotations.json',{{schemaVersion:1,kind:'threading-ui-evidence-annotations',reportID:'{identity}',platform:document.body.dataset.platform,annotations}}));
document.querySelector('#import-annotations')?.addEventListener('change',async event=>{{try{{const payload=await importJSON(event.target.files[0],'threading-ui-evidence-annotations');annotations=payload.annotations;persist();renderAnnotations();}}catch(error){{alert(error.message);}}}});
renderDecisions();renderAnnotations();applyFilters();
</script></body></html>"""


def report_data(
    platform_name: str,
    entries: list[Entry],
    artifacts_by_entry: dict[str, list[Artifact]],
    fingerprint: dict[str, str],
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "threading-ui-evidence-report",
        "platform": platform_name,
        "reportID": report_identity([
            artifact for values in artifacts_by_entry.values() for artifact in values
        ]),
        "environment": fingerprint,
        "entries": [
            {
                "id": entry.identifier,
                "kind": entry.kind,
                "status": entry.status,
                "artifacts": [
                    {
                        "id": artifact.identifier,
                        "title": artifact.title,
                        "variant": artifact.variant,
                        "description": artifact.description,
                        "comparison": artifact.comparison,
                        "current": artifact.current_asset,
                        "baseline": artifact.baseline_asset,
                        "diff": artifact.diff_asset,
                        "baselineRelative": artifact.baseline_relative.as_posix(),
                        "currentSHA256": artifact.current_sha256,
                        "baselineSHA256": artifact.baseline_sha256,
                        "dimensions": list(artifact.dimensions) if artifact.dimensions else None,
                        "baselineDimensions": (
                            list(artifact.baseline_dimensions)
                            if artifact.baseline_dimensions else None
                        ),
                        "changedPixels": artifact.changed_pixels,
                        "totalPixels": artifact.total_pixels,
                        "differenceBounds": (
                            list(artifact.difference_bounds)
                            if artifact.difference_bounds else None
                        ),
                    }
                    for artifact in artifacts_by_entry.get(entry.identifier, [])
                ],
            }
            for entry in entries
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--list-tests", action="store_true")
    parser.add_argument("--current", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--journey-evidence", action="append", default=[], type=Path)
    parser.add_argument("--accept-new-baselines", action="store_true")
    parser.add_argument(
        "--only-entry",
        action="append",
        default=[],
        help="Include only this coverage entry; repeatable or comma-separated.",
    )
    parser.add_argument(
        "--require-accepted",
        action="store_true",
        help="Return non-zero unless every generated artifact exactly matches a baseline.",
    )
    parser.add_argument(
        "--environment",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Add deterministic capture environment information to the report.",
    )
    parser.add_argument(
        "--allow-missing-captures",
        action="store_true",
        help="Build a partial report and omit implemented entries with no current artifact.",
    )
    arguments = parser.parse_args()

    try:
        manifest_path = arguments.manifest.expanduser().resolve()
        title, platform_name, entries = load_manifest(manifest_path)
        requested_entries = {
            value.strip()
            for supplied in arguments.only_entry
            for value in supplied.split(",")
            if value.strip()
        }
        if requested_entries:
            known_entries = {entry.identifier for entry in entries}
            unknown = sorted(requested_entries - known_entries)
            if unknown:
                raise ValueError(f"unknown evidence entries: {', '.join(unknown)}")
            entries = [entry for entry in entries if entry.identifier in requested_entries]
        repository = manifest_path.parent.parent.parent
        for entry in entries:
            if entry.source_path and not (repository / entry.source_path).is_file():
                raise ValueError(f"{entry.identifier}: source file does not exist: {entry.source_path}")

        if arguments.list_tests:
            if any((arguments.current, arguments.output, arguments.journey_evidence)):
                raise ValueError("--list-tests cannot be combined with report inputs")
            seen: set[str] = set()
            for entry in entries:
                if entry.kind == "journey" or entry.status != "implemented":
                    continue
                for selector in entry.selectors:
                    if selector not in seen:
                        print(selector)
                        seen.add(selector)
            return 0

        if arguments.current is None or arguments.output is None:
            raise ValueError("--current and --output are required when building a report")
        current = arguments.current.expanduser().resolve()
        output = arguments.output.expanduser().resolve()
        baseline = arguments.baseline.expanduser().resolve() if arguments.baseline else None
        if not current.is_dir():
            raise ValueError(f"current evidence directory does not exist: {current}")
        if output.exists():
            raise ValueError(f"report output already exists: {output}")
        if baseline is not None and baseline.exists() and not baseline.is_dir():
            raise ValueError(f"baseline path is not a directory: {baseline}")
        fingerprint = {
            "platform": platform_name,
            "host": host_platform.platform(),
            "python": host_platform.python_version(),
        }
        for supplied in arguments.environment:
            key, separator, value = supplied.partition("=")
            if not separator or not key.strip() or not value.strip():
                raise ValueError("--environment values must use non-empty KEY=VALUE form")
            fingerprint[key.strip()] = value.strip()

        journey_documents = load_journey_documents([
            path.expanduser().resolve() for path in arguments.journey_evidence
        ])
        artifacts_by_entry: dict[str, list[Artifact]] = {}
        assigned_current: set[Path] = set()
        all_artifacts: list[Artifact] = []
        for entry in entries:
            artifacts: list[Artifact] = []
            if entry.status == "implemented" and entry.capture:
                if "metadata" in entry.capture:
                    artifacts = load_component_artifacts(entry, current)
                elif "glob" in entry.capture:
                    artifacts = load_glob_artifacts(
                        entry,
                        current,
                        allow_empty=arguments.allow_missing_captures,
                    )
                elif "journey" in entry.capture:
                    artifacts = load_journey_artifacts(entry, journey_documents)
            for artifact in artifacts:
                resolved = artifact.current.resolve()
                if resolved in assigned_current:
                    raise ValueError(f"image assigned to more than one evidence entry: {resolved}")
                assigned_current.add(resolved)
            artifacts_by_entry[entry.identifier] = artifacts
            all_artifacts.extend(artifacts)

        if arguments.allow_missing_captures:
            entries = [
                entry
                for entry in entries
                if entry.status != "implemented" or artifacts_by_entry[entry.identifier]
            ]

        local_pngs = {path.resolve() for path in current.rglob("*.png") if path.is_file()}
        unassigned = sorted(local_pngs - assigned_current)
        if unassigned:
            display = ", ".join(str(path.relative_to(current)) for path in unassigned[:8])
            suffix = "…" if len(unassigned) > 8 else ""
            raise ValueError(f"uncatalogued evidence images: {display}{suffix}")
        if len(all_artifacts) > MAXIMUM_ARTIFACTS:
            raise ValueError(f"evidence run exceeds the {MAXIMUM_ARTIFACTS}-image bound")

        accepted_count = compare_and_optionally_accept(
            all_artifacts, baseline, arguments.accept_new_baselines
        )
        output.mkdir(parents=True)
        stage_assets(all_artifacts, baseline, output)
        review_report = render_report(
            title,
            platform_name,
            entries,
            artifacts_by_entry,
            accepted_count,
            "review",
            fingerprint,
        )
        regression_report = render_report(
            title,
            platform_name,
            entries,
            artifacts_by_entry,
            accepted_count,
            "regression",
            fingerprint,
        )
        (output / "index.html").write_text(review_report, encoding="utf-8")
        (output / "review.html").write_text(review_report, encoding="utf-8")
        (output / "regression.html").write_text(regression_report, encoding="utf-8")
        (output / "evidence.json").write_text(
            json.dumps(
                report_data(platform_name, entries, artifacts_by_entry, fingerprint),
                indent=2,
                sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
        print(output / "index.html")
        if arguments.require_accepted:
            unresolved = [
                artifact for artifact in all_artifacts if artifact.comparison != "accepted"
            ]
            if unresolved:
                print(
                    f"error: {len(unresolved)} UI evidence artifact(s) need approval; "
                    f"review {output / 'regression.html'}",
                    file=sys.stderr,
                )
                return 3
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: could not generate UI evidence report: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
