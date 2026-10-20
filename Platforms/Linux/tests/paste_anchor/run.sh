#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp /tmp/threading-paste-anchor.XXXXXX)
trap 'rm -f "$binary"' EXIT
swiftc Sources/WindowHarness/ComposerPasteAnchor.swift tests/paste_anchor/Fixture.swift -o "$binary"
"$binary"
