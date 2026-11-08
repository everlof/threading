"""Installed saved-agent header Actions: mounted rows, input, AT-SPI and clipboard."""
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
    if frame is None:
        return []
    return [frame.get_child_at_index(index) for index in range(frame.get_child_count())]


def child(identifier):
    return next((item for item in children() if item.get_accessible_id() == identifier), None)


def menu():
    return next((item for item in children()
                 if item.get_role_name() == 'list'
                 and item.get_name() == 'Session actions'), None)


def menu_with(title):
    opened = menu()
    if opened is None:
        return None
    return opened if any(opened.get_child_at_index(index).get_name() == title
                         for index in range(opened.get_child_count())) else None


def menu_row(opened, title):
    return next(opened.get_child_at_index(index)
                for index in range(opened.get_child_count())
                if opened.get_child_at_index(index).get_name() == title)


def prompt_with_id(identity):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() != 'Threading Linux' or candidate.get_process_id() == process.pid:
            continue
        frame = candidate.get_child_at_index(0)
        for child_index in range(frame.get_child_count()):
            panel = frame.get_child_at_index(child_index)
            if panel.get_accessible_id() == identity:
                return panel
    return None


def rename_prompt():
    return prompt_with_id('linux.prompt.rename-session')


def close_prompt():
    return prompt_with_id('linux.prompt.close-session')


def clipboard():
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-o'],
                            capture_output=True, text=True, timeout=3)
    return result.stdout if result.returncode == 0 else ''


def screenshot(name):
    path = Path(evidence) / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    return path


def pixel(path, x, y):
    return subprocess.check_output(
        ['convert', str(path), '-format', f'%[pixel:p{{{x},{y}}}]', 'info:'],
        text=True, timeout=5).strip()


try:
    app = eventually(application, 'AT-SPI application')
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                    str(process.pid)).splitlines()[0], 'installed window')
    actions = eventually(lambda: child('linux.page-actions'), 'saved-agent Actions button')
    assert actions.get_name() == 'Session context menu'
    assert child('linux.page-title').get_name()
    terminal = eventually(lambda: next((item for item in children()
                                if item.get_role_name() == 'terminal'), None), 'live terminal')
    eventually(lambda: 'LIVE ACTION TARGET' in Atspi.Text.get_text(
        terminal.get_text_iface(), 0, -1), 'synthetic agent visible in terminal')
    xdo('mousemove', '--window', window, '700', '200', 'click', '1')
    initial_input = input_log.read_bytes()
    assert menu() is None
    assert actions.get_action_iface().do_action(0), 'AT-SPI Actions press refused'
    opened = eventually(lambda: menu_with('Copy'), 'shared pane-header session menu')
    titles = [opened.get_child_at_index(index).get_name()
              for index in range(opened.get_child_count())]
    assert titles[:4] == ['Pin', 'Snooze', 'Archive', 'Close Session'], titles
    assert 'Rename Session…' in titles and 'Copy' in titles, titles
    assert menu_row(opened, 'Copy').get_accessible_id() == 'copy'
    light = screenshot('session-actions-open.png')
    assert menu_row(opened, 'Snooze').get_action_iface().do_action(1)
    snooze_page = eventually(lambda: menu_with('Custom time…'), 'shared Snooze submenu')
    snooze_titles = [snooze_page.get_child_at_index(index).get_name()
                     for index in range(snooze_page.get_child_count())]
    assert snooze_titles[0] == '‹  Snooze', snooze_titles
    assert 'In an hour' in snooze_titles and 'Custom time…' in snooze_titles, snooze_titles
    assert any(title.startswith('Tomorrow at ') for title in snooze_titles), snooze_titles
    assert menu_row(snooze_page, 'In an hour').get_accessible_id() == 'snoozeChoice:0'
    screenshot('session-header-snooze-menu.png')
    assert menu_row(snooze_page, '‹  Snooze').get_action_iface().do_action(1)
    eventually(lambda: menu_with('Copy'), 'returned to shared Actions menu')
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
    assert menu_row(eventually(lambda: menu_with('Copy'), 'restored session menu'),
                    'Copy').get_action_iface().do_action(1)
    copy_page = eventually(lambda: menu_with('Threading ID'), 'shared pane-header Copy fold')
    screenshot('session-header-copy-menu.png')
    assert menu_row(copy_page, 'Threading ID').get_action_iface().do_action(1)
    eventually(lambda: clipboard() == session_id.lower(), 'exact Threading ID copied')
    eventually(lambda: menu() is None, 'menu dismissed after choice')
    xdo('windowfocus', '--sync', window, 'key', 'q')
    eventually(lambda: input_log.read_bytes().endswith(b'q'),
               'header menu returned input focus to the agent pane')
    initial_input = input_log.read_bytes()

    # The production button also answers a native pointer press; arrow/Enter stay with the
    # overlay instead of entering the running synthetic agent's PTY.
    actions = eventually(lambda: child('linux.page-actions'), 'Actions button after Copy')
    bounds = actions.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, str(bounds.x + bounds.width // 2),
        str(bounds.y + bounds.height // 2), 'click', '1')
    opened = eventually(lambda: menu_with('Copy'), 'pointer opened shared session menu')
    assert menu_row(opened, 'Copy').get_action_iface().do_action(1)
    copy_page = eventually(lambda: menu_with('Worktree Path'), 'shared Worktree Path row')
    assert menu_row(copy_page, 'Worktree Path').get_action_iface().do_action(1)
    eventually(lambda: clipboard() == str(project), 'exact project path copied')
    eventually(lambda: menu() is None, 'menu dismissed after path choice')

    actions = eventually(lambda: child('linux.page-actions'), 'Actions button after path Copy')
    assert actions.get_action_iface().do_action(0)
    eventually(lambda: menu_with('Copy'), 'reopened shared Actions')
    xdo('windowfocus', '--sync', window, 'key', 'Down', 'Escape')
    eventually(lambda: menu() is None, 'Escape dismissed menu')
    assert 'SESSION_VALUE_COPIED copyThreadingID id=' + session_id in log_path.read_text()
    assert 'SESSION_VALUE_COPIED copyWorktreePath id=' + session_id in log_path.read_text()
    assert input_log.read_bytes() == initial_input, 'menu input reached the live agent PTY'

    projects = next(item for item in children()
                    if item.get_role_name() == 'list' and item.get_name() == 'Projects')
    session = next(projects.get_child_at_index(index)
                   for index in range(projects.get_child_count())
                   if projects.get_child_at_index(index).get_accessible_id() == session_id)
    assert session.get_action_iface().do_action(0)
    xdo('windowfocus', '--sync', window, 'key', 'shift+F10')
    row_menu = eventually(lambda: next((item for item in children()
        if item.get_role_name() == 'list' and item.get_name() == 'Session actions'), None),
        'row menu on live session')
    screenshot('session-row-menu.png')
    copy_fold = next(row_menu.get_child_at_index(index)
                     for index in range(row_menu.get_child_count())
                     if row_menu.get_child_at_index(index).get_name() == 'Copy')
    assert copy_fold.get_action_iface().do_action(1)
    copy_page = eventually(lambda: next((item for item in children()
        if item.get_role_name() == 'list' and item.get_name() == 'Session actions'
        and any(item.get_child_at_index(index).get_name() == 'Threading ID'
                for index in range(item.get_child_count()))), None),
        'shared Copy fold on saved session')
    screenshot('session-row-copy-menu.png')
    threading_id = next(copy_page.get_child_at_index(index)
                        for index in range(copy_page.get_child_count())
                        if copy_page.get_child_at_index(index).get_name() == 'Threading ID')
    assert threading_id.get_action_iface().do_action(1)
    eventually(lambda: clipboard() == session_id.lower(),
               'shared Copy fold copied Threading ID')
    xdo('windowfocus', '--sync', window, 'key', 'shift+F10')
    row_menu = eventually(lambda: next((item for item in children()
        if item.get_role_name() == 'list' and item.get_name() == 'Session actions'), None),
        'row menu reopened after Copy')
    rename = next(row_menu.get_child_at_index(index)
                  for index in range(row_menu.get_child_count())
                  if row_menu.get_child_at_index(index).get_name() == 'Rename Session…')
    assert rename.get_action_iface().do_action(1)
    prompt = eventually(rename_prompt, 'live session rename prompt')
    field = next(prompt.get_child_at_index(index)
                 for index in range(prompt.get_child_count())
                 if prompt.get_child_at_index(index).get_accessible_id() == 'linux.prompt.session-name')
    assert field.get_editable_text_iface().set_text_contents('Renamed live session')
    confirm = next(prompt.get_child_at_index(index)
                   for index in range(prompt.get_child_count())
                   if prompt.get_child_at_index(index).get_name() == 'Rename')
    assert confirm.get_action_iface().do_action(0)
    eventually(lambda: child('linux.page-title').get_name() == 'Renamed live session',
               'active pane header followed durable rename')
    with sqlite3.connect(store / 'threading.db') as database:
        payload, = database.execute('SELECT data FROM session WHERE id=?', (session_id,)).fetchone()
        assert json.loads(payload)['customTitle'] == 'Renamed live session'
    assert input_log.read_bytes() == initial_input, 'rename input reached live agent PTY'
    screenshot('session-actions-renamed-header.png')

    def session_row():
        listing = next((item for item in children()
                        if item.get_role_name() == 'list' and item.get_name() == 'Projects'), None)
        if listing is None:
            return None
        return next((listing.get_child_at_index(index)
                     for index in range(listing.get_child_count())
                     if listing.get_child_at_index(index).get_accessible_id() == session_id), None)

    def open_close():
        row = eventually(session_row, 'saved row before Close Session')
        assert row.get_action_iface().do_action(0)
        xdo('windowfocus', '--sync', window, 'key', 'shift+F10')
        opened = eventually(lambda: next((item for item in children()
            if item.get_role_name() == 'list' and item.get_name() == 'Session actions'), None),
            'row menu before Close Session')
        close = next((opened.get_child_at_index(index)
                      for index in range(opened.get_child_count())
                      if opened.get_child_at_index(index).get_name() == 'Close Session'), None)
        assert close is not None
        assert close.get_action_iface().do_action(1)
        return eventually(close_prompt, 'Close Session confirmation')

    confirmation = open_close()
    assert confirmation.get_name() == 'Close “Renamed live session”?', confirmation.get_name()
    assert all(confirmation.get_child_at_index(index).get_role_name() != 'text'
               for index in range(confirmation.get_child_count()))
    cancel = next(confirmation.get_child_at_index(index)
                  for index in range(confirmation.get_child_count())
                  if confirmation.get_child_at_index(index).get_name() == 'Cancel')
    bounds = cancel.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert bounds.width > 0 and bounds.height > 0, bounds
    subprocess.run(['import', '-window', 'root', str(Path(evidence) / 'session-close-confirm.png')],
                   check=True, timeout=5)
    suppression = next((confirmation.get_child_at_index(index)
                        for index in range(confirmation.get_child_count())
                        if confirmation.get_child_at_index(index).get_accessible_id()
                        == 'linux.prompt.suppression'), None)
    assert suppression and suppression.get_role_name() == 'check box'
    assert not suppression.get_state_set().contains(Atspi.StateType.CHECKED)
    assert suppression.get_action_iface().do_action(0)
    eventually(lambda: suppression.get_state_set().contains(Atspi.StateType.CHECKED),
               'Close Session suppression toggled')
    assert cancel.get_action_iface().do_action(0)
    eventually(lambda: 'SESSION_CLOSE_CANCELLED id=' + session_id in log_path.read_text(),
               'Close Session cancellation')
    assert input_log.read_bytes() == initial_input, 'confirmation input reached live agent PTY'

    confirmation = open_close()
    suppression = next((confirmation.get_child_at_index(index)
                        for index in range(confirmation.get_child_count())
                        if confirmation.get_child_at_index(index).get_accessible_id()
                        == 'linux.prompt.suppression'), None)
    assert suppression and not suppression.get_state_set().contains(Atspi.StateType.CHECKED)
    confirm = next(confirmation.get_child_at_index(index)
                   for index in range(confirmation.get_child_count())
                   if confirmation.get_child_at_index(index).get_name() == 'Close Session')
    assert confirm.get_action_iface().do_action(0)
    eventually(lambda: 'SESSION_CLOSED id=' + session_id in log_path.read_text(),
               'confirmed Close Session')
    eventually(session_row, 'saved row after Close Session')
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session WHERE id=?',
                                (session_id,)).fetchone()[0] == 1
    daemon = str(Path(binary).with_name('threading-ptyd'))
    def agent_stopped():
        result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                                check=True, capture_output=True, text=True, timeout=5)
        return any(item['id'] == session_id and item.get('exit') is not None
                   for item in json.loads(result.stdout))
    eventually(agent_stopped, 'daemon child exited after Close Session')
    assert input_log.read_bytes() == initial_input, 'Close Session sent input to agent PTY'
    dormant = eventually(lambda: next((item for item in children()
        if item.get_role_name() == 'panel' and item.get_name() == 'Session placeholder'), None),
        'selected dormant session pane')
    labels = [dormant.get_child_at_index(index).get_name()
              for index in range(dormant.get_child_count())]
    assert 'Renamed live session ended' in labels, labels
    assert any('No saved conversation was found' in name for name in labels), labels
    assert child('linux.page-title') is not None, 'dormant pane lost the Mac page header'
    selected = session_row()
    assert selected is not None and selected.get_state_set().contains(Atspi.StateType.SELECTED), \
        'closing changed the saved row selection'
    screenshot('session-close-dormant.png')
    resume = next(dormant.get_child_at_index(index)
                  for index in range(dormant.get_child_count())
                  if dormant.get_child_at_index(index).get_name() == 'Start Again')
    assert resume.get_action_iface().do_action(0), 'dormant action refused'
    eventually(lambda: next((item for item in children()
        if item.get_role_name() == 'terminal'), None), 'dormant button reopened the session')
    xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
    assert process.wait(timeout=6) == 0
    print('PASS saved-session Actions: header/menu, rename, Close, dormant pane, resume, PTY isolation',
          flush=True)
finally:
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)
    log.close()
