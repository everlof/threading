#!/usr/bin/env bash
# Exercise the archive and installed package without source or a Swift toolchain.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq /preview.deb >/dev/null
apt-get install -y -qq xvfb xauth xdotool xclip imagemagick python3 \
  desktop-file-utils libgtk-3-bin dbus-x11 python3-gi gir1.2-atspi-2.0 >/dev/null

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
installed_fixture=''
upgrade_fixture=''
upgrade_runner=''
restart_fixture=''
cleanup() {
  if [[ -n $upgrade_runner ]]; then kill "$upgrade_runner" 2>/dev/null || true; fi
  rm -rf -- "$fixture"
  if [[ -n $installed_fixture ]]; then rm -rf -- "$installed_fixture"; fi
  if [[ -n $upgrade_fixture ]]; then rm -rf -- "$upgrade_fixture"; fi
  if [[ -n $restart_fixture ]]; then rm -rf -- "$restart_fixture"; fi
}
trap cleanup EXIT
mkdir -p /evidence/out
ln -s /evidence/out /tmp/out
cd /tmp
xvfb-run -a python3 /test.py "$bundle/run-app.sh" "$bundle/bin/LinuxHost" \
  "$bundle/bin/threading-ptyd" "$bundle/bin" "$fixture" --bundled

useradd --create-home --shell /bin/bash threading-preview-test
runuser -u threading-preview-test -- env THREADING_LINUX_APP_DIR="$installed" \
  bash /provider-path-test.sh
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
runuser -u threading-preview-test -- "$installed/bin/LinuxHost" \
  "$installed_fixture/startup-data/store" "$installed_fixture/startup-runtime/pty.sock" list \
  | grep -Fq "$installed_fixture/StartupProject"

# The first smoke closes its daemon. This fixture holds an actual child across dpkg's replacement
# and then reopens the installed launcher, proving the process survives and can be reattached.
upgrade_fixture=$(mktemp -d /tmp/threading-upgrade.XXXXXXXX)
chown threading-preview-test:threading-preview-test "$upgrade_fixture"
rm /tmp/out
ln -s /evidence/installed-out /tmp/out
runuser -u threading-preview-test -- xvfb-run -a python3 /live-reinstall-test.py \
  "$installed/run-app.sh" "$installed/bin/threading-ptyd" "$upgrade_fixture" \
  "$installed/BUNDLE-MANIFEST" &
upgrade_runner=$!
ready=0
for ((attempt=0; attempt<250; attempt++)); do
  if [[ -f $upgrade_fixture/ready ]]; then ready=1; break; fi
  if ! kill -0 "$upgrade_runner" 2>/dev/null; then break; fi
  sleep .1
done
if [[ $ready != 1 ]]; then
  echo 'bundle smoke: live child did not become ready for reinstall' >&2
  wait "$upgrade_runner" || true
  exit 1
fi
upgrade_db=$upgrade_fixture/data/store/threading.db
before=$(sha256sum "$upgrade_db" | cut -d ' ' -f 1)
apt-get install --reinstall -y -qq /preview.deb >/dev/null
after=$(sha256sum "$upgrade_db" | cut -d ' ' -f 1)
test "$before" = "$after"
touch "$upgrade_fixture/reinstalled"
wait "$upgrade_runner"
upgrade_runner=''
restart_fixture=$(mktemp -d /tmp/threading-restart.XXXXXXXX)
chown threading-preview-test:threading-preview-test "$restart_fixture"
mkdir -p /evidence/restart-out
chmod 0777 /evidence/restart-out
rm /tmp/out
ln -s /evidence/restart-out /tmp/out
runuser -u threading-preview-test -- xvfb-run -a bash -s -- "$installed/bin" "$restart_fixture" <<'RESTART'
set -euo pipefail
bin=$1
fixture=$2
"$bin/threading-ptyd" --socket "$fixture/pty.sock" --state "$fixture/daemon" >"$fixture/daemon.log" 2>&1 &
daemon_pid=$!
trap 'kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true' EXIT
ready=0
for ((attempt=0; attempt<100; attempt++)); do
  if "$bin/threading-ptyd" sessions --json --socket "$fixture/pty.sock" >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$daemon_pid" || { cat "$fixture/daemon.log"; exit 1; }
  sleep .1
done
[[ $ready == 1 ]] || { cat "$fixture/daemon.log"; exit 1; }
python3 /terminal_restart_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
python3 /saved_terminal_refusal_smoke.py "$bin/WindowHarness" "$fixture/terminal-restart-store" "$fixture"
dbus-run-session -- python3 /terminal_catalogue_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
dbus-run-session -- python3 /terminal_catalogue_limits_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
RESTART
runuser -u threading-preview-test -- xvfb-run -a dbus-run-session -- bash /desktop-test.sh
echo 'PASS installed package, live-child reinstall, saved-terminal restart, desktop entry and non-root native window'
