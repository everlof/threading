#!/bin/bash
# Portable source build, owned by the Xcode application build graph; never downloads sources.
set -euo pipefail
proxy_source="${SRCROOT}/Targets/ProxyHost"
proxy_build="${DERIVED_FILE_DIR}/ProxyHost"
proxy_helpers="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
proxy_resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/ProxySource"
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
mkdir -p "$proxy_helpers" "$proxy_resources"
cp "$proxy_build/threading-proxyd" "$proxy_helpers/threading-proxyd"
chmod 755 "$proxy_helpers/threading-proxyd"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  proxy_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  proxy_entitlements="${SRCROOT}/Targets/ProxyHost/threading-proxyd.entitlements"
  if [[ "$proxy_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - --options runtime --entitlements "$proxy_entitlements" "$proxy_helpers/threading-proxyd"
  else
    /usr/bin/codesign --force --sign "$proxy_identity" --options runtime --timestamp --entitlements "$proxy_entitlements" "$proxy_helpers/threading-proxyd"
  fi
fi
# Full corresponding source, archives, original notices and rebuild instructions travel with it.
/usr/bin/rsync -a --delete --exclude __pycache__ --exclude .build --exclude build \
  "$proxy_source/" "$proxy_resources/"
