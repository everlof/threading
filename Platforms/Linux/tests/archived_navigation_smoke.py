"""Installed shell: archived chats remain durable but never occupy navigator rows."""
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import uuid

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'archived-navigation'
root.mkdir()
project = root / 'Project'
project.mkdir()
home = root / 'home'
home.mkdir()
store = root / 'store'
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_UI_SCALE='2',
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)

ids = []
with sqlite3.connect(store / 'threading.db') as database:
    project_id, kind, last_active, payload = database.execute(
        'SELECT project_id, kind, last_active_at, data FROM session').fetchone()
    template = json.loads(payload)
    database.execute('DELETE FROM session')
    database.execute("DELETE FROM app_state WHERE key = 'selectedSessionID'")
    for position in range(5):
        identifier = str(uuid.uuid4()).upper()
        ids.append(identifier)
        record = dict(template, id=identifier, title=f'Archive fixture {position}',
                      customTitle=None, hasLaunched=False, archived=position in (1, 4))
        if position in (2, 3):
            reference_now = time.time() - 978307200
            record.update(snoozedAt=reference_now - 3600,
                          snoozedUntil=reference_now + (5 if position == 2 else -60),
                          hadTurnInFlightWhenSnoozed=False)
        database.execute('INSERT INTO session '
                         '(id, project_id, position, kind, last_active_at, data) '
                         'VALUES (?, ?, ?, ?, ?, ?)',
                         (identifier, project_id, position, kind, last_active,
                          json.dumps(record, separators=(',', ':'))))

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


def project_list():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() != 'Threading Linux' or app.get_process_id() != process.pid:
            continue
        frame = app.get_child_at_index(0)
        for child_index in range(frame.get_child_count()):
            listed = frame.get_child_at_index(child_index)
            if listed.get_role_name() == 'list' and listed.get_name() == 'Projects':
                return listed
    return None


def session_menu():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() != 'Threading Linux' or app.get_process_id() != process.pid:
            continue
        frame = app.get_child_at_index(0)
        for child_index in range(frame.get_child_count()):
            listed = frame.get_child_at_index(child_index)
            if listed.get_role_name() == 'list' and listed.get_name() == 'Session actions':
                return listed
    return None


def session_name(identifier):
    listed = project_list()
    if listed is None:
        return ''
    for index in range(listed.get_child_count()):
        child = listed.get_child_at_index(index)
        if child.get_accessible_id() == identifier:
            return child.get_name()
    return ''


try:
    eventually(lambda: 'OUTLINE_FRAME ' in log_path.read_text(), 'navigator ready')
    eventually(lambda: 'SESSION_SNOOZE_RECONCILED active=1 expired=1' in log_path.read_text(),
               'missed snooze deadline materialized')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[3],)).fetchone()
        expired = json.loads(record)
        assert expired.get('snoozedAt') is None and expired.get('snoozedUntil') is None, expired
        assert expired['wake']['reason'] == 'timeReached', expired
    window = eventually(lambda: subprocess.check_output(
        ['xdotool', 'search', '--onlyvisible', '--name', '^Threading'], text=True).splitlines()[0],
        'window')
    subprocess.run(['xdotool', 'windowsize', window, '1120', '900'], check=True, timeout=5)
    listed = eventually(project_list, 'project list')
    visible = [listed.get_child_at_index(index).get_accessible_id()
               for index in range(listed.get_child_count())]
    assert ids[1] not in visible and ids[4] not in visible, visible
    assert set(ids[index] for index in (0, 2, 3)).issubset(visible), visible
    eventually(lambda: 'Woke' in session_name(ids[3]), 'missed deadline row shows Woke')
    assert 'of 4 items' in listed.get_description(), listed.get_description()
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation.png')],
                   check=True, timeout=8)
    target = next(listed.get_child_at_index(index)
                  for index in range(listed.get_child_count())
                  if listed.get_child_at_index(index).get_accessible_id() == ids[0])
    row = target.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    hover_x = row.x + row.width - 34
    archive_y = row.y + row.height // 2
    frames_before_hover = log_path.read_text().count('OUTLINE_FRAME ')
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(hover_x), str(archive_y)], check=True, timeout=5)
    eventually(lambda: log_path.read_text().count('OUTLINE_FRAME ') > frames_before_hover,
               'hovered session rendered')
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-hover.png')],
                   check=True, timeout=8)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(row.x + row.width // 2), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    context = eventually(session_menu, 'session secondary-click menu')
    context_names = [context.get_child_at_index(index).get_name()
                     for index in range(context.get_child_count())]
    assert {'Pin', 'Archive', 'Copy'}.issubset(set(context_names)), context_names
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-context.png')],
                   check=True, timeout=8)
    subprocess.run(['xdotool', 'key', 'Escape'], check=True, timeout=5)
    eventually(lambda: session_menu() is None, 'secondary-click menu dismissed')

    listed = eventually(project_list, 'project list after context menu')
    target = next(listed.get_child_at_index(index)
                  for index in range(listed.get_child_count())
                  if listed.get_child_at_index(index).get_accessible_id() == ids[0])
    assert target.get_action_iface().do_action(0), 'could not select session for keyboard menu'
    subprocess.run(['xdotool', 'key', 'shift+F10'], check=True, timeout=5)
    keyboard_menu = eventually(session_menu, 'selected session keyboard menu')
    keyboard_names = [keyboard_menu.get_child_at_index(index).get_name()
                      for index in range(keyboard_menu.get_child_count())]
    assert {'Pin', 'Archive', 'Copy'}.issubset(set(keyboard_names)), keyboard_names
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-keyboard-menu.png')],
                   check=True, timeout=8)
    subprocess.run(['xdotool', 'key', 'Escape'], check=True, timeout=5)
    eventually(lambda: session_menu() is None, 'keyboard menu dismissed')

    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(row.x + row.width // 2), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    menu = eventually(session_menu, 'session menu for Snooze')
    snooze = next(menu.get_child_at_index(index) for index in range(menu.get_child_count())
                  if menu.get_child_at_index(index).get_name() == 'Snooze')
    snooze_bounds = snooze.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(snooze_bounds.x + snooze_bounds.width // 2),
                    str(snooze_bounds.y + snooze_bounds.height // 2)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    submenu = eventually(lambda: (menu := session_menu()) and any(
        menu.get_child_at_index(index).get_name() == 'In an hour'
        for index in range(menu.get_child_count())) and menu, 'Snooze presets')
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-snooze-presets.png')],
                   check=True, timeout=8)
    hour = next(submenu.get_child_at_index(index) for index in range(submenu.get_child_count())
                if submenu.get_child_at_index(index).get_name() == 'In an hour')
    hour_bounds = hour.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(hour_bounds.x + hour_bounds.width // 2),
                    str(hour_bounds.y + hour_bounds.height // 2)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    eventually(lambda: f'SESSION_SNOOZE_SAVED id={ids[0]}' in log_path.read_text(),
               'Snooze persisted')
    eventually(lambda: 'Snoozed' in session_name(ids[0]), 'snoozed row rendered')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[0],)).fetchone()
        snoozed = json.loads(record)
        assert snoozed.get('snoozedAt') is not None and snoozed.get('snoozedUntil') is not None
        assert snoozed['snoozedUntil'] > snoozed['snoozedAt']
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-snoozed.png')],
                   check=True, timeout=8)

    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(row.x + row.width // 2), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    menu = eventually(session_menu, 'session menu for Unsnooze')
    unsnooze = next(menu.get_child_at_index(index) for index in range(menu.get_child_count())
                    if menu.get_child_at_index(index).get_name() == 'Unsnooze')
    unsnooze_bounds = unsnooze.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(unsnooze_bounds.x + unsnooze_bounds.width // 2),
                    str(unsnooze_bounds.y + unsnooze_bounds.height // 2)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    eventually(lambda: log_path.read_text().count(f'SESSION_SNOOZE_SAVED id={ids[0]}') >= 2,
               'Unsnooze persisted')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[0],)).fetchone()
        unsnoozed = json.loads(record)
        assert unsnoozed.get('snoozedAt') is None and unsnoozed.get('snoozedUntil') is None

    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(row.x + row.width // 2), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    menu = eventually(session_menu, 'session menu for custom Snooze')
    snooze = next(menu.get_child_at_index(index) for index in range(menu.get_child_count())
                  if menu.get_child_at_index(index).get_name() == 'Snooze')
    bounds = snooze.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2)],
                   check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    submenu = eventually(lambda: (menu := session_menu()) and any(
        menu.get_child_at_index(index).get_name() == 'Custom time…'
        for index in range(menu.get_child_count())) and menu, 'custom Snooze choice')
    custom = next(submenu.get_child_at_index(index) for index in range(submenu.get_child_count())
                  if submenu.get_child_at_index(index).get_name() == 'Custom time…')
    bounds = custom.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2)],
                   check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    picker = eventually(lambda: subprocess.check_output(
        ['xdotool', 'search', '--onlyvisible', '--name', '^Snooze session$'],
        text=True).splitlines()[0], 'custom Snooze sheet')
    subprocess.run(['xdotool', 'windowfocus', '--sync', picker], check=True, timeout=5)
    time.sleep(1.5)
    subprocess.run(['import', '-window', picker,
                    str(output / 'archived-navigation-custom-snooze.png')], check=True, timeout=8)
    subprocess.run(['xdotool', 'key', 'Left'], check=True, timeout=5)
    time.sleep(.2)
    subprocess.run(['xdotool', 'key', 'Down'], check=True, timeout=5)
    time.sleep(.2)
    subprocess.run(['import', '-window', picker,
                    str(output / 'archived-navigation-custom-tomorrow.png')],
                   check=True, timeout=8)
    subprocess.run(['xdotool', 'key', 'Return'], check=True, timeout=5)
    eventually(lambda: log_path.read_text().count(f'SESSION_SNOOZE_SAVED id={ids[0]}') >= 3,
               'custom Snooze persisted')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[0],)).fetchone()
        custom_snoozed = json.loads(record)
        deadline = datetime.fromtimestamp(custom_snoozed['snoozedUntil'] + 978307200)
        assert deadline.date() == (datetime.now() + timedelta(days=1)).date(), deadline
        assert deadline.minute % 15 == 0 and deadline.second == 0, deadline
    eventually(lambda: 'Snoozed' in session_name(ids[0]), 'custom snoozed row rendered')

    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(row.x + row.width // 2), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '3'], check=True, timeout=5)
    menu = eventually(session_menu, 'session menu for custom Unsnooze')
    unsnooze = next(menu.get_child_at_index(index) for index in range(menu.get_child_count())
                    if menu.get_child_at_index(index).get_name() == 'Unsnooze')
    bounds = unsnooze.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2)],
                   check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    eventually(lambda: log_path.read_text().count(f'SESSION_SNOOZE_SAVED id={ids[0]}') >= 4,
               'custom Unsnooze persisted')
    eventually(lambda: 'SESSION_SNOOZE_EXPIRED count=1' in log_path.read_text(),
               'live snooze deadline fired')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[2],)).fetchone()
        expired_live = json.loads(record)
        assert expired_live.get('snoozedUntil') is None, expired_live
        assert expired_live['wake']['reason'] == 'timeReached', expired_live
    eventually(lambda: 'Woke' in session_name(ids[2]), 'live deadline row shows Woke')

    action_x = row.x + row.width - 108
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(action_x), str(archive_y)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    menu = eventually(session_menu, 'anchored session menu')
    names = [menu.get_child_at_index(index).get_name()
             for index in range(menu.get_child_count())]
    assert {'Pin', 'Archive', 'Copy'}.issubset(set(names)), names
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-menu.png')],
                   check=True, timeout=8)
    pin = next(menu.get_child_at_index(index) for index in range(menu.get_child_count())
               if menu.get_child_at_index(index).get_name() == 'Pin')
    pin_bounds = pin.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(pin_bounds.x + pin_bounds.width // 2),
                    str(pin_bounds.y + pin_bounds.height // 2)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    eventually(lambda: f'SESSION_PIN_SAVED id={ids[0]} pinned=true' in log_path.read_text(),
               'menu Pin action committed')
    eventually(lambda: session_menu() is None, 'session menu dismissed after Pin')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[0],)).fetchone()
        assert json.loads(record)['pinned'] is True
    listed = eventually(project_list, 'project list after Pin')
    target = next(listed.get_child_at_index(index)
                  for index in range(listed.get_child_count())
                  if listed.get_child_at_index(index).get_accessible_id() == ids[0])
    row = target.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    archive_x = row.x + row.width - 64
    archive_y = row.y + row.height // 2
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(archive_x), str(archive_y)], check=True, timeout=5)
    frames_before_click = log_path.read_text().count('OUTLINE_FRAME ')
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    eventually(lambda: f'SESSION_ARCHIVED id={ids[0]}' in log_path.read_text(),
               'hover Archive action committed')
    eventually(lambda: log_path.read_text().count('OUTLINE_FRAME ') > frames_before_click,
               'archived row repainted')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[0],)).fetchone()
        assert json.loads(record)['archived'] is True
    def visible_ids_after_archive():
        listed = project_list()
        return [listed.get_child_at_index(index).get_accessible_id()
                for index in range(listed.get_child_count())] if listed else None
    eventually(lambda: (visible := visible_ids_after_archive()) is not None
               and ids[0] not in visible,
               'archived row left the navigator')
    subprocess.run(['import', '-window', window, str(output / 'archived-navigation-after.png')],
                   check=True, timeout=8)
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 5
    listed = eventually(project_list, 'project list before wake acknowledgement')
    woke_row = next(listed.get_child_at_index(index)
                    for index in range(listed.get_child_count())
                    if listed.get_child_at_index(index).get_accessible_id() == ids[2])
    woke_bounds = woke_row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    subprocess.run(['xdotool', 'mousemove', '--window', window,
                    str(woke_bounds.x + woke_bounds.width // 2),
                    str(woke_bounds.y + woke_bounds.height // 2)], check=True, timeout=5)
    subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    subprocess.run(['xdotool', 'key', 'Return'], check=True, timeout=5)
    eventually(lambda: f'SESSION_SNOOZE_SAVED id={ids[2]} deadline=nil' in log_path.read_text(),
               'visiting session acknowledged wake')
    with sqlite3.connect(store / 'threading.db') as database:
        record, = database.execute('SELECT data FROM session WHERE id=?', (ids[2],)).fetchone()
        assert json.loads(record).get('wake') is None
    eventually(lambda: 'Woke' not in session_name(ids[2]), 'wake caption cleared after visit')
    print('PASS installed navigator filters archived chats and commits Snooze/Unsnooze/Pin/Archive')
finally:
    try: subprocess.run(['xdotool', 'windowfocus', window, 'key', 'alt+F4'], check=False)
    except NameError: pass
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
