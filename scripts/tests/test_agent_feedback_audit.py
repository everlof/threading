#!/usr/bin/env python3
"""Focused tests for the private local Claude/Codex feedback audit."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "audit_agent_feedback.py"
SPEC = importlib.util.spec_from_file_location("audit_agent_feedback", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
audit_agent_feedback = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = audit_agent_feedback
SPEC.loader.exec_module(audit_agent_feedback)


class AgentFeedbackAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.project = self.root / "repo/AnotherTerminal"
        self.home.mkdir()
        self.project.mkdir(parents=True)

    def test_project_slug_matches_claudes_utf16_code_unit_encoding(self) -> None:
        self.assertEqual(
            audit_agent_feedback.claude_project_slug("slug probe_v1.2 åäö-🎉"),
            "slug-probe-v1-2-------",
        )

    def test_aliases_are_read_without_execution_and_preserve_their_real_case(self) -> None:
        self.write(
            self.home / ".bash_profile",
            "\n".join(
                [
                    "alias claudedb='CLAUDE_CONFIG_DIR=\"$HOME/.claude-dblock\" claude'",
                    "alias claudevl='CLAUDE_CONFIG_DIR=\"$HOME/.claude-vlundborg\" claude'",
                    "alias codexfestina=CODEX_HOME=\"$HOME/.codex-festina\" codex",
                    "alias not_an_account='claude --model opus'",
                ]
            ),
        )
        for path in (
            self.home / ".claude-dblock/projects",
            self.home / ".claude-vlundborg/projects",
            self.home / ".codex-festina/sessions",
        ):
            path.mkdir(parents=True)

        profiles = audit_agent_feedback.discover_profiles(self.home)
        aliases = {
            (profile.provider, profile.root.name): profile.aliases
            for profile in profiles
        }

        self.assertEqual(aliases[("Claude", ".claude-dblock")], ("claudedb",))
        self.assertEqual(aliases[("Claude", ".claude-vlundborg")], ("claudevl",))
        self.assertEqual(aliases[("Codex", ".codex-festina")], ("codexfestina",))
        self.assertNotIn("Claudevl", aliases[("Claude", ".claude-vlundborg")])

    def test_audit_filters_generated_records_subagents_and_duplicate_copies(self) -> None:
        self.configure_aliases()
        default_claude = self.home / ".claude"
        copied_claude = self.home / ".claude-dblock"
        default_codex = self.home / ".codex"
        for path in (
            default_claude / "projects",
            copied_claude / "projects",
            default_codex / "sessions/2026/08/17",
        ):
            path.mkdir(parents=True)

        session_id = "11111111-1111-1111-1111-111111111111"
        self.write_claude(
            default_claude,
            session_id,
            [
                self.claude_user("Build the requested surface", "2026-08-17T08:00:00Z"),
                self.claude_assistant("Done after a compile-only check", "2026-08-17T08:01:00Z"),
                self.claude_tool_result("NO_TOOL_OUTPUT_MUST_NOT_APPEAR"),
                self.claude_user(
                    "<local-command-stdout>NO_GENERATED_COMMAND</local-command-stdout>",
                    "2026-08-17T08:01:30Z",
                ),
                self.claude_user(
                    "No, that is not what I asked; inspect the rendered UI and fix the root cause.",
                    "2026-08-17T08:02:00Z",
                ),
                self.claude_user(
                    "NO_SIDECHAIN_MUST_NOT_APPEAR",
                    "2026-08-17T08:03:00Z",
                    sidechain=True,
                ),
                {"type": "ai-title", "sessionId": session_id, "aiTitle": "Surface audit"},
            ],
        )
        self.write_claude(
            copied_claude,
            session_id,
            [self.claude_user("Older copied opening", "2026-08-16T08:00:00Z")],
        )

        codex_id = "22222222-2222-2222-2222-222222222222"
        self.write_codex(
            default_codex,
            "user.jsonl",
            codex_id,
            thread_source="user",
            records=[
                {
                    "timestamp": "2026-08-17T09:00:01Z",
                    "type": "response_item",
                    "payload": {
                        "type": "custom_tool_call_output",
                        "output": "NO_CODEX_TOOL_OUTPUT_MUST_NOT_APPEAR",
                    },
                },
                self.codex_event("user_message", "Add the extension seam", "2026-08-17T09:00:02Z"),
                self.codex_event("agent_message", "I added a hard-coded row.", "2026-08-17T09:00:03Z"),
                self.codex_event(
                    "user_message",
                    "Why did you hard-code it? This should be fully customizable.",
                    "2026-08-17T09:00:04Z",
                ),
            ],
        )
        self.write_codex(
            default_codex,
            "guardian.jsonl",
            "33333333-3333-3333-3333-333333333333",
            thread_source="subagent",
            source={"subagent": {"other": "guardian"}},
            records=[
                self.codex_event(
                    "user_message",
                    "NO_GUARDIAN_TRANSCRIPT_MUST_NOT_APPEAR",
                    "2026-08-17T09:00:05Z",
                )
            ],
        )

        result = audit_agent_feedback.audit_project(self.project, self.home)

        self.assertEqual(len(result.conversations), 2)
        self.assertEqual(result.user_turn_count, 4)
        self.assertEqual(result.stats.claude_transcripts, 2)
        self.assertEqual(result.stats.codex_project_rollouts, 2)
        self.assertEqual(result.stats.codex_subagent_rollouts, 1)
        claude = next(item for item in result.conversations if item.provider == "Claude")
        self.assertEqual(claude.profile.root, default_claude.resolve())
        self.assertEqual(claude.title, "Surface audit")
        self.assertEqual(len(claude.user_turns), 2)
        self.assertIn("compile-only", claude.user_turns[1].previous_agent_text)

        report = audit_agent_feedback.render_report(result)
        self.assertIn("High-confidence correction candidates: 2", report)
        self.assertIn("Explicit guidance/process candidates: 1", report)
        self.assertIn("No, that is not what I asked", report)
        self.assertIn("Why did you hard-code it", report)
        for forbidden in (
            "NO_TOOL_OUTPUT_MUST_NOT_APPEAR",
            "NO_GENERATED_COMMAND",
            "NO_SIDECHAIN_MUST_NOT_APPEAR",
            "NO_CODEX_TOOL_OUTPUT_MUST_NOT_APPEAR",
            "NO_GUARDIAN_TRANSCRIPT_MUST_NOT_APPEAR",
            "Older copied opening",
        ):
            self.assertNotIn(forbidden, report)

    def test_since_filters_old_human_turns_without_dropping_the_conversation(self) -> None:
        root = self.home / ".claude"
        (root / "projects").mkdir(parents=True)
        self.write_claude(
            root,
            "44444444-4444-4444-4444-444444444444",
            [
                self.claude_user("Old request", "2026-08-01T08:00:00Z"),
                self.claude_assistant("Old reply", "2026-08-01T08:01:00Z"),
                self.claude_user("Second old request", "2026-08-02T08:00:00Z"),
                self.claude_assistant("Reply immediately before new", "2026-08-17T07:59:00Z"),
                self.claude_user("New request", "2026-08-17T08:00:00Z"),
            ],
        )

        result = audit_agent_feedback.audit_project(
            self.project, self.home, since="2026-08-17"
        )

        self.assertEqual(result.user_turn_count, 1)
        self.assertEqual(result.conversations[0].user_turns[0].text, "New request")
        self.assertEqual(
            result.conversations[0].user_turns[0].previous_agent_text,
            "Reply immediately before new",
        )

    def configure_aliases(self) -> None:
        self.write(
            self.home / ".bash_profile",
            "alias claudedb='CLAUDE_CONFIG_DIR=\"$HOME/.claude-dblock\" claude'\n",
        )

    def write_claude(self, root: Path, session_id: str, records: list[dict]) -> None:
        slug = audit_agent_feedback.claude_project_slug(str(self.project.resolve()))
        path = root / "projects" / slug / f"{session_id}.jsonl"
        self.write_jsonl(path, records)

    def write_codex(
        self,
        root: Path,
        filename: str,
        session_id: str,
        thread_source: str,
        records: list[dict],
        source: object = "vscode",
    ) -> None:
        metadata = {
            "timestamp": "2026-08-17T09:00:00Z",
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "cwd": str(self.project.resolve()),
                "thread_source": thread_source,
                "source": source,
            },
        }
        self.write_jsonl(root / "sessions/2026/08/17" / filename, [metadata] + records)

    def claude_user(
        self, text: str, timestamp: str, sidechain: bool = False
    ) -> dict:
        return {
            "type": "user",
            "sessionId": "11111111-1111-1111-1111-111111111111",
            "cwd": str(self.project.resolve()),
            "timestamp": timestamp,
            "isSidechain": sidechain,
            "message": {"role": "user", "content": text},
        }

    def claude_assistant(self, text: str, timestamp: str) -> dict:
        return {
            "type": "assistant",
            "sessionId": "11111111-1111-1111-1111-111111111111",
            "cwd": str(self.project.resolve()),
            "timestamp": timestamp,
            "isSidechain": False,
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
        }

    def claude_tool_result(self, text: str) -> dict:
        return {
            "type": "user",
            "sessionId": "11111111-1111-1111-1111-111111111111",
            "cwd": str(self.project.resolve()),
            "timestamp": "2026-08-17T08:01:10Z",
            "isSidechain": False,
            "message": {
                "role": "user",
                "content": [{"type": "tool_result", "content": text}],
            },
        }

    @staticmethod
    def codex_event(kind: str, message: str, timestamp: str) -> dict:
        return {
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {"type": kind, "message": message},
        }

    @staticmethod
    def write(path: Path, contents: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    @staticmethod
    def write_jsonl(path: Path, records: list[dict]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
            encoding="utf-8",
        )


if __name__ == "__main__":
    unittest.main()
