#!/usr/bin/env bash
# Capture the real Usage → Totals sheet. Called by profile_threading.sh after its optimized build.
set -euo pipefail
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_directory}/coresimulator_lane_lock.sh"
app="$1"
output="$2"
seconds="${3:-8}"
days="${4:-30}"
device="$5"
theme="${6:-neo-brutalism}"
mode="${7:-programmatic}"
[[ "$mode" == programmatic || "$mode" == native ]] || exit 2
[[ "$seconds" =~ ^[0-9]+$ && "$seconds" -ge 2 && "$seconds" -le 120 ]] || exit 2
native=0
if [[ "$mode" == native ]]; then
    native=1
    [[ "$seconds" -ge 20 ]] || { echo 'Native swipes require at least 20 seconds' >&2; exit 2; }
    command -v idb >/dev/null
fi
[[ "$days" == 7 || "$days" == 30 || "$days" == 90 ]] || exit 2
threading_acquire_coresimulator_lane ios-usage-scroll
mkdir -p "$output"
xcrun simctl install "$device" "$app"
container="$(xcrun simctl get_app_container "$device" codes.threading.mobile data)"
metrics="${container}/tmp/threading-usage-scroll-performance.log"
launch_fixture() {
    SIMCTL_CHILD_THREADING_MOBILE_DEMO=usage-totals \
    SIMCTL_CHILD_THREADING_MOBILE_THEME="$theme" \
    SIMCTL_CHILD_THREADING_MOBILE_USAGE_SCROLL_SECONDS="$seconds" \
    SIMCTL_CHILD_THREADING_MOBILE_USAGE_SCROLL_DAYS="$days" \
    SIMCTL_CHILD_THREADING_MOBILE_USAGE_SCROLL_NATIVE="$native" \
        xcrun simctl launch --terminate-running-process "$device" codes.threading.mobile
}
drive_swipes() {
    [[ "$mode" == native ]] || return 0
    sleep 3
    for pass in 1 2 3 4; do
        idb ui swipe --udid "$device" --duration 0.7 200 730 200 350
        idb ui swipe --udid "$device" --duration 0.7 200 350 200 730
    done
}
# Keep the timing passes separate from sampling overhead. Preserve every raw result.
for run in 1 2 3; do
    rm -f "$metrics"
    launch_fixture
    drive_swipes
    for ((poll = 0; poll < (seconds + 15) * 10; poll += 1)); do
        [[ -s "$metrics" ]] && break
        sleep 0.1
    done
    [[ -s "$metrics" ]] || { echo 'Usage scroll fixture produced no metric' >&2; exit 1; }
    cp "$metrics" "${output}/run-${run}.metrics.log"
    cat "$metrics"
    python3 - "$metrics" "$mode" <<'PY'
import sys
values = dict(part.split('=', 1) for part in open(sys.argv[1]).read().split() if '=' in part)
assert int(values['frames']) >= 10, values
if sys.argv[2] == 'native':
    assert int(values['tracking_frames']) >= 60, values
assert int(values['travel_pt']) > 100, values
assert float(values['final_top_error']) < 1, values
PY
done
rm -f "$metrics"
launch_result="$(launch_fixture)"
pid="${launch_result##*: }"
[[ "$pid" =~ ^[0-9]+$ ]] || exit 1
drive_swipes &
swipe_pid=$!
sleep 2
/usr/bin/sample "$pid" "$seconds" 1 -file "${output}/usage-scroll.sample.txt"
wait "$swipe_pid"
for ((poll = 0; poll < 150; poll += 1)); do
    [[ -s "$metrics" ]] && break
    sleep 0.1
done
[[ -s "$metrics" ]] || exit 1
# Let the final scroll transaction reach the display before capturing the shell.
sleep 1
xcrun simctl io "$device" screenshot "${output}/usage-totals.png"
printf 'Usage scroll artifacts: %s\n' "$output"
