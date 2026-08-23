#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


SCRIPT_PATH = pathlib.Path(__file__).resolve().parents[1] / "localization_boundary_lint.py"
SPEC = importlib.util.spec_from_file_location("localization_boundary_lint", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
lint = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = lint
SPEC.loader.exec_module(lint)


class MobileAccessibilityLocalizationTests(unittest.TestCase):
    def test_raw_accessibility_literal_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write_fixture(root, '.accessibilityLabel("Attachments")')

            findings = lint.audit_mobile(root)

            self.assertIn(
                'SwiftUI "accessibilityLabel" literal must resolve through MobileL10n',
                {finding.message for finding in findings},
            )

    def test_explicitly_localized_accessibility_literal_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.write_fixture(
                root,
                '.accessibilityLabel(MobileL10n.string("Attachments"))',
            )

            findings = lint.audit_mobile(root)

            self.assertEqual(findings, [])

    @staticmethod
    def write_fixture(root: pathlib.Path, modifier: str) -> None:
        mobile = root / "Sources/ThreadingMobile"
        mobile.mkdir(parents=True)
        (mobile / "Fixture.swift").write_text(
            f'import SwiftUI\nText("Attachments"){modifier}\n',
            encoding="utf-8",
        )
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "Attachments": {
                    "localizations": {
                        "sv": {
                            "stringUnit": {
                                "state": "translated",
                                "value": "Bilagor",
                            }
                        }
                    }
                }
            },
        }
        (mobile / "Localizable.xcstrings").write_text(
            json.dumps(catalog),
            encoding="utf-8",
        )
        (mobile / "ThreadingMobile-InfoPlist.xcstrings").write_text(
            json.dumps({"sourceLanguage": "en", "strings": {}}),
            encoding="utf-8",
        )
        for relative_path in lint.REMOTE_LOCALIZATION_SOURCES:
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("", encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
