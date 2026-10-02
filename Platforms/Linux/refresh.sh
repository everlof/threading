#!/usr/bin/env bash
#
# Re-copy production sources, rebuild, re-sweep, and report what moved.
#
#   ./refresh.sh                # measure the current checkout
#   ./refresh.sh --accept       # record the current sweep as the new baseline
#
# The per-file delta measures how ordinary product changes affect Linux compatibility.
# This command never changes Git history.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
repository="$(cd ../.. && pwd)"

accept=0
for argument in "$@"; do
  case "${argument}" in
    --no-rebase) ;; # compatibility with the old branch-only runner
    --accept) accept=1 ;;
    *) echo "refresh: unknown argument ${argument}" >&2; exit 64 ;;
  esac
done

if [[ ${accept} -eq 1 ]]; then
  cp out/sweep.tsv baseline/sweep.tsv
  echo "baseline updated from the last sweep; commit it with the change that earned it"
  exit 0
fi

echo "=== re-vendoring from the working tree ==="
./vendor.sh
moved="$(git -C "${repository}" diff --stat -- "Platforms/Linux/Sources/Harness/Vendored")"
if [[ -n "${moved}" ]]; then
  echo "--- vendored sources changed upstream:"
  echo "${moved}"
else
  echo "--- vendored sources unchanged upstream"
fi

echo "=== building ==="
./build.sh || exit 1

echo "=== sweeping ==="
./sweep.sh > /dev/null || exit 1

echo "=== delta since the baseline ==="
if ! diff <(cut -f1,2 baseline/sweep.tsv) <(cut -f1,2 out/sweep.tsv) > /dev/null; then
  join -t $'\t' -j 1 <(cut -f1,2 baseline/sweep.tsv | sort) <(cut -f1,2 out/sweep.tsv | sort) \
    | awk -F'\t' '$2 != $3 { printf "%-52s %s -> %s\n", $1, $2, $3 }'
  comm -13 <(cut -f1 baseline/sweep.tsv | sort) <(cut -f1 out/sweep.tsv | sort) \
    | sed 's/^/new file: /'
  comm -23 <(cut -f1 baseline/sweep.tsv | sort) <(cut -f1 out/sweep.tsv | sort) \
    | sed 's/^/gone: /'
  echo
  echo "verdict counts — baseline, then now:"
  cut -f2 baseline/sweep.tsv | sort | uniq -c | sort -rn | sed 's/^/  was /'
  cut -f2 out/sweep.tsv | sort | uniq -c | sort -rn | sed 's/^/  now /'
  echo
  echo "run ./refresh.sh --accept to adopt this as the baseline"
else
  echo "no file changed verdict since the baseline"
fi
