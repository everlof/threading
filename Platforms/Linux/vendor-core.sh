#!/usr/bin/env bash
#
# Copies the persistence slice listed in coreslice.list into Sources/CoreSlice, verbatim.
#
#   ./vendor-core.sh            # replace Sources/CoreSlice with fresh copies from the working tree
#   ./vendor-core.sh --verify   # fail if any copy differs from its original
#
# The same contract as vendor.sh for the UI half: the claim is "this file, exactly as it ships,
# compiles on Linux", and --verify is the only thing that keeps that claim honest. The directory is
# rebuilt from the manifest on every run, so a file vendored by hand and never recorded — which is
# how five of these went unverified for two rounds — cannot survive a refresh.
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

if [[ "${1:-}" == "--verify" ]]; then
  status=0
  while IFS=$'\t' read -r source name; do
    if ! cmp -s "${root}/${source}" "${destination}/${name}"; then
      echo "DIFFERS: ${source} -> ${name}" >&2
      status=1
    fi
  done < <(entries)
  # Anything in the directory the manifest does not name is an unrecorded file.
  while IFS= read -r present; do
    if ! entries | cut -f2 | grep -qxF "${present}"; then
      echo "UNRECORDED: Sources/CoreSlice/${present}" >&2
      status=1
    fi
  done < <(ls "${destination}")
  [[ ${status} -eq 0 ]] && echo "all $(entries | wc -l | tr -d ' ') vendored files are byte-identical, and none is unrecorded"
  exit ${status}
fi

rm -rf "${destination}"
mkdir -p "${destination}"
count=0
while IFS=$'\t' read -r source name; do
  cp "${root}/${source}" "${destination}/${name}"
  count=$((count + 1))
done < <(entries)
echo "vendored ${count} files into Sources/CoreSlice"
