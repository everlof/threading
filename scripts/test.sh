#!/usr/bin/env bash
#
# One entry point for the four test levels. See "Testing" in CLAUDE.md.
#
#   scripts/test.sh              # fast  — default; no window is ordered on screen
#   scripts/test.sh fast
#   scripts/test.sh all          # every Mac and iPhone unit test, plus on-screen WKWebView tests
#   scripts/test.sh mac-all      # every Mac test only; the direct-distribution release lane
#   scripts/test.sh ui           # app-level XCUITest scenarios in a disposable Cocoa home
#   scripts/test.sh e2e          # real APNs + optionally a real Claude; needs credentials
#
# Extra arguments are forwarded to xcodebuild, so this still works:
#   scripts/test.sh fast -only-testing:ThreadingTests/GitDiffParserTests
#
set -euo pipefail

level="${1:-fast}"
if [[ "${level}" == "fast" || "${level}" == "all" || "${level}" == "mac-all" || "${level}" == "ui" || "${level}" == "e2e" ]]; then
  shift || true
else
  level="fast"
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

# Render tests are part of the ordinary plans, not only the evidence command. Xcode launches the
# test host with `/` as its working directory, so their documented relative-path fallback tries
# to write `/component.png` and turns a healthy suite into dozens of read-only-volume failures.
# Give an ordinary run a disposable output root; an explicit evidence destination still wins.
render_scratch=""
if [[ -z "${THREADING_RENDER_OUT:-}" ]]; then
  render_scratch="$(mktemp -d -t threading-test-renders)"
  export THREADING_RENDER_OUT="${render_scratch}"
fi
if [[ -z "${THREADING_UI_EVIDENCE_OUT:-}" ]]; then
  export THREADING_UI_EVIDENCE_OUT="${THREADING_RENDER_OUT}"
fi

scratch_list=""
process_ledger=""
test_root_pid=""
process_monitor_pid=""
process_guard_done=0
process_leak_detected=0

# Snapshot descendants of the XCTest app host while xcodebuild is alive. A child that outlives its
# test host is reparented to launchd and cannot be discovered from the tree afterwards, so
# observation has to happen during the run. Build workers such as ibtoold are xcodebuild children
# too but are deliberately outside this ownership tree. Cleanup still validates the run token in
# the live process environment; a recorded pid alone is never authority to signal a reused pid.
capture_test_descendants() {
  local root_pid="$1"
  ps -axo pid=,ppid=,pgid=,command= 2>/dev/null | awk -v root="${root_pid}" '
    {
      pid[NR] = $1
      parent[$1] = $2
      group[$1] = $3
      executable[$1] = $4
    }
    END {
      descendant[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (row = 1; row <= NR; row++) {
          current = pid[row]
          if (!descendant[current] && descendant[parent[current]]) {
            descendant[current] = 1
            changed = 1
          }
        }
      }
      for (row = 1; row <= NR; row++) {
        current = pid[row]
        name = executable[current]
        sub(/^.*\//, "", name)
        isTestHost = name == "Threading" || name == "ThreadingTests" || name == "xctest"
        if (descendant[current] && isTestHost) testOwned[current] = 1
      }
      changed = 1
      while (changed) {
        changed = 0
        for (row = 1; row <= NR; row++) {
          current = pid[row]
          if (!testOwned[current] && testOwned[parent[current]]) {
            testOwned[current] = 1
            changed = 1
          }
        }
      }
      for (row = 1; row <= NR; row++) {
        current = pid[row]
        if (testOwned[current]) print current, group[current]
      }
    }
  ' >> "${process_ledger}"
}

monitor_test_descendants() {
  local root_pid="$1"
  while kill -0 "${root_pid}" 2>/dev/null; do
    capture_test_descendants "${root_pid}"
    sleep 0.2
  done
  capture_test_descendants "${root_pid}"
}

stop_process_guard() {
  # `cleanup` invokes this a second time from the EXIT trap. Return success explicitly: a bare
  # `return` would preserve the failed guard expression and turn a passing xcodebuild into exit 1.
  [[ "${process_guard_done}" == "0" ]] || return 0
  process_guard_done=1

  if [[ -n "${process_monitor_pid}" ]]; then
    kill "${process_monitor_pid}" 2>/dev/null || true
    wait "${process_monitor_pid}" 2>/dev/null || true
    process_monitor_pid=""
  fi
  if [[ -n "${test_root_pid}" && -n "${process_ledger}" ]]; then
    capture_test_descendants "${test_root_pid}"
  fi
  [[ -n "${process_ledger}" && -f "${process_ledger}" ]] || return

  local live_list
  live_list="$(mktemp -t threading-live-test-processes)"
  local leaked=0
  local attempt
  # XCTest can report completion a fraction before its app host exits. Give ordinary teardown a
  # short, early-exit grace period; a detached PTY shell does not disappear during this window.
  for attempt in {1..20}; do
    : > "${live_list}"
    awk '!seen[$1]++ { print $1, $2 }' "${process_ledger}" | while read -r pid pgid; do
      kill -0 "${pid}" 2>/dev/null || continue
      # `eww` includes the environment. The exact random token is the ownership proof which keeps
      # a concurrent test run, a production daemon, and a reused pid out of this cleanup.
      command_with_environment="$(ps eww -p "${pid}" -o command= 2>/dev/null || true)"
      [[ "${command_with_environment}" == *"THREADING_TEST_RUN_TOKEN=${THREADING_TEST_RUN_TOKEN}"* ]] \
        || continue
      printf '%s %s\n' "${pid}" "${pgid}" >> "${live_list}"
    done
    leaked="$(wc -l < "${live_list}" | tr -d ' ')"
    [[ "${leaked}" == "0" || "${attempt}" == "20" ]] && break
    sleep 0.1
  done

  if [[ "${leaked}" != "0" ]]; then
    process_leak_detected=1
    echo "test process guard found ${leaked} run-owned processes after xcodebuild; reaping them" >&2
    while read -r pid pgid; do
      command_without_environment="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
      echo "  pid=${pid} pgid=${pgid} command=${command_without_environment}" >&2
    done < "${live_list}"
    # `forkpty` makes the child its process-group leader. End those exact token-validated groups
    # first so a shell and the `stty`/`sleep` child it happens to be waiting for leave together.
    while read -r pid pgid; do
      [[ "${pid}" == "${pgid}" ]] || continue
      kill -TERM -- "-${pgid}" 2>/dev/null || true
    done < "${live_list}"
    while read -r pid _; do
      kill -TERM "${pid}" 2>/dev/null || true
    done < "${live_list}"
    sleep 0.5
    while read -r pid pgid; do
      kill -0 "${pid}" 2>/dev/null || continue
      if [[ "${pid}" == "${pgid}" ]]; then
        kill -KILL -- "-${pgid}" 2>/dev/null || true
      else
        kill -KILL "${pid}" 2>/dev/null || true
      fi
    done < "${live_list}"
  fi
  rm -f "${live_list}"
}

cleanup() {
  stop_process_guard
  if [[ -n "${scratch_list}" ]]; then
    rm -f "${scratch_list}"
  fi
  if [[ -n "${process_ledger}" ]]; then
    rm -f "${process_ledger}"
  fi
  if [[ -n "${render_scratch}" && -d "${render_scratch}" ]]; then
    find "${render_scratch}" -depth -delete
  fi
}
trap cleanup EXIT

if [[ "${level}" == "e2e" ]]; then
  exec "${script_directory}/run_notification_e2e.sh" "$@"
fi

if [[ "${level}" == "ui" ]]; then
  exec "${script_directory}/ui-test.sh" "$@"
fi

case "${level}" in
  fast) test_plan="Threading-Fast" ;;
  all|mac-all) test_plan="Threading-All" ;;
esac

export THREADING_TEST_RUN_TOKEN="$(uuidgen)"
process_ledger="$(mktemp -t threading-test-processes)"

set +e
xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme Threading \
  -testPlan "${test_plan}" \
  -destination "platform=macOS" \
  test \
  "$@" &
test_root_pid=$!
test_root_pgid="$(ps -p "${test_root_pid}" -o pgid= | tr -d ' ')"
printf '%s %s\n' "${test_root_pid}" "${test_root_pgid}" >> "${process_ledger}"
monitor_test_descendants "${test_root_pid}" &
process_monitor_pid=$!
wait "${test_root_pid}"
status=$?
set -e
stop_process_guard
if [[ "${process_leak_detected}" != "0" ]]; then
  status=1
fi

if [[ "${level}" == "all" && "${status}" == "0" ]]; then
  echo "test: Mac target passed; running the complete ThreadingMobileTests target…" >&2
  set +e
  "${script_directory}/test-mobile.sh"
  mobile_status=$?
  set -e
  if [[ "${mobile_status}" != "0" ]]; then
    status="${mobile_status}"
  fi
fi

# Sweep the empty preference files the scratch suites leave behind.
#
# Test classes here name a `UserDefaults` suite after a fresh UUID and remove its domain when
# they finish. That empties the domain but never unlinks the file — cfprefsd writes an empty
# plist back out as the test host exits — so `~/Library/Preferences` gained one more 42-byte
# `{}` per suite per run, permanently. It reached 8,703 of them inside a directory of 12,468
# entries, which every `defaults` read and every cfprefsd start has to walk.
#
# It cannot be swept from inside a test: the file is written *after* the process that would
# delete it is gone, so a `tearDown` that unlinks it watches it reappear. That was tried first —
# the unlink ran, its own test proved the file gone, and the plists were back on disk by the end
# of the run.
#
# Nor is the sweep scoped to this run. cfprefsd flushes on its own schedule and keeps trickling
# files out for a minute or so after xcodebuild returns, so a `-newer` marker reliably misses the
# tail — measured at 98 files deleted and 13 rewritten afterwards. Sweeping unconditionally means
# run N+1 collects whatever arrived late from run N; the steady state is a handful, not thousands.
#
# What keeps that safe is the *empty* condition, not the run window: a 42-byte plist is `{}` and
# holds no preference at all, so the delete cannot lose one. The UUID pattern is the scratch-suite
# signature and keeps the sweep away from real domains, which are never named that way.
# Collected first and deleted second, rather than `find -print -delete`: that form deletes
# without emitting the paths, so the count read zero on runs that had just swept a hundred files
# and the line never printed. A sweep that cannot say what it removed is one nobody can audit.
scratch_list="$(mktemp -t threading-scratch-prefs)"

find -E "${HOME}/Library/Preferences" -maxdepth 1 -type f \
  -regex '.*[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist' \
  -size -43c \
  -print0 > "${scratch_list}" 2>/dev/null || true

swept=$(tr -dc '\0' < "${scratch_list}" | wc -c | tr -d ' ')
if [[ "${swept}" != "0" ]]; then
  xargs -0 rm -f < "${scratch_list}"
  echo "swept ${swept} empty scratch preference files"
fi

# And the hosted-test suite this run wrote its recorded choices into.
#
# `PreferenceStore` names that suite after the test host's pid, because one shared name let two
# concurrent runs on the same machine read each other's answers — see the note there. The cost is
# one plist per run, so they are collected here rather than left to accumulate the way the UUID
# domains above once did.
#
# Deleted by liveness rather than by this run's own pid: cfprefsd flushes after the process it
# belongs to is gone, so a run that removed only its own file would race its own write. A domain
# whose pid no longer names a process cannot be in use, and whatever this run leaves behind the
# next one collects. The unsuffixed legacy name is always stale — nothing writes it any more.
hosted_prefix="codes.threading.hosted-tests"
hosted_swept=0
while IFS= read -r plist; do
  suffix="$(basename "${plist}" .plist)"
  suffix="${suffix#"${hosted_prefix}"}"
  suffix="${suffix#.}"
  if [[ -n "${suffix}" ]]; then
    [[ "${suffix}" =~ ^[0-9]+$ ]] || continue
    kill -0 "${suffix}" 2>/dev/null && continue
  fi
  rm -f "${plist}" && hosted_swept=$((hosted_swept + 1))
done < <(find "${HOME}/Library/Preferences" -maxdepth 1 -type f -name "${hosted_prefix}*.plist" 2>/dev/null)

if [[ "${hosted_swept}" != "0" ]]; then
  echo "swept ${hosted_swept} finished hosted-test preference domains"
fi

exit "${status}"
