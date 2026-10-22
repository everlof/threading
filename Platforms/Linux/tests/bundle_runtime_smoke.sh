#!/usr/bin/env bash
# Exercise the archive and installed package without source or a Swift toolchain.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq /preview.deb >/dev/null
apt-get install -y -qq xvfb xauth xdotool xclip imagemagick python3 \
  desktop-file-utils libgtk-3-bin dbus-x11 python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 >/dev/null

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
for root in "$bundle" "$installed"; do
  test -s "$root/licenses/Inter/LICENSE.txt"
  test -s "$root/licenses/Inter/SOURCE.md"
  fonts="$root/bin/LinuxAppKitSpike_AppKit.resources/Fonts/Inter"
  printf '%s  %s\n' \
    4989b125924991b90d05b2d16e0e388c48f7d5bb8b30539bbf9c755278d0ccaf "$fonts/InterVariable.ttf" \
    d6f1f6a172d9e588438db9f986fd5cfad7b30f644374080a8a9d4d91e344586f "$fonts/InterVariable-Italic.ttf" \
    | sha256sum --check --status
  for license in LICENSE.txt NOTICE.txt BoringSSL-LICENSE; do
    test -s "$root/licenses/swift-crypto/$license"
  done
done
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
runuser -u threading-preview-test -- xvfb-run -a dbus-run-session -- python3 /live-reinstall-test.py \
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
# This lane deliberately shares one display across short-lived clients. Keep it alive between
# journeys; an X server reset can race the next client's SDL video-driver discovery.
runuser -u threading-preview-test -- xvfb-run -a -s '-screen 0 1280x1024x24 -noreset' \
  bash -s -- "$installed/bin" "$restart_fixture" <<'RESTART'
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
dbus-run-session -- python3 /workspace_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
dbus-run-session -- python3 /session_actions_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" "$fixture" /evidence/restart-out
dbus-run-session -- python3 /session_close_unmounted_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture" \
  /evidence/restart-out
dbus-run-session -- python3 /open_in_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" "$fixture" /evidence/restart-out/open-in
LD_PRELOAD=/gtk-present-delay.so THREADING_GTK_PRESENT_DELAY_MS=3000 \
  THREADING_GTK_PRESENT_TRACE=/evidence/restart-out/gtk-delay.log \
  dbus-run-session -- python3 /agent_catalogue_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
grep -q 'delayMs=3000' /evidence/restart-out/gtk-delay.log
dbus-run-session -- python3 /actions_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
dbus-run-session -- python3 /project_actions_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture" /evidence/restart-out/project-actions
dbus-run-session -- python3 /project_create_menu_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture" /evidence/restart-out/project-create-menu
dbus-run-session -- python3 /composer_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer.sock" "$fixture" /evidence/restart-out/composer
dbus-run-session -- python3 /composer_checkout_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/checkout.sock" "$fixture" /evidence/restart-out/composer-checkout
dbus-run-session -- python3 /composer_surface_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/native-checkout.sock" "$fixture" \
  /evidence/restart-out/composer-native-checkout codex checkout
dbus-run-session -- python3 /composer_attachment_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-attachment.sock" "$fixture" /evidence/restart-out/composer-attachment
dbus-run-session -- python3 /composer_permissions_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-permissions.sock" "$fixture" /evidence/restart-out/composer-permissions
dbus-run-session -- python3 /composer_models_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-models.sock" "$fixture" /evidence/restart-out/composer-models
dbus-run-session -- python3 /composer_surface_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-surface.sock" "$fixture" /evidence/restart-out/composer-surface
dbus-run-session -- python3 /composer_surface_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-surface-claude.sock" "$fixture" \
  /evidence/restart-out/composer-surface-claude claude
for provider in codex claude; do
  for mode in speed-terminal speed-native speed-live configuration-live attachment; do
    dbus-run-session -- python3 /composer_surface_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
      "$bin/threading-ptyd" "$fixture/composer-$provider-$mode.sock" "$fixture" \
      "/evidence/restart-out/composer-$provider-$mode" "$provider" "$mode"
  done
done
THREADING_TEST_LAST_USED_MODE=1 dbus-run-session -- python3 /composer_surface_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" \
  "$fixture/composer-claude-last-used.sock" "$fixture" \
  /evidence/restart-out/composer-claude-last-used claude configuration-live
THREADING_TEST_LAST_USED_MODE=1 THREADING_TEST_INHERITED_MODE=1 \
  dbus-run-session -- python3 /composer_surface_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" \
  "$fixture/composer-claude-precedence.sock" "$fixture" \
  /evidence/restart-out/composer-claude-precedence claude configuration-live
THREADING_TEST_OBSERVED_MODE=1 THREADING_TEST_LAST_USED_MODE=1 \
  dbus-run-session -- python3 /composer_surface_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" \
  "$fixture/composer-claude-observed.sock" "$fixture" \
  /evidence/restart-out/composer-claude-observed claude baseline
THREADING_TEST_OBSERVED_MODE=1 THREADING_TEST_INHERITED_MODE=1 \
  dbus-run-session -- python3 /composer_surface_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" \
  "$fixture/composer-claude-observed-default.sock" "$fixture" \
  /evidence/restart-out/composer-claude-observed-default claude baseline
dbus-run-session -- python3 /document_ui_smoke.py "$bin/WindowHarness" /evidence/restart-out/document
timeout 15 "$bin/WindowHarness" --themed-table-row-fixture /evidence/restart-out/themed-table-row-default.png
dbus-run-session -- python3 /user_bubble_smoke.py "$bin/WindowHarness" /evidence/restart-out/user-bubble
dbus-run-session -- python3 /automatic_rows_smoke.py "$bin/WindowHarness" /evidence/restart-out/automatic-rows
dbus-run-session -- python3 /diff_ui_smoke.py "$bin/WindowHarness" /evidence/restart-out/diff
dbus-run-session -- python3 /stream_conversation_smoke.py "$bin/WindowHarness" /stream_agent_fixture.py \
  /evidence/restart-out/stream
timeout 15 "$bin/WindowHarness" --app-event-contract
timeout 30 "$bin/WindowHarness" --ui-worker-contract
timeout 60 "$bin/WindowHarness" --native-conversation-delivery-contract /native-conversation-providers.py
dbus-run-session -- python3 /short_user_row_smoke.py "$bin/WindowHarness" /evidence/restart-out/short-user-row
dbus-run-session -- python3 /native_workspace_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" /evidence/restart-out/native-workspace
dbus-run-session -- python3 /native_workspace_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" /evidence/restart-out/native-workspace-claude claude
dbus-run-session -- python3 /native_permission_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" /evidence/restart-out/native-permission
# Repeat the native pixel/input contracts at the second supported UI scale.
mkdir "$fixture/ui-scale-2"
THREADING_LINUX_UI_SCALE=2 dbus-run-session -- python3 /native_workspace_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/native-workspace-2x
THREADING_LINUX_UI_SCALE=2 dbus-run-session -- python3 /native_permission_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/native-permission-2x
dbus-run-session -- python3 /native_activity_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/native-activity-light
mkdir "$fixture/ui-scale-2-dark"
THREADING_TEST_DARK=1 dbus-run-session -- python3 /native_activity_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2-dark" /evidence/restart-out/native-activity-dark
dbus-run-session -- python3 /native_background_activity_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/native-background-activity-light
THREADING_TEST_DARK=1 dbus-run-session -- python3 /native_background_activity_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2-dark" /evidence/restart-out/native-background-activity-dark
dbus-run-session -- python3 /archived_navigation_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/archived-navigation
dbus-run-session -- python3 /session_rename_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture/ui-scale-2" /evidence/restart-out/session-rename-2x
THREADING_LINUX_UI_SCALE=1 dbus-run-session -- python3 /session_rename_smoke.py \
  "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" \
  "$fixture" /evidence/restart-out/session-rename-1x
dbus-run-session -- python3 /composer_account_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/composer-account.sock" "$fixture" \
  /evidence/restart-out/composer-account
dbus-run-session -- python3 /add_project_button_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture" /evidence/restart-out/add-project-button
dbus-run-session -- python3 /provider_marks_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
dbus-run-session -- python3 /account_picker_rows_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" /evidence/restart-out/account-picker
dbus-run-session -- python3 /project_count_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" "$fixture" /evidence/restart-out/project-count
dbus-run-session -- python3 /multi_project_outline_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" "$fixture" /evidence/restart-out/multi-project-outline
for scale in 1 2; do
  THREADING_LINUX_UI_SCALE=$scale dbus-run-session -- python3 /terminal_creation_selection_smoke.py \
    "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" \
    "/evidence/restart-out/terminal-creation-$scale"
  THREADING_LINUX_UI_SCALE=$scale dbus-run-session -- python3 /empty_sidebar_smoke.py \
    "$bin/WindowHarness" "$bin/LinuxHost" "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture" \
    "/evidence/restart-out/empty-sidebar-$scale"
done
dbus-run-session -- python3 /native_outline_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$fixture/pty.sock" "$fixture" /evidence/restart-out/native-outline
python3 /terminal_restart_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
python3 /saved_terminal_refusal_smoke.py "$bin/WindowHarness" "$fixture/terminal-restart-store" "$fixture"
dbus-run-session -- python3 /terminal_catalogue_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
dbus-run-session -- python3 /terminal_catalogue_limits_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
python3 /terminal_directory_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" \
  "$bin/threading-ptyd" "$fixture/pty.sock" "$fixture"
python3 /terminal_directory_identity_smoke.py "$bin/WindowHarness" "$fixture/terminal-restart-store" "$fixture"
RESTART
runuser -u threading-preview-test -- xvfb-run -a dbus-run-session -- bash /desktop-test.sh
echo 'PASS installed package, live-child reinstall, saved-terminal restart, desktop entry and non-root native window'
