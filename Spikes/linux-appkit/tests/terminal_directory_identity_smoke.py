"""Native cwd metadata needs the daemon's process incarnation and live OSC 7 evidence."""
import copy
import json
from pathlib import Path
import re
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time

binary, source_store, fixture_root = sys.argv[1:]


def frame(connection, kind, body):
    connection.sendall(struct.pack('<BBHI', kind, 0, 0, len(body)) + body)


def control(connection, value):
    frame(connection, 0, json.dumps(value).encode())


def receive(connection):
    def exact(length):
        result = b''
        while len(result) < length:
            chunk = connection.recv(length - len(result))
            assert chunk, 'client closed before its control frame'
            result += chunk
        return result
    kind, flags, reserved, length = struct.unpack('<BBHI', exact(8))
    assert (kind, flags, reserved) == (0, 0, 0) and 0 < length <= 1024 * 1024
    return json.loads(exact(length))


def osc7(path):
    return b'\x1b]7;' + path.as_uri().encode() + b'\x07'


def osc_title(value):
    return b'\x1b]0;' + value.encode() + b'\x07'


def run(root, name, start_time):
    directory = root / name
    directory.mkdir()
    store = directory / 'store'
    store.mkdir()
    database_path = store / 'threading.db'
    source_path = (Path(source_store) / 'threading.db').resolve()
    with sqlite3.connect(source_path.as_uri() + '?mode=ro', uri=True) as source:
        with sqlite3.connect(database_path) as destination:
            source.backup(destination)
            destination.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
            projects = [json.loads(row[0]) for row in destination.execute(
                'SELECT data FROM project ORDER BY position')]
    project = next((value for value in projects if value.get('terminals')), None)
    assert project is not None, 'source fixture must contain a saved terminal'
    terminal = project['terminals'][0]
    identity = {'kind': 'projectTerminal', 'id': terminal['id']}
    unrelated = directory / 'unrelated-process'
    historical = directory / 'historical-only'
    straddled = directory / 'historical-ending-live'
    live_path = directory / 'live 日本語 directory'
    for path in (unrelated, historical, straddled, live_path):
        path.mkdir()
        assert str(path) != terminal['currentDirectory']
    endpoint = str(directory / 'peer.sock')
    assert len(endpoint.encode()) < 108
    log_path = Path('out/terminal-directory-identity-' + name + '.log')
    process = None
    other_process = None
    connection = None

    def records():
        with sqlite3.connect(database_path) as database:
            return tuple(tuple(database.execute(f'SELECT * FROM {table} ORDER BY id'))
                         for table in ('project', 'session'))

    before = records()

    def check_alive():
        assert process.poll() is None, 'native window exited: ' + log_path.read_text()[-16384:]
        assert other_process.poll() is None, 'unrelated process ended before the observation'

    def title(value):
        deadline = time.monotonic() + 15
        pattern = '^Threading terminal - ' + re.escape(value) + r' \[history cut\]$'
        while time.monotonic() < deadline:
            check_alive()
            result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible', '--pid',
                                     str(process.pid), '--name', pattern],
                                    capture_output=True, text=True, timeout=4)
            if result.returncode == 0:
                return result.stdout.splitlines()[0]
            time.sleep(.05)
        raise AssertionError('missing native title ' + value + ': ' + log_path.read_text()[-16384:])

    def unchanged_for_ticks():
        # Three seconds covers more than two one-second metadata sampling/coalescing ticks.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            check_alive()
            assert records() == before, 'untrusted process or historical OSC changed stored records'
            time.sleep(.1)

    def assert_live_directory():
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            check_alive()
            with sqlite3.connect(database_path) as database:
                payload = database.execute('SELECT data FROM project WHERE id = ?',
                                           (project['id'],)).fetchone()[0]
                current = json.loads(payload)
            expected = copy.deepcopy(project)
            expected['terminals'][0]['currentDirectory'] = str(live_path)
            if current == expected:
                # All other project/session rows must remain byte-identical.
                after = records()
                assert after[1] == before[1]
                assert [row for row in after[0] if row[0] != project['id']] == [
                    row for row in before[0] if row[0] != project['id']]
                return
            time.sleep(.05)
        raise AssertionError('live OSC 7 did not persist independently of /proc sampling: '
                             + log_path.read_text()[-16384:])

    with socket.socket(socket.AF_UNIX) as listener, log_path.open('w+') as log:
        listener.bind(endpoint)
        listener.listen(1)
        listener.settimeout(12)
        try:
            other_process = subprocess.Popen(['/bin/sleep', '120'], cwd=unrelated,
                                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.DEVNULL)
            assert Path(f'/proc/{other_process.pid}/cwd').resolve() == unrelated.resolve()
            process = subprocess.Popen([binary, '--attach', str(store), endpoint, terminal['id']],
                                       stdout=log, stderr=log)
            connection, _ = listener.accept()
            connection.settimeout(5)
            hello = receive(connection)
            assert hello['type'] == 'hello', hello
            control(connection, hello)
            attach = receive(connection)
            assert attach['type'] == 'attach' and attach['body']['id'] == identity, attach

            historical_osc = osc7(historical)
            crossing_osc = osc7(straddled)
            # One complete historical sequence and another that starts in replay but ends live.
            replay = b'\x18' + historical_osc + crossing_osc[:-1]
            attached = {'id': identity, 'pid': other_process.pid,
                        'grid': {'cols': 80, 'rows': 24, 'xpixel': 0, 'ypixel': 0},
                        'replay': {'mode': 'cut'}, 'totalBytesWritten': len(replay),
                        'replayByteCount': len(replay)}
            if start_time is not None:
                attached['startTime'] = start_time
            control(connection, {'type': 'attached', 'body': attached})
            cut = 1 + len(historical_osc) // 2
            frame(connection, 1, replay[:cut])
            frame(connection, 1, replay[cut:])
            frame(connection, 1, crossing_osc[-1:] + osc_title('IDENTITY REPLAY'))
            window = title('IDENTITY REPLAY')
            unchanged_for_ticks()

            # Rejected live remote/relative reports must not become metadata either.
            invalid = (b'\x1b]7;file://remote.invalid' + live_path.as_posix().encode() + b'\x07'
                       + b'\x1b]7;relative-directory\x07')
            frame(connection, 1, invalid + osc_title('IDENTITY INVALID'))
            title('IDENTITY INVALID')
            unchanged_for_ticks()

            valid = osc7(live_path)
            split = len(valid) // 2
            frame(connection, 1, valid[:split])
            frame(connection, 1, valid[split:] + osc_title('IDENTITY LIVE'))
            title('IDENTITY LIVE')
            assert_live_directory()
            subprocess.run(['import', '-window', window,
                            'out/terminal-directory-identity-' + name + '.png'],
                           check=True, timeout=5)
            print('PASS attached ' + name + ': unrelated PID cannot change cwd; historical/split-replay '
                  'and invalid OSC 7 ignored; fragmented live local OSC 7 persists', flush=True)
        except BaseException:
            print(log_path.read_text()[-16384:], file=sys.stderr)
            raise
        finally:
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            if connection is not None:
                connection.close()
            if other_process is not None:
                if other_process.poll() is None:
                    other_process.terminate()
                other_process.wait(timeout=5)
            Path(endpoint).unlink(missing_ok=True)


with tempfile.TemporaryDirectory(prefix='cwd-id-', dir=fixture_root) as temporary:
    root = Path(temporary).resolve()
    run(root, 'missing-time', None)
    run(root, 'wrong-time', {'seconds': 1, 'microseconds': 0})
print('PASS native attach incarnation, replay boundary and live cwd metadata integration')
