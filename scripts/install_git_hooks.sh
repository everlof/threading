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
# Two hooks are taught the same lesson afterwards, post-commit and post-merge,
# and their shims run scripts/autoinstall.sh — the loop that keeps
# /Applications/Threading.app on master's tip. Their exit codes are discarded:
# they run after the commit or merge already happened, and a background build
# must never be able to look like a failed git command.
#
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
git_directory="$(cd "${repository_directory}" && git rev-parse --absolute-git-dir)"

delegation_marker="pre-push.local"

global_hooks_path="$(git config --global --get core.hooksPath || true)"
# Expanded here rather than inside the block below, because everything after it —
# the post-commit and post-merge delegation too — reads this variable.
global_hooks_path="${global_hooks_path/#\~/${HOME}}"
if [[ -n "${global_hooks_path}" ]]; then
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
echo "Push now runs 'scripts/test.sh all'. Bypass with THREADING_SKIP_TESTS=1 git push."

# The post-commit and post-merge hooks that keep /Applications current.
#
# Appended rather than spliced: unlike pre-push, nothing here needs to run before
# Git LFS or to see its stdin, and appending cannot mangle a global hook whose
# body has drifted. These hooks' exit codes are ignored by git, which is why the
# delegate's status is swallowed rather than propagated.
teach_global_delegation() {
  local hook="$1"
  local global_hook="${global_hooks_path}/${hook}"

  if [[ -z "${global_hooks_path}" || ! -f "${global_hook}" ]]; then
    echo "No global ${hook} to teach — leaving it alone."
    return
  fi
  if grep -q "${hook}.local" "${global_hook}"; then
    echo "Global ${hook} already delegates — leaving it alone."
    return
  fi

  cp "${global_hook}" "${global_hook}.backup"
  cat >> "${global_hook}" <<HOOK

# Run repo-specific ${hook} if it exists, mirroring the pre-commit convention. Its
# status is discarded: this hook runs after the work git was asked to do is already
# done, so a repository-local side effect must not look like a failed git command.
if [ -x ".git/hooks/${hook}.local" ]; then
    .git/hooks/${hook}.local "\$@" || true
fi
HOOK
  echo "Taught ${global_hook} to delegate to .git/hooks/${hook}.local"
}

for hook in post-commit post-merge; do
  teach_global_delegation "${hook}"

  hook_shim="${git_directory}/hooks/${hook}.local"
  cat > "${hook_shim}" <<'SHIM'
#!/usr/bin/env bash
# Installed by scripts/install_git_hooks.sh. The logic lives in the repository.
exec "$(git rev-parse --show-toplevel)/scripts/autoinstall.sh" trigger
SHIM
  chmod +x "${hook_shim}"
  echo "Installed ${hook_shim}"
done

echo "Commits and merges on master now rebuild and install Threading.app."
echo "Watch it with scripts/autoinstall.sh status, pause it with scripts/autoinstall.sh off."
