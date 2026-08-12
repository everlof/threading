#!/usr/bin/env python3
"""One-use, memory-bounded HTTP rendezvous for the physical ICE probe."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import re
import threading
import time

HOST = "127.0.0.1"
PORT = 51_838
TOKEN = os.environ.get("THREADING_PROBE_TOKEN", "")
MAX_BODY_BYTES = 300 * 1024
MAX_CANDIDATES_PER_SIDE = 64
MAX_LIFETIME_SECONDS = 10 * 60
STARTED = time.monotonic()
VALUES: dict[str, bytes] = {}
LOCK = threading.Lock()


def valid_slot(slot: str) -> bool:
    if slot in {"offer", "answer", "completion"}:
        return True
    match = re.fullmatch(r"(mac|phone)-candidate-(\d+)", slot)
    return bool(match and int(match.group(2)) < MAX_CANDIDATES_PER_SIDE)


class RendezvousHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        slot = self.authorized_slot()
        if slot is None:
            return
        with LOCK:
            value = VALUES.get(slot)
        if value is None:
            self.respond(404, b"")
        else:
            self.respond(200, value)

    def do_PUT(self) -> None:
        slot = self.authorized_slot()
        if slot is None:
            return
        try:
            count = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            count = -1
        if count <= 0 or count > MAX_BODY_BYTES:
            self.respond(413, b"")
            return
        body = self.rfile.read(count)
        if len(body) != count:
            self.respond(400, b"")
            return
        with LOCK:
            if slot in VALUES:
                self.respond(409, b"")
                return
            VALUES[slot] = body
        print(f"THREADING_RENDEZVOUS stored slot={slot} bytes={count}", flush=True)
        self.respond(204, b"")

    def authorized_slot(self) -> str | None:
        if time.monotonic() - STARTED > MAX_LIFETIME_SECONDS:
            self.respond(410, b"")
            return None
        parts = self.path.split("?", 1)[0].split("/")
        if len(parts) != 5 or parts[1:3] != ["v1", "probe"]:
            self.respond(404, b"")
            return None
        if parts[3] != TOKEN or not valid_slot(parts[4]):
            self.respond(403, b"")
            return None
        return parts[4]

    def respond(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


if len(TOKEN) < 32:
    raise SystemExit("THREADING_PROBE_TOKEN must contain at least 32 characters")

print(f"THREADING_RENDEZVOUS ready=http://{HOST}:{PORT}", flush=True)
ThreadingHTTPServer((HOST, PORT), RendezvousHandler).serve_forever()
