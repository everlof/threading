"""Real controlling-PTY checks, invoked inside Linux by host-smoke.sh (not unittest discovery)."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

host, store, socket, folder = sys.argv[1:]

def exercise(command, terminate=False):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 97, 0, 0))
    child = subprocess.Popen([host, store, socket, "run", folder, "/bin/sh", "-c", command],
                             stdin=slave, stdout=slave, stderr=slave)
    output = bytearray()
    def until(marker):
        deadline = time.monotonic() + 12
        while marker not in output:
            if time.monotonic() > deadline:
                raise AssertionError(("terminal deadline", marker, bytes(output)))
            if select.select([master], [], [], .1)[0]:
                output.extend(os.read(master, 4096))
            if len(output) > 65536:
                raise AssertionError("unexpected output growth")
    try:
        until(b"READY")
        assert not termios.tcgetattr(slave)[3] & termios.ICANON, "host input is still canonical"
        if terminate:
            child.send_signal(signal.SIGTERM)
            assert child.wait(timeout=5) == 143
        else:
            until(b"31 97")
            os.write(master, b"x")  # No newline: verifies immediate keyboard forwarding.
            until(b"KEY:x")
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 42, 113, 0, 0))
            child.send_signal(signal.SIGWINCH)
            until(b"RESIZED")
            assert child.wait(timeout=5) == 0
        assert termios.tcgetattr(slave) == original, "caller terminal mode was not restored"
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)
        os.close(slave)

exercise('stty -icanon -echo; printf "READY\\n"; stty size; '
         'key=$(dd bs=1 count=1 2>/dev/null); printf "KEY:%s\\n" "$key"; '
         'n=0; while [ "$(stty size)" != "42 113" ]; do '
         'n=$((n+1)); [ "$n" -lt 100 ] || exit 92; sleep .05; done; printf "RESIZED\\n"')
exercise('printf "READY\\n"; read value', terminate=True)
print("PASS raw keyboard, initial geometry, live resize and terminal restoration on exit/SIGTERM")

# Exercise the same login-shell plan factory and quoter used by the macOS launcher.
import json
from pathlib import Path
quoted_folder = Path(folder) / "quoted ' $HOME ; project"
quoted_folder.mkdir()
marker = Path(folder) / "unexpected-substitution"
words = ["a'b", 'a"b', "$HOME", f"$(touch {marker})", f"`touch {marker}`",
         "line one\nline two", "--leading-option", "", "日本語"]
result = subprocess.run([host, store, socket, "login-run", str(quoted_folder), "/bin/sh",
                         "/usr/bin/python3", "-c",
                         "import json,os,sys; print(json.dumps([os.getcwd(),sys.argv[1:]]))", *words],
                        input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
assert result.returncode == 0, (result.returncode, result.stderr)
records = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith("[")]
assert records == [[str(quoted_folder), words]], result.stdout
assert not marker.exists(), "login-shell plan executed command substitution"
print("PASS shared login-shell plan preserves hostile arguments, Unicode and quoted working directory")

# Inspect only fixture values, never dump the caller's credentials/environment into the log.
inherited = os.environ.copy()
fixture_environment = {
    "PATH": "/fixture/bin:/usr/bin:/bin",
    "HOME": str(Path(folder) / "fixture-home"),
    "CODEX_HOME": str(Path(folder) / "fixture-codex"),
    "CLAUDE_CONFIG_DIR": str(Path(folder) / "fixture-claude"),
    "CURSOR_API_KEY": "fixture-only",
    "CODEX_CI": "1",
    "CODEX_THREAD_ID": "parent-fixture",
    "CLAUDECODE": "1",
    "AI_AGENT": "parent-fixture",
    "TERM": "xterm-256color",
    "LANG": "C.UTF-8",
}
inherited.update(fixture_environment)
keys = list(fixture_environment)
result = subprocess.run([host, store, socket, "run", folder, "/usr/bin/python3", "-c",
                         "import json,os,sys; print(json.dumps({k:os.environ.get(k) for k in sys.argv[1:]}))",
                         *keys], env=inherited, input=b"", stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, timeout=15)
assert result.returncode == 0, (result.returncode, result.stderr)
reports = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith("{")]
expected = fixture_environment.copy()
for key in ("CODEX_CI", "CODEX_THREAD_ID", "CLAUDECODE", "AI_AGENT"):
    expected[key] = None
assert reports == [expected], "child environment did not follow shared identity/account policy"
print("PASS child preserves Linux PATH, HOME and account locations while stripping inherited run identity")

# An explicit argument recorder verifies integration without pretending to be an authenticated CLI.
import sqlite3
recorder = Path(folder) / "codex-argument-recorder"
recorder.write_text("#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd()}))\n")
recorder.chmod(0o700)
prompt = "- inspect this 'quoted' request; $(do-not-execute) 日本語"
result = subprocess.run([host, store, socket, "codex", folder, "/bin/sh", str(recorder), prompt],
                        input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
assert result.returncode == 0, (result.returncode, result.stderr)
reports = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith("{")]
assert len(reports) == 1, result.stdout
argv = reports[0]["argv"]
assert reports[0]["cwd"] == folder
assert argv[-2:] == ["--", prompt], argv
assert "--no-alt-screen" in argv
assert argv[argv.index("--ask-for-approval") + 1] == "untrusted"
assert argv[argv.index("--sandbox") + 1] == "read-only"
configs = [argv[i+1] for i, word in enumerate(argv[:-1]) if word == "--config"]
assert 'approvals_reviewer="user"' in configs, argv
assert 'check_for_update_on_startup=false' in configs, argv
with sqlite3.connect(str(Path(store) / "threading.db")) as database:
    rows = database.execute("SELECT id, kind, data FROM session").fetchall()
    assert len(rows) == 1 and rows[0][1] == "codex", rows
    payload = json.loads(rows[0][2])
    assert payload["permissionMode"] == "manual", payload
    assert payload["title"] == "", "fresh sessions must share the macOS unnamed policy"
    assert database.execute("SELECT value FROM app_state WHERE key='selectedSessionID'").fetchone()[0] == rows[0][0]
listing = subprocess.check_output([host, store, socket, "list"], text=True)
assert f"agent {rows[0][0]}" in listing, listing
print("PASS managed Codex command uses production permission flags and persists a selected agent session (recorder fixture)")
# The daemon's retained exited session must be attachable under the agent identity, not a terminal alias.
attached = subprocess.run([host, store, socket, "attach-agent", rows[0][0]], input=b"",
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
assert attached.returncode == 0, (attached.returncode, attached.stderr)
assert b'"argv"' in attached.stdout, attached.stdout
with sqlite3.connect(str(Path(store) / "threading.db")) as database:
    assert database.execute("SELECT COUNT(*) FROM session").fetchone()[0] == 1
    project_payload = json.loads(database.execute("SELECT data FROM project WHERE folder_path=?", (folder,)).fetchone()[0])
terminal_id = project_payload["terminals"][0]["id"]
refused = subprocess.run([host, store, socket, "attach-agent", terminal_id], input=b"",
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
assert refused.returncode != 0 and b"session is not in this store" in refused.stderr
print("PASS agent reattach reuses the persisted identity and refuses a project-terminal identity")

# Deliberately coalesce hello, output and an additive frame in a fake peer's first write.
# This is a protocol fixture, separate from the real daemon/PTY checks above.
import socket as socket_library
import threading
peer_path = str(Path(folder) / "hello-fixture.sock")
listener = socket_library.socket(socket_library.AF_UNIX, socket_library.SOCK_STREAM)
listener.bind(peer_path)
listener.listen(1)
listener.settimeout(15)
peer_errors = []
def framed(kind, payload, flags=0):
    return struct.pack("<BBHI", kind, flags, 0, len(payload)) + payload

def control(value):
    return framed(0, json.dumps(value).encode())

def read_control(connection):
    def exact(count):
        value = b""
        while len(value) < count:
            part = connection.recv(count - len(value))
            if not part:
                raise AssertionError("fixture peer closed early")
            value += part
        return value
    kind, _, _, length = struct.unpack("<BBHI", exact(8))
    assert kind == 0 and length <= 1024 * 1024
    return json.loads(exact(length))

def peer():
    try:
        with listener.accept()[0] as connection:
            connection.settimeout(15)
            hello = read_control(connection)
            assert hello["type"] == "hello"
            connection.sendall(framed(1, b"PREHELLO\n") + control(hello)
                               + control({"type": "future-fixture"}) + framed(1, b"STDERR\n", 2))
            spawn = read_control(connection)
            assert spawn["type"] == "spawn"
            connection.sendall(control({"type": "exited", "body": {
                "id": spawn["body"]["id"], "status": 0, "signalled": False}}))
    except BaseException as error:
        peer_errors.append(error)

worker = threading.Thread(target=peer, daemon=True)
worker.start()
try:
    result = subprocess.run([host, store + "-handshake", peer_path, "run", folder, "/bin/true"],
                            input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    worker.join(timeout=15)
    assert not worker.is_alive() and not peer_errors, peer_errors
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert result.stdout == b"PREHELLO\n", result.stdout
    assert b"STDERR\n" in result.stderr, result.stderr
    print("PASS host retains hello-batch output, routes stderr and skips additive control frames")
finally:
    listener.close()
    Path(peer_path).unlink(missing_ok=True)

# Traffic before hello must not restart the total handshake deadline.
slow_path = str(Path(folder) / "slow-hello.sock")
slow_listener = socket_library.socket(socket_library.AF_UNIX, socket_library.SOCK_STREAM)
slow_listener.bind(slow_path)
slow_listener.listen(1)
slow_listener.settimeout(10)
release_peer = threading.Event()
slow_errors = []
def slow_peer():
    try:
        with slow_listener.accept()[0] as connection:
            connection.settimeout(10)
            read_control(connection)
            if release_peer.wait(3):
                return
            connection.sendall(control({"type": "future-before-hello"}))
            release_peer.wait(10)
    except BaseException as error:
        slow_errors.append(error)
slow_worker = threading.Thread(target=slow_peer, daemon=True)
slow_worker.start()
started = time.monotonic()
try:
    result = subprocess.run([host, store + "-deadline", slow_path, "run", folder, "/bin/true"],
                            input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=7)
    elapsed = time.monotonic() - started
    assert result.returncode != 0 and 4 <= elapsed < 7, (result.returncode, elapsed)
    assert b"handshakeTimedOut" in result.stderr, result.stderr
finally:
    release_peer.set()
    slow_worker.join(timeout=10)
    slow_listener.close()
    Path(slow_path).unlink(missing_ok=True)
assert not slow_worker.is_alive() and not slow_errors, slow_errors
print("PASS pre-hello traffic does not extend the total handshake deadline")

# Exercise multiple shared-client callbacks and poll batches against the real daemon. No newline
# translation or terminal echo can hide dropped/duplicated bytes in this exact comparison.
stream_size = 2 * 1024 * 1024
result = subprocess.run([host, store + "-stream", socket, "run", folder, "/usr/bin/python3", "-c",
                         "import sys; sys.stdout.buffer.write(b'0123456789abcdef' * 131072); sys.stdout.buffer.flush()"],
                        input=b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
assert result.returncode == 0, (result.returncode, result.stderr)
assert result.stdout == b"0123456789abcdef" * (stream_size // 16), (len(result.stdout), result.stderr)
print("PASS shared-client host preserves an exact 2 MiB live PTY stream")
