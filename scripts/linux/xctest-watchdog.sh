#!/usr/bin/env bash
#
# Runs every case of a Linux XCTest bundle in its own process, and survives one specific upstream
# deadlock without hiding any other hang.
#
#   xctest-watchdog.sh <path/to/Package.xctest> [<Module.Class> ...]
#
# Runs inside the Linux container `scripts/test-ptyd-linux.sh` starts. Linux-only, bash-only: the
# Swift image has no Python.
#
# Why this exists: swift-corelibs-xctest wraps every test's `setUp()`/`tearDown()` in
# `awaitUsingExpectation`, which waits on `XCTWaiter` through the run loop, and on Linux that wait
# intermittently never returns — the main thread sits in `RunLoop.run(mode:before:)` while no thread
# runs any test code. Upstream: https://github.com/swiftlang/swift-corelibs-xctest/issues/504
# (open, rdar://139710145), reproduced there under Docker for Mac on both architectures. Measured
# here with Swift 6.3.2 on linux/arm64: one hang in 24 runs of a single empty-bodied test, so a
# 77-case bundle run as one process almost never finishes.
#
# The rule: a case still running after `probe_seconds` is backtraced once. If the main thread is
# inside `awaitUsingExpectation`, it is that deadlock — the empty async setUp/tearDown wrapper, not a
# test body; nothing in these suites overrides the async variants — so the case is killed and run
# again, at most `attempts` times, and every retry is printed and counted. Any other case still
# running at `limit_seconds` fails with its backtrace, and so does a case that deadlocks every
# attempt. Every wait in these suites is individually bounded well below `limit_seconds`, so a real
# hang cannot pass as the harness one. Five attempts rather than three because two consecutive
# deadlocks of one case were observed in a single run; the frame check, not the count, is what
# keeps a real hang out. Remove this runner when the upstream issue is fixed in the toolchain
# `scripts/test-ptyd-linux.sh` pins.
set -uo pipefail

readonly probe_seconds=10
readonly limit_seconds=180
readonly attempts=5
readonly deadlock_frame="awaitUsingExpectation"

bundle="$1"
shift
classes=("$@")

mapfile -t cases < <("${bundle}" --list-tests 2>/dev/null | grep -E '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/test')
if (( ${#classes[@]} > 0 )); then
  selected=()
  for case_name in "${cases[@]}"; do
    for class in "${classes[@]}"; do
      [[ "${case_name}" == "${class}/"* ]] && selected+=("${case_name}")
    done
  done
  cases=("${selected[@]}")
fi
if (( ${#cases[@]} == 0 )); then
  echo "xctest-watchdog: no test cases found in ${bundle}" >&2
  exit 1
fi

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
passed=0
skipped=()
failed=()
retries=0

backtrace() {
  lldb --batch -p "$1" -o "thread backtrace all" 2>&1 | grep -E 'thread #|frame #'
}

for case_name in "${cases[@]}"; do
  attempt=1
  while true; do
    # Its own session, so a failure can end the daemon and every child a test started with it.
    setsid "${bundle}" "${case_name}" >"${log}" 2>&1 &
    pid=$!
    started=${SECONDS}
    probed=0
    outcome=""

    while kill -0 "${pid}" 2>/dev/null; do
      elapsed=$(( SECONDS - started ))
      if (( !probed && elapsed >= probe_seconds )); then
        probed=1
        trace="$(backtrace "${pid}")"
        if grep -q "${deadlock_frame}" <<<"${trace}"; then
          outcome="deadlock"
          break
        fi
      fi
      if (( elapsed >= limit_seconds )); then
        outcome="timeout"
        trace="$(backtrace "${pid}")"
        break
      fi
      sleep 0.2
    done

    if [[ -n "${outcome}" ]]; then
      kill -9 -- "-${pid}" 2>/dev/null
      wait "${pid}" 2>/dev/null
    else
      wait "${pid}"
      status=$?
      # A skip is reported as its own outcome, never as a pass: the daemon suite skips when it
      # cannot find the binary, and "passed" would then describe a suite that ran nothing.
      if (( status == 0 )) && grep -q "' skipped (" "${log}"; then
        outcome="skipped"
      elif (( status == 0 )) && grep -q "' passed (" "${log}"; then
        outcome="passed"
      else
        outcome="failed"
      fi
    fi

    case "${outcome}" in
      passed)
        passed=$(( passed + 1 ))
        break
        ;;
      skipped)
        skipped+=("${case_name}: $(grep -m1 -o 'Test skipped.*' "${log}")")
        break
        ;;
      deadlock)
        if (( attempt < attempts )); then
          retries=$(( retries + 1 ))
          echo "xctest-watchdog: ${case_name}: XCTest harness deadlock (swift-corelibs-xctest#504), attempt ${attempt} of ${attempts}; running it again"
          attempt=$(( attempt + 1 ))
          continue
        fi
        echo "xctest-watchdog: ${case_name}: deadlocked in the XCTest harness on all ${attempts} attempts" >&2
        failed+=("${case_name}")
        break
        ;;
      timeout)
        echo "xctest-watchdog: ${case_name}: still running after ${limit_seconds}s" >&2
        echo "${trace}" >&2
        cat "${log}" >&2
        failed+=("${case_name}")
        break
        ;;
      failed)
        cat "${log}" >&2
        failed+=("${case_name}")
        break
        ;;
    esac
  done
done

echo "xctest-watchdog: $(basename "${bundle}"): ${passed} passed, ${#skipped[@]} skipped, ${#failed[@]} failed, ${retries} harness-deadlock retries"
if (( ${#skipped[@]} > 0 )); then
  printf '  skipped: %s\n' "${skipped[@]}"
fi
if (( ${#failed[@]} > 0 )); then
  printf '  failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
