#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# The row's item type currently lives at the start of a much larger card source file. Keep the
# focused fixture's prelude byte-identical so an item-model change cannot silently go untested.
cmp -s tests/subagent_row/SubagentSummaryItem.swift \
  <(sed -n '1,131p' ../../Sources/Threading/UI/Design/SubagentSummaryView.swift) || {
  echo 'SubagentSummaryItem fixture diverged from production source' >&2
  exit 1
}

if [[ "${1:-}" == '--mac' ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'macOS AppKit is required' >&2; exit 1; }
  output="$PWD/out/subagent-row-mac"
  mkdir -p "$output"
  SWIFT_MODULECACHE_PATH="${TMPDIR:-/tmp}/threading-row-swift-cache" \
    CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/threading-row-clang-cache" \
    swiftc tests/subagent_row/*.swift \
      ../../Sources/Threading/UI/Design/PointerTracking.swift \
      -o out/subagent-row-mac-exe
  out/subagent-row-mac-exe "$output"
  exit
fi

output="$PWD/out/subagent-row-linux"
mkdir -p "$output"
docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e "SUBAGENT_ROW_OUTPUT=/repo/Platforms/Linux/out/subagent-row-linux" \
  swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product SubagentRowHarness
bin=$(swift build --show-bin-path)
timeout 30 "$bin/SubagentRowHarness" "$SUBAGENT_ROW_OUTPUT"
INNER

for name in rows selection-moved; do
  test -s "$output/$name.png"
done
echo "Subagent row artifacts: $output"
