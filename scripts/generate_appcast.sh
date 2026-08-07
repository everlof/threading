#!/usr/bin/env bash
#
# Turns the zip scripts/release.sh produced into a signed Sparkle appcast.
#
# The release notes are this repo's CHANGELOG.md: the section matching the version is written
# beside the zip as Markdown, and Sparkle's generate_appcast embeds it as the item description
# with `sparkle:format="markdown"` — which is the exact shape the in-app update sheet renders
# natively (UpdateUserDriver reads itemDescription into MarkdownView). A version CHANGELOG.md
# does not describe cannot ship.
#
# Signing:
#   By default the EdDSA key comes from the login keychain under the account
#   `mjukis-threading` — Threading's *own* key, deliberately not shared with claudex, so a
#   compromised CI secret of one app can never sign an update for the other (see
#   docs/architecture/releasing.md). Create it once with:
#     generate_keys --account mjukis-threading
#   and put the printed public key in Sources/Threading/Resources/Info.plist (SUPublicEDKey).
#   This script refuses to sign with a key whose public half is not the one the app ships,
#   because that mismatch is otherwise discovered by every installed copy rejecting the update.
#
#   CI signs from a secret instead: THREADING_SPARKLE_PRIVATE_KEY_FILE=- reads the base64 seed
#   from stdin (the shape `generate_keys -x` exports). The plist guard cannot run in that mode,
#   so the secret must be the export of the same key the plist names.
#
# Usage:
#   scripts/generate_appcast.sh                # version from the tag on HEAD or THREADING_VERSION
#   scripts/generate_appcast.sh --channel beta # stamp the item into the beta channel
#
# Environment:
#   THREADING_VERSION                          the version when HEAD carries no tag
#   THREADING_REPO                             GitHub slug (default everlof/threading)
#   THREADING_SPARKLE_ACCOUNT                  keychain account (default mjukis-threading)
#   THREADING_SPARKLE_PRIVATE_KEY_FILE         private-key file for CI; '-' reads stdin
#   THREADING_SPARKLE_PHASED_ROLLOUT_INTERVAL  seconds between rollout phases (default 86400; 0 disables)
#   THREADING_DOWNLOAD_URL_PREFIX              enclosure URL prefix (nightly feeds override this)
#   THREADING_RELEASE_TAG                      tag the full-notes link points at (default v<version>)
#   THREADING_RELEASE_NOTES_FILE               Markdown notes to embed instead of the CHANGELOG
#                                              section — for nightlies, whose date versions have none
#   THREADING_SPARKLE_BIN                      Sparkle's tools; default: newest DerivedData artifacts

set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="$ROOT/build/release"
readonly PLIST="$ROOT/Sources/Threading/Resources/Info.plist"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

CHANNEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            shift
            CHANNEL="${1:-}"
            [[ -n "$CHANNEL" ]] || fail "--channel requires a value"
            ;;
        *) fail "unknown argument '$1'" ;;
    esac
    shift
done

# MARK: - Inputs

say "Resolving the version"
VERSION="${THREADING_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    tag="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
    VERSION="${tag#v}"
fi
[[ -n "$VERSION" ]] || fail "no version — tag the commit or set THREADING_VERSION"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || fail "version '$VERSION' is not dotted digits, so Sparkle cannot order it"
echo "  $VERSION"

readonly REPO="${THREADING_REPO:-everlof/threading}"
readonly RELEASE_TAG="${THREADING_RELEASE_TAG:-v$VERSION}"
readonly DOWNLOAD_URL_PREFIX="${THREADING_DOWNLOAD_URL_PREFIX:-https://github.com/$REPO/releases/download/$RELEASE_TAG/}"
readonly ZIP="$BUILD_DIR/Threading-$VERSION.zip"
readonly APPCAST="$BUILD_DIR/appcast.xml"
readonly WORK="$BUILD_DIR/appcast-work"

[[ -f "$ZIP" ]] || fail "missing $ZIP — run scripts/release.sh first"

# MARK: - Sparkle tools
#
# The tools travel inside Sparkle's SPM artifact bundle, which Xcode extracts under
# DerivedData. Newest wins because stale DerivedData directories linger for renamed schemes;
# an explicit THREADING_SPARKLE_BIN (CI resolves packages into a known path) wins over both.

SPARKLE_BIN="${THREADING_SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
    SPARKLE_BIN="$(ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/Threading-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"
fi
[[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/generate_appcast" ]] \
    || fail "Sparkle's tools not found — build once in Xcode, or set THREADING_SPARKLE_BIN"
echo "  Sparkle tools: $SPARKLE_BIN"

# MARK: - Key

key_args=()
if [[ -n "${THREADING_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    key_args+=(--ed-key-file "$THREADING_SPARKLE_PRIVATE_KEY_FILE")
    echo "  signing with a private-key file (plist guard skipped — CI mode)"
else
    readonly ACCOUNT="${THREADING_SPARKLE_ACCOUNT:-mjukis-threading}"
    key_args+=(--account "$ACCOUNT")

    say "Checking the signing key against the app's public key"
    shipped="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" \
        || fail "the app's Info.plist carries no SUPublicEDKey"
    signing="$("$SPARKLE_BIN/generate_keys" -p --account "$ACCOUNT" 2>/dev/null)" \
        || fail "no Sparkle key for account '$ACCOUNT' in the keychain — run: generate_keys --account $ACCOUNT (then put the printed public key in Info.plist)"
    if [[ "$shipped" != "$signing" ]]; then
        fail "key mismatch: the app ships SUPublicEDKey $shipped but account '$ACCOUNT' signs as $signing — every installed copy would reject this update. Update Info.plist or THREADING_SPARKLE_ACCOUNT."
    fi
    echo "  ✓ account '$ACCOUNT' matches the shipped SUPublicEDKey"
fi

# MARK: - Release notes

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"

if [[ -n "${THREADING_RELEASE_NOTES_FILE:-}" ]]; then
    say "Embedding release notes from $THREADING_RELEASE_NOTES_FILE"
    cp "$THREADING_RELEASE_NOTES_FILE" "$WORK/Threading-$VERSION.md"
else
    say "Extracting the $VERSION section from CHANGELOG.md"
    awk -v version="$VERSION" '
        $0 ~ "^## \\[" version "\\]" { printing = 1; next }
        printing && /^## \[/ { exit }
        printing { print }
    ' "$ROOT/CHANGELOG.md" > "$WORK/Threading-$VERSION.md"
fi

if [[ -z "$(tr -d '[:space:]' < "$WORK/Threading-$VERSION.md")" ]]; then
    fail "no release notes for $VERSION — a release cannot ship undescribed"
fi

# MARK: - Generate

say "Generating the signed appcast"
phase_args=()
readonly PHASE_SECONDS="${THREADING_SPARKLE_PHASED_ROLLOUT_INTERVAL:-86400}"
if [[ "$PHASE_SECONDS" != "0" ]]; then
    phase_args+=(--phased-rollout-interval "$PHASE_SECONDS")
fi

channel_args=()
if [[ -n "$CHANNEL" ]]; then
    channel_args+=(--channel "$CHANNEL")
fi

rm -f "$APPCAST"
"$SPARKLE_BIN/generate_appcast" \
    "${key_args[@]}" \
    "${phase_args[@]}" \
    "${channel_args[@]}" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --full-release-notes-url "https://github.com/$REPO/releases/tag/$RELEASE_TAG" \
    --link "https://github.com/$REPO" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$APPCAST" \
    "$WORK"

# MARK: - Verify
#
# Each failure here is one an installed copy would otherwise report by silently never
# updating: an unsigned enclosure, an unsigned feed, an item for the wrong zip, or notes in a
# format the in-app sheet would show as raw text.

say "Verifying the appcast"
grep -q 'sparkle:edSignature=' "$APPCAST" \
    || fail "the feed's enclosure is not signed"
grep -q '<!-- sparkle-signatures:' "$APPCAST" && grep -q '^edSignature: ' "$APPCAST" \
    || fail "the feed itself is not signed"
grep -q "Threading-$VERSION.zip" "$APPCAST" \
    || fail "the feed does not reference Threading-$VERSION.zip"
# generate_appcast reads the version off the bundle *inside* the zip, so a mismatch here
# means the zip is stale or hand-made — release.sh's read-back guarantees a fresh one agrees.
grep -q "<sparkle:version>$VERSION</sparkle:version>" "$APPCAST" \
    || fail "the feed's item version is not $VERSION — the zip in build/release is not this release's"
grep -q 'sparkle:format="markdown"' "$APPCAST" \
    || fail "the embedded release notes are not markdown — the in-app sheet renders exactly that (see releasing.md)"
"$SPARKLE_BIN/sign_update" --verify "${key_args[@]}" "$APPCAST"

say "Generated: $APPCAST"
echo "  stable feed URL: https://github.com/$REPO/releases/latest/download/appcast.xml"
