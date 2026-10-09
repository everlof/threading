#!/usr/bin/env bash
# Complete paragraph geometry and indexed viewport masks, with a full Pango reference.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mkdir -p out
evidence=$(mktemp -d "$PWD/out/document-text.XXXXXXXX")
docker run --rm -i --platform linux/arm64 -v "$PWD/../..:/repo" \
  -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'LINUX' 2>&1 | tee "$evidence/contract.log"
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libpango1.0-dev fonts-dejavu-core fonts-noto-cjk fonts-noto-color-emoji >/dev/null
clang -O2 -Wall -Wextra -Werror tests/document_text_contract.c \
  Sources/AppKitTextBridge/DocumentText.c -I Sources/AppKitTextBridge/include \
  $(pkg-config --cflags --libs pangocairo) -pthread -lm -o /tmp/document-text-contract
timeout 120 /tmp/document-text-contract
LINUX
printf 'document-text: %s\n' "$evidence"
