#!/usr/bin/env bash
# Test the already-built installed preview under headless Weston without Swift or X11.
# THREADING_WAYLAND_PACKAGE may point to an immutable snapshot during concurrent builds.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=${1:-render}
[[ $mode == render || $mode == --actions || $mode == --composer ]] || {
  echo 'usage: wayland_smoke.sh [--actions|--composer]' >&2; exit 64;
}
mkdir -p out
evidence=$(mktemp -d "$PWD/out/wayland-smoke.XXXXXXXX")
package=${THREADING_WAYLAND_PACKAGE:-$PWD/out/threading-linux-preview-ubuntu24.04-arm64.deb}
[[ -f $package ]] || { echo "missing Wayland package: $package" >&2; exit 1; }
printf 'Wayland evidence: %s\n' "$evidence"
docker run --rm -i --platform linux/arm64 \
  -e "THREADING_WAYLAND_SMOKE_MODE=$mode" \
  -e THREADING_WAYLAND_CAIRO_PLUGIN \
  -e SDL_VIDEO_WAYLAND_PREFER_LIBDECOR \
  -e SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR \
  -v "$package:/preview.deb:ro" \
  -v "$PWD/tests/wayland_capture.c:/wayland_capture.c:ro" \
  -v "$PWD/tests/wayland_render_smoke.py:/wayland_render_smoke.py:ro" \
  -v "$PWD/tests/wayland_atspi_smoke.py:/wayland_atspi_smoke.py:ro" \
  -v "$PWD/tests/wayland_input_module.c:/wayland_input_module.c:ro" \
  -v "$PWD/tests/wayland_input_smoke.py:/wayland_input_smoke.py:ro" \
  -v "$PWD/tests/wayland_composer_smoke.py:/wayland_composer_smoke.py:ro" \
  -v "$evidence:/evidence" ubuntu:24.04 bash -s <<'RUN'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC
apt-get update -qq >/dev/null
apt-get install -y -qq /preview.deb weston dbus-x11 python3-gi gir1.2-atspi-2.0 \
  libsdl2-dev libweston-13-dev build-essential >/dev/null
plugin=/usr/lib/aarch64-linux-gnu/libdecor/plugins-1/libdecor-cairo.so
packaged_plugin=/opt/threading-linux-preview/libdecor-cairo-only/libdecor-cairo.so
test -L "$packaged_plugin"
test "$(readlink "$packaged_plugin")" = "$plugin"
test -f "$packaged_plugin"
dpkg-deb -f /preview.deb Depends | grep -q 'libdecor-0-plugin-1-cairo'
test "$(dpkg-query -W -f='${Status}' libdecor-0-plugin-1-cairo)" = 'install ok installed'
if [[ ${THREADING_WAYLAND_CAIRO_PLUGIN:-0} == 1 ]]; then
  mkdir -p /tmp/libdecor-cairo-only
  ln -s "$plugin" /tmp/libdecor-cairo-only/libdecor-cairo.so
  export LIBDECOR_PLUGIN_DIR=/tmp/libdecor-cairo-only
fi
export THREADING_WAYLAND_EXPECTED_PLUGIN_DIR=${LIBDECOR_PLUGIN_DIR:-/opt/threading-linux-preview/libdecor-cairo-only}
test "$(dpkg-query -W -f='${Status}' threading-linux-preview)" = 'install ok installed'
test -z "$(command -v swift || true)"
cc -shared -fPIC -O2 -Wall -Wextra -o /tmp/wayland_capture.so \
  /wayland_capture.c -ldl -lSDL2
cc -shared -fPIC -O2 -Wall -Wextra -Werror -o /tmp/wayland_input_module.so \
  /wayland_input_module.c $(pkg-config --cflags --libs libweston-13)
mkdir -p /tmp/xdg-run
chmod 700 /tmp/xdg-run
export XDG_RUNTIME_DIR=/tmp/xdg-run WAYLAND_DISPLAY=wayland-0 SDL_VIDEODRIVER=wayland
export THREADING_WESTON_INPUT_SOCKET=/tmp/xdg-run/threading-input
unset DISPLAY
cat >/tmp/threading-weston.ini <<'CONFIG'
[keyboard]
keymap_layout=se
CONFIG
weston --backend=headless-backend.so --renderer=pixman --socket=wayland-0 \
  --width=1280 --height=800 --config=/tmp/threading-weston.ini \
  --modules=/tmp/wayland_input_module.so \
  --log=/evidence/weston.log &
weston_pid=$!
trap 'kill "$weston_pid" 2>/dev/null || true; wait "$weston_pid" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<100; attempt++)); do
  [[ -S /tmp/xdg-run/wayland-0 ]] && break
  kill -0 "$weston_pid" || { cat /evidence/weston.log; exit 1; }
  sleep .1
done
[[ -S /tmp/xdg-run/wayland-0 ]]
[[ -S "$THREADING_WESTON_INPUT_SOCKET" ]]
if [[ $THREADING_WAYLAND_SMOKE_MODE != --composer ]]; then
  dbus-run-session -- python3 /wayland_render_smoke.py \
    /opt/threading-linux-preview/run-app.sh /evidence/render
fi
if [[ $THREADING_WAYLAND_SMOKE_MODE == --actions ]]; then
  mkdir -p /evidence/actions
  dbus-run-session -- python3 /wayland_atspi_smoke.py \
    /opt/threading-linux-preview/run-app.sh /tmp/WaylandProject /evidence/actions
  grep -q 'WAYLAND_CAPTURE state=open' /evidence/actions/app.log
  mkdir -p /evidence/input
  dbus-run-session -- python3 /wayland_input_smoke.py \
    /opt/threading-linux-preview/run-app.sh /tmp/WaylandProject /evidence/input
fi
if [[ $THREADING_WAYLAND_SMOKE_MODE == --actions || $THREADING_WAYLAND_SMOKE_MODE == --composer ]]; then
  mkdir -p /evidence/composer
  dbus-run-session -- python3 /wayland_composer_smoke.py \
    /opt/threading-linux-preview/run-app.sh WaylandComposerProject /evidence/composer
fi
RUN
