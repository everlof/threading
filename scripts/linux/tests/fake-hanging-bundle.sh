#!/usr/bin/env bash
# Diagnostic fixture: only a main-thread harness backtrace permits the watchdog to retry.
if [[ "${1:-}" == --list-tests ]]; then
  echo "Fake.Hang/testCase"
  exit 0
fi
if [[ "${FAKE_HANG:-}" == once && -e "${FAKE_STATE}" ]]; then
  echo "Test Case '$1' passed (0.001 seconds)"
  exit 0
fi
if [[ "${FAKE_HANG:-}" == slow ]]; then
  sleep 1.5
  echo "Test Case '$1' passed (1.5 seconds)"
  exit 0
fi
touch "${FAKE_STATE}"
report() {
  case "${FAKE_HANG:-}" in
    once|always)
      printf 'Thread 0 "Tests" crashed:\n  5 [ra] 0x123 awaitUsingExpectation(_:) + 10\n' ;;
    worker)
      printf 'Thread 0 "Tests" crashed:\n  1 [ra] 0x123 realTestBody()\n'
      printf 'Thread 1:\n  5 [ra] 0x123 awaitUsingExpectation(_:) + 10\n' ;;
    body)
      printf 'Thread 0 "Tests" crashed:\n  1 [ra] 0x123 realTestBody()\n' ;;
    empty) printf 'Thread 0 "Tests" crashed:\n' ;;
  esac
}
trap report ABRT
while true; do sleep 0.1; done
