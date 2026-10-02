#!/usr/bin/env bash
# Exercise desktop-style provider discovery without a Swift build or real agent login.
set -euo pipefail
if [[ $(uname -s) != Linux || ! -x /usr/bin/zenity ]]; then
  echo 'provider path smoke needs Linux with /usr/bin/zenity' >&2
  exit 77
fi

app_dir=${THREADING_LINUX_APP_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
test -x "$app_dir/run-app.sh"
fixture=$(mktemp -d /tmp/threading-provider-path.XXXXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/bin" "$fixture/login-bin" "$fixture/inherited-bin"

cat >"$fixture/bin/LinuxHost" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$fixture/bin/threading-ptyd" <<'SH'
#!/bin/bash
[[ ${1:-} == sessions ]]
SH
cat >"$fixture/bin/WindowHarness" <<'SH'
#!/bin/bash
printf '%s\n' "$PATH" >"$TEST_CAPTURE/path"
printf '%s\n' "$@" >"$TEST_CAPTURE/args"
if [[ ${TEST_RUN_CODEX:-0} == 1 ]]; then
  [[ $1 == --app-agents ]]
  "$5" --fixture-run
fi
SH
cat >"$fixture/login-shell" <<'SH'
#!/bin/bash
[[ $1 == -l && $2 == -c ]]
case ${TEST_LOGIN_MODE:-success} in
  timeout) sleep 10 ;;
  failure) exit 19 ;;
  oversized) TEST_LOGIN_PATH=$(/usr/bin/printf 'x%.0s' {1..17000}) ;;
esac
command=$3
shift 3
export PATH=$TEST_LOGIN_PATH
exec /bin/bash -c "$command" "$@"
SH
cat >"$fixture/login-bin/codex" <<'SH'
#!/usr/bin/env fixture-node
SH
cat >"$fixture/login-bin/fixture-node" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CAPTURE/interpreter-args"
SH
cat >"$fixture/inherited-bin/codex" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_CAPTURE/inherited-args"
SH
cat >"$fixture/inherited-bin/claude" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$fixture/bin/"* "$fixture/login-shell" "$fixture/login-bin/"* \
  "$fixture/inherited-bin/"*

run_case() {
  local name=$1 inherited_path=$2 login_mode=$3
  shift 3
  local capture=$fixture/$name
  mkdir -p "$capture"
  env -i HOME="$fixture/home" PATH="$inherited_path" \
    THREADING_LINUX_DATA_DIR="$capture/data" \
    THREADING_LINUX_RUNTIME_DIR="$capture/runtime" \
    THREADING_LINUX_BIN_DIR="$fixture/bin" \
    THREADING_LINUX_DAEMON_BIN="$fixture/bin/threading-ptyd" \
    THREADING_LINUX_SHELL="$fixture/login-shell" \
    TEST_LOGIN_PATH="$fixture/login-bin:/usr/bin:/bin" \
    TEST_LOGIN_MODE="$login_mode" TEST_CAPTURE="$capture" \
    "$@" "$app_dir/run-app.sh"
}

# A minimal graphical PATH finds the CLI and its /usr/bin/env interpreter after one login probe.
run_case discovered /usr/bin:/bin success TEST_RUN_CODEX=1
grep -Fxq -- "$fixture/login-bin/codex" "$fixture/discovered/args"
grep -Fxq -- '--fixture-run' "$fixture/discovered/interpreter-args"

# Bash's real login-profile loading follows the same path as a provider launch.
printf 'export PATH="%s:$PATH"\n' "$fixture/login-bin" >"$fixture/home/.bash_profile"
run_case bash_profile /usr/bin:/bin success THREADING_LINUX_SHELL=/bin/bash TEST_RUN_CODEX=1
grep -Fxq -- "$fixture/login-bin/codex" "$fixture/bash_profile/args"
grep -Fxq -- '--fixture-run' "$fixture/bash_profile/interpreter-args"

# PATH entries supplied by the desktop session remain available after recovery.
run_case inherited "$fixture/inherited-bin:/usr/bin:/bin" success
grep -Fq -- "$fixture/inherited-bin" "$fixture/inherited/path"

# An explicit executable wins over discovery, and an empty override disables that provider.
run_case explicit /usr/bin:/bin success \
  "THREADING_LINUX_CODEX=$fixture/inherited-bin/codex" \
  "THREADING_LINUX_CLAUDE=$fixture/inherited-bin/claude"
grep -Fxq -- "$fixture/inherited-bin/codex" "$fixture/explicit/args"
grep -Fxq -- "$fixture/inherited-bin/claude" "$fixture/explicit/args"
run_case disabled /usr/bin:/bin success THREADING_LINUX_CODEX='' THREADING_LINUX_CLAUDE=''
grep -Fxq -- '--app' "$fixture/disabled/args"

# A nonzero exit and a hung profile both fall back to the original PATH.
run_case failed "$fixture/inherited-bin:/usr/bin:/bin" failure
grep -Fxq -- "$fixture/inherited-bin/codex" "$fixture/failed/args"
run_case oversized "$fixture/inherited-bin:/usr/bin:/bin" oversized
grep -Fxq -- "$fixture/inherited-bin/codex" "$fixture/oversized/args"
started=$SECONDS
run_case timed_out "$fixture/inherited-bin:/usr/bin:/bin" timeout
elapsed=$((SECONDS - started))
(( elapsed < 8 ))
grep -Fxq -- "$fixture/inherited-bin/codex" "$fixture/timed_out/args"
echo 'PASS desktop provider PATH, env interpreter, explicit overrides and bounded fallback'
