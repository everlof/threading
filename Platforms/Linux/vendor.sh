#!/usr/bin/env bash
#
# Links real Threading sources into the shim fixture. The same production file compiles against
# macOS AppKit and the Linux module named AppKit; there is no second body to drift.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
destination="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Sources/Harness/Vendored"

files=(
  "Sources/Threading/UI/Design/RevealHighlightView.swift"
)

if [[ -f "$(dirname "${BASH_SOURCE[0]}")/vendored.list" ]]; then
  mapfile -t files < "$(dirname "${BASH_SOURCE[0]}")/vendored.list"
fi

declare -A destinations=()
for file in "${files[@]}"; do
  name="$(basename "${file}")"
  if [[ -n "${destinations[${name}]:-}" ]]; then
    echo "DUPLICATE destination: ${name}" >&2
    exit 1
  fi
  destinations["${name}"]=1
  if [[ ! -f "${root}/${file}" ]]; then
    echo "MISSING source: ${file}" >&2
    exit 1
  fi
done

if [[ "${1:-}" == "--verify" ]]; then
  status=0
  for file in "${files[@]}"; do
    link="${destination}/$(basename "${file}")"
    if [[ ! -L "${link}" || "$(readlink "${link}")" != "../../../../../${file}" || ! -f "${link}" ]]; then
      echo "NOT LINKED: ${file}" >&2
      status=1
    fi
  done
  for link in "${destination}"/*.swift; do
    [[ -e "${link}" || -L "${link}" ]] || continue
    name="$(basename "${link}")"
    if [[ -z "${destinations[${name}]:-}" ]]; then
      echo "UNRECORDED fixture file: ${name}" >&2
      status=1
    fi
  done
  [[ $status -eq 0 ]] && echo "all fixture files link production sources"
  exit $status
fi

rm -rf "${destination}"
mkdir -p "${destination}"
for file in "${files[@]}"; do
  ln -s "../../../../../${file}" "${destination}/$(basename "${file}")"
  echo "linked ${file}"
done
