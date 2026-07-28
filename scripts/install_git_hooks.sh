#!/usr/bin/env bash
#
# Install this repository's git hooks. Idempotent — safe to re-run.
#
# core.hooksPath is set globally to ~/.git-hooks, so a repository cannot simply
# drop a file in .git/hooks and be heard. The global pre-commit already solves
# this by delegating to an optional .git/hooks/pre-commit.local; this script
# teaches the global pre-push the same trick, then installs the shim that runs
# scripts/pre_push.sh.
#
# Shadowing the global hooks with a repo-local core.hooksPath would have meant
# reimplementing Git LFS and the commit-msg hook here, so delegation it is.
#
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
git_directory="$(cd "${repository_directory}" && git rev-parse --absolute-git-dir)"

delegation_marker="pre-push.local"

global_hooks_path="$(git config --global --get core.hooksPath || true)"
if [[ -n "${global_hooks_path}" ]]; then
  global_hooks_path="${global_hooks_path/#\~/${HOME}}"
  global_pre_push="${global_hooks_path}/pre-push"

  if [[ -f "${global_pre_push}" ]] && ! grep -q "${delegation_marker}" "${global_pre_push}"; then
    cp "${global_pre_push}" "${global_pre_push}.backup"
    echo "Backed up ${global_pre_push} to ${global_pre_push}.backup"

    # Git LFS consumes stdin, so the ref lines are captured once and replayed to
    # both hooks. Without a .local hook the behaviour is byte-identical to before.
    python3 - "${global_pre_push}" <<'PYTHON'
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()

original_call = 'git lfs pre-push "$@"\n'
replacement = '''
# Run repo-specific pre-push hook if it exists, mirroring the pre-commit convention.
# git lfs pre-push consumes stdin, so the ref lines are captured once and replayed
# to both hooks. With no .local hook the behaviour is identical to the original.
if [ -x ".git/hooks/pre-push.local" ]; then
    stdin_copy=$(mktemp)
    cat > "$stdin_copy"
    if ! .git/hooks/pre-push.local "$@" < "$stdin_copy"; then
        rm -f "$stdin_copy"
        exit 1
    fi
    git lfs pre-push "$@" < "$stdin_copy"
    lfs_status=$?
    rm -f "$stdin_copy"
    exit $lfs_status
fi

git lfs pre-push "$@"
'''

if original_call not in text:
    sys.exit('Could not find the git lfs pre-push call to wrap; edit it by hand.')

text = text.replace(original_call, replacement, 1)
with open(path, 'w') as handle:
    handle.write(text)
PYTHON

    echo "Taught ${global_pre_push} to delegate to .git/hooks/pre-push.local"
  else
    echo "Global pre-push already delegates (or does not exist) — leaving it alone."
  fi
fi

mkdir -p "${git_directory}/hooks"
shim="${git_directory}/hooks/pre-push.local"
cat > "${shim}" <<'SHIM'
#!/usr/bin/env bash
# Installed by scripts/install_git_hooks.sh. The logic lives in the repository.
exec "$(git rev-parse --show-toplevel)/scripts/pre_push.sh" "$@"
SHIM
chmod +x "${shim}"

echo "Installed ${shim}"
echo "Push now runs 'scripts/test.sh all'. Bypass with SKALMAN_SKIP_TESTS=1 git push."
