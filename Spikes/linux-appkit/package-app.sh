#!/usr/bin/env bash
# Build a source-tree-independent preview for the Ubuntu Noble arm64 validation target.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 || $(uname -m) != aarch64 ]]; then
  echo 'package-app: build inside Ubuntu 24.04 arm64 (swift:6.3.2-noble)' >&2
  exit 1
fi

./vendor-core.sh --verify
if [[ -n ${THREADING_LINUX_SOURCE_REVISION:-} || -n ${THREADING_LINUX_SOURCE_DIRTY:-} ]]; then
  revision=${THREADING_LINUX_SOURCE_REVISION:-}
  dirty=${THREADING_LINUX_SOURCE_DIRTY:-}
else
  revision=$(git rev-parse HEAD) || { echo 'package-app: source revision unavailable' >&2; exit 1; }
  status=$(git status --porcelain) || { echo 'package-app: source status unavailable' >&2; exit 1; }
  dirty=$([[ -z $status ]] && echo false || echo true)
fi
if [[ ! $revision =~ ^[0-9a-f]{40,64}$ || ( $dirty != true && $dirty != false ) ]]; then
  echo 'package-app: valid source revision and dirty status are required' >&2
  exit 1
fi
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product WindowHarness
swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --product LinuxHost
swift build --package-path ../../Targets/PTYHost -c release --static-swift-stdlib \
  --product threading-ptyd

bin_dir=$(swift build -c release --static-swift-stdlib -Xswiftc -enable-testing --show-bin-path)
daemon_dir=$(swift build --package-path ../../Targets/PTYHost -c release \
  --static-swift-stdlib --show-bin-path)
name=threading-linux-preview-ubuntu24.04-arm64
mkdir -p out
staging=$(mktemp -d "$PWD/out/.bundle.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
bundle=$staging/$name
mkdir -p "$bundle/bin"
install -m 0755 run-app.sh "$bundle/run-app.sh"
install -m 0755 "$bin_dir/WindowHarness" "$bundle/bin/WindowHarness"
install -m 0755 "$bin_dir/LinuxHost" "$bundle/bin/LinuxHost"
install -m 0755 "$daemon_dir/threading-ptyd" "$bundle/bin/threading-ptyd"
install -m 0644 BUNDLE_README.md "$bundle/README.md"
cat > "$bundle/BUNDLE-MANIFEST" <<EOF
format=threading-linux-preview-1
target=ubuntu-24.04-aarch64
source_revision=$revision
source_dirty=$dirty
EOF

output=$PWD/out/$name
rm -rf -- "$output"
mv -- "$bundle" "$output"
tar -C out -czf "out/$name.tar.gz" "$name"

# Keep the launcher beside its binaries: run-app.sh resolves them from BASH_SOURCE.
package=threading-linux-preview
version=0.0.1+git${revision:0:12}
package_root=$staging/package-root
installed_bundle=$package_root/opt/$package
mkdir -p "$installed_bundle" "$package_root/DEBIAN" \
  "$package_root/usr/share/applications" "$package_root/usr/share/icons/hicolor/1024x1024/apps"
cp -a "$output/." "$installed_bundle/"
install -m 0644 ../../Brand/ThreadingMark-1024.png \
  "$package_root/usr/share/icons/hicolor/1024x1024/apps/$package.png"
cat > "$package_root/usr/share/applications/$package.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Threading Linux Preview
Comment=Local project and terminal workspace
Exec=/opt/$package/run-app.sh
Icon=$package
Terminal=false
Categories=Development;
EOF
cat > "$package_root/DEBIAN/control" <<EOF
Package: $package
Version: $version
Section: devel
Priority: optional
Architecture: arm64
Depends: libsqlite3-0, libsdl2-2.0-0, libpangocairo-1.0-0, libatk-bridge2.0-0t64, zenity, fonts-dejavu-core, util-linux
Maintainer: David Everlöf <support@mjukis.dev>
Description: Experimental native Linux host for Threading
 Local projects, terminals and coding-agent sessions in a desktop window.
 This preview currently targets Ubuntu 24.04 arm64.
EOF
deb=$PWD/out/$package-ubuntu24.04-arm64.deb
dpkg-deb --root-owner-group --build "$package_root" "$deb"
echo "package-app: $output"
echo "package-app: $PWD/out/$name.tar.gz"
echo "package-app: $deb"
