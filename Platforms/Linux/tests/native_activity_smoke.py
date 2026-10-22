"""Installed native session row: provider turn arc, then a real pending permission dot."""
from saved_catalog_menu import open_saved_agents
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'native-activity'
root.mkdir()
store, project, home = root / 'store', root / 'ActivityProject', root / 'home'
project.mkdir()
home.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_UI_SCALE='2',
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(nativeUI=True, hasLaunched=False, lastExitCode=None,
                  agentSessionID=None, customTitle='Native activity', permissionMode='manual')
    if os.environ.get('THREADING_TEST_SNOOZE_WAKE') == '1':
        reference_now = time.time() - 978307200
        record.update(snoozedAt=reference_now - 60,
                      snoozedUntil=reference_now + 3600,
                      hadTurnInFlightWhenSnoozed=False)
    database.execute('UPDATE session SET data=? WHERE id=?', (json.dumps(record), identifier))

peer = root / 'activity-peer'
peer.write_text(r'''#!/usr/bin/python3
import json, sys, time
def emit(value): print(json.dumps(value), flush=True)
def reply(request, result): emit({'id': request['id'], 'result': result})
def note(method, params): emit({'method': method, 'params': params})
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': reply(request, {})
    elif method == 'initialized': pass
    elif method == 'thread/start': reply(request, {'thread': {'id': '00000000-0000-4000-8000-000000000123', 'model': 'fixture'}})
    elif method == 'skills/list': reply(request, {'data': [{'cwd': '/tmp', 'skills': [], 'errors': []}]})
    elif method == 'turn/start':
        tid = 'activity-turn'
        reply(request, {'turn': {'id': tid}})
        note('turn/started', {'threadId': '00000000-0000-4000-8000-000000000123', 'turn': {'id': tid}})
        time.sleep(7)
        emit({'id': 'activity-approval', 'method': 'item/commandExecution/requestApproval',
              'params': {'threadId': '00000000-0000-4000-8000-000000000123', 'turnId': tid,
                         'command': 'touch approval-required.txt', 'cwd': '/tmp'}})
    elif request.get('id') == 'activity-approval':
        note('turn/completed', {'threadId': '00000000-0000-4000-8000-000000000123',
             'turn': {'id': 'activity-turn', 'status': 'completed', 'items': []}})
    elif method == 'turn/interrupt': reply(request, {})
''')
peer.chmod(0o700)
log_path = output / 'window.log'
log = log_path.open('w')
process = subprocess.Popen([binary, '--app-codex', str(store), endpoint, '/bin/sh', str(peer)],
                           env=environment, stdout=log, stderr=log)
window = None


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


def row_with(text):
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    Atspi.init()
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() != process.pid or app.get_name() != 'Threading Linux':
            continue
        frame = app.get_child_at_index(0)
        if frame is None:
            continue
        for child in range(frame.get_child_count()):
            listed = frame.get_child_at_index(child)
            if listed is None:
                continue
            if listed.get_role_name() != 'list' or not listed.get_name().startswith('Saved agents'):
                continue
            for row_index in range(listed.get_child_count()):
                row = listed.get_child_at_index(row_index)
                if row is None:
                    continue
                if row.get_accessible_id() == identifier and text in row.get_name():
                    return row
    return None


def capture(name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=8)
    return path


def trailing_pixels(path, row):
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
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
    subprocess.run(['xclip', '-selection', 'clipboard'], input=b'Inspect activity', check=True, timeout=5)
    key('ctrl+v')
    key('Return')
    working = eventually(lambda: row_with(' working'), 'reported foreground turn')
    import gi
    gi.require_version('Atspi', '2.0')
    from gi.repository import Atspi
    assert working.get_component_iface().get_extents(Atspi.CoordType.WINDOW).height == 56, \
        'saved session row did not use the Mac 28-point row height at 2x'
    first = capture('native-working-1.png')
    first_pixels = trailing_pixels(first, working)
    first_full_frames = log_path.read_text().count('AGENT_PICKER_FRAME ')
    time.sleep(.2)
    working = eventually(lambda: row_with(' working'), 'turn remains active')
    second = capture('native-working-2.png')
    second_full_frames = log_path.read_text().count('AGENT_PICKER_FRAME ')
    assert trailing_pixels(second, working) != first_pixels, 'working arc did not animate'
    assert second_full_frames - first_full_frames <= 1, 'animation rebuilt the whole sidebar'
    blocked = eventually(lambda: row_with(' waiting for an answer'), 'pending permission')
    blocked_capture = capture('native-awaiting-user.png')
    assert trailing_pixels(blocked_capture, blocked) != first_pixels, 'blocked dot kept the working arc'
    if os.environ.get('THREADING_TEST_SNOOZE_WAKE') == '1':
        eventually(lambda: f'SESSION_SNOOZE_SAVED id={identifier} deadline=nil'
                   in log_path.read_text(), 'new approval woke snoozed session')
        with sqlite3.connect(store / 'threading.db') as database:
            payload, = database.execute('SELECT data FROM session WHERE id=?', (identifier,)).fetchone()
            woke = json.loads(payload)
            assert woke.get('snoozedUntil') is None, woke
            assert woke['wake']['reason'] == 'approvalRequested', woke
        eventually(lambda: row_with(' Woke'), 'wake receipt rendered')
        capture('native-woke-on-approval.png')
    print('PASS installed native row: reported working arc animates, permission changes to blocked dot')
finally:
    if window is not None:
        subprocess.run(['xdotool', 'windowfocus', window, 'key', 'alt+F4'], check=False)
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
