#!/usr/bin/env bash
#
# Exercises the exact workflow agents are told to prefer: build for one already-booted device,
# then prepare/install/launch/inspect/control it through Threading's adopted right-panel route.
# The same run launches the exact signed macOS app in its hidden, read-only compatibility mode so
# every selected Xcode is tested against the shipped host/helper pair and its private frameworks.
#
# The runner never boots or shuts down a device and never opens Simulator.app. It fails if the
# any Simulator GUI is present or the workflow changes the supplied device's boot lifecycle.
#
# Usage:
#   scripts/simulator_dogfood.sh
#   scripts/simulator_dogfood.sh --udid <exact-booted-uuid>
#   scripts/simulator_dogfood.sh --xcode /Applications/Xcode.app \
#       --xcode /Applications/Xcode-beta.app
#   scripts/simulator_dogfood.sh --app build/release/export/Threading.app \
#       --require-notarized
#
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/coresimulator_lane_lock.sh"
requested_udid=""
app_path=""
output_root=""
require_notarized=0
xcode_paths=()

fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
say() { printf '\n==> %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid)
            shift
            requested_udid="${1:-}"
            ;;
        --xcode)
            shift
            xcode_paths+=("${1:-}")
            ;;
        --app)
            shift
            app_path="${1:-}"
            ;;
        --output)
            shift
            output_root="${1:-}"
            ;;
        --require-notarized)
            require_notarized=1
            ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) fail "unknown argument '$1'" ;;
    esac
    shift
done

if [[ ${#xcode_paths[@]} -eq 0 ]]; then
    xcode_paths+=("$(xcode-select -p)")
fi

if [[ -n "$app_path" ]]; then
    [[ "$app_path" = /* ]] || fail "--app must be an absolute path"
    [[ -d "$app_path" ]] || fail "no app bundle exists at $app_path"
fi

threading_acquire_coresimulator_lane "Simulator dogfood compatibility matrix" || exit $?

if [[ -z "$output_root" ]]; then
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    output_root="$ROOT/build/simulator-compatibility/$timestamp"
fi
[[ "$output_root" = /* ]] || output_root="$ROOT/$output_root"
if [[ -e "$output_root" && ! -d "$output_root" ]]; then
    fail "--output exists and is not a directory: $output_root"
fi
if [[ -d "$output_root" && -n "$(find "$output_root" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "--output must be new or empty so stale evidence cannot be reused: $output_root"
fi
mkdir -p "$output_root"
matrix_token="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-12)"

active_cleanup_udid=""
active_cleanup_bundle=""
active_developer_dir=""
cleanup_mobile_fixture() {
    local cleanup_status=0
    if [[ -n "$active_cleanup_udid" && -n "$active_cleanup_bundle" \
        && -n "$active_developer_dir" ]]; then
        cleanup_status=1
        local attempt
        for attempt in {1..12}; do
            DEVELOPER_DIR="$active_developer_dir" xcrun simctl terminate \
                "$active_cleanup_udid" "$active_cleanup_bundle" >/dev/null 2>&1 || true
            DEVELOPER_DIR="$active_developer_dir" xcrun simctl uninstall \
                "$active_cleanup_udid" "$active_cleanup_bundle" >/dev/null 2>&1 || true
            if wait_for_mobile_bundle_state "$active_developer_dir" \
                "$active_cleanup_udid" "$active_cleanup_bundle" absent 1; then
                cleanup_status=0
                break
            fi
            [[ $attempt -eq 12 ]] || sleep 1
        done
    fi
    active_cleanup_udid=""
    active_cleanup_bundle=""
    active_developer_dir=""
    return "$cleanup_status"
}
trap 'cleanup_mobile_fixture || true' EXIT

normalise_developer_dir() {
    local candidate="$1"
    if [[ "$candidate" == *.app ]]; then
        candidate="$candidate/Contents/Developer"
    fi
    [[ -x "$candidate/usr/bin/xcodebuild" ]] || return 1
    printf '%s\n' "$candidate"
}

xcode_label() {
    local candidate="$1"
    if [[ "$candidate" == */Contents/Developer ]]; then
        candidate="$(dirname "$(dirname "$candidate")")"
    fi
    candidate="$(basename "$candidate")"
    printf '%s' "$candidate" | tr -cs '[:alnum:].-' '_'
}

list_external_simulator_gui() {
    {
        pgrep -x Simulator 2>/dev/null || true
        pgrep -x "iOS Simulator" 2>/dev/null || true
        pgrep -x "Device Hub" 2>/dev/null || true
        pgrep -f '/(Simulator|Device Hub)\.app/Contents/MacOS/' 2>/dev/null || true
    } | sort -u
}

record_failure() {
    local run_directory="$1"
    shift
    printf '%s\n' "$*" >> "$run_directory/failure.txt"
    printf '  failed: %s\n' "$*" >&2
}

select_device() {
    local catalogue="$1"
    local wanted="$2"
    python3 - "$catalogue" "$wanted" <<'PYTHON'
import json
import sys

catalogue = json.load(open(sys.argv[1], encoding="utf-8"))
wanted = sys.argv[2].upper()
candidates = []
for runtime, devices in catalogue.get("devices", {}).items():
    if "SimRuntime.iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True) or device.get("state") != "Booted":
            continue
        candidates.append((
            device.get("udid", ""),
            device.get("name", ""),
            runtime,
            device.get("lastBootedAt") or "",
        ))

if wanted:
    candidates = [entry for entry in candidates if entry[0].upper() == wanted]
if not candidates:
    sys.exit(1)
print("\t".join(candidates[0]))
PYTHON
}

mobile_bundle_presence() {
    local developer_dir="$1"
    local udid="$2"
    local bundle_id="$3"
    local plist_file
    local json_file
    plist_file="$(mktemp -t threading-simulator-listapps)"
    json_file="$(mktemp -t threading-simulator-listapps-json)"
    if ! DEVELOPER_DIR="$developer_dir" xcrun simctl listapps "$udid" \
        > "$plist_file" 2>/dev/null; then
        rm -f "$plist_file" "$json_file"
        return 2
    fi
    if ! plutil -convert json -o "$json_file" "$plist_file" >/dev/null 2>&1; then
        rm -f "$plist_file" "$json_file"
        return 2
    fi
    rm -f "$plist_file"
    if python3 - "$json_file" "$bundle_id" <<'PYTHON'
import json
import sys
catalogue = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if sys.argv[2] in catalogue else 1)
PYTHON
    then
        rm -f "$json_file"
        return 0
    fi
    rm -f "$json_file"
    return 1
}

wait_for_mobile_bundle_state() {
    local developer_dir="$1"
    local udid="$2"
    local bundle_id="$3"
    local wanted="$4"
    local maximum_attempts="${5:-12}"
    local attempt
    for ((attempt = 1; attempt <= maximum_attempts; attempt += 1)); do
        local state="unknown"
        if mobile_bundle_presence "$developer_dir" "$udid" "$bundle_id"; then
            state="present"
        else
            local presence_status=$?
            [[ $presence_status -eq 1 ]] && state="absent"
        fi
        [[ "$state" == "$wanted" ]] && return 0
        [[ $attempt -eq $maximum_attempts ]] || sleep 1
    done
    return 1
}

write_entry_report() {
    local run_directory="$1"
    local developer_dir="$2"
    local device_id="$3"
    local device_name="$4"
    local runtime_id="$5"
    local workflow_host="$6"
    local probed_app="$7"
    local signature_verified="$8"
    local gatekeeper="$9"
    local notarization_ticket="${10}"
    local agent_workflow="${11}"
    python3 - "$run_directory" "$developer_dir" "$device_id" "$device_name" \
        "$runtime_id" "$workflow_host" "$probed_app" "$signature_verified" "$gatekeeper" \
        "$notarization_ticket" "$agent_workflow" <<'PYTHON'
import json
import sys
from pathlib import Path

(run_raw, developer_dir, device_id, device_name, runtime_id, workflow_host, probed_app,
 signature_verified, gatekeeper, notarization_ticket, agent_workflow) = sys.argv[1:]
run = Path(run_raw)

def text(name):
    path = run / name
    return path.read_text(encoding="utf-8").strip() if path.exists() else None

probe = None
probe_path = run / "bundle-probe.json"
if probe_path.exists():
    try:
        probe = json.loads(probe_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        probe = {"outcome": "invalid-report"}

failure = text("failure.txt")
entry = {
    "outcome": "failed" if failure else "passed",
    "failure": failure,
    "developer_dir": developer_dir,
    "xcode_version": text("xcode-version.txt"),
    "device": {
        "udid": device_id or None,
        "name": device_name or None,
        "runtime_identifier": runtime_id or None,
        "remained_booted": text("device-remained-booted.txt") == "yes",
        "last_booted_at_before": text("device-last-booted-before.txt"),
        "last_booted_at_after": text("device-last-booted-after.txt"),
        "boot_cycle_observed": (
            text("device-last-booted-before.txt") is not None
            and text("device-last-booted-after.txt") is not None
            and text("device-last-booted-before.txt") != text("device-last-booted-after.txt")
        ),
    },
    "agent_workflow": agent_workflow,
    "external_simulator_gui_present": text("external-gui-present.txt") == "yes",
    "workflow_host": {
        "path": workflow_host or None,
        "coverage": "hosted AgentToolCoordinator and adopted pane",
    },
    "probed_app": {
        "path": probed_app or None,
        "signature_verified": signature_verified == "yes",
        "gatekeeper": gatekeeper,
        "notarization_ticket": notarization_ticket,
    },
    "bundle_probe": probe,
    "logs": {
        "mobile_build": str(run / "mobile-build.log"),
        "agent_test": str(run / "agent-test.log"),
        "bundle_probe": str(run / "bundle-probe.log"),
    },
}
(run / "entry.json").write_text(
    json.dumps(entry, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYTHON
}

run_one_xcode() {
    local xcode_path="$1"
    local index="$2"
    local developer_dir=""
    local device_id=""
    local device_name=""
    local runtime_id=""
    local initial_last_booted_at=""
    local workflow_host=""
    local probed_app=""
    local signature_verified="no"
    local gatekeeper="not-checked"
    local notarization_ticket="not-checked"
    local agent_workflow="not-run"
    local failed=0

    local label
    label="$(xcode_label "$xcode_path")-$index"
    local run_directory="$output_root/$label"
    mkdir -p "$run_directory"

    if ! developer_dir="$(normalise_developer_dir "$xcode_path")"; then
        record_failure "$run_directory" "invalid Xcode developer directory: $xcode_path"
        write_entry_report "$run_directory" "$xcode_path" "" "" "" "" "" \
            "$signature_verified" "$gatekeeper" "$notarization_ticket" "$agent_workflow"
        return 1
    fi
    DEVELOPER_DIR="$developer_dir" xcodebuild -version > "$run_directory/xcode-version.txt"
    say "$(head -1 "$run_directory/xcode-version.txt")"

    if ! DEVELOPER_DIR="$developer_dir" xcrun simctl list devices available -j \
        > "$run_directory/devices-before.json"; then
        record_failure "$run_directory" "could not read the CoreSimulator device catalogue"
        failed=1
    fi
    if [[ $failed -eq 0 ]]; then
        local selected=""
        if ! selected="$(select_device \
            "$run_directory/devices-before.json" "$requested_udid")"; then
            record_failure "$run_directory" \
                "no matching already-booted available iOS Simulator was found"
            failed=1
        else
            IFS=$'\t' read -r device_id device_name runtime_id initial_last_booted_at \
                <<< "$selected"
            printf '%s\n' "$initial_last_booted_at" \
                > "$run_directory/device-last-booted-before.txt"
            printf '  device: %s (%s)\n' "$device_name" "$device_id"
        fi
    fi

    list_external_simulator_gui > "$run_directory/gui-before.txt"
    if [[ -s "$run_directory/gui-before.txt" ]]; then
        record_failure "$run_directory" \
            "close Apple Simulator and Device Hub before running conclusive headless evidence"
        failed=1
    fi

    local mobile_derived="$run_directory/mobile-derived-data"
    local mac_derived="$run_directory/mac-derived-data"
    local dogfood_bundle_id="codes.threading.mobile.simulator-dogfood.r$matrix_token.$index"
    if [[ $failed -eq 0 ]]; then
        say "Building the iOS dogfood app for the exact device"
        if ! DEVELOPER_DIR="$developer_dir" xcodebuild \
            -project "$ROOT/Threading.xcodeproj" \
            -scheme ThreadingMobile \
            -configuration Debug \
            -destination "platform=iOS Simulator,id=$device_id" \
            -derivedDataPath "$mobile_derived" \
            PRODUCT_BUNDLE_IDENTIFIER="$dogfood_bundle_id" \
            build > "$run_directory/mobile-build.log" 2>&1; then
            record_failure "$run_directory" \
                "the exact-destination ThreadingMobile build failed; see mobile-build.log"
            failed=1
        fi
    fi

    local mobile_app="$mobile_derived/Build/Products/Debug-iphonesimulator/ThreadingMobile.app"
    if [[ $failed -eq 0 && ! -d "$mobile_app" ]]; then
        record_failure "$run_directory" "the mobile build produced no ThreadingMobile.app"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        local built_bundle_id
        built_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$mobile_app/Info.plist" 2>/dev/null || true)"
        if [[ "$built_bundle_id" != "$dogfood_bundle_id" ]]; then
            record_failure "$run_directory" \
                "the mobile build ignored its unique dogfood bundle identifier"
            failed=1
        elif ! wait_for_mobile_bundle_state "$developer_dir" "$device_id" \
            "$dogfood_bundle_id" absent; then
            record_failure "$run_directory" \
                "could not prove the unique dogfood bundle was absent before install"
            failed=1
        fi
    fi

    if [[ $failed -eq 0 ]]; then
        active_cleanup_udid="$device_id"
        active_cleanup_bundle="$dogfood_bundle_id"
        active_developer_dir="$developer_dir"
        say "Driving the shipping agent tools through the adopted right panel"
        if ! DEVELOPER_DIR="$developer_dir" \
            THREADING_SIMULATOR_INTEGRATION_UDID="$device_id" \
            THREADING_SIMULATOR_DOGFOOD_APP_PATH="$mobile_app" \
            THREADING_SIMULATOR_DOGFOOD_BUNDLE_ID="$dogfood_bundle_id" \
            "$ROOT/scripts/test.sh" fast \
            -derivedDataPath "$mac_derived" \
            -parallel-testing-enabled NO \
            -only-testing:ThreadingTests/SimulatorLiveIntegrationTests \
            -only-testing:ThreadingTests/SimulatorAgentDogfoodIntegrationTests \
            > "$run_directory/agent-test.log" 2>&1; then
            record_failure "$run_directory" \
                "the live agent/pane workflow failed; see agent-test.log"
            agent_workflow="failed"
            failed=1
        else
            agent_workflow="passed"
        fi
        if ! cleanup_mobile_fixture; then
            record_failure "$run_directory" \
                "could not conclusively remove the unique dogfood bundle after bounded retries"
            failed=1
        fi
    fi

    workflow_host="$mac_derived/Build/Products/Debug/Threading.app"
    if [[ -n "$app_path" ]]; then
        probed_app="$app_path"
    else
        probed_app="$workflow_host"
    fi
    if [[ $failed -eq 0 && ! -d "$probed_app" ]]; then
        record_failure "$run_directory" "the signed macOS app bundle is missing: $probed_app"
        failed=1
    fi
    if [[ $failed -eq 0 ]]; then
        if codesign --verify --deep --strict "$probed_app" \
            > "$run_directory/codesign-verify.log" 2>&1; then
            signature_verified="yes"
        else
            record_failure "$run_directory" "the macOS app signature did not verify"
            failed=1
        fi
        codesign -d --verbose=4 "$probed_app" \
            > "$run_directory/codesign-detail.txt" 2>&1 || true
        if spctl --assess --type execute --verbose=4 "$probed_app" \
            > "$run_directory/gatekeeper.txt" 2>&1; then
            gatekeeper="accepted"
        else
            gatekeeper="rejected"
        fi
        if xcrun stapler validate "$probed_app" \
            > "$run_directory/stapler.txt" 2>&1; then
            notarization_ticket="valid"
        else
            notarization_ticket="missing-or-invalid"
        fi
        if [[ $require_notarized -eq 1 \
            && ( "$gatekeeper" != "accepted" || "$notarization_ticket" != "valid" ) ]]; then
            record_failure "$run_directory" \
                "--require-notarized needs Gatekeeper acceptance and a valid stapled ticket"
            failed=1
        fi
    fi

    if [[ $failed -eq 0 ]]; then
        local executable_name
        executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
            "$probed_app/Contents/Info.plist" 2>/dev/null || true)"
        local executable="$probed_app/Contents/MacOS/$executable_name"
        if [[ -z "$executable_name" || ! -x "$executable" ]]; then
            record_failure "$run_directory" "the macOS app has no executable compatibility host"
            failed=1
        else
            say "Probing the exact signed host/helper pair"
            if ! python3 - "$executable" "$device_id" \
                "$run_directory/bundle-probe.json" "$developer_dir" \
                > "$run_directory/bundle-probe.log" 2>&1 <<'PYTHON'
import os
import subprocess
import sys

executable, udid, report, developer_dir = sys.argv[1:]
environment = os.environ.copy()
environment["DEVELOPER_DIR"] = developer_dir
try:
    completed = subprocess.run(
        [
            executable,
            "--simulator-compatibility-probe", udid,
            "--simulator-compatibility-report", report,
        ],
        env=environment,
        timeout=30,
        check=False,
    )
except subprocess.TimeoutExpired:
    print("compatibility probe exceeded 30 seconds", file=sys.stderr)
    sys.exit(124)
sys.exit(completed.returncode)
PYTHON
            then
                record_failure "$run_directory" "the signed-bundle compatibility probe failed"
                failed=1
            elif ! python3 - "$run_directory/bundle-probe.json" <<'PYTHON'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if report.get("outcome") == "compatible" else 1)
PYTHON
            then
                record_failure "$run_directory" \
                    "the signed host/helper pair is incompatible with this Xcode/runtime"
                failed=1
            fi
        fi
    fi

    list_external_simulator_gui > "$run_directory/gui-after.txt"
    if [[ -s "$run_directory/gui-before.txt" || -s "$run_directory/gui-after.txt" ]]; then
        printf 'yes\n' > "$run_directory/external-gui-present.txt"
        if [[ $failed -eq 0 ]]; then
            record_failure "$run_directory" \
                "an Apple Simulator or Device Hub GUI process was present during the run"
            failed=1
        fi
    else
        printf 'no\n' > "$run_directory/external-gui-present.txt"
    fi

    local final_device=""
    if [[ -n "$device_id" ]] \
        && DEVELOPER_DIR="$developer_dir" xcrun simctl list devices available -j \
            > "$run_directory/devices-after.json" \
        && final_device="$(select_device "$run_directory/devices-after.json" "$device_id")"; then
        local final_id=""
        local final_name=""
        local final_runtime=""
        local final_last_booted_at=""
        IFS=$'\t' read -r final_id final_name final_runtime final_last_booted_at \
            <<< "$final_device"
        printf '%s\n' "$final_last_booted_at" \
            > "$run_directory/device-last-booted-after.txt"
        if [[ "$final_last_booted_at" == "$initial_last_booted_at" ]]; then
            printf 'yes\n' > "$run_directory/device-remained-booted.txt"
        else
            printf 'no\n' > "$run_directory/device-remained-booted.txt"
            if [[ $failed -eq 0 ]]; then
                record_failure "$run_directory" \
                    "the adopted user device was shut down or rebooted during the lane"
                failed=1
            fi
        fi
    else
        printf 'no\n' > "$run_directory/device-remained-booted.txt"
        if [[ $failed -eq 0 ]]; then
            record_failure "$run_directory" "the adopted user device did not remain booted"
            failed=1
        fi
    fi

    write_entry_report "$run_directory" "$developer_dir" "$device_id" "$device_name" \
        "$runtime_id" "$workflow_host" "$probed_app" "$signature_verified" "$gatekeeper" \
        "$notarization_ticket" "$agent_workflow"
    [[ $failed -eq 0 ]]
}

overall_status=0
for index in "${!xcode_paths[@]}"; do
    if ! run_one_xcode "${xcode_paths[$index]}" "$((index + 1))"; then
        overall_status=1
    fi
done

python3 - "$output_root" <<'PYTHON'
import datetime
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
entries = []
for path in sorted(root.glob("*/entry.json")):
    entries.append(json.loads(path.read_text(encoding="utf-8")))
outcome = "passed" if entries and all(e.get("outcome") == "passed" for e in entries) else "failed"
report = {
    "schema_version": 1,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "outcome": outcome,
    "entries": entries,
}
(root / "matrix.json").write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PYTHON

say "Compatibility evidence: $output_root/matrix.json"
if [[ $overall_status -ne 0 ]]; then
    fail "one or more Simulator dogfood matrix entries failed"
fi
printf 'All Simulator dogfood matrix entries passed.\n'
