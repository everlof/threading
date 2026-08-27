#!/usr/bin/env bash
#
# Focused connectivity gates. These are deliberately separate from scripts/test.sh: the mobile
# contract runs in an iOS Simulator, and the hardware lane is device-specific with a guided radio
# subset.
set -euo pipefail

level="${1:-software}"
shift || true

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
simulator_destination="${THREADING_CONNECTIVITY_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}"
source "${script_directory}/coresimulator_lane_lock.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/test-connectivity.sh software
  scripts/test-connectivity.sh topology
  scripts/test-connectivity.sh all
  scripts/test-connectivity.sh simulator-chaos [simulator-chaos options]
  scripts/test-connectivity.sh hardware --device <name-or-UDID> [hardware options]

software runs transport, reconnect, deadline, and connection-pool contracts on macOS and in an
iOS Simulator. topology runs discovery, candidate, trust, and listener-door contracts.
simulator-chaos repeatedly SIGKILLs/SIGABRTs the real iOS app against a real hosted socket server.
hardware delegates to the physical-device lane; pass `--scenario automatic --non-interactive`
for its unattended app-lifecycle subset.

Override the simulator with THREADING_CONNECTIVITY_SIMULATOR_DESTINATION, using any complete
xcodebuild destination string.
USAGE
}

run_mobile_tests() {
  threading_acquire_coresimulator_lane "connectivity" || return $?
  xcodebuild \
    -project "${repository_directory}/Threading.xcodeproj" \
    -scheme ThreadingMobile \
    -destination "${simulator_destination}" \
    test \
    "$@"
}

run_software() {
  "${script_directory}/test.sh" fast \
    -only-testing:ThreadingTests/RemoteWebSocketTests \
    -only-testing:ThreadingTests/RemoteServerIntegrationTests \
    -only-testing:ThreadingTests/RemoteTransportInjectionTests \
    "$@"

  run_mobile_tests \
    -only-testing:ThreadingMobileTests/MobileConnectionDiagnosticsTests \
    -only-testing:ThreadingMobileTests/RemoteConnectionFailureTests \
    -only-testing:ThreadingMobileTests/MobileHostRefreshSingleFlightTests \
    -only-testing:ThreadingMobileTests/MobileSessionConnectionPoolTests \
    "$@"
}

run_topology() {
  "${script_directory}/test.sh" fast \
    -only-testing:ThreadingTests/RemoteListenerDoorTests \
    -only-testing:ThreadingTests/RemoteListenerTLSTests \
    "$@"

  run_mobile_tests \
    -only-testing:ThreadingMobileTests/MobileInvitationRouteTests \
    -only-testing:ThreadingMobileTests/MobileLocalNetworkPermissionTests \
    -only-testing:ThreadingMobileTests/MobileSettingsIdentityTests \
    -only-testing:ThreadingMobileTests/MobileTerminalWireFixtureTests \
    -only-testing:ThreadingMobileTests/RemoteHostCandidateTests \
    -only-testing:ThreadingMobileTests/RemoteHostDiscoveryTests \
    -only-testing:ThreadingMobileTests/RemoteHostTrustTests \
    "$@"
}

case "${level}" in
  software) run_software "$@" ;;
  topology) run_topology "$@" ;;
  all)
    [[ "$#" == "0" ]] || { usage >&2; exit 1; }
    run_software
    run_topology
    ;;
  simulator-chaos) exec "${script_directory}/connectivity-simulator-chaos.sh" "$@" ;;
  hardware) exec "${script_directory}/connectivity-hardware.sh" "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
