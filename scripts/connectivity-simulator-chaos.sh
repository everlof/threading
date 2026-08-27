#!/usr/bin/env bash
#
# Abruptly terminate the real iOS Simulator app while it is connected to the real remote
# HTTP/WebSocket server. The server is hosted by an isolated XCTest process; this lane therefore
# proves product-client process recovery, not yet two ordinary application processes.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
diagnostics_tool="${script_directory}/connectivity_diagnostics.py"
source "${script_directory}/coresimulator_lane_lock.sh"

bundle_id="codes.threading.mobile"
cycles=2
timeout_seconds=60
requested_simulator=""
output_directory=""
temporary_simulator_udid=""
simulator_udid=""
host_pid=""
host_suspended=0
stop_path=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/connectivity-simulator-chaos.sh [options]

Options:
  --cycles <count>      connected-process fault cycles (default: 2; alternates SIGKILL/SIGABRT)
  --timeout <seconds>   deadline for each journal checkpoint (default: 60)
  --simulator <UDID>    reuse an explicit simulator instead of creating an isolated one
  --output <directory>  evidence directory (default: .build/connectivity-simulator/<stamp>)
  -h, --help            show this help

By default the script creates, boots, shuts down and deletes a fresh iPhone Simulator. Supplying
--simulator explicitly installs ThreadingMobile into that device and leaves the device intact.
After the connected cycles, one final SIGABRT lands while a catalogue refresh is in flight.
USAGE
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '\n==> %s\n' "$1"
}

while (($#)); do
  case "$1" in
    --cycles)
      (($# >= 2)) || fail "--cycles needs a value"
      cycles="$2"
      shift 2
      ;;
    --timeout)
      (($# >= 2)) || fail "--timeout needs a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --simulator)
      (($# >= 2)) || fail "--simulator needs a value"
      requested_simulator="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || fail "--output needs a value"
      output_directory="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "${cycles}" =~ ^[1-9][0-9]*$ ]] || fail "--cycles must be a positive integer"
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || fail "--timeout must be a positive integer"
for required_command in jq ps python3 xcodebuild xcrun; do
  command -v "${required_command}" >/dev/null 2>&1 \
    || fail "required command is unavailable: ${required_command}"
done
[[ -x "${diagnostics_tool}" ]] || fail "diagnostics helper is not executable: ${diagnostics_tool}"

if [[ -z "${output_directory}" ]]; then
  output_directory="${repository_directory}/.build/connectivity-simulator/$(date -u +%Y%m%d-%H%M%S)-$$"
elif [[ "${output_directory}" != /* ]]; then
  output_directory="${repository_directory}/${output_directory}"
fi
[[ ! -e "${output_directory}" ]] || fail "output already exists: ${output_directory}"
mkdir -p "${output_directory}/checks" "${output_directory}/logs"

cleanup() {
  local exit_status=$?
  if [[ -n "${simulator_udid}" ]]; then
    xcrun simctl terminate "${simulator_udid}" "${bundle_id}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${stop_path}" ]]; then
    touch "${stop_path}"
  fi
  if [[ "${host_suspended}" == "1" ]] \
      && [[ -n "${host_pid}" ]] \
      && kill -0 "${host_pid}" 2>/dev/null; then
    kill -CONT "${host_pid}" 2>/dev/null || true
    host_suspended=0
  fi
  if [[ -n "${host_pid}" ]] && kill -0 "${host_pid}" 2>/dev/null; then
    wait "${host_pid}" || true
  fi
  if [[ -n "${temporary_simulator_udid}" ]]; then
    xcrun simctl shutdown "${temporary_simulator_udid}" >/dev/null 2>&1 || true
    xcrun simctl delete "${temporary_simulator_udid}" >/dev/null 2>&1 || true
  fi
  exit "${exit_status}"
}
trap cleanup EXIT HUP INT TERM

threading_acquire_coresimulator_lane "iOS connectivity process chaos" || exit $?

if [[ -n "${requested_simulator}" ]]; then
  simulator_udid="${requested_simulator}"
  simulator_state="$(
    xcrun simctl list devices available -j \
      | jq -r --arg udid "${simulator_udid}" \
        '[.devices[][] | select(.udid == $udid)][0].state // empty'
  )"
  case "${simulator_state}" in
    Booted) ;;
    Shutdown) xcrun simctl boot "${simulator_udid}" ;;
    *) fail "simulator is unavailable: ${simulator_udid}" ;;
  esac
  xcrun simctl bootstatus "${simulator_udid}" -b >/dev/null
else
  runtime_id="$(
    xcrun simctl list runtimes available -j \
      | jq -r '[.runtimes[] | select(.isAvailable and (.identifier | contains(".iOS-")))][-1].identifier // empty'
  )"
  [[ -n "${runtime_id}" ]] || fail "no available iOS Simulator runtime"
  device_type_id="$(
    xcrun simctl list runtimes available -j \
      | jq -r --arg runtime "${runtime_id}" '
          [.runtimes[] | select(.identifier == $runtime)][0].supportedDeviceTypes
          | ([.[] | select(.name == "iPhone 17 Pro")][0]
              // [.[] | select(.productFamily == "iPhone")][0]).identifier // empty
        '
  )"
  [[ -n "${device_type_id}" ]] || fail "the newest iOS runtime has no iPhone device type"
  temporary_simulator_udid="$(
    xcrun simctl create "Threading Connectivity Chaos $$" "${device_type_id}" "${runtime_id}"
  )"
  simulator_udid="${temporary_simulator_udid}"
  xcrun simctl boot "${simulator_udid}"
  xcrun simctl bootstatus "${simulator_udid}" -b >/dev/null
fi

say "Building the isolated remote-server fixture"
derived_data_root="${THREADING_CONNECTIVITY_DERIVED_DATA:-${repository_directory}/.build/connectivity-simulator-derived-data}"
mac_derived_data="${derived_data_root}/mac"
xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme Threading \
  -testPlan Threading-Fast \
  -destination "platform=macOS" \
  -configuration Debug \
  -derivedDataPath "${mac_derived_data}" \
  -jobs "${THREADING_CONNECTIVITY_BUILD_JOBS:-2}" \
  -quiet \
  build-for-testing 2>&1 | tee "${output_directory}/logs/mac-build.log"

mac_build_directory="$(
  xcodebuild \
    -project "${repository_directory}/Threading.xcodeproj" \
    -scheme Threading \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "${mac_derived_data}" \
    -showBuildSettings \
    -json \
    | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
)"
mac_app="${mac_build_directory}/Threading.app"
test_bundle="${mac_app}/Contents/PlugIns/ThreadingTests.xctest"
[[ -d "${test_bundle}" ]] || fail "built test bundle not found: ${test_bundle}"

say "Building ThreadingMobile for simulator ${simulator_udid}"
ios_derived_data="${derived_data_root}/ios"
xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme ThreadingMobile \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath "${ios_derived_data}" \
  -jobs "${THREADING_CONNECTIVITY_BUILD_JOBS:-2}" \
  -quiet \
  build 2>&1 | tee "${output_directory}/logs/ios-build.log"
ios_app="${ios_derived_data}/Build/Products/Debug-iphonesimulator/ThreadingMobile.app"
[[ -d "${ios_app}" ]] || fail "built iOS app not found: ${ios_app}"

launch_path="${output_directory}/fixture-launch.json"
stop_path="${output_directory}/fixture.stop"
host_log="${output_directory}/logs/host.log"
THREADING_REMOTE_CONNECTIVITY_FIXTURE=1 \
THREADING_REMOTE_CONNECTIVITY_LAUNCH_PATH="${launch_path}" \
THREADING_REMOTE_CONNECTIVITY_STOP_PATH="${stop_path}" \
THREADING_REMOTE_CONNECTIVITY_TIMEOUT=1800 \
DYLD_LIBRARY_PATH="${mac_app}/Contents/MacOS" \
DYLD_FRAMEWORK_PATH="${mac_app}/Contents/Frameworks" \
  xcrun xctest \
    -XCTest ThreadingTests.RemoteServerIntegrationTests/testRemoteConnectivityProcessFixtureWhenEnabled \
    "${test_bundle}" >"${host_log}" 2>&1 &
host_pid=$!

fixture_ready=0
for _ in {1..600}; do
  if [[ -f "${launch_path}" ]]; then
    fixture_ready=1
    break
  fi
  if ! kill -0 "${host_pid}" 2>/dev/null; then
    tail -n 100 "${host_log}" >&2
    fail "remote-server fixture exited before becoming ready"
  fi
  sleep 0.1
done
[[ "${fixture_ready}" == "1" ]] || fail "remote-server fixture did not become ready within 60 seconds"

wire_url="$(/usr/bin/plutil -extract url raw -o - "${launch_path}")"
[[ "${wire_url}" == http://127.0.0.1:*'/#goodtoken' ]] \
  || fail "remote-server fixture returned an invalid loopback URL"

xcrun simctl install "${simulator_udid}" "${ios_app}"
data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_id}" data)"
journal_directory="${data_container}/Library/Application Support/Threading/Diagnostics"

wait_for_event() {
  local checkpoint="$1"
  local after="$2"
  shift 2
  local deadline=$((SECONDS + timeout_seconds))
  local check_output="${output_directory}/checks/${checkpoint}.json"
  local check_error="${output_directory}/checks/${checkpoint}.stderr"
  local check_status

  say "Waiting up to ${timeout_seconds}s for ${checkpoint}"
  while ((SECONDS < deadline)); do
    set +e
    python3 "${diagnostics_tool}" check "${journal_directory}" \
      --after "${after}" "$@" >"${check_output}" 2>"${check_error}"
    check_status=$?
    set -e
    if [[ "${check_status}" == "0" ]]; then
      cat "${check_output}"
      return 0
    fi
    sleep 0.25
  done
  printf 'error: checkpoint %s did not arrive after %s\n' "${checkpoint}" "${after}" >&2
  python3 "${diagnostics_tool}" timeline "${journal_directory}" --after "${after}" >&2 || true
  return 1
}

launch_phone() {
  local label="$1"
  local launch_result
  launch_result="$(
    SIMCTL_CHILD_THREADING_MOBILE_TERMINAL_WIRE_URL="${wire_url}" \
      xcrun simctl launch \
        --terminate-running-process \
        --stdout="${output_directory}/logs/${label}.stdout.log" \
        --stderr="${output_directory}/logs/${label}.stderr.log" \
        "${simulator_udid}" \
        "${bundle_id}"
  )"
  phone_pid="${launch_result##*: }"
  [[ "${phone_pid}" =~ ^[0-9]+$ ]] || fail "could not resolve app pid from: ${launch_result}"
}

signal_phone() {
  local signal="$1"
  local process_command
  process_command="$(ps -p "${phone_pid}" -o command=)"
  [[ "${process_command}" == *"/ThreadingMobile.app/ThreadingMobile"* ]] \
    || fail "refusing to signal pid ${phone_pid}; it is not the built simulator app"
  kill "-${signal}" "${phone_pid}"
  for _ in {1..40}; do
    if ! kill -0 "${phone_pid}" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  fail "simulator app pid ${phone_pid} survived SIG${signal}"
}

require_connection() {
  local label="$1"
  local after="$2"
  wait_for_event "${label}-refresh" "${after}" --event hostRefreshSucceeded
  wait_for_event "${label}-event-socket" "${after}" \
    --event socketConnected --field surface=events
}

say "Cold-launching the real iOS app against the real socket server"
empty_marker="1970-01-01T00:00:00.000Z"
launch_phone baseline
require_connection baseline "${empty_marker}"

for ((cycle = 1; cycle <= cycles; cycle += 1)); do
  marker="$(python3 "${diagnostics_tool}" marker "${journal_directory}")"
  if ((cycle % 2 == 1)); then
    fault_signal="KILL"
  else
    fault_signal="ABRT"
  fi
  say "Cycle ${cycle}/${cycles}: SIG${fault_signal} connected app pid ${phone_pid}"
  signal_phone "${fault_signal}"
  launch_phone "cycle-${cycle}-relaunch"
  require_connection "cycle-${cycle}" "${marker}"
done

say "In-flight fault: SIGABRT after a refresh starts but before the server can answer"
xcrun simctl terminate "${simulator_udid}" "${bundle_id}"
for _ in {1..40}; do
  if ! kill -0 "${phone_pid}" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
! kill -0 "${phone_pid}" 2>/dev/null \
  || fail "simulator app pid ${phone_pid} survived simctl terminate"
marker="$(python3 "${diagnostics_tool}" marker "${journal_directory}")"
kill -STOP "${host_pid}"
host_suspended=1
launch_phone "inflight-fault"
wait_for_event "inflight-refresh-started" "${marker}" --event hostRefreshStarted
signal_phone ABRT
kill -CONT "${host_pid}"
host_suspended=0
recovery_marker="$(python3 "${diagnostics_tool}" marker "${journal_directory}")"
launch_phone "inflight-relaunch"
require_connection "inflight-recovery" "${recovery_marker}"

touch "${stop_path}"
wait "${host_pid}"
host_pid=""
stop_path=""

say "Simulator process-chaos lane passed"
printf 'Evidence: %s\n' "${output_directory}"
