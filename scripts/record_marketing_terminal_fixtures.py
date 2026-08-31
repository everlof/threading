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

PROVIDERS = {
    "claude": {
        "binary": "claude",
        "rows": 38,
        "settled_marker": b"recapture",
        "version_prefix": "Claude Code ",
    },
    "codex": {
        "binary": "codex",
        "rows": 42,
        "settled_marker": b"Evidence assertions passed",
        "version_prefix": "codex-cli ",
    },
}


CLAUDE_PROMPT = (
    "Prepare the repeatable App Store capture flow and verify every checkpoint."
)
CLAUDE_RESPONSE = """I’ll verify the fixture-backed capture path and its fixed video timeline.

```diff
- Crossfade static screenshots
+ Begin in the draft and open its model picker
+ Scroll Codex toward older output
+ Finish on the Usage chart
```

Completed:
- Recorded real Claude and Codex TUI fixtures
- Seeded four mixed-provider sessions
- Replayed one fixed-frame interaction clock
- Verified Usage chart and provider palettes

Every recapture replays local PTY bytes, so it is deterministic and spends no provider usage."""

CODEX_PROMPT = "Verify the App Store capture flow."
CODEX_RESPONSE = """Implemented and verified the repeatable capture flow.

## What changed

```diff
- Begin on an already-open terminal
+ Begin in the New Session draft
+ Choose GPT-5.6 Sol · Extra High
- Push the terminal past its bottom edge
+ Scroll back toward earlier Codex output
```

## Capture contract

- The draft becomes the real fixture-backed chat.
- Claude exposes its task plan through shipping chrome.
- Usage ends on the daily provider chart.
- Every theme follows the same 900-frame clock.

## Validation

✓ 5 product screenshots render at native scale
✓ 900 video frames render at 30 fps
✓ Evidence assertions passed
✓ 0 provider calls during recapture

The fixtures now exercise each provider’s own diff colors while remaining deterministic."""


def _json_line(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _write_claude_session() -> Path:
    config = Path(
        os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))
    ).expanduser()
    project = config / "projects" / "-private-tmp-threading-marketing-tui"
    project.mkdir(parents=True, exist_ok=True)
    user_id = "62987373-0c8f-4aa1-a50a-294f4b62e752"
    assistant_id = "8c73f143-c624-410a-9ea3-984bc2b93bc0"
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
            "permissionMode": "plan",
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
                "content": [{"type": "text", "text": CLAUDE_RESPONSE}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {
                    "input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 0,
                },
            },
            "uuid": assistant_id,
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
        self.rfile.read(length)
        if not self.path.endswith("/responses"):
            self.send_error(404)
            return
        self.server.requests.put(self.path)
        response_id = "resp_threading_marketing_fixture"
        body = _sse(
            [
                {"type": "response.created", "response": {"id": response_id}},
                {
                    "type": "response.output_item.done",
                    "item": {
                        "type": "message",
                        "role": "assistant",
                        "id": "msg_threading_marketing_fixture",
                        "content": [{"type": "output_text", "text": CODEX_RESPONSE}],
                    },
                },
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
                },
            ]
        )
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
        self.requests: queue.Queue[str] = queue.Queue()

    @property
    def base_url(self) -> str:
        host, port = self.server_address
        return f"http://{host}:{port}/v1"


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


def _terminal_response(chunk: bytes) -> bytes:
    response = bytearray()
    if b"\x1b]10;?" in chunk:
        response.extend(b"\x1b]10;rgb:d9d9/d1d1/c8c8\x1b\\")
    if b"\x1b]11;?" in chunk:
        response.extend(b"\x1b]11;rgb:0404/0a0a/1212\x1b\\")
    if b"\x1b[6n" in chunk:
        response.extend(b"\x1b[1;1R")
    if b"\x1b[c" in chunk:
        response.extend(b"\x1b[?1;2c")
    return bytes(response)


def capture_pty(
    command: list[str],
    *,
    rows: int,
    environment: dict[str, str],
    settled_marker: bytes,
    timeout: float = 20,
) -> bytes:
    pid, descriptor = pty.fork()
    if pid == 0:
        size = struct.pack("HHHH", rows, 48, 0, 0)
        fcntl.ioctl(0, termios.TIOCSWINSZ, size)
        os.chdir(WORKSPACE)
        os.execvpe(command[0], command, environment)
        raise AssertionError("exec returned")

    captured = bytearray()
    started = time.monotonic()
    last_output = started
    marker_seen_at: float | None = None
    timed_out = False
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
                reply = _terminal_response(chunk)
                if reply:
                    os.write(descriptor, reply)
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


def record_claude() -> bytes:
    session = _write_claude_session()
    environment = os.environ.copy()
    environment.update(
        {
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
        }
    )
    environment.pop("NO_COLOR", None)
    try:
        return capture_pty(
            [
                require_binary("claude"),
                "--resume",
                CLAUDE_SESSION_ID,
                "--safe-mode",
                "--settings",
                '{"theme":"dark-ansi"}',
                "--permission-mode",
                "plan",
            ],
            rows=PROVIDERS["claude"]["rows"],
            environment=environment,
            settled_marker=PROVIDERS["claude"]["settled_marker"],
        )
    finally:
        session.unlink(missing_ok=True)


def record_codex() -> bytes:
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
        environment = os.environ.copy()
        environment.update(
            {
                "THREADING_MARKETING_FIXTURE_KEY": "local-fixture-only",
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            }
        )
        environment.pop("NO_COLOR", None)
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
                "read-only",
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
                'model_reasoning_effort="xhigh"',
                CODEX_PROMPT,
            ],
            rows=PROVIDERS["codex"]["rows"],
            environment=environment,
            settled_marker=PROVIDERS["codex"]["settled_marker"],
        )
        server.requests.get(timeout=1)
        return payload
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def fixture(provider: str, payload: bytes) -> dict[str, Any]:
    version = provider_version(provider)
    if provider == "claude":
        provenance = (
            f"Installed Claude Code {version} rendering of a synthetic saved session at "
            "48 × 38 in safe mode with its built-in dark ANSI theme. The temporary session is "
            "deleted immediately after recording. "
            "Screenshot capture only replays these bytes and cannot spend provider usage."
        )
    else:
        provenance = (
            f"Installed Codex {version} rendering a deterministic response from a "
            "localhost-only fixture provider in an ephemeral MCP-free profile. Screenshot "
            "capture only replays these bytes and cannot spend provider usage."
        )
    return {
        "schemaVersion": 1,
        "kind": "threading-mobile-terminal-pty-fixture",
        "provider": provider,
        "providerVersion": version,
        "columns": 48,
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
        if not any(code in payload for code in (b"\x1b[31m", b"\x1b[91m")):
            raise RuntimeError(f"Claude recording has no removed-line ANSI colour; SGR={codes}")
        if not any(code in payload for code in (b"\x1b[32m", b"\x1b[92m")):
            raise RuntimeError(f"Claude recording has no added-line ANSI colour; SGR={codes}")
    else:
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
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    selected = list(PROVIDERS) if arguments.provider == "all" else [arguments.provider]
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    for provider in selected:
        payload = record_claude() if provider == "claude" else record_codex()
        validate(provider, payload)
        destination = FIXTURE_DIRECTORY / f"marketing-{provider}-tui.json"
        destination.write_text(
            json.dumps(fixture(provider, payload), indent=2, ensure_ascii=False) + "\n"
        )
        print(f"Recorded {provider}: {len(payload)} PTY bytes -> {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
