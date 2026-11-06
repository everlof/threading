#!/usr/bin/env bash
# A short installed-package acceptance journey, with no checkout or Swift in the runtime.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq
apt-get install --no-install-recommends -y -qq /preview.deb
test -z "$(command -v swift || true)"
test "$(dpkg-deb -f /preview.deb Architecture)" = "$(dpkg --print-architecture)"
installed=/opt/threading-linux-preview
for binary in WindowHarness LinuxHost threading-ptyd; do
  test -x "$installed/bin/$binary"
  dependencies=$(ldd "$installed/bin/$binary")
  if grep -q 'not found' <<<"$dependencies"; then
    printf '%s\n' "$dependencies" >&2
    exit 1
  fi
done
apt-get install --no-install-recommends -y -qq xvfb xauth xdotool xclip imagemagick \
  python3 desktop-file-utils libgtk-3-bin dbus-x11 at-spi2-core python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0
desktop-file-validate /usr/share/applications/threading-linux-preview.desktop
cp "$installed/BUNDLE-MANIFEST" /evidence/BUNDLE-MANIFEST
cp /etc/os-release /evidence/runtime-os-release
dpkg-query -W > /evidence/runtime-packages.txt
sha256sum /preview.deb > /evidence/package.sha256
useradd --create-home --shell /bin/bash threading-alpha-test
unreadable=$(runuser -u threading-alpha-test -- find "$installed/bin" \
  \( -type f ! -readable -o -type d ! -executable \) -print -quit)
[[ -z $unreadable ]] || { echo "Unreadable installed resource: $unreadable" >&2; exit 1; }
mkdir -p /work/out /evidence/x11 /evidence/desktop-out
chown -R threading-alpha-test:threading-alpha-test /work /evidence/x11 /evidence/desktop-out
runuser -u threading-alpha-test -- env THREADING_LINUX_APP_DIR="$installed" \
  bash /tests/provider_path_smoke.sh
runuser -u threading-alpha-test -- xvfb-run -a dbus-run-session -- bash /tests/desktop_entry_smoke.sh
runuser -u threading-alpha-test -- xvfb-run -a -s '-screen 0 1280x1024x24 -noreset' \
  dbus-run-session -- bash -s -- "$installed" <<'JOURNEY'
set -euo pipefail
app=$1
bin=$app/bin
cd /work
mkdir startup
python3 /tests/app_startup_smoke.py "$app/run-app.sh" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$bin" /work/startup --bundled
cp -a /work/out/. /evidence/x11/
"$app/collect-diagnostics.py" --output /evidence/x11
fixture=$(mktemp -d /work/journey.XXXXXXXX)
"$bin/threading-ptyd" --socket "$fixture/pty.sock" --state "$fixture/daemon" \
  >"$fixture/daemon.log" 2>&1 &
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
python3 /tests/terminal_restart_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
for provider in codex claude; do
  python3 /tests/native_workspace_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
    "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" \
    "/evidence/x11/native-$provider" "$provider"
done
python3 /tests/native_permission_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" /evidence/x11/permissions
JOURNEY
printf 'PASS installed alpha: runtime dependencies, non-root startup, persistent terminal, native Codex/Claude replay/resume, permissions and diagnostics\n' \
  | tee /evidence/RESULT.txt
