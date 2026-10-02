"""Exercise the production Add Project control and three host-owned choices on X11."""
import os
from pathlib import Path
import json
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'add-project-button-fixture'
root.mkdir()
(root / 'home').mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
project = root / 'AlphaAdd'
project.mkdir()
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=8)
socket = root / 'pty.sock'
log_path = output / 'window.log'
Atspi.init()


def eventually(read, label, process, timeout=12):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: window exited: {log_path.read_text()}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; window log: {log_path.read_text()}')


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


def frame_button(app):
    frame = app.get_child_at_index(0)
    buttons = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_accessible_id() == 'linux.add-project']
    assert len(buttons) == 1
    return frame, buttons[0]


def chooser_pid(process):
    children = set()
    for task in list((Path('/proc') / str(process.pid) / 'task').iterdir())[:32]:
        try:
            children.update(int(value) for value in (task / 'children').read_text()[:4096].split())
        except FileNotFoundError:
            pass
    for pid in sorted(children)[:32]:
        try:
            if (Path('/proc') / str(pid) / 'comm').read_text().strip() == 'zenity':
                return pid
        except FileNotFoundError:
            pass
    return None


def capture(window, name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    assert subprocess.check_output(['identify', '-format', '%wx%h', str(path)],
                                   text=True, timeout=5) == '800x480'
    image = subprocess.check_output(['convert', str(path), '-depth', '8', 'RGB:-'], timeout=5)
    assert len(image) == 800 * 480 * 3
    return image


def changed_pixels(before, after, x0, y0, x1, y1):
    return sum(max(abs(before[(y * 800 + x) * 3 + channel] -
                       after[(y * 800 + x) * 3 + channel]) for channel in range(3)) > 25
               for y in range(y0, y1) for x in range(x0, x1))


process = None
daemon_process = None
try:
    state = root / 'daemon'
    state.mkdir()
    with (output / 'daemon.log').open('w+') as daemon_log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=daemon_log, stderr=daemon_log)
        eventually(lambda: subprocess.run([daemon, 'sessions', '--json', '--socket', str(socket)],
                                          capture_output=True, timeout=5).returncode == 0,
                   'daemon ready', daemon_process)
    xdo('mousemove', '0', '0')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), str(socket), '/bin/sh'],
                                   env=dict(os.environ, HOME=str(root / 'home'),
                                            THREADING_LINUX_NAVIGATION_TRACE='1'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI application', process)
        frame, button = eventually(lambda: frame_button(app), 'Add Project accessible button', process)
        assert button.get_role_name() == 'push button'
        assert button.get_name() == 'Add Project'
        assert button.get_state_set().contains(Atspi.StateType.ENABLED)
        assert button.get_action_iface().get_n_actions() == 1
        bounds = button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (bounds.x, bounds.y, bounds.width, bounds.height) == (640, 6, 40, 40)
        assert frame.get_component_iface().get_accessible_at_point(
            660, 26, Atspi.CoordType.WINDOW).get_accessible_id() == 'linux.add-project'
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        eventually(lambda: 'NAVIGATOR_TEXT mounted=' in log_path.read_text(),
                   'initial rendered frame', process)
        normal = capture(window, 'add-project-normal.png')
        before = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        xdo('mousemove', '--window', window, '660', '26')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before,
                   'production button hover frame', process)
        hover = capture(window, 'add-project-hover.png')
        assert changed_pixels(normal, hover, 640, 6, 680, 46) >= 8, \
            'production plus button did not paint its hover state'
        assert changed_pixels(normal, hover, 680, 6, 688, 46) == 0, \
            'plus hover leaked outside its slot toward Actions'

        def menu():
            listing = frame.get_child_at_index(0)
            assert listing.get_name() == 'Add Project'
            rows = [listing.get_child_at_index(i) for i in range(listing.get_child_count())]
            assert [(row.get_accessible_id(), row.get_name()) for row in rows] == [
                ('project.new', 'Start New Project…'),
                ('project.add', 'Use an Existing Folder…'),
                ('project.scratchpad', 'New Scratchpad')]
            assert all(row.get_action_iface().get_n_actions() == 2 for row in rows)
            return rows

        xdo('mousemove', '--window', window, '660', '26')
        xdo('click', '--window', window, '1')
        rows = eventually(menu, 'pointer Add Project menu', process)
        assert chooser_pid(process) is None, 'plus press bypassed its menu'
        capture(window, 'add-project-menu.png')
        # The separator before Scratchpad is visible below the second row and does not
        # insert an actionable item in AT-SPI's bounded three-choice list.
        xdo('windowfocus', '--sync', window, 'key', 'Escape')
        eventually(lambda: frame.get_child_at_index(0).get_name() == 'Projects',
                   'Add Project menu dismissed', process)

        def dismiss_chooser(label, title='Add project folder'):
            pid = eventually(lambda: chooser_pid(process), label, process)
            chooser = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                             str(pid), '--name', title),
                                 label + ' dialog', process).splitlines()[0]
            eventually(lambda: not frame_button(app)[1].get_state_set().contains(
                Atspi.StateType.ENABLED), label + ' button disabled during chooser', process)
            cancelled = log_path.read_text().count('PROJECT_IMPORT_CANCELLED')
            xdo('windowfocus', '--sync', chooser, 'key', 'Escape')
            eventually(lambda: log_path.read_text().count('PROJECT_IMPORT_CANCELLED') > cancelled,
                       label + ' cancelled', process)
            eventually(lambda: frame_button(app)[1].get_state_set().contains(Atspi.StateType.ENABLED),
                       label + ' button reenabled', process)

        # AT-SPI opens the same menu, and its existing-folder row opens the old chooser.
        assert frame_button(app)[1].get_action_iface().do_action(0)
        rows = eventually(menu, 'AT-SPI Add Project menu', process)
        assert rows[1].get_action_iface().do_action(1)
        dismiss_chooser('AT-SPI existing folder')
        xdo('windowfocus', '--sync', window, 'key', 'ctrl+shift+p')
        dismiss_chooser('keyboard existing folder')

        # Save-style chooser supplies the name and place, then the host creates the folder
        # and imports exactly that path. A cancelled save must not create anything.
        assert frame_button(app)[1].get_action_iface().do_action(0)
        rows = eventually(menu, 'new project menu', process)
        assert rows[0].get_action_iface().do_action(1)
        dismiss_chooser('cancel new project', title='New Project')
        new_project = root / 'CreatedProject'
        assert not new_project.exists()

        assert frame_button(app)[1].get_action_iface().do_action(0)
        rows = eventually(menu, 'create project menu', process)
        assert rows[0].get_action_iface().do_action(1)
        pid = eventually(lambda: chooser_pid(process), 'new project chooser', process)
        chooser = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                         str(pid), '--name', 'New Project'),
                             'new project dialog', process).splitlines()[0]
        xdo('windowfocus', '--sync', chooser)
        xdo('key', 'ctrl+l')
        xdo('type', '--clearmodifiers', '--', str(new_project))
        xdo('key', 'Return')
        eventually(lambda: new_project.is_dir() and
                   'PROJECT_IMPORTED ' + str(new_project) in log_path.read_text(),
                   'new project created and selected', process)

        # Scratchpad needs no picker. Its identity is stored, pinned above ordinary
        # projects, and remains stable when the command is repeated.
        assert frame_button(app)[1].get_action_iface().do_action(0)
        rows = eventually(menu, 'scratchpad menu', process)
        assert rows[2].get_action_iface().do_action(1)
        scratchpad = root / 'home' / 'Threading' / 'Scratchpad'
        eventually(lambda: scratchpad.is_dir() and
                   'PROJECT_IMPORTED ' + str(scratchpad) in log_path.read_text(),
                   'scratchpad created and selected', process)
        assert (scratchpad / 'README.md').is_file()
        assert (scratchpad / '.gitignore').read_text() == '.DS_Store\n'
        with sqlite3.connect(store / 'threading.db') as database:
            records = [(identifier, json.loads(payload)) for identifier, payload in
                       database.execute('SELECT id, data FROM project ORDER BY position')]
        scratch = [item for item in records if item[1].get('isScratchpad')]
        assert len(scratch) == 1 and scratch[0][1]['folderPath'] == str(scratchpad)
        assert frame.get_child_at_index(0).get_child_at_index(0).get_accessible_id() == scratch[0][0], \
            'Scratchpad did not pin above projects'
        (scratchpad / 'README.md').write_text('My notes\n')
        assert frame_button(app)[1].get_action_iface().do_action(0)
        rows = eventually(menu, 'repeat scratchpad menu', process)
        assert rows[2].get_action_iface().do_action(1)
        eventually(lambda: log_path.read_text().count('PROJECT_IMPORTED ' + str(scratchpad)) == 2,
                   'scratchpad reopened', process)
        with sqlite3.connect(store / 'threading.db') as database:
            again = [(identifier, json.loads(payload)) for identifier, payload in
                     database.execute('SELECT id, data FROM project ORDER BY position')]
        assert len(again) == len(records)
        assert next(identifier for identifier, row in again if row.get('isScratchpad')) == scratch[0][0]
        assert (scratchpad / 'README.md').read_text() == 'My notes\n'
        print('PASS mounted Add Project glyph/hover, pointer/AT-SPI three-choice menu, '
              'existing-folder shortcut, new folder creation, durable Scratchpad identity')
finally:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if daemon_process is not None and daemon_process.poll() is None:
        daemon_process.send_signal(signal.SIGTERM)
        try:
            daemon_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_process.kill()
            daemon_process.wait(timeout=5)
