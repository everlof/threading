#!/usr/bin/env bash
# A stand-in for a Linux XCTest bundle, for test-xctest-watchdog.sh: it lists three cases and
# reports each named in FAKE_SKIPS as skipped, every other as passed, in XCTest's own words.
if [[ "${1:-}" == --list-tests ]]; then
  printf 'Fake.First/testA\nFake.First/testB\nFake.Second/testC\n'
  exit 0
fi
if [[ " ${FAKE_SKIPS:-} " == *" $1 "* ]]; then
  echo "Test Case '$1' skipped (0.001 seconds)"
  echo "Test skipped: fixture"
else
  echo "Test Case '$1' passed (0.001 seconds)"
fi
