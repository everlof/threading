#!/usr/bin/env python3
"""How much of Threading's non-UI code could compile without Apple's frameworks.

This is the draft's delivery slice 2 — "make the product layers compilable" — asked as a number
instead of a plan. It is deliberately an *import* analysis, not a build: it says what a file
reaches for, which is the ceiling on portability, never the proof. A file importing only
Foundation can still be unportable — a Darwin-only API reached through a typealias, a path
assumption, a `Process` launch of a macOS binary. Treat every count here as an upper bound.

    ./headless.py [repo-root]
"""
import pathlib
import re
import sys
from collections import Counter

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
LAYERS = ["Sources/Threading/Core", "Sources/Threading/Models", "Sources/Threading/Application"]

# Available on Linux today, either in the toolchain or as a system library we already depend on.
PORTABLE = {
    "Foundation": "toolchain",
    "Dispatch": "toolchain",
    "Swift": "toolchain",
    "SQLite3": "system libsqlite3",
    "Compression": "zlib / liblzma",
    # Ours, and already Foundation-only by their own boundary checks.
    "ThreadingDomain": "ours",
    "ThreadingRemoteKit": "ours",
    "ThreadingPTYHostKit": "ours",
    "ThreadingExtensionKit": "ours",
    "ThreadingPeerTransport": "ours",
    "ThreadingSimulatorKit": "ours",
    "NativeDiffCore": "ours",
}

# A real Linux equivalent exists, but it is a port, not a recompile.
SUBSTITUTABLE = {
    "CryptoKit": "swift-crypto, same API",
    "os": "swift-log",
    "OSLog": "swift-log",
    "Network": "SwiftNIO or POSIX sockets",
    "Darwin": "Glibc",
    "ObjectiveC": "delete",
    "CoreGraphics": "the spike's own geometry, or Cairo/Skia",
    "CoreText": "HarfBuzz + FreeType",
    "ImageIO": "libpng / libjpeg",
    "UniformTypeIdentifiers": "shared-mime-info",
}

# No Linux story without a product decision about what the feature becomes.
BLOCKING = {
    "AppKit": "the UI question",
    "Security": "Keychain — libsecret, or a different credential story",
    "IOKit": "device identity",
    "ServiceManagement": "launchd — systemd user units",
    "UserNotifications": "libnotify / D-Bus",
    "SystemConfiguration": "NetworkManager / D-Bus",
    "AuthenticationServices": "a browser handoff",
    "Sparkle": "updates",
    "AVFoundation": "GStreamer / ffmpeg",
    "VideoToolbox": "ffmpeg",
    "CoreVideo": "ffmpeg",
    "CoreMedia": "ffmpeg",
    "CoreImage": "an image pipeline",
    "PDFKit": "poppler / MuPDF",
    "SwiftTerm": "ours, but its AppKit half is the UI question",
}

IMPORT = re.compile(r"^\s*(?:@[A-Za-z_]+\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)


def main() -> None:
    files = []
    for layer in LAYERS:
        directory = ROOT / layer
        if directory.is_dir():
            files.extend(sorted(directory.rglob("*.swift")))
    if not files:
        print(f"no Swift files under {ROOT}", file=sys.stderr)
        raise SystemExit(1)

    clean, ported, blocked = [], [], []
    blockers: Counter = Counter()
    substitutions: Counter = Counter()

    for path in files:
        imports = set(IMPORT.findall(path.read_text(encoding="utf-8", errors="replace")))
        hard = {name for name in imports if name in BLOCKING}
        soft = {name for name in imports if name in SUBSTITUTABLE}
        unknown = {
            name for name in imports
            if name not in PORTABLE and name not in SUBSTITUTABLE and name not in BLOCKING
        }
        for name in hard:
            blockers[name] += 1
        for name in unknown:
            blockers[f"{name} (unclassified)"] += 1
        for name in soft:
            substitutions[name] += 1

        if hard or unknown:
            blocked.append(path)
        elif soft:
            ported.append(path)
        else:
            clean.append(path)

    total = len(files)
    print(f"{total} files in Core, Models and Application\n")
    print(f"  {len(clean):4d}  ({len(clean) * 100 // total:2d}%)  import only what Linux already has")
    print(f"  {len(ported):4d}  ({len(ported) * 100 // total:2d}%)  also need a known substitution")
    print(f"  {len(blocked):4d}  ({len(blocked) * 100 // total:2d}%)  reach something with no Linux story yet")
    print()
    print("substitutions, by files needing them:")
    for name, count in substitutions.most_common():
        print(f"  {count:4d}  {name:26s} {SUBSTITUTABLE[name]}")
    print()
    print("blockers, by files needing them:")
    for name, count in blockers.most_common():
        print(f"  {count:4d}  {name:26s} {BLOCKING.get(name, 'unclassified — look at it')}")
    print()
    print("NOTE: an upper bound. Imports say what a file reaches for, never that it compiles.")


if __name__ == "__main__":
    main()
