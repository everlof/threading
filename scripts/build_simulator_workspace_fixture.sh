#!/usr/bin/env bash
# Public UIKit guest fixture for the opt-in multi-device live verification lane.
set -euo pipefail
repository_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_directory="${repository_directory}/Tests/Fixtures/SimulatorWorkspace"
application_directory="${repository_directory}/.build/simulator-workspace-live/WorkspaceFixture.app"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "${application_directory}"
xcrun --sdk iphonesimulator swiftc -parse-as-library -module-name WorkspaceFixture \
    -target arm64-apple-ios17.0-simulator -sdk "${sdk_path}" \
    "${fixture_directory}/WorkspaceFixture.swift" \
    -o "${application_directory}/WorkspaceFixture"
cp "${fixture_directory}/Info.plist" "${application_directory}/Info.plist"
codesign --force --sign - "${application_directory}"
printf '%s\n' "${application_directory}"
