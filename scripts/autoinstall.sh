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
# **Why an entitlement is dropped.** Any `com.apple.developer.*` app entitlement needs a
# provisioning profile, which an ordinary local auto-install deliberately does not use. The app's
# plist is therefore derived inside the disposable build checkout with that family removed.
# Helpers keep their own target entitlement files: overriding `CODE_SIGN_ENTITLEMENTS` on the
# xcodebuild command line would replace every helper's declaration and disable their sandboxes.
#
# **Why it never quits or moves the running app.** Threading hosts live agent sessions in PTYs,
# and any agent committing to master would otherwise stop your session mid-turn. A completed build
# waits until Threading quits, then replaces the bundle. Moving the live bundle aside made
# LaunchServices retain that parked copy as a notification target and launch a second instance.

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
readonly PRODUCT="$DERIVED/Build/Products/Release/$SCHEME.app"

readonly LOCK="$STATE/builder.lock"
readonly BUILDER_PID_FILE="$STATE/builder.pid"
readonly BUILD_GROUP_FILE="$STATE/build.pgid"
readonly BUILDING_SHA_FILE="$STATE/building.sha"
readonly WAITING_SHA_FILE="$STATE/waiting-to-install.sha"
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
    point_submodules_at_source
    git -C "$CHECKOUT" submodule update --init --recursive
}

# The vendored packages are our own forks, and a pin that lands on master is routinely a commit
# that exists only in this machine's checkout: committing here deliberately does not push them
# (CLAUDE.md - `submodule.recurse` would publish them to their real GitHub remotes). Fetching a
# submodule from GitHub therefore fails with `upload-pack: not our ref`, and because the object
# never arrives, *every* later commit fails the same way at checkout rather than only the one that
# moved the pin - which is how nine consecutive commits went uninstalled on 2026-08-20.
#
# The superproject is already a --local clone of the working tree, so the fix is to read the
# submodules from that same tree rather than from the network. This still builds the pinned commit:
# `submodule update` checks out the exact recorded sha, and only the objects come from elsewhere.
# It runs after `submodule sync`, which rewrites these same keys back from .gitmodules.
point_submodules_at_source() {
    local key path name source_git_dir
    while read -r key path; do
        name="${key#submodule.}"
        name="${name%.path}"
        source_git_dir="$(git -C "$SOURCE_REPO/$path" rev-parse --absolute-git-dir 2>/dev/null)" || continue
        git -C "$CHECKOUT" config "submodule.$name.url" "$source_git_dir" || return 1
        # An already-initialised submodule fetches through its own remote, which `submodule sync`
        # has just pointed back at GitHub, so the superproject key alone would not be read.
        if [[ -d "$CHECKOUT/.git/modules/$name" ]]; then
            git -C "$CHECKOUT/.git/modules/$name" config remote.origin.url "$source_git_dir" || return 1
        fi
    done < <(git -C "$CHECKOUT" config --file "$CHECKOUT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
    return 0
}

# Every step states its own failure, because `set -e` is suspended inside a function the caller
# tests — without these, a failed fetch would fall through to a reset onto a commit that is not
# there yet, and the round would build the wrong tree while reporting nothing.
prepare_checkout() {
    local sha="$1"
    # The superproject steps must not recurse into the submodules. `submodule.recurse` is true in
    # the developer's configuration, so a bare fetch or reset would fetch every submodule through
    # whatever remote the *previous* round left in `.git/modules/<name>/config` — and when that
    # round was triggered from a linked worktree, the remote is that worktree's own module store,
    # which disappears with the worktree. The 2026-09-02 build of 8c3f9787 failed exactly there,
    # before `sync` and `point_submodules_at_source` below had a chance to repair the remotes.
    # Only the explicit `submodule update` at the end touches the submodules, after both.
    git -C "$CHECKOUT" -c submodule.recurse=false fetch --quiet --recurse-submodules=no origin \
        "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || return 1
    git -C "$CHECKOUT" -c submodule.recurse=false reset --hard --quiet "$sha" || return 1
    # -fd, deliberately not -fdx: it clears files a previous commit left behind, while leaving the
    # ignored build products that make the next compile incremental.
    git -C "$CHECKOUT" clean -fdq || return 1
    git -C "$CHECKOUT" submodule sync --recursive --quiet || return 1
    point_submodules_at_source || return 1
    # The remotes above are local paths, and git refuses the `file` transport for a submodule
    # fetch unless told otherwise — `fatal: transport 'file' not allowed`. The clone had never
    # had to fetch a submodule commit before the round above, so this surfaced only then.
    git -C "$CHECKOUT" -c protocol.file.allow=always \
        submodule update --init --recursive --quiet || return 1
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
    python3 - "$CHECKOUT/$ENTITLEMENTS_IN_REPO" <<'PYTHON'
import plistlib
import sys
from pathlib import Path

source = Path(sys.argv[1])
with source.open("rb") as handle:
    entitlements = plistlib.load(handle)

# com.apple.developer.* is the profile-backed family; com.apple.security.* is not. Dropping by
# prefix means an entitlement added to the app later is handled the same way without an edit here.
dropped = sorted(key for key in entitlements if key.startswith("com.apple.developer."))
for key in dropped:
    del entitlements[key]

temporary = source.with_name(source.name + ".autoinstall")
with temporary.open("wb") as handle:
    plistlib.dump(entitlements, handle)
temporary.replace(source)

print(" ".join(dropped))
PYTHON
}

# MARK: - Build and install

# ARCHS: Threading is arm64-only (docs/architecture/releasing.md, "Apple silicon only"). Saying so
# on the command line reaches the Swift packages too, which do not read the project's ARCHS and
# would otherwise compile a second slice the link discards. (ONLY_ACTIVE_ARCH was tried first and
# did nothing: a generic destination has no active architecture.)
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: Xcode adds get-task-allow to a locally built Release
# — release.sh's header says so — and an app you leave running all day should not be one any
# process running as you can attach a debugger to and read the memory of.
build_the_checkout() {
    local sha="$1" status=0 product_revision helper
    : > "$BUILD_LOG"
    cd "$CHECKOUT"

    set -m
    xcodebuild \
        -project "$CHECKOUT/$SCHEME.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=macOS' \
        -derivedDataPath "$DERIVED" \
        ARCHS=arm64 \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
        PROVISIONING_PROFILE_SPECIFIER="" \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        THREADING_SOURCE_REVISION="$sha" \
        build >>"$BUILD_LOG" 2>&1 &
    local build_pid=$!
    set +m

    # With job control on, the background job's pid is also its process group id, which is what
    # the trigger signals to cancel it.
    echo "$build_pid" > "$BUILD_GROUP_FILE"
    wait "$build_pid" || status=$?
    rm -f "$BUILD_GROUP_FILE"

    if [[ $status -eq 0 ]]; then
        product_revision="$(/usr/libexec/PlistBuddy -c 'Print :ThreadingSourceRevision' \
            "$PRODUCT/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$product_revision" != "$sha" ]]; then
            printf 'error: built product reports source revision %q, expected %q\n' \
                "$product_revision" "$sha" >> "$BUILD_LOG"
            status=1
        fi
    fi
    if [[ $status -eq 0 ]]; then
        helper="$PRODUCT/Contents/Helpers/threading-ptyd"
        if [[ ! -x "$helper" ]]; then
            printf 'error: built product has no executable PTY host at %q\n' \
                "$helper" >> "$BUILD_LOG"
            status=1
        elif ! /usr/bin/strings "$helper" | awk \
            -v expected="<string>${sha}</string>" \
            '$0 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
            printf 'error: PTY host does not embed source revision %q\n' \
                "$sha" >> "$BUILD_LOG"
            status=1
        fi
    fi
    if [[ $status -eq 0 ]] && ! python3 "$SOURCE_REPO/scripts/check_bundle_entitlements.py" \
        --root "$CHECKOUT" "$PRODUCT" >>"$BUILD_LOG" 2>&1; then
        status=1
    fi
    return "$status"
}

install_the_build() {
    # The installer next to this script, not the one in the checkout: they are a matched pair, and
    # the checkout is at an arbitrary older commit.
    "$SOURCE_REPO/scripts/install-app.sh" \
        --app "$PRODUCT" \
        --to "$INSTALL_DIR" >>"$BUILD_LOG" 2>&1
}

# A live bundle stays at its registered URL until its process exits. Apart from avoiding a stale
# LaunchServices record, waiting also means every notification posted by that process still opens
# the process that owns its UNUserNotificationCenter delegate. If master moves while we wait, the
# built product is obsolete and the caller starts a fresh round instead of installing it briefly.
wait_for_install_window() {
    local sha="$1" subject="$2"
    [[ "$(source_tip)" == "$sha" ]] || return 2
    app_is_running || return 0

    echo "$sha" > "$WAITING_SHA_FILE"
    log_line "built $(short "$sha"); waiting for Threading to quit before installing"
    record "ready  $(short "$sha") $subject — waiting for Threading to quit"
    notify "Threading update ready" "$subject — quit Threading to install it"

    while app_is_running; do
        if [[ "$(source_tip)" != "$sha" ]]; then
            rm -f "$WAITING_SHA_FILE"
            return 2
        fi
        sleep 2
    done
    rm -f "$WAITING_SHA_FILE"
    return 0
}

# The app can be reopened during the installer's staging copy. The installer rechecks immediately
# before the swap and refuses rather than parking a newly live bundle; in that narrow race, wait
# again and retry the already-built product.
install_when_available() {
    local sha="$1" subject="$2" status=0
    while :; do
        wait_for_install_window "$sha" "$subject" || status=$?
        if [[ $status -ne 0 ]]; then
            return "$status"
        fi

        if install_the_build; then
            return 0
        fi
        if app_is_running; then
            log_line "Threading reopened while $(short "$sha") was being staged; waiting again"
            status=0
            continue
        fi
        return 1
    done
}

# MARK: - The builder loop

release_lock() {
    rm -rf "$LOCK"
    rm -f "$BUILDER_PID_FILE" "$BUILD_GROUP_FILE" "$BUILDING_SHA_FILE" "$WAITING_SHA_FILE"
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

        build_the_checkout "$sha" || status=$?
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

        local install_status=0
        install_when_available "$sha" "$subject" || install_status=$?
        if [[ $install_status -eq 2 ]]; then
            log_line "master moved while $(short "$sha") waited to install — building again"
            continue
        fi
        if [[ $install_status -ne 0 ]]; then
            log_line "install of $(short "$sha") failed — see $BUILD_LOG"
            record "FAILED to install $(short "$sha") $subject"
            notify "Threading auto-install failed" "built $(short "$sha") but could not install it"
            return 0
        fi

        echo "$sha" > "$INSTALLED_SHA_FILE"
        log_line "installed $(short "$sha") $subject"
        record "installed $(short "$sha") $subject"
        notify "Threading updated in /Applications" "$subject"

        if [[ "$(source_tip)" == "$sha" ]]; then
            break
        fi
        log_line "master moved while installing — building again"
    done
    return 0
}

# MARK: - Status

report_status() {
    local tip installed building waiting
    tip="$(source_tip)"
    installed="$(cat "$INSTALLED_SHA_FILE" 2>/dev/null || true)"
    building="$(cat "$BUILDING_SHA_FILE" 2>/dev/null || true)"
    waiting="$(cat "$WAITING_SHA_FILE" 2>/dev/null || true)"

    printf '\033[1mThreading auto-install\033[0m\n'
    if [[ -e "$DISABLED_FILE" ]]; then
        printf '  state:      paused (scripts/autoinstall.sh on)\n'
    elif builder_alive && [[ -n "$waiting" ]]; then
        printf '  state:      waiting for Threading to quit, then installing %s %s\n' \
            "$(short "$waiting")" "$(subject_of "$waiting")"
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
        # The executable's mtime, not the bundle directory's. ditto preserves both, and a rebuild
        # that relinks and re-signs the binary leaves the directory's mtime on whenever the
        # product folder itself last changed — which is how this line came to say a build was
        # 23 minutes older than the commit it had just installed.
        printf '  bundle:     %s, built %s\n' \
            "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
                "$INSTALL_DIR/$SCHEME.app/Contents/Info.plist" 2>/dev/null || echo '?')" \
            "$(date -r "$INSTALL_DIR/$SCHEME.app/Contents/MacOS/$SCHEME" "+%Y-%m-%d %H:%M" \
                2>/dev/null || echo '?')"
    fi
    if app_is_running; then
        printf '  running:    yes — a ready build waits rather than moving this live bundle\n'
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
