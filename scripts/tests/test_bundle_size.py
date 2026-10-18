import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "check_bundle_size.py"
RELEASE_SCRIPT = SCRIPT.parent / "release.sh"
AUTOINSTALL_SCRIPT = SCRIPT.parent / "autoinstall.sh"
SPEC = importlib.util.spec_from_file_location("check_bundle_size", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
bundle_size = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bundle_size
SPEC.loader.exec_module(bundle_size)

LARGE = bundle_size.INDIVIDUAL_COMPONENT_BYTES
SMALL = bundle_size.SMALL_ITEMS_LABEL


class BundleSizeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        self.app = self.root / "Threading.app"
        self.baseline = self.root / "baseline.json"

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def write(self, relative: str, size: int, *, compressible: bool = False) -> pathlib.Path:
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"a" * size if compressible else os.urandom(size))
        return path

    def make_bundle(self) -> None:
        self.write("Contents/MacOS/Threading", LARGE + 10)
        self.write("Contents/Helpers/threading-ptyd", 4096)
        self.write("Contents/Helpers/threading-mcp-bridge", 2048)
        self.write("Contents/Resources/Big", LARGE * 2, compressible=True)
        self.write("Contents/Info.plist", 512)
        framework = "Contents/Frameworks/Thing.framework"
        self.write(f"{framework}/Versions/A/Thing", LARGE + 1)
        os.symlink("A", self.app / f"{framework}/Versions/Current")
        os.symlink("Versions/Current/Thing", self.app / f"{framework}/Thing")

    def run_main(self, *arguments: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = bundle_size.main([*arguments, "--baseline", str(self.baseline), str(self.app)])
        return status, out.getvalue(), err.getvalue()

    def test_components_cover_every_regular_file_once(self) -> None:
        self.make_bundle()

        components = bundle_size.measure_bundle(self.app)

        self.assertEqual(
            set(components),
            {
                "Contents/MacOS/Threading",
                "Contents/Helpers/" + SMALL,
                "Contents/Resources/Big",
                "Contents/Frameworks/Thing.framework",
                bundle_size.OTHER_CONTENTS_LABEL,
            },
        )
        self.assertEqual(components["Contents/Helpers/" + SMALL].disk_bytes, 4096 + 2048)
        # The framework's two symlinks point at one binary; it is counted once.
        self.assertEqual(components["Contents/Frameworks/Thing.framework"].disk_bytes, LARGE + 1)
        expected_disk = (LARGE + 10) + 4096 + 2048 + LARGE * 2 + 512 + (LARGE + 1)
        self.assertEqual(bundle_size.total(components).disk_bytes, expected_disk)

    def test_compressed_size_follows_content_not_length(self) -> None:
        self.make_bundle()

        components = bundle_size.measure_bundle(self.app)

        repetitive = components["Contents/Resources/Big"]
        random = components["Contents/MacOS/Threading"]
        self.assertLess(repetitive.compressed_bytes, repetitive.disk_bytes // 100)
        self.assertGreater(random.compressed_bytes, random.disk_bytes * 0.99)

    def test_rejects_a_path_that_is_not_a_bundle(self) -> None:
        self.root.joinpath("plain").mkdir()
        with self.assertRaises(ValueError):
            bundle_size.measure_bundle(self.root / "plain")

    def test_growth_inside_the_allowance_is_noise(self) -> None:
        baseline = {"Contents/MacOS/Threading": bundle_size.Measurement(10_000_000, 5_000_000)}
        observed = {"Contents/MacOS/Threading": bundle_size.Measurement(10_090_000, 5_040_000)}

        violations, notes = bundle_size.compare(observed, baseline)

        self.assertEqual(violations, [])
        self.assertEqual(notes, [])

    def test_growth_past_the_allowance_fails_on_either_measure(self) -> None:
        baseline = {"Contents/MacOS/Threading": bundle_size.Measurement(10_000_000, 5_000_000)}
        observed = {"Contents/MacOS/Threading": bundle_size.Measurement(10_000_000, 5_200_000)}

        violations, _ = bundle_size.compare(observed, baseline)

        self.assertEqual(len(violations), 1)
        self.assertIn("compressed", violations[0])

    def test_small_components_get_the_absolute_allowance(self) -> None:
        baseline = {"Contents/Helpers/" + SMALL: bundle_size.Measurement(200_000, 100_000)}
        within = {"Contents/Helpers/" + SMALL: bundle_size.Measurement(300_000, 200_000)}
        beyond = {"Contents/Helpers/" + SMALL: bundle_size.Measurement(400_000, 100_000)}

        self.assertEqual(bundle_size.compare(within, baseline)[0], [])
        self.assertEqual(len(bundle_size.compare(beyond, baseline)[0]), 1)

    def test_an_unseen_payload_fails_and_a_removed_one_is_a_note(self) -> None:
        baseline = {"Contents/Resources/Old": bundle_size.Measurement(2_000_000, 1_000_000)}
        observed = {"Contents/Resources/New": bundle_size.Measurement(2_000_000, 1_000_000)}

        violations, notes = bundle_size.compare(observed, baseline)

        self.assertEqual(len(violations), 1)
        self.assertIn("Contents/Resources/New: new embedded payload", violations[0])
        self.assertEqual(len(notes), 1)
        self.assertIn("Contents/Resources/Old: gone", notes[0])

    def test_shrinking_passes_and_suggests_locking_it_in(self) -> None:
        self.make_bundle()
        self.assertEqual(self.run_main("--write-baseline", "fixture")[0], 0)
        (self.app / "Contents/Resources/Big").write_bytes(b"")
        self.write("Contents/MacOS/Threading", LARGE + 10, compressible=True)

        status, out, err = self.run_main()

        self.assertEqual(status, 0, err)
        self.assertIn("Contents/MacOS/Threading: shrank", out)
        self.assertIn("--write-baseline", out)

    def test_baseline_round_trips_with_its_provenance(self) -> None:
        self.make_bundle()

        status, _, _ = self.run_main("--write-baseline", "master abc123, release.sh export")
        document = json.loads(self.baseline.read_text(encoding="utf-8"))
        loaded = bundle_size.load_baseline(self.baseline)

        self.assertEqual(status, 0)
        self.assertEqual(document["measuredFrom"], "master abc123, release.sh export")
        self.assertEqual(loaded, bundle_size.measure_bundle(self.app))
        self.assertEqual(self.run_main()[0], 0)

    def test_growth_fails_main_but_not_a_report(self) -> None:
        self.make_bundle()
        self.run_main("--write-baseline", "fixture")
        self.write("Contents/Resources/Payload.bin", LARGE * 3)

        status, _, err = self.run_main()
        report_status, report_out, _ = self.run_main("--report")

        self.assertEqual(status, 1)
        self.assertIn("Contents/Resources/Payload.bin: new embedded payload", err)
        self.assertIn("bundle-size-levers.md", err)
        self.assertEqual(report_status, 0)
        self.assertIn("over baseline", report_out)

    def test_summary_is_one_line_and_needs_no_baseline(self) -> None:
        self.make_bundle()

        status, out, _ = self.run_main("--summary")

        self.assertEqual(status, 0)
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertRegex(out, r"^[0-9.]+ MB on disk, [0-9.]+ MB compressed$")

    def test_a_missing_baseline_is_an_error_outside_report_mode(self) -> None:
        self.make_bundle()

        self.assertEqual(self.run_main()[0], 2)
        self.assertEqual(self.run_main("--report")[0], 0)

    def test_malformed_baselines_are_errors(self) -> None:
        self.make_bundle()
        for document in (
            {"schemaVersion": 99, "components": {}},
            {"schemaVersion": 1, "components": []},
            {"schemaVersion": 1, "components": {"x": {"diskBytes": -1, "compressedBytes": 0}}},
            {"schemaVersion": 1, "components": {"x": {"diskBytes": True, "compressedBytes": 0}}},
        ):
            self.baseline.write_text(json.dumps(document), encoding="utf-8")
            self.assertEqual(self.run_main()[0], 2, document)

    def test_checked_in_baseline_is_well_formed(self) -> None:
        loaded = bundle_size.load_baseline(SCRIPT.parent / "bundle_size_baseline.json")

        self.assertIn("Contents/MacOS/Threading", loaded)

    def test_release_gates_the_export_and_autoinstall_thins_and_reports(self) -> None:
        release = RELEASE_SCRIPT.read_text(encoding="utf-8")
        autoinstall = AUTOINSTALL_SCRIPT.read_text(encoding="utf-8")
        gate = 'scripts/check_bundle_size.py" "$APP"'
        thinning = '"$PROFILE_ARCHIVE/Products/Applications/$SCHEME.app" arm64'

        self.assertTrue(gate in release, "release.sh does not run the bundle-size gate")
        # The gate measures the thinned export, so it must come after the export exists.
        self.assertLess(release.index("-exportArchive"), release.index(gate))
        self.assertTrue(thinning in autoinstall, "autoinstall.sh does not thin its archive")
        # Thinning after export would break the Developer ID seals the export just applied.
        self.assertLess(autoinstall.index(thinning), autoinstall.index("xcodebuild -exportArchive"))
        self.assertTrue(
            'check_bundle_size.py" --report "$PRODUCT"' in autoinstall,
            "autoinstall.sh does not report the size of what it built",
        )


if __name__ == "__main__":
    unittest.main()
