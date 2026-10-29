#!/usr/bin/env bash
# Build and load Device Logs from the SDK asset that users can actually download.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${THREADING_REPO:-everlof/threading}"
TAG="${1:-}"
VERSION="${2:-}"

fail() { printf 'plugin SDK verification: %s\n' "$1" >&2; exit 1; }
[[ -n "$TAG" && "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || fail "usage: verify_published_plugin_sdk.sh <release-tag> <dotted-version>"

if [[ "$TAG" != nightly ]]; then
    # shellcheck source=scripts/release_tag_policy.sh
    source "$ROOT/scripts/release_tag_policy.sh"
    description="$(release_tag_describe "$TAG")" || fail "invalid release tag"
    [[ "${description#* }" == "$VERSION" ]] || fail "$TAG does not name version $VERSION"
fi

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || fail "verify from a clean checkout of the release source"
revision="$(git -C "$ROOT" rev-parse HEAD)"
if [[ "$TAG" != nightly ]]; then
    [[ "$(git -C "$ROOT" rev-list -n 1 "$TAG")" == "$revision" ]] \
        || fail "$TAG does not point at the checkout being tested"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/threading-plugin-sdk-release.XXXXXX")"
finished=false
cleanup() {
    if [[ "$finished" == true ]]; then
        rm -rf "$scratch"
    else
        printf 'verification files retained at %s\n' "$scratch" >&2
    fi
}
trap cleanup EXIT

name="ThreadingPluginSDK-$VERSION"
archive="$scratch/$name.zip"
gh release download "$TAG" --repo "$REPO" --pattern "$name.zip" --dir "$scratch"
[[ -s "$archive" ]] || fail "release asset $name.zip is missing or empty"

python3 "$ROOT/scripts/verify_plugin_sdk_archive.py" "$archive" "$VERSION"

result="$scratch/parity.xcresult"
TEST_RUNNER_THREADING_PLUGIN_PARITY=1 \
TEST_RUNNER_THREADING_PLUGIN_SDK_ARCHIVE="$archive" \
    xcodebuild -project "$ROOT/Threading.xcodeproj" -scheme Threading \
        -testPlan Threading-Fast -destination 'platform=macOS' \
        -parallel-testing-enabled NO -resultBundlePath "$result" \
        test -quiet \
        -only-testing:ThreadingTests/NativePluginParityTests/testDeviceLogsBuiltWithPublicRecipeOffersTheSameTools \
        -only-testing:ThreadingTests/NativePluginParityTests/testManuallyInstalledFirstPartyIdentifierRequiresManagedReceipt

python3 - "$result" <<'PY'
import json
import subprocess
import sys

raw = subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", sys.argv[1]
])
summary = json.loads(raw)
if (summary.get("result"), summary.get("passedTests"), summary.get("failedTests"),
        summary.get("skippedTests"), summary.get("totalTestCount")) != ("Passed", 2, 0, 0, 2):
    raise SystemExit(f"host parity did not run both cases: {summary}")
PY

finished=true
printf 'Verified %s from %s against %s\n' "$name.zip" "$TAG" "$revision"
