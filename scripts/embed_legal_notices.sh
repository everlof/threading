#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(dirname "$script_directory")"

: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR must be set by Xcode}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?UNLOCALIZED_RESOURCES_FOLDER_PATH must be set by Xcode}"
: "${BUILD_DIR:?BUILD_DIR must be set by Xcode}"

if [[ "${PLATFORM_NAME:-macosx}" == "macosx" ]]; then
    profile="macos"
else
    profile="ios"
fi

legal_directory="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Legal"
if [[ -n "${THREADING_SOURCE_PACKAGES_DIR:-}" ]]; then
    package_checkouts="$THREADING_SOURCE_PACKAGES_DIR"
else
    # A normal build uses <DerivedData>/Build/Products, while an archive moves BUILD_DIR down
    # into Build/Intermediates.noindex/ArchiveIntermediates/…. Strip the stable /Build/ suffix
    # rather than counting parents, which is necessarily wrong for one of those two layouts.
    derived_data_directory="${BUILD_DIR%%/Build/*}"
    if [[ -z "$derived_data_directory" || "$derived_data_directory" == "$BUILD_DIR" ]]; then
        echo "error: cannot resolve DerivedData from BUILD_DIR: $BUILD_DIR" >&2
        exit 1
    fi
    package_checkouts="$derived_data_directory/SourcePackages/checkouts"
fi

copy_notice() {
    local source_path="$1"
    local destination_name="$2"

    if [[ ! -s "$source_path" ]]; then
        echo "error: required legal notice is missing or empty: $source_path" >&2
        exit 1
    fi

    # `install` creates an undeclared `INS@…` sibling before renaming it. Xcode's user-script
    # sandbox correctly rejects that extra output even when the final notice is in the phase's
    # output file list. Copy directly to the declared path, then normalize its mode.
    /bin/cp "$source_path" "$legal_directory/$destination_name"
    /bin/chmod 0644 "$legal_directory/$destination_name"
}

/bin/mkdir -p "$legal_directory"

copy_notice "$repository_root/LICENSE" "Threading-GPL-3.0.txt"
copy_notice "$repository_root/Legal/THIRD_PARTY_NOTICES.md" "THIRD_PARTY_NOTICES.md"
copy_notice "$repository_root/Packages/Vendor/SwiftTerm/LICENSE" "SwiftTerm-MIT.txt"
copy_notice "$package_checkouts/NativeDiffKit/LICENSE" "NativeDiffKit-MIT.txt"
copy_notice "$package_checkouts/WebRTC/LICENSE.md" "WebRTC-BSD-3-Clause.txt"

font_root="$repository_root/Sources/Threading/Resources/Fonts"
copy_notice "$font_root/W95FA/W95FA-OFL.txt" "W95FA-OFL-1.1.txt"
copy_notice "$font_root/W95FA/W95FA-SOURCE.md" "W95FA-SOURCE.md"
copy_notice "$font_root/PlatinumBitmap/PlatinumBitmap-OFL.txt" "PlatinumBitmap-OFL-1.1.txt"
copy_notice "$font_root/PlatinumBitmap/PlatinumBitmap-SOURCE.md" "PlatinumBitmap-SOURCE.md"
copy_notice "$font_root/Topaz/Topaz-GPL-2.0.txt" "Topaz-GPL-2.0.txt"
copy_notice "$font_root/Topaz/Topaz-FONT-EXCEPTION.txt" "Topaz-FONT-EXCEPTION.txt"
copy_notice "$font_root/Topaz/Topaz-UPSTREAM-README.txt" "Topaz-UPSTREAM-README.txt"
copy_notice "$font_root/Topaz/Topaz-SOURCE.md" "Topaz-SOURCE.md"

if [[ "$profile" == "macos" ]]; then
    copy_notice "$repository_root/ThirdParty/scc/LICENSE" "scc-MIT.txt"
    copy_notice "$repository_root/Packages/Vendor/BorderBeamKit/LICENSE" "BorderBeamKit-MIT.txt"
    copy_notice "$repository_root/Packages/Vendor/LabelMorph/LICENSE" "LabelMorph-MIT.txt"
    copy_notice "$repository_root/Packages/Vendor/ThinkingOrbs/LICENSE" "ThinkingOrbs-MIT.txt"
    copy_notice "$package_checkouts/Sparkle/LICENSE" "Sparkle-LICENSE.txt"
    copy_notice "$package_checkouts/Sparkle/Vendor/ed25519-sparkle/license.txt" "Sparkle-ed25519-LICENSE.txt"
    copy_notice "$package_checkouts/WasmKit/LICENSE" "WasmKit-MIT.txt"
    copy_notice "$package_checkouts/WasmKit/NOTICE.txt" "WasmKit-NOTICE.txt"
    copy_notice "$package_checkouts/swift-system/LICENSE.txt" "swift-system-LICENSE.txt"
    copy_notice "$package_checkouts/swift-argument-parser/LICENSE.txt" "swift-argument-parser-LICENSE.txt"
fi

"$repository_root/scripts/check_bundled_licenses.sh" "$profile" "$legal_directory"
