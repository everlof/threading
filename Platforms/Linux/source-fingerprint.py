#!/usr/bin/env python3
"""Fingerprint tracked and unignored source inputs, including links and submodule revisions."""
import hashlib
import os
from pathlib import Path
import subprocess


def fingerprint(root):
    paths = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root,
    ).split(b"\0")
    digest = hashlib.sha256()
    for relative in sorted(set(paths) - {b""}):
        path = root / os.fsdecode(relative)
        digest.update(relative + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_dir():
            # An uninitialized submodule still has an exact, recorded source revision.
            revision = subprocess.check_output(
                ["git", "ls-files", "--stage", "--", os.fsdecode(relative)], cwd=root)
            digest.update(b"submodule\0" + revision)
        elif not path.exists():
            digest.update(b"deleted")
        else:
            digest.update(b"executable\0" if path.stat().st_mode & 0o111 else b"file\0")
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
        digest.update(b"\0")
    return digest.hexdigest()


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2]
    print(fingerprint(root))
