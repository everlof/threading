#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
docker run --rm -e THREADING_EDITOR_SCROLL_BENCHMARK="${THREADING_EDITOR_SCROLL_BENCHMARK:-0}" \
  -e THREADING_EDITOR_CONFIGURATION="${THREADING_EDITOR_CONFIGURATION:-debug}" \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -lc '
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build -c "$THREADING_EDITOR_CONFIGURATION" --product TextEditorHarness
swift run -c "$THREADING_EDITOR_CONFIGURATION" --skip-build TextEditorHarness
'
