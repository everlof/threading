#!/usr/bin/env python3
"""Regression tests for the unrecognised-raw-value gate.

The checker is the only thing standing between this repository and a pattern that reads as
harmless at every individual call site, so its own blind spots matter more than usual: a
missed line break, a masked comment, or a scope glob that quietly stops covering a package
would all look exactly like a clean tree.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
CHECKER = REPOSITORY / "scripts/check_failopen_defaults.py"

sys.path.insert(0, str(REPOSITORY / "scripts"))
import check_failopen_defaults as checker  # noqa: E402


class FailOpenDefaultTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    # MARK: - Helpers

    def write(self, relative: str, source: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def run_checker(self, repository: Path = None):
        return subprocess.run(
            [sys.executable, str(CHECKER), str(repository or self.root)],
            check=False,
            capture_output=True,
            text=True,
        )

    # MARK: - The rule

    def test_rejects_a_raw_value_that_defaults_to_a_case(self) -> None:
        self.write(
            "Sources/Threading/Core/Agent/Policy.swift",
            "\n".join([
                "enum Access: String { case allowed, refused }",
                "",
                "func decide(_ raw: String) -> Access {",
                "    Access(rawValue: raw) ?? .allowed",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Sources/Threading/Core/Agent/Policy.swift:4", result.stdout)
        self.assertIn("Access(rawValue: raw) ?? .allowed", result.stdout)

    def test_a_line_break_before_the_fallback_does_not_defeat_the_check(self) -> None:
        """Every occurrence in the tree today is on one line, which is exactly why this is
        tested: the first reformat is not the moment to discover the check only saw one."""
        self.write(
            "Sources/Threading/Core/Agent/Policy.swift",
            "\n".join([
                "func decide(_ raw: String) -> Access {",
                "    Access(",
                "        rawValue: raw",
                "    )",
                "        ?? .allowed",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Sources/Threading/Core/Agent/Policy.swift:2", result.stdout)

    def test_rejects_the_self_and_qualified_spellings(self) -> None:
        self.write(
            "Sources/Threading/Core/Agent/Policy.swift",
            "\n".join([
                "extension Access {",
                "    init(wire raw: String) {",
                "        self = Self(rawValue: raw) ?? .allowed",
                "    }",
                "    static func named(_ raw: String) -> Access {",
                "        Access(rawValue: raw) ?? Access.allowed",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Policy.swift:3", result.stdout)
        self.assertIn("Policy.swift:6", result.stdout)

    def test_accepts_the_two_idioms_this_check_exists_to_push_people_towards(self) -> None:
        """An explicit unknown case that carries the raw value forward, and a fallback that
        derives an answer rather than naming a fixed one, are both the point rather than
        evasions of it."""
        self.write(
            "Sources/Threading/Core/Agent/Policy.swift",
            "\n".join([
                "func decide(_ raw: String) -> Access {",
                "    Access(rawValue: raw) ?? .unknown(raw)",
                "}",
                "func channel(_ raw: String) -> Channel {",
                "    Channel(rawValue: raw) ?? Channel.standard(for: AppInfo.buildChannel)",
                "}",
                "func refuse(_ raw: String) -> Bool {",
                "    guard let access = Access(rawValue: raw) else { return false }",
                "    return access.isAllowed",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("failopen-default: clean", result.stdout)

    def test_a_comment_or_a_string_neither_hides_a_site_nor_invents_one(self) -> None:
        """The notes explaining this seam have to be able to spell the pattern they refuse, and
        a doc comment above a real site must not swallow the site under it."""
        self.write(
            "Sources/Threading/Core/Agent/Policy.swift",
            "\n".join([
                "/// Replaces `Access(rawValue: raw) ?? .allowed`, which read as harmless.",
                "let explanation = \"Access(rawValue: raw) ?? .allowed\"",
                "/* Access(rawValue: raw) ?? .allowed */",
                "func decide(_ raw: String) -> Access {",
                "    Access(rawValue: raw) ?? .allowed",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout.count("Policy.swift:"), 1, result.stdout)
        self.assertIn("Policy.swift:5", result.stdout)

    # MARK: - Scope

    def test_covers_the_mobile_app_and_the_first_party_packages(self) -> None:
        self.write(
            "Sources/ThreadingMobile/Dashboard.swift",
            "let a = Access(rawValue: raw) ?? .allowed\n",
        )
        self.write(
            "Packages/ThreadingRemoteKit/Sources/ThreadingRemoteKit/Wire.swift",
            "let b = Access(rawValue: raw) ?? .allowed\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Sources/ThreadingMobile/Dashboard.swift:1", result.stdout)
        self.assertIn("ThreadingRemoteKit/Wire.swift:1", result.stdout)

    def test_leaves_the_vendored_forks_and_the_extension_examples_alone(self) -> None:
        self.write(
            "Packages/Vendor/SwiftTerm/Sources/SwiftTerm/CharData.swift",
            "let a = Code(rawValue: raw) ?? .none\n",
        )
        self.write(
            "Packages/ThreadingExtensionKit/Examples/HelloStatusExtension/main.swift",
            "let b = Role(rawValue: value) ?? .positive\n",
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # MARK: - The allowlist key

    def test_the_offered_key_names_the_enclosing_member_not_a_local_binding(self) -> None:
        """A key on a temporary is a key that stops matching the next time the body is edited,
        which is the failure mode a line-number key already has."""
        self.write(
            "Sources/Threading/Core/Remote/Listener.swift",
            "\n".join([
                "final class ListenerSet {",
                "    private func bind(candidates: [UInt16], index: Int) {",
                "        let parameters = NWParameters.tcp",
                "        parameters.endpoint = .hostPort(",
                "            host: .init(\"127.0.0.1\"),",
                "            port: NWEndpoint.Port(rawValue: port) ?? .any",
                "        )",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('"ListenerSet.bind"', result.stdout)

    # MARK: - The allowlist itself

    def test_the_shipped_allowlist_leaves_the_repository_clean(self) -> None:
        result = self.run_checker(repository=REPOSITORY)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("failopen-default: clean", result.stdout)

    def test_every_shipped_entry_carries_a_reason_a_reviewer_can_evaluate(self) -> None:
        for (path, symbol), reason in checker.ALLOWLIST.items():
            with self.subTest(path=path, symbol=symbol):
                self.assertGreaterEqual(
                    len(reason.strip()), checker.MINIMUM_REASON_LENGTH, f"{path} ({symbol})"
                )

    def test_a_suppression_without_a_reason_is_refused(self) -> None:
        entry = ("Sources/Threading/Core/Remote/RemoteListenerSet.swift", "RemoteListenerSet.bindLoopback")
        original = dict(checker.ALLOWLIST)
        checker.ALLOWLIST[entry] = "because"
        try:
            failures = checker.check(REPOSITORY)
        finally:
            checker.ALLOWLIST.clear()
            checker.ALLOWLIST.update(original)

        self.assertTrue(
            any("no reason a reviewer can evaluate" in failure for failure in failures),
            failures,
        )

    def test_an_entry_that_no_longer_matches_a_site_is_refused(self) -> None:
        entry = ("Sources/Threading/Core/Remote/RemoteListenerSet.swift", "RemoteListenerSet.gone")
        original = dict(checker.ALLOWLIST)
        checker.ALLOWLIST[entry] = (
            "A reason long enough to pass the minimum, describing a site that is not there."
        )
        try:
            failures = checker.check(REPOSITORY)
        finally:
            checker.ALLOWLIST.clear()
            checker.ALLOWLIST.update(original)

        self.assertTrue(
            any("no longer matches a site" in failure for failure in failures), failures
        )


if __name__ == "__main__":
    unittest.main()
