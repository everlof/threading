#!/usr/bin/env bash
#
# Publishes a tagged Threading release: builds and notarizes through scripts/release.sh,
# generates the signed appcast through scripts/generate_appcast.sh, and uploads both to the
# GitHub release for the tag. The stable Sparkle feed URL —
# https://github.com/everlof/threading/releases/latest/download/appcast.xml — resolves to
# whichever release is newest, which is why the appcast is uploaded *beside* each zip.
#
# This script never pushes. `submodule.recurse` is true in this repo, so a push from here
# recurses into the Packages/Vendor/LabelMorph and Packages/Vendor/ThinkingOrbs forks and
# publishes them (see CLAUDE.md); the tag
# is pushed by hand, and this script only verifies the remote already has it, exactly where
# HEAD is. Run:
#   git tag -a v0.1.0 -m "Threading 0.1.0"
#   git push origin v0.1.0        # deliberately by hand, never from a script
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
VERSION="${TAG#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "tag '$TAG' is not v<dotted digits>"
echo "  $TAG"

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

# MARK: - Build, notarize, appcast

say "Building the notarized release"
THREADING_VERSION="$VERSION" "$ROOT/scripts/release.sh" --notarize

say "Generating the appcast"
THREADING_VERSION="$VERSION" "$ROOT/scripts/generate_appcast.sh"

readonly ZIP="$BUILD_DIR/Threading-$VERSION.zip"
readonly APPCAST="$BUILD_DIR/appcast.xml"
[[ -f "$ZIP" && -f "$APPCAST" ]] || fail "expected artefacts are missing from $BUILD_DIR"

# MARK: - Release notes

NOTES="$(awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { printing = 1; next }
    printing && /^## \[/ { exit }
    printing { print }
' "$ROOT/CHANGELOG.md")"
[[ -n "${NOTES//[[:space:]]/}" ]] || fail "CHANGELOG.md has no section for $VERSION"

NOTES="$NOTES

Direct download: \`Threading-$VERSION.zip\` — Developer ID signed, notarized by Apple, and
stapled. Installed copies update themselves through Sparkle from this release's \`appcast.xml\`."

# MARK: - Publish

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    say "Updating the existing GitHub release $TAG"
    gh release upload "$TAG" "$ZIP" "$APPCAST" --repo "$REPO" --clobber
    gh release edit "$TAG" --repo "$REPO" --notes "$NOTES"
else
    say "Creating the GitHub release $TAG"
    gh release create "$TAG" "$ZIP" "$APPCAST" \
        --repo "$REPO" \
        --title "Threading $VERSION" \
        --notes "$NOTES"
fi

say "Published"
echo "  release: https://github.com/$REPO/releases/tag/$TAG"
echo "  download: https://github.com/$REPO/releases/download/$TAG/Threading-$VERSION.zip"
echo "  feed:     https://github.com/$REPO/releases/latest/download/appcast.xml"
echo "  sha256:   $(shasum -a 256 "$ZIP" | awk '{print $1}')"
