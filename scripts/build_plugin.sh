#!/usr/bin/env bash
# Builds a native plugin bundle and signs it with Threading's own team.
#
# Usage: scripts/build_plugin.sh <plugin-package-dir> [--install]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="${1:?usage: build_plugin.sh <plugin-package-dir> [--install]}"
package="$(cd "${package}" && pwd)"
name="$(basename "${package}")"
install=false
[ "${2:-}" = "--install" ] && install=true

# Threading is signed by this team, and NativePluginCatalog trusts it. A plugin signed by anything
# else is refused by the loader rather than by the operating system: the app carries
# `disable-library-validation`, so the allowlist is the whole policy.
identity="${THREADING_PLUGIN_IDENTITY:-Developer ID Application: MJUKIS AB (SMQ3E8Y57T)}"

out="${package}/.build/bundle"
bundle="${out}/${name}.bundle"
rm -rf "${out}"
mkdir -p "${bundle}/Contents/MacOS"

swift build --package-path "${package}" -c release
bin="$(swift build --package-path "${package}" -c release --show-bin-path)"
cp "${bin}/lib${name}.dylib" "${bundle}/Contents/MacOS/${name}"

# The host loads ThreadingPluginKit as an embedded *framework*; SwiftPM links the same code as a
# plain dylib, and the two install names do not match. dyld would then map a second copy, and two
# @objc protocol declarations in two images are two protocols — the loader would refuse the plugin
# for not conforming to the protocol it plainly conforms to. Point the dependency at the name the
# host already has loaded.
install_name_tool -change \
    "@rpath/libThreadingPluginKit.dylib" \
    "@rpath/ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit" \
    "${bundle}/Contents/MacOS/${name}" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${bundle}/Contents/MacOS/${name}" 2>/dev/null || true

cat > "${bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>codes.threading.plugin.$(echo "${name}" | tr '[:upper:]' '[:lower:]')</string>
    <key>CFBundleName</key><string>${name}</string>
    <key>CFBundleExecutable</key><string>${name}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>NSPrincipalClass</key><string>${name}</string>
</dict>
</plist>
PLIST

codesign -s "${identity}" -f -o runtime --timestamp=none "${bundle}" >/dev/null
echo "built ${bundle}"
codesign -dv --verbose=2 "${bundle}" 2>&1 | grep -E "TeamIdentifier|Signature" | sed 's/^/  /'

if [ "${install}" = true ]; then
    dest="${HOME}/Library/Application Support/Threading/Plugins"
    mkdir -p "${dest}"
    rm -rf "${dest}/${name}.bundle"
    cp -R "${bundle}" "${dest}/"
    echo "installed ${dest}/${name}.bundle"
fi
