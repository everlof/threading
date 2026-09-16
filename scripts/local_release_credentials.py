#!/usr/bin/env python3
"""Configure or recover this Mac's notarization profile from an ignored local backup."""

import argparse
import getpass
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CREDENTIALS = ROOT / ".release-local" / "credentials.json"
TEAM_ID = "SMQ3E8Y57T"


def keychain_arguments():
    if configured := os.environ.get("NOTARY_KEYCHAIN"):
        return ["--keychain", configured]
    if CREDENTIALS.is_file():
        # The default Local Items store can refuse unattended access even while the login
        # keychain is unlocked. Local backups consistently use the file-based login keychain.
        return ["--keychain", str(Path.home() / "Library/Keychains/login.keychain-db")]
    return []  # CI can keep its already-provisioned default profile.


def store_profile(values):
    # Capture output: neither credentials nor a subprocess command belong in release logs.
    result = subprocess.run(
        ["xcrun", "notarytool", "store-credentials", values["profile"],
         "--apple-id", values["apple_id"], "--team-id", values["team_id"],
         "--password", values["app_specific_password"], *keychain_arguments()],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError("Apple could not validate/store the notarization credentials; local backup was not changed.")


def save_backup(values, path=CREDENTIALS):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise ValueError("The local credential directory and file must not be symbolic links.")
    path.parent.chmod(0o700)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".credentials-")
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(values, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_backup(profile, path=CREDENTIALS):
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("The local credential directory and file must not be symbolic links.")
    if path.stat().st_mode & 0o077:
        raise ValueError("Local credentials must be owner-only; run chmod 600 .release-local/credentials.json.")
    values = json.loads(path.read_text())
    required = ("profile", "apple_id", "team_id", "app_specific_password")
    if not isinstance(values, dict) or not all(
        isinstance(values.get(key), str) and values[key].strip() for key in required
    ):
        raise ValueError("The local credential file is incomplete; rerun setup.")
    if values["profile"] != profile or values["team_id"] != TEAM_ID:
        raise ValueError("The local credentials do not match the requested profile and release team.")
    return values


def ensure_profile(profile, path=CREDENTIALS):
    result = subprocess.run(
        ["xcrun", "notarytool", "history", "--keychain-profile", profile, *keychain_arguments()],
        stdin=subprocess.DEVNULL, capture_output=True, check=False,
    )
    if result.returncode == 0:
        return
    store_profile(load_backup(profile, path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("setup", "ensure", "submit"))
    parser.add_argument("archive", nargs="?")
    parser.add_argument("--profile", default=os.environ.get("NOTARY_PROFILE", "mjukis-notary"))
    args = parser.parse_args()
    try:
        if args.action == "setup":
            os.environ.setdefault("NOTARY_KEYCHAIN", str(Path.home() / "Library/Keychains/login.keychain-db"))
            values = {
                "profile": args.profile,
                "team_id": TEAM_ID,
                "apple_id": input("Apple ID email: ").strip(),
                "app_specific_password": getpass.getpass("App-specific password: ").strip(),
            }
            if not values["apple_id"] or not values["app_specific_password"]:
                raise ValueError("Apple ID and app-specific password are required.")
            store_profile(values)
            save_backup(values)
            print("Notarization profile validated and stored. Local backup saved with mode 600.")
        elif args.action == "ensure":
            ensure_profile(args.profile)
        else:
            if not args.archive:
                parser.error("submit requires an archive path")
            return subprocess.run(
                ["xcrun", "notarytool", "submit", args.archive, "--keychain-profile", args.profile,
                 *keychain_arguments(), "--wait"],
                stdin=subprocess.DEVNULL, check=False,
            ).returncode
    except (OSError, ValueError):
        # Do not echo exception details: malformed JSON or OS errors can contain private values.
        print("Notarization credentials unavailable or invalid. Run: python3 scripts/local_release_credentials.py setup")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
