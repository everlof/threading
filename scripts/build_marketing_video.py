#!/usr/bin/env python3
"""Render one manifest flow on an exact, theme-independent frame timeline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from typing import NoReturn


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def frame_seconds(frames: int, fps: int) -> str:
    return f"{frames / fps:.9f}".rstrip("0").rstrip(".")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--images", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--flow", default="ios-marketing-flow")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    flow = next((item for item in manifest.get("flows", []) if item["id"] == args.flow), None)
    if flow is None:
        fail(f"manifest has no flow {args.flow}")
    fps = flow.get("fps")
    shots = flow.get("shots", [])
    if not isinstance(fps, int) or fps <= 0 or len(shots) < 2:
        fail("flow needs a positive integer fps and at least two shots")
    if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
        fail("ffmpeg and ffprobe are required")

    inputs: list[Path] = []
    filters: list[str] = []
    incoming_frames = 0
    for index, shot in enumerate(shots):
        capture_id = shot["captureID"]
        image = args.images / f"{capture_id}.png"
        if not image.is_file():
            fail(f"missing captured frame {image}")
        hold_frames = shot.get("holdFrames")
        if not isinstance(hold_frames, int) or hold_frames <= 0:
            fail(f"shot {capture_id} has no positive holdFrames")
        transition = shot.get("transition")
        outgoing_frames = transition.get("frames", 0) if transition else 0
        if not isinstance(outgoing_frames, int) or outgoing_frames < 0:
            fail(f"shot {capture_id} has invalid transition frames")
        # A middle source exists for its incoming dissolve, authored hold, and outgoing dissolve.
        # Giving each phase an integer frame count is what makes theme variants share timestamps.
        source_frames = incoming_frames + hold_frames + outgoing_frames
        filters.append(
            f"[{index}:v]fps={fps},trim=end_frame={source_frames},"
            f"setpts=PTS-STARTPTS,format=yuv420p,setsar=1[v{index}]"
        )
        inputs.append(image)
        incoming_frames = outgoing_frames

    current = "v0"
    elapsed_frames = shots[0]["holdFrames"]
    for index in range(1, len(shots)):
        previous_transition = shots[index - 1].get("transition")
        if not previous_transition:
            fail(f"shot {shots[index - 1]['captureID']} needs a transition")
        transition_frames = previous_transition["frames"]
        transition_name = previous_transition.get("name", "fade")
        output = f"mix{index}"
        filters.append(
            f"[{current}][v{index}]xfade=transition={transition_name}:"
            f"duration={frame_seconds(transition_frames, fps)}:"
            f"offset={frame_seconds(elapsed_frames, fps)}[{output}]"
        )
        current = output
        elapsed_frames += transition_frames + shots[index]["holdFrames"]

    total_frames = sum(shot["holdFrames"] for shot in shots) + sum(
        shot.get("transition", {}).get("frames", 0) for shot in shots[:-1]
    )
    filters.append(f"[{current}]trim=end_frame={total_frames},setpts=PTS-STARTPTS[out]")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    for image in inputs:
        command.extend(["-loop", "1", "-framerate", str(fps), "-i", str(image)])
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            "[out]",
            "-an",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-fps_mode",
            "cfr",
            "-r",
            str(fps),
            "-movflags",
            "+faststart",
            "-metadata",
            "creation_time=",
            str(args.output),
        ]
    )
    subprocess.run(command, check=True)
    probe = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=nb_read_frames",
            "-of",
            "default=nokey=1:noprint_wrappers=1",
            str(args.output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    actual_frames = int(probe.stdout.strip())
    if actual_frames != total_frames:
        fail(f"video has {actual_frames} frames; manifest requires {total_frames}")
    print(f"{args.output} ({actual_frames} frames at {fps} fps)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
