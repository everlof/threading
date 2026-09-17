#!/usr/bin/env bash
#
# One turn of the crank on a long-lived branch: catch up with master, re-copy the vendored
# sources, rebuild, re-sweep, and say what moved.
#
#   ./refresh.sh                # rebase onto master, then measure
#   ./refresh.sh --no-rebase    # measure only
#   ./refresh.sh --accept       # record the current sweep as the new baseline
#
# The delta is the point. A long-lived branch justifies itself by being a *meter*: when ordinary
# product work on master moves a file out of AppKit's way, this says so, by name, that week. When
# it moves one further in, it says that too. Neither is visible from inside the branch.
#
# The branch is deliberately thin. Nothing here is under `Sources/`, so it cannot conflict with
# product work; the only thing that drifts is the vendored copies, and re-copying them is what
# surfaces the drift. Anything this spike needs *changed* in the app belongs on master — see
# delivery slice 3 in docs/feature-drafts/linux-host-runtime.md, the structural ratchets.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
repository="$(cd ../.. && pwd)"

rebase=1
accept=0
for argument in "$@"; do
  case "${argument}" in
    --no-rebase) rebase=0 ;;
    --accept) accept=1; rebase=0 ;;
    *) echo "refresh: unknown argument ${argument}" >&2; exit 64 ;;
  esac
done

if [[ ${accept} -eq 1 ]]; then
  cp out/sweep.tsv baseline/sweep.tsv
  echo "baseline updated from the last sweep; commit it with the change that earned it"
  exit 0
fi

if [[ ${rebase} -eq 1 ]]; then
  if [[ -n "$(git -C "${repository}" status --porcelain)" ]]; then
    echo "refresh: the working tree is dirty; commit or stash before rebasing" >&2
    exit 1
  fi
  echo "=== rebasing onto master ==="
  git -C "${repository}" rebase master || {
    echo "refresh: rebase stopped — resolve, then re-run with --no-rebase" >&2
    exit 1
  }
fi

echo "=== re-vendoring from the working tree ==="
./vendor.sh
moved="$(git -C "${repository}" diff --stat -- "Spikes/linux-appkit/Sources/Harness/Vendored")"
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
