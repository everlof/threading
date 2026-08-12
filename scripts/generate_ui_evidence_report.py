#!/usr/bin/env python3
"""Build Threading's browsable component, surface, and journey evidence report."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import re
import shutil
import struct
import sys
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
    comparison: str = "new"
    dimensions: tuple[int, int] | None = None
    baseline_dimensions: tuple[int, int] | None = None


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


def load_manifest(path: Path) -> tuple[str, list[Entry]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read UI evidence manifest {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"unsupported UI evidence manifest schema in {path}")
    title = require_text(payload, "title", "manifest")
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
    return title, entries


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


def load_glob_artifacts(entry: Entry, current: Path) -> list[Artifact]:
    assert entry.capture is not None
    pattern = entry.capture["glob"]
    if Path(pattern).is_absolute() or ".." in Path(pattern).parts:
        raise ValueError(f"{entry.identifier}: unsafe capture glob {pattern!r}")
    images = sorted(path for path in current.glob(pattern) if path.is_file())
    if not images:
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


def compare_and_optionally_accept(
    artifacts: list[Artifact],
    baseline: Path | None,
    accept_new: bool,
) -> int:
    accepted = 0
    if accept_new and baseline is None:
        raise ValueError("--accept-new-baselines requires --baseline")
    for artifact in artifacts:
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
        artifact.comparison = (
            "accepted" if sha256(artifact.current) == sha256(baseline_image) else "changed"
        )
    return accepted


def copy_asset(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256(source) != sha256(destination):
            raise ValueError(f"two different artifacts map to {destination}")
        return
    shutil.copy2(source, destination)


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


def render_matrix(entry: Entry) -> str:
    rows = []
    for key, values in entry.matrix.items():
        rows.append(
            f"<div><dt>{html.escape(key.title())}</dt>"
            f"<dd>{html.escape(' · '.join(values))}</dd></div>"
        )
    return f'<dl class="matrix">{"".join(rows)}</dl>'


def render_artifact(artifact: Artifact) -> str:
    assert artifact.current_asset is not None
    current = html.escape(artifact.current_asset)
    baseline = html.escape(artifact.baseline_asset or "")
    controls = ""
    baseline_image = ""
    if artifact.baseline_asset:
        controls = (
            '<div class="compare-controls" role="group" aria-label="Image comparison">'
            '<button type="button" data-mode="current" class="active">Current</button>'
            '<button type="button" data-mode="baseline">Baseline</button>'
            '<button type="button" data-mode="diff">Diff</button></div>'
        )
        baseline_image = f'data-baseline="{baseline}"'
    result = f" · {html.escape(artifact.result)}" if artifact.result else ""
    dimensions = ""
    if artifact.dimensions:
        dimensions = f"{artifact.dimensions[0]}×{artifact.dimensions[1]} px"
    return (
        f'<figure data-status="{html.escape(artifact.comparison)}" '
        f'data-search="{html.escape((artifact.title + " " + artifact.variant + " " + artifact.description).lower())}">'
        f'<div class="image-stage" data-current="{current}" {baseline_image}>'
        f'<button class="image-button" type="button" aria-label="Enlarge {html.escape(artifact.title)}">'
        f'<img src="{current}" loading="lazy" alt="{html.escape(artifact.title + ": " + artifact.variant)}">'
        '<canvas hidden></canvas></button>'
        f'{controls}</div><figcaption>'
        f'<div class="caption-line"><span class="variant">{html.escape(artifact.variant)}</span>'
        f'<span class="verdict {html.escape(artifact.comparison)}">{html.escape(artifact.comparison.title())}{result}</span></div>'
        f'<h3>{html.escape(artifact.title)}</h3>'
        f'<p>{html.escape(artifact.description)}</p>'
        f'<small>{html.escape(dimensions)}</small></figcaption></figure>'
    )


def render_report(
    title: str,
    entries: list[Entry],
    artifacts_by_entry: dict[str, list[Artifact]],
    accepted_count: int,
) -> str:
    all_artifacts = [artifact for values in artifacts_by_entry.values() for artifact in values]
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
        figures = "".join(render_artifact(artifact) for artifact in artifacts)
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
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
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
.image-stage {{ position:relative; background:#080a0d; }} .image-button {{ display:block; width:100%; padding:0; border:0; background:transparent; cursor:zoom-in; }}
.image-button img,.image-button canvas {{ display:block; width:100%; height:auto; }} .compare-controls {{ display:flex; gap:3px; position:absolute; right:9px; bottom:9px; padding:3px; border-radius:8px; background:#090c11dd; backdrop-filter:blur(8px); }}
.compare-controls button {{ padding:4px 7px; color:#dce3ec; border:0; border-radius:5px; background:transparent; cursor:pointer; font-size:11px; }} .compare-controls button.active {{ background:#ffffff25; color:white; }}
figcaption {{ padding:14px 16px 16px; }} .caption-line {{ display:flex; justify-content:space-between; gap:12px; align-items:center; }} .variant {{ color:var(--accent); font-size:12px; font-weight:700; }}
.verdict {{ padding:2px 7px; border-radius:999px; background:var(--raised); font-size:11px; font-weight:700; }} .verdict.accepted {{ color:var(--pass); }} .verdict.changed {{ color:var(--change); }} .verdict.new,.verdict.unbaselined {{ color:var(--new); }}
h3 {{ margin:5px 0 4px; font-size:17px; }} figcaption p {{ margin:0; color:var(--muted); }} figcaption small {{ display:block; margin-top:8px; color:#707b89; }}
.empty {{ grid-column:1/-1; padding:18px; border:1px dashed var(--line); border-radius:10px; color:var(--muted); }} .empty strong {{ color:var(--text); }} .empty p {{ margin:4px 0 0; }}
dialog {{ width:min(96vw,1800px); max-width:none; padding:0; border:1px solid var(--line); border-radius:12px; background:#080a0d; color:var(--text); }} dialog::backdrop {{ background:#000d; }} dialog img {{ display:block; max-width:94vw; max-height:90vh; }} dialog button {{ position:fixed; top:14px; right:18px; width:38px; height:38px; border:1px solid #fff5; border-radius:20px; background:#111d; color:white; font-size:22px; cursor:pointer; }}
[hidden] {{ display:none !important; }}
@media(max-width:840px) {{ .layout {{ display:block; }} aside {{ position:relative; width:auto; height:auto; border-right:0; border-bottom:1px solid var(--line); }} nav {{ grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); }} main {{ padding-top:24px; }} }}
</style>
</head>
<body><div class="layout"><aside><h1>{html.escape(title)}</h1><p>{len(all_artifacts)} reviewable images</p>
<div class="filters"><input id="search" type="search" placeholder="Filter features and images" aria-label="Filter evidence">
<select id="kind" aria-label="Evidence kind"><option value="all">All evidence</option><option value="component">Components</option><option value="surface">Surfaces</option><option value="journey">Journeys</option></select>
<select id="verdict" aria-label="Comparison result"><option value="all">All comparisons</option><option value="accepted">Accepted</option><option value="changed">Changed</option><option value="new">New</option><option value="unbaselined">No baseline configured</option></select></div>
<nav>{''.join(navigation)}</nav><div class="summary"><div>{implemented} implemented · {planned} planned</div><div>{counts['accepted']} accepted · {counts['changed']} changed · {counts['new']} new</div><div>{counts['unbaselined']} without baseline{html.escape(acceptance_note)}</div><div>{html.escape(generated)}</div></div></aside>
<main><header class="run-header"><h1>UI evidence catalogue</h1><p>Components, complete surfaces and critical user promises in one reviewable report.</p></header>{''.join(sections)}</main></div>
<dialog id="lightbox"><button type="button" aria-label="Close">×</button><img alt="Selected UI evidence"></dialog>
<script>
const search=document.querySelector('#search'), kind=document.querySelector('#kind'), verdict=document.querySelector('#verdict');
function applyFilters(){{const query=search.value.trim().toLowerCase();document.querySelectorAll('.evidence-section').forEach(section=>{{const kindOK=kind.value==='all'||section.dataset.kind===kind.value;let visible=0;section.querySelectorAll('figure').forEach(figure=>{{const statusOK=verdict.value==='all'||figure.dataset.status===verdict.value;const queryOK=!query||(section.dataset.search+' '+figure.dataset.search).includes(query);figure.hidden=!(kindOK&&statusOK&&queryOK);if(!figure.hidden)visible++;}});const empty=section.querySelector('.empty');if(empty)empty.hidden=!(kindOK&&(!query||section.dataset.search.includes(query)));section.hidden=!kindOK||(section.querySelectorAll('figure').length>0?visible===0:empty?.hidden);}});}}
[search,kind,verdict].forEach(control=>control.addEventListener('input',applyFilters));
const lightbox=document.querySelector('#lightbox'), lightboxImage=lightbox.querySelector('img');
document.querySelectorAll('.image-button').forEach(button=>button.addEventListener('click',()=>{{const stage=button.closest('.image-stage'), image=button.querySelector('img');if(image.hidden)return;lightboxImage.src=image.src;lightboxImage.alt=image.alt;lightbox.showModal();}}));
lightbox.querySelector('button').addEventListener('click',()=>lightbox.close());lightbox.addEventListener('click',event=>{{if(event.target===lightbox)lightbox.close();}});
function loadImage(url){{return new Promise((resolve,reject)=>{{const image=new Image();image.onload=()=>resolve(image);image.onerror=reject;image.src=url;}});}}
async function drawDiff(stage){{const current=await loadImage(stage.dataset.current), baseline=await loadImage(stage.dataset.baseline), canvas=stage.querySelector('canvas'), context=canvas.getContext('2d',{{willReadFrequently:true}}), width=Math.max(current.naturalWidth,baseline.naturalWidth), height=Math.max(current.naturalHeight,baseline.naturalHeight);canvas.width=width;canvas.height=height;context.clearRect(0,0,width,height);context.drawImage(current,0,0);const a=context.getImageData(0,0,width,height);context.clearRect(0,0,width,height);context.drawImage(baseline,0,0);const b=context.getImageData(0,0,width,height), out=context.createImageData(width,height);for(let index=0;index<out.data.length;index+=4){{out.data[index]=Math.min(255,Math.abs(a.data[index]-b.data[index])*4);out.data[index+1]=Math.min(255,Math.abs(a.data[index+1]-b.data[index+1])*4);out.data[index+2]=Math.min(255,Math.abs(a.data[index+2]-b.data[index+2])*4);out.data[index+3]=255;}}context.putImageData(out,0,0);return canvas;}}
document.querySelectorAll('.compare-controls button').forEach(control=>control.addEventListener('click',async()=>{{const stage=control.closest('.image-stage'), image=stage.querySelector('img'), canvas=stage.querySelector('canvas');stage.querySelectorAll('.compare-controls button').forEach(button=>button.classList.toggle('active',button===control));if(control.dataset.mode==='diff'){{image.hidden=true;canvas.hidden=false;try{{await drawDiff(stage);}}catch(error){{canvas.hidden=true;image.hidden=false;}}}}else{{canvas.hidden=true;image.hidden=false;image.src=control.dataset.mode==='baseline'?stage.dataset.baseline:stage.dataset.current;}}}}));
</script></body></html>"""


def report_data(entries: list[Entry], artifacts_by_entry: dict[str, list[Artifact]]) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "threading-ui-evidence-report",
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
    arguments = parser.parse_args()

    try:
        manifest_path = arguments.manifest.expanduser().resolve()
        title, entries = load_manifest(manifest_path)
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
                    artifacts = load_glob_artifacts(entry, current)
                elif "journey" in entry.capture:
                    artifacts = load_journey_artifacts(entry, journey_documents)
            for artifact in artifacts:
                resolved = artifact.current.resolve()
                if resolved in assigned_current:
                    raise ValueError(f"image assigned to more than one evidence entry: {resolved}")
                assigned_current.add(resolved)
            artifacts_by_entry[entry.identifier] = artifacts
            all_artifacts.extend(artifacts)

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
        (output / "index.html").write_text(
            render_report(title, entries, artifacts_by_entry, accepted_count),
            encoding="utf-8",
        )
        (output / "evidence.json").write_text(
            json.dumps(report_data(entries, artifacts_by_entry), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(output / "index.html")
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: could not generate UI evidence report: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
