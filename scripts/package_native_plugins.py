#!/usr/bin/env python3
"""Package first-party native plugins for one exact Threading release build.

The signed manifest is an envelope: its payload is base64-encoded JSON bytes, and the
Ed25519 signature covers those bytes exactly. A reader must verify the signature before
decoding the payload or trusting any URL or digest in it.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


TEAM_ID = "SMQ3E8Y57T"
SCHEMA_VERSION = 1
MAXIMUM_PLUGINS = 32


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(*args: str) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def host_identity(app: Path) -> dict[str, str]:
    info = read_plist(app / "Contents/Info.plist")
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    design_kit = app / "Contents/Frameworks/ThreadingDesignKit.framework/Versions/A/ThreadingDesignKit"
    plugin_kit = app / "Contents/Frameworks/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit"
    if not design_kit.is_file() or not plugin_kit.is_file():
        raise ValueError("the exported app lacks its shared native plugin frameworks")
    return {
        "bundleIdentifier": info["CFBundleIdentifier"],
        "bundleVersion": info["CFBundleVersion"],
        "buildChannel": info["ThreadingBuildChannel"],
        "executableSHA256": sha256(executable),
        "designKitSHA256": sha256(design_kit),
        "pluginKitSHA256": sha256(plugin_kit),
    }


def plugin_bundles(directory: Path) -> list[Path]:
    bundles = sorted(directory.glob("*.bundle")) if directory.is_dir() else []
    if not bundles or len(bundles) > MAXIMUM_PLUGINS:
        raise ValueError("expected 1–32 first-party native plugin bundles in the export")
    return bundles


def verify_signed_bundle(bundle: Path) -> tuple[str, str]:
    info = read_plist(bundle / "Contents/Info.plist")
    identifier = info["CFBundleIdentifier"]
    run("codesign", "--verify", "--deep", "--strict", str(bundle))
    details = subprocess.run(
        ("codesign", "-dvvv", str(bundle)),
        check=True,
        capture_output=True,
        text=True,
    ).stderr
    if f"TeamIdentifier={TEAM_ID}" not in details:
        raise ValueError(f"{identifier} is not signed by Threading's team")
    if "Authority=Developer ID Application" not in details:
        raise ValueError(f"{identifier} is not Developer ID signed")
    if "Timestamp=" not in details or "flags=" not in details or "runtime" not in details:
        raise ValueError(f"{identifier} lacks a secure timestamp or hardened runtime")
    cd_hash = next((line.removeprefix("CDHash=") for line in details.splitlines()
                    if line.startswith("CDHash=")), "")
    if len(cd_hash) != 40 or any(c not in "0123456789abcdef" for c in cd_hash):
        raise ValueError(f"{identifier} has no SHA-256 code directory hash")
    return identifier, cd_hash


def archive_plugin(bundle: Path, destination: Path, notarize: bool, profile: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    run("ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", str(bundle), str(destination))
    if notarize:
        helper = Path(__file__).with_name("local_release_credentials.py")
        run(sys.executable, str(helper), "submit", str(destination), "--profile", profile)
        run("xcrun", "stapler", "staple", str(bundle))
        run("xcrun", "stapler", "validate", str(bundle))
        destination.unlink()
        run("ditto", "-c", "-k", "--keepParent", "--sequesterRsrc", str(bundle), str(destination))


def manifest_payload(app: Path, archives: list[dict], release_tag: str) -> bytes:
    host = host_identity(app)
    channel = host["buildChannel"]
    version = host["bundleVersion"]
    expected_tag = {
        "release": f"v{version}",
        "beta": f"beta-v{version}",
        "nightly": "nightly",
    }.get(channel)
    if not version or any(part == "" or not part.isdigit() for part in version.split(".")) \
            or release_tag != expected_tag:
        raise ValueError("release tag does not match the exported host build")
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "host": host,
        "releaseTag": release_tag,
        "plugins": archives,
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sign(payload_file: Path, sparkle_bin: Path, account: str, app: Path) -> str:
    signer = sparkle_bin / "sign_update"
    private_key_file = os.environ.get("THREADING_SPARKLE_PRIVATE_KEY_FILE")
    arguments = [str(signer), "-p"]
    if private_key_file:
        arguments.extend(("--ed-key-file", private_key_file))
    else:
        shipped_key = read_plist(app / "Contents/Info.plist")["SUPublicEDKey"]
        signing_key = run(str(sparkle_bin / "generate_keys"), "-p", "--account", account)
        if signing_key != shipped_key:
            raise ValueError("the signing key does not match the app's SUPublicEDKey")
        arguments.extend(("--account", account))
    arguments.append(str(payload_file))
    signature = run(*arguments)
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("the signer returned a non-Ed25519 signature")
    except ValueError as error:
        raise ValueError("the signer returned an invalid base64 signature") from error
    run(str(signer), "--verify", *(arguments[2:-1]), str(payload_file), signature)
    shipped_key = read_plist(app / "Contents/Info.plist")["SUPublicEDKey"]
    run("swift", str(Path(__file__).with_name("verify_ed25519_signature.swift")),
        shipped_key, str(payload_file), signature)
    return signature


def package(args: argparse.Namespace) -> Path:
    app = args.app.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    version = host_identity(app)["bundleVersion"]
    prefix = f"https://github.com/{args.repository}/releases/download/{quote(args.release_tag, safe='')}/"

    records = []
    seen_identifiers = set()
    plugin_source = (args.plugin_source or app / "Contents/PlugIns").resolve()
    for source in plugin_bundles(plugin_source):
        staged = output / "staging" / source.name
        staged.parent.mkdir(parents=True, exist_ok=True)
        if staged.exists():
            shutil.rmtree(staged)
        shutil.copytree(source, staged, symlinks=True)
        identifier, cd_hash = verify_signed_bundle(staged)
        if identifier in seen_identifiers:
            raise ValueError(f"duplicate plugin identifier: {identifier}")
        seen_identifiers.add(identifier)
        archive = output / f"{source.stem}-{version}.zip"
        archive_plugin(staged, archive, args.notarize, args.notary_profile)
        records.append({
            "bundleIdentifier": identifier,
            "codeDirectoryHash": cd_hash,
            "archiveURL": prefix + quote(archive.name),
            "archiveSHA256": sha256(archive),
            "archiveBytes": archive.stat().st_size,
            "bundleName": source.name,
        })

    payload = manifest_payload(app, records, args.release_tag)
    payload_file = output / f"native-plugins-{version}.payload.json"
    payload_file.write_bytes(payload)
    signature = sign(payload_file, args.sparkle_bin, args.signing_account, app)
    envelope = {
        "payload": base64.b64encode(payload).decode("ascii"),
        "signature": signature,
    }
    manifest = output / f"native-plugins-{version}.json"
    manifest.write_text(json.dumps(envelope, sort_keys=True, indent=2) + "\n")
    payload_file.unlink()
    shutil.rmtree(output / "staging")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--plugin-source", type=Path,
                        help="Developer ID signed bundles staged before pruning the release app")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--repository", default="everlof/threading")
    parser.add_argument("--sparkle-bin", required=True, type=Path)
    parser.add_argument("--signing-account", default="mjukis-threading")
    parser.add_argument("--notarize", action="store_true")
    parser.add_argument("--notary-profile", default="mjukis-notary")
    args = parser.parse_args()
    try:
        print(package(args))
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"native plugin package failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
