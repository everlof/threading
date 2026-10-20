#!/bin/bash
# Incremental app builds can retain files from before the helper moved to ProxyPlugin.
set -euo pipefail
: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set by Xcode}"
: "${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH must be set by Xcode}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set by Xcode}"

app="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
rm -f "$app/Helpers/threading-proxyd" "$resources/ProxyTools/apple_certificate.py"
rm -rf "$resources/ProxySource"
rmdir "$resources/ProxyTools" 2>/dev/null || true
