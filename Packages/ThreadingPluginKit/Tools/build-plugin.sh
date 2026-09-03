#!/usr/bin/env bash
# Builds a SwiftPM package into a loadable Threading plugin bundle.
#
#   build-plugin.sh <package-dir> --identifier <bundle-id> [--identity <codesign-identity>]
#                                 [--install] [--output <dir>]
#
# The contract in ThreadingPluginKit is not enough on its own to produce a bundle Threading will
# load. Three of the steps below are not guessable, and each one fails in a way that blames the
# wrong thing:
#
#   * the product is linked `-bundle`, not as a plain dylib;
#   * `NSPrincipalClass` names the @objc class, not the Swift type;
#   * the dependency's install name must be rewritten to the framework the host already has
#     loaded, or dyld maps a second copy of ThreadingPluginKit — and two @objc protocol
#     declarations in two images are two protocols, so the host refuses the plugin for not
#     conforming to a protocol it plainly conforms to.
#
# Signing defaults to ad-hoc. Threading accepts any valid signature, including ad-hoc, and then
# asks the user whether to run that particular build; a Developer ID is not a requirement to
# write a plugin, only a way for the person installing it to know who you are.
set -euo pipefail

package=""
identifier="${PLUGIN_IDENTIFIER:-}"
identity="${PLUGIN_IDENTITY:--}"
install=false
output=""

while [ $# -gt 0 ]; do
    case "$1" in
        --identifier) identifier="$2"; shift 2 ;;
        --identity)   identity="$2";   shift 2 ;;
        --output)     output="$2";     shift 2 ;;
        --install)    install=true;    shift ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *)  package="$1"; shift ;;
    esac
done

[ -n "${package}" ] || { echo "usage: build-plugin.sh <package-dir> --identifier <bundle-id>" >&2; exit 2; }
package="$(cd "${package}" && pwd)"
name="$(basename "${package}")"

if [ -z "${identifier}" ]; then
    echo "a bundle identifier is required: --identifier com.example.${name}" >&2
    echo "it is the name your approval is recorded against, so it has to be yours." >&2
    exit 2
fi

output="${output:-${package}/.build/bundle}"
bundle="${output}/${name}.bundle"
rm -rf "${output}"
mkdir -p "${bundle}/Contents/MacOS"

swift build --package-path "${package}" -c release
bin="$(swift build --package-path "${package}" -c release --show-bin-path)"
cp "${bin}/lib${name}.dylib" "${bundle}/Contents/MacOS/${name}"

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
    <key>CFBundleIdentifier</key><string>${identifier}</string>
    <key>CFBundleName</key><string>${name}</string>
    <key>CFBundleExecutable</key><string>${name}</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>NSPrincipalClass</key><string>${name}</string>
</dict>
</plist>
PLIST

codesign -s "${identity}" -f -o runtime --timestamp=none "${bundle}" >/dev/null
echo "built ${bundle}"
codesign -dv --verbose=2 "${bundle}" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" | sed 's/^/  /' || true

if [ "${install}" = true ]; then
    dest="${HOME}/Library/Application Support/Threading/Plugins"
    mkdir -p "${dest}"
    rm -rf "${dest}/${name}.bundle"
    cp -R "${bundle}" "${dest}/"
    echo "installed ${dest}/${name}.bundle"
    echo "Threading will ask before running it. Approving records this exact build."
fi
