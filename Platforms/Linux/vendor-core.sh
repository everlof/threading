#!/usr/bin/env bash
#
# Links the shared core listed in coreslice.list into Sources/CoreSlice.
#
#   ./vendor-core.sh            # replace Sources/CoreSlice with links to the working tree
#   ./vendor-core.sh --verify   # fail if a link is missing or points away from its original
#
# The same contract as vendor.sh for the UI half: this exact production source compiles on Linux.
# A manifest entry resolves to one source file; no copied body can drift from macOS.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
destination="${here}/Sources/CoreSlice"
manifest="${here}/coreslice.list"

entries() {
  # Skip comments and blank lines; emit "source<TAB>name".
  grep -vE '^\s*(#|$)' "${manifest}" | while IFS=$'\t' read -r source name; do
    printf '%s\t%s\n' "${source}" "${name:-$(basename "${source}")}"
  done
}

# Reject a collision before replacing the directory: two manifest rows cannot own one link.
recorded_names="$(entries | cut -f2)"
duplicate_names="$(printf '%s\n' "${recorded_names}" | sort | uniq -d)"
if [[ -n "${duplicate_names}" ]]; then
  echo "DUPLICATE destination: ${duplicate_names}" >&2
  exit 1
fi
while IFS=$'\t' read -r source name; do
  if [[ ! -f "${root}/${source}" ]]; then
    echo "MISSING source: ${source}" >&2
    exit 1
  fi
done < <(entries)

if [[ "${1:-}" == "--verify" ]]; then
  status=0
  while IFS=$'\t' read -r source name; do
    expected="../../../../${source}"
    link="${destination}/${name}"
    if [[ ! -L "${link}" || "$(readlink "${link}")" != "${expected}" || ! -f "${link}" ]]; then
      echo "NOT LINKED: ${source} -> ${name}" >&2
      status=1
    fi
  done < <(entries)
  # Parse the manifest once; rebuilding its full list for each file made this gate quadratic
  # in subprocess work as the native transport graph grew.
  # Anything in the directory the manifest does not name is an unrecorded file.
  while IFS= read -r present; do
    if ! grep -qxF "${present}" <<<"${recorded_names}"; then
      echo "UNRECORDED: Sources/CoreSlice/${present}" >&2
      status=1
    fi
  done < <(ls "${destination}")
  [[ ${status} -eq 0 ]] && echo "all $(printf '%s\n' "${recorded_names}" | wc -l | tr -d ' ') core files link production sources, and none is unrecorded"
  exit ${status}
fi

rm -rf "${destination}"
mkdir -p "${destination}"
count=0
while IFS=$'\t' read -r source name; do
  ln -s "../../../../${source}" "${destination}/${name}"
  count=$((count + 1))
done < <(entries)
echo "linked ${count} production files into Sources/CoreSlice"
