"""Late durable agent admission composes with imports, refusal, and a capped native picker."""
import json
import fcntl
import os
from pathlib import Path
import queue
import re
import socket
import sqlite3
import struct
import subprocess
import sys
import threading
import time
import uuid

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture) / 'agent-catalogue'
root.mkdir()
project = root / 'AgentCatalogue'
project.mkdir()
seed_store = root / 'seed-store'
home = root / 'home'
home.mkdir()
environment = dict(os.environ, HOME=str(home))
for name in ('THREADING_LINUX_CODEX_ACCOUNT', 'THREADING_LINUX_CLAUDE_ACCOUNT'):
    environment.pop(name, None)
# The production host supplies the current record/schema shape. Its isolated stand-in exits;
# the controlled native peers below never create a process or contact an agent provider.
subprocess.run([host, str(seed_store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true',
                'Catalogue seed'], input=b'', env=environment, capture_output=True,
               check=True, timeout=20)
with sqlite3.connect(seed_store / 'threading.db') as database:
    project_id, kind, active, payload = database.execute(
        'SELECT project_id, kind, last_active_at, data FROM session').fetchone()
    template = json.loads(payload)
    database.execute('DELETE FROM session')
    database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
    for position in range(512):
        identifier = str(uuid.uuid4()).upper()
        record = dict(template, id=identifier, title=f'Existing agent {position:03d}',
                      customTitle=None, terminalTitle='', hasLaunched=False)
        database.execute('INSERT INTO session '
                         '(id, project_id, position, kind, last_active_at, data) VALUES (?, ?, ?, ?, ?, ?)',
                         (identifier, project_id, position, kind, active, json.dumps(record)))
Atspi.init()


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


class Peer:
    """Hold only the creation handshake; surveys remain authoritative and immediately available."""
    def __init__(self, path):
        self.path = path
        assert len(str(path).encode()) < 108
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(path))
        self.listener.listen(4)
        self.listener.settimeout(.2)
        self.stop = threading.Event()
        self.release = threading.Event()
        self.hello = threading.Event()
        self.hello_at = None
        self.errors = queue.Queue()
        self.spawns = []
        self.connections = []
        self.workers = []
        self.acceptor = threading.Thread(target=self.accept, daemon=True)
        self.acceptor.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            first = not self.connections
            self.connections.append(connection)
            thread = threading.Thread(target=self.serve, args=(connection, first), daemon=True)
            self.workers.append(thread)
            thread.start()

    def serve(self, connection, first):
        try:
            connection.settimeout(6)
            hello = receive(connection)
            assert hello['type'] == 'hello', hello
            if first:
                self.hello_at = time.monotonic()
                self.hello.set()
                assert self.release.wait(4), 'fixture did not release creation within hello deadline'
            control(connection, hello)
            request = receive(connection)
            if first:
                assert request['type'] == 'spawn', request
                body = request['body']
                assert body['id']['kind'] == 'agentSession', body
                assert body.get('replaceExisting') in (None, False), body
                self.spawns.append(body)
                control(connection, {'type': 'spawnRefused', 'body': {
                    'id': body['id'], 'reason': 'executableUnavailable'}})
                # Keep the definitive refusal as the cause; do not race it with a closed link.
                self.stop.wait(30)
            else:
                assert request == {'type': 'list'}, request
                control(connection, {'type': 'sessions', 'body': []})
        except Exception as error:
            if not self.stop.is_set():
                self.errors.put(error)
        finally:
            connection.close()

    def check(self):
        if not self.errors.empty():
            raise self.errors.get()

    def close(self):
        self.stop.set()
        self.release.set()
        self.listener.close()
        for connection in self.connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        self.acceptor.join(timeout=1)
        for worker in self.workers:
            worker.join(timeout=1)
        self.path.unlink(missing_ok=True)


class Scenario:
    def __init__(self, name):
        self.name = name
        self.root = root / name
        self.root.mkdir()
        self.store = self.root / 'store'
        self.store.mkdir()
        with sqlite3.connect(seed_store / 'threading.db') as source:
            with sqlite3.connect(self.store / 'threading.db') as destination:
                source.backup(destination)
        self.before = self.records()
        self.peer = Peer(self.root / 'peer.sock')
        self.log_path = Path('out/agent-catalogue-' + name + '.log')
        self.log = self.log_path.open('w+')
        self.process = None
        self.chooser = None
        self.fresh_id = None
        self.additional = {}
        self.expected_count = 513

    def records(self):
        with sqlite3.connect(self.store / 'threading.db') as database:
            projects = tuple(database.execute('SELECT id, data FROM project ORDER BY position'))
            sessions = dict(database.execute('SELECT id, data FROM session'))
            return projects, sessions

    def eventually(self, read, label, timeout=12):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            self.peer.check()
            assert self.process.poll() is None, 'native window exited: ' + self.log_path.read_text()
            try:
                value = read()
                if value:
                    return value
            except Exception as error:
                last = error
            time.sleep(.03)
        raise AssertionError(f'{label}: {last}; {self.log_path.read_text()}')

    def xdo(self, *args):
        return subprocess.run(['xdotool', *args], capture_output=True, text=True,
                              check=True, timeout=3).stdout.strip()

    def title(self, value, pid=None, timeout=12):
        return self.eventually(lambda: self.xdo('search', '--all', '--onlyvisible', '--pid',
                              str(self.process.pid if pid is None else pid), '--name',
                              '^' + re.escape(value) + '$').splitlines()[0], value, timeout)

    def key(self, value, window=None):
        self.xdo('windowfocus', '--sync', str(self.window if window is None else window),
                 'key', '--delay', '30', value)

    def application(self):
        desktop = Atspi.get_desktop(0)
        for index in range(desktop.get_child_count()):
            candidate = desktop.get_child_at_index(index)
            if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == self.process.pid:
                return candidate
        return None

    def listed(self):
        frame = self.app.get_child_at_index(0)
        found = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
                 if frame.get_child_at_index(index).get_role_name() == 'list']
        assert len(found) == 1
        assert 1 <= found[0].get_child_count() <= 8
        return found[0]

    def start(self):
        self.process = subprocess.Popen([binary, '--app-claude', str(self.store), str(self.peer.path),
                                         '/bin/sh', '/bin/true'], env=environment,
                                        stdout=self.log, stderr=self.log)
        self.window = self.title('Threading experiment - ' + str(project))
        self.app = self.eventually(self.application, 'AT-SPI fixture application')

    def folder_pid(self):
        children = set()
        for task in list((Path('/proc') / str(self.process.pid) / 'task').iterdir())[:32]:
            try:
                children.update(int(value) for value in (task / 'children').read_text()[:4096].split())
            except FileNotFoundError:
                pass
        for pid in sorted(children)[:32]:
            try:
                if (Path('/proc') / str(pid) / 'comm').read_text().strip() == 'zenity':
                    return pid
            except FileNotFoundError:
                pass
        return None

    def open_folder(self, timeout=12):
        self.key('ctrl+shift+p')
        pid = self.eventually(self.folder_pid, 'owned GTK folder chooser', timeout)
        self.chooser = (pid, (Path('/proc') / str(pid) / 'stat').read_text().split()[21])
        return self.title('Add project folder', pid=pid, timeout=timeout)

    def submit_folder(self, dialog):
        subprocess.run(['xclip', '-selection', 'clipboard'], input=str(project), text=True,
                       check=True, timeout=3)
        self.key('ctrl+l', dialog)
        time.sleep(.15)
        self.key('ctrl+a', dialog)
        self.key('ctrl+v', dialog)
        time.sleep(.15)
        self.key('ctrl+a', dialog)
        self.key('ctrl+c', dialog)
        value = subprocess.check_output(['xclip', '-selection', 'clipboard', '-o'],
                                        text=True, timeout=3)
        assert Path(value).resolve() == project.resolve(), value
        self.key('Return', dialog)
        self.eventually(lambda: 'PROJECT_IMPORTED ' in self.log_path.read_text(),
                        'duplicate folder import snapshot completed')
        self.chooser = None
        self.title('Threading experiment - ' + str(project))

    def begin_creation(self):
        self.key('ctrl+shift+l')
        self.eventually(self.peer.hello.is_set, 'creation paused before persistence', timeout=3)
        assert self.records() == self.before, 'creation committed before controlled hello release'
        self.key('ctrl+shift+p')
        self.title('Threading experiment - ' + str(project), timeout=2)

    def release_creation(self):
        assert time.monotonic() - self.peer.hello_at < 4, 'fixture exceeded bounded handshake window'
        self.peer.release.set()
        spawn = self.eventually(lambda: self.peer.spawns[0] if self.peer.spawns else None,
                                'spawn request after durable creation')
        self.fresh_id = spawn['id']['id']
        assert spawn['cwd'] == str(project)
        records = self.records()
        assert records[0] == self.before[0], 'agent creation changed its project payload'
        assert set(records[1]) - set(self.before[1]) == {self.fresh_id}
        assert all(records[1][identifier] == payload for identifier, payload in self.before[1].items())
        assert len(records[1]) == 513
        self.eventually(lambda: 'FAILURE_FRAME ' in self.log_path.read_text(), 'definitive spawn refusal rendered')

    def check_picker(self, selected=None):
        def read():
            listing = self.listed()
            assert listing.get_name() == f'Saved agents (512 of {self.expected_count})', listing.get_name()
            assert listing.get_description() == 'Showing 1 through 8 of 512 items'
            rows = [listing.get_child_at_index(index) for index in range(listing.get_child_count())]
            ids = [row.get_accessible_id() for row in rows]
            assert len(ids) == len(set(ids)), ids
            assert ids.count(self.fresh_id) == 1 and ids[0] == self.fresh_id, ids
            assert rows[0].get_name().startswith('[Claude Code] New Session [' + self.fresh_id[:8] + ']')
            assert rows[0].get_name().endswith(' retained'), rows[0].get_name()
            chosen = listing.get_selection_iface().get_selected_child(0)
            assert chosen.get_accessible_id() == (self.fresh_id if selected is None else selected)
            return True
        self.eventually(read, 'unique capped admission and stable selected identity')

    def project_count(self):
        def read():
            listing = self.listed()
            assert listing.get_child_count() == 1
            row = listing.get_child_at_index(0)
            assert row.get_accessible_id() == project_id
            assert row.get_name() == f'AgentCatalogue [{self.expected_count} agents, 0 terminals] retained', row.get_name()
            return True
        self.eventually(read, 'authoritative project count after admission')

    def finish(self):
        assert len(self.peer.spawns) == 1
        self.peer.check()
        records = self.records()
        assert records[0] == self.before[0]
        assert len(records[1]) == self.expected_count
        assert all(records[1][identifier] == payload for identifier, payload in self.before[1].items())
        assert all(records[1][identifier] == payload for identifier, payload in self.additional.items())
        subprocess.run(['import', '-window', self.window,
                        'out/agent-catalogue-' + self.name + '.png'], check=True, timeout=5)
        self.key('alt+F4')
        assert self.process.wait(timeout=5) == 0

    def close(self):
        if self.chooser:
            pid, stamp = self.chooser
            try:
                if (Path('/proc') / str(pid) / 'stat').read_text().split()[21] == stamp:
                    os.kill(pid, 15)
            except FileNotFoundError:
                pass
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=5)
        self.peer.close()
        self.log.close()


def run(name, scenario):
    current = Scenario(name)
    try:
        current.start()
        scenario(current)
        current.finish()
    except BaseException:
        print(current.log_path.read_text()[-16384:], file=sys.stderr)
        raise
    finally:
        current.close()


def import_overlap(current, outside_projection=False):
    # Warm GTK once before the five-second shipping hello deadline starts.
    dialog = current.open_folder()
    current.key('Escape', dialog)
    current.eventually(lambda: 'PROJECT_IMPORT_CANCELLED' in current.log_path.read_text(), 'GTK warmup cancelled')
    current.chooser = None
    current.begin_creation()
    dialog = current.open_folder(timeout=2)
    current.release_creation()
    if outside_projection:
        # A later store update can contain the complete count while omitting this receipt's
        # row from its recent projection. Dedupe-by-visible-ID alone must not add to that count.
        with (current.store / 'host.lock').open('a+b') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with sqlite3.connect(current.store / 'threading.db') as database:
                timestamp, payload = database.execute(
                    'SELECT last_active_at, data FROM session WHERE id = ?', (current.fresh_id,)).fetchone()
                fresh = json.loads(payload)
                position = database.execute('SELECT MAX(position) + 1 FROM session').fetchone()[0]
                for offset in range(512):
                    identifier = str(uuid.uuid4()).upper()
                    delta = offset + 1000
                    record = dict(template, id=identifier, title=f'Later agent {offset:03d}',
                                  customTitle=None, terminalTitle='', hasLaunched=False,
                                  lastActiveAt=fresh['lastActiveAt'] + delta)
                    encoded = json.dumps(record)
                    database.execute('INSERT INTO session '
                                     '(id, project_id, position, kind, last_active_at, data) '
                                     'VALUES (?, ?, ?, ?, ?, ?)',
                                     (identifier, project_id, position + offset, kind, timestamp + delta, encoded))
                    current.additional[identifier] = encoded
                # Selected rows have their own indexed restoration slot. Clear this fixture
                # selection so it cannot smuggle the omitted fresh row back into the snapshot.
                database.execute("DELETE FROM app_state WHERE key = 'selectedSessionID'")
                recent = {row[0] for row in database.execute(
                    'SELECT id FROM session ORDER BY last_active_at DESC, position DESC LIMIT 512')}
                assert current.fresh_id not in recent and recent == set(current.additional)
        current.expected_count = 1025
    current.submit_folder(dialog)
    current.project_count()
    current.key('Left')
    current.title('Threading agents - ' + str(project))
    current.check_picker()


def selected_refusal(current):
    current.begin_creation()
    current.key('Left')
    current.title('Threading agents - ' + str(project), timeout=2)
    expected = current.listed().get_child_at_index(2).get_accessible_id()
    current.key('Down')
    current.key('Down')
    def selected():
        chosen = current.listed().get_selection_iface().get_selected_child(0).get_accessible_id()
        return chosen if chosen == expected else None
    chosen = current.eventually(selected, 'existing picker row selected before admission', timeout=1)
    assert chosen in current.before[1]
    current.release_creation()
    current.check_picker(selected=chosen)
    current.key('Escape')
    current.title('Threading experiment - ' + str(project))
    current.project_count()
    current.key('Left')
    current.title('Threading agents - ' + str(project))
    current.check_picker()


run('import-overlap', import_overlap)
run('refused-selected', selected_refusal)
run('import-outside-window', lambda current: import_overlap(current, outside_projection=True))
print('PASS late agent admission: duplicate import has one durable row and authoritative count; '
      'post-commit spawn refusal retains one capped picker row; selected identity survives insertion; '
      'receipt outside recent512 preserves authoritative1025 count', flush=True)
