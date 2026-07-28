#!/usr/bin/env bash
#
# The push gate: run the full test level before anything leaves this machine.
# See "Test levels" in CLAUDE.md.
#
# Installed by scripts/install_git_hooks.sh, which links .git/hooks/pre-push.local
# here. The logic lives in the repository so it is reviewed and versioned like any
# other code; the file under .git/ is only a shim.
#
# git passes the remote name and URL as $1 and $2, and one line per ref on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
#
# Escape hatches, in order of preference:
#   SKALMAN_SKIP_TESTS=1 git push     # documented, greppable
#   git push --no-verify              # skips every hook, including Git LFS
#
set -euo pipefail

if [[ "${SKALMAN_SKIP_TESTS:-}" == "1" ]]; then
  echo "pre-push: SKALMAN_SKIP_TESTS=1 — skipping the test gate." >&2
  exit 0
fi

# A push that only deletes refs has nothing to test. Each line's local sha is all
# zeros for a deletion; if every line looks like that, there is no new code.
has_something_to_test=0
while read -r _local_ref local_sha _remote_ref _remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  if [[ "${local_sha}" =~ ^0+$ ]]; then
    continue
  fi
  has_something_to_test=1
done

if [[ "${has_something_to_test}" == "0" ]]; then
  exit 0
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "pre-push: running the full test level (scripts/test.sh all)…" >&2
echo "pre-push: this opens windows and takes a few minutes." >&2

if ! "${script_directory}/test.sh" all; then
  cat >&2 <<'MESSAGE'

pre-push: the full test level failed, so nothing was pushed.

Fix the failures, or bypass deliberately:
  SKALMAN_SKIP_TESTS=1 git push

MESSAGE
  exit 1
fi

echo "pre-push: full test level passed." >&2
