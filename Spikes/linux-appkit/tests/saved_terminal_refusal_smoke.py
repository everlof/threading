"""Explicit saved-shell activation preserves identity and uncertain child ownership.

Controlled daemon peers exercise native Right/Enter navigation. They never start a process.
The source store is copied through SQLite backup and is never mutated.
"""
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


def control(connection, value):
    body = json.dumps(value).encode()
    connection.sendall(struct.pack('<BBHI', 0, 0, 0, len(body)) + body)


def receive(connection):
    def exact(size):
        result = b''
        while len(result) < size:
            part = connection.recv(size - len(result))
            assert part, 'native client closed before its control frame'
            result += part
        return result
    kind, flags, reserved, size = struct.unpack('<BBHI', exact(8))
    assert (kind, flags, reserved) == (0, 0, 0) and 0 < size <= 1024 * 1024
    return json.loads(exact(size))


class Fixture:
    def __init__(self, root, name, listening=True):
        self.root = root / name
        self.root.mkdir()
        self.store = self.root / 'store'
        self.store.mkdir()
        self.database = self.store / 'threading.db'
        source = Path(source_store) / 'threading.db'
        with sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True) as origin:
            with sqlite3.connect(self.database) as copy:
                origin.backup(copy)
                copy.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
                projects = [json.loads(row[0]) for row in copy.execute(
                    'SELECT data FROM project ORDER BY position')]
        self.project = next((row for row in projects if row.get('terminals')), None)
        assert self.project is not None, 'source fixture needs a project with a saved terminal'
        assert Path(self.project['folderPath']).is_dir(), 'fixture project directory must exist'
        # Right opens the most recent embedded terminal first, matching navigationSnapshot.
        self.identity = {'kind': 'projectTerminal', 'id': self.project['terminals'][-1]['id']}
        self.before = self.records()
        self.endpoint = str(self.root / 'peer.sock')
        assert len(self.endpoint.encode()) < 108, 'fixture UNIX socket path is too long'
        self.listener = None
        self.connections = []
        self.connection_count = 0
        self.spawn_count = 0
        self.process = None
        self.log_path = self.root / 'window.log'
        self.log = self.log_path.open('w+')
        if listening:
            self.listener = socket.socket(socket.AF_UNIX)
            self.listener.bind(self.endpoint)
            self.listener.listen(4)
            self.listener.settimeout(8)

    def records(self):
        with sqlite3.connect(self.database) as database:
            return tuple(tuple(database.execute(f'SELECT * FROM {table} ORDER BY id'))
                         for table in ('project', 'session'))

    def xdo(self, *args):
        return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                              text=True, timeout=4).stdout.strip()

    def title(self, title):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            assert self.process.poll() is None, 'native window exited before ' + title
            try:
                result = self.xdo('search', '--all', '--onlyvisible', '--pid',
                                  str(self.process.pid), '--name', '^' + re.escape(title) + '$')
                if result:
                    return result.splitlines()[0]
            except subprocess.CalledProcessError:
                pass
            time.sleep(.04)
        raise AssertionError('missing native title: ' + title)

    def key(self, key):
        self.xdo('windowfocus', '--sync', self.window, 'key', '--delay', '50', key)

    def start(self):
        self.process = subprocess.Popen([binary, '--app-project', str(self.store), self.endpoint,
                                         '/bin/sh', self.project['folderPath']],
                                        stdout=self.log, stderr=self.log)
        self.window = self.title('Threading experiment - ' + self.project['folderPath'])
        self.key('Right')
        self.title('Threading terminals - ' + self.project['folderPath'])

    def accepted(self):
        self.listener.settimeout(8)
        connection, _ = self.listener.accept()
        self.connections.append(connection)
        self.connection_count += 1
        connection.settimeout(5)
        hello = receive(connection)
        assert hello['type'] == 'hello', hello
        control(connection, hello)
        return connection

    def survey(self, available=True):
        connection = self.accepted()
        request = receive(connection)
        assert request == {'type': 'list'}, request
        if available:
            control(connection, {'type': 'sessions', 'body': []})
        # A closed query without a sessions reply is unavailable, never authoritative absence.
        connection.close()

    def spawn(self, refusal=None):
        connection = self.accepted()
        request = receive(connection)
        assert request['type'] == 'spawn', request
        body = request['body']
        assert body['id'] == self.identity, (body['id'], self.identity)
        assert body.get('replaceExisting') in (None, False), 'saved shell requested replacement'
        assert body['executable'] == '/bin/sh'
        self.spawn_count += 1
        if refusal is None:
            connection.close()  # Lost acknowledgement: the child might exist.
        else:
            control(connection, {'type': 'spawnRefused', 'body': {
                'id': self.identity, 'reason': refusal}})

    def unavailable(self):
        self.title('Threading terminal - unavailable')
        assert self.records() == self.before, 'saved terminal refusal rewrote project/session records'

    def back_to_picker(self):
        self.key('ctrl+shift+p')
        self.title('Threading terminals - ' + self.project['folderPath'])

    def no_connection(self):
        assert self.listener is not None
        self.listener.settimeout(.75)
        try:
            unexpected, _ = self.listener.accept()
        except TimeoutError:
            return
        unexpected.close()
        raise AssertionError('unexpected connection: refusal or uncertainty retried automatically')

    def close(self):
        try:
            if self.process is not None and self.process.poll() is None:
                self.process.kill()
            if self.process is not None:
                self.process.wait(timeout=5)
        finally:
            for connection in self.connections:
                connection.close()
            if self.listener is not None:
                self.listener.close()
            Path(self.endpoint).unlink(missing_ok=True)
            self.log.close()


def run(root, name, scenario, listening=True):
    fixture = Fixture(root, name, listening=listening)
    try:
        fixture.start()
        scenario(fixture)
        assert fixture.records() == fixture.before
        print('PASS saved terminal ' + name, flush=True)
    except BaseException:
        with fixture.log_path.open('rb') as log:
            log.seek(0, 2)
            log.seek(max(0, log.tell() - 16384))
            print(log.read().decode('utf-8', 'replace'), file=sys.stderr)
        raise
    finally:
        fixture.close()


def definitive_refusal(fixture):
    for reason in ('alreadyExists', 'executableUnavailable'):
        fixture.key('Return')
        fixture.survey()
        fixture.spawn(refusal=reason)
        fixture.unavailable()
        fixture.no_connection()
        fixture.back_to_picker()
    assert fixture.connection_count == 4 and fixture.spawn_count == 2


def lost_spawn_reply(fixture):
    fixture.key('Return')
    fixture.survey()
    fixture.spawn()
    fixture.unavailable()
    fixture.no_connection()
    fixture.back_to_picker()
    fixture.key('Return')
    fixture.unavailable()
    fixture.no_connection()
    assert fixture.connection_count == 2 and fixture.spawn_count == 1


def unavailable_survey(fixture):
    fixture.key('Return')
    fixture.survey(available=False)
    fixture.unavailable()
    fixture.no_connection()
    assert fixture.connection_count == 1 and fixture.spawn_count == 0


def missing_survey(fixture):
    fixture.key('Return')
    fixture.unavailable()
    assert fixture.connection_count == 0 and fixture.spawn_count == 0


with tempfile.TemporaryDirectory(prefix='saved-refusal-', dir=fixture_root) as temporary:
    root = Path(temporary)
    run(root, 'definitive', definitive_refusal)
    run(root, 'lost-reply', lost_spawn_reply)
    run(root, 'unavailable-survey', unavailable_survey)
    run(root, 'missing-survey', missing_survey, listening=False)
print('PASS saved shell retry requires explicit intent and fresh ownership evidence; '
      'typed identity and persisted record bytes stay unchanged')
