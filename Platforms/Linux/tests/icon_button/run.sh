#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out
artifact_dir=$(mktemp -d "$PWD/out/icon-button.XXXXXX")
container_dir="/repo/Platforms/Linux/out/${artifact_dir##*/}"

docker run --rm -i --platform linux/arm64 \
  -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e "ICON_BUTTON_OUTPUT=$container_dir" swift:6.3.2-noble bash -s <<'INNER'
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev >/dev/null
swift build --product IconButtonHarness
bin=$(swift build --show-bin-path)
timeout 30 "$bin/IconButtonHarness" "$ICON_BUTTON_OUTPUT"
INNER

for name in rest hover pressed focused disabled; do
  test -s "$artifact_dir/$name.png"
done
echo "IconButton artifacts: $artifact_dir"
