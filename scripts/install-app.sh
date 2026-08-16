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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) shift; APP="${1:-}" ;;
        --to) shift; DEST_DIR="${1:-}" ;;
        --quit) QUIT_RUNNING=1 ;;
        *) fail "unknown argument '$1'" ;;
    esac
    shift
done

[[ -n "$APP" && -d "$APP" ]] || fail "no app bundle at '$APP'"
[[ -d "$DEST_DIR" ]] || fail "no such directory: $DEST_DIR"
[[ -w "$DEST_DIR" ]] || fail "$DEST_DIR is not writable by $(whoami)"

readonly DEST="$DEST_DIR/$SCHEME.app"
readonly STAGE="$DEST_DIR/.$SCHEME.app.incoming"
readonly PREVIOUS="$DEST_DIR/.$SCHEME.app.previous"

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

# Matched unanchored on the destination's own binary path. Anchoring to the exact command line
# is more precise and the wrong trade for a *safety* check: a pattern that fails to match
# silently replaces a running app, while one that matches too eagerly only asks a question. The
# failure modes are not symmetric, so this errs toward asking.
running_pid="$(pgrep -f "$DEST/Contents/MacOS/$SCHEME" || true)"
if [[ -n "$running_pid" ]]; then
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
        pgrep -f "$DEST/Contents/MacOS/$SCHEME" >/dev/null || break
        sleep 0.5
    done
    if pgrep -f "$DEST/Contents/MacOS/$SCHEME" >/dev/null; then
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
ditto "$APP" "$STAGE"

say "Swapping"
if [[ -e "$DEST" ]]; then
    mv "$DEST" "$PREVIOUS"
fi
if ! mv "$STAGE" "$DEST"; then
    # Put the old one back rather than leaving the machine with no app at all.
    [[ -e "$PREVIOUS" ]] && mv "$PREVIOUS" "$DEST"
    fail "could not move the new bundle into place"
fi
rm -rf "$PREVIOUS"

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
echo "  open it with: open -a $SCHEME"
