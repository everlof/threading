#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
source "${repository_directory}/scripts/coresimulator_lane_lock.sh"
manifest="${repository_directory}/Tests/UIEvidence/ios-coverage.json"
baseline_directory="${repository_directory}/Tests/UIEvidence/iOSBaselines"
derived_data_directory="${repository_directory}/.build/ui-evidence-ios-derived-data"
bundle_identifier="codes.threading.mobile"
requested_output=""
requested_simulator="booted"
requested_template=""
requested_app=""
accept_new_baselines=0
require_accepted=0
requested_only=""
requested_theme=""
requested_marketing_video=""
temporary_simulator_udid=""
simulator_udid=""
simulator_preferences_backup=""
template_simulator_to_reboot=""
idb_connected=0

cleanup() {
  local exit_status=$?
  if [[ -n "${simulator_udid}" ]]; then
    xcrun simctl status_bar "${simulator_udid}" clear >/dev/null 2>&1 || true
  fi
  if ((idb_connected)) && [[ -n "${simulator_udid}" ]]; then
    idb disconnect "${simulator_udid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${temporary_simulator_udid}" ]]; then
    # `idb disconnect` removes its client registration but can leave the per-device companion
    # reparented to launchd. This runner owns both that helper and the temporary simulator; stop
    # the helper before deleting the device so repeated evidence runs do not accumulate orphaned
    # companions for UDIDs that no longer exist.
    local companion_pid companion_tick
    while read -r companion_pid; do
      [[ -n "${companion_pid}" ]] || continue
      kill -TERM "${companion_pid}" >/dev/null 2>&1 || true
      for ((companion_tick = 0; companion_tick < 20; companion_tick += 1)); do
        kill -0 "${companion_pid}" >/dev/null 2>&1 || break
        sleep 0.1
      done
      kill -KILL "${companion_pid}" >/dev/null 2>&1 || true
    done < <(
      ps -axo pid=,command= | awk -v udid="${temporary_simulator_udid}" '
        index($0, "idb_companion --udid " udid " ") { print $1 }
      '
    )
    xcrun simctl shutdown "${temporary_simulator_udid}" >/dev/null 2>&1 || true
    xcrun simctl delete "${temporary_simulator_udid}" >/dev/null 2>&1 || true
    temporary_simulator_udid=""
  fi
  if [[ -n "${simulator_preferences_backup}" \
      && -f "${simulator_preferences_backup}" ]]; then
    defaults import com.apple.iphonesimulator \
      "${simulator_preferences_backup}" >/dev/null 2>&1 || true
    simulator_preferences_backup=""
  fi
  if [[ -n "${template_simulator_to_reboot}" ]]; then
    xcrun simctl boot "${template_simulator_to_reboot}" >/dev/null 2>&1 || true
    template_simulator_to_reboot=""
  fi
  exit "${exit_status}"
}

trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
Usage: scripts/ui-evidence-ios.sh [options]

Capture the shipping iOS DEBUG fixtures on a real simulator and build a static HTML report.

Options:
  --output PATH                 Use a new run directory instead of .build/ui-evidence-ios-reports/…
  --simulator UDID              Reuse this booted/bootable iOS simulator instead of an isolated one
  --template UDID               Clone this shut-down iPhone as the isolated device instead of the booted one
  --app PATH                    Capture an already-built ThreadingMobile.app instead of rebuilding
  --only ID[,ID…]               Capture these image ids or coverage entries (ios- is optional)
  --theme ID                    Override every selected capture with one manifest theme
  --record-marketing-video PATH Record the declared real-use marketing walkthrough to PATH
  --accept-new-baselines        Copy only captures that do not have an approved baseline yet
  --require-accepted            Fail unless every captured image exactly matches a baseline
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
    --template)
      if (($# < 2)); then
        printf 'error: --template requires a UDID\n' >&2
        exit 2
      fi
      requested_template="$2"
      shift 2
      ;;
    --app)
      if (($# < 2)); then
        printf 'error: --app requires a ThreadingMobile.app path\n' >&2
        exit 2
      fi
      requested_app="$2"
      shift 2
      ;;
    --only)
      if (($# < 2)); then
        printf 'error: --only requires one or more comma-separated image ids or coverage entries\n' >&2
        exit 2
      fi
      requested_only="$2"
      shift 2
      ;;
    --theme)
      if (($# < 2)); then
        printf 'error: --theme requires a manifest theme id\n' >&2
        exit 2
      fi
      requested_theme="$2"
      shift 2
      ;;
    --record-marketing-video)
      if (($# < 2)); then
        printf 'error: --record-marketing-video requires a path\n' >&2
        exit 2
      fi
      requested_marketing_video="$2"
      shift 2
      ;;
    --accept-new-baselines)
      accept_new_baselines=1
      shift
      ;;
    --require-accepted)
      require_accepted=1
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

if [[ -n "${requested_template}" && "${requested_simulator}" != "booted" ]]; then
  printf 'error: --template clones a device and --simulator reuses one; pass only one of them\n' >&2
  exit 2
fi

for command in jq lockf python3 xcodebuild xcrun; do
  command -v "${command}" >/dev/null || {
    printf 'error: required command is unavailable: %s\n' "${command}" >&2
    exit 1
  }
done

if [[ -n "${requested_marketing_video}" ]]; then
  for command in ffmpeg ffprobe idb; do
    command -v "${command}" >/dev/null || {
      printf 'error: marketing video requires unavailable command: %s\n' "${command}" >&2
      exit 1
    }
  done
  case "${requested_marketing_video}" in
    /*) ;;
    *) requested_marketing_video="${repository_directory}/${requested_marketing_video}" ;;
  esac
  if [[ -e "${requested_marketing_video}" ]]; then
    printf 'error: marketing video output already exists: %s\n' \
      "${requested_marketing_video}" >&2
    exit 2
  fi
fi

if [[ -n "${requested_theme}" ]] \
    && ! jq -e --arg theme "${requested_theme}" '.themeIDs | index($theme) != null' \
      "${manifest}" >/dev/null; then
  printf 'error: unsupported iOS evidence theme override: %s\n' "${requested_theme}" >&2
  exit 2
fi

threading_acquire_coresimulator_lane "iOS UI evidence capture" || exit $?

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

# idb's flattened tree can list a UIKit bar as one childless group. `describe-all` on the session
# dashboard reports its navigation bar as a "Nav bar" group carrying the title as its identifier
# and nothing beneath it, while `describe-point` at the same bar still answers "Choose Mac", the
# title button and "Remote access options" (the session screen's bar enumerates normally, so this
# is idb's traversal, not the app). Hit-testing along such a bar's centreline finds what
# enumeration dropped: the pitch sits below any 44-point tap target, and only labelless groups no
# taller than two tap targets are walked, so the cost is bounded by bar count × bar width.
hit_test_pitch=12
hit_test_bar_height=88
hit_test_point_matches() {
  local x="$1" y="$2" label="$3"
  local point_json
  point_json="$(
    idb ui describe-point --json --udid "${simulator_udid}" "${x}" "${y}" 2>/dev/null || true
  )"
  jq -er --arg label "${label}" '
    select((.AXLabel // "") | startswith($label)) | .frame
    | select(.width > 0 and .height > 0)
    | "\(.x + (.width / 2)) \(.y + (.height / 2))"
  ' <<<"${point_json}" 2>/dev/null
}

hit_test_flattened_bars() {
  local accessibility_json="$1" label="$2"
  local left centre_y right step trailing leading found
  while IFS=$'\t' read -r left centre_y right; do
    [[ -n "${left}" ]] || continue
    # Ends first, then inward: a bar keeps its items at its edges and its title in the middle,
    # and each probe is one round trip to the simulator, so a trailing control is found in two
    # or three probes instead of thirty. Every probe still costs the same bounded walk at most.
    for ((step = 0; ; step += 1)); do
      trailing=$((right - step * hit_test_pitch))
      leading=$((left + step * hit_test_pitch))
      ((trailing >= leading)) || break
      if found="$(hit_test_point_matches "${trailing}" "${centre_y}" "${label}")"; then
        printf '%s\n' "${found}"
        return 0
      fi
      ((trailing != leading)) || continue
      if found="$(hit_test_point_matches "${leading}" "${centre_y}" "${label}")"; then
        printf '%s\n' "${found}"
        return 0
      fi
    done
  done < <(
    jq -r --argjson height "${hit_test_bar_height}" '
      .[]
      | select(.type == "Group" and (.AXLabel // "") == "")
      | select(.frame.height <= $height and .frame.width >= 44)
      | "\(.frame.x + 6 | floor)\t\(.frame.y + (.frame.height / 2) | floor)\t\(.frame.x + .frame.width - 6 | floor)"
    ' "${accessibility_json}"
  )
  return 1
}

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
    simulator="$(
      jq -r '
        [.devices[][] | select(.isAvailable) | select(.name == "iPhone 17 Pro")][0].udid
        // [.devices[][] | select(.isAvailable) | select(.name | startswith("iPhone"))][0].udid
        // empty
      ' <<<"${devices_json}"
    )"
  fi
  if [[ -z "${simulator}" ]]; then
    printf 'error: no available iPhone simulator template\n' >&2
    return 1
  fi
  printf '%s\n' "${simulator}"
}

boot_simulator_if_needed() {
  local udid="$1"
  local state
  state="$(
    xcrun simctl list devices available -j \
      | jq -r --arg udid "${udid}" \
        '[.devices[][] | select(.udid == $udid)][0].state // empty'
  )"
  if [[ "${state}" != "Booted" ]]; then
    xcrun simctl boot "${udid}"
  fi
  xcrun simctl bootstatus "${udid}" -b >/dev/null
}

if [[ -n "${requested_template}" ]]; then
  # A named template is cloned exactly like the booted iPhone is, so a Mac whose booted iPhone
  # is running another session's app can hand the runner a shut-down device instead. The booted
  # path shuts its template down to clone it and boots it again afterwards, which kills whatever
  # was running on it; a template chosen by UDID is never booted here at all.
  template_simulator_udid="${requested_template}"
else
  template_simulator_udid="$(resolve_simulator "${requested_simulator}")"
fi
# The model, not the device's user-editable name: a template kept for cloning can be called
# anything, and the report's `device=` label and the iPhone check should both still answer for
# the hardware that drew the pixels.
device_type_identifier="$(
  xcrun simctl list devices available -j \
    | jq -r --arg udid "${template_simulator_udid}" \
      '[.devices[][] | select(.udid == $udid)][0].deviceTypeIdentifier // empty'
)"
device_name="$(
  xcrun simctl list devicetypes -j \
    | jq -r --arg identifier "${device_type_identifier}" \
      '[.devicetypes[] | select(.identifier == $identifier)][0].name // empty'
)"
if [[ -z "${device_name}" || "${device_name}" != iPhone* ]]; then
  printf 'error: simulator %s is not an available iPhone\n' \
    "${template_simulator_udid}" >&2
  exit 1
fi

if [[ "${requested_simulator}" == "booted" || -n "${requested_template}" ]]; then
  template_state="$(
    xcrun simctl list devices available -j \
      | jq -r --arg udid "${template_simulator_udid}" \
        '[.devices[][] | select(.udid == $udid)][0].state // empty'
  )"
  if [[ "${template_state}" == "Booted" ]]; then
    # CoreSimulator clones only shutdown devices. Restore the developer's template to its booted
    # state immediately after cloning; the evidence run itself never touches it again.
    template_simulator_to_reboot="${template_simulator_udid}"
    xcrun simctl shutdown "${template_simulator_udid}"
  fi

  printf 'Cloning an isolated %s for keyboard-safe evidence…\n' "${device_name}"
  temporary_simulator_udid="$(
    xcrun simctl clone "${template_simulator_udid}" "Threading UI Evidence $$"
  )"
  simulator_udid="${temporary_simulator_udid}"
  if [[ -n "${template_simulator_to_reboot}" ]]; then
    boot_simulator_if_needed "${template_simulator_to_reboot}"
    template_simulator_to_reboot=""
  fi

  # Software-keyboard visibility has a separate persistent Simulator menu state. A fresh device
  # with hardware-keyboard connection disabled is the only deterministic, permission-free
  # starting point. Preserve the developer's complete preference domain and restore it in the
  # cleanup trap after deleting the device created above.
  simulator_preferences_backup="$(mktemp -t threading-simulator-preferences).plist"
  simulator_preferences_work="$(mktemp -t threading-simulator-preferences-work).plist"
  defaults export com.apple.iphonesimulator "${simulator_preferences_backup}" >/dev/null
  cp "${simulator_preferences_backup}" "${simulator_preferences_work}"
  plutil -insert "DevicePreferences.${simulator_udid}" -dictionary \
    "${simulator_preferences_work}"
  plutil -insert "DevicePreferences.${simulator_udid}.ConnectHardwareKeyboard" \
    -bool NO "${simulator_preferences_work}"
  defaults import com.apple.iphonesimulator "${simulator_preferences_work}" >/dev/null

  boot_simulator_if_needed "${simulator_udid}"

  # A cloned device can still consider the software keyboard's first-use lessons unseen. Those
  # system coachmarks sit above every app window and can cover half of an otherwise valid
  # keyboard-open capture. Seed only the disposable evidence device; an explicitly supplied
  # developer simulator keeps its own onboarding state. `MultilingualKeyboardTip` is the
  # "Type English and Swedish" sheet a bilingual keyboard raises on its first keystroke: a
  # never-typed-on template inherits the host's two languages, and the sheet then swallowed the
  # walkthrough's typing taps while every keyboard-open screenshot still looked fine.
  for tutorial_key in \
      DidShowContinuousPathIntroduction \
      KeyboardDidShowProductivityTutorial \
      DidShowGestureKeyboardIntroduction \
      UIKeyboardDidShowInternationalInfoIntroduction \
      MultilingualKeyboardTip; do
    xcrun simctl spawn "${simulator_udid}" defaults write \
      com.apple.keyboard.preferences "${tutorial_key}" 1
  done
else
  simulator_udid="${template_simulator_udid}"
fi

if [[ -n "${requested_app}" ]]; then
  if [[ ! -d "${requested_app}" ]]; then
    printf 'error: prebuilt iOS app is missing: %s\n' "${requested_app}" >&2
    exit 1
  fi
  app="$(cd "$(dirname "${requested_app}")" 2>/dev/null && pwd)/$(basename "${requested_app}")"
  printf 'Using prebuilt ThreadingMobile for %s (%s)…\n' "${device_name}" "${simulator_udid}"
else
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
fi
if [[ ! -d "${app}" ]]; then
  printf 'error: built iOS app is missing: %s\n' "${app}" >&2
  exit 1
fi

# A clone may contain the template's installed app and preferences. Removing that copy makes the
# fixture state equivalent to a clean install while retaining the clone's already-migrated OS.
# An explicitly supplied developer simulator is different: install upgrades the app in place so
# a targeted evidence run never destroys the developer's app data.
if [[ -n "${temporary_simulator_udid}" ]]; then
  xcrun simctl uninstall "${simulator_udid}" "${bundle_identifier}" >/dev/null 2>&1 || true
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

run_token="ios-$(basename "${run_directory}" | tr -cd '[:alnum:]-' | cut -c1-80)"

# `simctl launch` normally returns as soon as launchd accepts the process. CoreSimulator can
# instead leave that client blocked indefinitely while the cloned device remains reported as
# Booted. Keeping the command bounded lets an isolated evidence device be rebooted and retried;
# capture readiness is still proved solely by the app-owned marker below.
bounded_simulator_launch() {
  local stdout_path="$1"
  local stderr_path="$2"
  shift 2
  local launch_environment=()
  while (($#)) && [[ "$1" != "--" ]]; do
    launch_environment+=("$1")
    shift
  done
  if (($#)); then
    shift
  fi
  local launch_arguments=("$@")
  local launch_pid launch_tick launch_status

  env "${launch_environment[@]}" \
    xcrun simctl launch \
      --terminate-running-process \
      --stdout="${stdout_path}" \
      --stderr="${stderr_path}" \
      "${simulator_udid}" \
      "${bundle_identifier}" \
      "${launch_arguments[@]}" >/dev/null &
  launch_pid=$!

  for ((launch_tick = 0; launch_tick < 300; launch_tick += 1)); do
    if ! kill -0 "${launch_pid}" >/dev/null 2>&1; then
      if wait "${launch_pid}"; then
        return 0
      else
        launch_status=$?
        return "${launch_status}"
      fi
    fi
    sleep 0.1
  done

  kill -TERM "${launch_pid}" >/dev/null 2>&1 || true
  for ((launch_tick = 0; launch_tick < 20; launch_tick += 1)); do
    kill -0 "${launch_pid}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  kill -KILL "${launch_pid}" >/dev/null 2>&1 || true
  wait "${launch_pid}" >/dev/null 2>&1 || true
  return 124
}

capture_fixture() {
  local fixture="$1"
  local identifier entry_id demo appearance theme keyboard_state capture_mode keyboard_layout
  local content_size terminal_font_size
  local interaction_label interaction_wait_labels
  identifier="$(jq -r '.id' <<<"${fixture}")"
  entry_id="$(jq -r '.entryID' <<<"${fixture}")"
  demo="$(jq -r '.demo' <<<"${fixture}")"
  appearance="$(jq -r '.appearance' <<<"${fixture}")"
  theme="$(jq -r '.theme' <<<"${fixture}")"
  if [[ -n "${requested_theme}" ]]; then
    theme="${requested_theme}"
    appearance="$(jq -r --arg theme "${theme}" \
      '.themeAppearances[$theme] // "dark"' "${manifest}")"
  fi
  keyboard_state="$(jq -r '.keyboardState // "none"' <<<"${fixture}")"
  capture_mode="$(jq -r '.captureMode // "app"' <<<"${fixture}")"
  keyboard_layout="$(jq -r '.keyboardLayout // "frame"' <<<"${fixture}")"
  content_size="$(jq -r '.contentSize // "large"' <<<"${fixture}")"
  terminal_font_size="$(jq -r '.terminalFontSize // empty' <<<"${fixture}")"
  interaction_label="$(jq -r '.interaction.tapAccessibilityLabel // empty' <<<"${fixture}")"
  interaction_wait_labels="$(jq -c \
    '.interaction.waitForAccessibilityLabels // []' <<<"${fixture}")"

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
  if ! jq -e --arg theme "${theme}" '.themeIDs | index($theme) != null' \
      "${manifest}" >/dev/null; then
    printf 'error: capture %s has unsupported theme: %s\n' "${identifier}" "${theme}" >&2
    return 1
  fi
  if [[ "${keyboard_state}" != "none" && "${keyboard_state}" != "closed" \
      && "${keyboard_state}" != "open" \
      && "${keyboard_state}" != "dismissed-after-open" ]]; then
    printf 'error: capture %s has unsupported keyboard state: %s\n' \
      "${identifier}" "${keyboard_state}" >&2
    return 1
  fi
  if [[ "${capture_mode}" != "app" \
      && "${capture_mode}" != "display" \
      && "${capture_mode}" != "stable-display" ]]; then
    printf 'error: capture %s has unsupported capture mode: %s\n' \
      "${identifier}" "${capture_mode}" >&2
    return 1
  fi
  if [[ "${keyboard_layout}" != "frame" && "${keyboard_layout}" != "origin" ]]; then
    printf 'error: capture %s has unsupported keyboard layout contract: %s\n' \
      "${identifier}" "${keyboard_layout}" >&2
    return 1
  fi
  case "${content_size}" in
    extra-small|small|medium|large|extra-large|extra-extra-large|extra-extra-extra-large) ;;
    *)
      printf 'error: capture %s has unsupported content size: %s\n' \
        "${identifier}" "${content_size}" >&2
      return 1
      ;;
  esac
  if [[ -n "${terminal_font_size}" ]] \
      && ! [[ "${terminal_font_size}" =~ ^([9]|1[0-9]|2[0-4])$ ]]; then
    printf 'error: capture %s has unsupported terminal font size: %s\n' \
      "${identifier}" "${terminal_font_size}" >&2
    return 1
  fi
  if [[ -n "${interaction_label}" ]]; then
    if ! command -v idb >/dev/null; then
      printf 'error: capture %s requires idb for semantic interaction\n' "${identifier}" >&2
      return 1
    fi
    if [[ "${capture_mode}" == "app" ]]; then
      printf 'error: capture %s must use display mode for a system menu\n' "${identifier}" >&2
      return 1
    fi
    if [[ "$(jq 'length' <<<"${interaction_wait_labels}")" -le 0 ]]; then
      printf 'error: capture %s has no semantic interaction postconditions\n' \
        "${identifier}" >&2
      return 1
    fi
  fi

  printf 'Capturing %-42s  %s · %s · %s\n' \
    "${identifier}" "${demo}" "${appearance}" "${theme}"
  xcrun simctl ui "${simulator_udid}" appearance "${appearance}"
  xcrun simctl ui "${simulator_udid}" content_size "${content_size}"

  local stdout_path="${log_directory}/${identifier}.stdout.log"
  local stderr_path="${log_directory}/${identifier}.stderr.log"
  local marker="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.json"
  local source_image="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.png"
  local failure="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.failure.txt"
  local interaction_ready="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.interaction-ready"
  local interaction_prepared="${data_container}/tmp/threading-ui-evidence/${run_token}/${identifier}.interaction-prepared"
  local launch_environment=(
    "SIMCTL_CHILD_THREADING_MOBILE_DEMO=${demo}"
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_RUN=${run_token}"
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_ID=${identifier}"
  )
  local launch_arguments=()
  if [[ -n "${terminal_font_size}" ]]; then
    launch_arguments+=("-mobileTerminalFontSize" "${terminal_font_size}")
  fi
  if [[ "${theme}" == "fallback" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=fallback")
  elif [[ "${theme}" == "custom-light" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=light")
  elif [[ "${theme}" == "threading" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=threading")
  elif [[ "${theme}" != "custom" ]]; then
    launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=${theme}")
  fi
  if [[ "${keyboard_state}" != "none" ]]; then
    launch_environment+=(
      "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE=${keyboard_state}"
    )
  fi
  launch_environment+=(
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_CAPTURE_MODE=${capture_mode}"
    "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_LAYOUT=${keyboard_layout}"
  )
  if [[ -n "${interaction_label}" ]]; then
    launch_environment+=(
      "SIMCTL_CHILD_THREADING_MOBILE_UI_EVIDENCE_HOST_INTERACTION=semantic-tap"
    )
  fi

  local launch_status
  if bounded_simulator_launch \
      "${stdout_path}" "${stderr_path}" "${launch_environment[@]}" \
      -- "${launch_arguments[@]}"; then
    launch_status=0
  else
    launch_status=$?
  fi
  if ((launch_status == 124)) && [[ -n "${temporary_simulator_udid}" ]]; then
    printf 'warning: simulator launch for %s stalled; rebooting the isolated device once\n' \
      "${identifier}" >&2
    if ((idb_connected)); then
      idb disconnect "${simulator_udid}" >/dev/null 2>&1 || true
      idb_connected=0
    fi
    xcrun simctl shutdown "${simulator_udid}"
    boot_simulator_if_needed "${simulator_udid}"
    xcrun simctl status_bar "${simulator_udid}" override \
      --time '9:41' --batteryState charged --batteryLevel 100 \
      --wifiBars 3 --cellularBars 4 >/dev/null
    if bounded_simulator_launch \
        "${stdout_path}" "${stderr_path}" "${launch_environment[@]}" \
        -- "${launch_arguments[@]}"; then
      launch_status=0
    else
      launch_status=$?
    fi
  fi
  if ((launch_status != 0)); then
    printf 'error: simulator could not launch fixture %s (status %s)\n' \
      "${identifier}" "${launch_status}" >&2
    return "${launch_status}"
  fi

  if [[ -n "${interaction_label}" ]]; then
    local interaction_poll accessibility_json tap_point tap_x tap_y
    for ((interaction_poll = 0; interaction_poll < 400; interaction_poll += 1)); do
      [[ -f "${interaction_ready}" ]] && break
      [[ -f "${failure}" ]] && break
      sleep 0.05
    done
    if [[ ! -f "${interaction_ready}" ]]; then
      printf 'error: fixture %s never requested its semantic interaction\n' \
        "${identifier}" >&2
      if [[ -f "${failure}" ]]; then
        sed -n '1,20p' "${failure}" >&2
      fi
      return 1
    fi

    if ((!idb_connected)); then
      idb connect "${simulator_udid}" >"${log_directory}/idb-connect.log" 2>&1
      idb_connected=1
    fi
    accessibility_json="${log_directory}/${identifier}.accessibility.json"
    tap_point=""
    # The app gives the host a bounded wait for this tap (`waitsForHostInteraction`), and one
    # `describe-all` round trip is a few hundred milliseconds on its own, so the fallback is
    # gated on the clock rather than on a poll count: one second of flattened polling is long
    # enough for any control enumeration will ever list, then the bars it flattened are walked,
    # and again every second after that.
    local last_hit_test=${SECONDS}
    for ((interaction_poll = 0; interaction_poll < 200; interaction_poll += 1)); do
      idb ui describe-all --json --udid "${simulator_udid}" >"${accessibility_json}"
      tap_point="$(jq -er --arg label "${interaction_label}" '
        [.[] | select((.AXLabel // "") | startswith($label))][0].frame
        | select(.width > 0 and .height > 0)
        | "\((.x + (.width / 2)) | round) \((.y + (.height / 2)) | round)"
      ' "${accessibility_json}" 2>/dev/null || true)"
      [[ -n "${tap_point}" ]] && break
      if ((SECONDS - last_hit_test >= 1)); then
        last_hit_test=${SECONDS}
        tap_point="$(
          hit_test_flattened_bars "${accessibility_json}" "${interaction_label}" || true
        )"
        if [[ -n "${tap_point}" ]]; then
          printf 'note: fixture %s found %s by hit-testing a bar idb had flattened\n' \
            "${identifier}" "${interaction_label}" >&2
          break
        fi
      fi
      sleep 0.05
    done
    if [[ -z "${tap_point}" ]]; then
      printf 'error: fixture %s has no accessible control beginning with %s\n' \
        "${identifier}" "${interaction_label}" >&2
      return 1
    fi
    read -r tap_x tap_y <<<"${tap_point}"
    idb ui tap --udid "${simulator_udid}" "${tap_x}" "${tap_y}" \
      >"${log_directory}/${identifier}.tap.log" 2>&1

    local interaction_settled=0
    for ((interaction_poll = 0; interaction_poll < 200; interaction_poll += 1)); do
      idb ui describe-all --json --udid "${simulator_udid}" >"${accessibility_json}"
      if jq -e --argjson labels "${interaction_wait_labels}" '
          [.[] | .AXLabel? // empty] as $actual
          | all($labels[]; . as $label | any($actual[]; startswith($label)))
        ' "${accessibility_json}" >/dev/null; then
        interaction_settled=1
        break
      fi
      sleep 0.05
    done
    if ((!interaction_settled)); then
      printf 'error: fixture %s did not expose every post-interaction label\n' \
        "${identifier}" >&2
      printf 'expected: %s\n' "${interaction_wait_labels}" >&2
      return 1
    fi
    : >"${interaction_prepared}"
  fi

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
    if [[ -f "${failure}" ]]; then
      sed -n '1,20p' "${failure}" >&2
    fi
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

  local assertion
  while IFS= read -r assertion; do
    if ! jq -e --arg assertion "${assertion}" \
        '.checks[$assertion] == true' "${marker}" >/dev/null; then
      printf 'error: fixture %s failed evidence assertion: %s\n' \
        "${identifier}" "${assertion}" >&2
      jq . "${marker}" >&2 || true
      return 1
    fi
  done < <(jq -r '.assertions[]?' <<<"${fixture}")

  if [[ "${capture_mode}" != "app" ]]; then
    # The software keyboard is an OS-owned window and therefore absent from the app-owned PNG.
    # `simctl io` captures only this simulator display, needs no macOS screen-recording grant,
    # and preserves the same deterministic device pixels as the ordinary evidence images.
    xcrun simctl io "${simulator_udid}" screenshot --type=png \
      "${current_directory}/ios/${identifier}.png" >/dev/null
  else
    cp "${source_image}" "${current_directory}/ios/${identifier}.png"
  fi
  cp "${marker}" "${log_directory}/${identifier}.json"
}

record_marketing_walkthrough() {
  local video="$1"
  local flow_id="ios-marketing-flow"
  local movie_demo movie_theme movie_appearance movie_terminal_font_size
  local movie_stdout movie_stderr
  local movie_launch_environment=()

  movie_demo="$(jq -r --arg flow "${flow_id}" \
    '.flows[] | select(.id == $flow) | .movie.demo // empty' "${manifest}")"
  if [[ -z "${movie_demo}" ]]; then
    printf 'error: %s has no recorded walkthrough demo\n' "${flow_id}" >&2
    return 1
  fi
  movie_theme="${requested_theme:-threading}"
  movie_appearance="$(jq -r --arg theme "${movie_theme}" \
    '.themeAppearances[$theme] // "dark"' "${manifest}")"
  movie_terminal_font_size="$(jq -r --arg flow "${flow_id}" \
    '.flows[] | select(.id == $flow) | .movie.terminalFontSize // empty' "${manifest}")"
  if ! [[ "${movie_terminal_font_size}" =~ ^([9]|1[0-9]|2[0-4])$ ]]; then
    printf 'error: %s has no valid recorded terminal font size\n' "${flow_id}" >&2
    return 1
  fi

  printf 'Recording marketing walkthrough                    %s · %s · %s\n' \
    "${movie_demo}" "${movie_appearance}" "${movie_theme}"
  xcrun simctl ui "${simulator_udid}" appearance "${movie_appearance}"
  xcrun simctl ui "${simulator_udid}" content_size large
  movie_stdout="${log_directory}/marketing-walkthrough.stdout.log"
  movie_stderr="${log_directory}/marketing-walkthrough.stderr.log"
  movie_launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_DEMO=${movie_demo}")
  case "${movie_theme}" in
    custom) ;;
    custom-light)
      movie_launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=light")
      ;;
    *)
      movie_launch_environment+=("SIMCTL_CHILD_THREADING_MOBILE_THEME=${movie_theme}")
      ;;
  esac

  if ! bounded_simulator_launch \
      "${movie_stdout}" "${movie_stderr}" "${movie_launch_environment[@]}" \
      -- -mobileTerminalFontSize "${movie_terminal_font_size}"; then
    printf 'error: simulator could not launch the marketing walkthrough\n' >&2
    return 1
  fi
  if ((!idb_connected)); then
    idb connect "${simulator_udid}" >"${log_directory}/idb-connect.log" 2>&1
    idb_connected=1
  fi
  python3 "${script_directory}/record_marketing_ios.py" \
    --udid "${simulator_udid}" \
    --manifest "${manifest}" \
    --flow "${flow_id}" \
    --output "${video}" \
    --log "${log_directory}/marketing-walkthrough-timeline.json"
}

requested_only_json='[]'
if [[ -n "${requested_only}" ]]; then
  requested_only_json="$(jq -Rn --arg value "${requested_only}" '
    $value
    | split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0))
  ')"
fi

capture_selection='.
  as $capture
  | select(
      ($only | length) == 0
      or ($only | any(
        . == $capture.id
        or . == $capture.entryID
        or ("ios-" + .) == $capture.entryID
      ))
    )'

capture_count="$(jq --argjson only "${requested_only_json}" \
  "[.captures[] | ${capture_selection}] | length" "${manifest}")"
if [[ "${capture_count}" -le 0 ]]; then
  printf 'error: iOS evidence selection has no captures\n' >&2
  exit 1
fi

while IFS= read -r fixture; do
  capture_fixture "${fixture}"
done < <(jq --argjson only "${requested_only_json}" -c \
  ".captures[] | ${capture_selection}" "${manifest}")

if [[ -n "${requested_marketing_video}" ]]; then
  record_marketing_walkthrough "${requested_marketing_video}"
fi

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
  --environment "device=${device_name}"
  --environment "runner=iOS Simulator app-owned capture"
)
if [[ -n "${requested_theme}" ]]; then
  generator_arguments+=(--environment "themeOverride=${requested_theme}")
fi
if ((accept_new_baselines)); then
  generator_arguments+=(--accept-new-baselines)
fi
if [[ -n "${requested_only}" ]]; then
  generator_arguments+=(--allow-missing-captures)
  while IFS= read -r entry_id; do
    [[ -n "${entry_id}" ]] || continue
    generator_arguments+=(--only-entry "${entry_id}")
  done < <(jq --argjson only "${requested_only_json}" -r \
    "[.captures[] | ${capture_selection} | .entryID] | unique[]" "${manifest}")
fi
if ((require_accepted)); then
  generator_arguments+=(--require-accepted)
fi

set +e
report_path="$(python3 "${script_directory}/generate_ui_evidence_report.py" \
  "${generator_arguments[@]}")"
generator_status=$?
set -e
if [[ -n "${report_path}" ]]; then
  printf '\niOS UI evidence report: %s\n' "${report_path}"
  printf 'Regression approval: %s/regression.html\n' "${report_directory}"
  printf 'Open it with: open %q\n' "${report_path}"
fi
if ((generator_status != 0)); then
  exit "${generator_status}"
fi
