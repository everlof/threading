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
#   THREADING_SKIP_TESTS=1 git push   # skips the test level; secrets are still scanned
#   git push --no-verify              # skips every hook, including Git LFS
#
set -euo pipefail

# A push that only deletes refs has nothing to test. Each line's local sha is all
# zeros for a deletion; if every line looks like that, there is no new code.
has_something_to_test=0
pushed_ranges=()
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  if [[ "${local_sha}" =~ ^0+$ ]]; then
    continue
  fi
  has_something_to_test=1
  pushed_ranges+=("${local_sha} ${remote_sha}")
done

if [[ "${has_something_to_test}" == "0" ]]; then
  exit 0
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Secrets first: it is seconds against the test level's minutes, and it is the one failure
# here that cannot be undone by fixing it afterwards. Once a credential is pushed to a public
# remote it is burned, because GitHub keeps unreachable commits addressable by their sha.
for range in "${pushed_ranges[@]}"; do
  # shellcheck disable=SC2086 # deliberately split into the two arguments the script takes
  if ! "${script_directory}/check_secrets.sh" ${range}; then
    cat >&2 <<'MESSAGE'

pre-push: the secret scan did not pass on the commits being pushed, so nothing was pushed.

If it is real: rotate it first — pushing it to a public remote burns it, and removing the
commit afterwards does not, because GitHub keeps unreachable commits addressable by sha.

If it is a false positive: review it, then pin it by fingerprint in .gitleaksignore.
Never widen .gitleaks.toml to make one finding go away.

MESSAGE
    exit 1
  fi
done

# The variable is named for what it skips. The secret scan above is seconds, not minutes, and
# is the one gate whose failure cannot be repaired after the fact — so it runs either way, and
# skipping it deliberately means `git push --no-verify`.
if [[ "${THREADING_SKIP_TESTS:-}" == "1" ]]; then
  echo "pre-push: THREADING_SKIP_TESTS=1 — skipping the test gate. Secrets were still scanned." >&2
  exit 0
fi

echo "pre-push: running the full test level (scripts/test.sh all)…" >&2
echo "pre-push: this opens windows and takes a few minutes." >&2

if ! "${script_directory}/test.sh" all; then
  cat >&2 <<'MESSAGE'

pre-push: the full test level failed, so nothing was pushed.

Fix the failures, or bypass deliberately:
  THREADING_SKIP_TESTS=1 git push

MESSAGE
  exit 1
fi

echo "pre-push: full test level passed." >&2
