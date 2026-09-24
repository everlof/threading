"""A lost spawn reply leaves child ownership uncertain: native retry must refuse it."""
import json
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time

binary, source_store = sys.argv[1:]


def control(connection, value):
    body = json.dumps(value).encode()
    connection.sendall(struct.pack('<BBHI', 0, 0, 0, len(body)) + body)


def receive(connection):
    def exact(size):
        data = b''
        while len(data) < size:
            part = connection.recv(size - len(data))
            assert part
            data += part
        return data
    kind, _, _, size = struct.unpack('<BBHI', exact(8))
    assert kind == 0 and size <= 1024 * 1024
    return json.loads(exact(size))


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def title(pattern):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        assert process.poll() is None
        result = xdo('search', '--name', pattern)
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.04)
    raise AssertionError('missing native title: ' + pattern)


with tempfile.TemporaryDirectory(prefix='uncertain-spawn-') as root:
    with sqlite3.connect(str(Path(source_store) / 'threading.db')) as source:
        with sqlite3.connect(str(Path(root) / 'threading.db')) as destination:
            source.backup(destination)
    with socket.socket(socket.AF_UNIX) as listener, open(Path(root) / 'window.log', 'w+') as log:
        endpoint = str(Path(root) / 'peer.sock')
        listener.bind(endpoint)
        listener.listen(1)
        listener.settimeout(8)
        process = subprocess.Popen([binary, '--app', root, endpoint, '/bin/sh'], stdout=log, stderr=log)
        try:
            window = title('^Threading experiment - /')
            assert xdo('windowfocus', window, 'key', 'Return').returncode == 0
            with listener.accept()[0] as connection:
                connection.settimeout(5)
                hello = receive(connection)
                assert hello['type'] == 'hello'
                control(connection, hello)
                assert receive(connection)['type'] == 'spawn'
                # Drop the connection after receiving spawn, without an authoritative result.
            title('^Threading terminal - unavailable$')
            assert xdo('key', 'ctrl+shift+p').returncode == 0
            title('^Threading experiment - /')
            assert xdo('key', 'ctrl+shift+n').returncode == 0
            title('^Threading experiment - terminal may still be running$')
            listener.settimeout(.3)
            try:
                unexpected, _ = listener.accept()
            except TimeoutError:
                pass
            else:
                unexpected.close()
                raise AssertionError('uncertain child was replaced')
            assert xdo('key', 'Escape').returncode == 0
            assert process.wait(timeout=5) == 0
            print('PASS native replacement refuses an unacknowledged spawn after disconnect', flush=True)
        except BaseException:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
