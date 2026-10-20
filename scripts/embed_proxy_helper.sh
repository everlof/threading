#!/bin/bash
# Portable source build, owned by the first-party ProxyPlugin target; never downloads sources.
set -euo pipefail
: "${TARGET_NAME:?TARGET_NAME must be set by Xcode}"
if [[ "${TARGET_NAME}" != "ProxyPlugin" ]]; then
  echo "error: proxy payload must be built inside ProxyPlugin before it is signed" >&2
  exit 1
fi
proxy_source="${SRCROOT}/Targets/ProxyHost"
proxy_build="${DERIVED_FILE_DIR}/ProxyHost"
proxy_helpers="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
proxy_resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
proxy_tools="${proxy_resources}/ProxyTools"
proxy_legal="${proxy_resources}/Legal/ProxyHost"
proxy_cmake="$(command -v cmake || true)"
if [[ -z "$proxy_cmake" ]]; then
  for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
    if [[ -x "$candidate" ]]; then proxy_cmake="$candidate"; break; fi
  done
fi
if [[ -z "$proxy_cmake" ]]; then
  echo "error: CMake 3.25+ is required to build Threading's portable proxy helper." >&2
  exit 1
fi
"$proxy_cmake" -S "$proxy_source" -B "$proxy_build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DCMAKE_OSX_ARCHITECTURES="${ARCHS// /;}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
  -DCMAKE_OSX_SYSROOT="${SDKROOT}" -DCMAKE_C_COMPILER=/usr/bin/clang
"$proxy_cmake" --build "$proxy_build" --parallel 4
mkdir -p "$proxy_helpers" "$proxy_tools"
cp "$proxy_build/threading-proxyd" "$proxy_helpers/threading-proxyd"
chmod 755 "$proxy_helpers/threading-proxyd"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  proxy_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  proxy_entitlements="${SRCROOT}/Targets/ProxyHost/threading-proxyd.entitlements"
  if [[ "$proxy_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - --identifier codes.threading.proxyd --options runtime --entitlements "$proxy_entitlements" "$proxy_helpers/threading-proxyd"
  else
    /usr/bin/codesign --force --sign "$proxy_identity" --identifier codes.threading.proxyd --options runtime --timestamp --entitlements "$proxy_entitlements" "$proxy_helpers/threading-proxyd"
  fi
fi
# The one setup script the host names in its response. The helper's corresponding source is
# published beside the plugin archive (scripts/release.sh), with notices in both distributions.
cp "$proxy_source/tools/apple_certificate.py" "$proxy_tools/apple_certificate.py"
# This plugin is a separate download. Keep the binary's license notices in that archive too,
# even though the host app also indexes them for its licenses view.
mkdir -p "$proxy_legal"
cp "$proxy_source/LICENSE" "$proxy_legal/Threading-GPL-3.0.txt"
cp "$proxy_source/THIRD_PARTY_NOTICES.md" "$proxy_legal/THIRD_PARTY_NOTICES.md"
cp "$proxy_source/third_party/licenses/"* "$proxy_legal/"
