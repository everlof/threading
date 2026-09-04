from __future__ import annotations

import binascii
import base64
import hashlib
import json
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
GENERATOR = REPOSITORY / "scripts/generate_ui_evidence_report.py"
APPROVER = REPOSITORY / "scripts/approve_ui_evidence.py"


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_rgba_png(
    path: Path,
    pixels: list[tuple[int, int, int, int]],
    *,
    bit_depth: int,
    compression: int,
) -> None:
    width = len(pixels)
    maximum = (1 << bit_depth) - 1
    sample_format = ">B" if bit_depth == 8 else ">H"
    row = b"".join(
        struct.pack(sample_format, sample)
        for pixel in pixels
        for sample in pixel
        if 0 <= sample <= maximum
    )
    if len(row) != width * 4 * (bit_depth // 8):
        raise ValueError("pixel sample is outside the selected bit depth")
    payload = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, 1, bit_depth, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(b"\0" + row, compression))
        + png_chunk(b"IEND", b"")
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


class UIEvidenceToolsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Tests/UIEvidence").mkdir(parents=True)
        (self.root / "source.txt").write_text("fixture\n", encoding="utf-8")
        self.manifest = self.root / "Tests/UIEvidence/coverage.json"
        self.manifest.write_text(json.dumps({
            "schemaVersion": 1,
            "title": "Evidence test",
            "platform": "iOS",
            "entries": [{
                "id": "sentinel",
                "kind": "surface",
                "status": "implemented",
                "priority": "critical",
                "title": "Sentinel",
                "description": "Pixel contract",
                "states": ["Rendered"],
                "matrix": {"themes": ["Test"]},
                "source": {"path": "source.txt", "command": "capture"},
                "capture": {"glob": "shot.png"},
            }],
        }), encoding="utf-8")
        self.current = self.root / "current"
        self.baseline = self.root / "baseline"
        self.current.mkdir()
        self.baseline.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def generate(self, output: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--manifest", str(self.manifest),
                "--current", str(self.current),
                "--baseline", str(self.baseline),
                "--output", str(self.root / output),
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_exact_compare_uses_decoded_16_bit_pixels(self) -> None:
        pixels = [(0, 1, 65_535, 65_535), (4_096, 8_192, 16_384, 32_768)]
        write_rgba_png(self.current / "shot.png", pixels, bit_depth=16, compression=1)
        write_rgba_png(self.baseline / "shot.png", pixels, bit_depth=16, compression=9)

        result = self.generate("accepted", "--require-accepted")

        self.assertEqual(result.returncode, 0, result.stderr)
        evidence = json.loads((self.root / "accepted/evidence.json").read_text())
        artifact = evidence["entries"][0]["artifacts"][0]
        self.assertEqual(artifact["comparison"], "accepted")
        self.assertEqual(artifact["changedPixels"], 0)

    def test_strict_mode_writes_report_then_fails_on_one_pixel(self) -> None:
        write_rgba_png(
            self.current / "shot.png", [(0, 0, 0, 255), (1, 2, 3, 255)],
            bit_depth=8, compression=1,
        )
        write_rgba_png(
            self.baseline / "shot.png", [(0, 0, 0, 255), (1, 2, 4, 255)],
            bit_depth=8, compression=9,
        )

        result = self.generate("changed", "--require-accepted")

        self.assertEqual(result.returncode, 3)
        evidence = json.loads((self.root / "changed/evidence.json").read_text())
        artifact = evidence["entries"][0]["artifacts"][0]
        self.assertEqual(artifact["changedPixels"], 1)
        self.assertEqual(artifact["differenceBounds"], [1, 0, 2, 1])
        self.assertTrue((self.root / "changed" / artifact["diff"]).is_file())
        for name in ("index.html", "review.html", "regression.html"):
            self.assertTrue((self.root / "changed" / name).is_file())
        self.assertIn(
            "JSON.stringify(payload,null,2)+'\\n'",
            (self.root / "changed/regression.html").read_text(),
        )

    def test_report_reserves_image_space_and_explains_a_missing_asset(self) -> None:
        pixels = [(5, 6, 7, 255), (8, 9, 10, 255)]
        write_rgba_png(self.current / "shot.png", pixels, bit_depth=8, compression=1)
        write_rgba_png(self.baseline / "shot.png", pixels, bit_depth=8, compression=9)

        result = self.generate("missing-asset-fallback", "--require-accepted")

        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.root / "missing-asset-fallback/review.html").read_text()
        self.assertIn('width="2" height="1"', report)
        self.assertIn(
            "Image unavailable. Keep this report beside its assets directory.",
            report,
        )
        self.assertIn("setImageAvailability(image,image.naturalWidth>0)", report)

    def test_approval_is_bound_to_the_current_asset_hash(self) -> None:
        write_rgba_png(
            self.current / "shot.png", [(5, 6, 7, 255)], bit_depth=8, compression=1,
        )
        generated = self.generate("approval")
        self.assertEqual(generated.returncode, 0, generated.stderr)
        evidence = json.loads((self.root / "approval/evidence.json").read_text())
        artifact = evidence["entries"][0]["artifacts"][0]
        decisions = {
            "schemaVersion": 1,
            "kind": "threading-ui-evidence-decisions",
            "reportID": evidence["reportID"],
            "platform": evidence["platform"],
            "decisions": [{
                "artifactID": artifact["id"],
                "decision": "approve",
                "currentSHA256": artifact["currentSHA256"],
                "baselineRelative": artifact["baselineRelative"],
            }],
        }
        decision_path = self.root / "decisions.json"
        decision_path.write_text(json.dumps(decisions), encoding="utf-8")
        report_asset = self.root / "approval" / artifact["current"]
        report_asset.write_bytes(report_asset.read_bytes() + b"changed after review")

        result = subprocess.run(
            [
                sys.executable,
                str(APPROVER),
                "--report", str(self.root / "approval"),
                "--decisions", str(decision_path),
                "--baseline", str(self.baseline),
                "--require-complete",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("changed after review", result.stderr)
        self.assertFalse((self.baseline / "shot.png").exists())

    def test_ios_marketing_flow_has_one_theme_and_exact_interaction_clock(self) -> None:
        manifest = json.loads(
            (REPOSITORY / "Tests/UIEvidence/ios-coverage.json").read_text()
        )
        self.assertEqual(set(manifest["themeIDs"]), set(manifest["themeAppearances"]))
        flow = next(item for item in manifest["flows"] if item["id"] == "ios-marketing-flow")
        captures = {item["id"]: item for item in manifest["captures"]}
        self.assertEqual(len(flow["shots"]), 6)
        self.assertEqual(
            [shot["captureID"] for shot in flow["shots"]],
            [
                "marketing-sessions",
                "marketing-claude-tui",
                "marketing-claude-usage-menu",
                "marketing-codex-tui",
                "marketing-settings",
                "marketing-usage",
            ],
        )
        for shot in flow["shots"]:
            self.assertEqual(captures[shot["captureID"]]["entryID"], "ios-marketing-flow")
        marketing = [captures[shot["captureID"]] for shot in flow["shots"]]
        self.assertEqual({capture["theme"] for capture in marketing}, {"threading"})
        self.assertEqual({capture["contentSize"] for capture in marketing}, {"large"})
        self.assertEqual(
            {
                capture["captureMode"]
                for capture in marketing
                if capture["id"] != "marketing-claude-usage-menu"
            },
            {"stable-display"},
        )
        terminal_captures = [
            capture for capture in marketing if "tui" in capture["id"]
        ]
        self.assertEqual(
            {capture["terminalFontSize"] for capture in terminal_captures},
            {10},
        )
        self.assertTrue(all(set(shot) == {"captureID", "filename"} for shot in flow["shots"]))
        movie = flow["movie"]
        self.assertEqual((flow["fps"], movie["durationFrames"]), (30, 900))
        self.assertEqual(movie["terminalFontSize"], 10)
        self.assertGreaterEqual(movie["durationFrames"], 15 * flow["fps"])
        self.assertLessEqual(movie["durationFrames"], 30 * flow["fps"])
        self.assertEqual(movie["maximumActionLatenessSeconds"], 0.15)
        self.assertEqual(movie["demo"], "marketing-sessions")
        self.assertEqual(
            [action["atFrame"] for action in movie["actions"]],
            sorted(action["atFrame"] for action in movie["actions"]),
        )
        self.assertEqual(
            [action["kind"] for action in movie["actions"]],
            [
                "tap", "tap", "tap", "tapSequence", "tapPoint", "swipe", "swipe",
                "tap", "tapPoint", "tapPoint", "tapPoint", "tap", "tapPoint", "swipe",
            ],
        )
        self.assertEqual(movie["actions"][0]["label"], "New session in Threading")
        self.assertEqual(movie["actions"][1]["label"], "Model and effort")
        self.assertEqual(movie["actions"][2]["label"], "GPT-5.6 Sol, Extra High")
        self.assertEqual(movie["actions"][3]["text"], "Polish the flow")
        self.assertEqual(movie["actions"][3]["intervalFrames"], 6)
        self.assertEqual(len(movie["actions"][3]["points"]), 15)
        self.assertGreater(
            movie["actions"][5]["to"][1],
            movie["actions"][5]["from"][1],
            "the Codex gesture must reveal older output rather than push past the bottom",
        )
        self.assertEqual(movie["actions"][-2]["point"], [300, 159])
        self.assertEqual(
            movie["actions"][-1]["waitForAccessibilityLabels"],
            ["Processed tokens"],
        )
        self.assertNotIn("transition", json.dumps(flow))
        menu = captures["marketing-claude-usage-menu"]
        self.assertEqual(menu["captureMode"], "display")
        self.assertEqual(menu["keyboardState"], "open")
        self.assertEqual(
            menu["interaction"]["waitForAccessibilityLabels"],
            ["Vera Keller", "Workspace", "Interface", "Archive"],
        )

    def test_marketing_pty_resources_are_privacy_safe(self) -> None:
        fixture_directory = REPOSITORY / "Sources/ThreadingMobile/TerminalFixtures"
        expected_rows = {"claude": 49, "codex": 55}
        expected_transcript_marker = {"claude": b"Completed:", "codex": b"Validation"}
        for provider in ("claude", "codex"):
            fixture = json.loads(
                (fixture_directory / f"marketing-{provider}-tui.json").read_text()
            )
            payload = base64.b64decode(fixture["payloadBase64"], validate=True)
            self.assertEqual(fixture["provider"], provider)
            self.assertEqual(fixture["columns"], 62)
            self.assertEqual(fixture["rows"], expected_rows[provider])
            self.assertGreater(len(payload), 1_500)
            self.assertIn(expected_transcript_marker[provider], payload)
            self.assertIn(b"\x1b", payload)
            if provider == "claude":
                self.assertTrue(
                    any(code in payload for code in (b"\x1b[31m", b"\x1b[91m"))
                )
                self.assertTrue(
                    any(code in payload for code in (b"\x1b[32m", b"\x1b[92m"))
                )
                self.assertIn(b"capture-plan.md", payload)
                self.assertIn(b"Added", payload)
                self.assertIn(b"removed", payload)
            else:
                self.assertIn(b"Edited", payload)
                self.assertIn(b"capture-notes.md", payload)
                self.assertGreaterEqual(
                    len(set(re.findall(rb"\x1b\[38;[^m]+m", payload))),
                    4,
                )
            self.assertNotIn(b"authentication rejected", payload)
            self.assertNotIn(b"MCP client", payload)
            self.assertNotIn(b"/Users/", payload)
            self.assertNotIn(b"/home/", payload)

    def test_ios_evidence_seeds_system_keyboard_tutorials_on_its_clone(self) -> None:
        harness = (REPOSITORY / "scripts/ui-evidence-ios.sh").read_text()
        self.assertIn("DidShowContinuousPathIntroduction", harness)
        self.assertIn("KeyboardDidShowProductivityTutorial", harness)
        self.assertIn("DidShowGestureKeyboardIntroduction", harness)
        self.assertIn("UIKeyboardDidShowInternationalInfoIntroduction", harness)
        # The bilingual "Type English and Swedish" sheet: raised on the first keystroke, so a
        # keyboard-open screenshot never showed it while the walkthrough's typing hit it.
        self.assertIn("MultilingualKeyboardTip", harness)
        clone_seed = harness.index("DidShowContinuousPathIntroduction")
        explicit_simulator_branch = harness.index("else\n  simulator_udid=", clone_seed)
        self.assertLess(clone_seed, explicit_simulator_branch)

    def test_ios_evidence_clones_a_named_template_without_booting_it(self) -> None:
        harness = (REPOSITORY / "scripts/ui-evidence-ios.sh").read_text()
        marketing = (REPOSITORY / "scripts/capture_marketing_ios.sh").read_text()
        self.assertIn("--template UDID", harness)
        self.assertIn("--template UDID", marketing)
        # The named template takes the clone branch, with its keyboard seeding and app-data
        # reset, rather than the reuse branch that installs over a developer's own device.
        clone_branch = harness.index(
            'if [[ "${requested_simulator}" == "booted" || -n "${requested_template}" ]]'
        )
        clone_seed = harness.index("DidShowContinuousPathIntroduction")
        self.assertLess(clone_branch, clone_seed)
        # A template chosen by UDID must not pass through `resolve_simulator`, whose explicit
        # path boots the device it is handed; cloning needs the template shut down.
        template_assignment = harness.index('template_simulator_udid="${requested_template}"')
        resolver_call = harness.index(
            'template_simulator_udid="$(resolve_simulator "${requested_simulator}")"'
        )
        self.assertLess(template_assignment, resolver_call)
        self.assertIn("--template clones a device and --simulator reuses one", harness)

    def test_ios_evidence_hit_tests_bars_idb_flattens(self) -> None:
        harness = (REPOSITORY / "scripts/ui-evidence-ios.sh").read_text()
        # The dashboard's navigation bar comes back from `idb ui describe-all` as one childless
        # group; its items answer only to `describe-point`. The semantic lookup has to fall
        # through to hit-testing before it can report the control missing.
        self.assertIn("hit_test_flattened_bars()", harness)
        self.assertIn("idb ui describe-point --json", harness)
        flattened_poll = harness.index("idb ui describe-all --json --udid")
        fallback = harness.index('hit_test_flattened_bars "${accessibility_json}"', flattened_poll)
        missing = harness.index("has no accessible control beginning with", fallback)
        self.assertLess(fallback, missing)
        # Bounded: a pitch under one tap target, walked only along bar-shaped groups.
        self.assertIn("hit_test_pitch=12", harness)
        self.assertIn("hit_test_bar_height=88", harness)


if __name__ == "__main__":
    unittest.main()
