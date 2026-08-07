#!/usr/bin/env python3
"""Build and validate the historical chrome evidence and conformance archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from html import escape
from pathlib import Path
from urllib.parse import quote, urlsplit

try:
    from PIL import Image, ImageChops, ImageStat
except ImportError:  # pragma: no cover - reported only when extraction is requested
    Image = None
    ImageChops = None
    ImageStat = None

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_ROOT = ROOT / "docs" / "references" / "chrome"
CACHE_ROOT = REFERENCE_ROOT / ".cache"
GENERATED_ROOT = REFERENCE_ROOT / ".generated"
IMPLEMENTATION_CATALOG = REFERENCE_ROOT / "implementation-sources.json"
COMPONENTS = (
    "window_frame", "title_bar", "window_buttons", "toolbar", "buttons",
    "choice_controls", "fields", "menus", "popovers", "scrollbars",
    "lists_tables", "progress", "alerts_toasts", "typography", "icons",
)
STATES = {"missing", "source_found", "measured", "verified", "not_applicable"}
REPRODUCTION_MODES = {"component_fixture", "exact_reconstruction"}
REVIEW_STATES = {"pending", "mismatch", "verified"}
REPRODUCTION_FIXTURES = {
    "retro-caption-glyph-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroCaptionGlyphFamily"
    ),
    "retro-scrollbar-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroScrollbarFamily"
    ),
    "retro-menu-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroMenuFamily"
    ),
    "retro-button-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroButtonFamily"
    ),
    "retro-choice-control-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroRequesterControlFamily"
    ),
    "retro-field-family": (
        "ThreadingTests/WindowChromeComponentTests/"
        "testRendersEveryRetroRequesterControlFamily"
    ),
    "alert-requester-amiga-workbench-31": (
        "ThreadingTests/ThemedPresentationTests/"
        "testClassicRequesterMaterialDropsModernStatusIcon"
    ),
}
STATE_LABELS = {
    "missing": "Missing",
    "source_found": "Source found",
    "measured": "Measured",
    "verified": "Verified",
    "not_applicable": "Not applicable",
}


def manifests() -> list[Path]:
    return sorted(REFERENCE_ROOT.glob("*/reference.json"))


def load(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_implementation_catalog() -> list[str]:
    errors: list[str] = []
    try:
        data = load(IMPLEMENTATION_CATALOG)
    except (OSError, json.JSONDecodeError) as error:
        return [f"{IMPLEMENTATION_CATALOG.relative_to(ROOT)}: {error}"]
    prefix = IMPLEMENTATION_CATALOG.relative_to(ROOT)
    if data.get("schema_version") != 1:
        errors.append(f"{prefix}: schema_version must be 1")
    chrome_ids = {path.parent.name for path in manifests()}
    implementation_ids: set[str] = set()
    for implementation in data.get("implementations", []):
        implementation_id = implementation.get("id")
        if not implementation_id or implementation_id in implementation_ids:
            errors.append(f"{prefix}: implementation ids must be present and unique")
        implementation_ids.add(implementation_id)
        targets = implementation.get("chrome_ids")
        if not isinstance(targets, list) or not targets:
            errors.append(f"{prefix}: {implementation_id} must name chrome_ids")
        elif unknown := sorted(set(targets) - chrome_ids):
            errors.append(f"{prefix}: {implementation_id} names unknown chromes {unknown}")
        revision = implementation.get("revision")
        if (
            not isinstance(revision, str)
            or len(revision) != 40
            or any(character not in "0123456789abcdef" for character in revision)
        ):
            errors.append(f"{prefix}: {implementation_id} needs a pinned git revision")
        if not implementation.get("repository_url") or not implementation.get("license_spdx"):
            errors.append(f"{prefix}: {implementation_id} lacks repository/license provenance")
        files = implementation.get("files")
        if not isinstance(files, list) or not files:
            errors.append(f"{prefix}: {implementation_id} must import at least one file")
            continue
        file_paths: set[str] = set()
        for source in files:
            relative = source.get("path")
            if (
                not isinstance(relative, str)
                or not relative
                or Path(relative).is_absolute()
                or ".." in Path(relative).parts
                or relative in file_paths
            ):
                errors.append(f"{prefix}: {implementation_id} has an unsafe/duplicate file path")
            file_paths.add(relative)
            if not source.get("url"):
                errors.append(f"{prefix}: {implementation_id}/{relative} lacks a URL")
            digest = source.get("sha256")
            if (
                not isinstance(digest, str)
                or len(digest) != 64
                or any(character not in "0123456789abcdef" for character in digest)
            ):
                errors.append(f"{prefix}: {implementation_id}/{relative} has invalid sha256")
    return errors


def validate_manifest(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        data = load(path)
    except (OSError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"]
    prefix = path.relative_to(ROOT)
    if data.get("schema_version") != 2:
        errors.append(f"{prefix}: schema_version must be 2")
    if data.get("chrome_id") != path.parent.name:
        errors.append(f"{prefix}: chrome_id must match its directory")
    coverage = data.get("coverage", {})
    if set(coverage) != set(COMPONENTS):
        missing = sorted(set(COMPONENTS) - set(coverage))
        extra = sorted(set(coverage) - set(COMPONENTS))
        errors.append(f"{prefix}: coverage mismatch; missing={missing}, extra={extra}")
    for component, evidence in coverage.items():
        if not isinstance(evidence, dict) or evidence.get("status") not in STATES:
            errors.append(f"{prefix}: {component} has an invalid evidence status")
        if not isinstance(evidence, dict) or not evidence.get("note"):
            errors.append(f"{prefix}: {component} must explain its status")
    sources = data.get("sources", [])
    source_ids = {source.get("id") for source in sources}
    if None in source_ids or len(source_ids) != len(sources):
        errors.append(f"{prefix}: source ids must be present and unique")
    for source in sources:
        if not source.get("page_url") or not source.get("owner"):
            errors.append(f"{prefix}: source {source.get('id')} lacks provenance")
        if source.get("storage") not in {"remote_only", "redistributable", "project_owned"}:
            errors.append(f"{prefix}: source {source.get('id')} has invalid storage")
        if source.get("storage") == "redistributable" and not source.get("license"):
            errors.append(f"{prefix}: redistributable source {source.get('id')} needs a license")
        digest = source.get("sha256")
        if digest and (len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)):
            errors.append(f"{prefix}: source {source.get('id')} has invalid sha256")
        pdf_page = source.get("pdf_page")
        render_dpi = source.get("render_dpi")
        if pdf_page is not None:
            if not isinstance(pdf_page, int) or pdf_page < 1:
                errors.append(f"{prefix}: source {source.get('id')} has an invalid pdf_page")
            if not isinstance(render_dpi, int) or render_dpi < 36:
                errors.append(f"{prefix}: source {source.get('id')} needs render_dpi >= 36")
        elif render_dpi is not None:
            errors.append(f"{prefix}: source {source.get('id')} has render_dpi without pdf_page")
    crop_ids: set[str] = set()
    crop_components: dict[str, str] = {}
    crop_roles: dict[str, str] = {}
    cropped_components: set[str] = set()
    cropped_source_ids: set[str] = set()
    for crop in data.get("crops", []):
        crop_id = crop.get("id")
        if not crop_id or crop_id in crop_ids:
            errors.append(f"{prefix}: crop ids must be present and unique")
        crop_ids.add(crop_id)
        crop_role = crop.get("role", "comparison_target")
        if crop_role not in {"comparison_target", "supporting_context"}:
            errors.append(f"{prefix}: crop {crop_id} has an invalid role")
        elif crop_id:
            crop_roles[crop_id] = crop_role
        if crop.get("component") not in COMPONENTS:
            errors.append(f"{prefix}: crop {crop_id} names an unknown component")
        else:
            if crop_role == "comparison_target":
                cropped_components.add(crop["component"])
            if crop_id:
                crop_components[crop_id] = crop["component"]
        if crop.get("source_id") not in source_ids:
            errors.append(f"{prefix}: crop {crop_id} names an unknown source")
        else:
            cropped_source_ids.add(crop["source_id"])
        rect = crop.get("rect", {})
        if any(not isinstance(rect.get(key), int) for key in ("x", "y", "width", "height")):
            errors.append(f"{prefix}: crop {crop_id} has a non-integer rect")
        elif rect["x"] < 0 or rect["y"] < 0 or rect["width"] < 1 or rect["height"] < 1:
            errors.append(f"{prefix}: crop {crop_id} has an invalid rect")
    source_by_id = {source.get("id"): source for source in sources}
    for source_id in cropped_source_ids:
        source = source_by_id[source_id]
        if not source.get("asset_url") or not source.get("sha256"):
            errors.append(f"{prefix}: cropped source {source_id} must be fetchable and pinned")
        width = source.get("pixel_width")
        height = source.get("pixel_height")
        if not isinstance(width, int) or width < 1 or not isinstance(height, int) or height < 1:
            errors.append(f"{prefix}: cropped source {source_id} needs pixel dimensions")
    for component, evidence in coverage.items():
        if evidence.get("status") in {"measured", "verified"} and component not in cropped_components:
            errors.append(f"{prefix}: {component} is {evidence['status']} but has no exact crop")

    reproduction_ids: set[str] = set()
    verified_reproductions: dict[str, set[str]] = {}
    for reproduction in data.get("reproductions", []):
        reproduction_id = reproduction.get("id")
        component = reproduction.get("component")
        if not reproduction_id or reproduction_id in reproduction_ids:
            errors.append(f"{prefix}: reproduction ids must be present and unique")
        reproduction_ids.add(reproduction_id)
        if component not in COMPONENTS:
            errors.append(
                f"{prefix}: reproduction {reproduction_id} names an unknown component"
            )
        fixture_id = reproduction.get("fixture_id")
        if fixture_id not in REPRODUCTION_FIXTURES:
            errors.append(
                f"{prefix}: reproduction {reproduction_id} names an unknown fixture"
            )
        output = reproduction.get("output")
        if (
            not isinstance(output, str)
            or Path(output).name != output
            or not output.endswith(".png")
        ):
            errors.append(
                f"{prefix}: reproduction {reproduction_id} output must be a PNG filename"
            )
        if reproduction.get("comparison_mode") not in REPRODUCTION_MODES:
            errors.append(
                f"{prefix}: reproduction {reproduction_id} has an invalid comparison_mode"
            )
        review_status = reproduction.get("review_status")
        if review_status not in REVIEW_STATES:
            errors.append(
                f"{prefix}: reproduction {reproduction_id} has an invalid review_status"
            )
        scale = reproduction.get("scale")
        if not isinstance(scale, (int, float)) or isinstance(scale, bool) or scale <= 0:
            errors.append(f"{prefix}: reproduction {reproduction_id} needs a positive scale")
        if not reproduction.get("note"):
            errors.append(f"{prefix}: reproduction {reproduction_id} needs a note")
        linked_crop_ids = reproduction.get("reference_crop_ids")
        if not isinstance(linked_crop_ids, list) or not linked_crop_ids:
            errors.append(
                f"{prefix}: reproduction {reproduction_id} must link reference crops"
            )
            linked_crop_ids = []
        for linked_crop_id in linked_crop_ids:
            if linked_crop_id not in crop_ids:
                errors.append(
                    f"{prefix}: reproduction {reproduction_id} links unknown crop "
                    f"{linked_crop_id}"
                )
            elif crop_components.get(linked_crop_id) != component:
                errors.append(
                    f"{prefix}: reproduction {reproduction_id} links a crop from "
                    f"{crop_components.get(linked_crop_id)}, not {component}"
                )
            elif crop_roles.get(linked_crop_id) == "supporting_context":
                errors.append(
                    f"{prefix}: reproduction {reproduction_id} links supporting-context "
                    f"crop {linked_crop_id}"
                )
        if review_status == "verified":
            if reproduction.get("comparison_mode") != "exact_reconstruction":
                errors.append(
                    f"{prefix}: verified reproduction {reproduction_id} must be exact"
                )
            tolerance = reproduction.get("tolerance")
            if not isinstance(tolerance, dict) or not tolerance.get("method"):
                errors.append(
                    f"{prefix}: verified reproduction {reproduction_id} needs a tolerance"
                )
            maximum_rmse = tolerance.get("max_normalized_rgb_rmse") \
                if isinstance(tolerance, dict) else None
            if (
                not isinstance(maximum_rmse, (int, float))
                or isinstance(maximum_rmse, bool)
                or not 0 < maximum_rmse <= 1
            ):
                errors.append(
                    f"{prefix}: verified reproduction {reproduction_id} needs a "
                    "max_normalized_rgb_rmse in (0, 1]"
                )
            if not reproduction.get("reviewed_on"):
                errors.append(
                    f"{prefix}: verified reproduction {reproduction_id} needs reviewed_on"
                )
            verified_reproductions.setdefault(component, set()).update(linked_crop_ids)

    for component, evidence in coverage.items():
        if evidence.get("status") != "verified":
            continue
        component_crop_ids = {
            crop_id
            for crop_id, crop_component in crop_components.items()
            if crop_component == component
            and crop_roles.get(crop_id, "comparison_target") == "comparison_target"
        }
        if verified_reproductions.get(component, set()) != component_crop_ids:
            errors.append(
                f"{prefix}: verified {component} must have exact reviewed reproductions "
                "covering every reference crop"
            )
    return errors


def selected(chrome_id: str | None) -> list[Path]:
    paths = manifests()
    if chrome_id is None:
        return paths
    matches = [path for path in paths if path.parent.name == chrome_id]
    if not matches:
        raise SystemExit(f"unknown chrome id: {chrome_id}")
    return matches


def validate(chrome_id: str | None) -> None:
    paths = selected(chrome_id)
    errors = validate_implementation_catalog()
    errors.extend(error for path in paths for error in validate_manifest(path))
    output_owners: dict[str, str] = {}
    # Output filenames share one generated directory, so collision checks must remain global
    # even when a caller validates or reproduces only one chrome.
    for path in manifests():
        data = load(path)
        for reproduction in data.get("reproductions", []):
            output = reproduction.get("output")
            if not isinstance(output, str):
                continue
            owner = f"{data.get('chrome_id')}/{reproduction.get('id')}"
            if output in output_owners:
                errors.append(
                    f"{path.relative_to(ROOT)}: reproduction output {output} is also used by "
                    f"{output_owners[output]}"
                )
            else:
                output_owners[output] = owner
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"validated {len(paths)} chrome reference manifest(s)")


def import_implementations(chrome_id: str | None) -> None:
    validate(chrome_id)
    implementations = load(IMPLEMENTATION_CATALOG)["implementations"]
    if chrome_id is not None:
        implementations = [
            implementation for implementation in implementations
            if chrome_id in implementation["chrome_ids"]
        ]
        if not implementations:
            raise SystemExit(f"no implementation source recorded for chrome id: {chrome_id}")
    for implementation in implementations:
        destination_root = CACHE_ROOT / "implementations" / implementation["id"]
        for source in implementation["files"]:
            destination = destination_root / source["path"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            expected = source["sha256"]
            if (
                destination.exists()
                and hashlib.sha256(destination.read_bytes()).hexdigest() == expected
            ):
                print(f"imported {implementation['id']}/{source['path']} (cached)")
                continue
            print(f"importing {implementation['id']}/{source['path']}")
            request = urllib.request.Request(
                source["url"],
                headers={"User-Agent": "ThreadingChromeReference/1.0 (+local design audit)"},
            )
            with urllib.request.urlopen(request) as response, destination.open("wb") as handle:
                handle.write(response.read())
            actual = hashlib.sha256(destination.read_bytes()).hexdigest()
            if actual != expected:
                destination.unlink(missing_ok=True)
                raise SystemExit(
                    f"checksum mismatch for {implementation['id']}/{source['path']}: "
                    f"{actual} != {expected}"
                )


def source_path(chrome_id: str, source: dict) -> Path:
    filename = source.get("filename") or Path(source["asset_url"]).name
    return CACHE_ROOT / chrome_id / filename


def raster_source_path(chrome_id: str, source: dict) -> Path:
    """Return a raster source, rendering a pinned PDF page when requested."""
    source_file = source_path(chrome_id, source)
    page = source.get("pdf_page")
    if page is None:
        return source_file
    renderer = shutil.which("pdftoppm")
    if renderer is None:
        raise SystemExit("PDF reference extraction requires Poppler (`pdftoppm`)")
    dpi = source["render_dpi"]
    destination = source_file.with_name(
        f"{source_file.stem}-page-{page}-at-{dpi}dpi.png"
    )
    if destination.exists() and destination.stat().st_mtime >= source_file.stat().st_mtime:
        return destination
    destination_prefix = destination.with_suffix("")
    command = [
        renderer, "-f", str(page), "-l", str(page), "-singlefile",
        "-png", "-r", str(dpi), str(source_file), str(destination_prefix),
    ]
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip()
        raise SystemExit(f"could not render {source_file}: {detail}") from error
    return destination


def fetch(chrome_id: str | None) -> None:
    validate(chrome_id)
    for path in selected(chrome_id):
        data = load(path)
        current_id = data["chrome_id"]
        for source in data["sources"]:
            url = source.get("asset_url")
            if not url:
                continue
            destination = source_path(current_id, source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            expected = source.get("sha256")
            if (
                expected
                and destination.exists()
                and hashlib.sha256(destination.read_bytes()).hexdigest() == expected
            ):
                # Several sources may pin different pages of one PDF; download it once.
                print(f"cached {source['id']} <- {destination.relative_to(ROOT)}")
                continue
            print(f"fetching {source['id']} -> {destination.relative_to(ROOT)}")
            request = urllib.request.Request(
                url,
                headers={"User-Agent": "ThreadingChromeReference/1.0 (+local design audit)"},
            )
            with urllib.request.urlopen(request) as response, destination.open("wb") as handle:
                handle.write(response.read())
            actual = hashlib.sha256(destination.read_bytes()).hexdigest()
            if expected and actual != expected:
                destination.unlink(missing_ok=True)
                raise SystemExit(
                    f"checksum mismatch for {current_id}/{source['id']}: {actual} != {expected}"
                )


def extract(chrome_id: str | None) -> None:
    validate(chrome_id)
    if Image is None:
        raise SystemExit("extract requires Pillow (`python3 -m pip install Pillow`)")
    for path in selected(chrome_id):
        data = load(path)
        current_id = data["chrome_id"]
        sources = {source["id"]: source for source in data["sources"]}
        destination_root = GENERATED_ROOT / current_id
        destination_root.mkdir(parents=True, exist_ok=True)
        expected_crops = {f"{crop['id']}.png" for crop in data["crops"]}
        for stale_crop in destination_root.glob("*.png"):
            if stale_crop.name not in expected_crops:
                stale_crop.unlink()
        for crop in data["crops"]:
            source = sources[crop["source_id"]]
            source_file = raster_source_path(current_id, source)
            if not source_file.exists():
                raise SystemExit(f"missing {source_file}; run fetch {current_id} first")
            rect = crop["rect"]
            destination = destination_root / f"{crop['id']}.png"
            with Image.open(source_file) as source_image:
                expected_size = (source.get("pixel_width"), source.get("pixel_height"))
                if all(isinstance(value, int) for value in expected_size) and source_image.size != expected_size:
                    raise SystemExit(
                        f"source dimensions changed for {current_id}/{source['id']}: "
                        f"{source_image.width}x{source_image.height} != "
                        f"{expected_size[0]}x{expected_size[1]}"
                    )
                right = rect["x"] + rect["width"]
                bottom = rect["y"] + rect["height"]
                if right > source_image.width or bottom > source_image.height:
                    raise SystemExit(
                        f"crop {current_id}/{crop['id']} exceeds "
                        f"{source_image.width}x{source_image.height}"
                    )
                source_image.crop((rect["x"], rect["y"], right, bottom)).save(destination)
            print(destination.relative_to(ROOT))


def reproduce(chrome_id: str | None) -> None:
    """Render declared fixtures through the app's production design-system components."""
    validate(chrome_id)
    paths = selected(chrome_id)
    fixture_ids = sorted({
        reproduction["fixture_id"]
        for path in paths
        for reproduction in load(path).get("reproductions", [])
    })
    if not fixture_ids:
        print("no reproduction fixtures declared")
        return
    xcodebuild = shutil.which("xcodebuild")
    if xcodebuild is None:
        raise SystemExit("reproduce requires Xcode (`xcodebuild`)")
    destination = GENERATED_ROOT / "reproductions"
    destination.mkdir(parents=True, exist_ok=True)
    expected_outputs = {
        reproduction["output"]
        for path in paths
        for reproduction in load(path).get("reproductions", [])
    }
    if chrome_id is None:
        for stale_output in destination.glob("*.png"):
            if stale_output.name not in expected_outputs:
                stale_output.unlink()
    command = [
        xcodebuild,
        "test",
        "-quiet",
        "-project",
        str(ROOT / "Threading.xcodeproj"),
        "-scheme",
        "Threading",
        "-derivedDataPath",
        str(GENERATED_ROOT / ".derived-data"),
        "-destination",
        "platform=macOS",
    ]
    for fixture_id in fixture_ids:
        command.append("-only-testing:" + REPRODUCTION_FIXTURES[fixture_id])
    command.append("CODE_SIGNING_ALLOWED=NO")
    environment = os.environ.copy()
    environment["THREADING_RENDER_OUT"] = str(destination)
    started_at_ns = time.time_ns()
    print(
        f"rendering {len(fixture_ids)} project fixture(s) -> "
        f"{destination.relative_to(ROOT)}"
    )
    try:
        subprocess.run(command, check=True, env=environment)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"chrome reproduction render failed ({error.returncode})") from error

    # Hosted XCTest sanitizes arbitrary process environment on some Xcode releases. The render
    # tests deliberately have a stable NSTemporaryDirectory fallback, so collect only files
    # written by this invocation when the explicit directory did not reach the test process.
    fallback = Path(tempfile.gettempdir()) / "ThreadingRenders"
    for path in paths:
        for reproduction in load(path).get("reproductions", []):
            output = destination / reproduction["output"]
            fallback_output = fallback / reproduction["output"]
            if (
                fallback_output.exists()
                and fallback_output.stat().st_mtime_ns >= started_at_ns
            ):
                shutil.copy2(fallback_output, output)

    missing_or_stale: list[Path] = []
    for path in paths:
        for reproduction in load(path).get("reproductions", []):
            output = destination / reproduction["output"]
            if not output.exists() or output.stat().st_mtime_ns < started_at_ns:
                missing_or_stale.append(output)
    if missing_or_stale:
        rendered = "\n".join(
            f"- {path.relative_to(ROOT)}" for path in missing_or_stale
        )
        raise SystemExit(
            "declared reproduction outputs were not freshly rendered:\n" + rendered
        )
    dimension_errors: list[str] = []
    if Image is not None:
        for path in paths:
            data = load(path)
            for reproduction in data.get("reproductions", []):
                expected_size = exact_reproduction_size(data, reproduction)
                if expected_size is None:
                    continue
                output = destination / reproduction["output"]
                with Image.open(output) as rendered:
                    if rendered.size != expected_size:
                        dimension_errors.append(
                            f"- {output.relative_to(ROOT)} is "
                            f"{rendered.width}×{rendered.height}; expected "
                            f"{expected_size[0]}×{expected_size[1]}"
                        )
    if dimension_errors:
        raise SystemExit(
            "exact reproduction dimensions do not match their reference crops:\n"
            + "\n".join(dimension_errors)
        )
    comparison_errors: list[str] = []
    if Image is not None and ImageChops is not None and ImageStat is not None:
        for path in paths:
            data = load(path)
            current_id = data["chrome_id"]
            for reproduction in data.get("reproductions", []):
                if reproduction.get("review_status") != "verified":
                    continue
                maximum = reproduction["tolerance"]["max_normalized_rgb_rmse"]
                output = destination / reproduction["output"]
                for crop_id in reproduction["reference_crop_ids"]:
                    reference = GENERATED_ROOT / current_id / f"{crop_id}.png"
                    if not reference.exists():
                        comparison_errors.append(
                            f"- missing {reference.relative_to(ROOT)}; run extract {current_id}"
                        )
                        continue
                    with Image.open(reference) as historical, Image.open(output) as rendered:
                        difference = ImageChops.difference(
                            historical.convert("RGB"), rendered.convert("RGB")
                        )
                        channel_rms = ImageStat.Stat(difference).rms
                        normalized_rmse = math.sqrt(
                            sum(value * value for value in channel_rms) / len(channel_rms)
                        ) / 255
                    if normalized_rmse > maximum:
                        comparison_errors.append(
                            f"- {current_id}/{reproduction['id']} RGB RMSE "
                            f"{normalized_rmse:.6f} exceeds {maximum:.6f} against {crop_id}"
                        )
                    else:
                        print(
                            f"verified {current_id}/{reproduction['id']} RGB RMSE "
                            f"{normalized_rmse:.6f} <= {maximum:.6f}"
                        )
    if comparison_errors:
        raise SystemExit(
            "verified reproductions exceeded their recorded tolerance:\n"
            + "\n".join(comparison_errors)
        )
    print("rendered every declared reproduction output")


def report() -> None:
    validate(None)
    header = "chrome".ljust(25) + "verified measured found missing n/a repro reviewed"
    print(header)
    for path in manifests():
        data = load(path)
        counts = {state: 0 for state in STATES}
        for item in data["coverage"].values():
            counts[item["status"]] += 1
        reproductions = data.get("reproductions", [])
        reviewed = sum(item["review_status"] == "verified" for item in reproductions)
        print(
            data["chrome_id"].ljust(25)
            + f"{counts['verified']:>8} {counts['measured']:>8} "
            + f"{counts['source_found']:>5} {counts['missing']:>7} "
            + f"{counts['not_applicable']:>3} {len(reproductions):>5} {reviewed:>8}"
        )


def safe_web_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return "#"
    return escape(value, quote=True)


def humanize(value: str) -> str:
    return value.replace("_", " ").replace("-", " ").title()


def versioned_asset_path(local_path: str, asset_path: Path) -> str:
    """Fingerprint generated images so a refreshed file:// gallery cannot reuse old pixels."""
    if not asset_path.exists():
        return local_path
    digest = hashlib.sha256(asset_path.read_bytes()).hexdigest()[:12]
    return f"{local_path}?v={digest}"


def target_title(target: dict) -> str:
    """Join platform and release without repeating their overlapping words."""
    platform_words = target["platform"].split()
    release_words = target["release"].split()
    overlap = 0
    for length in range(1, min(len(platform_words), len(release_words)) + 1):
        if [word.casefold() for word in platform_words[-length:]] == [
            word.casefold() for word in release_words[:length]
        ]:
            overlap = length
    return " ".join(platform_words + release_words[overlap:])


def reference_crop_html(
    chrome_id: str,
    chrome_title: str,
    component: str,
    crop: dict,
    source: dict,
) -> str:
    rect = crop["rect"]
    local_path = f"{quote(chrome_id, safe='')}/{quote(crop['id'], safe='')}.png"
    versioned_path = versioned_asset_path(
        local_path,
        GENERATED_ROOT / chrome_id / f"{crop['id']}.png",
    )
    source_dimensions = f"{source.get('pixel_width', '?')}×{source.get('pixel_height', '?')}"
    source_kind = humanize(source.get("kind", "screenshot"))
    return (
        '<figure class="crop">'
        f'<a class="preview" href="{escape(versioned_path, quote=True)}" '
        f'target="_blank" title="Open {escape(crop["id"], quote=True)} at native size">'
        f'<img src="{escape(versioned_path, quote=True)}" '
        f'width="{rect["width"]}" height="{rect["height"]}" loading="lazy" '
        f'alt="{escape(chrome_title)} {escape(humanize(component))}: '
        f'{escape(humanize(crop["id"]))}"></a>'
        '<figcaption>'
        f'<strong>{escape(humanize(crop["id"]))}</strong>'
        f'<span class="pixels">{rect["width"]}×{rect["height"]} px crop</span>'
        '<dl>'
        f'<div><dt>Source</dt><dd><a href="{safe_web_url(source["page_url"])}" '
        f'target="_blank" rel="noreferrer">{escape(source["id"])}</a> '
        f'· {escape(source_kind)} · {escape(source["owner"])}</dd></div>'
        f'<div><dt>Original</dt><dd>{escape(source_dimensions)} px</dd></div>'
        f'<div><dt>Rect</dt><dd>x {rect["x"]}, y {rect["y"]}, '
        f'w {rect["width"]}, h {rect["height"]}</dd></div>'
        '</dl></figcaption></figure>'
    )


def exact_reproduction_size(data: dict, reproduction: dict) -> tuple[int, int] | None:
    if reproduction.get("comparison_mode") != "exact_reconstruction":
        return None
    crop_by_id = {crop["id"]: crop for crop in data["crops"]}
    sizes = {
        (
            int(crop_by_id[crop_id]["rect"]["width"] * reproduction["scale"]),
            int(crop_by_id[crop_id]["rect"]["height"] * reproduction["scale"]),
        )
        for crop_id in reproduction["reference_crop_ids"]
    }
    return next(iter(sizes)) if len(sizes) == 1 else None


def reproduction_html(reproduction: dict, expected_size: tuple[int, int] | None) -> str:
    output = reproduction["output"]
    output_path = GENERATED_ROOT / "reproductions" / output
    local_path = f"reproductions/{quote(output, safe='')}"
    versioned_path = versioned_asset_path(local_path, output_path)
    review_status = reproduction["review_status"]
    review_label = {
        "pending": "Review pending",
        "mismatch": "Mismatch recorded",
        "verified": "Verified match",
    }[review_status]
    actual_size: tuple[int, int] | None = None
    if output_path.exists() and Image is not None:
        with Image.open(output_path) as rendered:
            actual_size = rendered.size
    dimensions_match = expected_size is None or Image is None or actual_size == expected_size
    if output_path.exists() and dimensions_match:
        preview = (
            f'<a class="preview" href="{escape(versioned_path, quote=True)}" target="_blank" '
            f'title="Open {escape(output, quote=True)} at native size">'
            f'<img src="{escape(versioned_path, quote=True)}" loading="lazy" '
            f'alt="Threading reproduction {escape(reproduction["id"])}"></a>'
        )
        rendered_label = "Rendered locally"
    elif output_path.exists():
        preview = (
            '<div class="empty-crop reproduction-missing"><span>!</span>'
            f'Wrong render size: {actual_size[0]}×{actual_size[1]}; '
            f'expected {expected_size[0]}×{expected_size[1]}</div>'
        )
        rendered_label = "Dimension mismatch"
    else:
        preview = (
            '<div class="empty-crop reproduction-missing"><span>↻</span>'
            'Run <code>scripts/chrome_reference.py reproduce</code></div>'
        )
        rendered_label = "Fixture declared"
    crop_links = ", ".join(humanize(value) for value in reproduction["reference_crop_ids"])
    return (
        '<figure class="crop reproduction">'
        f'{preview}<figcaption><strong>{escape(humanize(reproduction["id"]))}</strong>'
        f'<span class="review-state {escape(review_status, quote=True)}">'
        f'{escape(review_label)}</span>'
        f'<p class="reproduction-note">{escape(reproduction["note"])}</p>'
        '<dl>'
        f'<div><dt>Fixture</dt><dd>{escape(reproduction["fixture_id"])}</dd></div>'
        f'<div><dt>Mode</dt><dd>{escape(humanize(reproduction["comparison_mode"]))} '
        f'· {reproduction["scale"]}× · {escape(rendered_label)}</dd></div>'
        f'<div><dt>Against</dt><dd>{escape(crop_links)}</dd></div>'
        '</dl></figcaption></figure>'
    )


def gallery_html() -> None:
    """Build an offline, searchable gallery from the reference manifests and crops."""
    validate(None)
    chrome_records: list[tuple[dict, Path]] = []
    missing_crops: list[Path] = []
    total_crops = 0
    total_reproductions = 0
    rendered_reproductions = 0
    for manifest_path in manifests():
        data = load(manifest_path)
        chrome_records.append((data, manifest_path))
        total_crops += len(data["crops"])
        total_reproductions += len(data.get("reproductions", []))
        rendered_reproductions += sum(
            (GENERATED_ROOT / "reproductions" / reproduction["output"]).exists()
            for reproduction in data.get("reproductions", [])
        )
        for crop in data["crops"]:
            crop_path = GENERATED_ROOT / data["chrome_id"] / f"{crop['id']}.png"
            if not crop_path.exists():
                missing_crops.append(crop_path)
    if missing_crops:
        preview = "\n".join(f"- {path.relative_to(ROOT)}" for path in missing_crops[:8])
        remainder = len(missing_crops) - 8
        suffix = f"\n- …and {remainder} more" if remainder > 0 else ""
        raise SystemExit(
            "gallery crops are missing; run `scripts/chrome_reference.py fetch` then "
            f"`scripts/chrome_reference.py extract` first:\n{preview}{suffix}"
        )

    body: list[str] = []
    nav: list[str] = []
    for data, _ in chrome_records:
        chrome_id = data["chrome_id"]
        target = data["target"]
        chrome_title = target_title(target)
        version = target.get("version", "")
        counts = {state: 0 for state in STATES}
        for evidence in data["coverage"].values():
            counts[evidence["status"]] += 1
        evidence_count = counts["measured"] + counts["verified"]
        crop_count = len(data["crops"])
        nav.append(
            f'<a href="#{escape(chrome_id, quote=True)}">'
            f'<span>{escape(chrome_title)}</span><small>{crop_count} crops</small></a>'
        )
        body.append(
            f'<section class="chrome" id="{escape(chrome_id, quote=True)}" '
            f'data-search="{escape((chrome_title + " " + version + " " + chrome_id).lower(), quote=True)}">'
            '<header class="chrome-header">'
            '<div><p class="eyebrow">Historical chrome</p>'
            f'<h2>{escape(chrome_title)}</h2>'
            f'<p class="version">{escape(version)} · <code>{escape(chrome_id)}</code></p></div>'
            '<div class="chrome-totals">'
            f'<strong>{evidence_count}<span>/ {len(COMPONENTS)}</span></strong>'
            '<small>components measured</small>'
            f'<span>{crop_count} exact crops</span>'
            '</div></header>'
            '<div class="coverage-strip" aria-label="Coverage summary">'
            f'<span class="verified">{counts["verified"]} verified</span>'
            f'<span class="measured">{counts["measured"]} measured</span>'
            f'<span class="source_found">{counts["source_found"]} source found</span>'
            f'<span class="missing">{counts["missing"]} missing</span>'
            f'<span class="not_applicable">{counts["not_applicable"]} n/a</span>'
            '</div>'
        )

        sources = {source["id"]: source for source in data["sources"]}
        body.append(
            f'<details class="sources"><summary>Source ledger <span>{len(sources)} preserved '
            f'source{"" if len(sources) == 1 else "s"}</span></summary><ul>'
        )
        for source in sources.values():
            source_kind = humanize(source.get("kind", "screenshot"))
            dimensions = (
                f'{source["pixel_width"]}×{source["pixel_height"]} px'
                if source.get("pixel_width") and source.get("pixel_height")
                else "dimensions not pinned"
            )
            if source.get("pdf_page"):
                dimensions += (
                    f' rendered from PDF page {source["pdf_page"]} '
                    f'at {source["render_dpi"]} dpi'
                )
            asset_link = (
                f' · <a href="{safe_web_url(source["asset_url"])}" target="_blank" '
                'rel="noreferrer">original asset</a>'
                if source.get("asset_url")
                else ""
            )
            checksum = (
                f' · <code>sha256:{escape(source["sha256"][:12])}…</code>'
                if source.get("sha256")
                else " · checksum not pinned"
            )
            body.append(
                '<li><div>'
                f'<a href="{safe_web_url(source["page_url"])}" target="_blank" '
                f'rel="noreferrer"><strong>{escape(source["id"])}</strong></a>{asset_link}'
                f'</div><p>{escape(source_kind)} · {escape(source["owner"])} · '
                f'{escape(source["storage"])} · '
                f'{escape(dimensions)}{checksum}</p></li>'
            )
        body.append('</ul></details>')
        crops_by_component: dict[str, list[dict]] = {component: [] for component in COMPONENTS}
        for crop in data["crops"]:
            crops_by_component[crop["component"]].append(crop)
        reproductions_by_component: dict[str, list[dict]] = {
            component: [] for component in COMPONENTS
        }
        for reproduction in data.get("reproductions", []):
            reproductions_by_component[reproduction["component"]].append(reproduction)

        body.append('<div class="component-grid">')
        for component in COMPONENTS:
            evidence = data["coverage"][component]
            status = evidence["status"]
            component_crops = crops_by_component[component]
            component_reproductions = reproductions_by_component[component]
            search_terms = " ".join(
                [chrome_title, chrome_id, component, status, evidence["note"]]
                + [crop["id"] for crop in component_crops]
                + [
                    term
                    for reproduction in component_reproductions
                    for term in (
                        reproduction["id"], reproduction["fixture_id"],
                        reproduction["review_status"], reproduction["note"],
                    )
                ]
            ).lower()
            body.append(
                f'<article class="component-card" data-status="{escape(status, quote=True)}" '
                f'data-search="{escape(search_terms, quote=True)}">'
                '<header class="component-header"><div>'
                f'<p class="component-name">{escape(humanize(component))}</p>'
                f'<span class="status {escape(status, quote=True)}">{escape(STATE_LABELS[status])}</span>'
                '</div>'
                f'<span class="crop-count">{len(component_crops)} crop'
                f'{"" if len(component_crops) == 1 else "s"}'
                f'{f" · {len(component_reproductions)} reproduction" if component_reproductions else ""}'
                f'{"s" if len(component_reproductions) > 1 else ""}</span></header>'
                f'<p class="evidence-note">{escape(evidence["note"])}</p>'
            )
            if not component_crops:
                empty_label = (
                    "No excerpt required for this system."
                    if status == "not_applicable"
                    else "No exact excerpt preserved yet."
                )
                body.append(f'<div class="empty-crop"><span>∅</span>{escape(empty_label)}</div>')
            if component_reproductions:
                crop_by_id = {crop["id"]: crop for crop in component_crops}
                linked_crop_ids = {
                    crop_id
                    for reproduction in component_reproductions
                    for crop_id in reproduction["reference_crop_ids"]
                }
                supporting_crops = [
                    crop for crop in component_crops if crop["id"] not in linked_crop_ids
                ]
                if supporting_crops:
                    body.append(
                        '<section class="supporting-evidence">'
                        '<p class="lane-label">Additional historical context</p>'
                    )
                    for crop in supporting_crops:
                        body.append(reference_crop_html(
                            chrome_id, chrome_title, component, crop,
                            sources[crop["source_id"]],
                        ))
                    body.append('</section>')
                for reproduction in component_reproductions:
                    body.append(
                        '<div class="comparison-grid"><section class="comparison-lane">'
                        '<p class="lane-label">Historical reference</p>'
                    )
                    for crop_id in reproduction["reference_crop_ids"]:
                        crop = crop_by_id[crop_id]
                        body.append(reference_crop_html(
                            chrome_id, chrome_title, component, crop,
                            sources[crop["source_id"]],
                        ))
                    body.append(
                        '</section><section class="comparison-lane implementation">'
                        '<p class="lane-label">Threading reproduction</p>'
                    )
                    body.append(reproduction_html(
                        reproduction,
                        exact_reproduction_size(data, reproduction),
                    ))
                    body.append('</section></div>')
            elif component_crops:
                for crop in component_crops:
                    source = sources[crop["source_id"]]
                    body.append(reference_crop_html(
                        chrome_id, chrome_title, component, crop, source
                    ))
            body.append('</article>')
        body.append('</div></section>')

    html = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
  <link rel="icon" href="data:,">
  <title>Threading chrome reference excerpts</title>
  <style>
    :root {{ color-scheme: dark; --ink: #f3f0e8; --muted: #a8a49a; --panel: #171817;
      --line: #33342f; --accent: #efd26d; --page: #0d0e0d; }}
    * {{ box-sizing: border-box; }}
    html {{ scroll-behavior: smooth; }}
    body {{ margin: 0; background: var(--page); color: var(--ink); font: 14px/1.45
      ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    a {{ color: inherit; }}
    code {{ color: #c8c3b7; font-size: .9em; }}
    .masthead {{ padding: 48px clamp(20px, 5vw, 80px) 28px; border-bottom: 1px solid var(--line);
      background: radial-gradient(circle at 80% 10%, #332e1c 0, transparent 35%), #111210; }}
    .masthead .eyebrow, .chrome-header .eyebrow {{ color: var(--accent); font-size: 11px;
      font-weight: 800; letter-spacing: .14em; text-transform: uppercase; margin: 0 0 8px; }}
    h1 {{ margin: 0; font-size: clamp(34px, 5vw, 62px); letter-spacing: -.04em; line-height: 1; }}
    .lede {{ max-width: 780px; margin: 18px 0 0; color: #c8c3b7; font-size: 16px; }}
    .summary {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 22px; }}
    .summary span {{ padding: 7px 10px; background: #20211e; border: 1px solid #3a3b35; border-radius: 4px; }}
    .controls {{ position: sticky; top: 0; z-index: 20; display: flex; flex-wrap: wrap; gap: 10px;
      align-items: center; padding: 12px clamp(20px, 5vw, 80px); border-bottom: 1px solid var(--line);
      background: color-mix(in srgb, #111 92%, transparent); backdrop-filter: blur(12px); }}
    .controls input {{ min-width: min(360px, 100%); flex: 1; color: var(--ink); background: #080908;
      border: 1px solid #46473f; border-radius: 5px; padding: 10px 12px; font: inherit; }}
    button {{ color: var(--ink); background: #22231f; border: 1px solid #494a42; border-radius: 5px;
      padding: 9px 11px; font: inherit; cursor: pointer; }}
    button[aria-pressed="true"] {{ color: #17150c; background: var(--accent); border-color: var(--accent); }}
    .layout {{ display: grid; grid-template-columns: 230px minmax(0, 1fr); }}
    nav {{ position: sticky; top: 63px; align-self: start; height: calc(100vh - 63px); overflow: auto;
      padding: 22px 14px 60px; border-right: 1px solid var(--line); background: #10110f; }}
    nav a {{ display: flex; justify-content: space-between; gap: 12px; padding: 9px 10px;
      text-decoration: none; border-radius: 4px; }}
    nav a:hover {{ background: #22231f; }} nav small {{ color: var(--muted); white-space: nowrap; }}
    main {{ min-width: 0; padding: 0 clamp(18px, 4vw, 56px) 80px; }}
    .chrome {{ padding: 54px 0 28px; scroll-margin-top: 68px; border-bottom: 1px solid var(--line); }}
    .chrome-header {{ display: flex; justify-content: space-between; align-items: end; gap: 24px; }}
    .chrome-header h2 {{ font-size: clamp(26px, 4vw, 44px); letter-spacing: -.035em; line-height: 1;
      margin: 0; }} .version {{ color: var(--muted); margin: 10px 0 0; }}
    .chrome-totals {{ min-width: 180px; display: grid; justify-items: end; }}
    .chrome-totals strong {{ font-size: 32px; line-height: 1; }} .chrome-totals strong span {{ color: var(--muted); font-size: 16px; }}
    .chrome-totals small {{ color: var(--muted); }} .chrome-totals > span {{ color: var(--accent); margin-top: 6px; }}
    .coverage-strip {{ display: flex; flex-wrap: wrap; gap: 7px; margin: 22px 0; }}
    .coverage-strip span, .status {{ border: 1px solid currentColor; border-radius: 999px; padding: 3px 8px;
      font-size: 11px; font-weight: 750; letter-spacing: .03em; text-transform: uppercase; }}
    .verified {{ color: #7fe09a; }} .measured {{ color: #78c9ff; }} .source_found {{ color: #e5c565; }}
    .missing {{ color: #ff8a7e; }} .not_applicable {{ color: #93958f; }}
    .sources {{ margin: -5px 0 20px; border: 1px solid var(--line); border-radius: 6px; background: #111210; }}
    .sources summary {{ cursor: pointer; padding: 11px 13px; font-weight: 700; }}
    .sources summary span {{ color: var(--muted); margin-left: 7px; font-weight: 400; }}
    .sources ul {{ list-style: none; display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 330px), 1fr));
      gap: 1px; margin: 0; padding: 1px 0 0; background: var(--line); border-top: 1px solid var(--line); }}
    .sources li {{ min-width: 0; padding: 11px 13px; background: #151614; }}
    .sources li p {{ margin: 4px 0 0; color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }}
    .component-grid {{ display: grid; grid-template-columns: minmax(0, 1fr); gap: 14px; align-items: start; }}
    .component-card {{ min-width: 0; padding: 16px; background: var(--panel); border: 1px solid var(--line);
      border-radius: 7px; box-shadow: 0 10px 26px rgb(0 0 0 / 18%); }}
    .component-header {{ display: flex; justify-content: space-between; align-items: start; gap: 10px; }}
    .component-header > div {{ display: flex; align-items: center; gap: 9px; flex-wrap: wrap; }}
    .component-name {{ margin: 0; font-size: 16px; font-weight: 750; }} .crop-count {{ color: var(--muted); }}
    .evidence-note {{ min-height: 61px; color: #beb9ae; }}
    .comparison-grid {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }}
    .comparison-grid + .comparison-grid {{ margin-top: 14px; }}
    .supporting-evidence {{ margin-bottom: 14px; padding: 0 12px 12px; border: 1px dashed #3b3c36;
      border-radius: 5px; background: #121311; }}
    .comparison-lane {{ min-width: 0; padding: 0 12px 12px; border: 1px solid #30312d;
      border-radius: 5px; background: #121311; }}
    .comparison-lane.implementation {{ border-color: #534d2f; background: #15150f; }}
    .lane-label {{ margin: 0 -12px; padding: 8px 12px; color: var(--muted); border-bottom: 1px solid #30312d;
      font-size: 11px; font-weight: 800; letter-spacing: .1em; text-transform: uppercase; }}
    .implementation .lane-label {{ color: var(--accent); border-color: #534d2f; }}
    .empty-crop {{ display: flex; align-items: center; justify-content: center; gap: 10px; min-height: 116px;
      color: #888b83; border: 1px dashed #40413c; background: #111210; }}
    .empty-crop span {{ font-size: 22px; }}
    .crop {{ margin: 14px 0 0; border-top: 1px solid var(--line); padding-top: 14px; }}
    .preview {{ display: flex; align-items: center; justify-content: center; min-height: 118px; max-height: 360px;
      overflow: auto; border: 1px solid #3f403a; background-color: #b8b8b8;
      background-image: linear-gradient(45deg, #aaa 25%, transparent 25%),
        linear-gradient(-45deg, #aaa 25%, transparent 25%), linear-gradient(45deg, transparent 75%, #aaa 75%),
        linear-gradient(-45deg, transparent 75%, #aaa 75%); background-size: 16px 16px;
      background-position: 0 0, 0 8px, 8px -8px, -8px 0; }}
    .preview img {{ display: block; max-width: 100%; height: auto; object-fit: contain; image-rendering: auto; }}
    body.native .preview {{ justify-content: flex-start; align-items: flex-start; }}
    body.native .preview img {{ max-width: none; }}
    figcaption {{ position: relative; padding-top: 10px; }} figcaption > strong {{ display: block; padding-right: 110px; }}
    .pixels {{ position: absolute; right: 0; top: 10px; color: var(--accent); font: 12px ui-monospace, monospace; }}
    .review-state {{ position: absolute; right: 0; top: 10px; border: 1px solid currentColor;
      border-radius: 999px; padding: 2px 7px; font-size: 10px; font-weight: 800; text-transform: uppercase; }}
    .review-state.pending {{ color: #e5c565; }} .review-state.mismatch {{ color: #ff8a7e; }}
    .review-state.verified {{ color: #7fe09a; }}
    .reproduction-note {{ margin: 8px 0; color: #beb9ae; }}
    .reproduction-missing {{ margin-top: 14px; flex-direction: column; text-align: center; }}
    dl {{ margin: 8px 0 0; color: var(--muted); font-size: 12px; }} dl div {{ display: grid;
      grid-template-columns: 62px 1fr; gap: 8px; margin-top: 3px; }} dt {{ color: #777a72; }} dd {{ margin: 0; overflow-wrap: anywhere; }}
    .component-card[hidden], .chrome[hidden] {{ display: none; }}
    .no-results {{ display: none; padding: 80px 20px; text-align: center; color: var(--muted); }}
    .no-results.visible {{ display: block; }}
    footer {{ color: var(--muted); padding: 32px clamp(20px, 5vw, 80px); border-top: 1px solid var(--line); }}
    @media (max-width: 900px) {{ .comparison-grid {{ grid-template-columns: minmax(0, 1fr); }} }}
    @media (max-width: 760px) {{ .layout {{ display: block; }} nav {{ position: static; height: auto; display: flex;
      overflow-x: auto; border-right: 0; border-bottom: 1px solid var(--line); }} nav a {{ min-width: max-content; }}
      .chrome-header {{ align-items: start; }} .chrome-totals {{ min-width: 120px; }} }}
  </style>
</head>
<body>
  <header class="masthead">
    <p class="eyebrow">Evidence archive</p>
    <h1>Chrome reference excerpts</h1>
    <p class="lede">Exact, unscaled crops from pinned historical sources beside project-owned renders of the
      production components. Coverage and review states remain explicit, so a fixture cannot masquerade as a match.</p>
    <div class="summary"><span>{len(chrome_records)} historical chromes</span><span>{len(COMPONENTS)} components each</span>
      <span>{total_crops} exact crops</span><span>{rendered_reproductions}/{total_reproductions} reproductions rendered</span>
      <span>coordinates use source pixels</span></div>
  </header>
  <div class="controls" aria-label="Gallery controls">
    <input id="search" type="search" placeholder="Search chrome, component, crop, or evidence note…" aria-label="Search references">
    <button class="filter" data-status="all" aria-pressed="true">All</button>
    <button class="filter" data-status="verified" aria-pressed="false">Verified</button>
    <button class="filter" data-status="measured" aria-pressed="false">Measured</button>
    <button class="filter" data-status="source_found" aria-pressed="false">Source found</button>
    <button class="filter" data-status="missing" aria-pressed="false">Missing</button>
    <button class="filter" data-status="not_applicable" aria-pressed="false">N/A</button>
    <button id="native" aria-pressed="false">Native pixels</button>
  </div>
  <div class="layout">
    <nav aria-label="Chrome index">{''.join(nav)}</nav>
    <main>{''.join(body)}<p class="no-results" id="no-results">No reference components match those filters.</p></main>
  </div>
  <footer>Generated from <code>docs/references/chrome/*/reference.json</code>. Historical images link to their native
    crop; project images come from the real Threading design-system render tests.</footer>
  <script>
    const search = document.querySelector('#search');
    const filters = [...document.querySelectorAll('.filter')];
    const cards = [...document.querySelectorAll('.component-card')];
    const chromes = [...document.querySelectorAll('.chrome')];
    let status = 'all';
    function applyFilters() {{
      const query = search.value.trim().toLowerCase();
      for (const card of cards) {{
        const statusMatch = status === 'all' || card.dataset.status === status;
        const queryMatch = !query || card.dataset.search.includes(query);
        card.hidden = !(statusMatch && queryMatch);
      }}
      for (const chrome of chromes) chrome.hidden = ![...chrome.querySelectorAll('.component-card')].some(card => !card.hidden);
      document.querySelector('#no-results').classList.toggle('visible', chromes.every(chrome => chrome.hidden));
    }}
    search.addEventListener('input', applyFilters);
    for (const button of filters) button.addEventListener('click', () => {{
      status = button.dataset.status;
      for (const candidate of filters) candidate.setAttribute('aria-pressed', String(candidate === button));
      applyFilters();
    }});
    document.querySelector('#native').addEventListener('click', event => {{
      const active = !document.body.classList.contains('native');
      document.body.classList.toggle('native', active);
      event.currentTarget.setAttribute('aria-pressed', String(active));
    }});
  </script>
</body>
</html>
'''
    GENERATED_ROOT.mkdir(parents=True, exist_ok=True)
    destination = GENERATED_ROOT / "index.html"
    destination.write_text(html, encoding="utf-8")
    print(f"wrote {destination.relative_to(ROOT)} ({total_crops} crops)")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("chrome_id", nargs="?")
    for command in ("fetch", "extract", "reproduce", "import"):
        child = subparsers.add_parser(command)
        child.add_argument("chrome_id", nargs="?")
    subparsers.add_parser("report")
    subparsers.add_parser("html")
    args = parser.parse_args()
    if args.command == "validate":
        validate(args.chrome_id)
    elif args.command == "fetch":
        fetch(args.chrome_id)
    elif args.command == "import":
        import_implementations(args.chrome_id)
    elif args.command == "extract":
        extract(args.chrome_id)
    elif args.command == "reproduce":
        reproduce(args.chrome_id)
    elif args.command == "html":
        gallery_html()
    else:
        report()


if __name__ == "__main__":
    main()
