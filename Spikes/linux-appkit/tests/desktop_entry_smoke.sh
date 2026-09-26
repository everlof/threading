#!/usr/bin/env bash
# Launch the installed desktop entry as a normal user, not its Exec path directly.
set -euo pipefail
fixture=$(mktemp -d /tmp/threading-desktop.XXXXXXXX)
data_dir=${XDG_DATA_HOME:-$HOME/.local/share}/threading-linux-spike
runtime_dir=${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/threading-linux-spike
test ! -e "$data_dir" && test ! -e "$runtime_dir"
daemon_pid=''
cleanup() {
  if [[ -n $daemon_pid ]]; then kill "$daemon_pid" 2>/dev/null || true; fi
  rm -rf -- "$data_dir" "$runtime_dir"
  rm -rf -- "$fixture"
}
trap cleanup EXIT
export THREADING_LINUX_CODEX='' THREADING_LINUX_CLAUDE=''
gtk-launch threading-linux-preview >"$fixture/desktop.log" 2>&1
window=''
for ((attempt=0; attempt<120; attempt++)); do
  window=$(xdotool search --onlyvisible --name '^Threading experiment - empty store$' 2>/dev/null | head -1 || true)
  if [[ -n $window ]]; then break; fi
  sleep .1
done
if [[ -z $window ]]; then
  cat "$fixture/desktop.log" >&2
  echo 'desktop entry did not open the native window' >&2
  exit 1
fi
daemon_pid=$(cat "$runtime_dir/daemon.pid")
test -f "$data_dir/store/threading.db"
import -window "$window" /evidence/desktop-out/desktop-entry-first-run.png
xdotool windowfocus --sync "$window" key Escape
echo 'PASS desktop entry opens the installed native window'
