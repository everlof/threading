#!/usr/bin/env bash
#
# Type-checks every file in `Sources/Threading/{Core,Models,Application}` on Linux, one at a time,
# against Foundation alone — no AppKit shim, nothing from this spike.
#
# That absence is the design. `headless.py` reads imports, which is a ceiling; this asks the Swift
# compiler, which is a measurement. And because no AppKit, Security or IOKit module exists in the
# container, a file that needs one fails with an unambiguous "no such module" rather than a
# thousand cascading symbol errors — so the blocked set classifies itself.
#
# Writes out/core-errors.tsv (one row per file, errors escaped onto one line). Run
# `./classify-core.py` afterwards to turn that into verdicts; the two are separate so a
# classification rule can change without a seven-minute re-run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p out

docker run --rm -i \
  -v "$PWD/out:/out" \
  -v "$PWD/../..:/repo:ro" \
  -w /tmp swift:6.3.2-noble bash -s <<'INNER'
set -uo pipefail
report=/out/core-errors.tsv
: > "${report}"
count=0
while IFS= read -r file; do
  count=$((count + 1))
  relative="${file#/repo/}"
  errors="$(swiftc -typecheck -swift-version 6 "${file}" 2>&1 | grep -E "error:" | sort -u | tr '\n' '\v' || true)"
  printf '%s\t%s\n' "${relative}" "${errors}" >> "${report}"
done < <(find /repo/Sources/Threading/Core /repo/Sources/Threading/Models \
              /repo/Sources/Threading/Application -name '*.swift' | sort)
echo "type-checked ${count} files"
INNER
