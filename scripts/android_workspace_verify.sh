#!/usr/bin/env bash
# Opt-in live lane for Android members of the Simulator workspace (docs/architecture/android-devices.md).
#
# Creates a dedicated `Threading_Verify_API36` AVD from an installed system image if it is missing,
# boots it read-only and headless with gRPC on, and runs the package and app live suites against it.
# It never starts, stops or edits any other AVD or running emulator, and it stops only the emulator
# it started. `--keep` leaves that emulator running for exploration; `--apk PATH --package ID` adds
# the install-and-launch case.
set -euo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
avd_home="${ANDROID_AVD_HOME:-${HOME}/.android/avd}"
avd="Threading_Verify_API36"
console_port=5580
grpc_port=8564
keep=0
apk=""
package=""
while (($#)); do
    case "$1" in
        --keep) keep=1; shift ;;
        --apk) apk="${2:?Provide a built .apk}"; shift 2 ;;
        --package) package="${2:?Provide the applicationId}"; shift 2 ;;
        --help|-h)
            printf '%s\n' 'Usage: scripts/android_workspace_verify.sh [--keep] [--apk PATH --package APPLICATION_ID]'
            exit 0 ;;
        *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done
adb="${sdk}/platform-tools/adb"
emulator="${sdk}/emulator/emulator"
[[ -x "${adb}" && -x "${emulator}" ]] || { printf 'error: no Android SDK with adb and the emulator at %s\n' "${sdk}" >&2; exit 2; }

if [[ ! -e "${avd_home}/${avd}.ini" ]]; then
    image="$(cd "${sdk}" && ls -d system-images/android-36/*/arm64-v8a 2>/dev/null | head -1)"
    [[ -n "${image}" ]] || { printf 'error: install an API 36 arm64-v8a system image first\n' >&2; exit 2; }
    mkdir -p "${avd_home}/${avd}.avd"
    printf 'avd.ini.encoding=UTF-8\npath=%s\npath.rel=avd/%s.avd\ntarget=android-36\n' \
        "${avd_home}/${avd}.avd" "${avd}" > "${avd_home}/${avd}.ini"
    cat > "${avd_home}/${avd}.avd/config.ini" <<EOF
AvdId=${avd}
avd.ini.displayname=Threading Verify API 36
abi.type=arm64-v8a
hw.cpu.arch=arm64
hw.cpu.ncore=2
hw.ramSize=2048
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=420
hw.keyboard=yes
hw.gpu.enabled=yes
hw.gpu.mode=auto
hw.accelerometer=yes
hw.sensors.orientation=yes
image.sysdir.1=${image}/
disk.dataPartition.size=2G
fastboot.forceColdBoot=yes
EOF
    printf 'Created %s from %s\n' "${avd}" "${image}"
fi

serial="emulator-${console_port}"
started_pid=""
if ! "${adb}" devices | grep -q "^${serial}[[:space:]]*device"; then
    log="${repository_directory}/.build/android-verify/emulator.log"
    mkdir -p "$(dirname "${log}")"
    "${emulator}" -avd "${avd}" -no-window -no-audio -no-boot-anim -read-only -no-snapshot \
        -ports "${console_port},$((console_port + 1))" -grpc "${grpc_port}" -grpc-use-jwt > "${log}" 2>&1 &
    started_pid=$!
    printf 'Booting %s (pid %s)…\n' "${avd}" "${started_pid}"
fi
cleanup() {
    if [[ -n "${started_pid}" && "${keep}" == 0 ]]; then
        "${adb}" -s "${serial}" emu kill >/dev/null 2>&1 || kill "${started_pid}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

deadline=$((SECONDS + 240))
until [[ "$("${adb}" -s "${serial}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    (( SECONDS < deadline )) || { printf 'error: %s did not boot in time\n' "${avd}" >&2; exit 1; }
    sleep 2
done
# The landscape case needs the guest to follow its rotation sensor; the AVD is read-only, so this
# lasts only for this boot.
"${adb}" -s "${serial}" shell settings put system accelerometer_rotation 1

export THREADING_ANDROID_LIVE_AVD="${avd}"
export THREADING_ANDROID_LIVE_APK="${apk}"
export THREADING_ANDROID_LIVE_PACKAGE="${package}"
cd "${repository_directory}"
swift test --package-path Packages/ThreadingAndroidKit --filter LiveEmulatorControlTests
scripts/test.sh fast -only-testing:ThreadingTests/AndroidLiveIntegrationTests
