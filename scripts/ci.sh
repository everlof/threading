#!/usr/bin/env bash
#
# One reproducible, non-interactive quality gate for CI and release preflight.
#
# The app has no root Package.swift, so "swift test" alone silently omits the product. Test the
# three local protocol/runtime packages explicitly, then run the app's off-screen Xcode plan.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

say() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

say "Checking repository boundaries"
"${script_directory}/check_architecture_boundaries.sh"
"${script_directory}/check_localization_boundaries.sh"
"${script_directory}/check_theme_boundaries.sh"

command -v swiftlint >/dev/null 2>&1 \
    || fail "swiftlint is required; install it with 'brew install swiftlint'"

say "Running SwiftLint policy"
swiftlint lint \
    --strict \
    --config "${repository_directory}/.swiftlint.yml" \
    "${repository_directory}/Sources"

for package in ThreadingExtensionKit ThreadingRemoteKit ThreadingWasmRuntime; do
    say "Testing ${package}"
    swift test --package-path "${repository_directory}/Packages/${package}"
done

say "Testing Threading (off-screen plan, complete concurrency checking)"
xcodebuild \
    -project "${repository_directory}/Threading.xcodeproj" \
    -scheme Threading \
    -testPlan Threading-Fast \
    -destination "platform=macOS" \
    SWIFT_STRICT_CONCURRENCY=complete \
    COMPILER_INDEX_STORE_ENABLE=NO \
    test
