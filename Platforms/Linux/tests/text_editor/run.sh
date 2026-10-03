#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
docker run --rm -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -lc '
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product TextEditorHarness
swift run --skip-build TextEditorHarness
'
