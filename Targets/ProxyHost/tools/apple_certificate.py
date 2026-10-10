#!/usr/bin/env python3
"""Prepare/apply explicit Apple trust setup for an MCP-exported public DER certificate.

Default: print a reviewable plan. --apply invokes native tools for this user or one booted
simulator. This development shortcut is not Threading's future UI/permission broker.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def command(target, action, certificate, udid):
    if target == "macos":
        if action == "remove-trust":
            return ["/usr/bin/security", "remove-trusted-cert", str(certificate)]
        return ["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
                "-k", str(Path.home() / "Library/Keychains/login.keychain-db"), str(certificate)]
    if not udid or not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", udid):
        raise ValueError("Simulator setup requires one explicit UDID (not 'booted' or 'all').")
    if action != "install":
        raise ValueError("simctl has no targeted root-removal command. This tool will not reset a simulator keychain.")
    return ["/usr/bin/xcrun", "simctl", "keychain", udid, "add-root-cert", str(certificate)]


def apply(target, action, data, udid):
    if sys.platform != "darwin":
        raise ValueError("Apple trust changes can only run on macOS.")
    if target == "simulator":
        result = subprocess.run(["/usr/bin/xcrun", "simctl", "list", "devices", "--json"],
                                capture_output=True, text=True, check=True, timeout=15)
        devices = [device for runtime in json.loads(result.stdout)["devices"].values() for device in runtime]
        selected = next((d for d in devices if d["udid"].lower() == udid.lower()), None)
        if not selected or not selected.get("isAvailable") or selected.get("state") != "Booted":
            raise ValueError("The selected simulator must exist, be available, and already be booted.")
    # Stage the exact bytes whose fingerprint was checked. Never reopen the source for the mutation.
    with tempfile.TemporaryDirectory(prefix="threading-public-ca-") as directory:
        certificate = Path(directory) / "public-root.cer"
        certificate.write_bytes(data)
        certificate.chmod(0o600)
        subprocess.run(command(target, action, certificate, udid), check=True, timeout=60)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("certificate", type=Path, help="DER .cer exported by traffic_certificate")
    parser.add_argument("--sha256", required=True, help="Expected fingerprint shown by the owning host/MCP")
    parser.add_argument("--target", choices=["macos", "simulator"], required=True)
    parser.add_argument("--udid", help="Exactly one booted simulator's UDID")
    parser.add_argument("--action", choices=["install", "remove-trust"], default="install")
    parser.add_argument("--apply", action="store_true", help="Execute the shown operation; default only prints a plan")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256):
            raise ValueError("Expected SHA-256 must contain exactly 64 hexadecimal digits.")
        with args.certificate.open("rb") as source:
            data = source.read(8193)
        if not data or len(data) > 8192 or data[0] != 0x30:
            raise ValueError("Expected one bounded DER certificate exported by traffic_certificate.")
        digest = hashlib.sha256(data).hexdigest()
        if digest != args.sha256.lower():
            raise ValueError("Certificate fingerprint does not match the owning host.")
        if args.target == "macos" and args.udid:
            raise ValueError("--udid only applies to simulator setup.")
        argv = command(args.target, args.action, args.certificate.resolve(), args.udid)
        print(json.dumps({"target": args.target, "action": args.action, "sha256": digest, "command": argv,
                          "applied": False, "scope": "current user" if args.target == "macos" else args.udid,
                          "note": "Traffic routing is separate. macOS removal removes trust, not the keychain certificate."}))
        if args.apply:
            apply(args.target, args.action, data, args.udid)
            print(json.dumps({"applied": True, "sha256": digest}))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Apple certificate setup: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
