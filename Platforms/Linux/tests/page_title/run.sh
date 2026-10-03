#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out

if [[ "${1:-}" == '--mac' ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'macOS AppKit is required' >&2; exit 1; }
  output="$PWD/out/page-title-mac"
  mkdir -p "$output"
  SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/threading-page-title-swift-cache" \
    CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/threading-page-title-clang-cache" \
    swiftc tests/page_title/*.swift \
      ../../Sources/Threading/UI/Design/PointerTracking.swift \
      -o out/page-title-mac-exe
  out/page-title-mac-exe "$output"
  exit
fi

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product PageTitleHarness
bin=$(swift build --show-bin-path)
timeout 30 "$bin/PageTitleHarness" out/page-title-linux
INNER
for name in wide hover narrow updated branded actions-hidden; do
  test -s "out/page-title-linux/$name.png"
done
