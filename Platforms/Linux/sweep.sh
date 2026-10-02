#!/usr/bin/env bash
#
# Type-checks every file in `Sources/Threading/UI/Design/` on Linux, one at a time, against the
# shim alone, and classifies what each one could not resolve:
#
#   shim-clean  — nothing missing but *Threading's own* types, which another file defines.
#                 The shim owes this file nothing; it is only sitting in a dependency graph.
#   shim-gap    — a candidate missing NS/CA/CG/CT symbol or member. A one-file compile also
#                 sees app-owned extensions (for example `NSTextField.applyFont`) as absent;
#                 inspect those before treating them as platform work. Missing app-owned types
#                 can also erase contextual enum information, hiding a real platform member.
#
# The point is to separate the two, because the headline number everyone wants ("how much of the
# UI compiles?") conflates them and flatters the answer in one direction or the other.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
docker run --rm -i -v "$PWD/../..:/repo" -w /repo/Platforms/Linux swift:6.3.2-noble bash -s <<'INNER'
set -uo pipefail
apt-get update -qq >/dev/null || exit 1
apt-get install -y -qq libpango1.0-dev >/dev/null || exit 1
# A failed build is not a sweep: stale modules would produce a plausible, false report.
mkdir -p out
if ! swift build --product Harness >out/sweep-build.log 2>&1; then
  cat out/sweep-build.log >&2
  exit 1
fi
binary_path="$(swift build --show-bin-path)" || exit 1
modules="${binary_path}/Modules"
bridge_map="${binary_path}/AppKitTextBridge.build/module.modulemap"
[[ -f "${modules}/AppKit.swiftmodule" ]] || { echo "missing AppKit module" >&2; exit 1; }
[[ -f "${bridge_map}" ]] || { echo "missing AppKitTextBridge module map" >&2; exit 1; }
echo "modules: ${modules}"
report=out/sweep.tsv
: > "${report}"
for file in /repo/Sources/Threading/UI/Design/*.swift; do
  name="$(basename "${file}")"
  errors="$(swiftc -typecheck -swift-version 6 -I "${modules}" \
    -Xcc "-fmodule-map-file=${bridge_map}" "${file}" 2>&1 | grep -E "error:" || true)"
  if [[ -z "${errors}" ]]; then
    printf '%s\tclean\t\n' "${name}" >> "${report}"
    continue
  fi
  missing="$(echo "${errors}" | grep -oE "cannot find (type )?'[A-Za-z_][A-Za-z0-9_]*'" \
    | grep -oE "'[A-Za-z0-9_]*'" | tr -d "'" | sort -u)"
  platform="$(echo "${missing}" | grep -E '^(NS|CA|CG|CT)[A-Z]' | tr '\n' ',' | sed 's/,$//')"
  # A member error on a type we *do* define is a shim gap too — it means the type is too thin.
  thin="$(echo "${errors}" | grep -oE "type '(NS|CA|CG|CT)[A-Za-z0-9_.]*' has no member '[A-Za-z0-9_]*'" \
    | sed -E "s/type '([A-Za-z0-9_.]*)' has no member '([A-Za-z0-9_]*)'/\1.\2/" | sort -u | tr '\n' ',' | sed 's/,$//')"
  joined="${platform}"
  if [[ -n "${thin}" ]]; then
    joined="${joined:+${joined},}${thin}"
  fi
  if [[ -z "${joined}" ]]; then
    printf '%s\tshim-clean\t\n' "${name}" >> "${report}"
  else
    printf '%s\tshim-gap\t%s\n' "${name}" "${joined}" >> "${report}"
  fi
done
echo "=== verdicts ==="
cut -f2 "${report}" | sort | uniq -c | sort -rn
echo "=== what a Linux AppKit would still owe, by how many files want it ==="
cut -f3 "${report}" | tr ',' '\n' | grep -v '^$' | sort | uniq -c | sort -rn | sed -n '1,45p'
echo "Candidate gaps only: app-owned extensions can be counted, and unresolved contextual members can be missed."
INNER
