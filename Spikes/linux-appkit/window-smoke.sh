#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./vendor-core.sh --verify
mkdir -p out
docker run --rm -i --platform linux/arm64 -e THREADING_LINUX_TERMINAL_STRESS="${THREADING_LINUX_TERMINAL_STRESS:-0}" -e THREADING_TERMINAL_REFERENCE_RENDERER="${THREADING_TERMINAL_REFERENCE_RENDERER:-0}" -v "$PWD/../..:/repo" -w /repo/Spikes/linux-appkit swift:6.3.2-noble bash -s <<'INNER' 2>&1 | tee out/window-smoke.log
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev fonts-dejavu-core fonts-noto-cjk xvfb xdotool imagemagick >/dev/null
./vendor.sh --verify
swift build --product WindowHarness
swift build --product LinuxHost
swift build --product PortablePTYClientHarness
swift build --package-path /repo/Targets/PTYHost --product threading-ptyd
bin=$(swift build --show-bin-path)
daemon=$(swift build --package-path /repo/Targets/PTYHost --show-bin-path)/threading-ptyd
fixture=$(mktemp -d /tmp/lwindow.XXXXXX)
clang -shared -fPIC Sources/LinuxWindowBridge/TerminalDrawing.c -I Sources/LinuxWindowBridge/include $(pkg-config --cflags --libs pangocairo) -o "$fixture/renderer.so"
python3 tests/terminal_renderer_contract.py "$fixture/renderer.so"
mkdir "$fixture/daemon"
"$daemon" --socket "$fixture/pty.sock" --state "$fixture/daemon" >"$fixture/daemon.log" 2>&1 &
daemon_pid=$!
Xvfb :88 -screen 0 1400x1000x24 >"$fixture/xvfb.log" 2>&1 &
x_pid=$!
window_pid=''
cleanup() {
  result=$?
  if [[ -f "$fixture/window.log" ]]; then cp "$fixture/window.log" out/window-session.log; fi
  if [[ $result -ne 0 ]]; then
    cat "$fixture/window.log" "$fixture/daemon.log" "$fixture/xvfb.log" 2>/dev/null || true
  fi
  [[ -z "$window_pid" ]] || kill "$window_pid" 2>/dev/null || true
  kill "$daemon_pid" "$x_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT
export DISPLAY=:88 SDL_VIDEODRIVER=x11
for attempt in $(seq 1 100); do
  [[ -S "$fixture/pty.sock" ]] && xdpyinfo >/dev/null 2>&1 && break
  sleep .1
done
timeout 30 "$bin/PortablePTYClientHarness" "$fixture/pty.sock"
for project in Alpha Beta Gamma; do
  mkdir "$fixture/$project"
  "$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" run "$fixture/$project" /bin/true </dev/null
 done
"$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" list >"$fixture/before"
"$bin/WindowHarness" "$fixture/store" >"$fixture/window.log" 2>&1 &
window_pid=$!
for attempt in $(seq 1 100); do
  id=$(xdotool search --name 'Threading experiment' 2>/dev/null | head -1) || true
  [[ -n "$id" ]] && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .1
done
[[ -n "$id" ]]
await_title() {
  for attempt in $(seq 1 200); do
    xdotool getwindowname "$id" | grep -q "/$1$" && return 0
    kill -0 "$window_pid" || return 1
    sleep .1
  done
  echo "selection did not reach $1" >&2
  return 1
}
# Native X events, not direct calls into the selection state.
xdotool windowfocus "$id" key Down
await_title Beta
xdotool getwindowname "$id" | grep '/Beta$'
xdotool mousemove --window "$id" 100 160 click 1
await_title Gamma
xdotool getwindowname "$id" | grep '/Gamma$'
xdotool windowsize "$id" 960 600
for attempt in $(seq 1 200); do
  grep -q 'FRAME 960x600' "$fixture/window.log" && break
  sleep .1
done
grep -q 'FRAME 960x600' "$fixture/window.log"
import -window "$id" out/window-native.png
xdotool key Escape
wait "$window_pid"
window_pid=''
cat "$fixture/window.log"
grep -q 'FRAME 960x600 mounted=3' "$fixture/window.log"
"$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" list >"$fixture/after"
cmp "$fixture/before" "$fixture/after"
echo 'PASS native window, keyboard and pointer selection, resize, close, durable store unchanged'
cat >"$fixture/terminal-child.py" <<'PYCHILD'
import os, tty, fcntl, termios, struct
tty.setraw(0)
os.write(1, "\x1b[2J\x1b[HThreading native Linux terminal\r\n\x1b[32mUnicode: 界 e\u0301 Ångström\x1b[0m\r\n\x1b[38;2;100;160;255mShared SwiftTerm + production PTY client\x1b[0m\r\nType a line: ".encode())
os.write(1, b'\x1b]0;READY\x07')
value = b''
while not value.endswith(b'\r'):
    chunk = os.read(0, 1)
    value += chunk
    os.write(1, chunk)
assert value == b'native-input\r', repr(value)
rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
assert (rows, cols) == (30, 96), (rows, cols)
os.write(1, ('\r\nINPUT OK: native-input\r\nGRID OK: %d columns x %d rows\r\n' % (cols, rows)).encode())
raise SystemExit(7)
PYCHILD
"$bin/WindowHarness" --terminal "$fixture/store" "$fixture/pty.sock" "$fixture/Alpha" /usr/bin/python3 "$fixture/terminal-child.py" >"$fixture/window.log" 2>&1 &
window_pid=$!
for attempt in $(seq 1 200); do
  id=$(xdotool search --name '^Threading terminal - READY$' 2>/dev/null | head -1) || true
  [[ -n "$id" ]] && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .1
done
[[ -n "$id" ]]
xdotool windowfocus "$id" windowsize "$id" 960 660
for attempt in $(seq 1 200); do
  grep -q 'TERMINAL_FRAME 960x660' "$fixture/window.log" && break
  sleep .1
done
grep -q 'TERMINAL_FRAME 960x660' "$fixture/window.log"
xdotool type --clearmodifiers 'native-input'
xdotool key Return
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'exited 7$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .1
done
xdotool getwindowname "$id" | grep 'exited 7$'
import -window "$id" out/terminal-native.png
xdotool key alt+F4
wait "$window_pid"
window_pid=''
"$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" list >"$fixture/terminal-after"
[[ $(grep -c '^  ' "$fixture/terminal-after") -eq 4 ]]
echo 'PASS native terminal: shaped Unicode, X keyboard input, real PTY resize, exit 7 and persisted terminal'

# Functional keys use the emulator's live modes, not a platform escape table.
cp "$fixture/window.log" out/terminal-interactive-session.log
"$bin/WindowHarness" --terminal "$fixture/store" "$fixture/pty.sock" "$fixture/Alpha" /usr/bin/python3 "$PWD/tests/terminal_keyboard_child.py" >"$fixture/window.log" 2>&1 &
window_pid=$!
for attempt in $(seq 1 200); do
  id=$(xdotool search --name '^Threading terminal - KEY NORMAL$' 2>/dev/null | head -1) || true
  [[ -n "$id" ]] && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .1
done
[[ -n "$id" ]]
xdotool windowfocus "$id"
key_stage() {
  local name=$1
  shift
  for attempt in $(seq 1 200); do
    xdotool getwindowname "$id" | grep -q "KEY $name$" && break
    kill -0 "$window_pid" || return 1
    sleep .05
  done
  xdotool getwindowname "$id" | grep -q "KEY $name$"
  xdotool key --clearmodifiers "$@"
  xdotool type --clearmodifiers '.'
}
key_stage NORMAL Up
key_stage APP Up
key_stage MOD ctrl+Right
key_stage 'KITTY TAB' ctrl+Tab
key_stage 'KITTY UP' Up
key_stage NAV Home End Prior Next Delete F2
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'KEY ORDER$' && break
  sleep .05
done
xdotool getwindowname "$id" | grep -q 'KEY ORDER$'
xdotool type a
xdotool key BackSpace
xdotool type b
xdotool key Return
xdotool type '.'
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'exited 0$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'exited 0$'
import -window "$id" out/terminal-keyboard.png
xdotool key alt+F4
wait "$window_pid"
window_pid=''
echo 'PASS native functional keys: normal/application modes, modifiers, kitty press/release and ordered editing'
python3 tests/terminal_exit_smoke.py "$bin/WindowHarness"
python3 tests/project_terminal_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" "$fixture" "$PWD/tests/project_terminal_child.py"

python3 tests/project_retry_smoke.py "$bin/WindowHarness" "$fixture/store"
python3 tests/project_terminal_picker_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture" "$PWD/tests/terminal_attach_child.py"
python3 tests/terminal_attach_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture" "$PWD/tests/terminal_attach_child.py"

if [[ "$THREADING_LINUX_TERMINAL_STRESS" == 1 ]]; then
  "$bin/WindowHarness" --terminal "$fixture/store" "$fixture/pty.sock" "$fixture/Alpha" /usr/bin/python3 "$PWD/tests/terminal_stress_child.py" >"$fixture/window.log" 2>&1 &
  window_pid=$!
  for attempt in $(seq 1 200); do
    id=$(xdotool search --name '^Threading terminal - STRESS READY$' 2>/dev/null | head -1) || true
    [[ -n "$id" ]] && break
    kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
    sleep .1
  done
  [[ -n "$id" ]]
  xdotool windowfocus "$id" windowmove "$id" 0 0 windowsize "$id" 1280 900
  for attempt in $(seq 1 200); do
    grep -q 'TERMINAL_FRAME 1280x900' "$fixture/window.log" && break
    sleep .1
  done
  grep -q 'TERMINAL_FRAME 1280x900' "$fixture/window.log"
  xdotool key g
  for attempt in $(seq 1 200); do
    xdotool getwindowname "$id" | grep -q 'STRESS RUNNING$' && break
    sleep .01
  done
  xdotool getwindowname "$id" | grep -q 'STRESS RUNNING$'
  started=$(date +%s%N)
  xdotool key p
  for attempt in $(seq 1 200); do
    xdotool getwindowname "$id" | grep -q 'STRESS ACK$' && break
    sleep .01
  done
  xdotool getwindowname "$id" | grep -q 'STRESS ACK$'
  elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
  echo "STRESS_INPUT_MS $elapsed" | tee out/terminal-stress-input.log
  for attempt in $(seq 1 300); do
    xdotool getwindowname "$id" | grep -q 'exited 0$' && break
    kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
    sleep .1
  done
  xdotool getwindowname "$id" | grep -q 'exited 0$'
  import -window "$id" out/terminal-stress.png
  # After output and exit settle, an idle terminal must stop preparing frames.
  before=$(grep -c TERMINAL_FRAME "$fixture/window.log")
  sleep .3
  [[ $(grep -c TERMINAL_FRAME "$fixture/window.log") -eq "$before" ]]
  cp "$fixture/window.log" out/terminal-stress-session.log
  xdotool key alt+F4
  wait "$window_pid"
  window_pid=''
  python3 tests/summarize_terminal_stress.py out/terminal-stress-session.log
  echo 'PASS maximum-grid live output, keyboard acknowledgment under load, exit and idle frame quiescence'
fi
INNER
