#!/usr/bin/env python3
"""Export a self-contained, browsable report from a Threading UI-test result bundle."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ATTACHMENT_SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f-]{36}$")
METADATA_KIND = "threading-ui-journey-screenshot"
REPORT_KIND = "threading-ui-journey-report"


@dataclass(frozen=True)
class TestResult:
    identifier: str
    result: str
    duration: str


@dataclass(frozen=True)
class Checkpoint:
    journey: str
    checkpoint: str
    order: int
    title: str
    description: str
    image: str


def run_xcresulttool(*arguments: str) -> str:
    completed = subprocess.run(
        ["xcrun", "xcresulttool", *arguments],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout


def attachment_label(suggested_name: str) -> str:
    stem = Path(suggested_name).stem
    return ATTACHMENT_SUFFIX.sub("", stem)


def load_test_results(result_bundle: Path) -> tuple[list[TestResult], str]:
    payload = json.loads(
        run_xcresulttool(
            "get",
            "test-results",
            "tests",
            "--path",
            str(result_bundle),
            "--compact",
        )
    )
    results: list[TestResult] = []

    def visit(node: dict[str, Any]) -> None:
        if node.get("nodeType") == "Test Case" and isinstance(node.get("nodeIdentifier"), str):
            results.append(
                TestResult(
                    identifier=node["nodeIdentifier"],
                    result=str(node.get("result", "Unknown")),
                    duration=str(node.get("duration", "")),
                )
            )
        for child in node.get("children", []):
            if isinstance(child, dict):
                visit(child)

    plans = payload.get("testNodes", [])
    for plan in plans:
        if isinstance(plan, dict):
            visit(plan)
    plan_result = str(plans[0].get("result", "Unknown")) if plans else "Unknown"
    return results, plan_result


def load_checkpoints(
    attachments: list[dict[str, Any]],
    assets_directory: Path,
) -> tuple[list[Checkpoint], list[str]]:
    by_label = {
        attachment_label(str(item.get("suggestedHumanReadableName", ""))): item
        for item in attachments
    }
    checkpoints: list[Checkpoint] = []
    diagnostics: list[str] = []

    for label, item in by_label.items():
        exported_name = str(item.get("exportedFileName", ""))
        if exported_name.lower().endswith(".mp4"):
            diagnostics.append(exported_name)
        if not label.startswith("journey-metadata-"):
            continue
        metadata_path = assets_directory / exported_name
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(f"invalid journey metadata attachment {metadata_path}: {error}") from error
        if metadata.get("schemaVersion") != 1 or metadata.get("kind") != METADATA_KIND:
            raise ValueError(f"unsupported journey metadata attachment {metadata_path}")

        checkpoint = require_text(metadata, "checkpoint")
        screenshot = by_label.get(f"journey-screenshot-{checkpoint}")
        if screenshot is None:
            raise ValueError(f"journey metadata {checkpoint!r} has no matching screenshot")
        order = metadata.get("order")
        if not isinstance(order, int) or order < 0:
            raise ValueError(f"journey metadata {checkpoint!r} has an invalid order")
        checkpoints.append(
            Checkpoint(
                journey=require_text(metadata, "journey"),
                checkpoint=checkpoint,
                order=order,
                title=require_text(metadata, "title"),
                description=require_text(metadata, "description"),
                image=str(screenshot["exportedFileName"]),
            )
        )
    return sorted(checkpoints, key=lambda item: (item.order, item.checkpoint)), diagnostics


def require_text(value: dict[str, Any], key: str) -> str:
    text = value.get(key)
    if not isinstance(text, str) or not text.strip():
        raise ValueError(f"journey metadata field {key!r} is missing or empty")
    return text.strip()


def render_report(
    result_bundle: Path,
    tests: list[TestResult],
    plan_result: str,
    attachments_by_test: dict[str, list[dict[str, Any]]],
    assets_directory: Path,
) -> str:
    sections: list[str] = []
    navigation: list[str] = []
    passed = sum(test.result.lower() == "passed" for test in tests)
    failed = sum(test.result.lower() == "failed" for test in tests)

    for index, test in enumerate(tests, start=1):
        attachments = attachments_by_test.get(test.identifier, [])
        checkpoints, diagnostic_videos = load_checkpoints(attachments, assets_directory)
        journey = checkpoints[0].journey if checkpoints else humanize_identifier(test.identifier)
        anchor = f"test-{index}"
        status_class = status_css(test.result)
        navigation.append(
            f'<a href="#{anchor}"><span>{html.escape(journey)}</span>'
            f'<small class="{status_class}">{html.escape(test.result)}</small></a>'
        )

        figures: list[str] = []
        for checkpoint in checkpoints:
            image_path = f"assets/{checkpoint.image}"
            figures.append(
                f'<figure id="{html.escape(checkpoint.checkpoint)}">'
                f'<button class="image-button" type="button" data-image="{html.escape(image_path)}" '
                f'data-alt="{html.escape(checkpoint.title)}" '
                f'data-description="{html.escape(checkpoint.description)}">'
                f'<img src="{html.escape(image_path)}" loading="lazy" '
                f'alt="{html.escape(journey + ": " + checkpoint.title)}"></button>'
                f'<figcaption><span class="step">Checkpoint {checkpoint.order}</span>'
                f'<h3>{html.escape(checkpoint.title)}</h3>'
                f'<p>{html.escape(checkpoint.description)}</p></figcaption></figure>'
            )
        if not figures:
            figures.append(
                '<div class="empty">This test produced no named journey checkpoint before it ended.</div>'
            )

        videos = ""
        if diagnostic_videos:
            players = "".join(
                f'<video controls preload="metadata" src="assets/{html.escape(filename)}"></video>'
                for filename in diagnostic_videos
            )
            videos = (
                '<details class="diagnostics"><summary>Full-display failure recording</summary>'
                '<p>This Xcode diagnostic can contain unrelated applications or private content.</p>'
                f'{players}</details>'
            )

        sections.append(
            f'<section class="journey" id="{anchor}"><header>'
            f'<div><span class="eyebrow">{html.escape(test.identifier)}</span>'
            f'<h2>{html.escape(journey)}</h2></div>'
            f'<div class="result {status_class}">{html.escape(test.result)}'
            f'<small>{html.escape(test.duration)}</small></div></header>'
            f'<div class="checkpoint-grid">{"".join(figures)}</div>{videos}</section>'
        )

    generated = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Threading UI journeys</title>
<style>
:root {{ color-scheme: light dark; --bg:#0e1014; --panel:#171a20; --raised:#20242c;
  --text:#f1f3f5; --muted:#9ba3af; --line:#303640; --accent:#8bb9ff;
  --pass:#5ad38a; --fail:#ff7272; --other:#e8b85f; }}
* {{ box-sizing:border-box; }}
html {{ scroll-behavior:smooth; }}
body {{ margin:0; background:var(--bg); color:var(--text); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
a {{ color:inherit; }}
.layout {{ display:grid; grid-template-columns:270px minmax(0,1fr); min-height:100vh; }}
aside {{ position:sticky; top:0; height:100vh; padding:28px 20px; border-right:1px solid var(--line); background:#12151a; overflow:auto; }}
aside h1 {{ margin:0 0 4px; font-size:20px; }}
aside>p {{ color:var(--muted); margin:0 0 24px; }}
nav {{ display:grid; gap:7px; }}
nav a {{ display:flex; justify-content:space-between; gap:10px; padding:10px 11px; border-radius:8px; text-decoration:none; }}
nav a:hover {{ background:var(--raised); }}
nav span {{ min-width:0; }}
nav small {{ flex:none; }}
.summary {{ margin-top:25px; padding-top:18px; border-top:1px solid var(--line); color:var(--muted); font-size:13px; }}
main {{ min-width:0; padding:34px clamp(20px,4vw,64px) 80px; }}
.run-header {{ max-width:1500px; margin:0 auto 30px; }}
.run-header h1 {{ margin:0 0 7px; font-size:30px; }}
.run-header p {{ margin:0; color:var(--muted); }}
.journey {{ max-width:1500px; margin:0 auto 56px; scroll-margin-top:20px; }}
.journey>header {{ display:flex; align-items:end; justify-content:space-between; gap:20px; margin-bottom:16px; }}
.eyebrow {{ display:block; color:var(--muted); font:12px ui-monospace,SFMono-Regular,Menlo,monospace; overflow-wrap:anywhere; }}
h2 {{ margin:5px 0 0; font-size:24px; }}
.result {{ padding:7px 11px; border:1px solid currentColor; border-radius:8px; font-weight:650; text-align:right; }}
.result small {{ display:block; color:var(--muted); font-weight:400; }}
.passed {{ color:var(--pass); }} .failed {{ color:var(--fail); }} .other {{ color:var(--other); }}
.checkpoint-grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,430px),1fr)); gap:18px; align-items:start; }}
figure {{ margin:0; border:1px solid var(--line); border-radius:12px; overflow:hidden; background:var(--panel); box-shadow:0 12px 35px #0004; }}
.image-button {{ display:block; width:100%; padding:0; border:0; background:#08090b; cursor:zoom-in; }}
figure img {{ display:block; width:100%; height:auto; }}
figcaption {{ padding:16px 18px 18px; }}
.step {{ color:var(--accent); font-size:12px; font-weight:700; letter-spacing:.04em; text-transform:uppercase; }}
h3 {{ margin:4px 0 5px; font-size:17px; }}
figcaption p {{ margin:0; color:var(--muted); }}
.empty,.diagnostics {{ padding:18px; border:1px solid var(--line); border-radius:10px; background:var(--panel); color:var(--muted); }}
.diagnostics {{ margin-top:18px; }} .diagnostics video {{ display:block; max-width:100%; margin-top:12px; }}
dialog {{ width:min(96vw,1700px); max-width:none; padding:0; border:1px solid var(--line); border-radius:12px; background:#08090b; color:var(--text); }}
dialog::backdrop {{ background:#000c; }} dialog img {{ display:block; max-width:94vw; max-height:calc(92vh - 92px); }}
.lightbox-copy {{ padding:14px 18px 17px; border-top:1px solid var(--line); background:var(--panel); }}
.lightbox-copy h3 {{ margin:0 0 3px; }} .lightbox-copy p {{ margin:0; color:var(--muted); }}
dialog button {{ position:fixed; top:14px; right:18px; width:38px; height:38px; border:1px solid #fff5; border-radius:20px; background:#111d; color:white; font-size:22px; cursor:pointer; }}
@media (max-width:800px) {{ .layout {{ display:block; }} aside {{ position:relative; width:auto; height:auto; border-right:0; border-bottom:1px solid var(--line); }} main {{ padding-top:24px; }} }}
</style>
</head>
<body>
<div class="layout">
<aside><h1>Threading journeys</h1><p>{len(tests)} application-level tests</p><nav>{''.join(navigation)}</nav>
<div class="summary"><div>{passed} passed · {failed} failed</div><div>Plan: {html.escape(plan_result)}</div><div>{html.escape(generated)}</div></div></aside>
<main><header class="run-header"><h1>UI journey evidence</h1><p>{html.escape(result_bundle.name)} · app-window captures with descriptions</p></header>{''.join(sections)}</main>
</div>
<dialog id="lightbox" aria-labelledby="lightbox-title" aria-describedby="lightbox-description"><button type="button" aria-label="Close">×</button><img alt="Selected journey evidence"><div class="lightbox-copy"><h3 id="lightbox-title"></h3><p id="lightbox-description"></p></div></dialog>
<script>
const dialog=document.querySelector('#lightbox'), full=dialog.querySelector('img'), title=dialog.querySelector('h3'), description=dialog.querySelector('p');
document.querySelectorAll('.image-button').forEach(button=>button.addEventListener('click',()=>{{full.src=button.dataset.image;full.alt=button.dataset.alt;title.textContent=button.dataset.alt;description.textContent=button.dataset.description;dialog.showModal();}}));
dialog.querySelector('button').addEventListener('click',()=>dialog.close());
dialog.addEventListener('click',event=>{{if(event.target===dialog)dialog.close();}});
</script>
</body></html>
"""


def evidence_document(
    result_bundle: Path,
    tests: list[TestResult],
    plan_result: str,
    attachments_by_test: dict[str, list[dict[str, Any]]],
    assets_directory: Path,
) -> dict[str, Any]:
    """Write the stable handoff consumed by the combined UI evidence catalogue.

    Exported attachment filenames contain xcresult UUIDs, so they are deliberately kept as
    source locations only. The combined report copies each checkpoint to a stable
    `journeys/<journey>/<checkpoint>.png` path before comparing it with an approved baseline.
    """
    evidence_tests: list[dict[str, Any]] = []
    for test in tests:
        checkpoints, _ = load_checkpoints(
            attachments_by_test.get(test.identifier, []),
            assets_directory,
        )
        evidence_tests.append({
            "identifier": test.identifier,
            "result": test.result,
            "duration": test.duration,
            "journey": (
                checkpoints[0].journey
                if checkpoints
                else humanize_identifier(test.identifier)
            ),
            "checkpoints": [
                {
                    "checkpoint": checkpoint.checkpoint,
                    "order": checkpoint.order,
                    "title": checkpoint.title,
                    "description": checkpoint.description,
                    "image": f"assets/{checkpoint.image}",
                }
                for checkpoint in checkpoints
            ],
        })
    return {
        "schemaVersion": 1,
        "kind": REPORT_KIND,
        "resultBundle": result_bundle.name,
        "planResult": plan_result,
        "tests": evidence_tests,
    }


def humanize_identifier(identifier: str) -> str:
    suite = identifier.split("/", 1)[0]
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", suite).replace("UI Tests", "")
    return words.strip() or identifier


def status_css(result: str) -> str:
    normalized = result.lower()
    if normalized == "passed":
        return "passed"
    if normalized == "failed":
        return "failed"
    return "other"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", required=True, type=Path, help="input .xcresult bundle")
    parser.add_argument("--output", required=True, type=Path, help="new report directory")
    arguments = parser.parse_args()

    result_bundle = arguments.result.expanduser().resolve()
    output = arguments.output.expanduser().resolve()
    if not result_bundle.is_dir():
        parser.error(f"result bundle does not exist: {result_bundle}")
    if output.exists():
        parser.error(f"report output already exists: {output}")

    assets = output / "assets"
    assets.mkdir(parents=True)
    try:
        run_xcresulttool(
            "export",
            "attachments",
            "--path",
            str(result_bundle),
            "--output-path",
            str(assets),
        )
        manifest = json.loads((assets / "manifest.json").read_text(encoding="utf-8"))
        tests, plan_result = load_test_results(result_bundle)
        attachments_by_test = {
            str(group.get("testIdentifier", "")): list(group.get("attachments", []))
            for group in manifest
        }
        report = render_report(
            result_bundle,
            tests,
            plan_result,
            attachments_by_test,
            assets,
        )
        (output / "index.html").write_text(report, encoding="utf-8")
        (output / "evidence.json").write_text(
            json.dumps(
                evidence_document(
                    result_bundle,
                    tests,
                    plan_result,
                    attachments_by_test,
                    assets,
                ),
                indent=2,
                sort_keys=True,
            ) + "\n",
            encoding="utf-8",
        )
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"error: could not generate UI journey report: {error}", file=sys.stderr)
        return 1

    print(output / "index.html")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
