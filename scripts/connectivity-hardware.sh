#!/usr/bin/env bash
#
# A physical-iPhone connectivity lane. CoreDevice owns lifecycle faults and evidence capture; the
# operator owns only radio and Network Link Conditioner changes that public tooling cannot
# perform. Every checkpoint is proved by a new record in the app's share-safe journal.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
diagnostics_tool="${script_directory}/connectivity_diagnostics.py"

device=""
scenario="all"
bundle_id="codes.threading.mobile"
process_name="ThreadingMobile"
timeout_seconds=60
suspend_seconds=10
non_interactive=0
output_directory=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/connectivity-hardware.sh --device <name-or-UDID> [options]

Options:
  --scenario <name>     automatic, smoke, kill, suspend, airplane, handoff, conditioned, or all
  --bundle-id <id>      installed iOS app bundle id (default: codes.threading.mobile)
  --process-name <name> app executable name (default: ThreadingMobile)
  --timeout <seconds>   deadline for each journal checkpoint (default: 60)
  --suspend-seconds <n> unattended suspend duration (default: 10)
  --non-interactive     skip prompts; valid with automatic, smoke, kill, or suspend
  --output <directory>  evidence directory (default: .build/connectivity-hardware/<stamp>)
  --list-devices        list CoreDevice targets and exit
  -h, --help            show this help

The automatic scenario runs smoke, kill, and suspend without operator input. Radio and Network
Link Conditioner scenarios remain guided because public device tooling cannot change them.
The script does not install or erase the app or change its Keychain state.
USAGE
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

say() {
  printf '\n==> %s\n' "$1"
}

prompt() {
  printf '\n%s\n' "$1"
  read -r -p "Press Return when ready (or Ctrl-C to stop). " _
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --device)
      [[ "$#" -ge 2 ]] || fail "--device needs a value"
      device="$2"
      shift 2
      ;;
    --scenario)
      [[ "$#" -ge 2 ]] || fail "--scenario needs a value"
      scenario="$2"
      shift 2
      ;;
    --bundle-id)
      [[ "$#" -ge 2 ]] || fail "--bundle-id needs a value"
      bundle_id="$2"
      shift 2
      ;;
    --process-name)
      [[ "$#" -ge 2 ]] || fail "--process-name needs a value"
      process_name="$2"
      shift 2
      ;;
    --timeout)
      [[ "$#" -ge 2 ]] || fail "--timeout needs a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --suspend-seconds)
      [[ "$#" -ge 2 ]] || fail "--suspend-seconds needs a value"
      suspend_seconds="$2"
      shift 2
      ;;
    --non-interactive)
      non_interactive=1
      shift
      ;;
    --output)
      [[ "$#" -ge 2 ]] || fail "--output needs a value"
      output_directory="$2"
      shift 2
      ;;
    --list-devices)
      exec xcrun devicectl list devices
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${device}" ]] || fail "--device is required; use --list-devices to find it"
[[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || fail "--timeout must be a positive integer"
[[ "${suspend_seconds}" =~ ^[1-9][0-9]*$ ]] || fail "--suspend-seconds must be a positive integer"
case "${scenario}" in
  automatic|smoke|kill|suspend|airplane|handoff|conditioned|all) ;;
  *) fail "unknown scenario: ${scenario}" ;;
esac
if [[ "${non_interactive}" == "1" ]]; then
  case "${scenario}" in
    automatic|smoke|kill|suspend) ;;
    *) fail "--non-interactive cannot control radio scenarios; use automatic, smoke, kill, or suspend" ;;
  esac
fi

command -v xcrun >/dev/null 2>&1 || fail "xcrun is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[[ -x "${diagnostics_tool}" ]] || fail "diagnostics helper is not executable: ${diagnostics_tool}"

if [[ -z "${output_directory}" ]]; then
  output_directory="${repository_directory}/.build/connectivity-hardware/$(date -u +%Y%m%d-%H%M%S)"
fi
journal_directory="${output_directory}/journal"
command_output_directory="${output_directory}/commands"
mkdir -p "${journal_directory}" "${command_output_directory}"

pull_journal() {
  local result_stamp
  result_stamp="$(date -u +%Y%m%dT%H%M%S)-${BASHPID}-${RANDOM}"
  xcrun devicectl device copy from \
    --device "${device}" \
    --domain-type appDataContainer \
    --domain-identifier "${bundle_id}" \
    --source "Library/Application Support/Threading/Diagnostics" \
    --destination "${journal_directory}" \
    --json-output "${command_output_directory}/copy-${result_stamp}.json" \
    --quiet
}

marker() {
  pull_journal
  python3 "${diagnostics_tool}" marker "${journal_directory}"
}

wait_for_event() {
  local checkpoint="$1"
  local after="$2"
  shift 2
  local deadline=$((SECONDS + timeout_seconds))
  local check_output="${command_output_directory}/${checkpoint}.json"
  local check_error="${command_output_directory}/${checkpoint}.stderr"
  local check_status

  say "Waiting up to ${timeout_seconds}s for ${checkpoint}"
  while (( SECONDS < deadline )); do
    pull_journal
    set +e
    python3 "${diagnostics_tool}" check "${journal_directory}" \
      --after "${after}" "$@" > "${check_output}" 2> "${check_error}"
    check_status=$?
    set -e
    if [[ "${check_status}" == "0" ]]; then
      cat "${check_output}"
      return 0
    fi
    if [[ "${check_status}" == "2" ]]; then
      cat "${check_error}" >&2
      return 2
    fi
    sleep 2
  done

  printf 'error: checkpoint %s did not arrive after %s\n' "${checkpoint}" "${after}" >&2
  python3 "${diagnostics_tool}" timeline "${journal_directory}" --after "${after}" >&2 || true
  return 1
}

launch_phone() {
  local label="$1"
  xcrun devicectl device process launch \
    --device "${device}" \
    --terminate-existing \
    --activate \
    --json-output "${command_output_directory}/${label}-launch.json" \
    --quiet \
    "${bundle_id}"
}

activate_phone() {
  local label="$1"
  # iOS has one application process per bundle. Without --terminate-existing this asks
  # SpringBoard to foreground the resumed instance rather than replacing the suspension fault
  # with a cold launch.
  xcrun devicectl device process launch \
    --device "${device}" \
    --activate \
    --json-output "${command_output_directory}/${label}-activate.json" \
    --quiet \
    "${bundle_id}"
}

process_pid() {
  local json_path="${command_output_directory}/processes.json"
  xcrun devicectl device info processes \
    --device "${device}" \
    --filter "executable.path CONTAINS '/${process_name}.app/'" \
    --json-output "${json_path}" \
    --quiet
  python3 - "${json_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    processes = json.load(handle).get("result", {}).get("runningProcesses", [])
if len(processes) != 1:
    raise SystemExit(f"expected one matching app process, found {len(processes)}")
print(processes[0]["processIdentifier"])
PY
}

ensure_connected() {
  local label="$1"
  local before
  before="$(marker)"
  launch_phone "${label}"
  wait_for_event "${label}-connected" "${before}" --event hostRefreshSucceeded
  wait_for_event "${label}-event-socket" "${before}" \
    --event socketConnected --field surface=events
}

run_smoke() {
  say "Smoke: cold foreground launch reaches the paired Mac"
  ensure_connected "smoke"
}

run_kill() {
  say "Kill: SIGKILL the connected iOS client, then prove a fresh connection"
  ensure_connected "kill-baseline"
  local before pid
  pid="$(process_pid)"
  xcrun devicectl device process terminate \
    --device "${device}" --pid "${pid}" --kill \
    --json-output "${command_output_directory}/kill-sigkill.json" --quiet
  before="$(marker)"
  launch_phone "kill-relaunch"
  wait_for_event "kill-reconnected" "${before}" --event hostRefreshSucceeded
  wait_for_event "kill-event-socket" "${before}" \
    --event socketConnected --field surface=events
}

run_suspend() {
  say "Suspend: freeze and resume the iOS client"
  ensure_connected "suspend-baseline"
  local before pid
  pid="$(process_pid)"
  xcrun devicectl device process suspend \
    --device "${device}" --pid "${pid}" \
    --json-output "${command_output_directory}/suspend.json" --quiet
  before="$(marker)"
  if [[ "${non_interactive}" == "1" ]]; then
    say "Holding the app suspended for ${suspend_seconds}s"
    sleep "${suspend_seconds}"
  else
    prompt "The app is suspended. Leave it frozen for as long as you want, then continue."
  fi
  xcrun devicectl device process resume \
    --device "${device}" --pid "${pid}" \
    --json-output "${command_output_directory}/resume.json" --quiet
  if [[ "${non_interactive}" == "1" ]]; then
    activate_phone "suspend-resumed"
  else
    prompt "Return to Threading on the phone. If a refresh does not start, pull to refresh the paired host."
  fi
  wait_for_event "suspend-reconnected" "${before}" --event hostRefreshSucceeded
}

run_airplane() {
  say "Airplane mode: observe a bounded failure, then recovery"
  ensure_connected "airplane-baseline"
  local offline_marker online_marker
  offline_marker="$(marker)"
  prompt "Turn Airplane Mode ON. Return to Threading and pull to refresh the paired host."
  wait_for_event "airplane-offline" "${offline_marker}" --event hostRefreshFailed
  online_marker="$(marker)"
  prompt "Turn Airplane Mode OFF. Wait for the network indicator, return to Threading, and pull to refresh."
  wait_for_event "airplane-reconnected" "${online_marker}" --event hostRefreshSucceeded
}

run_handoff() {
  say "Wi-Fi to cellular: require a successful non-LAN route, then restore LAN"
  ensure_connected "handoff-baseline"
  local cellular_marker wifi_marker
  cellular_marker="$(marker)"
  prompt "Leave cellular data ON, turn Wi-Fi OFF, return to Threading, and pull to refresh. This host must have a cellular-reachable Tailscale or Hosted Direct route."
  wait_for_event "handoff-cellular" "${cellular_marker}" \
    --event hostRefreshSucceeded --field-not transport=lan
  wifi_marker="$(marker)"
  prompt "Turn Wi-Fi ON, return to Threading, and pull to refresh."
  wait_for_event "handoff-wifi" "${wifi_marker}" --event hostRefreshSucceeded
}

run_conditioned() {
  say "Conditioned network: force a terminal result under impairment, then recover"
  ensure_connected "conditioned-baseline"
  local impaired_marker recovery_marker
  impaired_marker="$(marker)"
  prompt "On the phone, enable a Network Link Conditioner profile (for example Very Bad Network), return to Threading, and pull to refresh."
  wait_for_event "conditioned-terminal-result" "${impaired_marker}" \
    --event hostRefreshSucceeded --event hostRefreshFailed
  recovery_marker="$(marker)"
  prompt "Disable Network Link Conditioner, return to Threading, and pull to refresh."
  wait_for_event "conditioned-reconnected" "${recovery_marker}" --event hostRefreshSucceeded
}

say "Preflighting ${device}"
xcrun devicectl device info processes \
  --device "${device}" \
  --json-output "${command_output_directory}/preflight-processes.json" \
  --quiet
pull_journal

cat <<NOTICE

This run will foreground, suspend, resume, and/or SIGKILL only ${bundle_id} on ${device}.
It will not install the app, erase its data, change Keychain state, or alter network settings.
Keep the paired Mac awake with Remote Access enabled.

Evidence: ${output_directory}
NOTICE
if [[ "${non_interactive}" == "1" ]]; then
  say "Non-interactive preflight accepted; the phone must already be unlocked and reachable"
else
  prompt "Confirm the phone is unlocked, Threading is already installed and paired, and the Mac is reachable."
fi

case "${scenario}" in
  automatic)
    run_smoke
    run_kill
    run_suspend
    ;;
  smoke) run_smoke ;;
  kill) run_kill ;;
  suspend) run_suspend ;;
  airplane) run_airplane ;;
  handoff) run_handoff ;;
  conditioned) run_conditioned ;;
  all)
    run_smoke
    run_kill
    run_suspend
    run_handoff
    run_airplane
    run_conditioned
    ;;
esac

say "Hardware connectivity lane passed"
printf 'Evidence: %s\n' "${output_directory}"
