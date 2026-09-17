#!/usr/bin/env bash
# One Linux build of the spike, with the unique unresolved symbols ranked. That ranking is the
# spike's actual output: it says what an AppKit-shaped Linux shim would still owe Threading.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker run --rm -v "$PWD:/w" -w /w -e SPIKE_OUT=/w/out swift:6.3.2-noble \
  bash -c 'mkdir -p out && swift build 2>&1' > .build-log 2>&1
grep -E "^/w.*error:" .build-log | sed 's|/w/Sources/Harness/Vendored/||' | sort -u > .errors
if [[ -s .errors ]]; then
  echo "=== $(wc -l < .errors) errors; unresolved symbols by frequency ==="
  grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*'|has no member '[A-Za-z0-9_]*'|is not a member type of|type '[A-Za-z]*' has no member '[A-Za-z0-9_]*'" .errors \
    | grep -oE "'[A-Za-z0-9_]*'" | sort | uniq -c | sort -rn | head -40
  echo "=== other errors ==="
  grep -v "cannot find" .errors | head -25
else
  echo "=== builds clean ==="
  tail -3 .build-log
fi
