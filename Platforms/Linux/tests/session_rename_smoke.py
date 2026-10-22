"""Rename and clear a saved session through the installed row menu and themed prompt."""
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
root = Path(fixture) / 'session-rename'
root.mkdir(parents=True)
project = root / 'Project'
project.mkdir()
home = root / 'home'
home.mkdir()
store = root / 'store'
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(home),
                   THREADING_LINUX_UI_SCALE=os.environ.get('THREADING_LINUX_UI_SCALE', '2'),
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    session_id, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record['title'] = 'Seed conversation'
    database.execute('UPDATE session SET data=? WHERE id=?',
                     (json.dumps(record, separators=(',', ':')), session_id))

log_path = output / 'window.log'
log = log_path.open('w')
process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                           env=environment, stdout=log, stderr=log)
Atspi.init()


def eventually(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, f'exit={process.returncode} ' + log_path.read_text()[-5000:]
        try:
            value = read()
            if value:
                return value
        except (FileNotFoundError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()[-5000:]}')


def child_with_id(parent, identity):
    return next((parent.get_child_at_index(index)
                 for index in range(parent.get_child_count())
                 if parent.get_child_at_index(index).get_accessible_id() == identity), None)


def shell_frame():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() == process.pid and app.get_name() == 'Threading Linux':
            return app.get_child_at_index(0)
    return None


def shell_child(role, name):
    frame = shell_frame()
    if frame is None:
        return None
    return next((frame.get_child_at_index(index)
                 for index in range(frame.get_child_count())
                 if frame.get_child_at_index(index).get_role_name() == role
                 and frame.get_child_at_index(index).get_name() == name), None)


def session_row():
    listed = shell_child('list', 'Projects')
    return child_with_id(listed, session_id) if listed else None


def rename_prompt():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() != 'Threading Linux' or app.get_process_id() == process.pid:
            continue
        frame = app.get_child_at_index(0)
        panel = child_with_id(frame, 'linux.prompt.rename-session')
        if panel:
            return panel
    return None


def stored():
    with sqlite3.connect(store / 'threading.db') as database:
        payload, = database.execute('SELECT data FROM session WHERE id=?', (session_id,)).fetchone()
        return json.loads(payload)


def prompt_window_size():
    window_id = subprocess.check_output(
        ['xdotool', 'search', '--onlyvisible', '--name', '^Rename Session$'], text=True
    ).splitlines()[0]
    geometry = subprocess.check_output(
        ['xdotool', 'getwindowgeometry', '--shell', window_id], text=True
    )
    values = dict(line.split('=', 1) for line in geometry.splitlines() if '=' in line)
    return int(values['WIDTH']), int(values['HEIGHT'])


def open_rename(window):
    row = eventually(session_row, 'session row')
    bounds = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2)],
                   check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    menu = eventually(lambda: shell_child('list', 'Session actions'), 'session menu')
    rename = next((menu.get_child_at_index(index)
                   for index in range(menu.get_child_count())
                   if menu.get_child_at_index(index).get_name() == 'Rename Session…'), None)
    assert rename, [menu.get_child_at_index(index).get_name()
                    for index in range(menu.get_child_count())]
    assert rename.get_action_iface().do_action(1)
    return eventually(rename_prompt, 'rename prompt')


try:
    eventually(lambda: 'OUTLINE_FRAME ' in log_path.read_text(), 'navigator ready')
    window = eventually(lambda: subprocess.check_output(
        ['xdotool', 'search', '--onlyvisible', '--name', '^Threading'], text=True).splitlines()[0],
        'window')
    subprocess.run(['xdotool', 'windowsize', window, '1120', '900'], check=True, timeout=5)
    prompt = open_rename(window)
    assert prompt.get_name() == 'Rename Session'
    scale = int(environment['THREADING_LINUX_UI_SCALE'])
    assert eventually(prompt_window_size, 'prompt window size') == (400 * scale, 168 * scale)
    assert child_with_id(prompt, 'linux.prompt.clear') is None
    field = child_with_id(prompt, 'linux.prompt.session-name')
    assert field and field.get_name()
    assert field.get_editable_text_iface().set_text_contents('Renamed café 日本語')
    eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'Renamed café 日本語',
               'Unicode name entered')
    subprocess.run(['import', '-window', 'root', str(output / 'rename-prompt.png')],
                   check=True, timeout=8)
    confirm = child_with_id(prompt, 'linux.prompt.create')
    assert confirm.get_name() == 'Rename'
    assert confirm.get_action_iface().do_action(0)
    eventually(lambda: stored().get('customTitle') == 'Renamed café 日本語', 'rename persisted')
    eventually(lambda: (row := session_row()) and 'Renamed café 日本語' in row.get_name(),
               'renamed row')
    assert stored()['nameHistory']['entries'][0]['name'] == 'Seed conversation'

    prompt = open_rename(window)
    field = child_with_id(prompt, 'linux.prompt.session-name')
    assert Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'Renamed café 日本語'
    clear = child_with_id(prompt, 'linux.prompt.clear')
    assert clear and clear.get_name() == "Use Agent's Name"
    subprocess.run(['import', '-window', 'root', str(output / 'rename-clear-prompt.png')],
                   check=True, timeout=8)
    assert clear.get_action_iface().do_action(0)
    eventually(lambda: stored().get('customTitle') is None and
               len(stored().get('nameHistory', {}).get('entries', [])) >= 1,
               'clear persisted')
    eventually(lambda: (row := session_row()) and 'Renamed café 日本語' not in row.get_name(),
               'row follows agent')
    assert stored()['nameHistory']['entries'][0]['name'] == 'Renamed café 日本語'

    prompt = open_rename(window)
    field = child_with_id(prompt, 'linux.prompt.session-name')
    assert field.get_editable_text_iface().set_text_contents('Temporary name')
    eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'Temporary name',
               'temporary name entered')
    assert child_with_id(prompt, 'linux.prompt.create').get_action_iface().do_action(0)
    eventually(lambda: stored().get('customTitle') == 'Temporary name',
               'temporary name persisted')
    prompt = open_rename(window)
    field = child_with_id(prompt, 'linux.prompt.session-name')
    assert field.get_editable_text_iface().set_text_contents('')
    eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == '',
               'field emptied')
    assert child_with_id(prompt, 'linux.prompt.create').get_action_iface().do_action(0)
    eventually(lambda: stored().get('customTitle') is None, 'blank answer cleared custom name')
    print('PASS installed row Rename Session, Unicode persistence, name history, clear and blank')
finally:
    try: subprocess.run(['xdotool', 'windowfocus', window, 'key', 'alt+F4'], check=False)
    except NameError: pass
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
