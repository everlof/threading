#!/usr/bin/env bash
# Install a pinned build after every running Threading copy has closed.
#
# Usage: scripts/install-when-closed.sh --app <built.app> \
#          [--expected-sha256 <executable-sha256>] [--to <directory>]
#
# Run this once as a detached process if it must outlive the shell. Do not submit it to a
# launchd KeepAlive job: KeepAlive restarts a successful one-shot installer indefinitely.
# Installing never reopens Threading; an unattended install must not take keyboard focus.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

app=""
destination_directory="/Applications"
expected_sha=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) app="${2:-}"; shift 2 ;;
        --to) destination_directory="${2:-}"; shift 2 ;;
        --expected-sha256) expected_sha="${2:-}"; shift 2 ;;
        *) printf 'error: unknown argument %q\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -n "$app" && -d "$app" ]] || { echo 'error: --app must name a built app' >&2; exit 2; }
[[ -d "$destination_directory" ]] || {
    echo 'error: destination directory does not exist' >&2
    exit 2
}
if [[ -n "$expected_sha" && ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'error: --expected-sha256 must be a lowercase SHA-256 digest' >&2
    exit 2
fi

readonly source_executable="$app/Contents/MacOS/Threading"
readonly destination_executable="$destination_directory/Threading.app/Contents/MacOS/Threading"
[[ -f "$source_executable" ]] || { echo 'error: app executable is missing' >&2; exit 2; }

source_sha="$(shasum -a 256 "$source_executable" | awk '{print $1}')"
if [[ -n "$expected_sha" && "$source_sha" != "$expected_sha" ]]; then
    echo 'error: built app differs from the requested executable hash' >&2
    exit 1
fi

already_installed() {
    [[ -f "$destination_executable" ]] || return 1
    local installed_sha
    installed_sha="$(shasum -a 256 "$destination_executable" | awk '{print $1}')" || return 1
    [[ "$installed_sha" == "$source_sha" ]]
}

running_threading() {
    local processes
    processes="$(ps -Ao comm=)" || {
        echo 'error: cannot inspect running applications' >&2
        exit 1
    }
    grep -Eq '/Threading[.]app/Contents/MacOS/Threading$' <<< "$processes"
}

if already_installed; then
    echo 'Requested build is already installed.'
    exit 0
fi

# The second process check closes the gap while sleeping. install-app.sh also checks the
# destination bundle immediately before its swap, if that copy reopens during staging.
for ((attempt=0; attempt<1800; attempt++)); do
    if ! running_threading; then
        sleep 2
        if running_threading; then
            continue
        fi
        if already_installed; then
            echo 'Requested build was installed while waiting.'
            exit 0
        fi
        current_sha="$(shasum -a 256 "$source_executable" | awk '{print $1}')"
        [[ "$current_sha" == "$source_sha" ]] || {
            echo 'error: built app changed while waiting' >&2
            exit 1
        }
        exec "$ROOT/scripts/install-app.sh" --app "$app" --to "$destination_directory"
    fi
    sleep 2
done

echo 'error: timed out waiting for Threading to close' >&2
exit 2
