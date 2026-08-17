from __future__ import annotations

import binascii
import hashlib
import json
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


if __name__ == "__main__":
    unittest.main()
