#!/usr/bin/env python3
"""Executable parity checks for the public source-control extension schemas."""

from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


REPOSITORY = Path(__file__).resolve().parents[2]
SCHEMA_DIRECTORY = REPOSITORY / "docs" / "extensions" / "schema"
FORGEJO_MANIFEST = (
    REPOSITORY
    / "Packages"
    / "ThreadingExtensionKit"
    / "Examples"
    / "ForgejoSourceControlExtension"
    / "threading-extension.json"
)


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def schema_validator(
    filename: str, definition: str | None = None
) -> Draft202012Validator:
    schemas = [load_json(path) for path in sorted(SCHEMA_DIRECTORY.glob("*.json"))]
    registry = Registry().with_resources(
        (schema["$id"], Resource.from_contents(schema)) for schema in schemas
    )
    schema = next(value for value in schemas if value["$id"].endswith(f"/{filename}"))
    selected = schema if definition is None else {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$ref": f"{schema['$id']}#/$defs/{definition}",
    }
    Draft202012Validator.check_schema(selected)
    return Draft202012Validator(selected, registry=registry)


class SourceControlSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = schema_validator("extension-manifest.schema.json")
        cls.process = schema_validator("extension-process.schema.json")
        cls.fetch = schema_validator("extension-source-control.schema.json", "fetchRequest")

    def assert_valid(self, validator: Draft202012Validator, value: dict) -> None:
        errors = sorted(validator.iter_errors(value), key=lambda error: list(error.path))
        self.assertEqual([], errors, "\n".join(error.message for error in errors))

    def assert_invalid(self, validator: Draft202012Validator, value: dict) -> None:
        self.assertNotEqual([], list(validator.iter_errors(value)))

    def request(self) -> dict:
        return {
            "protocolVersion": 1,
            "requestID": "request-one",
            "providerID": "forgejo",
            "connectionID": "connection-one",
            "operation": "discover",
            "repository": {
                "host": "forge.example",
                "namespace": "team",
                "name": "repo",
                "branch": "feature/providers",
                "headRevision": "abc123",
            },
        }

    def test_shipped_forgejo_manifest_resolves_and_validates(self) -> None:
        self.assert_valid(self.manifest, load_json(FORGEJO_MANIFEST))

    def test_process_accepts_the_typed_request_and_response(self) -> None:
        self.assert_valid(self.process, self.request())
        self.assert_valid(
            self.process,
            {
                "protocolVersion": 1,
                "requestID": "request-one",
                "providerID": "forgejo",
                "defaultBranch": "main",
                "changeRequest": {
                    "number": 42,
                    "title": "Typed provider boundary",
                    "webURL": "https://forge.example/team/repo/pulls/42",
                    "lifecycle": {"normalized": "draft", "providerValue": "open"},
                    "baseBranch": "main",
                    "headBranch": "feature/providers",
                    "headRevision": "abc123",
                    "checks": {
                        "successful": 6,
                        "nonBlocking": 0,
                        "active": 1,
                        "needsAttention": 0,
                        "unknown": 0,
                        "isIncomplete": False,
                    },
                    "reviews": {
                        "approvals": 2,
                        "changesRequested": 0,
                        "requested": 1,
                    },
                },
            },
        )

    def test_operation_shapes_are_closed(self) -> None:
        probe = self.request()
        probe["operation"] = "probe"
        self.assert_invalid(self.process, probe)

        lifecycle = self.request()
        lifecycle["operation"] = "lifecycle"
        self.assert_invalid(self.process, lifecycle)
        lifecycle["changeRequestNumber"] = 42
        self.assert_valid(self.process, lifecycle)

    def test_fetch_cannot_choose_authority_or_smuggle_it_in_headers(self) -> None:
        fetch = {
            "connectionID": "connection-one",
            "method": "GET",
            "path": "/repos/team/repo",
            "queryItems": [],
            "headers": {"Accept": "application/json"},
        }
        self.assert_valid(self.fetch, fetch)

        for path in [
            "https://attacker.example/api/v1/repos",
            "/../admin",
            "/repos/../admin",
            "/repos/team/%2Fadmin",
            "/repos/team/",
        ]:
            with self.subTest(path=path):
                invalid = copy.deepcopy(fetch)
                invalid["path"] = path
                self.assert_invalid(self.fetch, invalid)

        for header in [
            "Authorization",
            "authorization",
            "Cookie",
            "Host",
            "Forwarded",
            "X-Forwarded-For",
            "X-Forwarded-Host",
            "X-Forwarded-Proto",
        ]:
            with self.subTest(header=header):
                invalid = copy.deepcopy(fetch)
                invalid["headers"][header] = "authority"
                self.assert_invalid(self.fetch, invalid)

        for header, value in [
            ("X-Bad\r\nHeader", "value"),
            ("Accept", "application/json\r\nAuthorization: stolen"),
        ]:
            with self.subTest(header=header, value=value):
                invalid = copy.deepcopy(fetch)
                invalid["headers"][header] = value
                self.assert_invalid(self.fetch, invalid)

    def test_error_response_cannot_also_claim_success(self) -> None:
        response = {
            "protocolVersion": 1,
            "requestID": "request-one",
            "providerID": "forgejo",
            "error": {"code": "forbidden", "message": "Not allowed."},
            "defaultBranch": "main",
        }
        self.assert_invalid(self.process, response)


if __name__ == "__main__":
    unittest.main()
