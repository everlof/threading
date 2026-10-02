#!/usr/bin/env bash
# Compare the same fixed stack layout contract with the Linux shim or real macOS AppKit.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if [[ "${1:-}" == "--mac" ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'macOS AppKit is required' >&2; exit 1; }
  mkdir -p out
  SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/threading-stack-swift-cache" \
    CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/threading-stack-clang-cache" \
    swiftc -parse-as-library tests/stack_layout/Fixture.swift -o out/stack-layout-mac
  out/stack-layout-mac
  SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/threading-stack-swift-cache" \
    CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/threading-stack-clang-cache" \
    swiftc -parse-as-library ../../Sources/Threading/UI/Design/ControlRow.swift \
      tests/stack_layout/ControlRowFixture.swift -o out/control-row-mac
  out/control-row-mac
  exit
fi

docker run --rm -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -lc '
  set -euo pipefail
  apt-get update -qq >/dev/null
  apt-get install -y -qq libpango1.0-dev >/dev/null
  swift build --product Harness
  bin="$(swift build --show-bin-path)"
  bridge_map="$bin/AppKitTextBridge.build/module.modulemap"
  swiftc -parse-as-library -swift-version 6 -I "$bin/Modules" \
    -Xcc "-fmodule-map-file=$bridge_map" \
    tests/stack_layout/Fixture.swift "$bin"/AppKit.build/*.o "$bin"/AppKitTextBridge.build/*.o \
    $(pkg-config --libs pangocairo) \
    -o out/stack-layout-linux
  out/stack-layout-linux
  swiftc -parse-as-library -swift-version 6 -I "$bin/Modules" \
    -Xcc "-fmodule-map-file=$bridge_map" \
    /repo/Sources/Threading/UI/Design/ControlRow.swift \
    tests/stack_layout/ControlRowFixture.swift "$bin"/AppKit.build/*.o "$bin"/AppKitTextBridge.build/*.o \
    $(pkg-config --libs pangocairo) \
    -o out/control-row-linux
  out/control-row-linux
'
