#!/usr/bin/env bash
# Keep per-file sweep accounting unchanged; check one real component with its product leaf.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
mkdir -p out
if ! swift build --product Harness >out/glyph-typecheck-build.log 2>&1; then
  cat out/glyph-typecheck-build.log >&2
  exit 1
fi
modules=$(swift build --show-bin-path)/Modules
bridge_map=$(swift build --show-bin-path)/AppKitTextBridge.build/module.modulemap
swiftc -typecheck -swift-version 6 -I "$modules" -Xcc "-fmodule-map-file=$bridge_map" \
  /repo/Platforms/Linux/tests/glyph_view/ShimDependencies.swift \
  /repo/Sources/Threading/UI/Design/TemplateImageDrawing.swift \
  /repo/Sources/Threading/UI/Design/GlyphView.swift
echo 'PASS exact production GlyphView + TemplateImageDrawing typecheck on shim AppKit'
INNER
