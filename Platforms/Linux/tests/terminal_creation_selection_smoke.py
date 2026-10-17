"""New shell selection follows launch intent without stealing later sidebar navigation."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
root = Path(fixture) / f'terminal-selection-{scale}'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
Atspi.init()


class LaunchGate:
    """Delay the first real daemon handshake, before the worker creates its terminal record."""
    def __init__(self, path, delayed):
        self.path = str(path)
        assert len(self.path.encode()) < 108
        self.arrived = threading.Event()
        self.release = threading.Event()
        self.stop = threading.Event()
        self.errors = []
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(.1)
        if not delayed:
            self.release.set()
        self.thread = threading.Thread(target=self.relay, daemon=True)
        self.thread.start()

    def relay(self):
        try:
            while not self.stop.is_set():
                try:
                    client, _ = self.listener.accept()
                    break
                except TimeoutError:
                    continue
            else:
                return
            with client, socket.socket(socket.AF_UNIX) as server:
                self.arrived.set()
                assert self.release.wait(10), 'fixture never released the daemon handshake'
                server.connect(endpoint)
                while not self.stop.is_set():
                    readable, _, _ = select.select([client, server], [], [], .1)
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (server if source is client else client).sendall(data)
        except Exception as error:
            if not self.stop.is_set():
                self.errors.append(error)

    def close(self):
        self.stop.set()
        self.release.set()
        self.listener.close()
        self.thread.join(timeout=2)
        assert not self.thread.is_alive(), 'fixture relay did not stop'
        assert not self.errors, self.errors


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, timeout=5).strip()


def scenario(name, delayed):
    folder = root / name
    folder.mkdir()
    store = folder / 'store'
    for project in ('Alpha', 'Beta'):
        path = folder / project
        path.mkdir()
        subprocess.run([host, '--add-project', str(store), str(path)],
                       check=True, capture_output=True, timeout=10)
    with sqlite3.connect(store / 'threading.db') as database:
        project_ids = []
        for identity, payload in database.execute('SELECT id,data FROM project ORDER BY position').fetchall():
            value = json.loads(payload)
            assert value['isExpanded'] is True
            value['isExpanded'] = False
            database.execute('UPDATE project SET data=? WHERE id=?', (json.dumps(value), identity))
            project_ids.append(identity)
    gate = LaunchGate(folder / 'p.sock', delayed)
    process = None
    terminal_id = None
    log_path = output / f'{name}.log'

    def eventually(read, label):
        deadline = time.monotonic() + 12
        last = None
        while time.monotonic() < deadline:
            assert process.poll() is None, log_path.read_text()
            assert not gate.errors, gate.errors
            try:
                value = read()
                if value:
                    return value
            except Exception as error:
                last = error
            time.sleep(.03)
        raise AssertionError(f'{label}: {last}; {log_path.read_text()}')

    def application():
        desktop = Atspi.get_desktop(0)
        return next((desktop.get_child_at_index(index) for index in range(desktop.get_child_count())
                     if desktop.get_child_at_index(index).get_process_id() == process.pid), None)

    def children():
        frame = app.get_child_at_index(0)
        return [frame.get_child_at_index(index) for index in range(frame.get_child_count())]

    def selected_identity():
        listed = next(item for item in children() if item.get_role_name() == 'list')
        assert listed.get_name() == 'Projects' and listed.get_child_count() <= 32
        chosen = listed.get_selection_iface().get_selected_child(0)
        return chosen.get_accessible_id() if chosen else None

    def records():
        with sqlite3.connect(store / 'threading.db') as database:
            return [json.loads(payload) for payload, in database.execute('SELECT data FROM project ORDER BY position')]

    def key(value):
        xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)

    def sessions():
        return json.loads(subprocess.check_output([daemon, 'sessions', '--json', '--socket', endpoint],
                                                 text=True, timeout=5))

    try:
        with log_path.open('w') as log:
            process = subprocess.Popen([binary, '--app', str(store), gate.path, '/bin/sh'],
                                       stdout=log, stderr=log)
            app = eventually(application, 'native accessibility registration')
            eventually(lambda: selected_identity() == project_ids[0], 'initial Alpha selection')
            window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                            '--name', '^Threading experiment - ').splitlines()[0],
                                'native product window')
            key('Return')
            eventually(gate.arrived.is_set, 'shell worker reached the real daemon handshake')
            if delayed:
                assert records()[0]['terminals'] == [], 'receipt arrived before the controlled handshake'
                key('ctrl+shift+p')
                key('Down')
                eventually(lambda: selected_identity() == project_ids[1], 'newer Beta navigation')
                key('Escape')  # Returning focus to the terminal must not revive the old launch intent.
                gate.release.set()
            terminal_id = eventually(lambda: records()[0]['terminals'][0]['id'], 'durable terminal')
            eventually(lambda: any(item.get_accessible_id() == 'linux.page-title' and item.get_name() == 'sh'
                                   for item in children()), 'saved terminal header')
            eventually(lambda: any(item.get_role_name() == 'terminal'
                                   and item.get_state_set().contains(Atspi.StateType.FOCUSED)
                                   for item in children()), 'terminal keeps keyboard input')
            expected = project_ids[1] if delayed else terminal_id
            eventually(lambda: selected_identity() == expected, 'selection follows current user intent')
            eventually(lambda: 'FRAME ' in log_path.read_text() and
                       ('OUTLINE_EXPANSION_SAVED ' in log_path.read_text() or delayed), 'settled outline frame')
            values = records()
            assert values[0]['isExpanded'] is (not delayed)
            assert values[1]['isExpanded'] is False and values[1]['terminals'] == []
            assert 'OUTLINE_EXPANSION_REFUSED' not in log_path.read_text()
            if delayed:
                assert 'OUTLINE_EXPANSION_PENDING' not in log_path.read_text()
            owner = eventually(lambda: next((row for row in sessions()
                                            if row['id'] == 'terminal-' + terminal_id and row['attached']), None),
                               'one attached real daemon child')
            key('ctrl+shift+p')
            eventually(lambda: selected_identity() == expected, 'focus return preserves selected row')
            subprocess.run(['import', '-window', window, str(output / f'{name}.png')], check=True, timeout=5)
            assert next(row for row in sessions() if row['id'] == owner['id'])['pid'] == owner['pid']
            key('alt+F4')
            assert process.wait(timeout=5) == 0
            print(f'PASS shell creation selection scale={scale} delayed={delayed}: exact child, focus and newer navigation', flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        try:
            if terminal_id:
                for row in sessions():
                    if row['id'] == 'terminal-' + terminal_id and row.get('exit') is None:
                        os.kill(row['pid'], signal.SIGTERM)
        finally:
            gate.close()


scenario('created', False)
scenario('newer-navigation', True)
