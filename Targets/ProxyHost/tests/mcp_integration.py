#!/usr/bin/env python3
"""Exercise the shipped executable's MCP stdio transport and capture lease."""
import base64
import contextlib
import hashlib
import gzip
import zlib
import json
from pathlib import Path
import plistlib
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from integration import BINARY, Proxy, origin, read_all, read_headers, respond
from tls_integration import Certificates, connect, tls_origin


class MCP(Proxy):
    def __init__(self, *arguments, initialize=True):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([BINARY, "--mcp", *arguments], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        self.events = queue.Queue()
        self.thread = threading.Thread(target=self._consume, args=(True,), daemon=True)
        self.thread.start()
        self.sequence = 0
        if initialize:
            self.initialize()

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def rpc(self, method, params=None):
        self.sequence += 1
        message = {"jsonrpc": "2.0", "id": self.sequence, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        response = self.event()
        if response["id"] != self.sequence or response["jsonrpc"] != "2.0":
            raise AssertionError(response)
        return response

    def initialize(self):
        response = self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                           "clientInfo": {"name": "test", "version": "1"}})
        if response["result"]["protocolVersion"] != "2025-11-25":
            raise AssertionError(response)
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def tool(self, name, arguments=None):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in result or result["result"]["isError"]:
            raise AssertionError(result)
        return json.loads(result["result"]["content"][0]["text"])

    def start(self):
        result = self.tool("traffic_start")
        self.port = result["port"]
        return result


class MCPIntegration(unittest.TestCase):
    @contextlib.contextmanager
    def raw_mcp(self):
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen([BINARY, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, bufsize=0)
            try:
                initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {}}}
                process.stdin.write(json.dumps(initialize).encode() + b"\n")
                self.assertIn("result", json.loads(process.stdout.readline()))
                process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                process.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"traffic_start"}}\n')
                result = json.loads(process.stdout.readline())
                port = json.loads(result["result"]["content"][0]["text"])["port"]
                yield process, port
            finally:
                process.stdin.close()
                try:
                    status = process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise AssertionError("MCP lease did not close")
                process.stdout.close()
                errors.seek(0)
                self.assertEqual(errors.read(), b"")
                self.assertEqual(status, 0)

    def test_closed_output_ends_mcp_lease(self):
        with self.raw_mcp() as (process, port):
            process.stdout.close()
            process.stdin.write(b'{"jsonrpc":"2.0","id":3,"method":"ping"}\n')
            self.assertEqual(process.wait(timeout=5), 0)
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_stalled_output_cannot_accumulate_unbounded_replies(self):
        with self.raw_mcp() as (process, port):
            request = b'{"jsonrpc":"2.0","id":3,"method":"tools/list"}\n'
            try:
                for _ in range(512):
                    process.stdin.write(request)
            except BrokenPipeError:
                pass
            self.assertEqual(process.wait(timeout=5), 0)
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", port), timeout=1)

    def test_initialization_catalog_and_idle_start(self):
        with MCP(initialize=False) as mcp:
            self.assertIn("error", mcp.rpc("tools/list"))
            mcp.initialize()
            catalog = mcp.rpc("tools/list")["result"]["tools"]
            self.assertEqual({t["name"] for t in catalog}, {"traffic_status", "traffic_start", "traffic_stop",
                                                         "traffic_get", "traffic_list", "traffic_clear", "traffic_certificate", "traffic_body", "traffic_headers"})
            self.assertFalse(mcp.tool("traffic_status")["running"])
            self.assertEqual(mcp.rpc("ping")["result"], {})
            self.assertTrue(mcp.start()["running"])
            self.assertEqual(mcp.start()["port"], mcp.port)  # Idempotent.
            self.assertFalse(mcp.tool("traffic_stop")["running"])
            self.assertFalse(mcp.tool("traffic_stop")["running"])
            self.assertTrue(mcp.start()["running"])

    def test_bounded_history_paging_detail_clear_and_restart_ids(self):
        def reply(connection):
            read_headers(connection)
            respond(connection)

        with origin(reply) as port, MCP() as mcp:
            mcp.start()
            for _ in range(140):
                self.assertTrue(mcp.request(port, path=b"/secret?token=password", suffix=b"Authorization: secret\r\n").endswith(b"hello"))
            time.sleep(0.05)
            first = mcp.tool("traffic_list", {"limit": 7})
            self.assertTrue(first["earlier_records_unavailable"])
            self.assertEqual(len(first["flows"]), 7)
            self.assertEqual(first["flows"][0]["id"], "13")
            self.assertTrue(first["has_more"])
            self.assertNotIn("secret", json.dumps(first))
            detail = mcp.tool("traffic_get", {"id": "13"})
            self.assertEqual(detail["status"], first["flows"][0]["status"])
            self.assertNotIn("password", json.dumps(detail))
            self.assertIn("[redacted]", json.dumps(detail))
            seen = list(first["flows"])
            page = first
            while page["has_more"]:
                page = mcp.tool("traffic_list", {"after": page["next_cursor"]})
                seen.extend(page["flows"])
            self.assertEqual([int(f["id"]) for f in seen], list(range(13, 141)))
            mcp.tool("traffic_clear")
            self.assertEqual(mcp.tool("traffic_list")["flows"], [])
            missing = mcp.rpc("tools/call", {"name": "traffic_get", "arguments": {"id": "13"}})
            self.assertTrue(missing["result"]["isError"])
            mcp.tool("traffic_stop")
            mcp.start()
            mcp.request(port)
            time.sleep(0.03)
            self.assertEqual(mcp.tool("traffic_list")["flows"][0]["id"], "141")

    def test_request_and_error_response_json_redaction_and_exact_bytes(self):
        request = b'{"name":"Ada","password":"dont-leak","nested":{"access_token":"private"}}'
        response = b'{ "id": 18446744073709551615, "error":"invalid input","details":[1,{"password":{"nested":[1,2]}}],"token":"server-secret","precise":0.12345678901234567890 }'
        def reply(connection):
            read_headers(connection)
            incoming = b""
            while len(incoming) < len(request):
                incoming += connection.recv(len(request) - len(incoming))
            self.assertEqual(incoming, request)
            connection.sendall(b"HTTP/1.1 422 Unprocessable Content\r\nContent-Type: application/json\r\nSet-Cookie: session=private\r\nContent-Length: " + str(len(response)).encode() + b"\r\n\r\n" + response)
        with origin(reply) as port, MCP() as mcp:
            mcp.start()
            with mcp.socket() as connection:
                connection.sendall(f"POST http://127.0.0.1:{port}/api?access%5Ftoken=private&x=ok HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nAuthorization: Bearer private\r\nContent-Length: {len(request)}\r\n\r\n".encode() + request)
                self.assertTrue(read_all(connection).endswith(response))
            time.sleep(0.03)
            detail = mcp.tool("traffic_get", {"id": "1"})
            self.assertEqual(detail["status"], 422)
            self.assertNotIn("private", json.dumps(detail))
            self.assertTrue(detail["request"]["complete"])
            self.assertTrue(detail["response"]["complete"])
            for side, expected in [("request", request), ("response", response)]:
                page = mcp.tool("traffic_body", {"id": "1", "side": side})
                self.assertEqual(page["encoding"], "utf8")
                self.assertIn("[redacted]", page["data"])
                if side == "response":
                    self.assertIn("18446744073709551615", page["data"])
                    self.assertIn("0.12345678901234567890", page["data"])
                    self.assertEqual(json.loads(page["data"])["details"][1]["password"], "[redacted]")
                raw = mcp.tool("traffic_body", {"id": "1", "side": side, "decode": False, "redact": False})
                self.assertEqual(base64.b64decode(raw["data"]), expected)
            header = mcp.tool("traffic_headers", {"id": "1", "side": "request", "index": 2})
            self.assertEqual(header["data"], "[redacted]")
            raw = mcp.tool("traffic_headers", {"id": "1", "side": "request", "index": 2, "redact": False})
            self.assertEqual(raw["data"], "Bearer private")

    def test_chunked_gzip_binary_and_byte_pages(self):
        payload = ("Hello åäö 🌍! " * 1000).encode()
        compressed = gzip.compress(payload)
        def reply(connection):
            read_headers(connection)
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n")
            for i in range(0, len(compressed), 11):
                chunk = compressed[i:i+11]
                connection.sendall(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            connection.sendall(b"0\r\n\r\n")
        with origin(reply) as port, MCP() as mcp:
            mcp.start()
            mcp.request(port)
            time.sleep(0.03)
            result = bytearray()
            offset = 0
            while True:
                page = mcp.tool("traffic_body", {"id": "1", "side": "response", "offset": offset, "limit": 37})
                result.extend(page["data"].encode() if page["encoding"] == "utf8" else base64.b64decode(page["data"]))
                if not page["has_more"]:
                    break
                offset = page["next_offset"]
            self.assertEqual(result, payload)
            raw = mcp.tool("traffic_body", {"id": "1", "side": "response", "decode": False, "redact": False})
            self.assertEqual(base64.b64decode(raw["data"]), compressed)

    def test_limits_preserve_forwarding_and_mark_partial_payload(self):
        payload = bytes(range(256)) * 1024
        def reply(connection):
            read_headers(connection)
            respond(connection, payload)
        with origin(reply) as port, MCP("--body-limit", "1024") as mcp:
            mcp.start()
            self.assertTrue(mcp.request(port).endswith(payload))
            time.sleep(0.03)
            detail = mcp.tool("traffic_get", {"id": "1"})
            self.assertEqual(detail["response"]["captured_body_bytes"], 1024)
            self.assertEqual(detail["response"]["observed_body_bytes"], str(len(payload)))
            self.assertTrue(detail["response"]["body_truncated"])
            page = mcp.tool("traffic_body", {"id": "1", "side": "response", "redact": False})
            self.assertEqual(base64.b64decode(page["data"]), payload[:1024])
            self.assertTrue(page["capture_truncated"])
            mcp.tool("traffic_clear")
            self.assertEqual(mcp.tool("traffic_status")["retained_capture_bytes"], 0)

    def test_history_evicts_by_byte_budget_and_partial_origin_is_inspectable(self):
        payload = b"x" * 1048576
        def reply(connection):
            read_headers(connection)
            respond(connection, payload)
        with origin(reply) as port, MCP("--body-limit", "1048576") as mcp:
            mcp.start()
            for _ in range(18):
                self.assertTrue(mcp.request(port).endswith(payload))
            time.sleep(0.03)
            status = mcp.tool("traffic_status")
            self.assertLessEqual(status["retained_capture_bytes"], 16777216)
            self.assertLess(status["retained_flows"], 18)
            self.assertTrue(mcp.tool("traffic_list")["earlier_records_unavailable"])
        def partial(connection):
            read_headers(connection)
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
        with origin(partial) as port, MCP() as mcp:
            mcp.start(); mcp.request(port); time.sleep(0.03)
            detail = mcp.tool("traffic_get", {"id": "1"})
            self.assertFalse(detail["response"]["complete"])
            page = mcp.tool("traffic_body", {"id": "1", "side": "response"})
            self.assertEqual(page["data"], "partial")
            self.assertTrue(page["capture_truncated"])

    def test_decode_budget_and_corrupt_encoding(self):
        payload = b"x" * (2 * 1024 * 1024)
        replies = [gzip.compress(payload), zlib.compress(b"deflate works"), b"broken"]
        for encoded, encoding in zip(replies, [b"gzip", b"deflate", b"gzip"]):
            def reply(connection):
                read_headers(connection)
                connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Encoding: " + encoding + b"\r\nContent-Length: " + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
            with origin(reply) as port, MCP() as mcp:
                mcp.start(); mcp.request(port); time.sleep(0.03)
                if encoded == b"broken":
                    result = mcp.rpc("tools/call", {"name": "traffic_body", "arguments": {"id": "1", "side": "response"}})
                    self.assertTrue(result["result"]["isError"])
                else:
                    page = mcp.tool("traffic_body", {"id": "1", "side": "response"})
                    self.assertEqual(page["decode_truncated"], encoding == b"gzip")
                    self.assertEqual(page["total_bytes"], 1048576 if encoding == b"gzip" else 13)

    def test_protocol_validation(self):
        with MCP() as mcp:
            for raw in [b'{"jsonrpc":"2.0","id":1,"method":"ping","method":"tools/list"}',
                        b'{"jsonrpc":"2.0","id":"\xff","method":"ping"}',
                        b'{"jsonrpc":"2.0","id":"\\u0000","method":"ping"}',
                        b'[' * 40 + b']' * 40, b'{} trailing']:
                mcp.process.stdin.write(raw + b"\n")
                mcp.process.stdin.flush()
                self.assertIn("error", mcp.event())
            for arguments in [{"limit": 21}, {"limit": 0}, {"limit": 1.5}, {"after": "999"},
                              {"after": "-1"}, {"unknown": True}, {"after": "18446744073709551616"}]:
                self.assertIn("error", mcp.rpc("tools/call", {"name": "traffic_list", "arguments": arguments}))
            self.assertIn("error", mcp.rpc("tools/call", {"name": "traffic_start", "arguments": {"tls_hosts": ["elsewhere"]}}))
            self.assertIn("error", mcp.rpc("unsupported"))
            mcp.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}})
            self.assertEqual(mcp.rpc("ping")["result"], {})

    def test_stop_closes_active_tunnel_and_parent_eof_closes_listener(self):
        def wait(connection):
            connection.recv(1)

        with origin(wait) as port:
            mcp = MCP()
            mcp.start()
            proxy_port = mcp.port
            connection, response = connect(mcp, port)
            self.assertIn(b"200", response)
            mcp.tool("traffic_stop")
            with connection:
                self.assertEqual(connection.recv(1), b"")
            mcp.start()
            proxy_port = mcp.port
            mcp.close()
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", proxy_port), timeout=1)

    def test_oversized_control_input_terminates_lease(self):
        with MCP() as mcp:
            mcp.start()
            try:
                mcp.process.stdin.write(b"x" * 65537 + b"\n")
                mcp.process.stdin.flush()
            except BrokenPipeError:
                pass
            self.assertEqual(mcp.process.wait(timeout=5), 0)

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL fixture generator is required")
    def test_tls_capture_and_public_apple_profile_export(self):
        certificates = Certificates()
        try:
            def reply(connection):
                read_headers(connection)
                respond(connection, b"MCP inspected TLS")

            options = certificates.options() + ["--inspection-ca", certificates.path("inspection-ca.pem")]
            with tls_origin(certificates, reply) as port, MCP(*options) as mcp:
                status = mcp.start()
                self.assertEqual(status["tls_hosts"], ["127.0.0.1"])
                public = mcp.tool("traffic_certificate")
                der = base64.b64decode(public["certificate_der_base64"], validate=True)
                self.assertEqual(hashlib.sha256(der).hexdigest(), public["sha256"])
                self.assertEqual(status["inspection_ca_sha256"], public["sha256"])
                profile = plistlib.loads(public["apple_mobileconfig"].encode())
                payload = profile["PayloadContent"][0]
                self.assertEqual(payload["PayloadType"], "com.apple.security.root")
                self.assertEqual(payload["PayloadContent"], der)
                self.assertFalse(profile["PayloadRemovalDisallowed"])
                self.assertNotIn("PRIVATE KEY", json.dumps(public))
                exported = certificates.root / "exported.cer"
                exported.write_bytes(der)
                setup = str(Path(__file__).resolve().parents[1] / "tools/apple_certificate.py")
                for target, extra in [("macos", []), ("simulator", ["--udid", "12345678-1234-1234-1234-1234567890AB"])]:
                    plan = subprocess.run([sys.executable, setup, str(exported), "--sha256", public["sha256"],
                                           "--target", target, *extra], capture_output=True, check=True)
                    planned = json.loads(plan.stdout)
                    self.assertFalse(planned["applied"])
                    self.assertNotIn("reset", planned["command"])
                    self.assertNotIn("sudo", planned["command"])
                for fingerprint, udid in [("0" * 64, "12345678-1234-1234-1234-1234567890AB"), (public["sha256"], "booted")]:
                    invalid = subprocess.run([sys.executable, setup, str(exported), "--sha256", fingerprint,
                                              "--target", "simulator", "--udid", udid], capture_output=True)
                    self.assertEqual(invalid.returncode, 1)
                plain, response = connect(mcp, port)
                self.assertIn(b"200", response)
                with certificates.client().wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                    connection.sendall(f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
                    self.assertTrue(read_all(connection).endswith(b"MCP inspected TLS"))
                time.sleep(0.03)
                flow = mcp.tool("traffic_list")["flows"][0]
                self.assertTrue(flow["tls_inspected"])
                self.assertEqual(flow["method"], "GET")
                self.assertEqual(mcp.tool("traffic_body", {"id": flow["id"], "side": "response"})["data"], "MCP inspected TLS")
            wrong_root = subprocess.run([BINARY, "--mcp", *certificates.options(), "--inspection-ca",
                                         certificates.path("origin-ca.pem")], capture_output=True, timeout=5)
            self.assertEqual(wrong_root.returncode, 2)
        finally:
            certificates.temporary.cleanup()


if __name__ == "__main__":
    unittest.main()
