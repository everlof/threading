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


class CanonicalCatalogTests(unittest.TestCase):
    """The catalogues must be byte-identical to what `xcstringstool sync` would write back.

    Xcode's build-time sync rewrote 60,000 lines of both files in one Run; keeping them in the
    tool's own layout with every entry manual leaves the sync nothing to change.
    """

    ENTRY = {"localizations": {"sv": {"stringUnit": {"state": "translated", "value": "Bilagor"}}}}

    def test_compact_insertion_ordered_catalog_is_rejected_until_formatted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / lint.MOBILE_CATALOG_PATH
            path.parent.mkdir(parents=True)
            path.write_text(
                '{"sourceLanguage": "en", "version": "1.2", "strings": {'
                '"Zebra": ' + json.dumps(self.ENTRY) + ', '
                '"Attachments": ' + json.dumps(self.ENTRY) + '}}\n',
                encoding="utf-8",
            )

            messages = {finding.message for finding in lint.canonical_findings(root)}
            self.assertEqual(len(messages), 1)
            self.assertIn("canonical layout", next(iter(messages)))

            self.assertEqual(lint.format_catalogs(root), 0)
            self.assertEqual(lint.canonical_findings(root), [])

            text = path.read_text(encoding="utf-8")
            self.assertTrue(text.startswith('{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "Attachments" : {\n'))
            self.assertFalse(text.endswith("\n"))
            document = json.loads(text)
            self.assertEqual(list(document["strings"]), ["Attachments", "Zebra"])
            self.assertTrue(all(
                entry["extractionState"] == "manual" for entry in document["strings"].values()
            ))

            # Formatting is idempotent, which is what makes a build a no-op.
            self.assertEqual(lint.format_catalogs(root), 0)
            self.assertEqual(path.read_text(encoding="utf-8"), text)

    def test_info_plist_catalog_keeps_extracted_states(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / lint.MOBILE_INFO_CATALOG_PATH
            path.parent.mkdir(parents=True)
            entry = {
                "extractionState": "extracted_with_value",
                "localizations": {
                    "en": {"stringUnit": {"state": "new", "value": "Threading"}},
                    "sv": {"stringUnit": {"state": "translated", "value": "Threading"}},
                },
            }
            path.write_text(
                json.dumps({"sourceLanguage": "en", "strings": {"CFBundleName": entry}}),
                encoding="utf-8",
            )

            self.assertEqual(lint.format_catalogs(root), 0)
            document = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(
                document["strings"]["CFBundleName"]["extractionState"],
                "extracted_with_value",
            )
            self.assertEqual(lint.canonical_findings(root), [])

    def test_duplicate_key_is_reported_and_collapses_to_its_last_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / lint.CATALOG_PATH
            path.parent.mkdir(parents=True)
            first = json.dumps(self.ENTRY)
            second = json.dumps({
                "localizations": {"sv": {"stringUnit": {"state": "translated", "value": "Senare"}}}
            })
            path.write_text(
                '{"sourceLanguage": "en", "version": "1.0", "strings": {'
                f'"Attachments": {first}, "Attachments": {second}}}}}',
                encoding="utf-8",
            )

            messages = {finding.message for finding in lint.canonical_findings(root)}
            self.assertTrue(any('duplicate key "Attachments"' in message for message in messages))

            self.assertEqual(lint.format_catalogs(root), 0)
            document = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(
                document["strings"]["Attachments"]["localizations"]["sv"]["stringUnit"]["value"],
                "Senare",
            )
            self.assertEqual(lint.canonical_findings(root), [])


if __name__ == "__main__":
    unittest.main()
