#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./vendor-core.sh --verify
mkdir -p out
docker run --rm -i --platform linux/arm64 -e THREADING_LINUX_TERMINAL_STRESS="${THREADING_LINUX_TERMINAL_STRESS:-0}" -e THREADING_LINUX_STARTUP_ONLY="${THREADING_LINUX_STARTUP_ONLY:-0}" -e THREADING_LINUX_AGENT_ONLY="${THREADING_LINUX_AGENT_ONLY:-0}" -e THREADING_LINUX_NAMED_ONLY="${THREADING_LINUX_NAMED_ONLY:-0}" -e THREADING_LINUX_IME_ONLY="${THREADING_LINUX_IME_ONLY:-0}" -e THREADING_LINUX_A11Y_ONLY="${THREADING_LINUX_A11Y_ONLY:-0}" -e THREADING_TERMINAL_REFERENCE_RENDERER="${THREADING_TERMINAL_REFERENCE_RENDERER:-0}" -v "$PWD/../..:/repo" -w /repo/Spikes/linux-appkit swift:6.3.2-noble bash -s <<'INNER' 2>&1 | tee out/window-smoke.log
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev libsdl2-dev libpango1.0-dev libatk-bridge2.0-dev fonts-dejavu-core fonts-noto-cjk xvfb xdotool xclip imagemagick >/dev/null
if [[ "$THREADING_LINUX_IME_ONLY" == 1 ]]; then
  apt-get install -y -qq ibus ibus-libpinyin dbus-x11 >/dev/null
fi
if [[ "$THREADING_LINUX_A11Y_ONLY" == 1 ]]; then
  apt-get install -y -qq python3-gi gir1.2-atspi-2.0 dbus-x11 >/dev/null
fi
./vendor.sh --verify
swift build --product WindowHarness
swift build --product LinuxHost
swift build --product PortablePTYClientHarness
swift build --package-path /repo/Targets/PTYHost --product threading-ptyd
bin=$(swift build --show-bin-path)
daemon=$(swift build --package-path /repo/Targets/PTYHost --show-bin-path)/threading-ptyd
fixture=$(mktemp -d /tmp/lwindow.XXXXXX)
clang -shared -fPIC Sources/LinuxWindowBridge/TerminalDrawing.c Sources/LinuxWindowBridge/NavigatorDrawing.c -I Sources/LinuxWindowBridge/include $(pkg-config --cflags --libs pangocairo) -o "$fixture/renderer.so"
python3 tests/terminal_renderer_contract.py "$fixture/renderer.so"
python3 tests/navigator_renderer_contract.py "$fixture/renderer.so"
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
if [[ "$THREADING_LINUX_A11Y_ONLY" == 1 ]]; then
  for number in $(seq -w 1 15); do
    project_name="Project$number"
    if [[ "$number" == 06 ]]; then project_name='Project06-界'; fi
    mkdir "$fixture/$project_name"
    "$bin/LinuxHost" --add-project "$fixture/a11y-store" "$fixture/$project_name"
  done
  dbus-run-session -- python3 tests/accessibility_smoke.py "$bin/WindowHarness" \
    "$fixture/a11y-store" "$fixture/pty.sock" "$fixture"
  cp "$fixture/accessibility-window.log" out/accessibility-window.log
  exit 0
fi
if [[ "$THREADING_LINUX_IME_ONLY" == 1 ]]; then
  export XMODIFIERS=@im=ibus SDL_IM_MODULE=ibus
  export THREADING_IME_FIXTURE="$fixture" THREADING_IME_BIN="$bin"
  dbus-run-session -- bash -s <<'IME'
set -euo pipefail
ibus-daemon -drx --panel=disable >"$THREADING_IME_FIXTURE/ibus.log" 2>&1
for attempt in $(seq 1 50); do
  if ibus engine libpinyin 2>/dev/null; then break; fi
  sleep .1
done
python3 tests/terminal_ime_smoke.py "$THREADING_IME_BIN/WindowHarness" \
  "$THREADING_IME_FIXTURE/ime-store" "$THREADING_IME_FIXTURE/pty.sock" "$THREADING_IME_FIXTURE"
IME
  exit 0
fi
if [[ "$THREADING_LINUX_STARTUP_ONLY" == 1 ]]; then
  python3 tests/app_startup_smoke.py "$PWD/run-app.sh" "$bin/LinuxHost" "$daemon" "$bin" "$fixture"
  exit 0
fi
if [[ "$THREADING_LINUX_AGENT_ONLY" == 1 ]]; then
  python3 tests/agent_attach_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture"
  python3 tests/named_codex_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
  python3 tests/native_claude_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
  python3 tests/named_claude_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
  exit 0
fi
if [[ "$THREADING_LINUX_NAMED_ONLY" == 1 ]]; then
  python3 tests/named_codex_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
  python3 tests/named_claude_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
  exit 0
fi
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

# Pointer events go through SwiftTerm's live DEC mouse mode and protocol encoder. Ordinary
# project-list clicks still use their own navigation path.
"$bin/WindowHarness" --terminal "$fixture/store" "$fixture/pty.sock" "$fixture/Alpha" \
  /usr/bin/python3 "$PWD/tests/terminal_mouse_child.py" >"$fixture/window.log" 2>&1 &
window_pid=$!
for attempt in $(seq 1 200); do
  id=$(xdotool search --name '^Threading terminal - MOUSE OFF$' 2>/dev/null | head -1) || true
  [[ -n "$id" ]] && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
[[ -n "$id" ]]
xdotool windowfocus "$id"
mouse_stage() {
  local name=$1
  for attempt in $(seq 1 200); do
    xdotool getwindowname "$id" | grep -q "MOUSE $name$" && return 0
    kill -0 "$window_pid" || return 1
    sleep .05
  done
  return 1
}
mouse_stage OFF
xdotool type --clearmodifiers '.'
xdotool mousemove --window "$id" 25 33 click 1 click 4
mouse_stage X10
xdotool mousemove --window "$id" 25 33 click 1
mouse_stage VT200
xdotool mousemove --window "$id" 25 33 click 1 click 4 click 5
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'exited 0$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'exited 0$'
xdotool key alt+F4
wait "$window_pid"
window_pid=''
echo 'PASS native mouse: tracking-off refusal, X10 press, SGR press/release and wheel'
"$bin/WindowHarness" --terminal "$fixture/store" "$fixture/pty.sock" "$fixture/Alpha" \
  /usr/bin/python3 "$PWD/tests/terminal_scrollback_child.py" >"$fixture/window.log" 2>&1 &
window_pid=$!
for attempt in $(seq 1 200); do
  id=$(xdotool search --name '^Threading terminal - SCROLL READY$' 2>/dev/null | head -1) || true
  [[ -n "$id" ]] && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
[[ -n "$id" ]]
xdotool windowfocus "$id" mousemove --window "$id" 25 33
for step in $(seq 1 4); do xdotool click 4; done
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'SCROLL READY \[scrollback\]$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'SCROLL READY \[scrollback\]$'
import -window "$id" out/terminal-scrollback-held.png
select_and_copy_row() {
  local row=$1 expected=$2 capture=$3
  local y=$((row * 22 + 5))
  xdotool mousemove --window "$id" 5 "$y" mousedown 1
  sleep .05
  xdotool mousemove --window "$id" 75 "$y"
  sleep .05
  xdotool mouseup 1
  sleep .2
  import -window "$id" "out/terminal-selection-$capture.png"
  xdotool key ctrl+shift+c
  for attempt in $(seq 1 100); do
    [[ $(timeout 5 xclip -selection clipboard -o 2>/dev/null) == "$expected" ]] && return 0
    kill -0 "$window_pid" || return 1
    sleep .05
  done
  echo "selected text did not reach the native clipboard: $expected" >&2
  return 1
}
select_and_copy_row 0 'ROW 025' held
xdotool type --clearmodifiers '.'
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'SCROLL NEW \[scrollback\]$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'SCROLL NEW \[scrollback\]$'
for step in $(seq 1 8); do xdotool click 5; done
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'SCROLL NEW$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'SCROLL NEW$'
import -window "$id" out/terminal-scrollback-live.png
xdotool type --clearmodifiers q
for attempt in $(seq 1 200); do
  xdotool getwindowname "$id" | grep -q 'exited 0$' && break
  kill -0 "$window_pid" || { cat "$fixture/window.log"; exit 1; }
  sleep .05
done
xdotool getwindowname "$id" | grep 'exited 0$'
printf stale | xclip -selection clipboard -i
select_and_copy_row 0 'ROW 038' exited
xdotool key alt+F4
wait "$window_pid"
window_pid=''
echo 'PASS native scrollback and copy: held rows, live return, selection, clipboard and exited child'
python3 tests/terminal_clipboard_smoke.py "$bin/WindowHarness" "$fixture/store" "$fixture/pty.sock" "$fixture"
python3 tests/terminal_exit_smoke.py "$bin/WindowHarness"
python3 tests/project_terminal_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/store" "$fixture/pty.sock" "$fixture" "$PWD/tests/project_terminal_child.py"

python3 tests/project_retry_smoke.py "$bin/WindowHarness" "$fixture/store"
python3 tests/project_terminal_picker_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture" "$PWD/tests/terminal_attach_child.py"
python3 tests/agent_attach_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture"
python3 tests/agent_create_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
python3 tests/named_codex_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
python3 tests/native_claude_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
python3 tests/named_claude_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$daemon" "$fixture/pty.sock" "$fixture"
python3 tests/terminal_attach_smoke.py "$bin/WindowHarness" "$bin/LinuxHost" "$fixture/pty.sock" "$fixture" "$PWD/tests/terminal_attach_child.py"
python3 tests/app_startup_smoke.py "$PWD/run-app.sh" "$bin/LinuxHost" "$daemon" "$bin" "$fixture"

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
