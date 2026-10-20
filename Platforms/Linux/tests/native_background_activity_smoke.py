"""Installed Claude row: a completed turn with live background work keeps a static status dot."""
from saved_catalog_menu import open_saved_agents
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
root = Path(fixture) / 'native-background-activity'
root.mkdir()
store, project, home = root / 'store', root / 'BackgroundProject', root / 'home'
project.mkdir()
home.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_UI_SCALE='2',
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'claude', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(nativeUI=True, hasLaunched=False, lastExitCode=None,
                  agentSessionID=None, customTitle='Background activity')
    database.execute('UPDATE session SET data=? WHERE id=?', (json.dumps(record), identifier))

peer = root / 'background-peer'
peer.write_text(r'''#!/usr/bin/python3
import json, sys, time
thread = '00000000-0000-4000-8000-000000000234'
def emit(value): print(json.dumps(value), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    if message.get('type') == 'control_request':
        assert message['request']['subtype'] == 'initialize', message
        emit({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': message['request_id'], 'response': {'commands': []}}})
        continue
    assert message.get('type') == 'user', message
    emit({'type': 'system', 'subtype': 'init', 'session_id': thread, 'model': 'fixture'})
    emit({'type': 'assistant', 'message': {'content': [{'type': 'text',
          'text': 'The background task is still running.'}]}})
    emit({'type': 'system', 'subtype': 'background_tasks_changed',
          'tasks': [{'task_id': 'background-1', 'task_type': 'local_agent'}]})
    emit({'type': 'result', 'subtype': 'success', 'result': 'Ready while it runs',
          'is_error': False, 'session_id': thread, 'duration_ms': 10})
    time.sleep(8)
    emit({'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': []})
''')
peer.chmod(0o700)
log_path = output / 'window.log'
log = log_path.open('w')
process = subprocess.Popen([binary, '--app-claude', str(store), endpoint, '/bin/sh', str(peer)],
                           env=environment, stdout=log, stderr=log)
window = None
Atspi.init()


def eventually(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()[-5000:]
        try:
            result = read()
            if result:
                return result
        except (FileNotFoundError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()[-5000:]}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *args], text=True, timeout=5).strip()


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '40', value)


def saved_row():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() != process.pid or app.get_name() != 'Threading Linux':
            continue
        frame = app.get_child_at_index(0)
        for child in range(frame.get_child_count()):
            listed = frame.get_child_at_index(child)
            if listed.get_role_name() != 'list' or not listed.get_name().startswith('Saved agents'):
                continue
            for row_index in range(listed.get_child_count()):
                row = listed.get_child_at_index(row_index)
                if row.get_accessible_id() == identifier:
                    return row
    return None


def row_named(fragment):
    row = saved_row()
    return row if row is not None and fragment in row.get_name() else None


def row_without(fragment):
    row = saved_row()
    return row if row is not None and fragment not in row.get_name() else None


def capture(name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=8)
    return path


def trailing_pixels(path, row):
    rect = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    crop = f'30x24+{rect.x + rect.width - 40}+{rect.y + (rect.height - 24) // 2}'
    return subprocess.check_output(['convert', str(path), '-crop', crop, '+repage',
                                    '-depth', '8', 'rgba:-'], timeout=5)


try:
    eventually(lambda: 'IDLE_PANE_FRAME ' in log_path.read_text(), 'workspace ready')
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0],
                        'window')
    xdo('windowsize', window, '1120', '900')
    open_saved_agents(key)
    key('Return')
    eventually(lambda: xdo('getwindowname', window) == 'Threading conversation · Ready',
               'native conversation ready')
    if os.environ.get('THREADING_TEST_DARK') == '1':
        key('ctrl+shift+t')
        eventually(lambda: 'THEME_APPEARANCE dark' in log_path.read_text(), 'dark shell ready')
    idle = eventually(lambda: row_named('Background activity'), 'idle saved row')
    idle_pixels = trailing_pixels(capture('native-background-idle.png'), idle)
    subprocess.run(['xclip', '-selection', 'clipboard'], input=b'Keep working in the background',
                   check=True, timeout=5)
    key('ctrl+v')
    key('Return')
    background = eventually(lambda: row_named('ready for input; background work running'),
                            'completed turn with provider background task')
    active_pixels = trailing_pixels(capture('native-background-active.png'), background)
    assert active_pixels != idle_pixels, 'background task had no visible status dot'
    time.sleep(.2)
    background = eventually(lambda: row_named('ready for input; background work running'),
                            'background task remains active')
    assert trailing_pixels(capture('native-background-still.png'), background) == active_pixels, \
        'background status dot animated while no foreground turn was active'
    cleared = eventually(lambda: row_without('background work running'),
                         'provider cleared background task', timeout=15)
    assert trailing_pixels(capture('native-background-cleared.png'), cleared) == idle_pixels, \
        'background status dot remained after the provider cleared its task list'
    print('PASS installed Claude row: completed turn shows a static background-work dot and clears it')
finally:
    if window is not None:
        subprocess.run(['xdotool', 'windowfocus', window, 'key', 'alt+F4'], check=False)
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
