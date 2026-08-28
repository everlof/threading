import contextlib
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "check_swift_warning_ratchet.py"
CI_SCRIPT = SCRIPT.parent / "ci.sh"
SPEC = importlib.util.spec_from_file_location("check_swift_warning_ratchet", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ratchet = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ratchet
SPEC.loader.exec_module(ratchet)


class SwiftWarningRatchetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.scratch.name)
        (self.root / "Sources/App").mkdir(parents=True)
        (self.root / "Tests/AppTests").mkdir(parents=True)
        (self.root / "Sources/App/Feature.swift").touch()
        (self.root / "Tests/AppTests/FeatureTests.swift").touch()

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def write_log(self, text: str) -> pathlib.Path:
        path = self.root / "build.log"
        path.write_text(text, encoding="utf-8")
        return path

    def test_parser_counts_repository_diagnostics_and_swift6_subset(self) -> None:
        log = self.write_log(
            f"{self.root}/Sources/App/Feature.swift:4:9: warning: ordinary warning\n"
            f"{self.root}/Sources/App/Feature.swift:8:2: warning: send risk; "
            "this is an error in the Swift 6 language mode\n"
            "/tmp/dependency/Other.swift:1:1: warning: external warning\n"
            "** BUILD SUCCEEDED **\n"
        )

        counts, all_logs_succeeded = ratchet.parse_logs([log], self.root)

        self.assertTrue(all_logs_succeeded)
        self.assertEqual(counts["Sources/App/Feature.swift"].warnings, 2)
        self.assertEqual(counts["Sources/App/Feature.swift"].swift6_language_mode, 1)
        self.assertEqual(set(counts), {"Sources/App/Feature.swift"})

    def test_parser_counts_repeated_batch_diagnostic_once_per_lane(self) -> None:
        diagnostic = (
            f"{self.root}/Tests/AppTests/FeatureTests.swift:8:2: warning: send risk; "
            "this is an error in the Swift 6 language mode\n"
        )
        first_lane = self.write_log(diagnostic * 25 + "** BUILD SUCCEEDED **\n")
        second_lane = self.root / "second-lane.log"
        second_lane.write_text(
            diagnostic * 3 + "** TEST SUCCEEDED **\n",
            encoding="utf-8",
        )

        one_lane, _ = ratchet.parse_logs([first_lane], self.root)
        both_lanes, _ = ratchet.parse_logs([first_lane, second_lane], self.root)

        self.assertEqual(one_lane["Tests/AppTests/FeatureTests.swift"].warnings, 1)
        self.assertEqual(one_lane["Tests/AppTests/FeatureTests.swift"].swift6_language_mode, 1)
        self.assertEqual(both_lanes["Tests/AppTests/FeatureTests.swift"].warnings, 2)
        self.assertEqual(both_lanes["Tests/AppTests/FeatureTests.swift"].swift6_language_mode, 2)

    def test_per_file_ceiling_cannot_be_borrowed_by_another_file(self) -> None:
        baseline = {
            "Sources/App/Feature.swift": ratchet.WarningCounts(2, 1),
        }
        observed = {
            "Sources/App/Feature.swift": ratchet.WarningCounts(1, 0),
            "Tests/AppTests/FeatureTests.swift": ratchet.WarningCounts(1, 1),
        }

        violations = ratchet.ratchet_violations(observed, baseline)

        self.assertEqual(len(violations), 2)
        self.assertTrue(all("Tests/AppTests/FeatureTests.swift" in item for item in violations))

    def test_lower_counts_pass_and_each_independent_ceiling_is_enforced(self) -> None:
        baseline = {"Sources/App/Feature.swift": ratchet.WarningCounts(4, 2)}

        self.assertEqual(
            ratchet.ratchet_violations(
                {"Sources/App/Feature.swift": ratchet.WarningCounts(3, 2)},
                baseline,
            ),
            [],
        )
        self.assertEqual(
            ratchet.ratchet_violations(
                {"Sources/App/Feature.swift": ratchet.WarningCounts(3, 3)},
                baseline,
            ),
            [
                "Sources/App/Feature.swift: Swift-6-mode diagnostics grew from 2 to 3"
            ],
        )

    def test_baseline_round_trip_is_sorted_and_validated(self) -> None:
        path = self.root / "baseline.json"
        ratchet.write_baseline(
            path,
            {
                "Tests/AppTests/FeatureTests.swift": ratchet.WarningCounts(3, 2),
                "Sources/App/Feature.swift": ratchet.WarningCounts(1, 0),
            },
        )

        document = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(
            list(document["files"]),
            ["Sources/App/Feature.swift", "Tests/AppTests/FeatureTests.swift"],
        )
        self.assertEqual(
            ratchet.load_baseline(path),
            {
                "Sources/App/Feature.swift": ratchet.WarningCounts(1, 0),
                "Tests/AppTests/FeatureTests.swift": ratchet.WarningCounts(3, 2),
            },
        )

    def test_cli_refuses_a_log_that_did_not_finish_successfully(self) -> None:
        log = self.write_log(
            f"{self.root}/Sources/App/Feature.swift:4:9: warning: unfinished\n"
        )

        with contextlib.redirect_stderr(io.StringIO()):
            status = ratchet.main([
                "--root",
                str(self.root),
                "--baseline",
                str(self.root / "missing.json"),
                str(log),
            ])

        self.assertEqual(status, 2)

    def test_cli_refuses_one_incomplete_log_beside_a_successful_log(self) -> None:
        successful = self.root / "successful.log"
        successful.write_text("** BUILD SUCCEEDED **\n", encoding="utf-8")
        incomplete = self.root / "incomplete.log"
        incomplete.write_text(
            f"{self.root}/Sources/App/Feature.swift:4:9: warning: unfinished\n",
            encoding="utf-8",
        )

        with contextlib.redirect_stderr(io.StringIO()):
            status = ratchet.main([
                "--root",
                str(self.root),
                "--baseline",
                str(self.root / "missing.json"),
                str(successful),
                str(incomplete),
            ])

        self.assertEqual(status, 2)

    def test_ci_captures_each_cold_xcode_lane_before_checking_the_ratchet(self) -> None:
        script = CI_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('ci_derived_data="${ci_scratch}/DerivedData"', script)
        self.assertIn("capture_swift_warnings mobile-build xcodebuild", script)
        self.assertIn("capture_swift_warnings mobile-tests", script)
        self.assertIn("capture_swift_warnings mac-tests", script)
        self.assertEqual(script.count('-derivedDataPath "${ci_derived_data}"'), 3)
        self.assertIn('"${swift_warning_logs[@]}"', script)


if __name__ == "__main__":
    unittest.main()
