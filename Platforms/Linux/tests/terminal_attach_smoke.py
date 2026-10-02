"""Reopen a graphical terminal after its first window process ends; no respawn or resize."""
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time

binary, host, endpoint, folder, child = sys.argv[1:]
store = folder + '/attach-store'


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def title(expected):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert process.poll() is None, 'terminal window exited early'
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.04)
    raise AssertionError('missing title: ' + expected)


def key(value):
    assert xdo('windowfocus', window, 'key', value).returncode == 0


def listing():
    return subprocess.run([host, store, endpoint, 'list'], check=True, capture_output=True,
                          text=True, timeout=8).stdout


with open(Path(folder) / 'attach-window.log', 'w+') as log:
    process = subprocess.Popen([binary, '--terminal', store, endpoint, folder,
                               '/usr/bin/timeout', '120', '/usr/bin/python3', child], stdout=log, stderr=log)
    try:
        window = title('Threading terminal - ATTACH READY')
        assert xdo('windowsize', window, '960', '660').returncode == 0
        deadline = time.monotonic() + 10
        while 'TERMINAL_FRAME 960x660' not in (Path(folder) / 'attach-window.log').read_text():
            assert time.monotonic() < deadline
            time.sleep(.04)
        key('g')
        title('Threading terminal - ATTACH DETACHED')
        original = json.loads((Path(folder) / 'attach-child.json').read_text())
        saved = listing()
        ids = [line.strip().split('\t')[0] for line in saved.splitlines() if line.startswith('  ')]
        assert len(ids) == 1, saved
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        os.kill(original['pid'], 0)
        process = subprocess.Popen([binary, '--attach', store, endpoint, ids[0]], stdout=log, stderr=log)
        window = title('Threading terminal - ATTACH DETACHED [history cut]')
        geometry = xdo('getwindowgeometry', '--shell', window).stdout
        assert 'WIDTH=960\n' in geometry and 'HEIGHT=660\n' in geometry, geometry
        assert json.loads((Path(folder) / 'attach-child.json').read_text()) == original
        key('p')
        title('Threading terminal - ATTACH LIVE [history cut]')
        subprocess.run(['import', '-window', window, 'out/terminal-reattached.png'], check=True, timeout=5)
        pixels = subprocess.run(['convert', 'out/terminal-reattached.png', '-depth', '8', 'rgb:-'],
                                capture_output=True, check=True, timeout=5).stdout
        assert len(pixels) == 960 * 660 * 3
        assert pixels[-3:] == bytes([0x17, 0x19, 0x1d]), 'renderer kept the old window surface extent'
        assert sum(value > 100 for value in pixels[:960 * 88 * 3:3]) > 300, 'replayed text is not visible'
        key('q')
        title('Threading terminal - exited 7 [history cut]')
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        assert listing() == saved, 'attach changed the durable terminal records'
        print('PASS native reattach: same child, adopted grid without resize, suppressed replay queries, live replies and exit 7', flush=True)
    except BaseException:
        log.seek(0)
        print(log.read(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        Path('out/terminal-attach-session.log').write_text((Path(folder) / 'attach-window.log').read_text())

# An older/invalid/incomplete replay cannot be presented as a live restored terminal.
def receive(connection):
    def exact(size):
        result = b''
        while len(result) < size:
            part = connection.recv(size - len(result))
            assert part
            result += part
        return result
    kind, _, _, size = struct.unpack('<BBHI', exact(8))
    assert kind == 0 and size <= 1024 * 1024
    return json.loads(exact(size))


def send(connection, value):
    body = json.dumps(value).encode()
    connection.sendall(struct.pack('<BBHI', 0, 0, 0, len(body)) + body)


for scenario in ('missing-boundary', 'invalid-boundary', 'incomplete'):
    path = folder + '/' + scenario + '.sock'
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(path)
        listener.listen(1)
        listener.settimeout(8)
        process = subprocess.Popen([binary, '--attach', store, path, ids[0]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with listener.accept()[0] as connection:
                connection.settimeout(8)
                hello = receive(connection)
                send(connection, hello)
                request = receive(connection)
                assert request['type'] == 'attach'
                body = {'id': request['body']['id'], 'pid': 123,
                        'grid': {'cols': 80, 'rows': 24, 'xpixel': 0, 'ypixel': 0},
                        'replay': {'mode': 'cut'}, 'totalBytesWritten': 100}
                if scenario != 'missing-boundary':
                    body['replayByteCount'] = -1 if scenario == 'invalid-boundary' else 100
                started = time.monotonic()
                send(connection, {'type': 'attached', 'body': body})
                output, error = process.communicate(timeout=7)
                assert process.returncode != 0 and b'TERMINAL_FRAME' not in output, (output, error)
                if scenario == 'incomplete':
                    assert 4 <= time.monotonic() - started < 7
                    assert b'timed out waiting for terminal replay' in error, error
                else:
                    assert b'valid replay boundary' in error, error
            print('PASS graphical attach refusal:', scenario, flush=True)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
