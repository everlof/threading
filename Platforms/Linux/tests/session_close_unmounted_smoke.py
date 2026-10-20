"""Installed Close Session route for a daemon child that this window never attached."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'session-close-unmounted'
root.mkdir()
store = root / 'store'
project = root / 'SavedAgent'
project.mkdir()
home = root / 'home'
home.mkdir()
environment = dict(os.environ, HOME=str(home))
input_log = root / 'agent-input.bin'
environment['THREADING_TEST_INPUT_LOG'] = str(input_log)
agent = root / 'fake-codex'
agent.write_text('#!/bin/sh\nstty raw -echo\nprintf "UNMOUNTED LIVE TARGET\\r\\n"\n'
                 'exec /bin/cat >> "$THREADING_TEST_INPUT_LOG"\n')
agent.chmod(0o755)
seed_log = (root / 'seed-host.log').open('w+')
seed = subprocess.Popen([host, str(store), endpoint, 'codex', str(project), '/bin/sh',
                         str(agent), 'Unmounted live session'], stdin=subprocess.PIPE,
                        stdout=seed_log, stderr=seed_log, env=environment)
seed.stdin.close()
deadline = time.monotonic() + 12
while time.monotonic() < deadline:
    assert seed.poll() is None, 'synthetic agent exited: ' + (root / 'seed-host.log').read_text()
    if (store / 'threading.db').exists() and input_log.exists():
        with sqlite3.connect(store / 'threading.db') as database:
            if database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 1:
                break
    time.sleep(.05)
else:
    raise AssertionError('synthetic agent did not become live: ' + (root / 'seed-host.log').read_text())
seed.terminate()
seed.wait(timeout=5)
seed_log.close()
with sqlite3.connect(store / 'threading.db') as database:
    session_id, session_payload = database.execute('SELECT id, data FROM session').fetchone()
    session_record = json.loads(session_payload)
    session_record['customTitle'] = 'Unmounted live session'
    database.execute('UPDATE session SET data=? WHERE id=?',
                     (json.dumps(session_record, separators=(',', ':')), session_id))
    project_id, payload = database.execute('SELECT id, data FROM project').fetchone()
    record = json.loads(payload)
    record['isExpanded'] = True
    database.execute('UPDATE project SET data=? WHERE id=?',
                     (json.dumps(record, separators=(',', ':')), project_id))
    database.execute("DELETE FROM app_state WHERE key='selectedSessionID'")

log_path = Path(evidence) / 'session-close-unmounted-window.log'
log = log_path.open('w+')
process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                            '/bin/sh', '/bin/true'], env=environment,
                           stdout=log, stderr=log)
Atspi.init()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, 'native window exited: ' + log_path.read_text()[-10000:]
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()[-10000:]}')


def xdo(*args):
    result = subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, f'xdotool {args}: {result.stderr}'
    return result.stdout.strip()


def children():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() != 'Threading Linux' or app.get_process_id() != process.pid:
            continue
        frame = app.get_child_at_index(0)
        return [frame.get_child_at_index(child) for child in range(frame.get_child_count())]
    return []


def saved_row():
    listing = next((item for item in children()
                    if item.get_role_name() == 'list' and item.get_name() == 'Projects'), None)
    if listing is None:
        return None
    return next((listing.get_child_at_index(index)
                 for index in range(listing.get_child_count())
                 if listing.get_child_at_index(index).get_accessible_id() == session_id), None)


def session_menu():
    return next((item for item in children()
                 if item.get_role_name() == 'list' and item.get_name() == 'Session actions'), None)


def close_prompt():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() != 'Threading Linux' or app.get_process_id() == process.pid:
            continue
        frame = app.get_child_at_index(0)
        return next((frame.get_child_at_index(child)
                     for child in range(frame.get_child_count())
                     if frame.get_child_at_index(child).get_accessible_id()
                     == 'linux.prompt.close-session'), None)
    return None


def agent_stopped():
    daemon = str(Path(binary).with_name('threading-ptyd'))
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            check=True, capture_output=True, text=True, timeout=5)
    return any(item['id'] == session_id and item.get('exit') is not None
               for item in json.loads(result.stdout))


try:
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                    str(process.pid)).splitlines()[0], 'installed window')
    row = eventually(saved_row, 'saved agent row without restore selection')
    assert all(item.get_role_name() != 'terminal' for item in children()), \
        'window attached the daemon child before the menu opened'
    initial_input = input_log.read_bytes()
    bounds = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, str(bounds.x + bounds.width // 2),
        str(bounds.y + bounds.height // 2), 'click', '3')

    def close_action():
        menu = session_menu()
        if menu is None:
            return None
        return next((menu.get_child_at_index(index)
                     for index in range(menu.get_child_count())
                     if menu.get_child_at_index(index).get_name() == 'Close Session'), None)

    close = eventually(close_action, 'daemon running status reached the open row menu')
    assert all(item.get_role_name() != 'terminal' for item in children()), \
        'the menu attached the daemon child'
    subprocess.run(['import', '-window', window,
                    str(Path(evidence) / 'session-close-unmounted-menu.png')],
                   check=True, timeout=5)
    assert close.get_action_iface().do_action(1)
    prompt = eventually(close_prompt, 'unmounted Close Session confirmation')
    assert prompt.get_name() == 'Close “Unmounted live session”?', prompt.get_name()
    confirm = next(prompt.get_child_at_index(index)
                   for index in range(prompt.get_child_count())
                   if prompt.get_child_at_index(index).get_name() == 'Close Session')
    assert confirm.get_action_iface().do_action(0)
    eventually(lambda: 'SESSION_CLOSED id=' + session_id in log_path.read_text(),
               'unmounted daemon child closed')
    eventually(agent_stopped, 'daemon child exited')
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session WHERE id=?',
                                (session_id,)).fetchone()[0] == 1
    assert input_log.read_bytes() == initial_input, 'Close menu sent input to the agent PTY'
    assert all(item.get_role_name() != 'terminal' for item in children()), \
        'closing an unmounted session attached a terminal'
    xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
    assert process.wait(timeout=6) == 0
    print('PASS unmounted daemon child: row menu, Close confirmation, exit, saved row, PTY isolation',
          flush=True)
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=6)
    subprocess.run([str(Path(binary).with_name('threading-ptyd')), 'stop', session_id,
                    '--socket', endpoint], capture_output=True, timeout=5)
    log.close()
