#!/usr/bin/env bash
# Builds the native-plugin-tier probe: the real ThreadingPluginKit package, one host app, and one
# loadable plugin bundle. Nothing here is part of Threading.xcodeproj. See README.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="${root}/../../Packages/ThreadingPluginKit"
out="${root}/build"
rm -rf "${out}"
mkdir -p "${out}/LogStreamPlugin.bundle/Contents/MacOS"

# 1. The contract, built as the real package rather than a copy compiled into each side.
#
# The probe first compiled the same protocol source into both host and plugin. The loader then
# correctly refused with "principal class does not conform": two @objc protocol declarations in two
# binaries are two protocols. One shared, linked framework is the mechanism, not a convenience.
swift build --package-path "${kit}" -c release
kitbuild="$(swift build --package-path "${kit}" -c release --show-bin-path)"
cp "${kitbuild}/libThreadingPluginKit.dylib" "${out}/"

modules="${kitbuild}/Modules"
[ -d "${modules}" ] || modules="${kitbuild}"

# 2. The plugin bundle, linked against the shared contract.
swiftc -O \
    -module-name LogStreamPlugin \
    -I "${modules}" -L "${out}" -lThreadingPluginKit \
    -Xlinker -bundle \
    -Xlinker -rpath -Xlinker "${out}" \
    -o "${out}/LogStreamPlugin.bundle/Contents/MacOS/LogStreamPlugin" \
    "${root}/Plugin/LogStreamPlugin.swift"

cat > "${out}/LogStreamPlugin.bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>codes.threading.probe.logstream</string>
    <key>CFBundleName</key><string>LogStreamPlugin</string>
    <key>CFBundleExecutable</key><string>LogStreamPlugin</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>NSPrincipalClass</key><string>LogStreamPlugin</string>
</dict>
</plist>
PLIST

# 3. The host, signed the way Threading is: hardened runtime, no library validation.
swiftc -O \
    -module-name ProbeHost \
    -I "${modules}" -L "${out}" -lThreadingPluginKit \
    -Xlinker -rpath -Xlinker "${out}" \
    -o "${out}/probe-host" \
    "${root}/Host/main.swift"

for artifact in libThreadingPluginKit.dylib LogStreamPlugin.bundle probe-host; do
    codesign -s - -f -o runtime "${out}/${artifact}" >/dev/null 2>&1 || true
done

echo "built:"
echo "  ${out}/probe-host"
echo "  ${out}/LogStreamPlugin.bundle"
