#!/usr/bin/env python3
"""Record the real iOS marketing walkthrough on a fixed interaction clock."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any


# A cold idb accessibility query can take a little over one second on a newly cloned simulator.
# Resolve after the preceding transition has settled but early enough that the query itself never
# shifts the fixed-frame interaction clock. The movie contract leaves at least 1.5 seconds between
# semantic taps whose targets move with the keyboard or a sheet.
TAP_RESOLUTION_LEAD_SECONDS = 1.4


def fail(message: str) -> None:
    raise RuntimeError(message)


def run(*arguments: str, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        check=True,
        capture_output=capture,
        text=True,
    )


def accessibility(udid: str) -> list[dict[str, Any]]:
    result = run("idb", "ui", "describe-all", "--json", "--udid", udid, capture=True)
    value = json.loads(result.stdout)
    if not isinstance(value, list):
        fail("idb returned a non-list accessibility hierarchy")
    return value


def matching_element(
    elements: list[dict[str, Any]], label: str
) -> dict[str, Any] | None:
    candidates: list[tuple[int, dict[str, Any]]] = []
    for element in elements:
        actual = element.get("AXLabel")
        frame = element.get("frame")
        if not (
            isinstance(actual, str)
            and isinstance(frame, dict)
            and frame.get("width", 0) > 0
            and frame.get("height", 0) > 0
        ):
            continue
        if actual == label:
            priority = 0
        elif actual.startswith(label):
            priority = 1
        elif label in actual:
            priority = 2
        else:
            continue
        candidates.append((priority, element))
    if candidates:
        return min(candidates, key=lambda candidate: candidate[0])[1]
    return None


def wait_for_labels(udid: str, labels: list[str], deadline: float) -> list[dict[str, Any]]:
    latest: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        latest = accessibility(udid)
        if all(matching_element(latest, label) is not None for label in labels):
            return latest
        time.sleep(0.05)
    actual = sorted(
        label
        for element in latest
        if isinstance((label := element.get("AXLabel")), str) and label
    )
    fail(f"accessibility deadline missed for {labels!r}; visible labels: {actual!r}")


def wait_until(moment: float) -> None:
    while True:
        remaining = moment - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 0.02))


def center(element: dict[str, Any]) -> tuple[int, int]:
    frame = element["frame"]
    return (
        round(float(frame["x"]) + float(frame["width"]) / 2),
        round(float(frame["y"]) + float(frame["height"]) / 2),
    )


def load_flow(manifest: Path, flow_id: str) -> dict[str, Any]:
    document = json.loads(manifest.read_text(encoding="utf-8"))
    flow = next((item for item in document["flows"] if item["id"] == flow_id), None)
    if flow is None:
        fail(f"manifest has no flow {flow_id!r}")
    movie = flow.get("movie")
    if not isinstance(movie, dict):
        fail(f"flow {flow_id!r} has no movie contract")
    return {"fps": flow["fps"], **movie}


def start_recorder(udid: str, raw_video: Path) -> subprocess.Popen[str]:
    recorder = subprocess.Popen(
        [
            "xcrun",
            "simctl",
            "io",
            udid,
            "recordVideo",
            "--codec=h264",
            "--mask=black",
            "--force",
            str(raw_video),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert recorder.stderr is not None
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        line = recorder.stderr.readline()
        if "Recording started" in line:
            return recorder
        if recorder.poll() is not None:
            fail(f"simctl recordVideo exited before its first frame: {line.strip()}")
    recorder.send_signal(signal.SIGINT)
    recorder.wait(timeout=10)
    fail("simctl recordVideo did not publish its first frame")


def stop_recorder(recorder: subprocess.Popen[str]) -> None:
    if recorder.poll() is not None:
        fail(f"simctl recordVideo exited early with status {recorder.returncode}")
    recorder.send_signal(signal.SIGINT)
    try:
        status = recorder.wait(timeout=30)
    except subprocess.TimeoutExpired:
        recorder.kill()
        recorder.wait(timeout=5)
        fail("simctl recordVideo did not finalize after SIGINT")
    if status != 0:
        fail(f"simctl recordVideo failed with status {status}")


def drive(
    udid: str,
    contract: dict[str, Any],
    raw_video: Path,
    log_path: Path,
) -> None:
    fps = int(contract["fps"])
    duration_frames = int(contract["durationFrames"])
    maximum_lateness = float(contract["maximumActionLatenessSeconds"])
    actions = contract["actions"]
    preconditions = contract["readyAccessibilityLabels"]
    cached_elements = wait_for_labels(udid, preconditions, time.monotonic() + 30)

    recorder = start_recorder(udid, raw_video)
    started = time.monotonic()
    action_log: list[dict[str, Any]] = []
    try:
        for index, action in enumerate(actions):
            target = started + int(action["atFrame"]) / fps
            next_target = (
                started + int(actions[index + 1]["atFrame"]) / fps
                if index + 1 < len(actions)
                else started + duration_frames / fps
            )
            kind = action["kind"]
            element: dict[str, Any] | None = None
            if kind == "tap":
                if not action.get("refreshAccessibility", False):
                    element = matching_element(cached_elements, action["label"])
                if element is None:
                    wait_until(max(started, target - TAP_RESOLUTION_LEAD_SECONDS))
                    labels = wait_for_labels(
                        udid,
                        [action["label"]],
                        max(target - 0.08, time.monotonic() + 0.01),
                    )
                    element = matching_element(labels, action["label"])
                if element is None:
                    fail(f"tap target disappeared before frame {action['atFrame']}: {action['label']}")

            wait_until(target)
            actual = time.monotonic()
            lateness = actual - target
            if lateness > maximum_lateness:
                fail(
                    f"action at frame {action['atFrame']} started {lateness:.3f}s late "
                    f"(limit {maximum_lateness:.3f}s)"
                )
            if kind == "tap":
                assert element is not None
                x, y = center(element)
                run("idb", "ui", "tap", "--udid", udid, str(x), str(y))
            elif kind == "tapPoint":
                run(
                    "idb", "ui", "tap", "--udid", udid,
                    str(action["point"][0]), str(action["point"][1]),
                )
            elif kind == "text":
                run("idb", "ui", "text", "--udid", udid, action["text"])
            elif kind == "tapSequence":
                interval_frames = int(action["intervalFrames"])
                for point_index, point in enumerate(action["points"]):
                    point_target = target + point_index * interval_frames / fps
                    wait_until(point_target)
                    point_actual = time.monotonic()
                    point_lateness = point_actual - point_target
                    if point_lateness > maximum_lateness:
                        fail(
                            f"tap sequence point {point_index} at frame "
                            f"{action['atFrame'] + point_index * interval_frames} started "
                            f"{point_lateness:.3f}s late (limit {maximum_lateness:.3f}s)"
                        )
                    run(
                        "idb", "ui", "tap", "--udid", udid,
                        str(point[0]), str(point[1]),
                    )
            elif kind == "swipe":
                run(
                    "idb", "ui", "swipe", "--udid", udid,
                    str(action["from"][0]), str(action["from"][1]),
                    str(action["to"][0]), str(action["to"][1]),
                    "--duration", str(action.get("duration", 0.45)),
                )
            else:
                fail(f"unsupported marketing action kind: {kind!r}")

            action_log.append(
                {
                    "atFrame": action["atFrame"],
                    "actualSeconds": actual - started,
                    "latenessSeconds": lateness,
                    "kind": kind,
                    "label": action.get("label"),
                    "pointCount": len(action["points"]) if kind == "tapSequence" else None,
                }
            )
            wait_after = action.get("waitForAccessibilityLabels", [])
            if wait_after:
                cached_elements = wait_for_labels(udid, wait_after, next_target - 0.12)
            else:
                cached_elements = []

        wait_until(started + duration_frames / fps)
        stop_recorder(recorder)
    except Exception:
        if recorder.poll() is None:
            recorder.send_signal(signal.SIGINT)
            try:
                recorder.wait(timeout=10)
            except subprocess.TimeoutExpired:
                recorder.kill()
        raise

    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(
        json.dumps(
            {
                "fps": fps,
                "durationFrames": duration_frames,
                "actions": action_log,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )


def normalize(raw_video: Path, output: Path, fps: int, frames: int) -> None:
    duration = frames / fps
    output.parent.mkdir(parents=True, exist_ok=True)
    run(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(raw_video),
        "-f", "lavfi", "-t", f"{duration:.9f}",
        "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-map", "0:v:0", "-map", "1:a:0",
        "-vf", (
            f"fps={fps},tpad=stop_mode=clone:stop_duration=1,"
            "scale=886:1920:flags=lanczos"
        ),
        "-t", f"{duration:.9f}",
        "-frames:v", str(frames),
        "-c:v", "libx264", "-profile:v", "high", "-level:v", "4.0",
        "-b:v", "11M", "-minrate", "11M", "-maxrate", "11M", "-bufsize", "22M",
        "-x264-params", "nal-hrd=cbr:force-cfr=1",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-ac", "2",
        "-movflags", "+faststart",
        str(output),
    )
    probe = run(
        "ffprobe", "-v", "error", "-count_frames",
        "-show_entries", (
            "stream=codec_name,profile,width,height,pix_fmt,level,avg_frame_rate,"
            "nb_read_frames,sample_rate,channels"
        ),
        "-of", "json", str(output), capture=True,
    )
    streams = json.loads(probe.stdout)["streams"]
    video = next(stream for stream in streams if stream["codec_name"] == "h264")
    audio = next(stream for stream in streams if stream["codec_name"] == "aac")
    expected_video = {
        "profile": "High",
        "width": 886,
        "height": 1920,
        "pix_fmt": "yuv420p",
        "level": 40,
        "avg_frame_rate": f"{fps}/1",
        "nb_read_frames": str(frames),
    }
    if any(video.get(key) != value for key, value in expected_video.items()):
        fail(f"normalized movie missed its App Store video contract: {video!r}")
    if audio.get("sample_rate") != "48000" or audio.get("channels") != 2:
        fail(f"normalized movie missed its App Store audio contract: {audio!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--flow", default="ios-marketing-flow")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()

    contract = load_flow(args.manifest, args.flow)
    raw_video = args.output.with_suffix(".raw.mov")
    if args.output.exists() or raw_video.exists():
        fail(f"marketing movie output already exists: {args.output}")
    try:
        drive(args.udid, contract, raw_video, args.log)
        normalize(
            raw_video,
            args.output,
            int(contract["fps"]),
            int(contract["durationFrames"]),
        )
    finally:
        if raw_video.exists():
            raw_video.unlink()
    print(
        f"{args.output} ({contract['durationFrames']} frames at {contract['fps']} fps)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
