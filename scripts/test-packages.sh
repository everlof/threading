#!/usr/bin/env bash
#
# Test every local Swift package that has its own test target, standalone, on this Mac.
#
#   scripts/test-packages.sh
#
# The app has no root Package.swift and its Xcode plans build one test target (ThreadingTests), so
# a package's own tests run in no lane unless they are named here. This is the one list: both
# scripts/ci.sh and the push gate (scripts/pre_push.sh) call it, so a package added to one is in
# the other.
#
# Not here, on purpose:
#   ThreadingController   — scripts/test-controller.sh, together with the real CLI and ptyd it drives;
#   ThreadingPTYClient    — no test target; compiled by Targets/Controller in test-controller.sh;
#   Packages/Vendor/*     — upstream packages with their own CI.
#
# Each package uses its default scratch directory (Packages/<name>/.build), so a second run compiles
# only what changed — which is what keeps this affordable in the push gate.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "${script_directory}/.." && pwd)"

readonly packages=(
    ThreadingDomain
    ThreadingPTYHostKit
    ThreadingExtensionKit
    ThreadingPluginKit
    ThreadingDesignKit
    ThreadingMarkdownKit
    ThreadingRemoteKit
    ThreadingGlanceKit
    ThreadingWasmRuntime
    ThreadingScenarioKit
    ThreadingPeerTransport
    ThreadingSimulatorKit
    ThreadingUsage
)

# The plugins are their own packages under a different root. The Xcode plans never run their tests;
# the app target compiles the same sources, so the warning ratchet covers them, but the assertions
# defending, for example, the device-log pane's behaviour ran only here.
readonly plugins=(
    DeviceLogsPlugin
    MarketeerPanelPlugin
)

for package in "${packages[@]}"; do
    printf '\n==> Testing %s\n' "${package}"
    swift test --package-path "${repository_directory}/Packages/${package}"
done

for plugin in "${plugins[@]}"; do
    printf '\n==> Testing %s\n' "${plugin}"
    swift test --package-path "${repository_directory}/Plugins/${plugin}"
done
