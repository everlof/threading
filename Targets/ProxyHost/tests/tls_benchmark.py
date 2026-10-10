#!/usr/bin/env python3
"""Matched fresh TLS connections against a local origin; reports observations, not pass/fail."""
import argparse
import json
import platform
import statistics
import time
import subprocess

from mcp_integration import MCP

from integration import BINARY, Proxy, read_all, read_headers, respond
from tls_integration import Certificates, connect, tls_origin


def summary(samples):
    ordered = sorted(samples)
    return {"requests": len(samples), "median_ms": statistics.median(ordered),
            "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
            "p99_ms": ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--requests", type=int, default=100)
    parser.add_argument("--capture", action="store_true", help="Measure retained headers/bodies through the MCP host path")
    args = parser.parse_args()
    if not 10 <= args.requests <= 10000:
        parser.error("--requests must be 10..10000")
    certificates = Certificates()
    try:
        direct_context = certificates.client("origin-ca.pem")
        proxy_context = certificates.client()
        direct_context.set_alpn_protocols(["http/1.1"])
        proxy_context.set_alpn_protocols(["http/1.1"])

        def reply(connection):
            read_headers(connection)
            respond(connection, b"x" * 1024)

        rounds = []
        with tls_origin(certificates, reply) as port, (MCP if args.capture else Proxy)(*certificates.options()) as proxy:
            import socket
            if args.capture:
                proxy.start()

            def run(inspect):
                samples = []
                for index in range(args.requests):
                    start = time.perf_counter_ns()
                    if inspect:
                        plain, response = connect(proxy, port)
                        if b"200" not in response:
                            raise AssertionError(response)
                    else:
                        plain = socket.create_connection(("127.0.0.1", port), timeout=5)
                    context = proxy_context if inspect else direct_context
                    with context.wrap_socket(plain, server_hostname="127.0.0.1") as encrypted:
                        encrypted.sendall(f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n".encode())
                        result = read_all(encrypted)
                    samples.append((time.perf_counter_ns() - start) / 1_000_000)
                    flow = proxy.event() if inspect and not args.capture else None
                    if not result.endswith(b"x" * 1024):
                        raise AssertionError(f"Incomplete response: inspect={inspect}, index={index}, bytes={len(result)}, prefix={result[:120]!r}, flow={flow}")
                    if flow and flow["result"] != "complete":
                        raise AssertionError(flow)
                return summary(samples)

            for round_number in range(3):
                observation = {}
                for inspect in ([False, True] if round_number % 2 == 0 else [True, False]):
                    observation["inspected" if inspect else "direct"] = run(inspect)
                rounds.append(observation)
            capture_status = proxy.tool("traffic_status") if args.capture else None
            if args.capture:
                assert all(flow["result"] == "complete" for flow in proxy.tool("traffic_list")["flows"])
            rss = subprocess.check_output(["ps", "-o", "rss=", "-p", str(proxy.process.pid)], text=True).strip() if platform.system() != "Windows" else None
        print(json.dumps({"binary": BINARY, "platform": platform.platform(), "payload_bytes": 1024,
                          "capture": args.capture, "capture_status": capture_status, "rss_kib": int(rss) if rss else None,
                          "fresh_connections": True, "concurrency": 1, "rounds": rounds}, indent=2))
    finally:
        certificates.temporary.cleanup()


if __name__ == "__main__":
    main()
