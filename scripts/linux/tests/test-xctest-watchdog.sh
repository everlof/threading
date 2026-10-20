#!/usr/bin/env bash
#
# The expected-skip contract of xctest-watchdog.sh, against a fake bundle. Linux-only (the watchdog
# uses setsid); scripts/test-ptyd-linux.sh runs it in its container before the real suites.
set -uo pipefail

directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
watchdog="${directory}/../xctest-watchdog.sh"
bundle="${directory}/fake-bundle.sh"
expected="$(mktemp)"
output="$(mktemp)"
scratch="$(mktemp -d)"
trap 'rm -f "${expected}" "${output}"; rm -rf "${scratch}"' EXIT
printf '# comment\nFake.First/testB  # the one case expected to skip\n\n' > "${expected}"

failures=0
check() {
  local want="$1" skips="$2"
  shift 2
  FAKE_SKIPS="${skips}" "${watchdog}" "$@" >"${output}" 2>&1
  local got=$?
  if { [[ "${want}" == pass ]] && (( got == 0 )); } || { [[ "${want}" == fail ]] && (( got != 0 )); }; then
    echo "ok: ${want} with skips '${skips}' and $*"
  else
    echo "FAILED: expected ${want}, exit ${got}, with skips '${skips}' and $*" >&2
    cat "${output}" >&2
    failures=$(( failures + 1 ))
  fi
}

check pass "Fake.First/testB" --expected-skips "${expected}" "${bundle}"
check fail "Fake.First/testB Fake.Second/testC" --expected-skips "${expected}" "${bundle}"
check fail "" --expected-skips "${expected}" "${bundle}"
# A listed case outside the selected classes is not required to run.
check pass "" --expected-skips "${expected}" "${bundle}" Fake.Second
check fail "Fake.Second/testC" --expected-skips /dev/null "${bundle}"
check pass "" --expected-skips /dev/null "${bundle}"
# Without the option a skip is reported, not failed (the controller lane's behaviour).
check pass "Fake.Second/testC" "${bundle}"

# Exercise the real watchdog with a shortened clock and an uninspectable LLDB response.
# Production's ten/180-second bounds are unchanged.
sed -e 's/readonly probe_seconds=10/readonly probe_seconds=0/' \
    -e 's/readonly limit_seconds=180/readonly limit_seconds=1/' \
    -e 's/readonly crash_trace_seconds=5/readonly crash_trace_seconds=1/' \
    -e 's/readonly attempts=5/readonly attempts=2/' \
    "${watchdog}" > "${scratch}/watchdog"
chmod +x "${scratch}/watchdog"
printf '#!/bin/sh\nprintf "thread #1\\n  frame #0: \\n"\n' > "${scratch}/lldb"
chmod +x "${scratch}/lldb"

check_hang() {
  local mode="$1" want="$2" retries="$3"
  rm -f "${scratch}/state"
  PATH="${scratch}:${PATH}" FAKE_HANG="${mode}" FAKE_STATE="${scratch}/state" \
    "${scratch}/watchdog" --expected-skips /dev/null \
      "${directory}/fake-hanging-bundle.sh" > "${output}" 2>&1
  local got=$?
  if { { [[ "${want}" == pass ]] && (( got == 0 )); } \
       || { [[ "${want}" == fail ]] && (( got != 0 )); }; } \
      && grep -q "${retries} harness-deadlock retries" "${output}"; then
    echo "ok: ${mode} backtrace ${want}, ${retries} retries"
  else
    echo "FAILED: ${mode} backtrace expected ${want}, ${retries} retries; exit ${got}" >&2
    cat "${output}" >&2
    failures=$(( failures + 1 ))
  fi
}
check_hang once pass 1
check_hang always fail 1
check_hang worker fail 0
check_hang body fail 0
check_hang empty fail 0
# A slow valid case must retain the interval between the diagnostic probe and the timeout.
sed 's/readonly limit_seconds=1/readonly limit_seconds=4/' \
  "${scratch}/watchdog" > "${scratch}/slow-watchdog"
mv "${scratch}/slow-watchdog" "${scratch}/watchdog"
chmod +x "${scratch}/watchdog"
check_hang slow pass 0

(( failures == 0 )) || { echo "test-xctest-watchdog: ${failures} failed" >&2; exit 1; }
echo "test-xctest-watchdog: passed"
