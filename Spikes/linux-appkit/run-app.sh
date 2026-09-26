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
cd "$(dirname "${BASH_SOURCE[0]}")"
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
  ./vendor-core.sh --verify
  swift build --product WindowHarness
  swift build --product LinuxHost
  bin_dir=$(swift build --show-bin-path)
else
  bin_dir=$THREADING_LINUX_BIN_DIR
fi
host=$bin_dir/LinuxHost
window=$bin_dir/WindowHarness
if [[ -z ${THREADING_LINUX_DAEMON_BIN:-} ]]; then
  swift build --package-path ../../Targets/PTYHost --product threading-ptyd
  daemon=$(swift build --package-path ../../Targets/PTYHost --show-bin-path)/threading-ptyd
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
if [[ -n $codex || -n $claude ]]; then
  if [[ -n $project ]]; then
    exec "$window" --app-agents-project "$store" "$socket" "$shell_path" "${codex:--}" "${claude:--}" "$project"
  fi
  exec "$window" --app-agents "$store" "$socket" "$shell_path" "${codex:--}" "${claude:--}"
fi
if [[ -n $project ]]; then
  exec "$window" --app-project "$store" "$socket" "$shell_path" "$project"
fi
exec "$window" --app "$store" "$socket" "$shell_path"
