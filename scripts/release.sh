#!/usr/bin/env bash
#
# Builds a distributable Threading.app: Developer ID signed, hardened, timestamped, notarized
# and stapled, arm64 only, plus the zip Sparkle serves.
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
#   scripts/release.sh --install       # also install the result over /Applications/Threading.app
#                                      # (scripts/install-app.sh does the work, and can be run on
#                                      # its own against any bundle — see its header)
#   scripts/release.sh --simulator-matrix
#                                      # dogfood the exported host/helper against every Xcode in
#                                      # THREADING_SIMULATOR_MATRIX_XCODES (colon-separated), or
#                                      # the active Xcode when unset; uses an already-booted device
#   scripts/release.sh --channel nightly
#                                      # stamp a channel other than release into the bundle;
#                                      # the app shows it as the sidebar badge (BuildChannelBadge)
#   THREADING_SKIP_RELEASE_CHECKS=1 scripts/release.sh
#                                      # explicit emergency escape hatch for the quality gate
#   THREADING_DERIVED_DATA=<dir> scripts/release.sh
#                                      # build in a chosen DerivedData rather than Xcode's default —
#                                      # a scratch clone or a CI runner with a seeded package cache
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
readonly BUNDLE_ID="${THREADING_BUNDLE_ID:-codes.threading}"
readonly PROVISIONING_PROFILE="${THREADING_PROVISIONING_PROFILE:-Threading Provisioning Profile}"
# Threading ships for Apple silicon only. The project builds its own targets arm64-only; this is
# the slice the archive's prebuilt embedded frameworks are thinned to, and the one every exported
# binary is checked against. See docs/architecture/releasing.md, "Apple silicon only".
readonly ARCHITECTURE="arm64"

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BUILD_DIR="$ROOT/build/release"
readonly ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
readonly EXPORT_DIR="$BUILD_DIR/export"
readonly APP="$EXPORT_DIR/$SCHEME.app"

derived_data_args=()
if [[ -n "${THREADING_DERIVED_DATA:-}" ]]; then
    derived_data_args+=(-derivedDataPath "$THREADING_DERIVED_DATA")
fi

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# The release tag grammar, shared with publish_release.sh so the two cannot disagree about what
# a tag means. See scripts/tests/test_release_tag_policy.py.
# shellcheck source=scripts/release_tag_policy.sh
source "$ROOT/scripts/release_tag_policy.sh"

NOTARIZE=0
INSTALL=0
SIMULATOR_MATRIX=0
CHANNEL="release"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) NOTARIZE=1 ;;
        --install) INSTALL=1 ;;
        --simulator-matrix) SIMULATOR_MATRIX=1 ;;
        --channel)
            shift
            CHANNEL="${1:-}"
            ;;
        *) fail "unknown argument '$1'" ;;
    esac
    shift
done

# `dev` is not offered: it is what every build gets *without* this script, and a shipped
# artefact deliberately claiming to be a dev build would wear the badge while carrying a
# Developer ID signature — a contradiction nothing downstream could interpret.
case "$CHANNEL" in
    release|beta|nightly) ;;
    *) fail "channel '$CHANNEL' is not release, beta or nightly" ;;
esac

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
    say "Running the Mac release quality gate"
    "$ROOT/scripts/ci.sh" --mac-release
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

# The provisioning profile, checked against the entitlements it has to authorise — and, today,
# confirming there are none, so no profile is needed and none is named in ExportOptions.plist.
#
# Same bargain as the embedded-binary sweep below: exportArchive only reports this after the
# archive is built, so an unauthorised entitlement costs a full release build to discover. It is
# checked here, where it costs nothing. The failure this was written for is a profile issued
# before a capability was enabled on the App ID: the App ID shows the capability ticked, and the
# profile — a snapshot of the moment it was issued — does not carry it, so signing refuses.
say "Checking the provisioning profile"
profile_directory="$HOME/Library/MobileDevice/Provisioning Profiles"
if ! python3 - "$profile_directory" "$PROVISIONING_PROFILE" "$TEAM_ID.$BUNDLE_ID" \
    "$ROOT/Sources/Threading/Resources/Threading.entitlements"; then
    fail "the provisioning profile cannot sign this app — see above"
fi <<'PYTHON'
import plistlib
import subprocess
import sys
from pathlib import Path

directory, wanted_name, wanted_app_id, entitlements_path = sys.argv[1:5]

# Only com.apple.developer.* needs a profile's blessing; com.apple.security.cs.* are hardened
# runtime flags the profile never mentions, and demanding them here would fail every build.
required = {
    key for key in plistlib.loads(Path(entitlements_path).read_bytes())
    if key.startswith("com.apple.developer.")
}

# Nothing restricted, nothing to authorise. Developer ID needs no profile in that case, and
# demanding one would fail a release that is correct — which is the state this app is in since
# Sign in with Apple was dropped: it cannot cross into a Developer ID profile at all.
if not required:
    print("  no restricted entitlements — Developer ID needs no profile")
    sys.exit(0)

candidates = sorted(Path(directory).glob("*.provisionprofile")) if Path(directory).is_dir() else []
for path in candidates:
    decoded = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)],
        capture_output=True,
    )
    if decoded.returncode != 0:
        continue
    profile = plistlib.loads(decoded.stdout)
    entitlements = profile.get("Entitlements", {})
    if entitlements.get("com.apple.application-identifier") != wanted_app_id:
        continue
    if profile.get("Name") != wanted_name:
        print(f"  note: {path.name} matches {wanted_app_id} but is named "
              f"{profile.get('Name')!r}, not {wanted_name!r}", file=sys.stderr)
        continue
    if not profile.get("ProvisionsAllDevices"):
        print(f"  {wanted_name!r} is not a Developer ID profile", file=sys.stderr)
        sys.exit(1)
    missing = sorted(required - set(entitlements))
    if missing:
        print(f"  {wanted_name!r} does not carry: {', '.join(missing)}", file=sys.stderr)
        print("  Re-issue it in the portal: a profile is a snapshot of the App ID's", file=sys.stderr)
        print("  capabilities when it was generated and cannot gain one afterwards.", file=sys.stderr)
        sys.exit(1)
    print(f"  {wanted_name!r} authorises {', '.join(sorted(required)) or 'no restricted entitlements'}")
    sys.exit(0)

print(f"  no installed profile named {wanted_name!r} for {wanted_app_id}", file=sys.stderr)
print(f"  looked in {directory}", file=sys.stderr)
sys.exit(1)
PYTHON

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
    if [[ -n "$tag" ]] && description="$(release_tag_describe "$tag" 2>/dev/null)"; then
        read -r tag_channel VERSION <<< "$description"
        # The tag is the only thing saying what this build is here, so a --channel that
        # contradicts it would silently stamp the wrong badge and the wrong feed behaviour.
        [[ "$tag_channel" == "$CHANNEL" ]] \
            || fail "$tag is a $tag_channel tag but --channel says $CHANNEL — pass --channel $tag_channel, or set THREADING_VERSION to build something the tag does not name"
    fi
fi

if [[ -z "$VERSION" ]]; then
    # A signing/verification dry run does not need a real version, but shipping does: an app that
    # publishes the placeholder forever is one Sparkle can never see an update for.
    [[ $NOTARIZE -eq 1 ]] && fail "no version — tag the commit (git tag v1.1.0) or set THREADING_VERSION"
    VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$ROOT/$PROJECT/project.pbxproj" | head -1)"
    echo "  no tag on HEAD — using the project's $VERSION for this dry run"
    DEV_BUILD=1
    # An artefact with no real version is not a member of any channel, whatever was asked for —
    # it wears the dev badge for the same reason it carries 0.0.0.
    if [[ "$CHANNEL" != "release" ]]; then
        echo "  no version, so the requested '$CHANNEL' channel becomes 'dev' for this dry run"
    fi
    CHANNEL="dev"
else
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
        || fail "version '$VERSION' is not dotted digits, so Sparkle cannot order it"
    echo "  $VERSION"
    DEV_BUILD=0
fi

# MARK: - Archive
#
# ARCHS on the command line as well as in the project: Swift packages built inside the workspace
# do not read the project's ARCHS, so without this every package compiles an x86_64 slice the
# link then discards — 139 compiles per archive when it was measured.

# MARK: - Issue-report intake
#
# There is deliberately no compiled-in fallback: a build that names no endpoint writes its record
# and posts nothing, so this is the only thing standing between a user's bug report and the
# developer. It is injected here rather than committed because it is a *release* property; an
# ordinary Debug build must not post to production, and MacIssueReportSubmitter only honours the
# environment override under DEBUG.
#
# The host is verified before the archive rather than after. `issue-reporting-setup.md` records
# why in blood: the iOS app once shipped naming this host before it served anything, and the
# 2026-08-21 support report is 250 deliveries that could only ever fail against a parked domain's
# TLS. A registrar parking record answers a ClientHello with handshake_failure and no certificate,
# which reaches the app as URLError(-1200) and is indistinguishable from a real network fault.
REPORT_INTAKE_HOST="remote.threading.codes"
REPORT_INTAKE_URL="https://${REPORT_INTAKE_HOST}/v1/reports"

say "Checking the report intake host presents a certificate"
if ! openssl s_client -connect "${REPORT_INTAKE_HOST}:443" -servername "$REPORT_INTAKE_HOST" \
        </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
    fail "${REPORT_INTAKE_HOST} presented no certificate; refusing to ship a build that names it"
fi

say "Archiving $SCHEME ($CHANNEL)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
run_xcodebuild "archive" "$BUILD_DIR/archive.log" archive \
    -project "$ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates \
    ${derived_data_args[@]+"${derived_data_args[@]}"} \
    ARCHS="$ARCHITECTURE" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    THREADING_CHANNEL="$CHANNEL" \
    THREADING_SOURCE_REVISION= \
    THREADING_REPORT_INTAKE_URL="$REPORT_INTAKE_URL" \
    -archivePath "$ARCHIVE"

[[ -d "$ARCHIVE" ]] || fail "the archive was not produced"

# MARK: - Thin
#
# Before export, not after: the export re-signs every nested binary with the Developer ID identity,
# so the seals thinning breaks are replaced for free. Thinning the exported app instead would mean
# re-signing Sparkle's five nested bundles inside-out by hand.

say "Thinning embedded binaries to $ARCHITECTURE"
"$ROOT/scripts/thin_app_architectures.sh" "$ARCHIVE/Products/Applications/$SCHEME.app" "$ARCHITECTURE"

# MARK: - Export

# Manual signing, with the profile named explicitly.
#
# `automatic` cannot work here and never could. Threading ships
# `com.apple.developer.applesignin`, a restricted capability, so even a Developer ID build needs
# a provisioning profile — and automatic signing mints one by asking the Apple ID signed into
# Xcode. A CI runner has the certificate and no account at all, so the first tagged release
# would have spent a full build to arrive at:
#
#     error: exportArchive Cannot create a Developer ID provisioning profile for "codes.threading".
#     error: exportArchive No profiles for 'codes.threading' were found
#
# Naming the profile removes the account from the picture: the export uses what is installed in
# ~/Library/MobileDevice/Provisioning Profiles, which the workflow writes from a secret and this
# machine has from the portal. The profile is a snapshot of the App ID's capabilities when it was
# issued, so enabling a capability later means re-issuing it — a profile cannot gain one.
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
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
PLIST

run_xcodebuild "export" "$BUILD_DIR/export.log" -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates \
    -exportPath "$EXPORT_DIR"

[[ -d "$APP" ]] || fail "the export produced no app bundle"

# MARK: - Verify

say "Verifying declared helper entitlements"
python3 "$ROOT/scripts/check_bundle_entitlements.py" --root "$ROOT" "$APP" \
    || fail "an embedded helper does not carry its declared entitlements"

# Notarization rejects a bundle whose *nested* code is development-signed, untimestamped, or
# missing the hardened runtime — and it reports that only after the upload round-trip. Checking
# every Mach-O here turns a ten-minute server rejection into an immediate local failure.
say "Verifying every embedded executable"
problems=0
while IFS= read -r binary; do
    file "$binary" | grep -q "Mach-O" || continue
    name="$(basename "$binary")"
    details="$(codesign -dvvv "$binary" 2>&1)"
    architectures="$(lipo -archs "$binary")"

    [[ "$architectures" == "$ARCHITECTURE" ]] \
        || { echo "  ✗ $name carries $architectures, not $ARCHITECTURE alone"; problems=1; }
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

[[ $problems -eq 0 ]] || fail "the export is not shippable — see above"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
"$ROOT/scripts/check_bundled_scc.sh" "$APP/Contents/Helpers/scc"

# MARK: - Package

say "Packaging"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
channel="$(/usr/libexec/PlistBuddy -c 'Print :ThreadingBuildChannel' "$APP/Contents/Info.plist")"

# claudex's safety net, moved after the fact: it checks the tag against the plist before
# building, which cannot catch a build setting that failed to take. Reading it back off the
# exported bundle does. A release whose zip says 1.1.0 and whose CFBundleVersion says 1 is an
# update no installed copy will ever accept.
if [[ "$version" != "$VERSION" || "$build" != "$VERSION" ]]; then
    fail "asked for $VERSION but the bundle carries $version ($build)"
fi

# The channel gets the same read-back, and the failure it prevents is the same shape: a
# nightly whose badge claims nothing, or a release wearing NIGHTLY, is a build setting that
# failed to take — visible only after someone installs it.
if [[ "$channel" != "$CHANNEL" ]]; then
    fail "asked for a $CHANNEL build but the bundle carries '$channel'"
fi

zip="$BUILD_DIR/$SCHEME-$version.zip"

# ditto, not `zip`: Sparkle unpacks with the same tool, and only ditto preserves the symlinks
# and extended attributes inside a signed bundle. A `zip`-ed app fails its signature check.
ditto -c -k --keepParent --sequesterRsrc "$APP" "$zip"
echo "  $zip"

# MARK: - Install
#
# A function rather than a tail, because this script has two endings — the un-notarized one below
# and the stapled one at the bottom — and an install step reachable from only one of them would
# be a flag that silently does nothing half the time.

install_if_asked() {
    [[ $INSTALL -eq 1 ]] || return 0
    say "Installing over /Applications"
    "$ROOT/scripts/install-app.sh" --app "$APP"
}

simulator_matrix_if_asked() {
    [[ $SIMULATOR_MATRIX -eq 1 ]] || return 0
    say "Dogfooding the adopted Simulator against the release bundle"
    local arguments=(
        --app "$APP"
        --output "$BUILD_DIR/simulator-compatibility"
    )
    if [[ -n "${THREADING_SIMULATOR_MATRIX_UDID:-}" ]]; then
        arguments+=(--udid "$THREADING_SIMULATOR_MATRIX_UDID")
    fi
    if [[ -n "${THREADING_SIMULATOR_MATRIX_XCODES:-}" ]]; then
        local matrix_xcodes=()
        IFS=':' read -r -a matrix_xcodes <<< "$THREADING_SIMULATOR_MATRIX_XCODES"
        local matrix_xcode
        for matrix_xcode in "${matrix_xcodes[@]}"; do
            [[ -n "$matrix_xcode" ]] && arguments+=(--xcode "$matrix_xcode")
        done
    fi
    [[ $NOTARIZE -eq 0 ]] || arguments+=(--require-notarized)
    "$ROOT/scripts/simulator_dogfood.sh" "${arguments[@]}"
}

# MARK: - Notarize

if [[ $NOTARIZE -eq 0 ]]; then
    simulator_matrix_if_asked
    say "Done (not notarized)"
    echo "The bundle is signed and verified but Gatekeeper will still warn until it is"
    echo "notarized. Re-run with --notarize to submit it."
    install_if_asked
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

simulator_matrix_if_asked

say "Ready: $SCHEME $version ($build, $channel)"
echo "  app: $APP"
echo "  zip: $zip"

install_if_asked
