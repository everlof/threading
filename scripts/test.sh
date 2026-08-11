#!/usr/bin/env bash
#
# One entry point for the four test levels. See "Testing" in CLAUDE.md.
#
#   scripts/test.sh              # fast  — default; no window is ordered on screen
#   scripts/test.sh fast
#   scripts/test.sh all          # everything, including the on-screen WKWebView tests
#   scripts/test.sh ui           # app-level XCUITest scenarios in a disposable Cocoa home
#   scripts/test.sh e2e          # real APNs + optionally a real Claude; needs credentials
#
# Extra arguments are forwarded to xcodebuild, so this still works:
#   scripts/test.sh fast -only-testing:ThreadingTests/GitDiffParserTests
#
set -euo pipefail

level="${1:-fast}"
if [[ "${level}" == "fast" || "${level}" == "all" || "${level}" == "ui" || "${level}" == "e2e" ]]; then
  shift || true
else
  level="fast"
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

# An unregistered source produces a passing Xcode run with zero cases from that file. Refuse the
# command before selecting a plan so focused runs cannot accidentally provide false evidence.
python3 "${script_directory}/check_test_registration.py"

if [[ "${level}" == "e2e" ]]; then
  exec "${script_directory}/run_notification_e2e.sh" "$@"
fi

if [[ "${level}" == "ui" ]]; then
  exec "${script_directory}/ui-test.sh" "$@"
fi

case "${level}" in
  fast) test_plan="Threading-Fast" ;;
  all)  test_plan="Threading-All" ;;
esac

set +e
xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme Threading \
  -testPlan "${test_plan}" \
  -destination "platform=macOS" \
  test \
  "$@"
status=$?
set -e

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
trap 'rm -f "${scratch_list}"' EXIT

find -E "${HOME}/Library/Preferences" -maxdepth 1 -type f \
  -regex '.*[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.plist' \
  -size -43c \
  -print0 > "${scratch_list}" 2>/dev/null || true

swept=$(tr -dc '\0' < "${scratch_list}" | wc -c | tr -d ' ')
if [[ "${swept}" != "0" ]]; then
  xargs -0 rm -f < "${scratch_list}"
  echo "swept ${swept} empty scratch preference files"
fi

exit "${status}"
