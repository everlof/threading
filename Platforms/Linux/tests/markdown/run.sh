#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
mode=${1:-linux}
[[ $mode == linux || $mode == macos || $mode == compare ]] || {
  echo 'usage: run.sh [linux|macos|compare]' >&2; exit 64;
}
if [[ $mode == compare ]]; then
  python3 - <<'PY'
import json
from pathlib import Path
mac = json.loads(Path('out/markdown-macos/grammar.json').read_text())
linux = json.loads(Path('out/markdown-linux/grammar.json').read_text())
assert mac == linux, 'Markdown block, trait, link, or alignment snapshots differ'
print(f'PASS {len(mac)} production Markdown cases match macOS AppKit')
PY
  exit
fi
sources=(tests/markdown/Markdown.swift tests/markdown/MarkdownInline.swift
         tests/markdown/AgentAuthoredURLPolicy.swift tests/markdown/ThemeBoundary.swift
         tests/markdown/Fixture.swift)
for file in "${sources[@]:0:3}"; do
  [[ -L $file && -f $file ]] || { echo "missing production source link: $file" >&2; exit 1; }
done
if [[ $mode == macos ]]; then
  mkdir -p out/markdown-macos
  swiftc -parse-as-library "${sources[@]}" -o out/markdown-macos/fixture
  out/markdown-macos/fixture out/markdown-macos
  exit
fi
docker run --rm --platform linux/arm64 -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  swift:6.3.2-noble bash -lc '
    set -euo pipefail
    apt-get update -qq >/dev/null
    apt-get install -y -qq libpango1.0-dev fonts-dejavu-core fonts-noto-color-emoji >/dev/null
    swift build --product MarkdownHarness
    bin="$(swift build --show-bin-path)"
    "$bin/MarkdownHarness" out/markdown-linux
  '
