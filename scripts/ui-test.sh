#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
host_architecture="$(uname -m)"

cd "${repository_directory}"

python3 scripts/check_test_registration.py
scripts/check_theme_boundaries.sh
scripts/check_architecture_boundaries.sh
scripts/check_agent_scenarios.sh

xcodebuild \
  -project Threading.xcodeproj \
  -scheme ThreadingUI \
  -testPlan Threading-UI \
  -destination "platform=macOS,arch=${host_architecture}" \
  test \
  "$@"
