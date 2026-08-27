import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "connectivity_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("connectivity_diagnostics", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
diagnostics = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = diagnostics
SPEC.loader.exec_module(diagnostics)


def record(timestamp: str, event: str, **fields: str) -> dict[str, object]:
    return {
        "timestamp": timestamp,
        "source": "iOSClient",
        "level": "info",
        "event": event,
        "fields": fields,
    }


class ConnectivityDiagnosticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, name: str, records: list[dict[str, object]]) -> None:
        path = self.directory / name
        path.write_text(
            "".join(json.dumps(item) + "\n" for item in records),
            encoding="utf-8",
        )

    def run_tool(self, *arguments: str) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status = diagnostics.main(list(arguments))
        return status, stdout.getvalue(), stderr.getvalue()

    def test_marker_is_newest_record_across_journal_files(self) -> None:
        self.write(
            "remote-diagnostics-2026-08-25.jsonl",
            [record("2026-08-25T23:59:59.000Z", "hostRefreshFailed")],
        )
        self.write(
            "remote-diagnostics-2026-08-26.jsonl",
            [record("2026-08-26T00:00:01.000Z", "hostRefreshSucceeded")],
        )

        status, output, error = self.run_tool("marker", str(self.directory))

        self.assertEqual(status, 0, error)
        self.assertEqual(output.strip(), "2026-08-26T00:00:01.000Z")

    def test_check_requires_a_new_event_and_field_constraints(self) -> None:
        self.write(
            "remote-diagnostics-2026-08-26.jsonl",
            [
                record("2026-08-26T10:00:00.000Z", "hostRefreshSucceeded", transport="lan"),
                record(
                    "2026-08-26T10:00:01.000Z",
                    "hostRefreshSucceeded",
                    transport="tailscale",
                ),
            ],
        )

        status, output, error = self.run_tool(
            "check",
            str(self.directory),
            "--after",
            "2026-08-26T10:00:00.000Z",
            "--event",
            "hostRefreshSucceeded",
            "--field-not",
            "transport=lan",
        )

        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output)["fields"]["transport"], "tailscale")

    def test_check_accepts_either_terminal_event(self) -> None:
        self.write(
            "remote-diagnostics-2026-08-26.jsonl",
            [record("2026-08-26T10:00:02.000Z", "hostRefreshFailed", result="failed")],
        )

        status, output, error = self.run_tool(
            "check",
            str(self.directory),
            "--event",
            "hostRefreshSucceeded",
            "--event",
            "hostRefreshFailed",
        )

        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(output)["event"], "hostRefreshFailed")

    def test_excluded_field_requires_the_field_to_exist(self) -> None:
        self.write(
            "remote-diagnostics-2026-08-26.jsonl",
            [record("2026-08-26T10:00:02.000Z", "hostRefreshSucceeded")],
        )

        status, _, error = self.run_tool(
            "check",
            str(self.directory),
            "--event",
            "hostRefreshSucceeded",
            "--field-not",
            "transport=lan",
        )

        self.assertEqual(status, 1)
        self.assertIn("no new matching record", error)

    def test_malformed_journal_fails_closed(self) -> None:
        (self.directory / "remote-diagnostics-2026-08-26.jsonl").write_text(
            "{not-json}\n",
            encoding="utf-8",
        )

        status, _, error = self.run_tool("marker", str(self.directory))

        self.assertEqual(status, 2)
        self.assertIn("invalid JSON", error)


if __name__ == "__main__":
    unittest.main()
