#!/usr/bin/env bash
#
# Installs a built Threading.app over the one in /Applications.
#
# Its own script rather than a tail on `release.sh` because two build paths need it: the release
# export, and the manual Developer ID build used while Xcode has no account to mint the profile
# `release.sh`'s archive step wants. One installer means one set of answers to "what happens to
# the running app" and "what happens to the old bundle".
#
# Usage:
#   scripts/install-app.sh                          # installs build/release/export/Threading.app
#   scripts/install-app.sh --app <path/to/.app>     # installs a bundle built anywhere
#   scripts/install-app.sh --to ~/Applications      # somewhere other than /Applications
#   scripts/install-app.sh --quit                   # quit a running copy without asking
#   scripts/install-app.sh --leave-running          # install underneath a running copy
#
# **Why not `cp -R`.** `cp -R src dst` copies *into* `dst` when `dst` already exists as a
# directory, so `cp -R Threading.app /Applications/Threading.app` produces
# `/Applications/Threading.app/Threading.app` and leaves the real bundle untouched. The app
# appears not to update, Finder shows a fresh modification date on the folder, and the binary
# inside is the old one. That happened, which is why this script exists.

set -euo pipefail

readonly SCHEME="Threading"
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

APP="$ROOT/build/release/export/$SCHEME.app"
DEST_DIR="/Applications"
QUIT_RUNNING=0
LEAVE_RUNNING=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) shift; APP="${1:-}" ;;
        --to) shift; DEST_DIR="${1:-}" ;;
        --quit) QUIT_RUNNING=1 ;;
        --leave-running) LEAVE_RUNNING=1 ;;
        *) fail "unknown argument '$1'" ;;
    esac
    shift
done

if [[ $QUIT_RUNNING -eq 1 && $LEAVE_RUNNING -eq 1 ]]; then
    fail "--quit and --leave-running ask for opposite things"
fi

[[ -n "$APP" && -d "$APP" ]] || fail "no app bundle at '$APP'"
[[ -d "$DEST_DIR" ]] || fail "no such directory: $DEST_DIR"
[[ -w "$DEST_DIR" ]] || fail "$DEST_DIR is not writable by $(whoami)"

readonly DEST="$DEST_DIR/$SCHEME.app"
readonly STAGE="$DEST_DIR/.$SCHEME.app.incoming"
readonly PREVIOUS="$DEST_DIR/.$SCHEME.app.previous"
readonly PARKED_PREFIX="$DEST_DIR/.$SCHEME.app.parked-"

# Which processes are running the bundle at $1.
#
# `pgrep -f "$DEST/Contents/MacOS/$SCHEME"` was the obvious way to ask and is the wrong one: it
# matches against argv, which a sandboxed shell — any agent's, and so any git hook one of them
# triggers — is not allowed to read. It comes back empty while the app is plainly running, and an
# empty answer here means "nothing is running it, go ahead and replace it". `ps -o comm=` reports
# the kernel's path for the running image and answers correctly in both contexts.
#
# It reports the path the process was *launched* from, which does not follow a later rename. That
# is exactly the question being asked here — "who is using the bundle at this path" — and it is
# why a parked bundle records the pids that were running it rather than being re-tested by path.
running_pids_at() {
    local executable="$1/Contents/MacOS/$SCHEME"
    local pid path
    # if/fi rather than `[[ … ]] && printf`: a non-matching last line would make the loop's final
    # command non-zero, and under `set -e` inside a command substitution that truncates the
    # answer to nothing — which reads here as "the app is not running".
    while read -r pid path; do
        if [[ "$path" == "$executable" ]]; then
            printf '%s\n' "$pid"
        fi
    done < <(ps -Ao pid=,comm=)
    return 0
}

# A bundle moved aside while a process was still running it is not litter: it is the file that
# process reads from. Deleting it is how you get the running app SIGKILLed on its next page fault,
# so an aside bundle is named for the pids that were running it and removed once none of them are.
#
# The pid is checked against a still-running Threading rather than against bare liveness, because
# pids are reused, and a recycled one would otherwise pin 200MB on disk indefinitely.
sweep_parked_bundles() {
    local aside pids pid in_use
    for aside in "$PARKED_PREFIX"*; do
        [[ -d "$aside" ]] || continue
        pids="${aside##*.parked-}"
        in_use=0
        for pid in ${pids//-/ }; do
            if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == *"/$SCHEME.app/Contents/MacOS/$SCHEME" ]]; then
                in_use=1
            fi
        done
        if [[ $in_use -eq 1 ]]; then
            echo "  keeping $(basename "$aside") — pid ${pids//-/, } is still running it"
        else
            rm -rf "$aside"
            echo "  removed $(basename "$aside") — nothing is running it any more"
        fi
    done
    return 0
}

# MARK: - What is being installed

say "Installing"
echo "  from: $APP"
echo "    to: $DEST"

installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "  version: $installed_version ($installed_build)"

# A locally built Release carries `get-task-allow`, which the shipping export does not. It is not
# a reason to refuse — a debuggable build is a perfectly good thing to run yourself — but it is a
# reason to say so, because it is the difference between this and what users get.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
    echo "  note: this build carries get-task-allow (locally built, debuggable — not the shipping shape)"
fi

# MARK: - The running copy
#
# Threading hosts live agent sessions in PTYs, so quitting it is not free: whatever those agents
# were doing stops. That is why this asks rather than killing, and why it never escalates to
# SIGKILL — a forced quit here can lose a turn somebody is in the middle of.

# --leave-running is the other answer to the same problem, and the one an automated install needs:
# the swap below goes in underneath the running process instead of asking it to stop. It costs a
# relaunch before the new build is the one you are using, which is a much smaller price than
# ending a turn somebody is in the middle of.
running_pid="$(running_pids_at "$DEST" | tr '\n' ' ' | sed 's/ *$//')"
if [[ -n "$running_pid" && $LEAVE_RUNNING -eq 1 ]]; then
    echo
    echo "$SCHEME is running (pid $running_pid) and is being left alone. The new build goes in"
    echo "underneath it; the running copy stays on the build it launched with until you reopen it."
elif [[ -n "$running_pid" ]]; then
    if [[ $QUIT_RUNNING -eq 0 ]]; then
        if [[ ! -t 0 ]]; then
            fail "$SCHEME is running (pid $running_pid); re-run with --quit, or quit it yourself"
        fi
        echo
        echo "$SCHEME is running (pid $running_pid). Installing over it means quitting it, which"
        echo "stops every agent session it is hosting."
        read -r -p "Quit it and install? [y/N] " reply
        [[ "$reply" == "y" || "$reply" == "Y" ]] || fail "cancelled"
    fi

    say "Quitting $SCHEME"
    osascript -e "quit app \"$SCHEME\"" || true

    # Politely, and then not at all. Ten seconds is long enough for a normal termination and
    # short enough that a wedged app is reported rather than waited on; killing it is the user's
    # call, not this script's.
    for _ in $(seq 1 20); do
        [[ -z "$(running_pids_at "$DEST")" ]] && break
        sleep 0.5
    done
    if [[ -n "$(running_pids_at "$DEST")" ]]; then
        fail "$SCHEME did not quit — quit it by hand and re-run (this script will not force it)"
    fi
fi

# MARK: - The swap
#
# Staged beside the destination and moved into place, rather than copied over it. Three things
# that buys: the copy either lands whole or not at all, the old bundle survives until the new one
# is in place, and — the one that matters most — the destination is *replaced* rather than merged
# into, so a stale file from an older build cannot survive inside the new bundle.
#
# `ditto` rather than `cp -R`: it is the tool that preserves the symlinks and extended attributes
# a signed bundle depends on, which is the same reason `release.sh` zips with it.

rm -rf "$STAGE" "$PREVIOUS"
say "Staging"
sweep_parked_bundles
ditto "$APP" "$STAGE"

say "Swapping"
aside=""
if [[ -e "$DEST" ]]; then
    # Asked again here rather than reusing the answer from above, because the quit path may have
    # changed it. Nobody running the outgoing bundle means it can simply be deleted once the new
    # one is in place; somebody running it means it is parked under their pids instead. Only one
    # parked bundle can accumulate: the next install finds the destination unheld — its holders
    # are on the parked copy, not on it — and deletes it outright.
    holders="$(running_pids_at "$DEST" | tr '\n' '-' | sed 's/-$//')"
    if [[ -n "$holders" ]]; then
        aside="$PARKED_PREFIX$holders"
        rm -rf "$aside"
    else
        aside="$PREVIOUS"
    fi
    mv "$DEST" "$aside"
fi
if ! mv "$STAGE" "$DEST"; then
    # Put the old one back rather than leaving the machine with no app at all.
    if [[ -n "$aside" && -e "$aside" ]]; then
        mv "$aside" "$DEST"
    fi
    fail "could not move the new bundle into place"
fi
if [[ "$aside" == "$PREVIOUS" ]]; then
    rm -rf "$PREVIOUS"
fi

# MARK: - Prove it took
#
# Every check here exists because its absence is silent. A nested bundle looks like a successful
# install until you notice the app is unchanged; a broken signature looks fine until Gatekeeper
# refuses to launch it; the wrong build number looks fine forever.

say "Verifying the installed copy"

[[ ! -e "$DEST/$SCHEME.app" ]] \
    || fail "there is a nested $SCHEME.app inside $DEST — the install merged instead of replacing"

# Status captured, not piped. `codesign --verify … | tail` reports *tail's* exit code, so the
# check would print a failure and carry on regardless — a verification that cannot fail is
# decoration. The output is still shown; it is the `if` that makes it mean something.
if ! verify_output="$(codesign --verify --strict --verbose=2 "$DEST" 2>&1)"; then
    echo "$verify_output"
    fail "the installed bundle does not pass its own signature check — it will not launch"
fi
echo "$verify_output" | tail -2

dest_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
[[ "$dest_build" == "$installed_build" ]] \
    || fail "installed bundle reports build $dest_build, expected $installed_build"

say "Installed: $SCHEME $installed_version ($installed_build)"
echo "  $DEST"
if [[ "$aside" == "$PARKED_PREFIX"* ]]; then
    echo "  pid ${aside##*.parked-} is still running the previous build — quit and reopen to use this one"
else
    echo "  open it with: open -a $SCHEME"
fi
