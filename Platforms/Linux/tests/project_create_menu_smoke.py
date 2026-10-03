"""Exercise the production project-row + through the real X11 shell and host commands."""
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, daemon, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'project-create-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
for name in ('AlphaCreate', 'BetaCreate'):
    folder = root / name
    folder.mkdir()
    subprocess.run([host, '--add-project', str(store), str(folder)],
                   check=True, capture_output=True, timeout=8)
socket = root / 'pty.sock'
daemon_log = output / 'daemon.log'
window_log = output / 'window.log'
Atspi.init()


def eventually(read, label, process, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: window exited: {window_log.read_text()}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {window_log.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def listing(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    assert len(matches) == 1
    return matches[0]


def projects(app):
    listed = listing(app)
    if listed.get_name() != 'Projects' or listed.get_child_count() != 2:
        return None
    return [listed.get_child_at_index(index) for index in range(2)]


def ids(listed):
    return [listed.get_child_at_index(index).get_accessible_id()
            for index in range(listed.get_child_count())]


def menu(app, name, expected, process):
    return eventually(lambda: listing(app) if listing(app).get_name() == name
                      and ids(listing(app)) == expected else None,
                      name + ' menu', process)


def selected(row):
    return row.get_state_set().contains(Atspi.StateType.SELECTED)


def visible_title(window):
    return xdo('getwindowname', window)


process = None
daemon_process = None
try:
    state = root / 'daemon'
    state.mkdir()
    with daemon_log.open('w+') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: subprocess.run([daemon, 'sessions', '--json', '--socket', str(socket)],
                                        capture_output=True, timeout=5).returncode == 0,
                   'PTY daemon', daemon_process)
    with window_log.open('w+') as log:
        process = subprocess.Popen([binary, '--app-codex', str(store), str(socket),
                                    '/bin/sh', '/bin/true'],
                                   env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI registration', process)
        rows = eventually(lambda: projects(app), 'two project rows', process)
        assert selected(rows[0]) and not selected(rows[1])
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)

        # The AX action is the same exact-ID route as the visible production control.
        create = rows[1].get_child_at_index(0)
        assert create.get_accessible_id() == 'sidebar.project.create.' + rows[1].get_accessible_id()
        assert create.get_name() == 'New chat or terminal'
        create_rect = create.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (create_rect.x, create_rect.y, create_rect.width, create_rect.height) == (692, 136, 40, 40)
        assert create.get_action_iface().do_action(0)
        listed = menu(app, 'New in Project', ['linux.project.new-chat',
                      'linux.project.new-manager', 'linux.project.new-shell'], process)
        assert visible_title(window).endswith('/BetaCreate')
        assert [listed.get_child_at_index(i).get_name() for i in range(3)] == [
            'New Chat…', 'New Manager…. Managers are not available in the Linux preview.',
            'New Terminal']
        assert not listed.get_child_at_index(1).get_state_set().contains(Atspi.StateType.ENABLED)
        screenshot = output / 'project-create-menu.png'
        subprocess.run(['import', '-window', window, str(screenshot)], check=True, timeout=5)
        assert subprocess.check_output(['identify', '-format', '%wx%h', str(screenshot)],
                                       text=True, timeout=5) == '800x480'
        xdo('key', 'Escape')
        rows = eventually(lambda: projects(app), 'return to projects', process)
        assert selected(rows[0]) and not selected(rows[1])

        # Pointer opens the same menu. Chat chooses a configured provider in a nested list;
        # Escape peels one list at a time and leaves project selection unchanged.
        create_rect = rows[1].get_child_at_index(0).get_component_iface().get_extents(
            Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, str(create_rect.x + create_rect.width // 2),
            str(create_rect.y + create_rect.height // 2))
        xdo('click', '--window', window, '1')
        listed = menu(app, 'New in Project', ['linux.project.new-chat',
                      'linux.project.new-manager', 'linux.project.new-shell'], process)
        assert listed.get_child_at_index(0).get_action_iface().do_action(1)
        providers = menu(app, 'New Chat providers', ['linux.session.new-codex',
                         'linux.session.new-claude'], process)
        assert providers.get_child_at_index(0).get_state_set().contains(Atspi.StateType.ENABLED)
        assert not providers.get_child_at_index(1).get_state_set().contains(Atspi.StateType.ENABLED)
        xdo('key', 'Escape')
        menu(app, 'New in Project', ['linux.project.new-chat',
             'linux.project.new-manager', 'linux.project.new-shell'], process)
        xdo('key', 'Escape')
        rows = eventually(lambda: projects(app), 'return from nested menu', process)
        assert selected(rows[0]) and not selected(rows[1])

        # New Terminal admits the exact Beta target even while Alpha is selected.
        assert rows[1].get_child_at_index(0).get_action_iface().do_action(0)
        listed = menu(app, 'New in Project', ['linux.project.new-chat',
                      'linux.project.new-manager', 'linux.project.new-shell'], process)
        assert listed.get_child_at_index(2).get_action_iface().do_action(1)
        eventually(lambda: visible_title(window).startswith('Threading terminal - ') and
                   'TERMINAL_FRAME' in window_log.read_text(), 'Beta terminal', process, timeout=20)
        rows = eventually(lambda: projects(app) if projects(app) and selected(projects(app)[1])
                          else None, 'Beta selected after new terminal', process)
        assert not selected(rows[0])
        print('PASS project-row + exact-ID menu, manager refusal, nested chat provider and Beta terminal',
              flush=True)
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if daemon_process is not None and daemon_process.poll() is None:
        daemon_process.terminate()
        try:
            daemon_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_process.kill()
            daemon_process.wait(timeout=5)
