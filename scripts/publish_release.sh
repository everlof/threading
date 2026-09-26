#!/usr/bin/env bash
#
# Publishes a tagged Threading release: builds and notarizes through scripts/release.sh,
# generates the signed appcast through scripts/generate_appcast.sh, and uploads both to GitHub.
#
# The tag says which channel this is — `v0.2.0` is a stable release, `beta-v0.1.9` a beta. See
# scripts/release_tag_policy.sh for the grammar and for why a beta's version has to sit strictly
# below the stable it precedes.
#
# ## Where each artefact goes
#
# The zip goes on the release for its own tag; a beta's release is marked prerelease.
#
# The appcast goes on the newest *stable* release, always. Every shipped copy resolves
# SUFeedURL to https://github.com/everlof/threading/releases/latest/download/appcast.xml, that
# URL cannot move without stranding every installed app, and a prerelease never becomes
# `latest`. A dedicated "feed" release would have to *be* latest to serve it, which would point
# the repository's human-facing Latest at an XML file. Clobbering a stable release's appcast
# asset is already how a second stable release works, and the feed is EdDSA-signed, so a
# tampered one is rejected rather than installed.
#
# This script never pushes. `submodule.recurse` is true in this repo, so a push from here
# recurses into the Packages/Vendor/LabelMorph and Packages/Vendor/ThinkingOrbs forks and
# publishes them (see CLAUDE.md); the tag
# is pushed by hand, and this script only verifies the remote already has it, exactly where
# HEAD is. Run:
#   git tag -a v0.2.0 -m "Threading 0.2.0"
#   git push origin v0.2.0        # deliberately by hand, never from a script
#   scripts/publish_release.sh
#
# or, for a beta of the 0.2.0 that follows it:
#   git tag -a beta-v0.1.90 -m "Threading 0.1.90 beta"
#   git push origin beta-v0.1.90
#   scripts/publish_release.sh
#
# Environment: THREADING_REPO (default everlof/threading), NOTARY_PROFILE, and everything
# scripts/generate_appcast.sh reads.

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="$ROOT/build/release"
readonly REPO="${THREADING_REPO:-everlof/threading}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# The tag grammar and the version ordering, in one place a test can run. See
# scripts/tests/test_release_tag_policy.py.
# shellcheck source=scripts/release_tag_policy.sh
source "$ROOT/scripts/release_tag_policy.sh"

# The stable feed URL every shipped copy resolves. Named once: it is both what this script
# seeds from and the reason the appcast always lands on the newest stable release.
readonly FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

# MARK: - Preflight

say "Preflight"
command -v gh >/dev/null || fail "the gh CLI is required to publish"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in — run: gh auth login"
gh repo view "$REPO" >/dev/null 2>&1 \
    || fail "cannot reach github.com/$REPO — check THREADING_REPO and your access"

git -C "$ROOT" remote get-url origin >/dev/null 2>&1 \
    || fail "this checkout has no 'origin' remote, so the tag checks below cannot run — add one first"

# The clean-tree requirement is stricter than release.sh's own (which ignores untracked
# files): an untracked file can still change what the archive contains through a synchronized
# folder, and a published artefact must correspond to reviewable source.
[[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ]] \
    || fail "the worktree must be completely clean, including untracked files"

say "Resolving the tag"
TAG="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ -n "$TAG" ]] || fail "HEAD carries no tag — tag it first (git tag -a v0.1.0 -m ...)"
DESCRIPTION="$(release_tag_describe "$TAG")" \
    || fail "HEAD's tag cannot be published — see scripts/release_tag_policy.sh"
read -r CHANNEL VERSION <<< "$DESCRIPTION"
[[ -n "$CHANNEL" && -n "$VERSION" ]] || fail "could not read a channel and version from '$TAG'"
echo "  $TAG  ($CHANNEL $VERSION)"

# Annotated, because a lightweight tag is one keystroke and a release deserves a recorded
# author and date; at HEAD and on the remote, because the artefact must be reproducible from
# what the world can see.
[[ "$(git -C "$ROOT" cat-file -t "$TAG")" == "tag" ]] \
    || fail "$TAG must be an annotated tag (git tag -a)"
[[ "$(git -C "$ROOT" rev-list -n 1 "$TAG")" == "$(git -C "$ROOT" rev-parse HEAD)" ]] \
    || fail "$TAG does not point at HEAD"
remote_commit="$(git -C "$ROOT" ls-remote --tags origin "refs/tags/$TAG^{}" | awk 'NR == 1 { print $1 }')"
if [[ -z "$remote_commit" || "$remote_commit" != "$(git -C "$ROOT" rev-parse HEAD)" ]]; then
    fail "the remote's $TAG does not point at HEAD — push the tag by hand first (git push origin $TAG)"
fi

# MARK: - Version allocation
#
# The rule and its two failure modes live in scripts/release_tag_policy.sh, where a test can
# run them. This half only fetches what is already served.

say "Checking the version against what is already published"
published="$(gh release list --repo "$REPO" --limit 200 \
    --json tagName,isPrerelease,isDraft \
    --jq '.[] | select(.isDraft | not) | "\(.isPrerelease)\t\(.tagName)"')" \
    || fail "could not list the published releases of $REPO"

release_version_is_publishable "$CHANNEL" "$VERSION" "$TAG" <<< "$published" \
    || fail "$TAG cannot be published at this version — see the reason above"

# MARK: - Build, notarize, appcast

say "Building the notarized release ($CHANNEL)"
THREADING_VERSION="$VERSION" "$ROOT/scripts/release.sh" --notarize --channel "$CHANNEL"

# The enclosure URL is built from the tag, not from the version: a beta's zip lives under
# releases/download/beta-v0.1.9/, and defaulting to v0.1.9 would publish a feed whose every
# download 404s.
#
# Channel: only a prerelease is tagged. An untagged item is what "stable" means to Sparkle.
#
# Phased rollout: the 86400s default staggers a public release over days, which is right when
# the audience is everyone and wrong when it is a handful of testers waiting for the build.
#
# Seed: extend the feed already published rather than replacing it, so a lagging stable user is
# still offered the stable release when the newest item is a beta.
say "Generating the appcast"
appcast_args=(--seed "$FEED_URL")
appcast_rollout="${THREADING_SPARKLE_PHASED_ROLLOUT_INTERVAL:-}"
if [[ "$CHANNEL" != "release" ]]; then
    appcast_args+=(--channel "$CHANNEL")
    appcast_rollout="${appcast_rollout:-0}"
fi
appcast_env=(
    THREADING_VERSION="$VERSION"
    THREADING_RELEASE_TAG="$TAG"
    THREADING_SPARKLE_MAXIMUM_VERSIONS="${THREADING_SPARKLE_MAXIMUM_VERSIONS:-5}"
)
[[ -z "$appcast_rollout" ]] \
    || appcast_env+=(THREADING_SPARKLE_PHASED_ROLLOUT_INTERVAL="$appcast_rollout")
env "${appcast_env[@]}" "$ROOT/scripts/generate_appcast.sh" "${appcast_args[@]}"

readonly ZIP="$BUILD_DIR/Threading-$VERSION.zip"
readonly APPCAST="$BUILD_DIR/appcast.xml"
[[ -f "$ZIP" && -f "$APPCAST" ]] || fail "expected artefacts are missing from $BUILD_DIR"

# MARK: - Release notes

NOTES="$(release_notes_for_version "$VERSION" "$ROOT/CHANGELOG.md")"
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "CHANGELOG.md has no section for $VERSION"

# The appcast is not an asset of every release, so the notes must not say it is: a beta's zip
# lives on its own prerelease while the feed that describes it lives on the newest stable.
if [[ "$CHANNEL" == "release" ]]; then
    NOTES="$NOTES

Direct download: \`Threading-$VERSION.zip\` — Developer ID signed, notarized by Apple, and
stapled. Installed copies update themselves through Sparkle from the feed published with this
release."
else
    NOTES="$NOTES

This is a **$CHANNEL** build. Direct download: \`Threading-$VERSION.zip\` — Developer ID signed,
notarized by Apple, and stapled. It updates itself like any other copy; a build downloaded from
here starts out receiving $CHANNEL builds, and Settings ▸ General ▸ Software Updates switches
that back to stable releases at any time."
fi

# MARK: - Publish

# --latest is stated rather than left to GitHub's default, because the next step uploads the
# feed to whatever `latest` resolves to and a race there would publish it where nothing reads it.
release_kind_args=()
if [[ "$CHANNEL" == "release" ]]; then
    release_kind_args+=(--latest)
else
    release_kind_args+=(--prerelease)
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    say "Updating the existing GitHub release $TAG"
    gh release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes "$NOTES" "${release_kind_args[@]}"
else
    say "Creating the GitHub release $TAG"
    gh release create "$TAG" "$ZIP" \
        --repo "$REPO" \
        --title "Threading $VERSION" \
        --notes "$NOTES" \
        "${release_kind_args[@]}"
fi

# MARK: - The feed
#
# Asked of GitHub rather than worked out here: `gh release view` with no tag returns the release
# `releases/latest` resolves to, which is by definition the one serving SUFeedURL. For a stable
# publish that is the release just made; for a beta it is the newest stable, which is why the
# appcast is uploaded in a separate step rather than beside the zip.

say "Publishing the feed"
FEED_TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null || true)"
[[ -n "$FEED_TAG" ]] || fail "the repository has no latest release to carry appcast.xml — publish a stable release before a $CHANNEL one"
if [[ "$(gh release view "$FEED_TAG" --repo "$REPO" --json isPrerelease --jq .isPrerelease)" == "true" ]]; then
    fail "$FEED_TAG is a prerelease, so releases/latest/download would not serve a feed uploaded to it — publish a stable release first"
fi
if [[ "$CHANNEL" == "release" && "$FEED_TAG" != "$TAG" ]]; then
    fail "GitHub still resolves 'latest' to $FEED_TAG rather than $TAG, so the feed would be uploaded where nothing reads it"
fi
gh release upload "$FEED_TAG" "$APPCAST" --repo "$REPO" --clobber
echo "  appcast.xml on $FEED_TAG"

if [[ "$CHANNEL" == "release" ]]; then
    sentry_environment="production"
else
    sentry_environment="$CHANNEL"
fi
say "Recording the Sentry deploy"
"$ROOT/scripts/sentry-release.sh" deploy \
    --release-file "$BUILD_DIR/sentry-release.txt" \
    --environment "$sentry_environment" \
    --url "https://github.com/$REPO/releases/tag/$TAG"

say "Published"
echo "  release:  https://github.com/$REPO/releases/tag/$TAG"
echo "  download: https://github.com/$REPO/releases/download/$TAG/Threading-$VERSION.zip"
echo "  feed:     $FEED_URL"
echo "  sha256:   $(shasum -a 256 "$ZIP" | awk '{print $1}')"
