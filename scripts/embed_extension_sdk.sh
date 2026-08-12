#!/bin/bash
set -euo pipefail

source_directory="${SRCROOT}/Packages/ThreadingExtensionKit"
destination_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExtensionSDK/ThreadingExtensionKit"
documentation_source_directory="${SRCROOT}/docs/extensions"
documentation_destination_directory="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ExtensionSDK/docs/extensions"

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
