#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
host_architecture="$(uname -m)"
scenario_module_cache="${repository_directory}/Packages/ThreadingScenarioKit/.build/ModuleCache"

cd "${repository_directory}"

mkdir -p "${scenario_module_cache}"
export CLANG_MODULE_CACHE_PATH="${scenario_module_cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${scenario_module_cache}"

python3 scripts/check_test_registration.py
scripts/check_theme_boundaries.sh
scripts/check_architecture_boundaries.sh
scripts/check_agent_scenarios.sh
swift build \
  --disable-sandbox \
  --package-path Packages/ThreadingScenarioKit \
  --product threading-scenario

xcodebuild \
  -project Threading.xcodeproj \
  -scheme ThreadingUI \
  -testPlan Threading-UI \
  -destination "platform=macOS,arch=${host_architecture}" \
  THREADING_EMBED_UI_SCENARIO_HELPER=YES \
  test \
  "$@"
