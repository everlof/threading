#!/usr/bin/env bash
#
# Keeps /Applications/Threading.app on the tip of master.
#
# Every commit that lands on master — yours, or one from an agent working in this tree — builds a
# Developer ID signed Release and installs it. A build still running when the next commit arrives
# is cancelled and restarted on the newer commit, so the installed copy converges on master's tip
# rather than on whichever build happened to finish last.
#
# Usage:
#   scripts/autoinstall.sh trigger   # what the post-commit / post-merge hooks call
#   scripts/autoinstall.sh status    # what is installed, what is building, what last failed
#   scripts/autoinstall.sh log       # follow the build that is running now
#   scripts/autoinstall.sh off       # pause it without uninstalling the hooks
#   scripts/autoinstall.sh on        # resume
#   scripts/autoinstall.sh run       # the builder loop itself, in the foreground; the trigger
#                                    # spawns this detached, and running it by hand forces a build
#
# **Why a second checkout.** This tree is shared: several agents edit it at once and master moves
# under them, so a build started here would compile whatever half-written state the working tree
# happened to be in, and would fight the developer's own builds over DerivedData. The builder
# works in ~/.threading-autoinstall/checkout, a --local clone reset to the exact commit that
# triggered it, with its own DerivedData. A build is therefore of a commit, not of a moment.
#
# **Why Release, signed with Developer ID.** The installed app's designated requirement is
# `identifier "codes.threading"` and a Developer ID leaf for team SMQ3E8Y57T. TCC keys the
# Accessibility, notification and screen-recording grants to that requirement, so signing every
# build with the same identity means the grants survive the swap. An ad-hoc or development
# signature would be a different app to macOS and would ask for all of them again, every commit.
#
# **Why an entitlement is dropped.** The app's entitlements ask for Sign In with Apple, which
# manual signing can only grant through a provisioning profile, and no codes.threading profile
# exists on this machine (`xcodebuild` fails outright: "requires a provisioning profile with the
# Sign In with Apple feature"). Every `com.apple.developer.*` key is stripped for this build —
# they are the profile-backed ones — and the two hardened-runtime relaxations are kept. That is
# the same shape release.sh's manual-signing fallback has been installing all along; the copy in
# /Applications carries exactly those two entitlements today.
#
# **Why it never quits the running app.** Threading hosts live agent sessions in PTYs, and any
# agent committing to master would otherwise stop your session mid-turn. The install goes in
# underneath the running copy, which keeps running the build it launched with until you quit and
# reopen it. scripts/install-app.sh --leave-running does the careful part.

set -euo pipefail

# A git hook runs with GIT_DIR, GIT_INDEX_FILE and friends set to the repository that invoked it.
# They would follow this script into the build checkout and quietly redirect every `git -C` below
# at the wrong repository, so the first thing it does is forget them.
while IFS='=' read -r variable _; do
    case "$variable" in
        GIT_*) unset "$variable" ;;
    esac
done < <(env)

# MARK: - Constants

readonly SCHEME="Threading"
readonly BRANCH="master"
readonly SIGNING_IDENTITY="Developer ID Application: MJUKIS AB (SMQ3E8Y57T)"
readonly INSTALL_DIR="/Applications"
readonly ENTITLEMENTS_IN_REPO="Sources/Threading/Resources/Threading.entitlements"
readonly HISTORY_KEPT_LINES=200
readonly BUILDER_LOG_KEPT_LINES=2000

readonly SOURCE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SELF="$SOURCE_REPO/scripts/autoinstall.sh"

readonly HOME_DIR="${THREADING_AUTOINSTALL_HOME:-$HOME/.threading-autoinstall}"
readonly CHECKOUT="$HOME_DIR/checkout"
readonly DERIVED="$HOME_DIR/derived"
readonly STATE="$HOME_DIR/state"
readonly BUILD_LOG="$HOME_DIR/build.log"
readonly BUILDER_LOG="$HOME_DIR/builder.log"
readonly HISTORY="$HOME_DIR/history.log"
readonly ENTITLEMENTS="$HOME_DIR/local.entitlements"
readonly PRODUCT="$DERIVED/Build/Products/Release/$SCHEME.app"

readonly LOCK="$STATE/builder.lock"
readonly BUILDER_PID_FILE="$STATE/builder.pid"
readonly BUILD_GROUP_FILE="$STATE/build.pgid"
readonly BUILDING_SHA_FILE="$STATE/building.sha"
readonly INSTALLED_SHA_FILE="$STATE/installed.sha"
readonly DISABLED_FILE="$STATE/disabled"

# MARK: - Small helpers

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

log_line() { printf '%s  %s\n' "$(timestamp)" "$*"; }

record() {
    mkdir -p "$HOME_DIR"
    printf '%s  %s\n' "$(timestamp)" "$*" >> "$HISTORY"
    # Bounded rather than rotated: this is a breadcrumb trail, and the interesting end is the new
    # one. Written to a sibling and moved so a reader never sees a half-trimmed file.
    if [[ "$(wc -l < "$HISTORY")" -gt $(( HISTORY_KEPT_LINES * 2 )) ]]; then
        tail -n "$HISTORY_KEPT_LINES" "$HISTORY" > "$HISTORY.trimmed" && mv "$HISTORY.trimmed" "$HISTORY"
    fi
}

# Notifications go through osascript rather than terminal-notifier, which is installed but lives
# in a gem bin directory that a git hook's PATH does not have. Arguments are passed to the script
# rather than interpolated into it, so a commit subject with a quote in it cannot break the call.
notify() {
    osascript - "$1" "$2" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

short() { printf '%.10s' "$1"; }

subject_of() {
    git -C "$SOURCE_REPO" log -1 --format=%s "$1" 2>/dev/null || echo "(unknown commit)"
}

source_tip() { git -C "$SOURCE_REPO" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true; }

# ps rather than pgrep for the reason spelled out in install-app.sh: a sandboxed shell cannot read
# another process's argv, and a git hook fired by an agent's commit is one.
app_is_running() {
    local executable="$INSTALL_DIR/$SCHEME.app/Contents/MacOS/$SCHEME"
    local pid path
    while read -r pid path; do
        if [[ "$path" == "$executable" ]]; then
            return 0
        fi
    done < <(ps -Ao pid=,comm=)
    return 1
}

builder_alive() {
    local pid
    pid="$(cat "$BUILDER_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# MARK: - Trigger
#
# Called from the post-commit and post-merge hooks, so it has two hard requirements: it returns
# immediately, and it cannot fail the git command that ran it.

cancel_running_build() {
    local group
    group="$(cat "$BUILD_GROUP_FILE" 2>/dev/null || true)"
    [[ -n "$group" ]] || return 0
    # Negative pid: the whole process group. xcodebuild is started under job control precisely so
    # it has a group of its own, and killing the group takes its swift-frontend and clang children
    # with it. The builder itself is in a different group and stays alive to start the next round.
    kill -TERM "-$group" 2>/dev/null || true
    record "cancelled the build of $(short "$(cat "$BUILDING_SHA_FILE" 2>/dev/null || echo '?')") — master moved"
}

spawn_builder() {
    mkdir -p "$HOME_DIR" "$STATE"
    # `set -m` puts the builder in a process group of its own, so a Ctrl-C in the terminal that
    # made the commit does not reach it, and nohup detaches it from that terminal's lifetime.
    set -m
    nohup "$SELF" run >>"$BUILDER_LOG" 2>&1 </dev/null &
    set +m
    disown 2>/dev/null || true
}

trigger() {
    if [[ -e "$DISABLED_FILE" ]]; then
        return 0
    fi

    # Only master, and only from the main working tree. A linked worktree — every managed
    # workspace is one — has a .git *file*, so the hook that delegates here is never installed
    # there; the branch check is the second lock on the same door.
    local branch
    branch="$(git -C "$SOURCE_REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [[ "$branch" == "$BRANCH" ]] || return 0

    mkdir -p "$STATE"
    if builder_alive; then
        # A build already in flight is only worth cancelling if it is building something master
        # has moved past. If the builder is between rounds there is no group to signal, and it
        # re-reads master's tip on its own before starting the next one.
        local building
        building="$(cat "$BUILDING_SHA_FILE" 2>/dev/null || true)"
        [[ "$building" == "$(source_tip)" ]] || cancel_running_build
    else
        spawn_builder
    fi
    return 0
}

# MARK: - The build checkout

ensure_checkout() {
    if [[ -d "$CHECKOUT/.git" ]]; then
        return 0
    fi
    log_line "creating the build checkout at $CHECKOUT"
    mkdir -p "$HOME_DIR"
    # --local hardlinks the object store instead of copying it, so this costs a checkout of the
    # working tree and almost nothing for the history.
    git clone --local "$SOURCE_REPO" "$CHECKOUT"
    git -C "$CHECKOUT" submodule update --init --recursive
}

# Every step states its own failure, because `set -e` is suspended inside a function the caller
# tests — without these, a failed fetch would fall through to a reset onto a commit that is not
# there yet, and the round would build the wrong tree while reporting nothing.
prepare_checkout() {
    local sha="$1"
    git -C "$CHECKOUT" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || return 1
    git -C "$CHECKOUT" reset --hard --quiet "$sha" || return 1
    # -fd, deliberately not -fdx: it clears files a previous commit left behind, while leaving the
    # ignored build products that make the next compile incremental.
    git -C "$CHECKOUT" clean -fdq || return 1
    git -C "$CHECKOUT" submodule sync --recursive --quiet || return 1
    git -C "$CHECKOUT" submodule update --init --recursive --quiet || return 1
}

# Checkout and entitlements together, so the loop can treat "could not get ready to build" the
# same way it treats a failed build: reported once, out loud. A commit that deletes or breaks the
# entitlements file used to kill the builder here with a Python traceback and nothing else.
prepare_round() {
    local sha="$1" dropped
    prepare_checkout "$sha" || return 1
    dropped="$(derive_entitlements)" || return 1
    if [[ -n "$dropped" ]]; then
        log_line "signing without profile-backed entitlements: $dropped"
    fi
    return 0
}

# Derived from the repository's own entitlements on every build rather than kept as a second copy
# in the repository, so it cannot drift: whatever the app asks for, this asks for too, minus the
# keys that need a provisioning profile.
derive_entitlements() {
    python3 - "$CHECKOUT/$ENTITLEMENTS_IN_REPO" "$ENTITLEMENTS" <<'PYTHON'
import plistlib
import sys

source, destination = sys.argv[1], sys.argv[2]
with open(source, "rb") as handle:
    entitlements = plistlib.load(handle)

# com.apple.developer.* is the profile-backed family; com.apple.security.* is not. Dropping by
# prefix means an entitlement added to the app later is handled the same way without an edit here.
dropped = sorted(key for key in entitlements if key.startswith("com.apple.developer."))
for key in dropped:
    del entitlements[key]

with open(destination, "wb") as handle:
    plistlib.dump(entitlements, handle)

print(" ".join(dropped))
PYTHON
}

# MARK: - Build and install

# ONLY_ACTIVE_ARCH: this build is for one machine, so it does not need the second slice a release
# does. CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: Xcode adds get-task-allow to a locally built Release
# — release.sh's header says so — and an app you leave running all day should not be one any
# process running as you can attach a debugger to and read the memory of.
build_the_checkout() {
    local status=0
    : > "$BUILD_LOG"
    cd "$CHECKOUT"

    set -m
    xcodebuild \
        -project "$CHECKOUT/$SCHEME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED" \
        ONLY_ACTIVE_ARCH=YES \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        build >>"$BUILD_LOG" 2>&1 &
    local build_pid=$!
    set +m

    # With job control on, the background job's pid is also its process group id, which is what
    # the trigger signals to cancel it.
    echo "$build_pid" > "$BUILD_GROUP_FILE"
    wait "$build_pid" || status=$?
    rm -f "$BUILD_GROUP_FILE"
    return "$status"
}

install_the_build() {
    # The installer next to this script, not the one in the checkout: they are a matched pair, and
    # the checkout is at an arbitrary commit that may predate --leave-running.
    "$SOURCE_REPO/scripts/install-app.sh" \
        --app "$PRODUCT" \
        --to "$INSTALL_DIR" \
        --leave-running >>"$BUILD_LOG" 2>&1
}

# MARK: - The builder loop

release_lock() {
    rm -rf "$LOCK"
    rm -f "$BUILDER_PID_FILE" "$BUILD_GROUP_FILE" "$BUILDING_SHA_FILE"
}

acquire_lock() {
    mkdir -p "$STATE"
    mkdir "$LOCK" 2>/dev/null && return 0
    builder_alive && return 1
    # The holder is gone; the directory it left behind is not a reason to never build again.
    log_line "clearing a lock left by a builder that is no longer running"
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null
}

run_builder() {
    acquire_lock || { log_line "another builder holds the lock — nothing to do"; return 0; }
    echo $$ > "$BUILDER_PID_FILE"
    trap release_lock EXIT

    if [[ -f "$BUILDER_LOG" && "$(wc -l < "$BUILDER_LOG")" -gt $(( BUILDER_LOG_KEPT_LINES * 2 )) ]]; then
        tail -n "$BUILDER_LOG_KEPT_LINES" "$BUILDER_LOG" > "$BUILDER_LOG.trimmed"
        mv "$BUILDER_LOG.trimmed" "$BUILDER_LOG"
    fi

    if ! ensure_checkout; then
        log_line "could not create the build checkout at $CHECKOUT — see above"
        record "FAILED to create the build checkout"
        notify "Threading auto-install failed" "could not create the build checkout"
        return 0
    fi

    while :; do
        local sha subject status=0
        sha="$(source_tip)"
        if [[ -z "$sha" ]]; then
            log_line "no $BRANCH in $SOURCE_REPO — stopping"
            return 0
        fi
        subject="$(subject_of "$sha")"
        echo "$sha" > "$BUILDING_SHA_FILE"

        log_line "building $(short "$sha") $subject"
        record "building $(short "$sha") $subject"

        if ! prepare_round "$sha"; then
            if [[ "$(source_tip)" != "$sha" ]]; then
                log_line "checkout of $(short "$sha") stopped; master has moved — starting again"
                continue
            fi
            log_line "could not get ready to build $(short "$sha") — see above"
            record "FAILED to prepare $(short "$sha") $subject"
            notify "Threading auto-install failed" "could not check out $(short "$sha") $subject"
            return 0
        fi

        build_the_checkout || status=$?
        if [[ $status -ne 0 ]]; then
            if [[ "$(source_tip)" != "$sha" ]]; then
                log_line "build of $(short "$sha") stopped; master has moved — starting again"
                continue
            fi
            log_line "build of $(short "$sha") failed (exit $status) — see $BUILD_LOG"
            record "FAILED  $(short "$sha") $subject (exit $status)"
            notify "Threading auto-install failed" "$(short "$sha") $subject — see scripts/autoinstall.sh log"
            return 0
        fi

        local was_running=1
        app_is_running || was_running=0

        if ! install_the_build; then
            log_line "install of $(short "$sha") failed — see $BUILD_LOG"
            record "FAILED to install $(short "$sha") $subject"
            notify "Threading auto-install failed" "built $(short "$sha") but could not install it"
            return 0
        fi

        echo "$sha" > "$INSTALLED_SHA_FILE"
        log_line "installed $(short "$sha") $subject"
        record "installed $(short "$sha") $subject"
        if [[ $was_running -eq 1 ]]; then
            notify "Threading updated in /Applications" "$subject — relaunch to pick it up"
        else
            notify "Threading updated in /Applications" "$subject"
        fi

        if [[ "$(source_tip)" == "$sha" ]]; then
            break
        fi
        log_line "master moved while installing — building again"
    done
    return 0
}

# MARK: - Status

report_status() {
    local tip installed building
    tip="$(source_tip)"
    installed="$(cat "$INSTALLED_SHA_FILE" 2>/dev/null || true)"
    building="$(cat "$BUILDING_SHA_FILE" 2>/dev/null || true)"

    printf '\033[1mThreading auto-install\033[0m\n'
    if [[ -e "$DISABLED_FILE" ]]; then
        printf '  state:      paused (scripts/autoinstall.sh on)\n'
    elif builder_alive; then
        printf '  state:      building %s %s\n' "$(short "$building")" "$(subject_of "$building")"
    else
        printf '  state:      idle\n'
    fi

    printf '  master tip: %s %s\n' "$(short "$tip")" "$(subject_of "$tip")"
    if [[ -n "$installed" ]]; then
        printf '  installed:  %s %s%s\n' "$(short "$installed")" "$(subject_of "$installed")" \
            "$([[ "$installed" == "$tip" ]] && echo "" || echo "   (behind master)")"
    else
        printf '  installed:  nothing yet\n'
    fi

    if [[ -d "$INSTALL_DIR/$SCHEME.app" ]]; then
        # The mtime is the build product's, which ditto preserves: it says when this bundle was
        # built, not when it was copied here, and that is the more useful of the two.
        printf '  bundle:     %s, built %s\n' \
            "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
                "$INSTALL_DIR/$SCHEME.app/Contents/Info.plist" 2>/dev/null || echo '?')" \
            "$(date -r "$INSTALL_DIR/$SCHEME.app" "+%Y-%m-%d %H:%M" 2>/dev/null || echo '?')"
    fi
    if app_is_running; then
        printf '  running:    yes — it stays on its launched build until you reopen it\n'
    fi

    printf '  disk:       %s\n' "$(du -sh "$HOME_DIR" 2>/dev/null | cut -f1)"
    printf '  logs:       %s\n' "$BUILD_LOG"

    if [[ -f "$HISTORY" ]]; then
        printf '\n\033[1mRecent\033[0m\n'
        tail -n 8 "$HISTORY" | sed 's/^/  /'
    fi
}

# MARK: - Entry point

case "${1:-status}" in
    trigger) trigger ;;
    run)     run_builder ;;
    status)  report_status ;;
    log)     tail -f "$BUILD_LOG" ;;
    off)     mkdir -p "$STATE"; touch "$DISABLED_FILE"; echo "Auto-install paused." ;;
    on)      rm -f "$DISABLED_FILE"; echo "Auto-install resumed." ;;
    *)
        printf 'usage: %s {trigger|run|status|log|off|on}\n' "$(basename "$0")" >&2
        exit 2
        ;;
esac
