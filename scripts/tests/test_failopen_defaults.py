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


class DroppedVocabularyTests(unittest.TestCase):
    """The sibling rule: the same unmodelled value removing a row instead of downgrading it.

    This shape is one conjunction away from `guard let n = Int(text) else { return nil }`, which
    is everywhere and is fine, so most of these tests are about what the rule refuses to say.
    Each `test_leaves_…` case is a shape that was measured against the real tree while the rule
    was being calibrated and would have failed somebody's build had the rule been looser.
    """

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

    def vocabulary(self, body: str) -> str:
        """A closed wire vocabulary of ours, entered through a failable `String` initializer."""

        return "\n".join([
            "enum PlanStatus {",
            "    case pending",
            "    case completed",
            "",
            "    init?(providerValue: String) {",
            "        switch providerValue {",
            "        case \"pending\": self = .pending",
            "        case \"completed\": self = .completed",
            "        default: return nil",
            "        }",
            "    }",
            "}",
            "",
            body,
            "",
        ])

    # MARK: - The rule

    def test_rejects_a_row_dropped_out_of_a_compact_map(self) -> None:
        """The shape `ACPWireAdapter.planSteps` had before commit 2536faf9: a plan entry whose
        status the provider added later left the run indicator without ever saying so."""
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "enum Plan {",
                "    static func steps(in update: [String: Any]) -> [Step] {",
                "        let entries = update[\"entries\"] as? [[String: Any]] ?? []",
                "        return entries.compactMap { entry in",
                "            guard let title = entry[\"content\"] as? String,",
                "                  let rawStatus = entry[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: rawStatus)",
                "            else { return nil }",
                "            return Step(title: title, status: status)",
                "        }",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Sources/Threading/Core/Agent/Plan.swift:18", result.stdout)
        self.assertIn("unrecognised wire value drops this row", result.stdout)
        self.assertIn("PlanStatus(providerValue: rawStatus)", result.stdout)
        self.assertIn('"Plan.steps"', result.stdout)

    def test_rejects_a_row_skipped_by_continue_in_a_loop(self) -> None:
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "enum Plan {",
                "    static func steps(in items: [[String: Any]]) -> [Step] {",
                "        var steps: [Step] = []",
                "        for item in items {",
                "            guard let raw = item[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: raw) else {",
                "                continue",
                "            }",
                "            steps.append(Step(title: \"\", status: status))",
                "        }",
                "        return steps",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("unrecognised wire value drops this row", result.stdout)

    def test_reads_the_value_through_a_typed_json_accessor_too(self) -> None:
        """`fields["status"]?.stringValue` is the same provenance as `as? String`, and the
        adapters that have already been converted read the wire that way."""
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "enum Plan {",
                "    static func steps(in entries: [JSONValue]) -> [Step] {",
                "        entries.compactMap { entry in",
                "            guard let raw = entry.objectValue?[\"status\"]?.stringValue,",
                "                  let status = PlanStatus(providerValue: raw) else { return nil }",
                "            return Step(title: \"\", status: status)",
                "        }",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("unrecognised wire value drops this row", result.stdout)

    def test_a_comment_or_a_string_neither_hides_a_site_nor_invents_one(self) -> None:
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "/// Replaced `guard let s = PlanStatus(providerValue: raw) else { return nil }`.",
                "let note = \"guard let s = PlanStatus(providerValue: raw) else { return nil }\"",
                "enum Plan {",
                "    static func steps(in entries: [[String: Any]]) -> [Step] {",
                "        entries.compactMap { entry in",
                "            guard let raw = entry[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: raw) else { return nil }",
                "            return Step(title: \"\", status: status)",
                "        }",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout.count("drops this row"), 1, result.stdout)

    # MARK: - What it refuses to say

    def test_leaves_a_format_parser_alone(self) -> None:
        """`Int`, `URL` and `UUID` are not declared here, and their `nil` means "this is not one
        of those at all" rather than "this is a name I have no case for". Dropping a row whose
        URL will not parse is the only thing a caller can do."""
        self.write(
            "Sources/Threading/Core/Agent/Links.swift",
            "\n".join([
                "enum Links {",
                "    static func read(_ rows: [[String: Any]]) -> [URL] {",
                "        rows.compactMap { row in",
                "            guard let raw = row[\"href\"] as? String,",
                "                  let url = URL(string: raw) else { return nil }",
                "            return url",
                "        }",
                "    }",
                "    static func counts(_ rows: [[String: Any]]) -> [Int] {",
                "        rows.compactMap { row in",
                "            guard let raw = row[\"count\"] as? String,",
                "                  let count = Int(raw) else { return nil }",
                "            return count",
                "        }",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_raw_representable_conformance_alone(self) -> None:
        """`RawRepresentable` requires `init?(rawValue:)` to be failable, so banning it would
        ban the conformance. A `String`-raw enum is also our own persisted vocabulary as often
        as it is a provider's, and the call site cannot tell those apart."""
        self.write(
            "Sources/Threading/Core/Agent/Stored.swift",
            "\n".join([
                "enum Grouping: String {",
                "    case project",
                "    case account",
                "}",
                "enum Stored {",
                "    static func read(_ rows: [[String: Any]]) -> [Grouping] {",
                "        rows.compactMap { row in",
                "            guard let raw = row[\"grouping\"] as? String,",
                "                  let grouping = Grouping(rawValue: raw) else { return nil }",
                "            return grouping",
                "        }",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_struct_alone(self) -> None:
        """A struct's failable initializer parses a format — a fingerprint, a pairing payload,
        a colour. Only an enum is a closed list of names somebody else chose."""
        self.write(
            "Sources/Threading/Core/Agent/Fingerprint.swift",
            "\n".join([
                "struct Fingerprint {",
                "    init?(hex: String) { return nil }",
                "}",
                "enum Peers {",
                "    static func read(_ rows: [[String: Any]]) -> [Fingerprint] {",
                "        rows.compactMap { row in",
                "            guard let raw = row[\"fingerprint\"] as? String,",
                "                  let value = Fingerprint(hex: raw) else { return nil }",
                "            return value",
                "        }",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_value_that_did_not_come_off_the_wire_alone(self) -> None:
        """The argument here is read from our own `[String: String]` overrides, with no cast in
        sight. Nothing external chose that string, so nothing unmodelled can arrive in it."""
        self.write(
            "Sources/Threading/Core/Agent/Overrides.swift",
            self.vocabulary("\n".join([
                "enum Overrides {",
                "    static func read(_ overrides: [String: String], keys: [String]) -> [Int] {",
                "        var found: [Int] = []",
                "        for key in keys {",
                "            guard let name = overrides[key],",
                "                  let status = PlanStatus(providerValue: name) else { continue }",
                "            found.append(status.hashValue)",
                "        }",
                "        return found",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_whole_collection_withdrawal_alone(self) -> None:
        """Refusing the entire snapshot is lossy but legible: the reader sees no plan rather
        than a plan with a step quietly missing. Two sites in this repository do exactly that
        on purpose, and this rule is not the place to argue with them."""
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "enum Plan {",
                "    static func steps(in items: [[String: Any]]) -> [Step]? {",
                "        var steps: [Step] = []",
                "        for item in items {",
                "            guard let raw = item[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: raw) else {",
                "                return nil",
                "            }",
                "            steps.append(Step(title: \"\", status: status))",
                "        }",
                "        return steps",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_failure_branch_that_says_something_alone(self) -> None:
        """A branch that records the unrecognised value has already made the omission
        findable, which is the whole thing being asked for."""
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            self.vocabulary("\n".join([
                "enum Plan {",
                "    static func steps(in entries: [[String: Any]]) -> [Step] {",
                "        entries.compactMap { entry in",
                "            guard let raw = entry[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: raw) else {",
                "                ThreadingLogger.wire.warning(\"unknown plan status\")",
                "                return nil",
                "            }",
                "            return Step(title: \"\", status: status)",
                "        }",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_the_idiom_it_is_pushing_people_towards_alone(self) -> None:
        """The fix: a non-failable initializer with an explicit unknown case, and the omission
        decided at the projection where a reader can find it."""
        self.write(
            "Sources/Threading/Core/Agent/Plan.swift",
            "\n".join([
                "enum PlanStatus {",
                "    case pending",
                "    case unknown(String)",
                "",
                "    init(providerValue: String) {",
                "        switch providerValue {",
                "        case \"pending\": self = .pending",
                "        default: self = .unknown(providerValue)",
                "        }",
                "    }",
                "}",
                "enum Plan {",
                "    static func steps(in entries: [[String: Any]]) -> [Step] {",
                "        entries.compactMap { entry in",
                "            guard let raw = entry[\"status\"] as? String else { return nil }",
                "            switch PlanStatus(providerValue: raw) {",
                "            case .pending: return Step(title: \"\", status: .pending)",
                "            case .unknown: return nil",
                "            }",
                "        }",
                "    }",
                "}",
                "",
            ]),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_leaves_a_drop_outside_a_collection_alone(self) -> None:
        """Refusing one operation is not the same as removing one row from a list somebody is
        reading: a router's unknown path becomes a 404 that the caller answers."""
        self.write(
            "Sources/Threading/Core/Agent/Router.swift",
            self.vocabulary("\n".join([
                "enum Router {",
                "    static func handle(_ request: [String: Any]) -> Int {",
                "        guard let raw = request[\"status\"] as? String,",
                "              let status = PlanStatus(providerValue: raw) else { return 404 }",
                "        return status.hashValue",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    # MARK: - Scope and the shipped tree

    def test_leaves_the_vendored_forks_and_the_extension_examples_alone(self) -> None:
        self.write(
            "Packages/Vendor/SwiftTerm/Sources/SwiftTerm/Wire.swift",
            self.vocabulary("\n".join([
                "enum Wire {",
                "    static func steps(in entries: [[String: Any]]) -> [Step] {",
                "        entries.compactMap { entry in",
                "            guard let raw = entry[\"status\"] as? String,",
                "                  let status = PlanStatus(providerValue: raw) else { return nil }",
                "            return Step(title: \"\", status: status)",
                "        }",
                "    }",
                "}",
            ])),
        )

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_shipped_tree_is_clean_under_both_rules(self) -> None:
        result = self.run_checker(repository=REPOSITORY)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("dropped-vocabulary: clean", result.stdout)

    def test_the_omission_allowlist_carries_a_reason_a_reviewer_can_evaluate(self) -> None:
        for (path, symbol), reason in checker.DROPPED_ELEMENT_ALLOWLIST.items():
            with self.subTest(path=path, symbol=symbol):
                self.assertGreaterEqual(
                    len(reason.strip()), checker.MINIMUM_REASON_LENGTH, f"{path} ({symbol})"
                )

    def test_a_suppression_without_a_reason_is_refused(self) -> None:
        entry = ("Sources/Threading/Core/Agent/WorkingWords.swift", "RunProgress.steps")
        original = dict(checker.DROPPED_ELEMENT_ALLOWLIST)
        checker.DROPPED_ELEMENT_ALLOWLIST[entry] = "because"
        try:
            failures = checker.check(REPOSITORY)
        finally:
            checker.DROPPED_ELEMENT_ALLOWLIST.clear()
            checker.DROPPED_ELEMENT_ALLOWLIST.update(original)

        self.assertTrue(
            any("dropped-vocabulary" in failure and "no reason" in failure
                for failure in failures),
            failures,
        )

    def test_an_entry_that_no_longer_matches_a_site_is_refused(self) -> None:
        entry = ("Sources/Threading/Core/Agent/WorkingWords.swift", "RunProgress.gone")
        original = dict(checker.DROPPED_ELEMENT_ALLOWLIST)
        checker.DROPPED_ELEMENT_ALLOWLIST[entry] = (
            "A reason long enough to pass the minimum, describing a site that is not there."
        )
        try:
            failures = checker.check(REPOSITORY)
        finally:
            checker.DROPPED_ELEMENT_ALLOWLIST.clear()
            checker.DROPPED_ELEMENT_ALLOWLIST.update(original)

        self.assertTrue(
            any("dropped-vocabulary" in failure and "no longer matches a site" in failure
                for failure in failures),
            failures,
        )


if __name__ == "__main__":
    unittest.main()
