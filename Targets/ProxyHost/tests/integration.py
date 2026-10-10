#!/usr/bin/env python3
"""Exercise the real helper over loopback sockets; no Internet or installed CA needed."""
import concurrent.futures
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import socket
import socketserver
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest


BINARY = str(Path(sys.argv.pop(1)).resolve())


def read_all(connection):
    parts = []
    while True:
        part = connection.recv(65536)
        if not part:
            return b"".join(parts)
        parts.append(part)


def read_headers(connection):
    # Read exactly to the delimiter so following tunnel/body bytes remain in the socket.
    data = bytearray()
    while not data.endswith(b"\r\n\r\n"):
        byte = connection.recv(1)
        if not byte:
            raise EOFError(bytes(data))
        data.extend(byte)
    return bytes(data)


def respond(connection, body=b"hello"):
    connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)


@contextlib.contextmanager
def origin(callback, ipv6=False):
    errors = queue.Queue()

    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
        allow_reuse_address = True
        address_family = socket.AF_INET6 if ipv6 else socket.AF_INET

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(5)
            try:
                callback(self.request)
            except (ConnectionError, BrokenPipeError):
                pass
            except BaseException as error:
                errors.put(error)

    server = Server(("::1" if ipv6 else "127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server.server_address[1]
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)
        if not errors.empty():
            raise errors.get()


class Proxy:
    def __init__(self, *arguments, consume=True):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [BINARY, "--stdio", *arguments], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.stderr,
        )
        self.events = queue.Queue()
        self.thread = threading.Thread(target=self._consume, args=(consume,), daemon=True)
        self.thread.start()
        ready = self.event()
        if ready["event"] != "ready" or ready["tls_inspection"] != ("--tls-identity" in arguments):
            raise AssertionError(ready)
        self.port = ready["port"]

    def _consume(self, continuous):
        for line in self.process.stdout:
            try:
                self.events.put(json.loads(line))
            except Exception as error:
                self.events.put(error)
            if not continuous:
                return

    def event(self):
        try:
            event = self.events.get(timeout=8)
        except queue.Empty:
            self.stderr.seek(0)
            raise AssertionError(f"No event; exit={self.process.poll()}; {self.stderr.read().decode()}")
        if isinstance(event, Exception):
            raise event
        return event

    def socket(self):
        return socket.create_connection(("127.0.0.1", self.port), timeout=5)

    def request(self, port, suffix=b"", method=b"GET", path=b"/", host=b"127.0.0.1"):
        authority = host + b":" + str(port).encode()
        with self.socket() as connection:
            connection.sendall(method + b" http://" + authority + path + b" HTTP/1.1\r\nHost: " + authority + b"\r\n" + suffix + b"\r\n")
            return read_all(connection)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()  # Portable parent-lifetime shutdown, including Windows.
        try:
            status = self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise AssertionError("Helper did not stop when its parent pipe closed")
        finally:
            self.thread.join(2)
            self.process.stdout.close()
            self.process.stdin.close()
        self.stderr.seek(0)
        error = self.stderr.read().decode()
        self.stderr.close()
        if status or error:
            raise AssertionError(f"Helper exit={status}, stderr={error}")

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()


class Integration(unittest.TestCase):
    def test_absolute_target_and_hop_headers_and_metadata_privacy(self):
        requests = queue.Queue()

        def handler(connection):
            requests.put(read_headers(connection))
            connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: secret\r\nsecret: internal\r\nSet-Cookie: sensitive\r\n\r\nhello")

        with origin(handler) as port, Proxy() as proxy:
            response = proxy.request(port,
                b"Connection: x-remove\r\nX-Remove: internal\r\nProxy-Authorization: hidden\r\nAuthorization: forwarded\r\n",
                path=b"/private?token=secret")
            request = requests.get(timeout=2)
            self.assertTrue(request.startswith(b"GET /private?token=secret HTTP/1.1\r\n"))
            self.assertNotIn(b"X-Remove", request)
            self.assertNotIn(b"Proxy-Authorization", request)
            self.assertIn(b"Authorization: forwarded", request)
            self.assertNotIn(b"secret: internal", response)
            self.assertIn(b"Set-Cookie: sensitive", response)
            self.assertTrue(response.endswith(b"hello"))
            event = proxy.event()
            self.assertEqual(event["result"], "complete")
            self.assertEqual(event["status"], 200)
            for secret in ("private", "token", "secret", "hidden", "sensitive", "forwarded", "hello"):
                self.assertNotIn(secret, json.dumps(event))

    def test_fragmented_headers_and_query_without_path(self):
        requests = queue.Queue()
        with origin(lambda c: (requests.put(read_headers(c)), respond(c))) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                request = f"GET http://127.0.0.1:{port}?x=1 HTTP/1.1\r\nHost: ignored\r\n\r\n".encode()
                for byte in request:
                    connection.sendall(bytes([byte]))
                self.assertTrue(read_all(connection).endswith(b"hello"))
            self.assertTrue(requests.get(timeout=2).startswith(b"GET /?x=1 HTTP/1.1"))

    def test_upload_streams_before_body_finishes_and_expect_continue(self):
        prefix_seen = threading.Event()

        def handler(connection):
            headers = read_headers(connection)
            self.assertIn(b"Expect: 100-continue", headers)
            connection.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            self.assertEqual(connection.recv(3), b"abc")
            prefix_seen.set()
            self.assertEqual(connection.recv(3), b"def")
            respond(connection)

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"POST http://127.0.0.1:{port}/ HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\nExpect: 100-continue\r\n\r\n".encode())
                self.assertIn(b"100 Continue", read_headers(connection))
                connection.sendall(b"abc")
                self.assertTrue(prefix_seen.wait(2), "Proxy buffered an incomplete upload")
                connection.sendall(b"def")
                self.assertTrue(read_all(connection).endswith(b"hello"))

    def test_chunked_upload(self):
        bodies = queue.Queue()

        def handler(connection):
            read_headers(connection)
            data = bytearray()
            while not data.endswith(b"0\r\n\r\n"):
                data.extend(connection.recv(32))
            bodies.put(bytes(data))
            respond(connection)

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"POST http://127.0.0.1:{port}/ HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n".encode())
                for part in (b"3\r\nabc\r\n", b"2\r\nde\r\n", b"0\r\n\r\n"):
                    connection.sendall(part)
                self.assertTrue(read_all(connection).endswith(b"hello"))
            self.assertEqual(bodies.get(timeout=2), b"3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")

    def test_response_streams_before_origin_finishes(self):
        release_origin = threading.Event()

        def handler(connection):
            read_headers(connection)
            connection.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n")
            self.assertTrue(release_origin.wait(3))
            connection.sendall(b"0\r\n\r\n")

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"GET http://127.0.0.1:{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                read_headers(connection)
                prefix = bytearray()
                try:
                    while len(prefix) < 8:
                        prefix.extend(connection.recv(8 - len(prefix)))
                    self.assertEqual(prefix, b"3\r\nabc\r\n")
                finally:
                    release_origin.set()
                self.assertEqual(read_all(connection), b"0\r\n\r\n")

    def test_close_delimited_response(self):
        with origin(lambda c: (read_headers(c), c.sendall(b"HTTP/1.0 200 OK\r\n\r\nhello"))) as port, Proxy() as proxy:
            self.assertTrue(proxy.request(port).endswith(b"hello"))
            self.assertEqual(proxy.event()["result"], "complete")

    def test_head_and_no_content_do_not_wait_for_declared_body(self):
        for status, method in ((b"200 OK", b"HEAD"), (b"204 No Content", b"GET"), (b"304 Not Modified", b"GET")):
            with self.subTest(status=status):
                with origin(lambda c: (read_headers(c), c.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Length: 123\r\n\r\n"))) as port, Proxy() as proxy:
                    response = proxy.request(port, method=method)
                    self.assertTrue(response.endswith(b"\r\n\r\n"))
                    self.assertEqual(proxy.event()["result"], "complete")

    def test_informational_responses_in_same_read(self):
        with origin(lambda c: (read_headers(c), c.sendall(b"HTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\n"), respond(c))) as port, Proxy() as proxy:
            response = proxy.request(port)
            self.assertIn(b"103 Early Hints", response)
            self.assertIn(b"200 OK", response)
            self.assertEqual(proxy.event()["status"], 200)

    def test_connect_binary_and_client_half_close(self):
        body = bytes(range(256)) * 1024

        def handler(connection):
            received = read_all(connection)
            self.assertEqual(received, body)
            connection.sendall(hashlib.sha256(received).digest())

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode() + body[:10])
                self.assertIn(b"200 Connection Established", read_headers(connection))
                connection.sendall(body[10:])
                connection.shutdown(socket.SHUT_WR)
                self.assertEqual(read_all(connection), hashlib.sha256(body).digest())
            event = proxy.event()
            self.assertTrue(event["tunnel"])
            self.assertEqual(event["result"], "complete")

    def test_connect_origin_half_close_preserves_reverse_direction(self):
        received = queue.Queue()

        def handler(connection):
            connection.sendall(b"greeting")
            connection.shutdown(socket.SHUT_WR)
            received.put(read_all(connection))

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                read_headers(connection)
                self.assertEqual(read_all(connection), b"greeting")
                connection.sendall(b"reply after eof")
                connection.shutdown(socket.SHUT_WR)
            self.assertEqual(received.get(timeout=2), b"reply after eof")
            self.assertEqual(proxy.event()["result"], "complete")

    def test_real_https_through_connect_keeps_end_to_end_tls(self):
        openssl = shutil.which("openssl")
        if not openssl:
            self.skipTest("OpenSSL CLI needed only to generate the test's ephemeral TLS identity")
        with tempfile.TemporaryDirectory() as scratch:
            cert, key = Path(scratch) / "cert.pem", Path(scratch) / "key.pem"
            subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                            "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True, timeout=15)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            client_context = ssl.create_default_context(cafile=str(cert))

            def handler(connection):
                with server_context.wrap_socket(connection, server_side=True) as tls:
                    read_headers(tls)
                    respond(tls, b"encrypted payload")

            with origin(handler) as port, Proxy() as proxy:
                with proxy.socket() as connection:
                    connection.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n".encode())
                    read_headers(connection)
                    with client_context.wrap_socket(connection, server_hostname="localhost") as tls:
                        tls.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                        self.assertTrue(read_all(tls).endswith(b"encrypted payload"))
                event = proxy.event()
                self.assertTrue(event["tunnel"])
                self.assertNotIn("encrypted payload", json.dumps(event))

    def test_ipv6_destination(self):
        try:
            probe = socket.socket(socket.AF_INET6)
            probe.bind(("::1", 0))
            probe.close()
        except OSError:
            self.skipTest("Runner has no IPv6 loopback")
        with origin(lambda c: (read_headers(c), respond(c)), ipv6=True) as port, Proxy() as proxy:
            self.assertTrue(proxy.request(port, host=b"[::1]").endswith(b"hello"))

    def test_dns_address_fallback(self):
        # localhost commonly resolves to ::1 before 127.0.0.1; this origin binds IPv4 only.
        with origin(lambda c: (read_headers(c), respond(c))) as port, Proxy() as proxy:
            self.assertTrue(proxy.request(port, host=b"localhost").endswith(b"hello"))

    def test_ambiguous_and_unsupported_requests_are_rejected_before_connect(self):
        invalid = [
            b"GET http://example.com/ HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n",
            b"POST http://example.com/ HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            b"POST http://example.com/ HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            b"POST http://example.com/ HTTP/1.1\r\nContent-Length: 1\r\nConnection: content-length\r\n\r\n",
            b"GET http://example.com/ HTTP/1.1\r\nHost: x\r\n folded: x\r\n\r\n",
            b"GET http://name:password@example.com/ HTTP/1.1\r\n\r\n",
            b"GET http://example.com:0/ HTTP/1.1\r\n\r\n",
            b"GET http://example.com:65536/ HTTP/1.1\r\n\r\n",
            b"GET http://[face]:80/ HTTP/1.1\r\n\r\n",
            b"GET http://example.com/path#fragment HTTP/1.1\r\n\r\n",
            b"GET https://example.com/ HTTP/1.1\r\n\r\n",
            b"GET /origin-form HTTP/1.1\r\n\r\n",
            b"CONNECT example.com HTTP/1.1\r\n\r\n",
            b"CONNECT example.com:443 HTTP/1.1\r\nContent-Length: 1\r\n\r\nx",
            b"GET http://example.com/ HTTP/1.1\r\nUpgrade: websocket\r\n\r\n",
        ]
        with Proxy() as proxy:
            for request in invalid:
                with self.subTest(request=request), proxy.socket() as connection:
                    connection.sendall(request)
                    self.assertIn(b"400 Proxy Error", read_all(connection))

    def test_header_count_and_size_limits(self):
        with Proxy() as proxy:
            for headers in (b"X: y\r\n" * 129, b"X: " + b"a" * 32768):
                with proxy.socket() as connection:
                    connection.sendall(b"GET http://example.com/ HTTP/1.1\r\n" + headers + b"\r\n")
                    self.assertIn(b"400 Proxy Error", read_all(connection))

    def test_truncated_response_is_reported(self):
        with origin(lambda c: (read_headers(c), c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort"))) as port, Proxy() as proxy:
            self.assertTrue(proxy.request(port).endswith(b"short"))
            self.assertEqual(proxy.event()["result"], "truncated_response")

    def test_invalid_upstream_framing_is_not_forwarded(self):
        with origin(lambda c: (read_headers(c), c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n"))) as port, Proxy() as proxy:
            self.assertIn(b"502 Proxy Error", proxy.request(port))

    def test_pipelined_second_request_is_never_forwarded(self):
        requests = queue.Queue()

        def handler(connection):
            requests.put(read_headers(connection))
            respond(connection)

        with origin(handler) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                request = f"GET http://127.0.0.1:{port}/one HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
                connection.sendall(request + request.replace(b"/one", b"/two"))
                self.assertTrue(read_all(connection).endswith(b"hello"))
            self.assertIn(b"/one", requests.get(timeout=2))
            self.assertTrue(requests.empty())

    def test_connection_refused_and_self_proxy_do_not_loop(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            unused = reservation.getsockname()[1]
        with Proxy() as proxy:
            self.assertIn(b"502 Proxy Error", proxy.request(unused))
            self.assertIn(b"502 Proxy Error", proxy.request(proxy.port))

    def test_idle_timeout_and_connection_budget(self):
        with Proxy("--idle-timeout-ms", "250", "--max-connections", "1") as proxy:
            with proxy.socket() as first:
                first.sendall(b"G")
                time.sleep(0.05)
                with proxy.socket() as second:
                    try:
                        self.assertEqual(second.recv(1), b"")
                    except ConnectionResetError:
                        pass
                self.assertIn(b"504 Proxy Error", read_all(first))
            self.assertEqual(proxy.event()["result"], "timeout")

    def test_large_slow_download_has_bounded_write_queue(self):
        body = b"0123456789abcdef" * (512 * 1024)
        with origin(lambda c: (read_headers(c), respond(c, body))) as port, Proxy() as proxy:
            with proxy.socket() as connection:
                connection.sendall(f"GET http://127.0.0.1:{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                read_headers(connection)
                time.sleep(0.1)
                received = read_all(connection)
                self.assertEqual(hashlib.sha256(received).digest(), hashlib.sha256(body).digest())
            event = proxy.event()
            self.assertLessEqual(event["peak_pending_bytes"], 2 * (262144 + 32768 + 1024))

    def test_parallel_clients_and_stalled_event_consumer(self):
        count = int(os.environ.get("THREADING_PROXY_STRESS_FLOWS", "700"))
        with origin(lambda c: (read_headers(c), respond(c))) as port, Proxy(consume=False) as proxy:
            def request(_):
                self.assertTrue(proxy.request(port).endswith(b"hello"))

            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
                list(executor.map(request, range(count)))
            # Resume the observer after enough flows to fill both the OS pipe and event queue.
            proxy.thread = threading.Thread(target=proxy._consume, args=(True,), daemon=True)
            proxy.thread.start()
            time.sleep(0.05)
            request(None)
            dropped = 0
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                event = proxy.event()
                dropped = max(dropped, event["dropped_events"])
                if dropped:
                    break
            self.assertGreater(dropped, 0)

    def test_parent_exit_stops_active_tunnel(self):
        with origin(lambda c: read_all(c)) as port:
            proxy = Proxy()
            with proxy.socket() as connection:
                connection.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n".encode())
                self.assertIn(b"200", read_headers(connection))
                proxy.close()
                self.assertEqual(connection.recv(1), b"")

    def test_cancel_during_resolution_and_large_writes(self):
        def cancelled_origin(connection):
            try:
                read_headers(connection)
            except EOFError:
                return  # Cancellation may win after upstream accept but before request forwarding.
            respond(connection, b"x" * (1024 * 1024))

        with origin(cancelled_origin) as port, Proxy() as proxy:
            for _ in range(60):
                connection = proxy.socket()
                connection.sendall(f"GET http://localhost:{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
                connection.close()
            self.assertTrue(proxy.request(port).endswith(b"x" * 1024))

    def test_stdout_file_and_broken_capture_pipe(self):
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            process = subprocess.Popen([BINARY, "--stdio"], stdin=subprocess.PIPE, stdout=output, stderr=errors)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    output.seek(0)
                    line = output.readline()
                    if line.endswith(b"\n"):
                        break
                    time.sleep(0.01)
                ready = json.loads(line)
                self.assertEqual(ready["event"], "ready")
            finally:
                process.stdin.close()
                self.assertEqual(process.wait(timeout=5), 0)
        with origin(lambda c: (read_headers(c), respond(c))) as port, Proxy(consume=False) as proxy:
            proxy.thread.join(2)
            proxy.process.stdout.close()
            for _ in range(3):
                self.assertTrue(proxy.request(port).endswith(b"hello"))

    def test_stop_command_and_invalid_cli(self):
        with Proxy() as proxy:
            proxy.process.stdin.write(b"stop\n")
            proxy.process.stdin.flush()
            self.assertEqual(proxy.process.wait(timeout=5), 0)
        for args in (("--port", "-1"), ("--port", "999999999999999999"), ("--max-connections", "0"), ("--unknown", "1")):
            result = subprocess.run([BINARY, *args], capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
