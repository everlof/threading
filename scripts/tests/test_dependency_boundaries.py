#!/usr/bin/env python3
"""Regression tests for inferred Core-to-UI controller dependencies."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "check_dependency_boundaries.py"


class DependencyBoundaryTests(unittest.TestCase):
    def test_rejects_dotted_controller_lookup_anywhere_in_core(self) -> None:
        repository = self.fixture_repository()
        self.write(
            repository,
            "Sources/Threading/Core/Agent/Delivery.swift",
            "func deliver(runtime: AgentRuntime, id: SessionID) { "
            "_ = runtime.controller(for: id) }\n",
        )

        result = self.run_checker(repository)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Core must not use a controller-returning lookup", result.stderr)

    def test_rejects_unqualified_controller_lookup_anywhere_in_core(self) -> None:
        repository = self.fixture_repository()
        self.write(
            repository,
            "Sources/Threading/Core/Agent/ContextHandoff.swift",
            "extension AgentRuntime { func handoff(id: SessionID) { "
            "_ = controller(for: id) } }\n",
        )

        result = self.run_checker(repository)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Core must not use a controller-returning lookup", result.stderr)

    def test_accepts_core_with_only_typed_runtime_capabilities(self) -> None:
        result = self.run_checker(self.fixture_repository())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 ratcheted concrete-controller references remain", result.stdout)

    def test_rejects_concrete_ui_controller_type_in_core(self) -> None:
        repository = self.fixture_repository()
        self.write(
            repository,
            "Sources/Threading/Core/Agent/AgentRuntime.swift",
            "let surface: ConversationViewController?\n",
        )

        result = self.run_checker(repository)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ConversationViewController appears 1 time(s)", result.stderr)

    def fixture_repository(self) -> pathlib.Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        repository = pathlib.Path(temporary.name)

        self.write(
            repository,
            "Sources/Threading/UI/Views/ConversationViewController.swift",
            "class ConversationViewController {}\n",
        )
        self.write(
            repository,
            "Sources/Threading/UI/Views/ProjectTerminalViewController.swift",
            "class ProjectTerminalViewController {}\n",
        )
        self.write(
            repository,
            "Sources/Threading/Core/Agent/AgentRuntime.swift",
            "protocol AgentConversationRuntimeSurface {}\n",
        )
        self.write(
            repository,
            "Sources/Threading/Core/Session/ProjectTerminalRuntime.swift",
            "protocol ProjectTerminalRuntimeSurface {}\n",
        )
        self.write(
            repository,
            "Sources/Threading/Core/Session/TerminalNaming.swift",
            "let title = runtime.foregroundProcessName(for: terminal.id)\n",
        )
        return repository

    def run_checker(self, repository: pathlib.Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), str(repository)],
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def write(repository: pathlib.Path, relative: str, contents: str) -> None:
        path = repository / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
