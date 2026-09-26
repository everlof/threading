#!/usr/bin/env bash
# Exercise the archive and installed package without source or a Swift toolchain.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq /preview.deb >/dev/null
apt-get install -y -qq xvfb xauth xdotool xclip imagemagick python3 \
  desktop-file-utils libgtk-3-bin dbus-x11 >/dev/null

if command -v swift >/dev/null; then
  echo 'bundle smoke: runtime unexpectedly has Swift' >&2
  exit 1
fi
installed=/opt/threading-linux-preview
desktop=/usr/share/applications/threading-linux-preview.desktop
desktop-file-validate "$desktop"
grep -Fxq "Exec=$installed/run-app.sh" "$desktop"
grep -Fxq 'Architecture: arm64' <(dpkg-deb --ctrl-tarfile /preview.deb | tar -xO ./control)
test -x "$installed/run-app.sh"
test -f /usr/share/icons/hicolor/1024x1024/apps/threading-linux-preview.png
dpkg-query -W -f='${Status}\n' threading-linux-preview | grep -Fxq 'install ok installed'
tar -xzf /archive.tar.gz -C /tmp
bundle=/tmp/threading-linux-preview-ubuntu24.04-arm64
grep -Eq '^source_revision=[0-9a-f]{40,64}$' "$bundle/BUNDLE-MANIFEST"
grep -Eq '^source_dirty=(true|false)$' "$bundle/BUNDLE-MANIFEST"
for executable in "$bundle/bin/WindowHarness" "$bundle/bin/LinuxHost" "$bundle/bin/threading-ptyd"; do
  if ldd "$executable" | grep -q 'not found'; then
    ldd "$executable" >&2
    exit 1
  fi
done

fixture=$(mktemp -d /tmp/threading-bundle.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p /evidence/out
ln -s /evidence/out /tmp/out
cd /tmp
xvfb-run -a python3 /test.py "$bundle/run-app.sh" "$bundle/bin/LinuxHost" \
  "$bundle/bin/threading-ptyd" "$bundle/bin" "$fixture" --bundled

useradd --create-home --shell /bin/bash threading-preview-test
mkdir -p /evidence/installed-out /evidence/desktop-out
chmod 0777 /evidence/installed-out /evidence/desktop-out
rm /tmp/out
ln -s /evidence/installed-out /tmp/out
installed_fixture=$(mktemp -d /tmp/threading-installed.XXXXXXXX)
chown threading-preview-test:threading-preview-test "$installed_fixture"
runuser -u threading-preview-test -- xvfb-run -a python3 /test.py \
  "$installed/run-app.sh" "$installed/bin/LinuxHost" \
  "$installed/bin/threading-ptyd" "$installed/bin" "$installed_fixture" --bundled
profile_db=$installed_fixture/startup-data/store/threading.db
before=$(sha256sum "$profile_db" | cut -d ' ' -f 1)
apt-get install --reinstall -y -qq /preview.deb >/dev/null
after=$(sha256sum "$profile_db" | cut -d ' ' -f 1)
test "$before" = "$after"
runuser -u threading-preview-test -- "$installed/bin/LinuxHost" \
  "$installed_fixture/startup-data/store" "$installed_fixture/startup-runtime/pty.sock" list \
  | grep -Fq "$installed_fixture/StartupProject"
runuser -u threading-preview-test -- xvfb-run -a dbus-run-session -- bash /desktop-test.sh
echo 'PASS installed package, desktop entry, native window and non-root startup'
