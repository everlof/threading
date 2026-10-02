#!/usr/bin/env bash
# Build the Linux harness and rank unresolved symbols in the AppKit compatibility layer.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Mount the package dependencies at the same relative paths as on the host, and build only
# the UI product. The independently measured CoreSlice can still have platform blockers.
status=0
docker run --rm -v "$PWD/../..:/repo" -w /repo/Platforms/Linux \
  -e SPIKE_OUT=/repo/Platforms/Linux/out swift:6.3.2-noble \
  bash -lc 'apt-get update -qq >/dev/null && apt-get install -y -qq libpango1.0-dev >/dev/null && swift build --product Harness' > .build-log 2>&1 || status=$?
grep -E "^/repo/.*error:" .build-log | sed 's|/repo/Platforms/Linux/Sources/Harness/Vendored/||' | sort -u > .errors
if [[ -s .errors ]]; then
  echo "=== $(wc -l < .errors) errors; unresolved symbols by frequency ==="
  grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*'|has no member '[A-Za-z0-9_]*'|is not a member type of|type '[A-Za-z]*' has no member '[A-Za-z0-9_]*'" .errors \
    | grep -oE "'[A-Za-z0-9_]*'" | sort | uniq -c | sort -rn | head -40
  echo "=== other errors ==="
  grep -v "cannot find" .errors | head -25
elif [[ ${status} -ne 0 ]]; then
  echo "=== build failed (exit ${status}); full output in .build-log ===" >&2
  tail -60 .build-log >&2
else
  echo "=== builds clean ==="
  tail -3 .build-log
fi

exit "${status}"
