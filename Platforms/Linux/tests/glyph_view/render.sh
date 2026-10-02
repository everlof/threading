#!/usr/bin/env bash
# Draw the exact production GlyphView with shim AppKit and inspect pixels before keeping PNGs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out
artifact_dir=$(mktemp -d "$PWD/out/glyph-view.XXXXXX")
container_dir="/repo/Platforms/Linux/out/${artifact_dir##*/}"

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e "GLYPH_OUTPUT=$container_dir" swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product GlyphViewHarness
bin=$(swift build --show-bin-path)
timeout 30 "$bin/GlyphViewHarness" "$GLYPH_OUTPUT"
INNER

test -s "$artifact_dir/template-1x.png"
test -s "$artifact_dir/template-2x.png"
test -s "$artifact_dir/artwork-2x.png"
test -s "$artifact_dir/image-view-template-1x.png"
test -s "$artifact_dir/image-view-template-2x.png"
test -s "$artifact_dir/image-view-artwork-2x.png"
echo "GlyphView artifacts: $artifact_dir"
