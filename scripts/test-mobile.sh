#!/usr/bin/env bash
#
# Run the complete iPhone unit-test target under the host-wide CoreSimulator lane lock.
# Focused connectivity selectors stay in test-connectivity.sh; this is the ordinary full gate.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
simulator_destination="${THREADING_MOBILE_TEST_DESTINATION:-${THREADING_CONNECTIVITY_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}}"
source "${script_directory}/coresimulator_lane_lock.sh"

threading_acquire_coresimulator_lane "mobile unit tests"

xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme ThreadingMobile \
  -destination "${simulator_destination}" \
  test \
  "$@"
