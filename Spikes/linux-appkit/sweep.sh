#!/usr/bin/env bash
#
# Type-checks every file in `Sources/Threading/UI/Design/` on Linux, one at a time, against the
# shim alone, and classifies what each one could not resolve:
#
#   shim-clean  — nothing missing but *Threading's own* types, which another file defines.
#                 The shim owes this file nothing; it is only sitting in a dependency graph.
#   shim-gap    — something beginning NS/CA/CG/CT is missing. This is what a Linux AppKit
#                 would still have to implement.
#
# The point is to separate the two, because the headline number everyone wants ("how much of the
# UI compiles?") conflates them and flatters the answer in one direction or the other.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker run --rm -i -v "$PWD:/w" -v "$PWD/../..:/repo:ro" -w /w swift:6.3.2-noble bash -s <<'INNER'
set -uo pipefail
swift build >/dev/null 2>&1
modules="$(find .build -name 'AppKit.swiftmodule' -printf '%h\n' | head -1)"
echo "modules: ${modules}"
mkdir -p /w/out
report=/w/out/sweep.tsv
: > "${report}"
for file in /repo/Sources/Threading/UI/Design/*.swift; do
  name="$(basename "${file}")"
  errors="$(swiftc -typecheck -swift-version 6 -I "${modules}" "${file}" 2>&1 | grep -E "error:" || true)"
  if [[ -z "${errors}" ]]; then
    printf '%s\tclean\t\n' "${name}" >> "${report}"
    continue
  fi
  missing="$(echo "${errors}" | grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*'" \
    | grep -oE "'[A-Za-z0-9_]*'" | tr -d "'" | sort -u)"
  platform="$(echo "${missing}" | grep -E '^(NS|CA|CG|CT)[A-Z]' | tr '\n' ',' | sed 's/,$//')"
  # A member error on a type we *do* define is a shim gap too — it means the type is too thin.
  thin="$(echo "${errors}" | grep -oE "type '(NS|CA|CG|CT)[A-Za-z0-9_]*' has no member '[A-Za-z0-9_]*'" \
    | sed -E "s/type '([A-Za-z0-9_]*)' has no member '([A-Za-z0-9_]*)'/\1.\2/" | sort -u | tr '\n' ',' | sed 's/,$//')"
  joined="${platform}${thin:+,}${thin}"
  if [[ -z "${joined}" ]]; then
    printf '%s\tshim-clean\t\n' "${name}" >> "${report}"
  else
    printf '%s\tshim-gap\t%s\n' "${name}" "${joined}" >> "${report}"
  fi
done
echo "=== verdicts ==="
cut -f2 "${report}" | sort | uniq -c | sort -rn
echo "=== what a Linux AppKit would still owe, by how many files want it ==="
cut -f3 "${report}" | tr ',' '\n' | grep -v '^$' | sort | uniq -c | sort -rn | head -45
INNER
