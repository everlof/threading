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
        self.forwarders = []
        if not delayed:
            self.release.set()
        self.thread = threading.Thread(target=self.relay, daemon=True)
        self.thread.start()

    def relay(self):
        try:
            while not self.stop.is_set():
                try:
                    client, _ = self.listener.accept()
                except TimeoutError:
                    continue
                self.arrived.set()
                forwarder = threading.Thread(target=self.forward, args=(client,), daemon=True)
                self.forwarders.append(forwarder)
                forwarder.start()
        except Exception as error:
            if not self.stop.is_set():
                self.errors.append(error)

    def forward(self, client):
        try:
            with client, socket.socket(socket.AF_UNIX) as server:
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
        for forwarder in self.forwarders:
            forwarder.join(timeout=2)
            assert not forwarder.is_alive(), 'fixture connection did not stop'
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

    def terminal_label():
        listed = next(item for item in children() if item.get_role_name() == 'list')
        return next((listed.get_child_at_index(index).get_name()
                     for index in range(listed.get_child_count())
                     if listed.get_child_at_index(index).get_accessible_id() == terminal_id), None)

    def terminal_row():
        listed = next(item for item in children() if item.get_role_name() == 'list'
                      and item.get_name() == 'Projects')
        return next((listed.get_child_at_index(index) for index in range(listed.get_child_count())
                     if listed.get_child_at_index(index).get_accessible_id() == terminal_id), None)

    def terminal_menu():
        return next((item for item in children() if item.get_role_name() == 'list'
                     and item.get_name() == 'Terminal actions'), None)

    def rename_prompt():
        desktop = Atspi.get_desktop(0)
        for index in range(desktop.get_child_count()):
            candidate = desktop.get_child_at_index(index)
            if candidate.get_name() != 'Threading Linux' or candidate.get_process_id() == process.pid:
                continue
            frame = candidate.get_child_at_index(0)
            for child_index in range(frame.get_child_count()):
                panel = frame.get_child_at_index(child_index)
                if panel.get_accessible_id() == 'linux.prompt.rename-terminal':
                    return panel
        return None

    def menu_item(title):
        menu = eventually(terminal_menu, 'terminal row menu')
        return next((menu.get_child_at_index(index) for index in range(menu.get_child_count())
                     if menu.get_child_at_index(index).get_name() == title), None)

    def open_terminal_menu():
        row = eventually(terminal_row, 'terminal row before menu')
        bounds = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, bounds.x + bounds.width // 2,
            bounds.y + bounds.height // 2)
        xdo('click', '--window', window, 3)
        return eventually(terminal_menu, 'terminal row menu')

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
            if not delayed:
                xdo('windowfocus', '--sync', window, 'type', '--clearmodifiers', 'sleep 6')
                key('Return')
                eventually(lambda: 'command running' in (terminal_label() or ''),
                           'foreground process status from the real daemon')
                subprocess.run(['import', '-window', window, str(output / 'foreground.png')],
                               check=True, timeout=5)
                eventually(lambda: terminal_label() and 'command running' not in terminal_label(),
                           'foreground status clears when the shell resumes')
            key('ctrl+shift+p')
            eventually(lambda: selected_identity() == expected, 'focus return preserves selected row')
            subprocess.run(['import', '-window', window, str(output / f'{name}.png')], check=True, timeout=5)
            assert next(row for row in sessions() if row['id'] == owner['id'])['pid'] == owner['pid']
            if not delayed:
                row = eventually(terminal_row, 'terminal row for hover action')
                bounds = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                previous_frames = log_path.read_text().count('OUTLINE_FRAME')
                xdo('mousemove', '--window', window, bounds.x + bounds.width - 28 * scale,
                    bounds.y + bounds.height // 2)
                eventually(lambda: log_path.read_text().count('OUTLINE_FRAME') > previous_frames,
                           'hover action repainted')
                subprocess.run(['import', '-window', window, str(output / 'terminal-action-hover.png')],
                               check=True, timeout=5)
                xdo('click', '--window', window, 1)
                eventually(terminal_menu, 'production terminal action opens shared menu')
                subprocess.run(['import', '-window', window, str(output / 'terminal-menu.png')],
                               check=True, timeout=5)
                assert menu_item('Rename Terminal…').get_action_iface().do_action(1)
                prompt = eventually(rename_prompt, 'terminal rename prompt')
                assert prompt.get_name() == 'Rename Terminal'
                field = next(prompt.get_child_at_index(index)
                             for index in range(prompt.get_child_count())
                             if prompt.get_child_at_index(index).get_accessible_id()
                             == 'linux.prompt.terminal-name')
                assert field.get_editable_text_iface().set_text_contents('Renamed café 日本語')
                subprocess.run(['import', '-window', 'root', str(output / 'rename-terminal.png')],
                               check=True, timeout=5)
                confirm = next(prompt.get_child_at_index(index)
                               for index in range(prompt.get_child_count())
                               if prompt.get_child_at_index(index).get_accessible_id()
                               == 'linux.prompt.create')
                assert confirm.get_action_iface().do_action(0)
                eventually(lambda: records()[0]['terminals'][0].get('customTitle')
                           == 'Renamed café 日本語', 'terminal rename persisted')
                eventually(lambda: 'Renamed café 日本語' in (terminal_label() or ''),
                           'renamed terminal row')
                open_terminal_menu()
                assert menu_item('Copy').get_action_iface().do_action(1)
                assert menu_item('Threading ID').get_action_iface().do_action(1)
                eventually(lambda: subprocess.check_output(
                    ['xclip', '-selection', 'clipboard', '-o'], text=True, timeout=5,
                    stderr=subprocess.DEVNULL).strip()
                    == terminal_id.lower(), 'terminal identity copied')
                open_terminal_menu()
                assert menu_item('Copy').get_action_iface().do_action(1)
                assert menu_item('Worktree Path').get_action_iface().do_action(1)
                eventually(lambda: subprocess.check_output(
                    ['xclip', '-selection', 'clipboard', '-o'], text=True, timeout=5,
                    stderr=subprocess.DEVNULL).strip()
                    == str(folder / 'Alpha'), 'current terminal worktree copied')
                open_terminal_menu()
                assert menu_item('Close Terminal').get_action_iface().do_action(1)
                eventually(lambda: records()[0]['terminals'] == [],
                           'terminal close removed durable row')
                eventually(lambda: selected_identity() == project_ids[0],
                           'terminal close selected owning project')
                eventually(lambda: next((item for item in sessions()
                    if item['id'] == owner['id'] and item.get('exit') is not None), None),
                    'terminal close stopped daemon child')
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
