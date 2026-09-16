#!/usr/bin/env bash
#
# One reproducible, non-interactive quality gate for CI and release preflight.
#
# The app has no root Package.swift, so "swift test" alone silently omits the product. Test the
# six local protocol/runtime/test-contract packages explicitly, then run the app's off-screen
# Xcode plan. Application-level UI scenarios stay in their separate GUI lane.
#
# `--mac-release` is the direct-distribution lane. Threading's downloadable artifact is the Mac
# app, and release builds force Remote Access off; the companion is neither embedded nor
# published. This mode therefore keeps every repository, package, service and Mac shipping gate
# while omitting only the ThreadingMobile build and test lanes. Ordinary CI remains the superset.
set -euo pipefail

include_mobile=1
case "${1:-}" in
    "") ;;
    --mac-release) include_mobile=0 ;;
    *) printf 'error: usage: scripts/ci.sh [--mac-release]\n' >&2; exit 1 ;;
esac

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"
ci_scratch="$(mktemp -d "${TMPDIR:-/tmp}/threading-ci.XXXXXX")"
ci_derived_data="${ci_scratch}/DerivedData"
swift_warning_logs=()

cleanup() {
    if [[ -d "${ci_scratch}" ]]; then
        find "${ci_scratch}" -depth -delete
    fi
}
trap cleanup EXIT

say() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

capture_swift_warnings() {
    local lane_name="$1"
    shift
    local log_path="${ci_scratch}/${lane_name}.log"
    swift_warning_logs+=("${log_path}")
    "$@" 2>&1 | tee "${log_path}"
}

say "Checking repository boundaries"
"${script_directory}/check_architecture_boundaries.sh"
"${script_directory}/check_localization_boundaries.sh"
"${script_directory}/check_theme_boundaries.sh"
"${script_directory}/check_bundled_scc.sh"

say "Scanning history for secrets"
"${script_directory}/check_secrets.sh"

say "Checking Debug entitlements"
debug_entitlements="${repository_directory}/Sources/Threading/Resources/Threading-Debug.entitlements"
if /usr/libexec/PlistBuddy -c Print "${debug_entitlements}" \
    | rg --quiet '^[[:space:]]*com\.apple\.developer\.'; then
    fail "Debug entitlements contain a restricted com.apple.developer.* key; ad-hoc builds cannot launch"
fi

command -v swiftlint >/dev/null 2>&1 \
    || fail "swiftlint is required; install it with 'brew install swiftlint'"

say "Running SwiftLint policy"
swiftlint lint \
    --strict \
    --config "${repository_directory}/.swiftlint.yml" \
    "${repository_directory}/Sources"

if [[ "${include_mobile}" == "1" ]]; then
    say "Building ThreadingMobile (generic iOS Simulator)"
    capture_swift_warnings mobile-build xcodebuild \
        -project "${repository_directory}/Threading.xcodeproj" \
        -scheme ThreadingMobile \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${ci_derived_data}" \
        build \
        SWIFT_STRICT_CONCURRENCY=complete \
        COMPILER_INDEX_STORE_ENABLE=NO

    say "Testing ThreadingMobile (complete iOS Simulator target)"
    capture_swift_warnings mobile-tests "${script_directory}/test-mobile.sh" \
        -derivedDataPath "${ci_derived_data}" \
        SWIFT_STRICT_CONCURRENCY=complete \
        COMPILER_INDEX_STORE_ENABLE=NO
else
    say "Skipping the unshipped ThreadingMobile lane for the Mac release"
fi

for package in ThreadingExtensionKit ThreadingPluginKit ThreadingRemoteKit ThreadingGlanceKit ThreadingWasmRuntime ThreadingScenarioKit ThreadingPeerTransport ThreadingSimulatorKit; do
    say "Testing ${package}"
    swift test --package-path "${repository_directory}/Packages/${package}"
done

# The plugins are their own packages under a different root, and until now their tests ran in no
# lane at all: the Xcode plans build one target (ThreadingTests), and the loop above only walks
# Packages/. Every test defending the device-log pane's behaviour was therefore only ever run by
# hand. The app target does compile these same sources, so the warning ratchet already covered
# them — it was the assertions that nothing ran.
for plugin in DeviceLogsPlugin MarketeerPanelPlugin; do
    say "Testing ${plugin}"
    swift test --package-path "${repository_directory}/Plugins/${plugin}"
done

say "Checking generated component inventory"
swift run \
    --package-path "${repository_directory}/Packages/ThreadingExtensionKit" \
    ThreadingComponentCatalogGenerator \
    --check \
    "${repository_directory}/docs/extensions/generated"

say "Validating recorded agent scenarios"
"${script_directory}/check_agent_scenarios.sh"

say "Testing localization boundary tooling"
python3 -m unittest "${repository_directory}/scripts/tests/test_localization_boundary_lint.py"

say "Testing public extension schemas"
python3 "${repository_directory}/scripts/tests/test_workspace_navigator_schema.py"
python3 "${repository_directory}/scripts/tests/test_source_control_schema.py"

say "Testing UI evidence tooling"
python3 "${repository_directory}/scripts/tests/test_ui_evidence_tools.py"

say "Testing the development launcher"
python3 "${repository_directory}/scripts/tests/test_dev_launcher.py"

say "Testing connectivity evidence tooling"
python3 "${repository_directory}/scripts/tests/test_connectivity_diagnostics.py"

say "Testing generated diagnostic contract"
python3 "${repository_directory}/scripts/tests/test_generate_diagnostic_contract.py"

say "Testing mobile report intake configuration"
python3 "${repository_directory}/scripts/tests/test_mobile_report_intake_configuration.py"

say "Testing strict concurrency configuration"
python3 "${repository_directory}/scripts/tests/test_strict_concurrency_configuration.py"

say "Testing mobile test gate configuration"
python3 "${repository_directory}/scripts/tests/test_mobile_test_gate.py"

say "Testing Swift warning ratchet"
python3 "${repository_directory}/scripts/tests/test_swift_warning_ratchet.py"

say "Testing bundle entitlement verification"
python3 "${repository_directory}/scripts/tests/test_bundle_entitlements.py"

say "Testing agent feedback audit"
python3 "${repository_directory}/scripts/tests/test_agent_feedback_audit.py"

say "Testing release tag policy"
python3 "${repository_directory}/scripts/tests/test_release_tag_policy.py"

say "Testing the local release driver"
python3 "${repository_directory}/scripts/tests/test_local_release_driver.py"
python3 "${repository_directory}/scripts/tests/test_local_release_credentials.py"

say "Installing ThreadingControlPlane test dependencies"
npm --prefix "${repository_directory}/Service/ThreadingControlPlane" ci

say "Testing ThreadingControlPlane"
npm --prefix "${repository_directory}/Service/ThreadingControlPlane" test

mac_test_level=fast
if [[ "${include_mobile}" == "0" ]]; then
    mac_test_level=mac-all
fi
say "Testing Threading (${mac_test_level}, complete concurrency checking)"
capture_swift_warnings mac-tests "${script_directory}/test.sh" "${mac_test_level}" \
    -derivedDataPath "${ci_derived_data}" \
    SWIFT_STRICT_CONCURRENCY=complete \
    COMPILER_INDEX_STORE_ENABLE=NO

say "Checking Swift warning ceilings"
python3 "${script_directory}/check_swift_warning_ratchet.py" \
    --root "${repository_directory}" \
    "${swift_warning_logs[@]}"
