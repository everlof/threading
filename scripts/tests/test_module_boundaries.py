from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts/check_module_boundaries.py"


class ModuleBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.domain = self.root / "Packages/ThreadingDomain/Sources/ThreadingDomain"
        self.application = self.root / "Sources/Threading/Application"
        self.pty_host = self.root / "Packages/ThreadingPTYHostKit/Sources/ThreadingPTYHostKit"
        self.controller = self.root / "Packages/ThreadingController/Sources/ThreadingController"
        self.controller_runtime = self.root / "Targets/Controller/Sources/ControllerRuntime"
        self.domain.mkdir(parents=True)
        self.application.mkdir(parents=True)
        self.pty_host.mkdir(parents=True)
        self.controller.mkdir(parents=True)
        self.controller_runtime.mkdir(parents=True)
        # Every declared module root must exist in the fixture, as in the repository.
        (self.root / "Packages/ThreadingUsage/Sources/ThreadingUsage").mkdir(parents=True)
        (self.controller / "Store.swift").write_text(
            "import Foundation\nimport CControllerSQLite\n", encoding="utf-8"
        )
        (self.domain / "Identity.swift").write_text("import Foundation\n", encoding="utf-8")
        (self.pty_host / "Frame.swift").write_text(
            "import Foundation\nimport ThreadingDomain\n", encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_checker(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), str(self.root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_application_accepts_only_explicit_lower_level_modules(self) -> None:
        (self.application / "Feature.swift").write_text(
            "\n".join([
                "import Foundation",
                "import ThreadingDomain",
                "import ThreadingExtensionKit",
                "import ThreadingRemoteKit",
                "",
            ]),
            encoding="utf-8",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_new_nested_application_file_cannot_import_appkit(self) -> None:
        violating = self.application / "NewFeature/AccidentalView.swift"
        violating.parent.mkdir(parents=True)
        violating.write_text("import Foundation\nimport AppKit\n", encoding="utf-8")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "Sources/Threading/Application/NewFeature/AccidentalView.swift imports AppKit",
            result.stderr,
        )
        self.assertIn("Threading/Application allows only", result.stderr)

    def test_the_pty_host_contract_cannot_reach_past_the_domain(self) -> None:
        """The daemon and the app link this package. A single AppKit or app-module import here
        would put the app's stores and emulation inside a process whose safety argument is that
        it holds neither."""
        (self.pty_host / "Leak.swift").write_text(
            "import Foundation\nimport ThreadingRemoteKit\n",
            encoding="utf-8",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("imports ThreadingRemoteKit", result.stderr)
        self.assertIn("ThreadingPTYHostKit allows only", result.stderr)

    def test_controller_cannot_import_pty_or_app_services(self) -> None:
        (self.controller / "Leak.swift").write_text(
            "import ThreadingPTYClient\nimport AppKit\n", encoding="utf-8"
        )
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("imports ThreadingPTYClient", result.stderr)
        self.assertIn("imports AppKit", result.stderr)

    def test_controller_runtime_cannot_import_the_application(self) -> None:
        (self.controller_runtime / "Leak.swift").write_text("import Threading\n", encoding="utf-8")
        result = self.run_checker()
        self.assertEqual(result.returncode, 1)
        self.assertIn("imports Threading", result.stderr)

    def test_application_rejects_an_unapproved_project_module(self) -> None:
        (self.application / "Feature.swift").write_text(
            "import Foundation\nimport ThreadingUI\n",
            encoding="utf-8",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("imports ThreadingUI", result.stderr)


if __name__ == "__main__":
    unittest.main()
