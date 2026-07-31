#!/usr/bin/env bash
#
# Non-interactive performance entry point for Threading.
#
#   scripts/profile_threading.sh git-stress
#   scripts/profile_threading.sh sample [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh trace "Time Profiler" [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh full [seconds] [process-name-or-pid]
#   scripts/profile_threading.sh full+ [seconds] [process-name-or-pid]
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
  sed -n '3,11p' "$0"
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

run_git_stress() {
  local output_directory="$1"
  local jobs="${THREADING_PROFILE_BUILD_JOBS:-2}"
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

command="${1:-}"
case "${command}" in
  git-stress)
    output_directory="$(new_run_directory git-stress)"
    run_git_stress "${output_directory}"
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

  full|full+)
    seconds="${2:-15}"
    target="${3:-Threading}"
    output_directory="$(new_run_directory "${command}")"

    run_git_stress "${output_directory}"
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
