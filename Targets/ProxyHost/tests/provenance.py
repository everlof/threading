#!/usr/bin/env python3
"""Offline verification of retained archives and unmodified upstream license notices."""
import hashlib
import json
from pathlib import Path
import re
import tarfile


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "third_party"


def source_notices(archive, root, all_sources=False):
    groups = {}
    for member in sorted(archive.getmembers(), key=lambda item: item.name):
        relative = member.name.removeprefix(root + "/")
        if not member.isfile() or (not all_sources and not relative.startswith(("src/", "include/"))) or not relative.endswith((".c", ".h", ".S")):
            continue
        text = archive.extractfile(member).read().decode("utf-8", errors="replace")
        match = re.match(r"\s*(/\*.*?\*/)", text, re.DOTALL)
        if match and re.search(r"copyright|license|public domain", match[1], re.IGNORECASE):
            groups.setdefault(match[1], []).append(relative)
    return "\n\n".join("Sources: " + ", ".join(paths) + "\n\n" + notice for notice, paths in groups.items()) + "\n"


def verify():
    manifest = json.loads((VENDOR / "manifest.json").read_text())
    cmake = (ROOT / "CMakeLists.txt").read_text()
    for entry in manifest["dependencies"]:
        path = VENDOR / entry["archive"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"], path
        if "source only" not in entry["name"]:
            assert entry["sha256"] in cmake, "Build and provenance pins have diverged"
        with tarfile.open(path) as archive:
            for source, destination in entry["notices"].items():
                expected = archive.extractfile(entry["root"] + "/" + source).read()
                assert expected == (VENDOR / "licenses" / destination).read_bytes(), destination
            if entry["name"] == "libuv":
                actual = (VENDOR / "licenses" / "libuv-SOURCE-NOTICES.txt").read_text()
                assert actual == source_notices(archive, entry["root"]), "libuv file-level notices changed"
            if entry["name"] == "Mbed TLS and TF-PSA-Crypto":
                actual = (VENDOR / "licenses" / "mbedtls-SOURCE-NOTICES.txt").read_text()
                assert actual == source_notices(archive, entry["root"], all_sources=True), "Mbed TLS file-level notices changed"
    assert (ROOT / "LICENSE").read_text().startswith("                    GNU GENERAL PUBLIC LICENSE")
    print(f"Verified {len(manifest['dependencies'])} source archives, build pins, upstream licenses and file-level notices")


if __name__ == "__main__":
    verify()
