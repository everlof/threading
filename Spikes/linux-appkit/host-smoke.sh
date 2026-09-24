#!/usr/bin/env bash
# Production storage + production daemon + Linux host transport, all in a disposable container.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
./vendor-core.sh --verify
mkdir -p out
docker run --rm -i --platform linux/arm64 -v "$PWD/../..:/repo" -w /repo/Spikes/linux-appkit swift:6.3.2-noble bash -s <<'INNER' 2>&1 | tee out/host-smoke.log
set -euo pipefail
apt-get update -qq >/dev/null
apt-get install -y -qq libsqlite3-dev python3 >/dev/null
swift build --product LinuxHost
swift build --product PortablePTYClientHarness
python3 tests/build_info_smoke.py "$(swift build --show-bin-path)/SwiftTermBuildInfoGenerator-tool" /repo/Packages/Vendor/SwiftTerm/swifterm-terminfo
swift build --package-path /repo/Targets/PTYHost --product threading-ptyd
host="$(swift build --show-bin-path)/LinuxHost"
daemon="$(swift build --package-path /repo/Targets/PTYHost --show-bin-path)/threading-ptyd"
fixture=$(mktemp -d /tmp/lhost.XXXXXX)
mkdir -m 700 "$fixture/daemon" "$fixture/project"
"$daemon" --socket "$fixture/pty.sock" --state "$fixture/daemon" >"$fixture/daemon.log" 2>&1 &
daemon_pid=$!
cleanup() { kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; rm -rf "$fixture"; }
trap cleanup EXIT
for attempt in $(seq 1 100); do
  [[ -S "$fixture/pty.sock" ]] && break
  kill -0 "$daemon_pid" || { cat "$fixture/daemon.log"; exit 1; }
  sleep 0.1
done
[[ -S "$fixture/pty.sock" ]]
timeout 30 "$(swift build --show-bin-path)/PortablePTYClientHarness" "$fixture/pty.sock"
mkdir "$fixture/imported"
ln -s "$fixture/imported" "$fixture/imported-link"
"$host" --add-project "$fixture/import-store" "$fixture/imported-link" >"$fixture/import-path"
[[ $(cat "$fixture/import-path") == "$fixture/imported" ]]
"$host" --add-project "$fixture/import-store" "$fixture/imported" >/dev/null
"$host" "$fixture/import-store" "$fixture/missing.sock" list >"$fixture/import-list"
[[ $(grep -c "$fixture/imported" "$fixture/import-list") -eq 1 ]]
[[ $(grep -c '^  ' "$fixture/import-list" || true) -eq 0 ]]
if "$host" --add-project "$fixture/invalid-import" "$fixture/absent" >"$fixture/refusal" 2>&1; then
  echo 'host imported an absent directory' >&2; exit 1
fi
[[ ! -e "$fixture/invalid-import" ]]
if flock "$fixture/import-store/host.lock" "$host" --add-project "$fixture/import-store" "$fixture/project" >"$fixture/refusal" 2>&1; then
  echo 'host imported through a competing store lock' >&2; exit 1
fi
"$host" "$fixture/import-store" "$fixture/pty.sock" run "$fixture/imported-link" /bin/true </dev/null
"$host" "$fixture/import-store" "$fixture/missing.sock" list >"$fixture/import-after-run"
[[ $(grep -c "$fixture/imported" "$fixture/import-after-run") -eq 1 ]]
[[ $(grep -c '^  ' "$fixture/import-after-run") -eq 1 ]]
python3 - "$fixture/import-store/threading.db" "$fixture/standing-project.json" <<'PY'
import json, sqlite3, sys
db, receipt = sys.argv[1:]
with sqlite3.connect(db) as connection:
    project_id, data = connection.execute('SELECT id, data FROM project').fetchone()
    payload = json.loads(data)
    payload['futureProjectField'] = 'retain without rewriting'
    encoded = json.dumps(payload, sort_keys=True, separators=(',', ':'))
    connection.execute('UPDATE project SET data = ? WHERE id = ?', (encoded, project_id))
open(receipt, 'w').write(encoded)
PY
"$host" --add-project "$fixture/import-store" "$fixture/project" >/dev/null
python3 - "$fixture/import-store/threading.db" "$fixture/standing-project.json" <<'PY'
import sqlite3, sys
db, receipt = sys.argv[1:]
with sqlite3.connect(db) as connection:
    rows = connection.execute('SELECT data FROM project ORDER BY position').fetchall()
assert len(rows) == 2 and rows[0][0] == open(receipt).read(), 'project import rewrote a standing row'
PY
echo 'PASS offline incremental project import, symlink identity, refusals and untouched standing rows'
printf 'from-input\n' | timeout 20 "$host" "$fixture/store" "$fixture/pty.sock" run "$fixture/project" /bin/sh -c \
  'test -t 0 && test -t 1 || exit 91; read value; printf "PTY:%s\\n" "$value"; pwd; stty size' >"$fixture/output"
cat "$fixture/output"
grep -q 'PTY:from-input' "$fixture/output"
grep -q "$fixture/project" "$fixture/output"
grep -q '24 80' "$fixture/output"
"$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/list"
grep -q "$fixture/project" "$fixture/list"
grep -q 'sh' "$fixture/list"
cat "$fixture/list"
set +e
timeout 20 "$host" "$fixture/store" "$fixture/pty.sock" run "$fixture/project" /bin/sh -c 'exit 7' </dev/null
result=$?
set -e
[[ $result -eq 7 ]]
# Two invocations must reuse one durable project while retaining two terminal identities.
"$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/list"
[[ $(grep -c '^  ' "$fixture/list") -eq 2 ]]
[[ $(grep -c "$fixture/project" "$fixture/list") -eq 1 ]]
# A concurrent writer and an absent daemon must refuse without adding a terminal record.
if flock "$fixture/store/host.lock" "$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/refusal" 2>&1; then
  echo 'host ignored store lock' >&2; exit 1
fi
grep -q 'already owned' "$fixture/refusal"
if "$host" "$fixture/store" "$fixture/missing.sock" run "$fixture/project" /bin/sh -c true >"$fixture/refusal" 2>&1; then
  echo 'host accepted missing daemon' >&2; exit 1
fi
"$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/after-refusal"
cmp "$fixture/list" "$fixture/after-refusal"
echo 'PASS store ownership and missing-daemon refusal preserve durable records'
echo 'PASS real PTY input/output, cwd, grid, exit status and durable project/terminal reopen'
# Keep stdin open while the first watcher disappears; the child remains blocked in a real PTY read.
mkfifo "$fixture/input"
exec 3<>"$fixture/input"
"$host" "$fixture/store" "$fixture/pty.sock" run "$fixture/project" /bin/sh -c \
  'printf "READY:%s\n" "$$"; read value; printf "REJOINED:%s:%s\n" "$$" "$value"' \
  <"$fixture/input" >"$fixture/first-watch" 2>"$fixture/first-error" &
watcher_pid=$!
for attempt in $(seq 1 100); do
  grep -q 'READY:' "$fixture/first-watch" && break
  kill -0 "$watcher_pid" || { cat "$fixture/first-error"; exit 1; }
  sleep 0.1
done
grep -q 'READY:' "$fixture/first-watch"
child_pid=$(sed -n 's/.*READY:\([0-9]*\).*/\1/p' "$fixture/first-watch" | head -1)
kill "$watcher_pid"
wait "$watcher_pid" || true
exec 3>&-
"$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/before-attach"
terminal_id=$(awk '/^  / { id=$1 } END { print id }' "$fixture/before-attach")
printf 'after-reconnect\n' | timeout 20 "$host" "$fixture/store" "$fixture/pty.sock" attach "$terminal_id" \
  >"$fixture/rejoined" 2>"$fixture/replay-status"
cat "$fixture/rejoined"
grep -q "READY:$child_pid" "$fixture/rejoined"
grep -q "REJOINED:$child_pid:after-reconnect" "$fixture/rejoined"
"$host" "$fixture/store" "$fixture/pty.sock" list >"$fixture/after-attach"
cmp "$fixture/before-attach" "$fixture/after-attach"
if "$host" "$fixture/store" "$fixture/pty.sock" attach 00000000-0000-0000-0000-000000000000 >"$fixture/refusal" 2>&1; then
  echo 'host attached identity outside its store' >&2; exit 1
fi
grep -q 'not in this store' "$fixture/refusal"
echo 'PASS host restart reattaches the same live child, replays output and preserves terminal identity'
python3 tests/host_terminal_smoke.py "$host" "$fixture/store" "$fixture/pty.sock" "$fixture/project"
# Fast exits race pipe EOF. Preserve the child's status even when the daemon refuses late input.
for attempt in $(seq 1 8); do
  set +e
  timeout 15 "$host" "$fixture/exit-store" "$fixture/pty.sock" run "$fixture/project" /bin/sh -c 'exit 7' </dev/null
  result=$?
  set -e
  [[ $result -eq 7 ]]
done
echo 'PASS repeated fast exits preserve status across stdin EOF'


INNER
