#!/usr/bin/env python3
"""Release gate for the exact Linux components pinned in the compiled Swift manifest."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import posixpath
import re
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path("Sources/Threading/Core/RemoteHost/RemoteHostComponentManifest.swift")
# Package dependencies and test symlink destinations are discovered below, at BOTH revisions.
INPUTS = (
    "Targets/PTYHost",
    "Targets/MCPBridge",
    "scripts/test-ptyd-linux.sh",
    "scripts/linux",
    "scripts/publish_remote_components.sh",
    "scripts/check_remote_components.py",
)
MAX_ASSET_BYTES = 64 * 1024 * 1024
MAX_BINARY_BYTES = 256 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
REPAIR = "Run scripts/publish_remote_components.sh, then commit the regenerated manifest before tagging the app."


class ComponentError(Exception):
    pass


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments], capture_output=True, check=False
    )
    if result.returncode:
        raise ComponentError(result.stderr.decode().strip())
    return result.stdout.decode()


def revision(root: Path, ref: str) -> str:
    try:
        return git(root, "rev-parse", "--verify", f"{ref}^{{commit}}").strip()
    except ComponentError as error:
        raise ComponentError(f"cannot resolve {ref}; fetch the component history first: {error}") from error


def repository_path(parent: str, relative: str) -> str:
    path = posixpath.normpath(posixpath.join(parent, relative))
    if path == ".." or path.startswith("../") or path.startswith("/"):
        raise ComponentError(f"component input escapes the repository: {path}")
    return path


def input_entries(root: Path, commit: str) -> dict[str, tuple[str, str]]:
    """Git modes/blob IDs include additions, removals, recipes, toolchains and shared tests."""
    entries: dict[str, tuple[str, str]] = {}
    pending = list(INPUTS)
    visited: set[str] = set()
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        listing = git(root, "ls-tree", "-rz", commit, "--", path)
        for record in listing.split("\0"):
            if not record:
                continue
            metadata, name = record.split("\t", 1)
            mode, kind, blob = metadata.split()
            if kind != "blob":
                raise ComponentError(f"unsupported component input {name}: {kind}")
            entries[name] = (mode, blob)
            if mode == "120000":
                destination = git(root, "show", f"{commit}:{name}")
                destination_path = repository_path(posixpath.dirname(name), destination)
                git(root, "cat-file", "-e", f"{commit}:{destination_path}")
                pending.append(destination_path)
            elif name.endswith("/Package.swift"):
                source = git(root, "show", f"{commit}:{name}")
                dependencies = re.findall(r'\.package\s*\(\s*path:\s*"([^"]+)"\s*\)', source)
                if len(dependencies) != len(re.findall(r"\.package\s*\(", source)):
                    raise ComponentError(
                        f"{name} has a dependency this gate cannot inventory; extend the gate first"
                    )
                for dependency in dependencies:
                    dependency_path = repository_path(posixpath.dirname(name), dependency)
                    # Missing local packages must not silently vanish from the input inventory.
                    git(root, "cat-file", "-e", f"{commit}:{dependency_path}/Package.swift")
                    pending.append(dependency_path)
    return entries


def assert_clean_inputs(root: Path, commit: str) -> None:
    entries = input_entries(root, commit)
    # Include package directories, not just their existing files: new sources matter too.
    packages = [str(Path(name).parent) for name in entries if name.endswith("/Package.swift")]
    paths = sorted(set(INPUTS) | set(entries) | set(packages))
    changed = git(root, "diff", "--name-only", commit, "--", *paths).splitlines()
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "--", *paths).splitlines()
    if changed or untracked:
        raise ComponentError(
            "component inputs differ from the committed sources; commit them first:\n  "
            + "\n  ".join(sorted(set(changed + untracked)))
        )


def assert_snapshot(root: Path, expected: str) -> None:
    if revision(root, "HEAD") != expected:
        raise ComponentError("HEAD moved while preparing remote components; rerun from a stable checkout")
    assert_clean_inputs(root, expected)


def assert_committed_manifest(root: Path, head: str) -> None:
    if (root / MANIFEST).read_text() != git(root, "show", f"{head}:{MANIFEST.as_posix()}"):
        raise ComponentError("the component manifest differs from HEAD; commit the regenerated manifest first")


@dataclass(frozen=True)
class Component:
    kind: str
    architecture: str
    asset: str
    asset_hash: str
    asset_size: int
    binary_hash: str


@dataclass(frozen=True)
class Manifest:
    tag: str
    base_url: str
    components: tuple[Component, ...]


def read_manifest(path: Path, repository: str) -> Manifest:
    source = path.read_text()

    def string(name: str) -> str:
        values = re.findall(rf'\bstatic let {name} = "([^"]*)"', source)
        if len(values) != 1:
            raise ComponentError(f"manifest must declare exactly one {name}")
        return values[0]

    tag = string("release")
    if not re.fullmatch(r"remote-components-[0-9a-f]{12,40}", tag):
        raise ComponentError("manifest has no valid immutable component release")
    base_url = string("baseURL")
    if base_url != f"https://github.com/{repository}/releases/download/":
        raise ComponentError(f"manifest does not download from the expected repository {repository}")
    rows = re.findall(
        r'RemoteHostComponent\(\s*kind: \.(\w+),\s*architecture: \.(\w+),\s*'
        r'assetName: "([^"]+)",\s*assetSHA256: "([0-9a-f]{64})",\s*'
        r'assetByteCount: (\d+),\s*sha256: "([0-9a-f]{64})"\s*\)', source
    )
    components = tuple(Component(k, a, n, h, int(s), b) for k, a, n, h, s, b in rows)
    expected = {(kind, arch) for kind in ("daemon", "bridge") for arch in ("arm64", "amd64")}
    if (len(components) != 4 or source.count("RemoteHostComponent(") != 4
            or {(c.kind, c.architecture) for c in components} != expected):
        raise ComponentError("manifest must pin exactly one daemon and bridge for each Linux architecture")
    for component in components:
        executable = "threading-ptyd" if component.kind == "daemon" else "threading-mcp-bridge"
        if component.asset != f"{executable}-{component.architecture}.gz":
            raise ComponentError(f"unexpected component asset name: {component.asset}")
        if not 0 < component.asset_size <= MAX_ASSET_BYTES:
            raise ComponentError(f"invalid download size for {component.asset}")
    return Manifest(tag, base_url, components)


def check_sources(root: Path, manifest: Manifest) -> str:
    head = revision(root, "HEAD")
    assert_clean_inputs(root, head)
    pinned = revision(root, manifest.tag.removeprefix("remote-components-"))
    previous = input_entries(root, pinned)
    current = input_entries(root, head)
    changed = sorted(path for path in previous.keys() | current.keys()
                     if previous.get(path) != current.get(path))
    if changed:
        raise ComponentError(
            f"{manifest.tag} is stale; component inputs changed:\n  " + "\n  ".join(changed)
        )
    return head


def verify_asset(component: Component, path: Path) -> None:
    if path.stat().st_size != component.asset_size:
        raise ComponentError(f"{component.asset}: download size does not match the compiled manifest")
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(CHUNK_BYTES), b""):
            digest.update(chunk)
    if digest.hexdigest() != component.asset_hash:
        raise ComponentError(f"{component.asset}: compressed SHA-256 does not match the compiled manifest")
    digest = hashlib.sha256()
    count = 0
    with gzip.open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK_BYTES), b""):
            count += len(chunk)
            if count > MAX_BINARY_BYTES:
                raise ComponentError(f"{component.asset}: decompressed binary exceeds the size limit")
            digest.update(chunk)
    if digest.hexdigest() != component.binary_hash:
        raise ComponentError(f"{component.asset}: binary SHA-256 does not match the compiled manifest")


def check_downloads(manifest: Manifest) -> None:
    # Fetch the same public URLs the app uses; authenticated API access can hide a draft/private
    # release that users cannot download. Never trust GitHub's asset metadata in place of bytes.
    with tempfile.TemporaryDirectory(prefix="threading-components-") as scratch:
        for component in manifest.components:
            url = manifest.base_url + manifest.tag + "/" + component.asset
            destination = Path(scratch) / component.asset
            with urllib.request.urlopen(url, timeout=30) as response, destination.open("wb") as output:
                count = 0
                while chunk := response.read(CHUNK_BYTES):
                    count += len(chunk)
                    if count > component.asset_size:
                        raise ComponentError(f"{component.asset}: download exceeds the manifest size")
                    output.write(chunk)
            verify_asset(component, destination)
            print(f"  verified {component.asset}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--repository", default=os.environ.get("THREADING_REPO", "everlof/threading"))
    parser.add_argument("--local", action="store_true", help="only check source freshness (no network)")
    parser.add_argument("--source-revision", action="store_true", help="check inputs and print HEAD for publishing")
    parser.add_argument("--assert-snapshot", metavar="COMMIT", help="refuse changed inputs or HEAD after a build")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
            raise ComponentError("invalid GitHub repository name")
        if args.source_revision:
            head = revision(args.root, "HEAD")
            assert_clean_inputs(args.root, head)
            print(head)
        elif args.assert_snapshot:
            assert_snapshot(args.root, args.assert_snapshot)
        else:
            manifest = read_manifest(args.manifest or args.root / MANIFEST, args.repository)
            head = check_sources(args.root, manifest)
            if args.manifest is None:
                assert_committed_manifest(args.root, head)
            if not args.local:
                check_downloads(manifest)
            assert_snapshot(args.root, head)
            if args.manifest is None:
                assert_committed_manifest(args.root, head)
            print(f"remote components: {manifest.tag} verified" + (" (sources only)" if args.local else ""))
    except (ComponentError, OSError, EOFError, ValueError) as error:
        print(f"remote components: {error}\n{REPAIR}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
