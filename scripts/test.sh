#!/usr/bin/env bash
#
# One entry point for the three test levels. See "Testing" in CLAUDE.md.
#
#   scripts/test.sh              # fast  — default; no window is ordered on screen
#   scripts/test.sh fast
#   scripts/test.sh all          # everything, including the on-screen WKWebView tests
#   scripts/test.sh e2e          # real APNs + optionally a real Claude; needs credentials
#
# Extra arguments are forwarded to xcodebuild, so this still works:
#   scripts/test.sh fast -only-testing:SkalmanTests/GitDiffParserTests
#
set -euo pipefail

level="${1:-fast}"
if [[ "${level}" == "fast" || "${level}" == "all" || "${level}" == "e2e" ]]; then
  shift || true
else
  level="fast"
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

if [[ "${level}" == "e2e" ]]; then
  exec "${script_directory}/run_notification_e2e.sh" "$@"
fi

case "${level}" in
  fast) test_plan="Skalman-Fast" ;;
  all)  test_plan="Skalman-All" ;;
esac

exec xcodebuild \
  -project "${repository_directory}/Skalman.xcodeproj" \
  -scheme Skalman \
  -testPlan "${test_plan}" \
  -destination "platform=macOS" \
  test \
  "$@"
