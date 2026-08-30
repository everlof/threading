#!/usr/bin/env python3
"""Executable parity checks for the shipped workspace-navigator JSON schemas."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


REPOSITORY = Path(__file__).resolve().parents[2]
SCHEMA_DIRECTORY = REPOSITORY / "docs" / "extensions" / "schema"
ACTIVITY_MANIFEST = (
    REPOSITORY
    / "Packages"
    / "ThreadingExtensionKit"
    / "Examples"
    / "ActivityInboxExtension"
    / "threading-extension.json"
)
T3_MANIFEST = (
    REPOSITORY
    / "Packages"
    / "ThreadingExtensionKit"
    / "Examples"
    / "T3SidebarExtension"
    / "threading-extension.json"
)


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def schema_validator(filename: str):
    schemas = [load_json(path) for path in sorted(SCHEMA_DIRECTORY.glob("*.json"))]
    registry = Registry().with_resources(
        (schema["$id"], Resource.from_contents(schema)) for schema in schemas
    )
    schema = next(
        value for value in schemas if value["$id"].endswith(f"/{filename}")
    )
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, registry=registry)


class WorkspaceNavigatorSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest_validator = schema_validator("extension-manifest.schema.json")
        cls.process_validator = schema_validator("extension-process.schema.json")
        cls.activity_manifest = load_json(ACTIVITY_MANIFEST)
        cls.t3_manifest = load_json(T3_MANIFEST)

    def assert_valid(self, validator, value: dict) -> None:
        errors = sorted(validator.iter_errors(value), key=lambda error: list(error.path))
        self.assertEqual([], errors, "\n".join(error.message for error in errors))

    def assert_invalid(self, validator, value: dict) -> None:
        self.assertNotEqual([], list(validator.iter_errors(value)))

    def test_shipped_activity_manifest_resolves_and_validates(self) -> None:
        self.assert_valid(self.manifest_validator, self.activity_manifest)

    def test_shipped_t3_manifest_resolves_and_validates(self) -> None:
        self.assert_valid(self.manifest_validator, self.t3_manifest)

    def test_windowing_is_optional_but_never_null_or_unknown(self) -> None:
        legacy = copy.deepcopy(self.activity_manifest)
        output = legacy["workspaceNavigators"][0]["pipeline"]["output"]
        output.pop("windowing")
        self.assert_valid(self.manifest_validator, legacy)

        explicit_null = copy.deepcopy(self.activity_manifest)
        explicit_null["workspaceNavigators"][0]["pipeline"]["output"][
            "windowing"
        ] = None
        self.assert_invalid(self.manifest_validator, explicit_null)

        unknown = copy.deepcopy(self.activity_manifest)
        unknown["workspaceNavigators"][0]["pipeline"]["output"][
            "windowing"
        ] = "extensionPaged"
        self.assert_invalid(self.manifest_validator, unknown)

    def test_pipeline_intent_vocabulary_is_bounded_and_requires_a_pipeline(self) -> None:
        manifest = copy.deepcopy(self.activity_manifest)
        navigator = manifest["workspaceNavigators"][0]
        navigator["intents"] = ["pin", "archive"]
        navigator["pipeline"]["output"]["rowTemplate"]["children"].extend(
            [
                {"type": "intent", "intent": "pin"},
                {"type": "intent", "intent": "archive"},
            ]
        )
        self.assert_valid(self.manifest_validator, manifest)

        unknown = copy.deepcopy(manifest)
        unknown["workspaceNavigators"][0]["intents"] = ["delete"]
        self.assert_invalid(self.manifest_validator, unknown)

        duplicate = copy.deepcopy(manifest)
        duplicate["workspaceNavigators"][0]["intents"] = ["pin", "pin"]
        self.assert_invalid(self.manifest_validator, duplicate)

        legacy = copy.deepcopy(manifest)
        legacy_navigator = legacy["workspaceNavigators"][0]
        legacy_navigator.pop("pipeline")
        self.assert_invalid(self.manifest_validator, legacy)

    def test_registered_fact_options_are_tagged_and_bounded(self) -> None:
        manifest = copy.deepcopy(self.activity_manifest)
        pipeline = manifest["workspaceNavigators"][0]["pipeline"]
        pipeline["registeredFactOptions"] = [
            {
                "id": "group-by-fact",
                "title": "Group by",
                "application": {
                    "type": "bucket",
                    "direction": "ascending",
                    "unknownTitle": "Unknown",
                },
            },
            {
                "id": "sort-by-fact",
                "title": "Sort by",
                "application": {"type": "sort", "direction": "descending"},
            },
        ]
        self.assert_valid(self.manifest_validator, manifest)

        duplicate_application = copy.deepcopy(manifest)
        duplicate_application["workspaceNavigators"][0]["pipeline"][
            "registeredFactOptions"
        ][1]["application"] = {
            "type": "bucket",
            "direction": "descending",
            "unknownTitle": "Missing",
        }
        self.assert_invalid(self.manifest_validator, duplicate_application)

        too_many = copy.deepcopy(manifest)
        too_many["workspaceNavigators"][0]["pipeline"][
            "registeredFactOptions"
        ].append(
            {
                "id": "third-fact-control",
                "title": "Third",
                "application": {"type": "sort", "direction": "ascending"},
            }
        )
        self.assert_invalid(self.manifest_validator, too_many)

        unknown_tag = copy.deepcopy(manifest)
        unknown_tag["workspaceNavigators"][0]["pipeline"][
            "registeredFactOptions"
        ][0]["application"]["type"] = "filter"
        self.assert_invalid(self.manifest_validator, unknown_tag)

        missing_unknown_title = copy.deepcopy(manifest)
        del missing_unknown_title["workspaceNavigators"][0]["pipeline"][
            "registeredFactOptions"
        ][0]["application"]["unknownTitle"]
        self.assert_invalid(self.manifest_validator, missing_unknown_title)

    def test_manifest_rejects_whitespace_navigator_title_and_v1_status(self) -> None:
        title = copy.deepcopy(self.activity_manifest)
        title["workspaceNavigators"][0]["title"] = " \n\t"
        self.assert_invalid(self.manifest_validator, title)

        fallback = copy.deepcopy(self.activity_manifest)
        fallback["workspaceNavigators"][0]["root"]["content"]["text"] = " \n\t"
        self.assert_invalid(self.manifest_validator, fallback)

    def test_process_rejects_whitespace_item_patch_content(self) -> None:
        contents = [
            {"type": "text", "text": " \n\t", "role": "body"},
            {
                "type": "button",
                "id": "refresh",
                "title": " \n\t",
                "role": "standard",
                "isEnabled": True,
            },
            {"type": "status", "text": " \n\t", "role": "neutral"},
        ]
        for content in contents:
            with self.subTest(content_type=content["type"]):
                response = {
                    "protocolVersion": 1,
                    "requestID": "schema-test",
                    "navigatorID": "activity-inbox",
                    "itemPatches": [
                        {
                            "collectionID": "sessions",
                            "itemID": "session",
                            "content": content,
                        }
                    ],
                }
                self.assert_invalid(self.process_validator, response)


if __name__ == "__main__":
    unittest.main()
