#!/usr/bin/env bash
#
# One reproducible, non-interactive quality gate for CI and release preflight.
#
# The app has no root Package.swift, so "swift test" alone silently omits the product. Test the
# five local protocol/runtime/test-contract packages explicitly, then run the app's off-screen
# Xcode plan. Application-level UI scenarios stay in their separate GUI lane.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

say() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

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

for package in ThreadingExtensionKit ThreadingRemoteKit ThreadingWasmRuntime ThreadingScenarioKit ThreadingPeerTransport; do
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

say "Testing agent feedback audit"
python3 "${repository_directory}/scripts/tests/test_agent_feedback_audit.py"

say "Testing Threading (off-screen plan, complete concurrency checking)"
"${script_directory}/test.sh" fast \
    SWIFT_STRICT_CONCURRENCY=complete \
    COMPILER_INDEX_STORE_ENABLE=NO
