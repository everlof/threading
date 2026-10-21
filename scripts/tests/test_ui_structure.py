#!/usr/bin/env python3
"""Regression tests for the desktop structural-site inventory and ceiling."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "check_ui_structure.py"
CATEGORIES = ("controllers", "platform_views", "constraints", "drawing")
LINUX_CATEGORIES = ("linux_platform_views", "linux_constraints", "linux_stacks")


class UIStructureTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.write(root, "Sources/Threading/UI/Views/Existing.swift", """
            class Existing: NSViewController {
                override func draw(_ rect: NSRect) { }
                func mount(_ view: NSView) {
                    NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 42)])
                }
            }
            class Surface: NSView { }
            """)
        self.write(root, "scripts/config/ui-structure-baseline.json", json.dumps({
            "controllers": 1, "platform_views": 1, "constraints": 2, "drawing": 1,
            "linux_platform_views": 0, "linux_constraints": 0, "linux_stacks": 0,
        }))
        return root

    def test_current_ceiling_accepts_existing_structure(self) -> None:
        result = self.run_checker(self.fixture())
        self.assertEqual(result.returncode, 0, result.stderr)
        for category, count in zip(CATEGORIES, (1, 1, 2, 1)):
            self.assertIn(f"{category}: {count} sites", result.stdout)

    def test_new_feature_controller_and_constraint_exceed_ceiling(self) -> None:
        root = self.fixture()
        self.write(root, "Sources/Threading/UI/Views/New.swift", """
            final class NewScreen<Value>:
                AppKit.NSViewController { }
            let pin = view.topAnchor.constraint(equalTo: root.topAnchor)
            """)
        result = self.run_checker(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("controllers: 2 sites exceed the 1-site ceiling", result.stderr)
        self.assertIn("constraints: 3 sites exceed the 2-site ceiling", result.stderr)

    def test_reduced_debt_requires_lower_baseline(self) -> None:
        root = self.fixture()
        self.write(root, "Sources/Threading/UI/Views/Existing.swift", "class Surface: NSView { }\n")
        result = self.run_checker(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("controllers: 0 sites remain; lower the 1-site ceiling", result.stderr)

    def test_design_adapter_and_comment_examples_are_not_feature_sites(self) -> None:
        root = self.fixture()
        self.write(root, "Sources/Threading/UI/Design/Component.swift", """
            class Component: NSViewController { }
            NSLayoutConstraint.activate([])
            """)
        self.write(root, "Sources/Threading/UI/Views/Examples.swift", '''
            /* nested /* class Example: NSViewController */
               NSLayoutConstraint.activate([]) */
            let example = #"class StringExample: NSViewController"#
            let longer = """override func draw(_ rect: NSRect) { NSBezierPath() }"""
            // view.topAnchor.constraint(equalTo: root.topAnchor)
            ''')
        result = self.run_checker(root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_build_gate_runs_the_checker(self) -> None:
        gate = SCRIPT.parent / "check_architecture_boundaries.sh"
        self.assertIn('check_ui_structure.py', gate.read_text(encoding="utf-8"))

    def test_linux_runtime_hierarchy_exceeds_its_own_ceiling(self) -> None:
        root = self.fixture()
        self.write(root, "Platforms/Linux/Sources/WindowHarness/NewPane.swift", """
            final class NewPane: NSView {
                let content = NSStackView()
                func mount(_ view: NSView) {
                    NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: topAnchor)])
                }
            }
            """)
        result = self.run_checker(root)
        self.assertNotEqual(result.returncode, 0)
        for category, count in zip(LINUX_CATEGORIES, (1, 2, 1)):
            self.assertIn(f"{category}: {count} sites exceed the 0-site ceiling", result.stderr)

    def test_linux_design_symlink_is_not_counted_again(self) -> None:
        root = self.fixture()
        design = root / "Sources/Threading/UI/Design/SharedPane.swift"
        self.write(root, "Sources/Threading/UI/Design/SharedPane.swift",
                   "final class SharedPane: NSView { }\n")
        link = root / "Platforms/Linux/Sources/WindowHarness/SharedPane.swift"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(design)
        result = self.run_checker(root)
        self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def write(root: Path, relative: str, contents: str) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    @staticmethod
    def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), str(root)], check=False, capture_output=True, text=True,
        )


if __name__ == "__main__":
    unittest.main()
