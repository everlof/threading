#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
host_architecture="$(uname -m)"
scenario_module_cache="${repository_directory}/Packages/ThreadingScenarioKit/.build/ModuleCache"
xcodebuild_arguments=("$@")
result_bundle=""

for ((index = 0; index < ${#xcodebuild_arguments[@]}; index++)); do
  argument="${xcodebuild_arguments[$index]}"
  case "${argument}" in
    -resultBundlePath)
      next_index=$((index + 1))
      if ((next_index >= ${#xcodebuild_arguments[@]})); then
        printf 'error: -resultBundlePath requires a path\n' >&2
        exit 2
      fi
      result_bundle="${xcodebuild_arguments[$next_index]}"
      ;;
    -resultBundlePath=*)
      result_bundle="${argument#-resultBundlePath=}"
      ;;
  esac
done

if [[ -z "${result_bundle}" ]]; then
  run_identifier="$(date -u +'%Y%m%d-%H%M%S')-$$"
  run_directory="${repository_directory}/.build/ui-test-reports/${run_identifier}"
  mkdir -p "${run_directory}"
  result_bundle="${run_directory}/ThreadingUI.xcresult"
  xcodebuild_arguments+=("-resultBundlePath" "${result_bundle}")
else
  case "${result_bundle}" in
    /*) ;;
    *) result_bundle="${repository_directory}/${result_bundle}" ;;
  esac
  run_directory="${result_bundle%.xcresult}"
fi
report_directory="${run_directory}/report"

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

set +e
xcodebuild \
  -project Threading.xcodeproj \
  -scheme ThreadingUI \
  -testPlan Threading-UI \
  -destination "platform=macOS,arch=${host_architecture}" \
  THREADING_EMBED_UI_SCENARIO_HELPER=YES \
  test \
  "${xcodebuild_arguments[@]}"
test_status=$?
set -e

if [[ -d "${result_bundle}" ]]; then
  if report_path="$(python3 "${script_directory}/generate_ui_test_report.py" \
      --result "${result_bundle}" \
      --output "${report_directory}")"; then
    printf '\nUI journey report: %s\n' "${report_path}"
    printf 'Open it with: open %q\n' "${report_path}"
  else
    printf 'error: UI tests produced a result bundle but the journey report failed\n' >&2
    if [[ "${test_status}" -eq 0 ]]; then
      test_status=1
    fi
  fi
fi

exit "${test_status}"
