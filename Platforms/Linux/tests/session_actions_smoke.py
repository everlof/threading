"""Installed saved-agent header Actions: mounted rows, input, AT-SPI and clipboard."""
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
root = Path(fixture) / 'session-actions'
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
agent.write_text('#!/bin/sh\nstty raw -echo\nprintf "LIVE ACTION TARGET\\r\\n"\n'
                 'exec /bin/cat >> "$THREADING_TEST_INPUT_LOG"\n')
agent.chmod(0o755)
seed_log = (root / 'seed-host.log').open('w+')
seed = subprocess.Popen([host, str(store), endpoint, 'codex', str(project), '/bin/sh',
                         str(agent), 'Action target'], stdin=subprocess.PIPE,
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
    session_id, = database.execute('SELECT id FROM session').fetchone()
    project_id, = database.execute('SELECT id FROM project').fetchone()
    assert session_id and project_id
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('selectedSessionID', session_id))
log_path = Path('out/session-actions-window.log')
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
    return subprocess.run(['xdotool', *args], capture_output=True, text=True,
                          check=True, timeout=5).stdout.strip()


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        item = desktop.get_child_at_index(index)
        if item.get_name() == 'Threading Linux' and item.get_process_id() == process.pid:
            return item
    return None


def children():
    frame = app.get_child_at_index(0)
    return [frame.get_child_at_index(index) for index in range(frame.get_child_count())]


def child(identifier):
    return next((item for item in children() if item.get_accessible_id() == identifier), None)


def menu():
    item = child('linux.session-actions')
    return item if item is not None and item.get_child_count() == 2 else None


def clipboard():
    return subprocess.check_output(['xclip', '-selection', 'clipboard', '-o'],
                                   text=True, timeout=3)


def screenshot(name):
    path = Path(evidence) / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    return path


def pixel(path, x, y):
    return subprocess.check_output(
        ['convert', str(path), '-format', f'%[pixel:p{{{x},{y}}}]', 'info:'],
        text=True, timeout=5).strip()


try:
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                    str(process.pid)).splitlines()[0], 'installed window')
    app = eventually(application, 'AT-SPI application')
    actions = eventually(lambda: child('linux.page-actions'), 'saved-agent Actions button')
    assert actions.get_name() == 'Session context menu'
    assert child('linux.page-title').get_name()
    terminal = eventually(lambda: next((item for item in children()
                                if item.get_role_name() == 'terminal'), None), 'live terminal')
    eventually(lambda: 'LIVE ACTION TARGET' in Atspi.Text.get_text(
        terminal.get_text_iface(), 0, -1), 'synthetic agent visible in terminal')
    initial_input = input_log.read_bytes()
    assert child('linux.session-actions') is None
    assert actions.get_action_iface().do_action(0), 'AT-SPI Actions press refused'
    opened = eventually(menu, 'two mounted production menu rows')
    rows = [opened.get_child_at_index(index) for index in range(2)]
    assert [row.get_name() for row in rows] == ['Copy Session ID', 'Copy Project Path']
    assert [row.get_accessible_id() for row in rows] == ['copySessionID', 'copyProjectPath']
    assert all(row.get_action_iface().get_n_actions() == 1 for row in rows)
    light = screenshot('session-actions-open.png')
    before_theme = input_log.read_bytes()
    navigator_frames = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
    terminal_frames = log_path.read_text().count('TERMINAL_FRAME ')
    xdo('windowfocus', '--sync', window, 'key', 'ctrl+shift+t')
    eventually(lambda: 'THEME_APPEARANCE dark' in log_path.read_text(), 'dark appearance')
    eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > navigator_frames,
               'dark navigator frame')
    eventually(lambda: log_path.read_text().count('TERMINAL_FRAME ') > terminal_frames,
               'dark terminal frame')
    eventually(menu, 'menu preserved across dark appearance')
    dark = screenshot('session-actions-dark.png')
    for x, y in [(300, 300), (800, 30), (1100, 400)]:
        assert pixel(light, x, y) != pixel(dark, x, y), \
            f'appearance left pane pixel unchanged at {(x, y)}'
    assert input_log.read_bytes() == before_theme, 'theme shortcut reached live PTY'
    navigator_frames = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
    xdo('key', 'ctrl+shift+t')
    eventually(lambda: 'THEME_APPEARANCE light' in log_path.read_text(), 'light appearance')
    eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > navigator_frames,
               'restored light navigator frame')
    eventually(menu, 'menu preserved across light appearance')
    restored = screenshot('session-actions-light-restored.png')
    for x, y in [(300, 300), (800, 30), (1100, 400)]:
        assert pixel(light, x, y) == pixel(restored, x, y), \
            f'light appearance did not restore pane pixel at {(x, y)}'
    assert rows[0].get_action_iface().do_action(0), 'AT-SPI menu row press refused'
    eventually(lambda: clipboard() == session_id, 'exact saved session ID copied')
    eventually(lambda: child('linux.session-actions') is None, 'menu dismissed after choice')

    # The production button also answers a native pointer press; arrow/Enter stay with the
    # overlay instead of entering the running synthetic agent's PTY.
    bounds = actions.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, str(bounds.x + bounds.width // 2),
        str(bounds.y + bounds.height // 2), 'click', '1')
    eventually(menu, 'pointer opened saved-session Actions')
    xdo('windowfocus', '--sync', window, 'key', 'Down', 'Return')
    eventually(lambda: clipboard() == str(project), 'keyboard copied owning project path')
    eventually(lambda: child('linux.session-actions') is None, 'keyboard choice dismissed menu')

    assert actions.get_action_iface().do_action(0)
    eventually(menu, 'reopened Actions')
    xdo('windowfocus', '--sync', window, 'key', 'Escape')
    eventually(lambda: child('linux.session-actions') is None, 'Escape dismissed menu')
    assert 'SESSION_ACTION_COPIED copySessionID ' + session_id in log_path.read_text()
    assert 'SESSION_ACTION_COPIED copyProjectPath ' + session_id in log_path.read_text()
    assert input_log.read_bytes() == initial_input, 'menu input reached the live agent PTY'
    xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
    assert process.wait(timeout=6) == 0
    print('PASS saved-session Actions: production header/menu, pointer, keyboard, AT-SPI, exact clipboard, live PTY isolation',
          flush=True)
finally:
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)
    log.close()
