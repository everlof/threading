#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out

if [[ "${1:-}" == '--mac' ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'macOS AppKit is required' >&2; exit 1; }
  output="$PWD/out/pane-header-mac"
  mkdir -p "$output"
  SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/threading-header-swift-cache" \
    CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/threading-header-clang-cache" \
    swiftc -D THREADING_PANE_HEADER_HARNESS tests/pane_header/*.swift \
      ../../Sources/Threading/UI/Design/PointerTracking.swift \
      -o out/pane-header-mac-exe
  out/pane-header-mac-exe "$output"
  exit
fi

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product PaneHeaderHarness
bin=$(swift build --show-bin-path)
timeout 30 "$bin/PaneHeaderHarness" out/pane-header-linux
INNER
for name in wide narrow resized open disabled; do
  test -s "out/pane-header-linux/$name.png"
done
