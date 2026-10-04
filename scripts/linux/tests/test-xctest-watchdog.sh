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
trap 'rm -f "${expected}" "${output}"' EXIT
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

(( failures == 0 )) || { echo "test-xctest-watchdog: ${failures} failed" >&2; exit 1; }
echo "test-xctest-watchdog: passed"
