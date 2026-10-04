#!/usr/bin/env bash
set -euo pipefail

# Standalone shipping path for the experimental Linux/macOS controller. The macOS app is
# still built only by Xcode; this target is not embedded in it yet.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
controller_scratch="${1:?usage: scripts/test-controller.sh ABSOLUTE_SCRATCH_DIRECTORY}"
case "$controller_scratch" in /*) ;; *) echo 'scratch directory must be absolute' >&2; exit 2 ;; esac
if [[ "$(uname -s)" == Linux ]]; then
    swift build --build-tests --package-path "$repo_root/Packages/ThreadingController" --scratch-path "$controller_scratch/tests"
    bash "$repo_root/scripts/linux/xctest-watchdog.sh" "$controller_scratch/tests/debug/ThreadingControllerPackageTests.xctest"
    swift test --skip-build --disable-xctest --package-path "$repo_root/Packages/ThreadingController" --scratch-path "$controller_scratch/tests"
else
    swift test --package-path "$repo_root/Packages/ThreadingController" --scratch-path "$controller_scratch/tests"
fi
swift test --package-path "$repo_root/Targets/Controller" --scratch-path "$controller_scratch/cli" --disable-xctest
python3 "$repo_root/scripts/tests/test_controller_cli.py" "$controller_scratch/cli/debug/threading-controller"
python3 "$repo_root/scripts/tests/test_controller_automations.py" "$controller_scratch/cli/debug/threading-controller"
swift build --package-path "$repo_root/Targets/PTYHost" --scratch-path "$controller_scratch/ptyd"
python3 "$repo_root/scripts/tests/test_controller_runtime.py" \
    "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"
python3 "$repo_root/scripts/tests/test_controller_recovery.py" \
    "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"
python3 "$repo_root/scripts/tests/test_controller_broker.py" \
    "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"
# Agents under their own Unix user: needs root to create the two accounts, so it runs in the
# Linux container (CI's controller-linux job) and is skipped, saying so, anywhere else.
if [[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]]; then
    python3 "$repo_root/scripts/tests/test_controller_agent_user.py" \
        "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"
else
    echo 'test_controller_agent_user.py: skipped (needs Linux as root, e.g. the controller-linux container)'
fi
python3 "$repo_root/scripts/tests/test_controller_mail.py" \
    "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"
python3 "$repo_root/scripts/tests/test_controller_sources.py" "$controller_scratch/cli/debug/threading-controller"
python3 "$repo_root/scripts/tests/test_controller_usage.py" \
    "$controller_scratch/cli/debug/threading-controller" "$controller_scratch/ptyd/debug/threading-ptyd"

python3 "$repo_root/scripts/tests/test_controller_host.py" "$controller_scratch/cli/debug/threading-controller"
