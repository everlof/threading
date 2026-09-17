#!/usr/bin/env bash
#
# Copies real Threading sources into the spike **verbatim**. Nothing here may edit them: the whole
# claim the spike is making is "this file, exactly as it ships on macOS, compiles against a module
# we named AppKit". `./vendor.sh --verify` re-checks that, and is the only thing standing between
# an honest measurement and a flattering one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
destination="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Sources/Harness/Vendored"

files=(
  "Sources/Threading/UI/Design/RevealHighlightView.swift"
)

if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vendored.list" ]]; then
  mapfile -t files < "$(dirname "${BASH_SOURCE[0]}")/vendored.list"
fi

if [[ "${1:-}" == "--verify" ]]; then
  status=0
  for file in "${files[@]}"; do
    if ! diff -q "${root}/${file}" "${destination}/$(basename "${file}")" >/dev/null; then
      echo "MODIFIED: ${file}" >&2
      status=1
    fi
  done
  [[ $status -eq 0 ]] && echo "all vendored files are byte-identical to the repository"
  exit $status
fi

rm -rf "${destination}"
mkdir -p "${destination}"
for file in "${files[@]}"; do
  cp "${root}/${file}" "${destination}/$(basename "${file}")"
  echo "vendored ${file}"
done
