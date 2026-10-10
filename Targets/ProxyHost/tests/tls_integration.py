#!/usr/bin/env python3
"""Two independent ephemeral CAs. No keychain, system trust, or external network changes."""
import contextlib
from pathlib import Path
import queue
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import unittest

from integration import BINARY, Proxy, origin, read_all, read_headers, respond


class Certificates:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="threading-proxy-tls-")
        self.root = Path(self.temporary.name)
        for name in ("origin", "inspection"):
            self.run("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                     "-keyout", f"{name}-ca.key", "-out", f"{name}-ca.pem", "-days", "2", "-sha256",
                     "-subj", f"/CN=Ephemeral {name} fixture CA",
                     "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        self.leaf("server", "origin", "DNS:localhost,IP:127.0.0.1")
        self.leaf("leaf", "inspection", "IP:127.0.0.1")
        self.leaf("wrong", "origin", "DNS:wrong.invalid")
        self.leaf("expired", "origin", "IP:127.0.0.1", days="-1")
        self.leaf("long-lived", "inspection", "IP:127.0.0.1", days="8")

    def run(self, *arguments):
        subprocess.run([shutil.which("openssl"), *arguments], cwd=self.root, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def leaf(self, name, ca, san, days="1"):
        self.run("req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                 "-keyout", f"{name}.key", "-out", f"{name}.csr", "-subj", f"/CN={name}")
        (self.root / f"{name}.ext").write_text(
            f"basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
            f"extendedKeyUsage=serverAuth\nsubjectAltName={san}\n")
        if days == "-1":
            (self.root / "index").write_text("")
            (self.root / "serial").write_text("10\n")
            (self.root / "expired.cnf").write_text(
                f"[ca]\ndefault_ca=fixture\n[fixture]\ncertificate={ca}-ca.pem\nprivate_key={ca}-ca.key\n"
                "database=index\nserial=serial\nnew_certs_dir=.\ndefault_md=sha256\npolicy=names\n"
                "[names]\ncommonName=supplied\n")
            self.run("ca", "-batch", "-notext", "-config", "expired.cnf", "-in", f"{name}.csr",
                     "-out", f"{name}.pem", "-startdate", "20010101000000Z", "-enddate", "20020101000000Z",
                     "-extfile", f"{name}.ext")
        else:
            self.run("x509", "-req", "-in", f"{name}.csr", "-CA", f"{ca}-ca.pem", "-CAkey", f"{ca}-ca.key",
                     "-CAcreateserial", "-out", f"{name}.pem", "-days", days, "-sha256", "-extfile", f"{name}.ext")

    def path(self, name):
        return str(self.root / name)

    def options(self, ca="origin-ca.pem"):
        return ["--upstream-ca", self.path(ca), "--tls-identity", "127.0.0.1", self.path("leaf.pem"), self.path("leaf.key")]

    def server(self, name="server", version=None):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.path(f"{name}.pem"), self.path(f"{name}.key"))
        context.set_alpn_protocols(["h2", "http/1.1"])
        if version:
            context.minimum_version = context.maximum_version = version
        return context

    def client(self, ca="inspection-ca.pem", version=None):
        context = ssl.create_default_context(cafile=self.path(ca))
        context.set_alpn_protocols(["h2", "http/1.1"])
        if version:
            context.minimum_version = context.maximum_version = version
        return context


def tls_origin(certificates, callback, name="server", version=None):
    context = certificates.server(name, version)

    def handle(connection):
        try:
            with context.wrap_socket(connection, server_side=True) as encrypted:
                callback(encrypted)
        except (ssl.SSLError, EOFError):
            pass  # Verification-failure fixtures intentionally terminate the upstream handshake.

    return origin(handle)


def connect(proxy, port, host="127.0.0.1"):
    connection = proxy.socket()
    authority = f"{host}:{port}".encode()
    connection.sendall(b"CONNECT " + authority + b" HTTP/1.1\r\nHost: " + authority + b"\r\n\r\n")
    return connection, read_headers(connection)


@unittest.skipUnless(shutil.which("openssl"), "OpenSSL fixture generator is required")
class TLSIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificates = Certificates()

    @classmethod
    def tearDownClass(cls):
        cls.certificates.temporary.cleanup()

    def exchange(self, version=None, body=b"decrypted and inspected", request_host=None):
        observed = queue.Queue()

        def reply(connection):
            observed.put((read_headers(connection), connection.selected_alpn_protocol()))
            respond(connection, body)

        with tls_origin(self.certificates, reply, version=version) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port)
            self.assertIn(b"200 Connection Established", response)
            with self.certificates.client(version=version).wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                self.assertEqual(connection.selected_alpn_protocol(), "http/1.1")
                connection.sendall(f"GET /secret?token=hidden HTTP/1.1\r\nHost: {request_host or f'127.0.0.1:{port}'}\r\nAuthorization: Bearer hidden\r\n\r\n".encode())
                result = read_all(connection)
            flow = proxy.event()
        return result, flow, observed

    def test_tls12_and_tls13_inspect_inner_exchange(self):
        versions = [ssl.TLSVersion.TLSv1_2]
        if ssl.HAS_TLSv1_3:
            versions.append(ssl.TLSVersion.TLSv1_3)
        for version in versions:
            with self.subTest(version=version):
                result, flow, observed = self.exchange(version)
                self.assertTrue(result.endswith(b"decrypted and inspected"))
                self.assertTrue(flow["tls_inspected"])
                self.assertFalse(flow["tunnel"])
                self.assertEqual((flow["method"], flow["status"], flow["result"]), ("GET", 200, "complete"))
                self.assertNotIn("hidden", str(flow))
                self.assertIn("TLSv1.", flow["tls_version"])
                headers, alpn = observed.get(timeout=2)
                self.assertIn(b"GET /secret?token=hidden HTTP/1.1", headers)
                self.assertEqual(alpn, "http/1.1")

    def test_large_body_and_slow_reader_remain_bounded(self):
        body = b"encrypted-stream-" * (1024 * 512)

        def reply(connection):
            connection.settimeout(30)  # Bulk crypto under Linux ASan is substantially slower than control exchanges.
            read_headers(connection)
            respond(connection, body)

        with tls_origin(self.certificates, reply) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port)
            self.assertIn(b"200", response)
            with self.certificates.client().wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                connection.settimeout(30)
                connection.sendall(f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
                time.sleep(0.15)
                result = read_all(connection)
            flow = proxy.event()
            received = result.split(b"\r\n\r\n", 1)[1]
            self.assertEqual(len(received), len(body), flow)
            self.assertEqual(received, body)
            self.assertLessEqual(flow["peak_pending_bytes"], 2 * (262144 + 65536))

    def test_upstream_wrong_root_name_and_expiry_fail_before_connect_success(self):
        for certificate, trust in [("server", "inspection-ca.pem"), ("wrong", "origin-ca.pem"), ("expired", "origin-ca.pem")]:
            with self.subTest(certificate=certificate, trust=trust):
                with tls_origin(self.certificates, lambda c: None, name=certificate) as port, Proxy(*self.certificates.options(trust)) as proxy:
                    connection, response = connect(proxy, port)
                    with connection:
                        self.assertIn(b"502", response)
                        self.assertEqual(read_all(connection), b"")
                    self.assertEqual(proxy.event()["result"], "upstream_tls_error")

    def test_inner_authority_cannot_escape_connect_scope(self):
        result, flow, observed = self.exchange(request_host="different.invalid")
        self.assertIn(b"400", result)
        self.assertEqual(flow["result"], "unsupported_target")
        self.assertTrue(observed.empty())

    def test_upload_streams_and_interim_response_crosses_both_tls_legs(self):
        observed = queue.Queue()

        def reply(connection):
            headers = read_headers(connection)
            self.assertIn(b"Content-Length: 6", headers)
            observed.put(connection.recv(3))
            connection.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
            observed.put(connection.recv(3))
            respond(connection)

        with tls_origin(self.certificates, reply) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port)
            self.assertIn(b"200", response)
            with self.certificates.client().wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                connection.sendall(f"POST / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Length: 6\r\n\r\nabc".encode())
                self.assertEqual(observed.get(timeout=3), b"abc")
                self.assertIn(b"100 Continue", read_headers(connection))
                connection.sendall(b"def")
                self.assertTrue(read_all(connection).endswith(b"hello"))
                self.assertEqual(observed.get(timeout=3), b"def")
            self.assertEqual(proxy.event()["result"], "complete")

    def test_close_delimited_response_requires_authenticated_tls_shutdown(self):
        for authenticated in [False, True]:
            with self.subTest(authenticated=authenticated):
                def reply(connection):
                    read_headers(connection)
                    connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nbody")
                    if authenticated:
                        connection.unwrap().close()
                    else:
                        socket.socket(fileno=connection.detach()).close()

                with tls_origin(self.certificates, reply) as port, Proxy(*self.certificates.options()) as proxy:
                    plain, response = connect(proxy, port)
                    self.assertIn(b"200", response)
                    with self.certificates.client().wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                        connection.sendall(f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
                        self.assertTrue(read_all(connection).endswith(b"body"))
                    self.assertEqual(proxy.event()["result"], "complete" if authenticated else "truncated_tls")

    def test_http2_only_alpn_fails_explicitly(self):
        with tls_origin(self.certificates, read_headers) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port)
            self.assertIn(b"200", response)
            client = self.certificates.client()
            client.set_alpn_protocols(["h2"])
            with self.assertRaises((ssl.SSLError, ConnectionError)):
                with client.wrap_socket(plain, server_hostname="127.0.0.1"):
                    pass
            self.assertEqual(proxy.event()["result"], "client_tls_error")

    @unittest.skipUnless(ssl.HAS_TLSv1_3, "Requires TLS 1.3 post-handshake tickets")
    def test_tls13_tickets_are_drained_before_a_later_request(self):
        def reply(connection):
            read_headers(connection)
            respond(connection)

        with tls_origin(self.certificates, reply, version=ssl.TLSVersion.TLSv1_3) as port, Proxy(*self.certificates.options()) as proxy:
            for _ in range(8):
                plain, response = connect(proxy, port)
                self.assertIn(b"200", response)
                with self.certificates.client().wrap_socket(plain, server_hostname="127.0.0.1") as connection:
                    # Let both upstream tickets arrive before sending HTTP. No later upstream
                    # packet can wake a TLS adapter that abandoned a buffered ticket on WANT_READ.
                    time.sleep(0.03)
                    connection.sendall(f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
                    self.assertTrue(read_all(connection).endswith(b"hello"))
                self.assertEqual(proxy.event()["result"], "complete")

    def test_sni_must_match_connect_scope(self):
        with tls_origin(self.certificates, read_headers) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port)
            self.assertIn(b"200", response)
            with self.assertRaises((ssl.SSLError, ConnectionError)):
                with self.certificates.client().wrap_socket(plain, server_hostname="wrong.invalid"):
                    pass
            self.assertEqual(proxy.event()["result"], "client_tls_error")

    def test_unselected_host_is_opaque_tunnel(self):
        def reply(connection):
            read_headers(connection)
            respond(connection)

        with tls_origin(self.certificates, reply) as port, Proxy(*self.certificates.options()) as proxy:
            plain, response = connect(proxy, port, "localhost")
            self.assertIn(b"200", response)
            with self.certificates.client("origin-ca.pem").wrap_socket(plain, server_hostname="localhost") as connection:
                connection.sendall(f"GET / HTTP/1.1\r\nHost: localhost:{port}\r\n\r\n".encode())
                self.assertTrue(read_all(connection).endswith(b"hello"))
            flow = proxy.event()
            self.assertTrue(flow["tunnel"])
            self.assertFalse(flow["tls_inspected"])
            self.assertEqual(flow["method"], "CONNECT")

    def test_ca_keys_multi_host_and_wrong_leaf_keys_are_rejected(self):
        for certificate, key in [("inspection-ca.pem", "inspection-ca.key"), ("server.pem", "server.key"),
                                 ("leaf.pem", "server.key"), ("long-lived.pem", "long-lived.key"), ("expired.pem", "expired.key")]:
            with self.subTest(certificate=certificate, key=key):
                result = subprocess.run([BINARY, "--upstream-ca", self.certificates.path("origin-ca.pem"),
                                         "--tls-identity", "127.0.0.1", self.certificates.path(certificate), self.certificates.path(key)],
                                        capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"invalid TLS policy", result.stderr)
                self.assertEqual(result.stdout, b"")


if __name__ == "__main__":
    unittest.main()
