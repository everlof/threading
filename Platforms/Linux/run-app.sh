#!/usr/bin/env bash
# Development entry point for the native Linux window and its existing PTY daemon.
set -euo pipefail
if [[ $# -gt 1 || $(uname -s) != Linux ]]; then
  echo 'usage (on Linux): ./run-app.sh [EXISTING_PROJECT_DIRECTORY]' >&2
  exit 64
fi
project=''
if [[ $# == 1 ]]; then
  project=$(realpath -e -- "$1")
fi
app_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$app_dir"
bundle_bin=''
if [[ -f "$app_dir/BUNDLE-MANIFEST" ]]; then
  bundle_bin=$app_dir/bin
fi
if [[ -n $project && ! -d $project ]]; then
  echo "run-app: project is not a directory: $project" >&2
  exit 1
fi
if [[ -z ${HOME:-} ]]; then
  echo 'run-app: HOME is required' >&2
  exit 1
fi
data_dir=${THREADING_LINUX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/threading-linux-spike}
runtime_dir=${THREADING_LINUX_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}}/threading-linux-spike}
shell_path=${THREADING_LINUX_SHELL:-${SHELL:-/bin/sh}}
for directory in "$data_dir" "$runtime_dir"; do
  if [[ $directory != /* ]]; then
    echo "run-app: state paths must be absolute: $directory" >&2
    exit 1
  fi
done
store=$data_dir/store
for directory in "$data_dir" "$runtime_dir"; do
  mkdir -p -m 700 -- "$directory"
  chmod 700 -- "$directory"
done
if [[ $shell_path != /* || ! -x $shell_path ]]; then
  echo "run-app: shell must be an absolute executable: $shell_path" >&2
  exit 1
fi
if [[ ! -x /usr/bin/zenity ]]; then
  echo 'run-app: /usr/bin/zenity is required for the native project folder picker' >&2
  exit 1
fi

if [[ -z ${THREADING_LINUX_BIN_DIR:-} ]]; then
  if [[ -n $bundle_bin ]]; then
    bin_dir=$bundle_bin
  else
    ./vendor-core.sh --verify
    swift build --product WindowHarness
    swift build --product LinuxHost
    bin_dir=$(swift build --show-bin-path)
  fi
else
  bin_dir=$THREADING_LINUX_BIN_DIR
fi
host=$bin_dir/LinuxHost
window=$bin_dir/WindowHarness
if [[ -z ${THREADING_LINUX_DAEMON_BIN:-} ]]; then
  if [[ -n $bundle_bin ]]; then
    daemon=$bundle_bin/threading-ptyd
  else
    swift build --package-path ../../Targets/PTYHost --product threading-ptyd
    daemon=$(swift build --package-path ../../Targets/PTYHost --show-bin-path)/threading-ptyd
  fi
else
  daemon=$THREADING_LINUX_DAEMON_BIN
fi
for executable in "$host" "$window" "$daemon"; do
  if [[ $executable != /* || ! -x $executable ]]; then
    echo "run-app: expected an absolute executable: $executable" >&2
    exit 1
  fi
done

state=$data_dir/daemon
socket=$runtime_dir/pty.sock
mkdir -p -m 700 -- "$state"
chmod 700 -- "$state"

# Serialize project import and daemon startup across launchers. Only threading-ptyd may decide
# whether a stale socket can be replaced.
exec 9>"$runtime_dir/start.lock"
flock -x 9
if [[ -n $project ]]; then
  "$host" --add-project "$store" "$project" >/dev/null
else
  "$host" --init-store "$store" >/dev/null
fi
if ! "$daemon" sessions --json --socket "$socket" >/dev/null 2>&1; then
  nohup "$daemon" --socket "$socket" --state "$state" >"$data_dir/daemon.log" 2>&1 </dev/null 9>&- &
  daemon_pid=$!
  printf '%s\n' "$daemon_pid" >"$runtime_dir/daemon.pid"
  ready=0
  for ((attempt=0; attempt<100; attempt++)); do
    if "$daemon" sessions --json --socket "$socket" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then break; fi
    sleep .1
  done
  if [[ $ready != 1 ]]; then
    echo "run-app: PTY daemon did not start; see $data_dir/daemon.log" >&2
    exit 1
  fi
fi
flock -u 9
exec 9>&-

# A desktop entry may inherit only system directories, while the provider is installed by a
# login-shell profile (for example in ~/.local/bin or a Node prefix). Probe with the same
# `-l -c` mode used for the eventual provider launch. Keep the inherited entries too: the
# window and an `/usr/bin/env node` shebang both need the resulting PATH after this script exits.
# A slow or broken profile must not prevent the native window from opening.
recover_login_path() {
  local path_file path_size login_path
  path_file=$(mktemp "$runtime_dir/login-path.XXXXXX") || return 0
  if /usr/bin/timeout -k 1s 3s "$shell_path" -l -c 'printf "%s" "$PATH" > "$1"' \
      threading-login-path "$path_file" >/dev/null 2>&1; then
    path_size=$(/usr/bin/stat -c %s -- "$path_file" 2>/dev/null) || path_size=0
    if (( path_size > 0 && path_size <= 16384 )); then
      login_path=$(cat -- "$path_file" 2>/dev/null) || login_path=''
      if [[ -n $login_path && $login_path != *$'\n'* && $login_path != *$'\r'* ]]; then
        PATH=$login_path${PATH:+:$PATH}
        export PATH
      fi
    fi
  fi
  rm -f -- "$path_file" || true
}
recover_login_path

if [[ ${THREADING_LINUX_CODEX+x} ]]; then
  codex=$THREADING_LINUX_CODEX
else
  codex=$(command -v codex || true)
fi
if [[ ${THREADING_LINUX_CLAUDE+x} ]]; then
  claude=$THREADING_LINUX_CLAUDE
else
  claude=$(command -v claude || true)
fi
if [[ -n $codex ]]; then
  if [[ $codex != /* || ! -x $codex ]]; then
    echo "run-app: Codex must be an absolute executable: $codex" >&2
    exit 1
  fi
fi
if [[ -n $claude ]]; then
  if [[ $claude != /* || ! -x $claude ]]; then
    echo "run-app: Claude must be an absolute executable: $claude" >&2
    exit 1
  fi
fi

# On Wayland, the default GTK libdecor plugin starts GTK inside the SDL process and publishes
# GTK's AT-SPI root in place of this window's custom accessibility tree. The packaged Cairo
# plugin keeps client decorations without starting GTK. Scope the default to the window process:
# the host, daemon and provider path discovery above retain their inherited environment.
window_libdecor_dir=''
if [[ ! ${LIBDECOR_PLUGIN_DIR+x} && ( ${SDL_VIDEODRIVER:-} == wayland \
    || ( -z ${SDL_VIDEODRIVER:-} && -n ${WAYLAND_DISPLAY:-} ) ) \
    && -f "$app_dir/libdecor-cairo-only/libdecor-cairo.so" ]]; then
  window_libdecor_dir=$app_dir/libdecor-cairo-only
fi
launch_window() {
  if [[ -n $window_libdecor_dir ]]; then
    exec env LIBDECOR_PLUGIN_DIR="$window_libdecor_dir" "$window" "$@"
  fi
  exec "$window" "$@"
}
if [[ -n $codex || -n $claude ]]; then
  if [[ -n $project ]]; then
    launch_window --app-agents-project "$store" "$socket" "$shell_path" "${codex:--}" "${claude:--}" "$project"
  fi
  launch_window --app-agents "$store" "$socket" "$shell_path" "${codex:--}" "${claude:--}"
fi
if [[ -n $project ]]; then
  launch_window --app-project "$store" "$socket" "$shell_path" "$project"
fi
launch_window --app "$store" "$socket" "$shell_path"
