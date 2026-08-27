import copy
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "generate_diagnostic_contract.py"
SPEC = importlib.util.spec_from_file_location("generate_diagnostic_contract", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)

REPOSITORY = Path(__file__).parents[2]
CONTRACT = (
    REPOSITORY
    / "Packages/ThreadingRemoteKit/Contracts/RemoteDiagnosticContract.json"
)


class DiagnosticContractGeneratorTests(unittest.TestCase):
    def test_checked_in_projections_are_current_and_share_one_fingerprint(self) -> None:
        contract = generator.read_contract(CONTRACT)
        digest = generator.fingerprint(contract)
        swift = generator.render_swift(contract, digest)
        typescript = generator.render_typescript(contract, digest)

        self.assertIn(f'public static let fingerprint = "{digest}"', swift)
        self.assertIn(f'diagnosticContractFingerprint = "{digest}"', typescript)
        self.assertEqual(
            swift,
            (
                REPOSITORY
                / "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/RemoteDiagnosticContract.generated.swift"
            ).read_text(encoding="utf-8"),
        )
        self.assertEqual(
            typescript,
            (
                REPOSITORY
                / "Service/ThreadingControlPlane/src/issue-report-contract.generated.ts"
            ).read_text(encoding="utf-8"),
        )

    def test_duplicate_wire_name_is_rejected_before_generation(self) -> None:
        contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
        contract["fields"].append(copy.deepcopy(contract["fields"][0]))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(contract), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "duplicate fields name"):
                generator.read_contract(path)

    def test_unknown_platform_source_is_rejected_before_generation(self) -> None:
        contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
        contract["extraFields"][0]["reportSources"] = ["futureClient"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(contract), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "contains unknown sources"):
                generator.read_contract(path)

    def test_fingerprint_tracks_behavior_not_prose_or_presentation_order(self) -> None:
        contract = generator.read_contract(CONTRACT)
        digest = generator.fingerprint(contract)

        presentation_only = copy.deepcopy(contract)
        presentation_only["events"][0]["clientUploadSources"].reverse()
        presentation_only["events"].reverse()
        presentation_only["events"][0]["description"] = "Reworded documentation."
        self.assertEqual(generator.fingerprint(presentation_only), digest)

        behavioral_change = copy.deepcopy(contract)
        behavioral_change["fields"][0]["validation"] = "unsignedInteger"
        self.assertNotEqual(generator.fingerprint(behavioral_change), digest)

    def test_stale_projection_reports_the_file_and_diff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "generated.swift"
            path.write_text("old\n", encoding="utf-8")
            stderr = io.StringIO()

            with redirect_stderr(stderr):
                matches = generator.compare(path, "new\n")

            self.assertFalse(matches)
            self.assertIn("generated file is stale", stderr.getvalue())
            self.assertIn("-old", stderr.getvalue())
            self.assertIn("+new", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
