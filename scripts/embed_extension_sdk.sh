#!/bin/bash
set -euo pipefail

source_directory="${SRCROOT}/Packages/ThreadingExtensionKit"
destination_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExtensionSDK/ThreadingExtensionKit"
documentation_source_directory="${SRCROOT}/docs/extensions"
documentation_destination_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExtensionSDK/docs/extensions"
first_party_destination_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/FirstPartyExtensions"
storm_source_directory="${source_directory}/Examples/StormThemeExtension"
storm_destination_directory="${first_party_destination_directory}/codes.threading.storm.threadingextension"
empty_registration_module="${SRCROOT}/Tests/Fixtures/Extensions/registration.wasm"

/bin/mkdir -p "${destination_directory}"
/usr/bin/rsync -a --delete --delete-excluded \
  --exclude .build \
  --exclude build \
  --exclude Build \
  --exclude .git \
  --exclude .swiftpm \
  --exclude .DS_Store \
  "${source_directory}/" \
  "${destination_directory}/"

# Keep the SDK README's `../docs/extensions` links valid in the app bundle. The project
# scaffolder preserves this sibling layout under `Vendor/`, so generated projects and their
# retained package source remain fully authorable offline.
/bin/mkdir -p "${documentation_destination_directory}"
/usr/bin/rsync -a --delete \
  --exclude .DS_Store \
  "${documentation_source_directory}/" \
  "${documentation_destination_directory}/"

# The launch catalogue is app-owned and offline: its package resources are covered by the app's
# own code signature and Settings performs no repository discovery. Storm is data-plane only, so
# the tiny real WASI fixture writes its empty registration while the host reads the theme and icon
# directly from the package. The retained source remains the authored Swift implementation and
# includes the exact vendored SDK snapshot needed to rebuild it.
/usr/bin/rsync -a --delete \
  --exclude main.swift \
  --exclude Scripts \
  --exclude .DS_Store \
  "${storm_source_directory}/" \
  "${storm_destination_directory}/"
/bin/mkdir -p "${storm_destination_directory}/bin"
/bin/mkdir -p "${storm_destination_directory}/Source"
/bin/cp "${empty_registration_module}" "${storm_destination_directory}/bin/storm.wasm"
/usr/bin/rsync -a --delete --delete-excluded \
  --exclude .build \
  --exclude build \
  --exclude Build \
  --exclude .git \
  --exclude .swiftpm \
  --exclude .DS_Store \
  "${source_directory}/" \
  "${storm_destination_directory}/Source/"
