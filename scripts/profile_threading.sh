#!/usr/bin/env bash
#
# Non-interactive performance entry point for Threading.
#
#   scripts/profile_threading.sh git-stress
#   scripts/profile_threading.sh git-repository-stress <checkout> [base] [target] [runs]
#   scripts/profile_threading.sh agent-work-stress
#   scripts/profile_threading.sh chart-stress
#   scripts/profile_threading.sh tools-settings-stress
#   scripts/profile_threading.sh settings-search-stress
#   scripts/profile_threading.sh extensions-preferences-stress
#   scripts/profile_threading.sh archived-settings-stress
#   scripts/profile_threading.sh component-gallery-stress
#   scripts/profile_threading.sh changed-files-stress
#   scripts/profile_threading.sh extension-ui-stress
#   scripts/profile_threading.sh baseline-library-stress
#   scripts/profile_threading.sh conversation-stress
#   scripts/profile_threading.sh conversation-massive-stress
#   scripts/profile_threading.sh conversation-active-turn-stress
#   scripts/profile_threading.sh conversation-residency-stress
#   scripts/profile_threading.sh subagent-stress [child-transcript-path]
#   scripts/profile_threading.sh sidebar-stress
#   scripts/profile_threading.sh file-tree-stress
#   scripts/profile_threading.sh attachment-stress
#   scripts/profile_threading.sh attachment-format-stress
#   scripts/profile_threading.sh window-resize-stress
#   scripts/profile_threading.sh display-pane-stress
#   scripts/profile_threading.sh launch-ledger-stress
#   scripts/profile_threading.sh startup
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
  sed -n '3,40p' "$0"
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
  if ! rg -q \
      "THREADING_PERF ios-conversation-cold-open .*invalid_width_cells=0 settle_tasks=1" \
      "${container_metrics}"; then
    echo "The ${label} fixture mounted cells before receiving its real width or scheduled duplicate cold settling." >&2
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

prepare_git_stress_bundle() {
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
  git_stress_app="${build_directory}/Threading.app"
  git_stress_test_bundle="${git_stress_app}/Contents/PlugIns/ThreadingTests.xctest"
  [[ -d "${git_stress_test_bundle}" ]] || {
    echo "Built test bundle not found at ${git_stress_test_bundle}." >&2
    return 1
  }
}

run_git_stress() {
  local output_directory="$1"
  echo "Running deterministic Git Review file-index sweeps…"

  # Xcode test plans intentionally sanitize the launched test process's environment. Build the
  # normal test bundle through Xcode, then invoke that bundle directly so this opt-in workload
  # receives its gate without permanently enabling a 1,000-row stress case in the fast suite.
  (
    cd "${repository_directory}"
    prepare_git_stress_bundle "${output_directory}"

    THREADING_GIT_STRESS=1 \
    DYLD_LIBRARY_PATH="${git_stress_app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${git_stress_app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.GitReviewViewTests/testStressLargeFileIndexesWhenEnabled \
        "${git_stress_test_bundle}"

    THREADING_GIT_MASSIVE_STRESS=1 \
    DYLD_LIBRARY_PATH="${git_stress_app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${git_stress_app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.GitReviewViewTests/testStressMassiveExpandedFileIndexWhenEnabled \
        "${git_stress_test_bundle}"
  ) 2>&1 | tee "${output_directory}/git-review-stress.log"
}

run_git_repository_stress() {
  local output_directory="$1"
  local checkout="$2"
  local base="${3:-HEAD~100}"
  local target="${4:-HEAD}"
  local runs="${5:-3}"

  [[ -d "${checkout}" ]] || {
    echo "Git repository stress checkout is not a directory: ${checkout}" >&2
    return 2
  }
  git -C "${checkout}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "Git repository stress path is not a worktree: ${checkout}" >&2
    return 2
  }
  [[ "${runs}" =~ ^[1-9][0-9]*$ ]] || {
    echo "Git repository stress runs must be a positive integer, got: ${runs}" >&2
    return 2
  }

  echo "Running real Git Review sweep against the supplied checkout (${runs} runs)…"
  (
    cd "${repository_directory}"
    prepare_git_stress_bundle "${output_directory}"

    THREADING_GIT_REPOSITORY_STRESS_PATH="${checkout}" \
    THREADING_GIT_REPOSITORY_STRESS_BASE="${base}" \
    THREADING_GIT_REPOSITORY_STRESS_TARGET="${target}" \
    THREADING_GIT_REPOSITORY_STRESS_RUNS="${runs}" \
    DYLD_LIBRARY_PATH="${git_stress_app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${git_stress_app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.GitReviewViewTests/testStressRealRepositoryWhenEnabled \
        "${git_stress_test_bundle}"
  ) 2>&1 | tee "${output_directory}/git-repository-stress.log"
}

run_tools_settings_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic Tools settings render, disclosure and scroll sweep…"

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

    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_TOOLS_SETTINGS_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_TOOLS_SETTINGS_STRESS_THEME}")
    fi
    local theme
    for theme in "${themes[@]}"; do
      THREADING_TOOLS_SETTINGS_STRESS=1 \
      THREADING_TOOLS_SETTINGS_STRESS_THEME="${theme}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.SettingsDisclosureRenderTests/testStressToolsPreferencesWhenEnabled \
          "${test_bundle}"
    done

    THREADING_TOOLS_WEBSITE_ACCESS_STRESS=1 \
    THREADING_TOOLS_WEBSITE_ACCESS_STRESS_ORIGINS="${THREADING_TOOLS_WEBSITE_ACCESS_STRESS_ORIGINS:-1000}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.SettingsDisclosureRenderTests/testStressToolsWebsiteAccessWhenEnabled \
        "${test_bundle}"

    THREADING_TOOLS_BROWSER_SIGN_IN_STRESS=1 \
    THREADING_TOOLS_BROWSER_SIGN_IN_STRESS_ORIGINS="${THREADING_TOOLS_BROWSER_SIGN_IN_STRESS_ORIGINS:-1000}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.SettingsDisclosureRenderTests/testStressToolsBrowserSignInWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/tools-settings-stress.log"
}

run_settings_search_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic settings-search result and query-update sweep…"

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

    THREADING_SETTINGS_SEARCH_STRESS=1 \
    THREADING_SETTINGS_SEARCH_STRESS_RESULTS="${THREADING_SETTINGS_SEARCH_STRESS_RESULTS:-2048}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.SettingsRowLayoutTests/testStressSettingsSearchResultsWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/settings-search-stress.log"
}

run_extensions_preferences_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running deterministic Extensions preferences package-ceiling sweep…"

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

    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_EXTENSIONS_PREFERENCES_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_EXTENSIONS_PREFERENCES_STRESS_THEME}")
    fi
    local theme
    for theme in "${themes[@]}"; do
      THREADING_EXTENSIONS_PREFERENCES_STRESS=1 \
      THREADING_EXTENSIONS_PREFERENCES_STRESS_PACKAGES="${THREADING_EXTENSIONS_PREFERENCES_STRESS_PACKAGES:-256}" \
      THREADING_EXTENSIONS_PREFERENCES_STRESS_THEME="${theme}" \
      DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.ExtensionPackageStoreTests/testStressExtensionsPreferencesWhenEnabled \
          "${test_bundle}"
    done
  ) 2>&1 | tee "${output_directory}/extensions-preferences-stress.log"
}

run_archived_settings_stress() {
  local output_directory="$1"
  echo "Running deterministic Archived settings cold, disclosure and scroll sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_ARCHIVED_SETTINGS_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_ARCHIVED_SETTINGS_STRESS_THEME}")
    fi
    local theme
    for theme in "${themes[@]}"; do
      THREADING_ARCHIVED_SETTINGS_STRESS=1 \
      THREADING_ARCHIVED_SETTINGS_STRESS_ROWS="${THREADING_ARCHIVED_SETTINGS_STRESS_ROWS:-1000}" \
      THREADING_ARCHIVED_SETTINGS_STRESS_THEME="${theme}" \
      DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.SettingsDisclosureRenderTests/testStressArchivedPreferencesWhenEnabled \
          "${THREADING_STRESS_TEST_BUNDLE}"
    done
  ) 2>&1 | tee "${output_directory}/archived-settings-stress.log"
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

run_launch_ledger_stress() {
  local output_directory="$1"
  local log="${output_directory}/launch-ledger-stress.log"
  echo "Running the deterministic 512-record launch-ledger parser sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    THREADING_LAUNCH_LEDGER_STRESS=1 \
    DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.LaunchLedgerTests/testStressParserAtRetentionCeilingWhenEnabled \
        "${THREADING_STRESS_TEST_BUNDLE}"
  ) 2>&1 | tee "${log}"

  rg -q '^THREADING_PERF launch-ledger-parser records=512 ' "${log}" || {
    echo "The launch-ledger fixture produced no complete metric." >&2
    return 1
  }
}

run_component_gallery_stress() {
  local output_directory="$1"
  echo "Running deterministic Component Gallery construction and scroll sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    THREADING_COMPONENT_GALLERY_STRESS=1 \
    DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.ThemedControlTests/testComponentGalleryScrollStress \
        "${THREADING_STRESS_TEST_BUNDLE}"
  ) 2>&1 | tee "${output_directory}/component-gallery-stress.log"
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

run_chart_stress() {
  local output_directory="$1"
  echo "Running maximum-contract agent-chart pipeline sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local workloads=(
      "bar:0"
      "bar:1"
      "ranking:0"
      "line:0"
      "area:0"
    )
    if [[ -n "${THREADING_CHART_STRESS_KIND:-}" \
       || -n "${THREADING_CHART_STRESS_STACKED:-}" ]]; then
      workloads=(
        "${THREADING_CHART_STRESS_KIND:-bar}:${THREADING_CHART_STRESS_STACKED:-0}"
      )
    fi

    local workload kind stacked
    for workload in "${workloads[@]}"; do
      kind="${workload%%:*}"
      stacked="${workload##*:}"
      THREADING_CHART_STRESS=1 \
      THREADING_CHART_STRESS_KIND="${kind}" \
      THREADING_CHART_STRESS_STACKED="${stacked}" \
      DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.UsageDashboardPerformanceTests/testStressAgentChartPipelineWhenEnabled \
          "${THREADING_STRESS_TEST_BUNDLE}"
    done
  ) 2>&1 | tee "${output_directory}/chart-stress.log"
}

run_changed_files_stress() {
  local output_directory="$1"
  echo "Running deterministic changed-files card construction and disclosure sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local workloads=(
      "collapsed:10:0"
      "collapsed:100:0"
      "collapsed:500:0"
      "collapsed:1000:0"
      "previews:10:400"
      "previews:100:400"
      "previews:174:400"
    )
    local override_shape="${THREADING_CHANGED_FILES_STRESS_SHAPE:-}"
    local override_files="${THREADING_CHANGED_FILES_STRESS_FILES:-}"
    if [[ -n "${override_shape}" || -n "${override_files}" ]]; then
      local shape="${override_shape:-collapsed}"
      local default_files=1000
      if [[ "${shape}" == "previews" ]]; then default_files=174; fi
      workloads=(
        "${shape}:${override_files:-${default_files}}:${THREADING_CHANGED_FILES_STRESS_LINES:-400}"
      )
    fi

    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_CHANGED_FILES_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_CHANGED_FILES_STRESS_THEME}")
    fi
    local theme workload shape files lines
    for theme in "${themes[@]}"; do
      for workload in "${workloads[@]}"; do
        IFS=: read -r shape files lines <<<"${workload}"
        THREADING_CHANGED_FILES_STRESS=1 \
        THREADING_CHANGED_FILES_STRESS_THEME="${theme}" \
        THREADING_CHANGED_FILES_STRESS_SHAPE="${shape}" \
        THREADING_CHANGED_FILES_STRESS_FILES="${files}" \
        THREADING_CHANGED_FILES_STRESS_LINES="${lines}" \
        DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
        DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
          xcrun xctest \
            -XCTest ThreadingTests.ChangedFilesCardTests/testStressChangedFilesCardWhenEnabled \
            "${THREADING_STRESS_TEST_BUNDLE}"
      done
    done
  ) 2>&1 | tee "${output_directory}/changed-files-stress.log"
}

run_extension_ui_stress() {
  local output_directory="$1"
  echo "Running deterministic extension panel and settings scaling sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local panel_points=(50 250 500)
    if [[ -n "${THREADING_EXTENSION_UI_STRESS_NODES:-}" ]]; then
      panel_points=("${THREADING_EXTENSION_UI_STRESS_NODES}")
    fi
    local settings_points=(32 128 512)
    if [[ -n "${THREADING_EXTENSION_SETTINGS_STRESS_FIELDS:-}" ]]; then
      settings_points=("${THREADING_EXTENSION_SETTINGS_STRESS_FIELDS}")
    fi
    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_EXTENSION_UI_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_EXTENSION_UI_STRESS_THEME}")
    fi

    local theme count
    for theme in "${themes[@]}"; do
      for count in "${panel_points[@]}"; do
        THREADING_EXTENSION_UI_STRESS=1 \
        THREADING_EXTENSION_UI_STRESS_THEME="${theme}" \
        THREADING_EXTENSION_UI_STRESS_NODES="${count}" \
        DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
        DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
          xcrun xctest \
            -XCTest ThreadingTests.ExtensionPanelLayoutTests/testStressExtensionPanelWhenEnabled \
            "${THREADING_STRESS_TEST_BUNDLE}"
      done
      for count in "${settings_points[@]}"; do
        THREADING_EXTENSION_SETTINGS_STRESS=1 \
        THREADING_EXTENSION_UI_STRESS_THEME="${theme}" \
        THREADING_EXTENSION_SETTINGS_STRESS_FIELDS="${count}" \
        DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
        DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
          xcrun xctest \
            -XCTest ThreadingTests.ExtensionPanelLayoutTests/testStressExtensionSettingsWhenEnabled \
            "${THREADING_STRESS_TEST_BUNDLE}"
      done
    done
  ) 2>&1 | tee "${output_directory}/extension-ui-stress.log"
}

run_baseline_library_stress() {
  local output_directory="$1"
  echo "Running deterministic browser baseline-library cold-load and mutation sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local points=(10 100 200)
    if [[ -n "${THREADING_BASELINE_LIBRARY_STRESS_COUNT:-}" ]]; then
      points=("${THREADING_BASELINE_LIBRARY_STRESS_COUNT}")
    fi
    local themes=(system neo-brutalism)
    if [[ -n "${THREADING_BASELINE_LIBRARY_STRESS_THEME:-}" ]]; then
      themes=("${THREADING_BASELINE_LIBRARY_STRESS_THEME}")
    fi
    local theme count
    for theme in "${themes[@]}"; do
      for count in "${points[@]}"; do
        THREADING_BASELINE_LIBRARY_STRESS=1 \
        THREADING_BASELINE_LIBRARY_STRESS_THEME="${theme}" \
        THREADING_BASELINE_LIBRARY_STRESS_COUNT="${count}" \
        DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
        DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
          xcrun xctest \
            -XCTest ThreadingTests.BrowserBaselineUITests/testStressBaselineLibraryWhenEnabled \
            "${THREADING_STRESS_TEST_BUNDLE}"
      done
    done
  ) 2>&1 | tee "${output_directory}/baseline-library-stress.log"
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

  if ! rg -q \
    "THREADING_PERF subagent-transcript .*summary_rebuilds=1 .*styled_markdown_during_render=0" \
    "${output_directory}/subagent-stress.log"; then
    echo "Subagents stress did not preserve lazy Markdown and single-pass navigation." >&2
    return 1
  fi
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
      "manual:5:100"
      "manual:10:100"
      "manual:20:100"
      "manual:20:250"
      "recentActivity:20:250"
      "name:20:250"
    )
    if [[ -n "${THREADING_SIDEBAR_STRESS_PROJECTS:-}" \
       || -n "${THREADING_SIDEBAR_STRESS_SESSIONS:-}" \
       || -n "${THREADING_SIDEBAR_STRESS_ORDER:-}" ]]; then
      workloads=(
        "${THREADING_SIDEBAR_STRESS_ORDER:-manual}:${THREADING_SIDEBAR_STRESS_PROJECTS:-10}:${THREADING_SIDEBAR_STRESS_SESSIONS:-100}"
      )
    fi
    local workload order remainder projects sessions
    for workload in "${workloads[@]}"; do
      order="${workload%%:*}"
      remainder="${workload#*:}"
      projects="${remainder%%:*}"
      sessions="${remainder##*:}"
      THREADING_SIDEBAR_STRESS=1 \
      THREADING_SIDEBAR_STRESS_ORDER="${order}" \
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
    # what widening costs on the same buffer. Matching, existence checks and containment run on
    # the worker; newly visible rows are admitted on the main actor, where wide scope may take
    # custody of bytes. The fixture reports scheduling, resolution-worker, custody-worker,
    # main-actor apply and end-to-end time separately. Narrow rows also time the pane's async
    # scope widening; outside/wide rows replace a full generation to expose eviction cleanup.
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

run_attachment_format_stress() {
  local output_directory="$1"
  echo "Running capped attachment-format mount and preview sweep…"

  (
    cd "${repository_directory}"
    build_macos_stress_test_bundle "${output_directory}"

    local workloads=(image pdf html archive document diagram mixed)
    if [[ -n "${THREADING_ATTACHMENT_FORMAT_STRESS_KIND:-}" ]]; then
      workloads=("${THREADING_ATTACHMENT_FORMAT_STRESS_KIND}")
    fi

    local format
    for format in "${workloads[@]}"; do
      THREADING_ATTACHMENT_FORMAT_STRESS=1 \
      THREADING_ATTACHMENT_FORMAT_STRESS_KIND="${format}" \
      DYLD_LIBRARY_PATH="${THREADING_STRESS_APP}/Contents/MacOS" \
      DYLD_FRAMEWORK_PATH="${THREADING_STRESS_APP}/Contents/Frameworks" \
        xcrun xctest \
          -XCTest ThreadingTests.SessionAttachmentsLayoutTests/testStressAttachmentFormatPipelineWhenEnabled \
          "${THREADING_STRESS_TEST_BUNDLE}"
    done
  ) 2>&1 | tee "${output_directory}/attachment-format-stress.log"
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

run_display_pane_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local derived_data="${output_directory}/derived-data"
  echo "Running Codex TUI display-pane transition sweep…"

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

    THREADING_DISPLAY_PANE_STRESS=1 \
    THREADING_DISPLAY_PANE_STRESS_CYCLES="${THREADING_DISPLAY_PANE_STRESS_CYCLES:-3}" \
    DYLD_LIBRARY_PATH="${app}/Contents/MacOS" \
    DYLD_FRAMEWORK_PATH="${app}/Contents/Frameworks" \
      xcrun xctest \
        -XCTest ThreadingTests.WindowEdgeTests/testStressDisplayPaneTransitionBesideCodexWhenEnabled \
        "${test_bundle}"
  ) 2>&1 | tee "${output_directory}/display-pane-stress.log"
}

prepare_startup_profile_home() {
  local profile_identifier="$1"
  local profile_home="$2"
  local source_home="${HOME}"
  local source_support="${source_home}/Library/Application Support/Threading"
  local profile_support_parent="${profile_home}/Library/Application Support"
  local profile_support="${profile_support_parent}/Threading"
  local source_preferences="${source_home}/Library/Preferences/codes.threading.plist"
  local profile_preferences="${profile_home}/Library/Preferences/${profile_identifier}.plist"

  mkdir -p "${profile_support_parent}" "${profile_home}/Library/Preferences"
  if [[ -d "${source_support}" ]]; then
    # This is an APFS clone, not a second 2.6 GB copy. It gives every non-database startup store
    # its real shape while ensuring launch markers, logs, extension state and icon reads cannot
    # mutate the running app's directory. Atomic JSON replacements remain complete in the clone.
    /bin/cp -cR "${source_support}" "${profile_support}"

    # Cloning the three live SQLite files independently could pair a database page with the wrong
    # WAL generation. Replace that family with one SQLite-owned snapshot taken through the live
    # reader API; the source remains untouched and may continue serving the installed app.
    if [[ -f "${source_support}/threading.db" ]]; then
      rm -f \
        "${profile_support}/threading.db" \
        "${profile_support}/threading.db-wal" \
        "${profile_support}/threading.db-shm"
      /usr/bin/sqlite3 \
        "${source_support}/threading.db" \
        ".timeout 5000" \
        ".backup '${profile_support}/threading.db'"
    fi
  else
    mkdir -p "${profile_support}"
  fi

  # The measured app has a throwaway bundle id so LaunchServices cannot redirect xctrace to the
  # installed build. Give that domain the real preferences too; otherwise a profile of a themed,
  # resized window silently measures factory defaults instead.
  if [[ -f "${source_preferences}" ]]; then
    /bin/cp -c "${source_preferences}" "${profile_preferences}"
  fi
}

clone_startup_profile_home() {
  local template_home="$1"
  local run_home="$2"
  /bin/cp -cR "${template_home}" "${run_home}"
}

# `xctrace record --template "App Launch"` can return with the process it launched still
# suspended. A suspended target ignores TERM until it is continued, so merely waiting for
# xctrace—or restarting the Dock—leaves one live app per capture. Match the complete executable
# path: startup captures use a throwaway app identity precisely so cleanup must never reach the
# installed Threading process or another capture's isolated copy.
startup_profile_process_ids() {
  local executable="$1"
  /bin/ps -axww -o pid=,command= | /usr/bin/awk -v executable="${executable}" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if ($0 == executable || index($0, executable " ") == 1) {
        print pid
      }
    }
  '
}

signal_startup_profile_processes() {
  local executable="$1"
  local signal="$2"
  local pid
  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    kill "-${signal}" "${pid}" 2>/dev/null || true
  done < <(startup_profile_process_ids "${executable}")
}

terminate_startup_profile_processes() {
  local executable="$1"
  local attempt

  # Queue termination while the target is still stopped, then let it run just far enough for
  # the signal to take effect. This order avoids briefly resuming a profiled copy into ordinary
  # application work.
  signal_startup_profile_processes "${executable}" TERM
  signal_startup_profile_processes "${executable}" CONT

  for ((attempt = 0; attempt < 20; attempt += 1)); do
    if [[ -z "$(startup_profile_process_ids "${executable}")" ]]; then
      return
    fi
    sleep 0.05
  done

  # TERM is normally immediate. Keep cleanup bounded for a wedged AppKit shutdown, and re-match
  # the executable path before KILL so a recycled pid can never widen the target.
  signal_startup_profile_processes "${executable}" KILL
}

cleanup_startup_profile() {
  local executable="$1"
  local snapshot_root="$2"
  terminate_startup_profile_processes "${executable}"
  rm -rf -- "${snapshot_root}"
}

run_startup_profile() (
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
  local runs="${THREADING_STARTUP_PROFILE_RUNS:-3}"
  local configuration="${THREADING_STARTUP_PROFILE_CONFIGURATION:-Debug}"
  local architecture="${THREADING_STARTUP_PROFILE_ARCH:-$(uname -m)}"
  local derived_data="${THREADING_STARTUP_PROFILE_DERIVED_DATA:-${output_directory}/derived-data}"
  local direct_log="${output_directory}/startup-runs.log"
  local trace_stdout="${output_directory}/startup-trace.stdout.log"
  local trace_path="${output_directory}/App-Launch.trace"

  [[ "${runs}" =~ ^[1-9][0-9]*$ ]] || {
    echo "THREADING_STARTUP_PROFILE_RUNS must be a positive integer." >&2
    return 2
  }

  echo "Building the ${configuration} macOS app for cold-launch profiling…"
  (
    cd "${repository_directory}"
    xcodebuild \
      -project Threading.xcodeproj \
      -scheme Threading \
      -configuration "${configuration}" \
      -destination "platform=macOS,arch=${architecture}" \
      -derivedDataPath "${derived_data}" \
      -jobs "${jobs}" \
      -quiet \
      ENABLE_CODE_COVERAGE=NO \
      CLANG_COVERAGE_MAPPING=NO \
      ARCHS="${architecture}" \
      ONLY_ACTIVE_ARCH=YES \
      build
  ) 2>&1 | tee "${output_directory}/startup-build.log"

  local app="${derived_data}/Build/Products/${configuration}/Threading.app"
  [[ -d "${app}" ]] || {
    echo "Built app not found at ${app}." >&2
    return 1
  }

  # LaunchServices can redirect xctrace to an installed app with the same bundle identity.
  # Give the measured copy an isolated identity and ad-hoc signature so the trace always owns
  # the binary built above. The direct repetitions use that same copy.
  local profile_app="${output_directory}/ThreadingStartupProfile.app"
  local profile_identifier="codes.threading.startup-profile.run$(date +%s)$$"
  /usr/bin/ditto "${app}" "${profile_app}"
  /usr/bin/plutil -replace CFBundleIdentifier -string "${profile_identifier}" \
    "${profile_app}/Contents/Info.plist"
  /usr/bin/plutil -replace CFBundleName -string "ThreadingStartupProfile" \
    "${profile_app}/Contents/Info.plist"
  /usr/bin/codesign --force --deep --sign - "${profile_app}"

  # Each measured process receives the same pristine snapshot. Besides making the command safe
  # while Threading is open, this prevents run 2 from inheriting run 1's launch-ledger writes.
  local snapshot_root
  snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/threading-startup-state.XXXXXX")"
  local executable="${profile_app}/Contents/MacOS/Threading"
  trap 'cleanup_startup_profile "${executable}" "${snapshot_root}"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local template_home="${snapshot_root}/template"
  echo "Snapshotting startup state without disturbing the running app…"
  prepare_startup_profile_home "${profile_identifier}" "${template_home}"

  echo "Running ${runs} direct cold-launch measurements…"
  local run
  for ((run = 1; run <= runs; run += 1)); do
    echo "Startup run ${run}/${runs}"
    local run_home="${snapshot_root}/direct-${run}"
    clone_startup_profile_home "${template_home}" "${run_home}"
    CFFIXED_USER_HOME="${run_home}" \
      THREADING_STARTUP_PROFILE=1 \
      "${executable}" 2>&1 | tee -a "${direct_log}"
  done

  local metric_count
  metric_count="$(rg -c '^THREADING_PERF app-startup ' "${direct_log}" || true)"
  [[ "${metric_count}" == "${runs}" ]] || {
    echo "Expected ${runs} startup metrics, found ${metric_count:-0}." >&2
    return 1
  }
  local settled_metric_count
  settled_metric_count="$(
    rg -c '^THREADING_PERF app-startup .* total_to_frame_ms=[0-9]' "${direct_log}" || true
  )"
  [[ "${settled_metric_count}" == "${runs}" ]] || {
    echo "Expected ${runs} settled-frame startup metrics, found ${settled_metric_count:-0}." >&2
    return 1
  }

  echo "Recording one isolated App Launch trace…"
  local trace_home="${snapshot_root}/trace"
  clone_startup_profile_home "${template_home}" "${trace_home}"
  xcrun xctrace record \
    --template "App Launch" \
    --time-limit 3s \
    --output "${trace_path}" \
    --target-stdout "${trace_stdout}" \
    --env THREADING_STARTUP_PROFILE=1 \
    --env CFFIXED_USER_HOME="${trace_home}" \
    --no-prompt \
    --launch -- "${profile_app}"

  rg '^THREADING_PERF app-startup .* total_to_frame_ms=[0-9]' "${trace_stdout}" || {
    echo "The App Launch trace produced no settled-frame startup metric." >&2
    return 1
  }
)

command="${1:-}"
case "${command}" in
  git-stress)
    output_directory="$(new_run_directory git-stress)"
    run_git_stress "${output_directory}"
    ;;

  git-repository-stress)
    checkout="${2:-${THREADING_GIT_REPOSITORY_STRESS_PATH:-}}"
    [[ -n "${checkout}" ]] || {
      echo "git-repository-stress requires an existing checkout path." >&2
      usage >&2
      exit 2
    }
    base="${3:-${THREADING_GIT_REPOSITORY_STRESS_BASE:-HEAD~100}}"
    target_revision="${4:-${THREADING_GIT_REPOSITORY_STRESS_TARGET:-HEAD}}"
    repository_runs="${5:-${THREADING_GIT_REPOSITORY_STRESS_RUNS:-3}}"
    output_directory="$(new_run_directory git-repository-stress)"
    run_git_repository_stress \
      "${output_directory}" \
      "${checkout}" \
      "${base}" \
      "${target_revision}" \
      "${repository_runs}"
    ;;

  agent-work-stress)
    output_directory="$(new_run_directory agent-work-stress)"
    run_agent_work_stress "${output_directory}"
    ;;

  chart-stress)
    output_directory="$(new_run_directory chart-stress)"
    run_chart_stress "${output_directory}"
    ;;

  tools-settings-stress)
    output_directory="$(new_run_directory tools-settings-stress)"
    run_tools_settings_stress "${output_directory}"
    ;;

  settings-search-stress)
    output_directory="$(new_run_directory settings-search-stress)"
    run_settings_search_stress "${output_directory}"
    ;;

  extensions-preferences-stress)
    output_directory="$(new_run_directory extensions-preferences-stress)"
    run_extensions_preferences_stress "${output_directory}"
    ;;

  archived-settings-stress)
    output_directory="$(new_run_directory archived-settings-stress)"
    run_archived_settings_stress "${output_directory}"
    ;;

  component-gallery-stress)
    output_directory="$(new_run_directory component-gallery-stress)"
    run_component_gallery_stress "${output_directory}"
    ;;

  changed-files-stress)
    output_directory="$(new_run_directory changed-files-stress)"
    run_changed_files_stress "${output_directory}"
    ;;

  extension-ui-stress)
    output_directory="$(new_run_directory extension-ui-stress)"
    run_extension_ui_stress "${output_directory}"
    ;;

  baseline-library-stress)
    output_directory="$(new_run_directory baseline-library-stress)"
    run_baseline_library_stress "${output_directory}"
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

  attachment-format-stress)
    output_directory="$(new_run_directory attachment-format-stress)"
    run_attachment_format_stress "${output_directory}"
    ;;

  window-resize-stress)
    output_directory="$(new_run_directory window-resize-stress)"
    run_window_resize_stress "${output_directory}"
    ;;

  display-pane-stress)
    output_directory="$(new_run_directory display-pane-stress)"
    run_display_pane_stress "${output_directory}"
    ;;

  launch-ledger-stress)
    output_directory="$(new_run_directory launch-ledger-stress)"
    run_launch_ledger_stress "${output_directory}"
    ;;

  startup)
    output_directory="$(new_run_directory startup)"
    run_startup_profile "${output_directory}"
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
    run_chart_stress "${output_directory}"
    run_tools_settings_stress "${output_directory}"
    run_settings_search_stress "${output_directory}"
    run_extensions_preferences_stress "${output_directory}"
    run_archived_settings_stress "${output_directory}"
    run_conversation_stress "${output_directory}"
    run_subagent_stress "${output_directory}"
    run_sidebar_stress "${output_directory}"
    run_file_tree_stress "${output_directory}"
    run_attachment_stress "${output_directory}"
    run_attachment_format_stress "${output_directory}"
    run_window_resize_stress "${output_directory}"
    run_display_pane_stress "${output_directory}"
    run_launch_ledger_stress "${output_directory}"
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
      run_agent_work_stress "${output_directory}"
      run_changed_files_stress "${output_directory}"
      run_extension_ui_stress "${output_directory}"
      run_baseline_library_stress "${output_directory}"
      run_conversation_stress "${output_directory}" massive
      run_conversation_active_turn_stress "${output_directory}"
      run_conversation_residency_stress "${output_directory}"
      run_window_resize_stress "${output_directory}" history-heavy

      # A real checkout is deliberately opt-in: unlike the generated routine fixtures, its
      # contents and filesystem cache are not reproducible. When supplied, full+ keeps the
      # expensive real-world reader/parser/view sweep beside the specialist captures.
      if [[ -n "${THREADING_GIT_REPOSITORY_STRESS_PATH:-}" ]]; then
        run_git_repository_stress \
          "${output_directory}" \
          "${THREADING_GIT_REPOSITORY_STRESS_PATH}" \
          "${THREADING_GIT_REPOSITORY_STRESS_BASE:-HEAD~100}" \
          "${THREADING_GIT_REPOSITORY_STRESS_TARGET:-HEAD}" \
          "${THREADING_GIT_REPOSITORY_STRESS_RUNS:-3}"
      fi

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
