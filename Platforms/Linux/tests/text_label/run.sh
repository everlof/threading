#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mode=${1:-check}
[[ $mode == check || $mode == --benchmark ]] || { echo 'usage: run.sh [--benchmark]' >&2; exit 64; }
configuration=${THREADING_LABEL_CONFIGURATION:-debug}
[[ $configuration == debug || $configuration == release ]] || { echo 'invalid label configuration' >&2; exit 64; }
docker run --rm -e "THREADING_LABEL_FIXTURE_MODE=$mode" \
  -e "THREADING_LABEL_CONFIGURATION=$configuration" \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  swift:6.3.2-noble bash -lc '
    set -euo pipefail
    apt-get update -qq >/dev/null
    apt-get install -y -qq libpango1.0-dev >/dev/null
    swift build -c "$THREADING_LABEL_CONFIGURATION" --product TextLabelHarness
    bin="$(swift build -c "$THREADING_LABEL_CONFIGURATION" --show-bin-path)"
    if [[ $THREADING_LABEL_FIXTURE_MODE == --benchmark ]]; then
      "$bin/TextLabelHarness" --benchmark
      exit
    fi
    swift build -c "$THREADING_LABEL_CONFIGURATION" --product Harness
    mkdir -p out/text_label
    swiftc Sources/Harness/Vendored/NeutralInk.swift \
      Sources/Harness/Vendored/TextLegibilityPolicy.swift \
      tests/neutral_ink/Fixture.swift -o out/text_label/neutral-ink
    out/text_label/neutral-ink out/text_label/neutral-ink.json
    SPIKE_OUT=out/text_label SPIKE_SKIP_LAYOUT_BENCHMARK=1 "$bin/Harness"
    "$bin/TextLabelHarness" --ink-json out/text_label/neutral-ink.json
  '
