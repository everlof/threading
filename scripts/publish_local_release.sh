#!/usr/bin/env bash
#
# Cuts and publishes one release from the trusted Mac, without allowing this checkout's
# `submodule.recurse=true` to publish any vendored fork and without racing the tag-triggered
# GitHub Actions publisher.
#
# Usage:
#   scripts/publish_local_release.sh v0.1.0
#   scripts/publish_local_release.sh beta-v0.1.90
#
# This is intentionally the whole outer-repository choreography: validate the local signing
# material and remote allocation, run the complete shipping test level and release-quality gate,
# prove that the clean commit which passed them is still checked out, push only `master`,
# create/push one annotated tag, then hand the build/notarize/appcast/release work to the same
# publish_release.sh used by CI. It is safe to rerun after a partial publication.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO="${THREADING_REPO:-everlof/threading}"
readonly RELEASE_BRANCH="master"
readonly RELEASE_WORKFLOW="release.yml"
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-mjukis-notary}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# shellcheck source=scripts/release_tag_policy.sh
source "$ROOT/scripts/release_tag_policy.sh"

[[ $# -eq 1 ]] || fail "usage: scripts/publish_local_release.sh <vX.Y.Z|beta-vX.Y.Z>"
readonly TAG="$1"
DESCRIPTION="$(release_tag_describe "$TAG")" \
    || fail "'$TAG' is not a publishable release tag"
read -r CHANNEL VERSION <<< "$DESCRIPTION"
[[ -n "$CHANNEL" && -n "$VERSION" ]] || fail "could not resolve '$TAG'"

push_outer_ref() {
    # The repository explicitly enables submodule recursion. Both controls are named because
    # this command is the only permitted publication path: a future config change or Git default
    # must not turn an outer release into a push of LabelMorph or ThinkingOrbs.
    THREADING_SKIP_TESTS=1 git -C "$ROOT" -c submodule.recurse=false push \
        --recurse-submodules=no origin "$1"
}

remote_ref_commit() {
    git -C "$ROOT" ls-remote "$@" | awk 'NR == 1 { print $1 }'
}

active_release_run_count() {
    local total=0 status count
    for status in queued in_progress requested waiting pending; do
        count="$(gh api \
            "repos/$REPO/actions/workflows/$RELEASE_WORKFLOW/runs?status=$status&per_page=1" \
            --jq .total_count)" || return 1
        [[ "$count" =~ ^[0-9]+$ ]] || return 1
        total=$((total + count))
    done
    printf '%s\n' "$total"
}

assert_release_snapshot() {
    local current_commit
    current_commit="$(git -C "$ROOT" rev-parse HEAD)"
    [[ "$current_commit" == "$HEAD_COMMIT" ]] \
        || fail "HEAD moved from tested commit $HEAD_COMMIT to $current_commit"
    [[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]] \
        || fail "the worktree changed after release validation; commit and rerun"
}

assert_release_credentials() {
    local current_signing_key

    security find-identity -v -p codesigning \
        | grep -q 'Developer ID Application.*(SMQ3E8Y57T)' \
        || fail "no Developer ID Application certificate for team SMQ3E8Y57T"
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool profile '$NOTARY_PROFILE' is unavailable"
    current_signing_key="$("$sparkle_bin/generate_keys" -p --account "${THREADING_SPARKLE_ACCOUNT:-mjukis-threading}" 2>/dev/null)" \
        || fail "the Threading Sparkle private key is unavailable"
    [[ "$shipped_key" == "$current_signing_key" ]] \
        || fail "the Sparkle private key does not match the public key shipped by the app"
}

workflow_was_disabled=0
restore_release_workflow() {
    [[ $workflow_was_disabled -eq 1 ]] || return 0
    say "Re-enabling the tag release workflow"
    if ! gh workflow enable "$RELEASE_WORKFLOW" --repo "$REPO"; then
        printf '\033[31merror: could not re-enable %s; run: gh workflow enable %s --repo %s\033[0m\n' \
            "$RELEASE_WORKFLOW" "$RELEASE_WORKFLOW" "$REPO" >&2
        return 1
    fi
    workflow_was_disabled=0
}
trap 'restore_release_workflow || true' EXIT

# MARK: - Local and remote preflight

say "Checking the release checkout"
[[ "$(git -C "$ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$RELEASE_BRANCH" ]] \
    || fail "releases must be cut from the $RELEASE_BRANCH branch"
[[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]] \
    || fail "the worktree must be completely clean, including untracked files and submodules"

origin_url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
origin_without_suffix="${origin_url%.git}"
case "$origin_without_suffix" in
    "git@github.com:$REPO"|"https://github.com/$REPO"|"ssh://git@github.com/$REPO") ;;
    *) fail "origin is '$origin_url', not the expected GitHub repository $REPO" ;;
esac

command -v gh >/dev/null || fail "the gh CLI is required"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in — run: gh auth login"
gh repo view "$REPO" >/dev/null 2>&1 || fail "cannot reach github.com/$REPO"

git -C "$ROOT" -c submodule.recurse=false fetch --no-recurse-submodules --no-tags \
    origin "+refs/heads/$RELEASE_BRANCH:refs/remotes/origin/$RELEASE_BRANCH"
readonly HEAD_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
remote_branch_commit="$(remote_ref_commit --heads origin "refs/heads/$RELEASE_BRANCH")"
[[ -n "$remote_branch_commit" ]] || fail "origin has no $RELEASE_BRANCH branch"
git -C "$ROOT" merge-base --is-ancestor "$remote_branch_commit" "$HEAD_COMMIT" \
    || fail "local $RELEASE_BRANCH is not a fast-forward of origin/$RELEASE_BRANCH"

# More than one release tag on the same commit makes `git describe --exact-match` ambiguous,
# and publish_release.sh must never guess which audience or version it is building for.
while IFS= read -r head_tag; do
    [[ "$head_tag" == "$TAG" ]] && continue
    if release_tag_describe "$head_tag" >/dev/null 2>&1; then
        fail "HEAD already carries the different release tag '$head_tag'"
    fi
done < <(git -C "$ROOT" tag --points-at HEAD)

local_tag_object="$(git -C "$ROOT" rev-parse --verify --quiet "refs/tags/$TAG" 2>/dev/null || true)"
remote_tag_object="$(remote_ref_commit --tags origin "refs/tags/$TAG")"
remote_tag_commit="$(remote_ref_commit --tags origin "refs/tags/$TAG^{}")"

if [[ -n "$remote_tag_object" && -z "$remote_tag_commit" ]]; then
    fail "origin's $TAG is lightweight; releases require an annotated tag"
fi
if [[ -n "$remote_tag_commit" && "$remote_tag_commit" != "$HEAD_COMMIT" ]]; then
    fail "origin's $TAG points at $remote_tag_commit, not HEAD $HEAD_COMMIT"
fi
if [[ -n "$remote_tag_object" && -z "$local_tag_object" ]]; then
    git -C "$ROOT" -c submodule.recurse=false fetch --no-recurse-submodules \
        origin "refs/tags/$TAG:refs/tags/$TAG"
    local_tag_object="$(git -C "$ROOT" rev-parse "refs/tags/$TAG")"
fi
if [[ -n "$local_tag_object" ]]; then
    [[ "$(git -C "$ROOT" cat-file -t "refs/tags/$TAG")" == "tag" ]] \
        || fail "local $TAG is lightweight; releases require an annotated tag"
    [[ "$(git -C "$ROOT" rev-list -n 1 "$TAG")" == "$HEAD_COMMIT" ]] \
        || fail "local $TAG does not point at HEAD"
    if [[ -n "$remote_tag_object" && "$remote_tag_object" != "$local_tag_object" ]]; then
        fail "local and remote $TAG are different annotated tag objects"
    fi
fi

sparkle_bin="${THREADING_SPARKLE_BIN:-}"
if [[ -z "$sparkle_bin" ]]; then
    sparkle_bin="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Threading-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
fi
[[ -x "$sparkle_bin/generate_keys" ]] \
    || fail "Sparkle's tools are unavailable — build once in Xcode or set THREADING_SPARKLE_BIN"
shipped_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Sources/Threading/Resources/Info.plist")" \
    || fail "Info.plist carries no Sparkle public key"
say "Checking release credentials"
assert_release_credentials

notes="$(release_notes_for_version "$VERSION" "$ROOT/CHANGELOG.md")"
[[ -n "${notes//[[:space:]]/}" ]] || fail "CHANGELOG.md has no release notes for $VERSION"

published="$(gh release list --repo "$REPO" --limit 200 \
    --json tagName,isPrerelease,isDraft \
    --jq '.[] | select(.isDraft | not) | "\(.isPrerelease)\t\(.tagName)"')" \
    || fail "could not list published releases"
release_version_is_publishable "$CHANNEL" "$VERSION" "$TAG" <<< "$published" \
    || fail "$TAG collides with an already-published Sparkle version"

# MARK: - Test, push, and publish

say "Running the complete shipping test level"
"$ROOT/scripts/test.sh" all

# `release.sh` normally runs this gate immediately before archive. The local driver must run it
# before publishing either immutable ref: a lint, package, service, strict-concurrency, or iOS
# failure cannot be allowed to leave a tag pointing at a commit that was never releasable.
say "Running the release quality gate before publishing refs"
"$ROOT/scripts/ci.sh"

# Tests are long enough for another local process or chat to move the branch or edit the shared
# checkout. Never substitute whatever HEAD happens to mean now for the commit preflighted above.
assert_release_snapshot

# Keychain items can be removed, locked, or replaced during the long test run. Recheck every
# release credential immediately before the first public ref moves, and prove that this check did
# not itself race a checkout change.
say "Rechecking release credentials before publishing refs"
assert_release_credentials
assert_release_snapshot

if [[ "$remote_branch_commit" != "$HEAD_COMMIT" ]]; then
    say "Pushing only the outer $RELEASE_BRANCH ref"
    push_outer_ref "$HEAD_COMMIT:refs/heads/$RELEASE_BRANCH"
    [[ "$(remote_ref_commit --heads origin "refs/heads/$RELEASE_BRANCH")" == "$HEAD_COMMIT" ]] \
        || fail "origin/$RELEASE_BRANCH did not advance to HEAD"
else
    echo "  origin/$RELEASE_BRANCH already points at HEAD"
fi

if [[ -z "$local_tag_object" ]]; then
    say "Creating annotated tag $TAG"
    git -C "$ROOT" tag -a "$TAG" -m "Threading $VERSION" "$HEAD_COMMIT"
    local_tag_object="$(git -C "$ROOT" rev-parse "refs/tags/$TAG")"
fi

# A pushed tag normally starts release.yml. A local publish must be its only writer: two
# notarized builds have different signed bytes, so racing uploads can pair one zip with the
# other build's appcast signature. Disable only for this critical section and restore its prior
# state on every normal or failing exit.
workflow_state="$(gh api "repos/$REPO/actions/workflows/$RELEASE_WORKFLOW" --jq .state)" \
    || fail "could not read the $RELEASE_WORKFLOW state"
active_runs="$(active_release_run_count)" \
    || fail "could not determine whether $RELEASE_WORKFLOW already has a writer"
[[ "$active_runs" == "0" ]] \
    || fail "$RELEASE_WORKFLOW already has $active_runs active run(s); refusing two release writers"
case "$workflow_state" in
    active)
        say "Temporarily disabling the tag release workflow"
        gh workflow disable "$RELEASE_WORKFLOW" --repo "$REPO"
        workflow_was_disabled=1
        [[ "$(gh api "repos/$REPO/actions/workflows/$RELEASE_WORKFLOW" --jq .state)" == "disabled_manually" ]] \
            || fail "$RELEASE_WORKFLOW did not become disabled"
        active_runs="$(active_release_run_count)" \
            || fail "could not verify the disabled workflow has no active writer"
        [[ "$active_runs" == "0" ]] \
            || fail "$RELEASE_WORKFLOW started a run while it was being disabled"
        ;;
    disabled_manually) ;;
    *) fail "$RELEASE_WORKFLOW is in unexpected state '$workflow_state'" ;;
esac

if [[ -z "$remote_tag_object" ]]; then
    say "Pushing only the annotated tag $TAG"
    push_outer_ref "refs/tags/$TAG:refs/tags/$TAG"
    remote_tag_object="$(remote_ref_commit --tags origin "refs/tags/$TAG")"
    remote_tag_commit="$(remote_ref_commit --tags origin "refs/tags/$TAG^{}")"
fi
[[ "$remote_tag_object" == "$local_tag_object" && "$remote_tag_commit" == "$HEAD_COMMIT" ]] \
    || fail "origin's annotated $TAG was not published exactly at HEAD"

# The exact commit already passed release.sh's own quality gate above, before either ref moved.
# Scope the escape hatch to this one child process; release.sh remains fail-closed when invoked
# directly, and its clean-tree/tag/build checks still run here.
assert_release_snapshot
THREADING_SKIP_RELEASE_CHECKS=1 "$ROOT/scripts/publish_release.sh"

restore_release_workflow \
    || fail "the release was published, but $RELEASE_WORKFLOW could not be re-enabled"
trap - EXIT

say "Local release complete"
echo "  https://github.com/$REPO/releases/tag/$TAG"
