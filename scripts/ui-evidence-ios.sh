#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
manifest="${repository_directory}/Tests/UIEvidence/ios-coverage.json"
baseline_directory="${repository_directory}/Tests/UIEvidence/iOSBaselines"
derived_data_directory="${repository_directory}/.build/ui-evidence-ios-derived-data"
bundle_identifier="codes.threading.mobile"
requested_output=""
requested_simulator="booted"
accept_new_baselines=0

usage() {
  cat <<'EOF'
Usage: scripts/ui-evidence-ios.sh [options]

Capture the shipping iOS DEBUG fixtures on a real simulator and build a static HTML report.

Options:
  --output PATH                 Use a new run directory instead of .build/ui-evidence-ios-reports/…
  --simulator UDID              Use this booted/bootable iOS simulator (default: booted)
  --accept-new-baselines        Copy only captures that do not have an approved baseline yet
  -h, --help                    Show this help
EOF
}

while (($#)); do
  case "$1" in
    --output)
      if (($# < 2)); then
        printf 'error: --output requires a path\n' >&2
        exit 2
      fi
      requested_output="$2"
      shift 2
      ;;
    --simulator)
      if (($# < 2)); then
        printf 'error: --simulator requires a UDID\n' >&2
        exit 2
      fi
      requested_simulator="$2"
      shift 2
      ;;
    --accept-new-baselines)
      accept_new_baselines=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command in jq python3 xcodebuild xcrun; do
  command -v "${command}" >/dev/null || {
    printf 'error: required command is unavailable: %s\n' "${command}" >&2
    exit 1
  }
done

if [[ -n "${requested_output}" ]]; then
  case "${requested_output}" in
    /*) run_directory="${requested_output}" ;;
    *) run_directory="${repository_directory}/${requested_output}" ;;
  esac
else
  run_identifier="$(date -u +'%Y%m%d-%H%M%S')-$$"
  reports_root="${repository_directory}/.build/ui-evidence-ios-reports"
  mkdir -p "${reports_root}"
  run_directory="${reports_root}/${run_identifier}"
fi

if [[ -e "${run_directory}" ]]; then
  printf 'error: iOS UI evidence output already exists: %s\n' "${run_directory}" >&2
  exit 2
fi

current_directory="${run_directory}/current"
report_directory="${run_directory}/report"
log_directory="${run_directory}/logs"
mkdir -p "${current_directory}/ios" "${log_directory}"

resolve_simulator() {
  local selector="$1"
  if [[ "${selector}" != "booted" ]]; then
    xcrun simctl bootstatus "${selector}" -b >/dev/null
    printf '%s\n' "${selector}"
    return
  fi

  local devices_json simulator
  devices_json="$(xcrun simctl list devices available -j)"
  simulator="$(
    jq -r '
      [.devices[][] | select(.state == "Booted") | select(.name == "iPhone 17 Pro")][0].udid
      // [.devices[][] | select(.state == "Booted") | select(.name | startswith("iPhone"))][0].udid
      // empty
    ' <<<"${devices_json}"
  )"
  if [[ -z "${simulator}" ]]; then
    printf 'error: no booted iPhone simulator; boot iPhone 17 Pro or pass --simulator UDID\n' >&2
    return 1
  fi
  printf '%s\n' "${simulator}"
}

simulator_udid="$(resolve_simulator "${requested_simulator}")"
device_name="$(
  xcrun simctl list devices available -j \
    | jq -r --arg udid "${simulator_udid}" \
      '[.devices[][] | select(.udid == $udid)][0].name // empty'
)"
if [[ -z "${device_name}" || "${device_name}" != iPhone* ]]; then
  printf 'error: simulator %s is not an available iPhone\n' "${simulator_udid}" >&2
  exit 1
fi

printf 'Building ThreadingMobile for %s (%s)…\n' "${device_name}" "${simulator_udid}"
xcodebuild \
  -project "${repository_directory}/Threading.xcodeproj" \
  -scheme ThreadingMobile \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath "${derived_data_directory}" \
  -jobs "${THREADING_UI_EVIDENCE_BUILD_JOBS:-2}" \
  -quiet \
  build 2>&1 | tee "${log_directory}/build.log"

app="${derived_data_directory}/Build/Products/Debug-iphonesimulator/ThreadingMobile.app"
if [[ ! -d "${app}" ]]; then
  printf 'error: built iOS app is missing: %s\n' "${app}" >&2
  exit 1
fi

xcrun simctl install "${simulator_udid}" "${app}"
data_container="$(xcrun simctl get_app_container "${simulator_udid}" "${bundle_identifier}" data)"
if [[ ! -d "${data_container}" ]]; then
  printf 'error: could not resolve the installed app data container\n' >&2
  exit 1
fi

# Keep simulator furniture deterministic even though the app-owned capture normally excludes it.
xcrun simctl status_bar "${simulator_udid}" override \
  --time '9:41' --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 >/dev/null
trap 'xcrun simctl status_bar "${simulator_udid}" clear >/dev/null 2>&1 || true' EXIT HUP INT TERM

run_token="ios-$(basename "${run_directory}" | tr -cd '[:alnum:]-' | cut -c1-80)"

capture_fixture() {
  local fixture="$1"
  local identifier entry_id demo appearance theme
  identifier="$(jq -r '.id' <<<"${fixture}")"
  entry_id="$(jq -r '.entryID' <<<"${fixture}")"
  demo="$(jq -r '.demo' <<<"${fixture}")"
  appearance="$(jq -r '.appearance' <<<"${fixture}")"
  theme="$(jq -r '.theme' <<<"${fixture}")"

  if [[ ! "${identifier}" =~ ^[a-z][a-z0-9-]{0,95}$ ]]; then
    printf 'error: invalid iOS evidence capture id: %s\n' "${identifier}" >&2
    return 1
  fi
  if ! jq -e --arg entry "${entry_id}" \
      '.entries[] | select(.id == $entry and .status == "implemented")' \
      "${manifest}" >/dev/null; then
    printf 'error: capture %s references a missing implemented entry: %s\n' \
      "${identifier}" "${entry_id}" >&2
    return 1
  fi
  if [[ "${appearance}" != "light" && "${appearance}" != "dark" ]]; then
    printf 'error: capture %s has unsupported appearance: %s\n' \
      "${identifier}" "${appearance}" >&2
    return 1
  fi
  if [[ "${theme}" != "custom" && "${theme}" != "custom-light" \
      && "${theme}" != "fallback" ]]; then
    printf 'error: capture %s has unsupported theme: %s\n' "${identifier}" "${theme}" >&2
    return 1
  fi

  printf 'Capturing %-42s  %s · %s · %s\n' \
    "${identifier}" "${demo}" "${appearance}" "${theme}"
  xcrun simctl ui "${simulator_udid}" appearance "${appearance}"

  local stdout_path="${log_directory}/${identifier}.stdout.log"
  local stderr_path="${log_directory}/${identifier}.stderr.log"
  local marker="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.json"
  local source_image="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.png"
  local launch_environment=(
    "SIMCTL_CHILD_THREADING_MOBILE_DEMO=${demo}"
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_RUN=${run_token}"
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_ID=${identifier}"
  )
  if [[ "${theme}" == "fallback" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=fallback")
  elif [[ "${theme}" == "custom-light" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=light")
  fi

  env "${launch_environment[@]}" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="${stdout_path}" \
      --stderr="${stderr_path}" \
      "${simulator_udid}" \
      "${bundle_identifier}" >/dev/null

  local poll
  # The app publishes an explicit terminal marker after at most 75 rendered samples. A complex
  # SwiftUI hierarchy can spend material time drawing each sample in addition to the 200 ms poll
  # cadence, so the host timeout is deliberately wider than the in-app sampling budget.
  for ((poll = 0; poll < 400; poll += 1)); do
    [[ -f "${marker}" ]] && break
    sleep 0.1
  done
  if [[ ! -f "${marker}" ]]; then
    printf 'error: fixture %s produced no stable evidence marker\n' "${identifier}" >&2
    return 1
  fi
  if ! jq -e \
      --arg id "${identifier}" \
      '.schemaVersion == 1
        and .kind == "threading-mobile-ui-evidence"
        and .identifier == $id
        and .stabilized == true
        and .pixelWidth > 0
        and .pixelHeight > 0' \
      "${marker}" >/dev/null; then
    printf 'error: fixture %s never reached a pixel-stable state\n' "${identifier}" >&2
    jq . "${marker}" >&2 || true
    return 1
  fi
  if [[ ! -f "${source_image}" ]]; then
    printf 'error: fixture %s marker names a missing PNG\n' "${identifier}" >&2
    return 1
  fi

  cp "${source_image}" "${current_directory}/ios/${identifier}.png"
  cp "${marker}" "${log_directory}/${identifier}.json"
}

capture_count="$(jq '.captures | length' "${manifest}")"
if [[ "${capture_count}" -le 0 ]]; then
  printf 'error: iOS evidence manifest has no captures\n' >&2
  exit 1
fi

while IFS= read -r fixture; do
  capture_fixture "${fixture}"
done < <(jq -c '.captures[]' "${manifest}")

captured_count="$(find "${current_directory}/ios" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
if [[ "${captured_count}" -ne "${capture_count}" ]]; then
  printf 'error: captured %s of %s declared iOS evidence images\n' \
    "${captured_count}" "${capture_count}" >&2
  exit 1
fi

generator_arguments=(
  --manifest "${manifest}"
  --current "${current_directory}"
  --baseline "${baseline_directory}"
  --output "${report_directory}"
)
if ((accept_new_baselines)); then
  generator_arguments+=(--accept-new-baselines)
fi

report_path="$(python3 "${script_directory}/generate_ui_evidence_report.py" \
  "${generator_arguments[@]}")"
printf '\niOS UI evidence report: %s\n' "${report_path}"
printf 'Open it with: open %q\n' "${report_path}"
