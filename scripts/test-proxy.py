#!/usr/bin/env python3
"""Build and test threading-proxyd on macOS, Linux or Windows with the same entry point."""
import argparse
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    build = (args.build_dir or repository / ".build" / ("proxy-sanitize" if args.sanitize else "proxy")).resolve()
    source = repository / "Targets" / "ProxyHost"
    subprocess.run([
        "cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
        "-DBUILD_TESTING=ON", "-DTHREADING_PROXY_SANITIZERS=" + ("ON" if args.sanitize else "OFF"),
    ], check=True)
    subprocess.run(["cmake", "--build", str(build), "--config", "RelWithDebInfo", "--parallel", "4"], check=True)
    subprocess.run(["ctest", "--test-dir", str(build), "-C", "RelWithDebInfo", "--output-on-failure"], check=True)


if __name__ == "__main__":
    main()
