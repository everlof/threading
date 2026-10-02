#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out
artifact_dir=$(mktemp -d "$PWD/out/floating-glyph.XXXXXX")
docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e "GLYPH_OUTPUT=/repo/Platforms/Linux/out/${artifact_dir##*/}" \
  swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --scratch-path out/floating-glyph-build --product FloatingGlyphHarness
bin=$(swift build --scratch-path out/floating-glyph-build --show-bin-path)
timeout 30 "$bin/FloatingGlyphHarness" "$GLYPH_OUTPUT"
INNER
test -s "$artifact_dir/folder.png"
test -s "$artifact_dir/speed.png"
test -s "$artifact_dir/system.png"
echo "Floating glyph artifacts: $artifact_dir"
