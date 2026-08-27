#!/usr/bin/env bash
#
# One reproducible, non-interactive quality gate for CI and release preflight.
#
# The app has no root Package.swift, so "swift test" alone silently omits the product. Test the
# six local protocol/runtime/test-contract packages explicitly, then run the app's off-screen
# Xcode plan. Application-level UI scenarios stay in their separate GUI lane.
set -euo pipefail

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

for package in ThreadingExtensionKit ThreadingRemoteKit ThreadingWasmRuntime ThreadingScenarioKit ThreadingPeerTransport ThreadingSimulatorKit; do
    say "Testing ${package}"
    swift test --package-path "${repository_directory}/Packages/${package}"
done

say "Checking generated component inventory"
swift run \
    --package-path "${repository_directory}/Packages/ThreadingExtensionKit" \
    ThreadingComponentCatalogGenerator \
    --check \
    "${repository_directory}/docs/extensions/generated"

say "Validating recorded agent scenarios"
"${script_directory}/check_agent_scenarios.sh"

say "Testing UI evidence tooling"
python3 -m unittest "${repository_directory}/scripts/tests/test_ui_evidence_tools.py"

say "Testing connectivity evidence tooling"
python3 -m unittest "${repository_directory}/scripts/tests/test_connectivity_diagnostics.py"

say "Testing generated diagnostic contract"
python3 -m unittest "${repository_directory}/scripts/tests/test_generate_diagnostic_contract.py"

say "Testing mobile report intake configuration"
python3 -m unittest "${repository_directory}/scripts/tests/test_mobile_report_intake_configuration.py"

say "Testing mobile test gate configuration"
python3 -m unittest "${repository_directory}/scripts/tests/test_mobile_test_gate.py"

say "Testing Swift warning ratchet"
python3 -m unittest "${repository_directory}/scripts/tests/test_swift_warning_ratchet.py"

say "Testing agent feedback audit"
python3 "${repository_directory}/scripts/tests/test_agent_feedback_audit.py"

say "Testing release tag policy"
python3 -m unittest "${repository_directory}/scripts/tests/test_release_tag_policy.py"

say "Installing ThreadingControlPlane test dependencies"
npm --prefix "${repository_directory}/Service/ThreadingControlPlane" ci

say "Testing ThreadingControlPlane"
npm --prefix "${repository_directory}/Service/ThreadingControlPlane" test

say "Testing Threading (off-screen plan, complete concurrency checking)"
capture_swift_warnings mac-tests "${script_directory}/test.sh" fast \
    -derivedDataPath "${ci_derived_data}" \
    SWIFT_STRICT_CONCURRENCY=complete \
    COMPILER_INDEX_STORE_ENABLE=NO

say "Checking Swift warning ceilings"
python3 "${script_directory}/check_swift_warning_ratchet.py" \
    --root "${repository_directory}" \
    "${swift_warning_logs[@]}"
