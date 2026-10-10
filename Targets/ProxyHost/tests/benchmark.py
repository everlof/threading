#!/usr/bin/env python3
"""Opt-in matched direct/proxied loopback measurement; excludes fixture and process startup."""
import argparse
import json
import statistics
import time
import socket
import subprocess
import sys

# integration consumes argv[1] as the exact helper binary; importing it runs no tests.
from integration import BINARY, Proxy, origin, read_all, read_headers, respond


def distribution(samples):
    ordered = sorted(samples)
    return {"median_ms": statistics.median(ordered), "p95_ms": ordered[int((len(ordered) - 1) * 0.95)], "max_ms": max(ordered)}


def rss_kib(process):
    if sys.platform == "win32":
        return None
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(process.pid)], text=True).strip())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--requests", type=int, default=300)
    args = parser.parse_args()
    if not 10 <= args.requests <= 100000:
        parser.error("--requests must be between 10 and 100000")
    results = {"binary": BINARY, "requests_per_route": args.requests, "rounds": []}
    with origin(lambda c: (read_headers(c), respond(c, b"x" * 1024))) as port, Proxy() as proxy:
        def direct():
            with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                assert read_all(connection).endswith(b"x" * 1024)

        def proxied():
            assert proxy.request(port).endswith(b"x" * 1024)

        for _ in range(10):
            direct()
            proxied()
        for iteration in range(3):
            timings = {"direct": [], "proxied": []}
            routes = [("direct", direct), ("proxied", proxied)]
            if iteration % 2:
                routes.reverse()
            for _ in range(args.requests):
                for name, request in routes:
                    started = time.perf_counter()
                    request()
                    timings[name].append((time.perf_counter() - started) * 1000)
            results["rounds"].append({name: distribution(samples) for name, samples in timings.items()})
        peak = 0
        for _ in range(args.requests * 3 + 10):
            peak = max(peak, proxy.event()["peak_pending_bytes"])
        results["peak_pending_bytes"] = peak
    with origin(lambda c: read_all(c)) as port, Proxy() as proxy:
        idle = rss_kib(proxy.process)
        connections = []
        try:
            for _ in range(128):
                connection = proxy.socket()
                connections.append(connection)
                connection.sendall(f"CONNECT 127.0.0.1:{port} HTTP/1.1\r\n\r\n".encode())
                assert b"200 Connection Established" in read_headers(connection)
            results["idle_rss_kib"] = idle
            results["rss_kib_with_128_tunnels"] = rss_kib(proxy.process)
        finally:
            for connection in connections:
                connection.close()
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
