#!/usr/bin/env bash
#
# The secret-scanning gate: no credential leaves this machine inside a commit.
#
# Called by scripts/ci.sh (whole history, because CI is the release gate and proves the whole
# artifact) and by scripts/pre_push.sh (only the range being pushed, because that is the part
# that has not been proven yet). Policy lives in .gitleaks.toml; reviewed false positives are
# pinned by fingerprint in .gitleaksignore.
#
# Scan *git*, never the working directory. `gitleaks dir .` walks build output — DerivedData,
# .build, node_modules, xcbuilddata attachments — which measured 2.87 GB and 8m50s here against
# 125 MB and 26s for the whole history, and reports findings in artifacts nobody can commit.
#
# Usage:
#   check_secrets.sh                  # whole history
#   check_secrets.sh <since> <until>  # one range, as the pre-push hook passes it
#
set -euo pipefail

readonly install_hint="install it with 'brew install gitleaks'"

say() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

command -v gitleaks >/dev/null 2>&1 \
    || fail "gitleaks is required; ${install_hint}"

# gitleaks reports a bad revision on stderr and still exits 0 with "no leaks found", so an
# unresolvable sha would read as a clean scan. Resolve every revision ourselves first and fail
# loudly, because a gate that silently scans nothing is worse than no gate at all.
require_revision() {
    git -C "${repository_directory}" rev-parse --verify --quiet "$1^{commit}" >/dev/null \
        || fail "cannot resolve revision '$1'; refusing to report a scan that examined nothing"
}

log_options=""
scope="the whole history"
if [[ $# -eq 2 ]]; then
    # A branch pushed for the first time has no remote sha, so git hands the hook all zeros.
    # Scanning that range would be an error; scanning everything reachable from the new tip
    # is the honest reading of "none of this has been pushed".
    require_revision "$1"
    if [[ "$2" =~ ^0+$ ]]; then
        log_options="$1"
        scope="everything reachable from $1"
    else
        require_revision "$2"
        log_options="$2..$1"
        scope="$2..$1"
    fi
fi

say "Scanning ${scope} for secrets"

if [[ -n "${log_options}" ]]; then
    gitleaks git "${repository_directory}" \
        --config "${repository_directory}/.gitleaks.toml" \
        --gitleaks-ignore-path "${repository_directory}/.gitleaksignore" \
        --log-opts "${log_options}" \
        --redact \
        --no-banner
else
    gitleaks git "${repository_directory}" \
        --config "${repository_directory}/.gitleaks.toml" \
        --gitleaks-ignore-path "${repository_directory}/.gitleaksignore" \
        --redact \
        --no-banner
fi
