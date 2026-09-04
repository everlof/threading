#!/usr/bin/env python3
"""Record privacy-safe marketing PTY fixtures through the installed provider TUIs.

Claude renders a synthetic saved session and Codex renders a response from a loopback-only
Responses API server. Neither route contacts a model. The recorder answers the small terminal
capability queries a bare PTY cannot answer on its own, then stores the exact provider output.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import re
import select
import shutil
import signal
import struct
import subprocess
import termios
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[1]
FIXTURE_DIRECTORY = REPOSITORY / "Sources/ThreadingMobile/TerminalFixtures"
WORKSPACE = Path("/private/tmp/threading-marketing-tui")
CLAUDE_SESSION_ID = "7ee72d66-0e50-4e5d-912b-96104c5919bd"
FIXED_TIMESTAMP = "2026-08-30T12:00:00.000Z"
GRID_COLUMNS = 62

# The terminal each recording believes it is drawing into. Both TUIs pick their palette from the
# background the terminal reports (OSC 11 and `COLORFGBG`), and Claude also takes its theme as a
# setting, so one recording per mode is what a light app theme honestly gets: Codex's own light
# diff backgrounds rather than its dark truecolour ones on paper. The light answer is Editorial's
# ground and label; only light-versus-dark matters to the providers.
TERMINAL_MODES = {
    "dark": {
        "foreground": "d9d9/d1d1/c8c8",
        "background": "0404/0a0a/1212",
        "colorfgbg": "15;0",
        "claude_theme": "dark-ansi",
        "suffix": "",
    },
    "light": {
        "foreground": "2a2a/2525/2020",
        "background": "f2f2/eeee/e7e7",
        "colorfgbg": "0;15",
        "claude_theme": "light-ansi",
        "suffix": "-light",
    },
}

PROVIDERS = {
    "claude": {
        "binary": "claude",
        "rows": 49,
        "settled_marker": b"recapture",
        "version_prefix": "Claude Code ",
    },
    "codex": {
        "binary": "codex",
        "rows": 55,
        "settled_marker": b"Evidence assertions passed",
        "version_prefix": "codex-cli ",
    },
}


CLAUDE_PROMPT = (
    "Verify the App Store capture checkpoints."
)
CLAUDE_INTRO = "I’ll verify the capture plan and tighten the replay checkpoints."
CLAUDE_EDIT_PATH = WORKSPACE / "capture-plan.md"
CLAUDE_OLD_CONTENT = """# App Store capture

Opening scene: Active terminal
Terminal gesture: Scroll past the bottom
Final scene: Settings
Timeline: Best effort
"""
CLAUDE_NEW_CONTENT = """# App Store capture

Opening scene: New Session draft
Terminal gesture: Reveal earlier tool output
Final scene: Daily Usage chart
Timeline: Fixed 900-frame clock
"""
CLAUDE_RESPONSE = """Capture flow verified.

Completed:
- Recorded the installed Claude and Codex TUIs
- Seeded four chats across two providers and accounts
- Replayed the exact 900-frame interaction clock
- Verified the task strip, terminal palette, and Usage chart

Every recapture replays local PTY bytes.
The timing stays deterministic and spends no provider usage."""

CODEX_PROMPT = "Verify the App Store capture flow."
CODEX_RESPONSE = """The capture contract is now implemented and repeatable.

- Draft opens first and uses the real model picker.
- Codex reveals earlier tool and diff output naturally.
- Claude keeps its task plan in shipping chrome.
- Usage ends on the real daily provider chart.

Validation

✓ 6 product screenshots at native scale
✓ 900 video frames at 30 fps
✓ Evidence assertions passed
✓ 0 provider calls during recapture

The reviewed PTY recording is deterministic across every theme."""

CODEX_PATCH = """*** Begin Patch
*** Update File: capture-notes.md
@@
-Status: Draft
-Opening scene: Active terminal
-Terminal gesture: Scroll past the bottom
-Final scene: Settings
+Status: Ready for review
+Opening scene: New Session draft and model picker
+Terminal gesture: Reveal earlier tool output
+Final scene: Daily Usage chart
@@
-Theme timing: Best effort
+Theme timing: Fixed 900-frame clock at 30 fps
+Provider usage during recapture: 0 turns
*** Add File: evidence/checkpoints.md
+# App Store checkpoints
+
+- [x] Four mixed-provider sessions
+- [x] Claude task progress
+- [x] Codex tool activity and file diff
+- [x] Keyboard and complete session menu
+- [x] Daily Usage chart
+
+All scenes use privacy-reviewed synthetic data.
*** End Patch"""


def _json_line(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _write_claude_session() -> Path:
    config = Path(
        os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))
    ).expanduser()
    project = config / "projects" / "-private-tmp-threading-marketing-tui"
    project.mkdir(parents=True, exist_ok=True)
    user_id = "62987373-0c8f-4aa1-a50a-294f4b62e752"
    intro_id = "8c73f143-c624-410a-9ea3-984bc2b93bc0"
    edit_id = "10cb918b-27bb-4cea-8a04-a5083ad136e4"
    result_id = "11fb1d72-78de-4d05-820a-a09c6b97f113"
    final_id = "13f26014-d319-4e08-8627-2c76db78340e"
    edit_tool_id = "toolu_01_threading_marketing_edit"
    usage = {
        "input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "output_tokens": 0,
    }
    common = {
        "isSidechain": False,
        "cwd": str(WORKSPACE),
        "sessionId": CLAUDE_SESSION_ID,
        "version": provider_version("claude"),
        "gitBranch": "HEAD",
    }
    records = [
        {"type": "mode", "mode": "normal", "sessionId": CLAUDE_SESSION_ID},
        {
            "type": "permission-mode",
            "permissionMode": "acceptEdits",
            "sessionId": CLAUDE_SESSION_ID,
        },
        {
            **common,
            "parentUuid": None,
            "type": "user",
            "message": {"role": "user", "content": CLAUDE_PROMPT},
            "uuid": user_id,
            "timestamp": FIXED_TIMESTAMP,
            "userType": "external",
            "entrypoint": "cli",
        },
        {
            **common,
            "parentUuid": user_id,
            "type": "assistant",
            "message": {
                "id": "msg_01_threading_marketing_fixture",
                "type": "message",
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [{"type": "text", "text": CLAUDE_INTRO}],
                "stop_reason": "tool_use",
                "stop_sequence": None,
                "usage": usage,
            },
            "uuid": intro_id,
            "timestamp": FIXED_TIMESTAMP,
        },
        {
            **common,
            "parentUuid": intro_id,
            "type": "assistant",
            "message": {
                "id": "msg_01_threading_marketing_fixture",
                "type": "message",
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [
                    {
                        "type": "tool_use",
                        "id": edit_tool_id,
                        "name": "Edit",
                        "input": {
                            "replace_all": False,
                            "file_path": str(CLAUDE_EDIT_PATH),
                            "old_string": CLAUDE_OLD_CONTENT,
                            "new_string": CLAUDE_NEW_CONTENT,
                        },
                        "caller": {"type": "direct"},
                    }
                ],
                "stop_reason": "tool_use",
                "stop_sequence": None,
                "usage": usage,
            },
            "uuid": edit_id,
            "timestamp": FIXED_TIMESTAMP,
        },
        {
            **common,
            "parentUuid": edit_id,
            "type": "user",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": edit_tool_id,
                        "content": f"The file {CLAUDE_EDIT_PATH} has been updated successfully.",
                    }
                ],
            },
            "toolUseResult": {
                "filePath": str(CLAUDE_EDIT_PATH),
                "oldString": CLAUDE_OLD_CONTENT,
                "newString": CLAUDE_NEW_CONTENT,
                "originalFile": CLAUDE_OLD_CONTENT,
                "structuredPatch": [
                    {
                        "oldStart": 1,
                        "oldLines": 6,
                        "newStart": 1,
                        "newLines": 6,
                        "lines": [
                            " # App Store capture",
                            " ",
                            "-Opening scene: Active terminal",
                            "+Opening scene: New Session draft",
                            "-Terminal gesture: Scroll past the bottom",
                            "+Terminal gesture: Reveal earlier tool output",
                            "-Final scene: Settings",
                            "+Final scene: Daily Usage chart",
                            "-Timeline: Best effort",
                            "+Timeline: Fixed 900-frame clock",
                        ],
                    }
                ],
                "userModified": False,
                "replaceAll": False,
            },
            "uuid": result_id,
            "timestamp": FIXED_TIMESTAMP,
            "userType": "external",
            "entrypoint": "cli",
        },
        {
            **common,
            "parentUuid": result_id,
            "type": "assistant",
            "message": {
                "id": "msg_02_threading_marketing_fixture",
                "type": "message",
                "role": "assistant",
                "model": "claude-fable-5",
                "content": [{"type": "text", "text": CLAUDE_RESPONSE}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": usage,
            },
            "uuid": final_id,
            "timestamp": FIXED_TIMESTAMP,
        },
    ]
    session = project / f"{CLAUDE_SESSION_ID}.jsonl"
    if session.exists():
        raise RuntimeError(f"refusing to replace existing Claude session: {session}")
    session.write_text("\n".join(_json_line(record) for record in records) + "\n")
    return session


def _sse(events: list[dict[str, Any]]) -> bytes:
    chunks = []
    for event in events:
        kind = event["type"]
        chunks.append(f"event: {kind}\ndata: {_json_line(event)}\n\n")
    return "".join(chunks).encode()


class _CodexFixtureHandler(BaseHTTPRequestHandler):
    server: "_CodexFixtureServer"

    def log_message(self, _format: str, *_args: object) -> None:
        return None

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path.endswith("/models"):
            self._send_json(
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "gpt-5.6-sol",
                            "object": "model",
                            "created": 0,
                            "owned_by": "threading-fixture",
                        }
                    ],
                }
            )
            return
        self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        if not self.path.endswith("/responses"):
            self.send_error(404)
            return
        self.server.requests.put(request)
        body = _sse(self.server.events_for(request))
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, value: dict[str, Any]) -> None:
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class _CodexFixtureServer(ThreadingHTTPServer):
    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _CodexFixtureHandler)
        self.requests: queue.Queue[dict[str, Any]] = queue.Queue()
        self.response_count = 0

    @property
    def base_url(self) -> str:
        host, port = self.server_address
        return f"http://{host}:{port}/v1"

    def events_for(self, request: dict[str, Any]) -> list[dict[str, Any]]:
        self.response_count += 1
        response_id = f"resp_threading_marketing_fixture_{self.response_count}"
        events: list[dict[str, Any]] = [
            {"type": "response.created", "response": {"id": response_id}}
        ]
        if self.response_count == 1:
            events.extend(
                [
                    {
                        "type": "response.output_item.done",
                        "item": {
                            "type": "reasoning",
                            "id": "reasoning_threading_fixture",
                            "summary": [
                                {
                                    "type": "summary_text",
                                    "text": "Reviewing the capture timeline and fixture contract",
                                }
                            ],
                            "encrypted_content": "dGhyZWFkaW5nLWZpeHR1cmU=",
                        },
                    },
                    {
                        "type": "response.output_item.done",
                        "item": {
                            "type": "custom_tool_call",
                            "name": "apply_patch",
                            "input": CODEX_PATCH,
                            "call_id": "call_threading_fixture_patch",
                        },
                    },
                ]
            )
        else:
            events.append(
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "message",
                        "role": "assistant",
                        "id": "msg_threading_marketing_fixture",
                        "content": [{"type": "output_text", "text": CODEX_RESPONSE}],
                    },
                }
            )
        events.append(
            {
                "type": "response.completed",
                "response": {
                    "id": response_id,
                    "usage": {
                        "input_tokens": 0,
                        "input_tokens_details": {"cached_tokens": 0},
                        "output_tokens": 0,
                        "output_tokens_details": {"reasoning_tokens": 0},
                        "total_tokens": 0,
                    },
                },
            }
        )
        return events


def provider_version(provider: str) -> str:
    binary = require_binary(PROVIDERS[provider]["binary"])
    result = subprocess.run(
        [binary, "--version"],
        check=True,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    prefix = PROVIDERS[provider]["version_prefix"]
    if provider == "claude":
        return value.split(" ", 1)[0]
    if not value.startswith(prefix):
        raise RuntimeError(f"unexpected {provider} version output: {value}")
    return value.removeprefix(prefix)


def require_binary(name: str) -> str:
    value = shutil.which(name)
    if value is None:
        raise RuntimeError(f"{name} is not installed")
    return value


def _terminal_response(chunk: bytes, terminal_mode: str) -> bytes:
    mode = TERMINAL_MODES[terminal_mode]
    response = bytearray()
    if b"\x1b]10;?" in chunk:
        response.extend(f"\x1b]10;rgb:{mode['foreground']}\x1b\\".encode())
    if b"\x1b]11;?" in chunk:
        response.extend(f"\x1b]11;rgb:{mode['background']}\x1b\\".encode())
    if b"\x1b[6n" in chunk:
        response.extend(b"\x1b[1;1R")
    if b"\x1b[c" in chunk:
        response.extend(b"\x1b[?1;2c")
    return bytes(response)


def _echo_enabled(descriptor: int) -> bool:
    try:
        return bool(termios.tcgetattr(descriptor)[3] & termios.ECHO)
    except termios.error:
        return False


def capture_pty(
    command: list[str],
    *,
    columns: int,
    rows: int,
    environment: dict[str, str],
    settled_marker: bytes,
    terminal_mode: str,
    timeout: float = 20,
) -> bytes:
    pid, descriptor = pty.fork()
    if pid == 0:
        size = struct.pack("HHHH", rows, columns, 0, 0)
        fcntl.ioctl(0, termios.TIOCSWINSZ, size)
        os.chdir(WORKSPACE)
        os.execvpe(command[0], command, environment)
        raise AssertionError("exec returned")

    captured = bytearray()
    started = time.monotonic()
    last_output = started
    marker_seen_at: float | None = None
    timed_out = False
    # A capability reply written while the slave still echoes is typed back into the stream as
    # caret text ("^[[?1;2c") ahead of the TUI's first frame. Hold replies until raw mode has
    # cleared ECHO; a TUI that never does gets them after a bounded wait so it cannot stall on a
    # query nothing answers.
    pending_replies = bytearray()
    pending_since: float | None = None
    theme_dialog_seen_at: float | None = None
    theme_acknowledgements = 0
    trust_dialog_seen_at: float | None = None
    trust_acknowledgements = 0
    try:
        while time.monotonic() - started < timeout:
            ready, _, _ = select.select([descriptor], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(descriptor, 65_536)
                except OSError:
                    break
                if not chunk:
                    break
                captured.extend(chunk)
                last_output = time.monotonic()
                reply = _terminal_response(chunk, terminal_mode)
                if reply:
                    if not pending_replies:
                        pending_since = time.monotonic()
                    pending_replies.extend(reply)
                if (
                    theme_dialog_seen_at is None
                    and b"Syntax" in captured
                    and b"theme:" in captured
                    and b"ansi" in captured
                ):
                    theme_dialog_seen_at = time.monotonic()
                if (
                    trust_dialog_seen_at is None
                    and b"Quick" in captured
                    and b"safety" in captured
                    and b"check:" in captured
                ):
                    trust_dialog_seen_at = time.monotonic()
                if settled_marker in captured and marker_seen_at is None:
                    marker_seen_at = time.monotonic()
            now = time.monotonic()
            if pending_replies and (
                not _echo_enabled(descriptor)
                or (pending_since is not None and now - pending_since >= 1.0)
            ):
                os.write(descriptor, bytes(pending_replies))
                pending_replies.clear()
                pending_since = None
            if (
                theme_dialog_seen_at is not None
                and theme_acknowledgements < 3
                and now - max(theme_dialog_seen_at, last_output) >= 0.3
            ):
                os.write(descriptor, b"\r")
                theme_acknowledgements += 1
                theme_dialog_seen_at = now
            if (
                trust_dialog_seen_at is not None
                and trust_acknowledgements < 3
                and now - max(trust_dialog_seen_at, last_output) >= 0.3
            ):
                os.write(descriptor, b"\x1b[B\r")
                trust_acknowledgements += 1
                trust_dialog_seen_at = now
            if marker_seen_at is not None and time.monotonic() - last_output >= 1.2:
                break
        else:
            timed_out = True
    finally:
        reaped = False
        if marker_seen_at is not None:
            graceful_deadline = time.monotonic() + 2
            next_interrupt = time.monotonic()
            while time.monotonic() < graceful_deadline:
                if time.monotonic() >= next_interrupt:
                    try:
                        os.write(descriptor, b"\x03")
                    except OSError:
                        pass
                    next_interrupt = time.monotonic() + 0.25
                try:
                    completed_pid, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    reaped = True
                    break
                if completed_pid == pid:
                    reaped = True
                    break
                time.sleep(0.05)
        if not reaped:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            reap_deadline = time.monotonic() + 0.5
            while time.monotonic() < reap_deadline:
                try:
                    completed_pid, _ = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    break
                if completed_pid == pid:
                    break
                time.sleep(0.05)
        os.close(descriptor)

    if settled_marker not in captured:
        tail = captured[-600:].decode(errors="replace")
        reason = f" within {timeout:.0f}s" if timed_out else ""
        raise RuntimeError(
            f"PTY never rendered {settled_marker!r}{reason}; tail:\n{tail}"
        )
    return bytes(captured)


def _recording_environment() -> dict[str, str]:
    """The host's environment without the coding agent that may be running this script.

    A recording made from inside a Claude Code session inherits `CLAUDECODE` and
    `CLAUDE_CODE_*`, and the child Claude then draws a "Transcript saving is off — inherited
    CLAUDE_CODE_…" warning into its footer, which is not part of the product being photographed.
    """
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("CLAUDECODE", "CLAUDE_CODE_", "CODEX_"))
    }


def record_claude(terminal_mode: str) -> bytes:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    CLAUDE_EDIT_PATH.write_text(CLAUDE_OLD_CONTENT)
    session = _write_claude_session()
    environment = _recording_environment()
    environment.update(
        {
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        }
    )
    environment.pop("NO_COLOR", None)
    environment["COLORFGBG"] = TERMINAL_MODES[terminal_mode]["colorfgbg"]
    try:
        return capture_pty(
            [
                require_binary("claude"),
                "--resume",
                CLAUDE_SESSION_ID,
                "--safe-mode",
                "--settings",
                json.dumps({"theme": TERMINAL_MODES[terminal_mode]["claude_theme"]}),
                "--permission-mode",
                "acceptEdits",
            ],
            columns=GRID_COLUMNS,
            rows=PROVIDERS["claude"]["rows"],
            environment=environment,
            settled_marker=PROVIDERS["claude"]["settled_marker"],
            terminal_mode=terminal_mode,
        )
    finally:
        session.unlink(missing_ok=True)
        CLAUDE_EDIT_PATH.unlink(missing_ok=True)


def record_codex(terminal_mode: str) -> bytes:
    (WORKSPACE / "evidence").mkdir(parents=True, exist_ok=True)
    (WORKSPACE / "capture-notes.md").write_text(
        "# App Store capture\n\n"
        "Status: Draft\n"
        "Opening scene: Active terminal\n"
        "Terminal gesture: Scroll past the bottom\n"
        "Final scene: Settings\n\n"
        "Theme timing: Best effort\n"
    )
    (WORKSPACE / "evidence" / "checkpoints.md").unlink(missing_ok=True)
    server = _CodexFixtureServer()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        provider = (
            "{ name = \"Threading Fixture\", "
            f"base_url = \"{server.base_url}\", "
            "env_key = \"THREADING_MARKETING_FIXTURE_KEY\", "
            "wire_api = \"responses\", requires_openai_auth = false, "
            "request_max_retries = 0, stream_max_retries = 0 }"
        )
        environment = _recording_environment()
        environment.update(
            {
                "THREADING_MARKETING_FIXTURE_KEY": "local-fixture-only",
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            }
        )
        environment.pop("NO_COLOR", None)
        environment["COLORFGBG"] = TERMINAL_MODES[terminal_mode]["colorfgbg"]
        payload = capture_pty(
            [
                require_binary("codex"),
                "-C",
                str(WORKSPACE),
                "-m",
                "gpt-5.6-sol",
                "-a",
                "never",
                "-s",
                "workspace-write",
                "-c",
                'model_provider="threading_fixture"',
                "-c",
                f"model_providers.threading_fixture={provider}",
                "-c",
                "ephemeral=true",
                "-c",
                'history.persistence="none"',
                "-c",
                "mcp_servers={}",
                "-c",
                "mcp_servers.xcode.enabled=false",
                "-c",
                "plugins={}",
                "-c",
                "tui.show_tooltips=false",
                "-c",
                'model_reasoning_effort="xhigh"',
                CODEX_PROMPT,
            ],
            columns=GRID_COLUMNS,
            rows=PROVIDERS["codex"]["rows"],
            environment=environment,
            settled_marker=PROVIDERS["codex"]["settled_marker"],
            terminal_mode=terminal_mode,
        )
        server.requests.get(timeout=1)
        second_request = server.requests.get(timeout=1)
        if (
            not second_request.get("input")
            or "Status: Ready for review"
            not in (WORKSPACE / "capture-notes.md").read_text()
            or not (WORKSPACE / "evidence" / "checkpoints.md").is_file()
        ):
            raise RuntimeError("Codex fixture did not execute and return the synthetic patch")
        return payload
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def fixture(provider: str, payload: bytes, terminal_mode: str) -> dict[str, Any]:
    version = provider_version(provider)
    if provider == "claude":
        provenance = (
            f"Installed Claude Code {version} rendering of a synthetic saved session at "
            f"{GRID_COLUMNS} × {PROVIDERS['claude']['rows']} in safe mode with its built-in "
            f"{terminal_mode} ANSI theme. The temporary session is "
            "deleted immediately after recording. "
            "Screenshot capture only replays these bytes and cannot spend provider usage."
        )
    else:
        provenance = (
            f"Installed Codex {version} rendering a deterministic patch and response at "
            f"{GRID_COLUMNS} × {PROVIDERS['codex']['rows']} into a terminal reporting a "
            f"{terminal_mode} background, from a localhost-only fixture provider in an "
            "ephemeral MCP-free profile and disposable workspace. Screenshot capture only "
            "replays these bytes and cannot spend provider usage."
        )
    return {
        "schemaVersion": 1,
        "kind": "threading-mobile-terminal-pty-fixture",
        "provider": provider,
        "providerVersion": version,
        "terminalMode": terminal_mode,
        "columns": GRID_COLUMNS,
        "rows": PROVIDERS[provider]["rows"],
        "provenance": provenance,
        "payloadBase64": base64.b64encode(payload).decode(),
    }


def validate(provider: str, payload: bytes) -> None:
    if len(payload) < 1_500 or b"\x1b" not in payload:
        raise RuntimeError(f"{provider} recording is not a complete PTY stream")
    if b"/Users/" in payload or b"/home/" in payload:
        raise RuntimeError(f"{provider} recording contains a private home path")
    startup_failures = (b"authentication rejected", b"MCP client")
    if any(marker in payload for marker in startup_failures):
        raise RuntimeError(f"{provider} recording contains a provider startup failure")
    codes = set(re.findall(rb"\x1b\[([0-9;:]*)m", payload))
    if provider == "claude":
        if (
            b"capture-plan.md" not in payload
            or b"Added" not in payload
            or b"removed" not in payload
        ):
            raise RuntimeError("Claude recording did not render its native Edit diff")
        if not any(code in payload for code in (b"\x1b[31m", b"\x1b[91m")):
            raise RuntimeError(f"Claude recording has no removed-line ANSI colour; SGR={codes}")
        if not any(code in payload for code in (b"\x1b[32m", b"\x1b[92m")):
            raise RuntimeError(f"Claude recording has no added-line ANSI colour; SGR={codes}")
    else:
        if b"Edited" not in payload or b"capture-notes.md" not in payload:
            raise RuntimeError("Codex recording did not render its native file-change block")
        rich_foregrounds = {code for code in codes if code.startswith(b"38;")}
        if len(rich_foregrounds) < 4:
            raise RuntimeError(
                "Codex recording did not render its syntax/diff palette; "
                f"foreground SGR={rich_foregrounds}"
            )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--provider",
        choices=["all", *PROVIDERS],
        default="all",
        help="Provider fixture to regenerate (default: all)",
    )
    parser.add_argument(
        "--terminal-mode",
        choices=["all", *TERMINAL_MODES],
        default="all",
        help="Terminal background the recording is made for (default: all)",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    selected = list(PROVIDERS) if arguments.provider == "all" else [arguments.provider]
    modes = (
        list(TERMINAL_MODES)
        if arguments.terminal_mode == "all"
        else [arguments.terminal_mode]
    )
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    for provider in selected:
        for terminal_mode in modes:
            payload = (
                record_claude(terminal_mode)
                if provider == "claude"
                else record_codex(terminal_mode)
            )
            validate(provider, payload)
            suffix = TERMINAL_MODES[terminal_mode]["suffix"]
            destination = FIXTURE_DIRECTORY / f"marketing-{provider}-tui{suffix}.json"
            destination.write_text(
                json.dumps(fixture(provider, payload, terminal_mode), indent=2, ensure_ascii=False)
                + "\n"
            )
            print(
                f"Recorded {provider} ({terminal_mode}): {len(payload)} PTY bytes -> {destination}"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
