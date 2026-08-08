#!/usr/bin/env bash
#
# Non-interactive performance entry point for Threading.
#
#   scripts/profile_threading.sh git-stress
#   scripts/profile_threading.sh agent-work-stress
#   scripts/profile_threading.sh conversation-stress
#   scripts/profile_threading.sh conversation-massive-stress
#   scripts/profile_threading.sh conversation-active-turn-stress
#   scripts/profile_threading.sh conversation-residency-stress
#   scripts/profile_threading.sh subagent-stress [child-transcript-path]
#   scripts/profile_threading.sh sidebar-stress
#   scripts/profile_threading.sh file-tree-stress
#   scripts/profile_threading.sh attachment-stress
#   scripts/profile_threading.sh window-resize-stress
#   scripts/profile_threading.sh sample [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh trace "Time Profiler" [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh full [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh full+ [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh ios-simulator-sample [seconds] [booted|simulator-UDID]
#   scripts/profile_threading.sh remote-conversation-stress [rows]
#   scripts/profile_threading.sh ios-conversation-stress [seconds] [rows] [booted|simulator-UDID]
#   scripts/profile_threading.sh cross-device-conversation-stress [seconds] [rows] [booted|simulator-UDID]
#   scripts/profile_threading.sh ios-device-trace "Time Profiler" [seconds] <device-name-or-UDID> [process]
#   scripts/profile_threading.sh ios-device-full [seconds] <device-name-or-UDID> [process]
#   scripts/profile_threading.sh latest
#
# `full` covers the routine UI regression sweep. `full+` adds the expensive, system-wide and
# specialist captures used before release or while investigating a persistent regression.
#
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
performance_directory="${THREADING_PROFILE_OUTPUT:-/tmp/threading-profiles}"
built_in_directory="${HOME}/Library/Application Support/Threading/Performance"

usage() {
  sed -n '3,23p' "$0"
}

resolve_pid() {
  local target="${1:-Threading}"
  if [[ "${target}" =~ ^[0-9]+$ ]]; then
    kill -0 "${target}" 2>/dev/null || {
      echo "No process with pid ${target}." >&2
      return 1
    }
    echo "${target}"
    return
  fi

  local pid
  pid="$(pgrep -x "${target}" | head -n 1)"
  [[ -n "${pid}" ]] || {
    echo "No running process named '${target}'. Launch Threading, then retry." >&2
    return 1
  }
  echo "${pid}"
}

new_run_directory() {
  local label="$1"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local run_directory="${performance_directory}/${stamp}-${label}"
  mkdir -p "${run_directory}"
  echo "${run_directory}"
}

capture_sample() {
  local seconds="$1"
  local target="$2"
  local output_directory="$3"
  local pid
  pid="$(resolve_pid "${target}")"

  echo "Capturing sample for ${seconds}s from pid ${pid}…"
  /usr/bin/sample "${pid}" "${seconds}" 1 \
    -file "${output_directory}/threading.sample.txt"
}

capture_trace() {
  local template="$1"
  local seconds="$2"
  local target="$3"
  local output_directory="$4"
  local pid
  pid="$(resolve_pid "${target}")"
  local slug="${template// /-}"
  slug="${slug//\\//-}"

  echo "Capturing '${template}' for ${seconds}s from pid ${pid}; exercise the target pane now…"
  xcrun xctrace record \
    --template "${template}" \
    --attach "${pid}" \
    --time-limit "${seconds}s" \
    --output "${output_directory}/${slug}.trace" \
    --no-prompt
}

resolve_booted_ios_simulator() {
  local selector="${1:-booted}"
  if [[ "${selector}" != "booted" ]]; then
    xcrun simctl bootstatus "${selector}" -b >/dev/null || {
      echo "iOS simulator '${selector}' is not booted and available." >&2
      return 1
    }
    echo "${selector}"
    return
  fi

  local device_line
  device_line="$(
    xcrun simctl list devices available \
      | awk '
          /^-- iOS / { in_ios = 1; next }
          /^-- / { in_ios = 0 }
          in_ios && /\(Booted\)[[:space:]]*$/ { print; exit }
        '
  )"
  [[ -n "${device_line}" ]] || {
    echo "No booted iOS simulator. Boot one with Simulator or 'xcrun simctl boot <UDID>'." >&2
    return 1
  }

  sed -E 's/.*\(([0-9A-F-]{36})\) \(Booted\)[[:space:]]*$/\1/' <<<"${device_line}"
}

build_ios_simulator_app() {
  local simulator_udid="$1"
  local output_directory="$2"
  local configuration="${3:-Release}"
  local swift_optimization="${4:-}"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  local build_settings=()
  if [[ -n "${swift_optimization}" ]]; then
    build_settings+=("SWIFT_OPTIMIZATION_LEVEL=${swift_optimization}")
  fi

  local build_label="${configuration}"
  if [[ -n "${swift_optimization}" ]]; then
    build_label+=" (${swift_optimization})"
  fi
  echo "Building the ${build_label} iOS app for simulator ${simulator_udid}…"
  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme ThreadingMobile \
      -configuration "${configuration}" \
      -destination "platform=iOS Simulator,id=${simulator_udid}" \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      "${build_settings[@]}" \
      build
  ) 2>&1 | tee "${output_directory}/ios-simulator-build.log"

  local app="${derived_data}/Build/Products/${configuration}-iphonesimulator/ThreadingMobile.app"
  [[ -d "${app}" ]] || {
    echo "Built iOS app not found at ${app}." >&2
    return 1
  }
}

capture_ios_conversation_fixture() {
  local mode="$1"
  local seconds="$2"
  local source_rows="$3"
  local simulator_udid="$4"
  local app="$5"
  local output_directory="$6"
  local label="${mode#conversation-}"
  local stdout_path="${output_directory}/ios-${label}.stdout.log"
  local stderr_path="${output_directory}/ios-${label}.stderr.log"
  local profile_stdout_path="${output_directory}/ios-${label}.profile.stdout.log"
  local profile_stderr_path="${output_directory}/ios-${label}.profile.stderr.log"
  local sample_path="${output_directory}/iOS-${label}.sample.txt"
  # Leave room for a cold 5,000-row collection to mount before the display-link driver starts,
  # and for the final metric to flush before `/usr/bin/sample` exits.
  local scroll_seconds=$((seconds > 4 ? seconds - 4 : 1))

  echo "Launching iOS ${label} fixture with ${source_rows} source rows…"
  xcrun simctl install "${simulator_udid}" "${app}"
  local data_container container_metrics
  data_container="$(
    xcrun simctl get_app_container "${simulator_udid}" codes.threading.mobile data
  )"
  container_metrics="${data_container}/tmp/threading-conversation-performance.log"
  # A fixture must prove that this process emitted its metric; never let an earlier launch make a
  # failed or crashed run look successful.
  rm -f "${container_metrics}"
  local expected_metric="ios-conversation-cold-open mode=${mode}"
  if [[ "${mode}" == "conversation-scroll-stress" ]]; then
    expected_metric="ios-conversation-scroll"
  fi
  local launch_result pid
  launch_result="$(
    SIMCTL_CHILD_THREADING_MOBILE_DEMO="${mode}" \
    SIMCTL_CHILD_THREADING_MOBILE_CONVERSATION_STRESS_ROWS="${source_rows}" \
    SIMCTL_CHILD_THREADING_MOBILE_CONVERSATION_SCROLL_SECONDS="${scroll_seconds}" \
      xcrun simctl launch \
        --terminate-running-process \
        --stdout="${stdout_path}" \
        --stderr="${stderr_path}" \
        "${simulator_udid}" \
        codes.threading.mobile
  )"
  pid="${launch_result##*: }"
  [[ "${pid}" =~ ^[0-9]+$ ]] || {
    echo "Could not resolve the simulator app pid from: ${launch_result}" >&2
    return 1
  }

  # `/usr/bin/sample` at 1 ms is intentionally invasive. Record user-facing latency from a clean
  # launch, then relaunch the identical fixture for the diagnostic call tree.
  local poll_count=$(((seconds + 4) * 10))
  local poll_index
  for ((poll_index = 0; poll_index < poll_count; poll_index += 1)); do
    if [[ -f "${container_metrics}" ]] \
        && rg -q "THREADING_PERF ${expected_metric}" "${container_metrics}"; then
      break
    fi
    sleep 0.1
  done
  if [[ ! -f "${container_metrics}" ]] \
      || ! rg "THREADING_PERF ${expected_metric}" "${container_metrics}"; then
    echo "The ${label} fixture produced no THREADING_PERF metrics." >&2
    return 1
  fi
  cp "${container_metrics}" "${output_directory}/ios-${label}.metrics.log"

  launch_result="$(
    SIMCTL_CHILD_THREADING_MOBILE_DEMO="${mode}" \
    SIMCTL_CHILD_THREADING_MOBILE_CONVERSATION_STRESS_ROWS="${source_rows}" \
    SIMCTL_CHILD_THREADING_MOBILE_CONVERSATION_SCROLL_SECONDS="${scroll_seconds}" \
      xcrun simctl launch \
        --terminate-running-process \
        --stdout="${profile_stdout_path}" \
        --stderr="${profile_stderr_path}" \
        "${simulator_udid}" \
        codes.threading.mobile
  )"
  pid="${launch_result##*: }"
  [[ "${pid}" =~ ^[0-9]+$ ]] || {
    echo "Could not resolve the profiled simulator app pid from: ${launch_result}" >&2
    return 1
  }
  echo "Sampling iOS ${label} fixture pid ${pid} for ${seconds}s…"
  /usr/bin/sample "${pid}" "${seconds}" 1 -file "${sample_path}"
}

run_ios_conversation_stress() {
  local output_directory="$1"
  local seconds="$2"
  local source_rows="$3"
  local simulator_udid="$4"
  [[ "${seconds}" =~ ^[0-9]+$ && "${seconds}" -gt 0 ]] || {
    echo "iOS conversation stress seconds must be a positive integer." >&2
    return 2
  }
  [[ "${source_rows}" =~ ^[0-9]+$ && "${source_rows}" -gt 0 ]] || {
    echo "iOS conversation stress rows must be a positive integer." >&2
    return 2
  }

  # Keep DEBUG-only deterministic fixtures and probes, but optimize app code so reported latency
  # is representative of what users run rather than Swift's intentionally slow -Onone build.
  build_ios_simulator_app "${simulator_udid}" "${output_directory}" Debug -O
  local app="${output_directory}/derived-data/Build/Products/Debug-iphonesimulator/ThreadingMobile.app"
  local cold_seconds=3
  if (( seconds < cold_seconds )); then cold_seconds="${seconds}"; fi
  capture_ios_conversation_fixture \
    conversation-cold-stress "${cold_seconds}" "${source_rows}" \
    "${simulator_udid}" "${app}" "${output_directory}"
  capture_ios_conversation_fixture \
    conversation-scroll-stress "${seconds}" "${source_rows}" \
    "${simulator_udid}" "${app}" "${output_directory}"
}

capture_ios_simulator_sample() {
  local seconds="$1"
  local simulator_udid="$2"
  local app="$3"
  local output_directory="$4"

  echo "Installing and launching the Release app on simulator ${simulator_udid}…"
  xcrun simctl install "${simulator_udid}" "${app}"
  local launch_result pid
  launch_result="$(
    xcrun simctl launch \
      --terminate-running-process \
      "${simulator_udid}" \
      codes.threading.mobile
  )"
  pid="${launch_result##*: }"
  [[ "${pid}" =~ ^[0-9]+$ ]] || {
    echo "Could not resolve the simulator app pid from: ${launch_result}" >&2
    return 1
  }

  echo "Sampling iOS simulator app pid ${pid} for ${seconds}s; exercise it now…"
  /usr/bin/sample "${pid}" "${seconds}" 1 \
    -file "${output_directory}/iOS-Simulator.sample.txt"
}

capture_ios_device_trace() {
  local template="$1"
  local seconds="$2"
  local device="$3"
  local target="$4"
  local output_directory="$5"
  local slug="${template// /-}"
  slug="${slug//\\//-}"

  echo "Capturing iOS '${template}' for ${seconds}s from '${target}' on '${device}'…"
  xcrun xctrace record \
    --template "${template}" \
    --device "${device}" \
    --attach "${target}" \
    --time-limit "${seconds}s" \
    --output "${output_directory}/iOS-Device-${slug}.trace" \
    --no-prompt
}

run_remote_conversation_stress() {
  local output_directory="$1"
  local row_override="${2:-}"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  if [[ -n "${row_override}" ]] \
      && { [[ ! "${row_override}" =~ ^[0-9]+$ ]] \
        || (( 10#${row_override} <= 0 )); }; then
    echo "Remote conversation stress rows must be a positive integer." >&2
    return 2
  fi
  echo "Running deterministic remote catch-up, pagination, delta, and reconnect sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    THREADING_REMOTE_CONVERSATION_STRESS=1 \
    THREADING_REMOTE_CONVERSATION_STRESS_ROWS="${row_override}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.RemoteServerIntegrationTests/testStressRemoteConversationCatchUpWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/remote-conversation-stress.log"
}

run_git_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic Git Review file-index sweep…"

  # Xcode test plans intentionally sanitize the launched test process's environment. Build the
  # normal test bundle through Xcode, then invoke that bundle directly so this opt-in workload
  # receives its gate without permanently enabling a 1,000-row stress case in the fast suite.
  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    THREADING_GIT_STRESS=1 \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.GitReviewViewTests/testStressLargeFileIndexesWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/git-review-stress.log"
}

build_macos_stress_test_bundle() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"

  xcodebuild \
    -project Threading.xcodeproj \
    -scheme Threading \
    -testPlan Threading-Fast \
    -destination "platform=macOS" \
    -configuration Debug \
    -derivedDataPath "${derived_data}" \
    -jobs "${jobs}" \
    -quiet \
    build-for-testing

  local build_directory
  build_directory="$(
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -configuration Debug \
      -destination "platform=macOS" \
      -derivedDataPath "${derived_data}" \
      -showBuildSettings \
      -json \
      | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
  )"
  THREADING_STRESS_APP="${build_directory}/Threading.app"
  THREADING_STRESS_TEST_BUNDLE="${THREADING_STRESS_APP}/Contents/PlugIns/ThreadingTests.xctest"
  [[ -d "${THREADING_STRESS_TEST_BUNDLE}" ]] || {
    echo "Built test bundle not found at ${THREADING_STRESS_TEST_BUNDLE}." >&2
    return 1
  }
}

run_agent_work_stress() {
  local output_directory="$1"
  echo "Running 100k-file, 64-agent work-atlas benchmark…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    THREADING_AGENT_WORK_STRESS=1 \
    DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.FileActivityMapTests/testAgentWorkProjectionStressBenchmark \
        "${THREADING_STRESS_TEST_BUNDLE}"
  ) 2>&1 | tee "${output_directory}/agent-work-stress.log"
}

run_conversation_stress() {
  local output_directory="$1"
  local scale="${2:-routine}"
  local log_name="conversation-stress.log"
  if [[ "${scale}" == "massive" ]]; then
    log_name="conversation-massive-stress.log"
  fi
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic ${scale} native-conversation sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    local workloads=(
      "mixed:10"
      "mixed:25"
      "mixed:50"
      "mixed:100"
      "prose:125"
      "tool-heavy:100"
    )
    if [[ "${scale}" == "massive" ]]; then
      workloads=(
        "mixed:250"
        "mixed:500"
        "mixed:1000"
        "prose:1000"
        "tool-heavy:1000"
      )
    fi
    if [[ -n "${THREADING_CONVERSATION_STRESS_TURNS:-}" ]]; then
      workloads=(
        "${THREADING_CONVERSATION_STRESS_SHAPE:-mixed}:${THREADING_CONVERSATION_STRESS_TURNS}"
      )
    fi
    local workload shape turns
    for workload in "${workloads[@]}"; do
      shape="${workload%%:*}"
      turns="${workload##*:}"
      THREADING_CONVERSATION_STRESS=1 \
      THREADING_CONVERSATION_STRESS_SHAPE="${shape}" \
      THREADING_CONVERSATION_STRESS_TURNS="${turns}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.ConversationRenderTests/testStressNativeConversationWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/${log_name}"
}

run_conversation_active_turn_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic unfolded active-turn sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    local workloads=(
      "100:25"
      "100:100"
      "100:500"
      "1000:500"
    )
    if [[ -n "${THREADING_CONVERSATION_ACTIVE_TOOLS:-}" \
       || -n "${THREADING_CONVERSATION_ACTIVE_BASE_TURNS:-}" ]]; then
      workloads=(
        "${THREADING_CONVERSATION_ACTIVE_BASE_TURNS:-100}:${THREADING_CONVERSATION_ACTIVE_TOOLS:-100}"
      )
    fi
    local workload base_turns tool_count
    for workload in "${workloads[@]}"; do
      base_turns="${workload%%:*}"
      tool_count="${workload##*:}"
      THREADING_CONVERSATION_ACTIVE_STRESS=1 \
      THREADING_CONVERSATION_ACTIVE_BASE_TURNS="${base_turns}" \
      THREADING_CONVERSATION_ACTIVE_TOOLS="${tool_count}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.ConversationRenderTests/testStressActiveConversationTurnWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/conversation-active-turn-stress.log"
}

run_conversation_residency_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic multi-conversation residency sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    # Each workload gets a fresh xctest process so physical-footprint deltas are comparable and
    # cannot inherit allocator high-water marks from the preceding, larger conversation set.
    local workloads=(
      "2:50:mixed"
      "4:50:mixed"
      "8:50:mixed"
      "8:100:mixed"
      "8:100:tool-heavy"
    )
    if [[ -n "${THREADING_CONVERSATION_RESIDENCY_SESSIONS:-}" \
       || -n "${THREADING_CONVERSATION_RESIDENCY_TURNS:-}" \
       || -n "${THREADING_CONVERSATION_RESIDENCY_SHAPE:-}" ]]; then
      workloads=(
        "${THREADING_CONVERSATION_RESIDENCY_SESSIONS:-8}:${THREADING_CONVERSATION_RESIDENCY_TURNS:-50}:${THREADING_CONVERSATION_RESIDENCY_SHAPE:-mixed}"
      )
    fi
    local workload sessions remainder turns shape
    for workload in "${workloads[@]}"; do
      sessions="${workload%%:*}"
      remainder="${workload#*:}"
      turns="${remainder%%:*}"
      shape="${remainder##*:}"
      THREADING_CONVERSATION_RESIDENCY_STRESS=1 \
      THREADING_CONVERSATION_RESIDENCY_SESSIONS="${sessions}" \
      THREADING_CONVERSATION_RESIDENCY_TURNS="${turns}" \
      THREADING_CONVERSATION_RESIDENCY_SHAPE="${shape}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.ConversationRenderTests/testStressConversationResidencyWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/conversation-residency-stress.log"
}

run_subagent_stress() {
  local output_directory="$1"
  local transcript_path="${2:-}"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic Subagents-pane sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    THREADING_SUBAGENT_STRESS=1 \
    THREADING_SUBAGENT_STRESS_TRANSCRIPT="${transcript_path}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.ConversationRenderTests/testStressSubagentTranscriptWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/subagent-stress.log"
}

run_sidebar_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic project-sidebar sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    local workloads=(
      "5:100"
      "10:100"
      "20:100"
      "20:250"
    )
    if [[ -n "${THREADING_SIDEBAR_STRESS_PROJECTS:-}" \
       || -n "${THREADING_SIDEBAR_STRESS_SESSIONS:-}" ]]; then
      workloads=(
        "${THREADING_SIDEBAR_STRESS_PROJECTS:-10}:${THREADING_SIDEBAR_STRESS_SESSIONS:-100}"
      )
    fi
    local workload projects sessions
    for workload in "${workloads[@]}"; do
      projects="${workload%%:*}"
      sessions="${workload##*:}"
      THREADING_SIDEBAR_STRESS=1 \
      THREADING_SIDEBAR_STRESS_PROJECTS="${projects}" \
      THREADING_SIDEBAR_STRESS_SESSIONS="${sessions}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.SidebarTreeBuilderTests/testStressProjectSidebarWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/project-sidebar-stress.log"
}

run_attachment_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic attachment-scan sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    # shape:scope:paths. Both scopes at both extremes, because the interesting comparison is
    # what widening costs on the same buffer — the narrow scope refuses on a `stat`, the wide
    # one takes custody of bytes, and both happen on the main thread.
    local workloads=(
      "absent:narrow:1000"
      "mixed:narrow:1000"
      "mixed:wide:1000"
      "outside:narrow:1000"
      "outside:wide:1000"
      "outside:narrow:5000"
      "outside:wide:5000"
    )
    if [[ -n "${THREADING_ATTACHMENT_STRESS_SHAPE:-}" \
       || -n "${THREADING_ATTACHMENT_STRESS_PATHS:-}" \
       || -n "${THREADING_ATTACHMENT_STRESS_SCOPE:-}" ]]; then
      workloads=(
        "${THREADING_ATTACHMENT_STRESS_SHAPE:-mixed}:${THREADING_ATTACHMENT_STRESS_SCOPE:-narrow}:${THREADING_ATTACHMENT_STRESS_PATHS:-1000}"
      )
    fi
    local workload shape scope paths remainder
    for workload in "${workloads[@]}"; do
      shape="${workload%%:*}"
      remainder="${workload#*:}"
      scope="${remainder%%:*}"
      paths="${workload##*:}"
      THREADING_ATTACHMENT_STRESS=1 \
      THREADING_ATTACHMENT_STRESS_SHAPE="${shape}" \
      THREADING_ATTACHMENT_STRESS_SCOPE="${scope}" \
      THREADING_ATTACHMENT_STRESS_PATHS="${paths}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.SessionAttachmentStoreTests/testStressAttachmentScanWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/attachment-stress.log"
}

run_file_tree_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic file-tree sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    # Each point gets a new process. The fixture is made before its timer starts, and the fresh
    # process keeps AppKit/LaunchServices caches and allocator high-water marks comparable.
    local workloads=(
      "system:flat:100"
      "system:flat:1000"
      "system:flat:5000"
      "system:flat:20000"
      "system:expanded:5000"
      "system:expanded:20000"
      "neo-brutalism:flat:100"
      "neo-brutalism:flat:1000"
      "neo-brutalism:flat:5000"
      "neo-brutalism:flat:20000"
      "neo-brutalism:expanded:5000"
      "neo-brutalism:expanded:20000"
    )
    if [[ -n "${THREADING_FILE_TREE_STRESS_SHAPE:-}" \
       || -n "${THREADING_FILE_TREE_STRESS_ENTRIES:-}" ]]; then
      workloads=(
        "${THREADING_FILE_TREE_STRESS_THEME:-system}:${THREADING_FILE_TREE_STRESS_SHAPE:-flat}:${THREADING_FILE_TREE_STRESS_ENTRIES:-5000}"
      )
    elif [[ -n "${THREADING_FILE_TREE_STRESS_THEME:-}" ]]; then
      workloads=(
        "${THREADING_FILE_TREE_STRESS_THEME}:flat:100"
        "${THREADING_FILE_TREE_STRESS_THEME}:flat:1000"
        "${THREADING_FILE_TREE_STRESS_THEME}:flat:5000"
        "${THREADING_FILE_TREE_STRESS_THEME}:flat:20000"
        "${THREADING_FILE_TREE_STRESS_THEME}:expanded:5000"
        "${THREADING_FILE_TREE_STRESS_THEME}:expanded:20000"
      )
    fi
    local workload theme shape entries remainder
    for workload in "${workloads[@]}"; do
      theme="${workload%%:*}"
      remainder="${workload#*:}"
      shape="${remainder%%:*}"
      entries="${workload##*:}"
      THREADING_FILE_TREE_STRESS=1 \
      THREADING_FILE_TREE_STRESS_THEME="${theme}" \
      THREADING_FILE_TREE_STRESS_SHAPE="${shape}" \
      THREADING_FILE_TREE_STRESS_ENTRIES="${entries}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.FileTreeViewTests/testStressFileTreeWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/file-tree-stress.log"
}

run_window_resize_stress() {
  local output_directory="$1"
  local scale="${2:-routine}"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  local log_name="window-resize-stress.log"
  if [[ "${scale}" == "history-heavy" ]]; then
    log_name="window-resize-history-heavy-stress.log"
  fi
  echo "Running deterministic ${scale} whole-window resize sweep…"

  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -testPlan Threading-Fast \
      -destination "platform=macOS" \
      -configuration Debug \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      build-for-testing

    local build_directory
    build_directory="$(
      xcodebuild \
        -project Threading.xcodeproj \
        -scheme Threading \
        -configuration Debug \
        -destination "platform=macOS" \
        -derivedDataPath "${derived_data}" \
        -showBuildSettings \
        -json \
        | /usr/bin/plutil -extract 0.buildSettings.TARGET_BUILD_DIR raw -o - -
    )"
    local app="${build_directory}/Threading.app"
    local test_bundle="${app}/Contents/PlugIns/ThreadingTests.xctest"
    [[ -d "${test_bundle}" ]] || {
      echo "Built test bundle not found at ${test_bundle}." >&2
      return 1
    }

    local history_lines=0
    if [[ "${scale}" == "history-heavy" ]]; then
      history_lines=5000
    fi
    history_lines="${THREADING_WINDOW_RESIZE_STRESS_HISTORY_LINES:-${history_lines}}"

    THREADING_WINDOW_RESIZE_STRESS=1 \
    THREADING_WINDOW_RESIZE_STRESS_TICKS="${THREADING_WINDOW_RESIZE_STRESS_TICKS:-120}" \
    THREADING_WINDOW_RESIZE_STRESS_HISTORY_LINES="${history_lines}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.WindowEdgeTests/testStressWholeWindowResizeWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/${log_name}"
}

command="${1:-}"
case "${command}" in
  git-stress)
    output_directory="$(new_run_directory git-stress)"
    run_git_stress "${output_directory}"
    ;;

  agent-work-stress)
    output_directory="$(new_run_directory agent-work-stress)"
    run_agent_work_stress "${output_directory}"
    ;;

  conversation-stress)
    output_directory="$(new_run_directory conversation-stress)"
    run_conversation_stress "${output_directory}"
    ;;

  conversation-massive-stress)
    output_directory="$(new_run_directory conversation-massive-stress)"
    run_conversation_stress "${output_directory}" massive
    ;;

  conversation-active-turn-stress)
    output_directory="$(new_run_directory conversation-active-turn-stress)"
    run_conversation_active_turn_stress "${output_directory}"
    ;;

  conversation-residency-stress)
    output_directory="$(new_run_directory conversation-residency-stress)"
    run_conversation_residency_stress "${output_directory}"
    ;;

  subagent-stress)
    output_directory="$(new_run_directory subagent-stress)"
    run_subagent_stress "${output_directory}" "${2:-}"
    ;;

  sidebar-stress)
    output_directory="$(new_run_directory sidebar-stress)"
    run_sidebar_stress "${output_directory}"
    ;;

  file-tree-stress)
    output_directory="$(new_run_directory file-tree-stress)"
    run_file_tree_stress "${output_directory}"
    ;;

  attachment-stress)
    output_directory="$(new_run_directory attachment-stress)"
    run_attachment_stress "${output_directory}"
    ;;

  window-resize-stress)
    output_directory="$(new_run_directory window-resize-stress)"
    run_window_resize_stress "${output_directory}"
    ;;

  sample)
    seconds="${2:-15}"
    target="${3:-Threading}"
    output_directory="$(new_run_directory sample)"
    capture_sample "${seconds}" "${target}" "${output_directory}"
    ;;

  trace)
    template="${2:-Time Profiler}"
    seconds="${3:-15}"
    target="${4:-Threading}"
    output_directory="$(new_run_directory trace)"
    capture_trace "${template}" "${seconds}" "${target}" "${output_directory}"
    ;;

  ios-simulator-sample)
    seconds="${2:-15}"
    simulator_udid="$(resolve_booted_ios_simulator "${3:-booted}")"
    output_directory="$(new_run_directory ios-simulator-sample)"
    build_ios_simulator_app "${simulator_udid}" "${output_directory}"
    ios_app="${output_directory}/derived-data/Build/Products/Release-iphonesimulator/ThreadingMobile.app"
    capture_ios_simulator_sample \
      "${seconds}" "${simulator_udid}" "${ios_app}" "${output_directory}"
    ;;

  remote-conversation-stress)
    rows="${2:-}"
    output_directory="$(new_run_directory remote-conversation-stress)"
    run_remote_conversation_stress "${output_directory}" "${rows}"
    ;;

  ios-conversation-stress)
    seconds="${2:-12}"
    rows="${3:-5000}"
    simulator_udid="$(resolve_booted_ios_simulator "${4:-booted}")"
    output_directory="$(new_run_directory ios-conversation-stress)"
    run_ios_conversation_stress \
      "${output_directory}" "${seconds}" "${rows}" "${simulator_udid}"
    ;;

  cross-device-conversation-stress)
    seconds="${2:-12}"
    rows="${3:-5000}"
    simulator_udid="$(resolve_booted_ios_simulator "${4:-booted}")"
    output_directory="$(new_run_directory cross-device-conversation-stress)"
    run_remote_conversation_stress "${output_directory}" "${rows}"
    THREADING_CONVERSATION_STRESS_TURNS="${THREADING_CROSS_DEVICE_MAC_TURNS:-1000}" \
    THREADING_CONVERSATION_STRESS_SHAPE="${THREADING_CROSS_DEVICE_MAC_SHAPE:-mixed}" \
      run_conversation_stress "${output_directory}"
    run_ios_conversation_stress \
      "${output_directory}" "${seconds}" "${rows}" "${simulator_udid}"
    ;;

  ios-device-trace)
    template="${2:-Time Profiler}"
    seconds="${3:-15}"
    device="${4:-}"
    [[ -n "${device}" ]] || {
      echo "ios-device-trace requires a device name or UDID." >&2
      exit 2
    }
    target="${5:-ThreadingMobile}"
    output_directory="$(new_run_directory ios-device-trace)"
    capture_ios_device_trace "${template}" "${seconds}" "${device}" "${target}" "${output_directory}"
    ;;

  ios-device-full)
    seconds="${2:-15}"
    device="${3:-}"
    [[ -n "${device}" ]] || {
      echo "ios-device-full requires a device name or UDID." >&2
      exit 2
    }
    target="${4:-ThreadingMobile}"
    output_directory="$(new_run_directory ios-device-full)"
    ios_templates=(
      "Time Profiler"
      "Animation Hitches"
      "Allocations"
    )
    for template in "${ios_templates[@]}"; do
      capture_ios_device_trace "${template}" "${seconds}" "${device}" "${target}" "${output_directory}"
    done
    ;;

  full|full+)
    seconds="${2:-15}"
    target="${3:-Threading}"
    output_directory="$(new_run_directory "${command}")"

    run_git_stress "${output_directory}"
    run_conversation_stress "${output_directory}"
    run_subagent_stress "${output_directory}"
    run_sidebar_stress "${output_directory}"
    run_file_tree_stress "${output_directory}"
    run_attachment_stress "${output_directory}"
    run_window_resize_stress "${output_directory}"
    capture_sample "${seconds}" "${target}" "${output_directory}"

    full_templates=(
      "Time Profiler"
      "Animation Hitches"
      "Allocations"
    )
    for template in "${full_templates[@]}"; do
      capture_trace "${template}" "${seconds}" "${target}" "${output_directory}"
    done

    if [[ "${command}" == "full+" ]]; then
      run_conversation_stress "${output_directory}" massive
      run_conversation_active_turn_stress "${output_directory}"
      run_conversation_residency_stress "${output_directory}"
      run_window_resize_stress "${output_directory}" history-heavy

      full_plus_templates=(
        "CPU Profiler"
        "File Activity"
        "Leaks"
        "Swift Concurrency"
        "System Trace"
        "Power Profiler"
      )
      for template in "${full_plus_templates[@]}"; do
        capture_trace "${template}" "${seconds}" "${target}" "${output_directory}"
      done
    fi
    ;;

  latest)
    echo "CLI captures:"
    find "${performance_directory}" -maxdepth 2 -type f -print 2>/dev/null \
      | sort \
      | tail -n 30
    echo
    echo "Built-in traces and MetricKit payloads:"
    find "${built_in_directory}" -maxdepth 3 -type f -print 2>/dev/null \
      | sort \
      | tail -n 30
    exit 0
    ;;

  -h|--help|help)
    usage
    exit 0
    ;;

  *)
    usage >&2
    exit 2
    ;;
esac

echo "Profile artifacts: ${output_directory}"
