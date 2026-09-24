"""Native window exit ordering against a controlled wire peer; real PTY lives in window-smoke."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

binary = sys.argv[1]


def send(connection, value):
    body = json.dumps(value).encode()
    connection.sendall(struct.pack('<BBHI', 0, 0, 0, len(body)) + body)


def receive(connection):
    def exact(size):
        data = b''
        while len(data) < size:
            part = connection.recv(size - len(data))
            assert part, 'unexpected peer close'
            data += part
        return data
    kind, _, _, size = struct.unpack('<BBHI', exact(8))
    assert size <= 1024 * 1024
    body = exact(size)
    return kind, json.loads(body) if kind == 0 else body


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def await_title(process, title):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        assert process.poll() is None, 'window closed before authoritative exit'
        result = xdo('search', '--name', '^' + title + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.03)
    raise AssertionError('missing window title: ' + title)


for scenario in ('exit', 'timeout', 'other-error', 'disconnect', 'wrong-identity'):
    with tempfile.TemporaryDirectory(prefix='window-exit-') as root:
        path = str(Path(root) / 'peer.sock')
        with socket.socket(socket.AF_UNIX) as listener, open(Path(root) / 'window.log', 'w+') as log:
            listener.bind(path)
            listener.listen(1)
            listener.settimeout(8)
            process = subprocess.Popen([binary, '--terminal', root + '/store', path, root, '/bin/true'],
                                       stdout=log, stderr=log)
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(5)
                    _, hello = receive(connection)
                    assert hello['type'] == 'hello'
                    send(connection, hello)
                    _, spawn = receive(connection)
                    assert spawn['type'] == 'spawn'
                    identity = spawn['body']['id']
                    send(connection, {'type': 'spawned', 'body': {'id': identity, 'pid': 123,
                         'startTime': {'seconds': 1, 'microseconds': 0}}})
                    window = await_title(process, 'Threading terminal - running')
                    assert xdo('windowfocus', window, 'key', 'x').returncode == 0
                    while True:
                        kind, value = receive(connection)
                        if kind == 2:
                            assert value == b'x', value
                            break
                        assert value['type'] == 'resize', value
                    refusal = {'type': 'error', 'body': {'code': 'sessionExited',
                               'detail': 'resize' if scenario == 'other-error' else 'input'}}
                    started = time.monotonic()
                    send(connection, refusal)
                    if scenario == 'exit':
                        time.sleep(.2)
                        assert process.poll() is None
                        send(connection, {'type': 'exited', 'body': {
                            'id': identity, 'status': 7, 'signalled': False}})
                        await_title(process, 'Threading terminal - exited 7')
                        # The pending timeout must not destroy the completed window.
                        time.sleep(5.2)
                        assert process.poll() is None
                        assert xdo('windowfocus', window, 'key', 'alt+F4').returncode == 0
                        assert process.wait(timeout=3) == 0
                    elif scenario == 'timeout':
                        for _ in range(3):
                            time.sleep(1)
                            send(connection, refusal)
                        assert process.wait(timeout=3.5) != 0
                        assert 4.8 <= time.monotonic() - started < 6.5
                    else:
                        if scenario == 'disconnect':
                            connection.shutdown(socket.SHUT_RDWR)
                        elif scenario == 'wrong-identity':
                            wrong = dict(identity, id='00000000-0000-0000-0000-000000000000')
                            send(connection, {'type': 'exited', 'body': {
                                'id': wrong, 'status': 7, 'signalled': False}})
                        assert process.wait(timeout=3) != 0
                log.seek(0)
                output = log.read()
                expected = {'timeout': 'timed out waiting for child exit',
                            'other-error': 'PTY:', 'disconnect': 'PTY connection closed',
                            'wrong-identity': 'exit identity mismatch'}
                if scenario in expected:
                    assert expected[scenario] in output, output
                print('PASS native terminal exit ordering:', scenario, flush=True)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
