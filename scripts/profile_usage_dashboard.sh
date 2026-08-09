#!/usr/bin/env bash
# Run the opt-in million-response Usage dashboard performance sweep.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

cd "${repository_directory}"
xcodebuild \
  -project Threading.xcodeproj \
  -scheme Threading \
  -testPlan Threading-Fast \
  -destination "platform=macOS" \
  -configuration Debug \
  -quiet \
  build-for-testing

build_directory="$(
  xcodebuild \
    -project Threading.xcodeproj \
    -scheme Threading \
    -configuration Debug \
    -destination "platform=macOS" \
    -showBuildSettings \
    -json \
    | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
)"
stress_app="${build_directory}/Threading.app"
stress_bundle="${stress_app}/Contents/PlugIns/ThreadingTests.xctest"
[[ -d "${stress_bundle}" ]] || {
  echo "Built test bundle not found at ${stress_bundle}." >&2
  exit 1
}

THREADING_USAGE_STRESS=1 \
DYLD_LIBRARY_PATH="${stress_app}/Contents/MacOS" \
DYLD_FRAMEWORK_PATH="${stress_app}/Contents/Frameworks" \
  xcrun xctest \
    -XCTest ThreadingTests.UsageDashboardPerformanceTests \
    "${stress_bundle}"
