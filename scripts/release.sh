#!/usr/bin/env bash
#
# Builds a distributable Threading.app: Developer ID signed, hardened, timestamped, notarized
# and stapled, plus the zip Sparkle serves.
#
# Why an archive/export rather than `xcodebuild build -configuration Release`:
# Xcode's automatic signing only issues *development* certificates for a build action. Pinning
# `CODE_SIGN_IDENTITY = "Developer ID Application"` in the build settings fails outright with
# "conflicting provisioning settings" unless every target also switches to manual signing.
# Distribution signing is an export concern, so it lives here. The practical consequence worth
# remembering: a locally built Release is development-signed and *does* carry get-task-allow,
# injected by Xcode. Only the artefact this script produces is the shipping one.
#
# Usage:
#   scripts/release.sh                 # build, export, verify (no upload)
#   scripts/release.sh --notarize      # also submit to Apple, staple, and Gatekeeper-check
#   THREADING_SKIP_RELEASE_CHECKS=1 scripts/release.sh
#                                      # explicit emergency escape hatch for the quality gate
#
# --notarize uses the `mjukis-notary` credential profile, which already exists on the release
# machine because claudex ships with it — same Apple ID, same team. Override with NOTARY_PROFILE.
# To recreate it:
#   xcrun notarytool store-credentials mjukis-notary \
#     --apple-id <your-apple-id> --team-id SMQ3E8Y57T --password <app-specific-password>
#
# claudex (~/repo/claudex/scripts/) is the reference for the steps past this one — appcast
# generation, the GitHub release, and the Homebrew cask. See docs/architecture/releasing.md.

set -euo pipefail

readonly SCHEME="Threading"
readonly PROJECT="Threading.xcodeproj"
readonly TEAM_ID="SMQ3E8Y57T"
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-mjukis-notary}"

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="$ROOT/build/release"
readonly ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly APP="$EXPORT_DIR/$SCHEME.app"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

NOTARIZE=0
for argument in "$@"; do
    case "$argument" in
        --notarize) NOTARIZE=1 ;;
        *) fail "unknown argument '$argument'" ;;
    esac
done

run_xcodebuild() {
    local phase="$1"
    local log_file="$2"
    shift 2

    if ! xcodebuild "$@" >"$log_file" 2>&1; then
        rg '(^|: )(error|warning): |\\*\\* (ARCHIVE|EXPORT)' "$log_file" \
            || tail -80 "$log_file"
        fail "$phase failed; full output is in $log_file"
    fi
    rg '(^|: )(error|warning): |\\*\\* (ARCHIVE|EXPORT)' "$log_file" || true
}

# MARK: - Preflight

[[ "$ROOT" != "/" && "$BUILD_DIR" == "$ROOT/build/release" ]] \
    || fail "refusing an unsafe build directory: $BUILD_DIR"

if [[ $NOTARIZE -eq 1 && -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    fail "notarized releases require a clean worktree"
fi

if [[ "${THREADING_SKIP_RELEASE_CHECKS:-0}" != "1" ]]; then
    say "Running the release quality gate"
    "$ROOT/scripts/ci.sh"
else
    echo "warning: release quality gate skipped by THREADING_SKIP_RELEASE_CHECKS=1" >&2
fi

say "Checking the signing identity"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM_ID)"; then
    fail "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain"
fi

if [[ $NOTARIZE -eq 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "notarytool profile '$NOTARY_PROFILE' not found — see the header of this script"
fi

# MARK: - Version
#
# The version is *injected* rather than committed. claudex keeps its number in a standalone
# Info.plist and bumps it by hand; here the same two fields come from build settings, so bumping
# them would mean editing project.pbxproj — the single most contended file in this repo — once
# per release. Passing them to xcodebuild instead keeps releases out of that file entirely and
# leaves the git tag as the only source of truth.
#
# Both fields get the same semver, as in claudex. Sparkle compares CFBundleVersion with
# SUStandardVersionComparator, which orders dotted components numerically, so 1.10.0 > 1.9.0.

say "Resolving the version"
VERSION="${THREADING_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    tag="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
    VERSION="${tag#v}"
fi

if [[ -z "$VERSION" ]]; then
    # A signing/verification dry run does not need a real version, but shipping does: an app that
    # publishes the placeholder forever is one Sparkle can never see an update for.
    [[ $NOTARIZE -eq 1 ]] && fail "no version — tag the commit (git tag v1.1.0) or set THREADING_VERSION"
    VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$ROOT/$PROJECT/project.pbxproj" | head -1)"
    echo "  no tag on HEAD — using the project's $VERSION for this dry run"
    DEV_BUILD=1
else
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
        || fail "version '$VERSION' is not dotted digits, so Sparkle cannot order it"
    echo "  $VERSION"
    DEV_BUILD=0
fi

# MARK: - Archive

say "Archiving $SCHEME"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
run_xcodebuild "archive" "$BUILD_DIR/archive.log" archive \
    -project "$ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    -archivePath "$ARCHIVE"

[[ -d "$ARCHIVE" ]] || fail "the archive was not produced"

# MARK: - Export

say "Exporting with Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

run_xcodebuild "export" "$BUILD_DIR/export.log" -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR"

[[ -d "$APP" ]] || fail "the export produced no app bundle"

# MARK: - Verify

# Notarization rejects a bundle whose *nested* code is development-signed, untimestamped, or
# missing the hardened runtime — and it reports that only after the upload round-trip. Checking
# every Mach-O here turns a ten-minute server rejection into an immediate local failure.
say "Verifying every embedded executable"
problems=0
while IFS= read -r binary; do
    file "$binary" | grep -q "Mach-O" || continue
    name="$(basename "$binary")"
    details="$(codesign -dvvv "$binary" 2>&1)"

    grep -q "Authority=Developer ID Application" <<<"$details" \
        || { echo "  ✗ $name is not Developer ID signed"; problems=1; }
    grep -q "flags=.*runtime" <<<"$details" \
        || { echo "  ✗ $name has no hardened runtime"; problems=1; }
    grep -q "^Timestamp=" <<<"$details" \
        || { echo "  ✗ $name has no secure timestamp"; problems=1; }

    if codesign -d --entitlements - --xml "$binary" 2>/dev/null \
        | plutil -convert xml1 -o - - 2>/dev/null \
        | grep -q "get-task-allow"; then
        echo "  ✗ $name ships com.apple.security.get-task-allow"
        problems=1
    fi
    echo "  ✓ $name"
done < <(find "$APP" -type f -perm +111)

[[ $problems -eq 0 ]] || fail "the export is not notarizable — see above"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2

# MARK: - Package

say "Packaging"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# claudex's safety net, moved after the fact: it checks the tag against the plist before
# building, which cannot catch a build setting that failed to take. Reading it back off the
# exported bundle does. A release whose zip says 1.1.0 and whose CFBundleVersion says 1 is an
# update no installed copy will ever accept.
if [[ "$version" != "$VERSION" || "$build" != "$VERSION" ]]; then
    fail "asked for $VERSION but the bundle carries $version ($build)"
fi

zip="$BUILD_DIR/$SCHEME-$version.zip"

# ditto, not `zip`: Sparkle unpacks with the same tool, and only ditto preserves the symlinks
# and extended attributes inside a signed bundle. A `zip`-ed app fails its signature check.
ditto -c -k --keepParent --sequesterRsrc "$APP" "$zip"
echo "  $zip"

# MARK: - Notarize

if [[ $NOTARIZE -eq 0 ]]; then
    say "Done (not notarized)"
    echo "The bundle is signed and verified but Gatekeeper will still warn until it is"
    echo "notarized. Re-run with --notarize to submit it."
    exit 0
fi

say "Submitting to Apple"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait

say "Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The staple lives in the bundle, so the zip has to be rebuilt from the stapled app or the
# download Sparkle serves is the un-stapled one.
rm -f "$zip"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$zip"

say "Gatekeeper assessment"
spctl -a -vvv -t install "$APP"

say "Ready: $SCHEME $version ($build)"
echo "  app: $APP"
echo "  zip: $zip"
