"""Exercise the mounted project-row control in the real X11 window and AT-SPI tree."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'project-actions-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
for name in ('AlphaAction', 'BetaAction'):
    folder = root / name
    folder.mkdir()
    subprocess.run([host, '--add-project', str(store), str(folder)],
                   check=True, capture_output=True, timeout=8)
log_path = output / 'window.log'
daemon_log_path = output / 'daemon.log'
socket = root / 'pty.sock'
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


def listing(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    assert len(matches) == 1
    return matches[0]


def project_rows(app):
    listed = listing(app)
    if listed.get_name() != 'Projects' or listed.get_child_count() != 2:
        return None
    return [listed.get_child_at_index(index) for index in range(2)]


def selected(row):
    return row.get_state_set().contains(Atspi.StateType.SELECTED)


def capture(window, name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    assert subprocess.check_output(['identify', '-format', '%wx%h', str(path)],
                                   text=True, timeout=5) == '800x480'
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'RGB:-'], timeout=5)
    assert len(pixels) == 800 * 480 * 3
    return pixels


def changed_pixels(before, after, x0, y0, x1, y1):
    changed = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            offset = (y * 800 + x) * 3
            if max(abs(before[offset + channel] - after[offset + channel])
                   for channel in range(3)) > 28:
                changed += 1
    return changed


def dark_pixels(image, x0, y0, x1, y1):
    return sum(max(image[(y * 800 + x) * 3:(y * 800 + x) * 3 + 3]) < 80
               for y in range(y0, y1) for x in range(x0, x1))


def title(window):
    return xdo('getwindowname', window)


process = None
daemon_process = None
try:
    state = root / 'daemon'
    state.mkdir()
    with daemon_log_path.open('w+') as daemon_log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=daemon_log, stderr=daemon_log)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert daemon_process.poll() is None, daemon_log_path.read_text()
            ready = subprocess.run([daemon, 'sessions', '--json', '--socket', str(socket)],
                                   capture_output=True, timeout=5)
            if ready.returncode == 0:
                break
            time.sleep(.05)
        else:
            raise AssertionError('daemon unavailable: ' + daemon_log_path.read_text())
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), str(socket), '/bin/sh'],
                                   env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI registration', process)
        rows = eventually(lambda: project_rows(app), 'two project rows', process)
        assert rows[0].get_name().startswith('AlphaAction ')
        assert rows[1].get_name().startswith('BetaAction ')
        assert selected(rows[0]) and not selected(rows[1])
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)
        actions = []
        for index, row in enumerate(rows):
            assert row.get_child_count() == 2
            create = row.get_child_at_index(0)
            assert create.get_role_name() == 'push button'
            assert create.get_name() == 'New chat or terminal'
            assert create.get_accessible_id() == 'sidebar.project.create.' + row.get_accessible_id()
            assert create.get_action_iface().get_n_actions() == 1
            create_rect = create.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            assert (create_rect.x, create_rect.y, create_rect.width, create_rect.height) == (
                692, 58 + index * 48, 40, 40)
            button = row.get_child_at_index(1)
            assert button.get_role_name() == 'push button'
            assert button.get_name() == 'Project actions'
            assert button.get_accessible_id() == 'sidebar.project.actions.' + row.get_accessible_id()
            assert button.get_state_set().contains(Atspi.StateType.ENABLED)
            assert button.get_action_iface().get_n_actions() == 1
            rect = button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            assert (rect.x, rect.y, rect.width, rect.height) == (736, 58 + index * 48, 40, 40)
            actions.append(button)

        normal = capture(window, 'project-actions-normal.png')
        before_frame = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        xdo('mousemove', '--window', window, '100', '78')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before_frame,
                   'row hover repaint', process)
        row_hovered = capture(window, 'project-actions-row-hover.png')
        before_frame = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        xdo('mousemove', '--window', window, '756', '78')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before_frame,
                   'control hover repaint within the same row', process)
        hovered = capture(window, 'project-actions-hover.png')
        assert changed_pixels(normal, hovered, 736, 58, 776, 98) >= 8, \
            'production ellipsis did not become visible on hover'
        assert changed_pixels(row_hovered, hovered, 736, 58, 776, 98) >= 8, \
            'production control hover plate did not update within the same row'
        assert dark_pixels(hovered, 748, 68, 766, 88) >= 5, \
            'ellipsis glyph is not centered inside its production hover plate'
        assert dark_pixels(row_hovered, 704, 68, 724, 88) >= 5, \
            'plus glyph is not centered in the companion 20-point target'
        assert dark_pixels(hovered, 720, 88, 736, 100) == 0, \
            'ellipsis glyph leaked outside its 20-point target'
        assert selected(project_rows(app)[0]) and not selected(project_rows(app)[1])

        xdo('mousemove', '--window', window, '756', '126')
        xdo('click', '--window', window, '1')
        eventually(lambda: listing(app).get_name() == 'Project actions' and
                   title(window).endswith('/BetaAction'), 'Beta row pointer menu', process)
        capture(window, 'project-actions-open-beta.png')
        xdo('key', 'Escape')
        rows = eventually(lambda: project_rows(app), 'return from Beta menu', process)
        assert selected(rows[0]) and not selected(rows[1]), 'opening row menu changed selection'

        # AT-SPI and keyboard both enter the same exact-ID menu route.
        assert rows[1].get_child_at_index(1).get_action_iface().do_action(0)
        eventually(lambda: listing(app).get_name() == 'Project actions' and
                   title(window).endswith('/BetaAction'), 'Beta AT-SPI menu', process)
        xdo('key', 'Escape')
        rows = eventually(lambda: project_rows(app), 'return from accessible menu', process)
        assert selected(rows[0]) and not selected(rows[1])
        xdo('key', 'Shift+F10')
        eventually(lambda: listing(app).get_name() == 'Project actions' and
                   title(window).endswith('/AlphaAction'), 'selected project keyboard menu', process)
        xdo('key', 'Escape')
        eventually(lambda: project_rows(app), 'return from keyboard menu', process)

        # The pre-existing labeled header remains an independent pointer target.
        xdo('mousemove', '--window', window, '738', '26')
        xdo('click', '--window', window, '1')
        eventually(lambda: listing(app).get_name() == 'Project actions',
                   'header Actions pointer menu', process)
        xdo('click', '--window', window, '1')
        eventually(lambda: project_rows(app), 'header Actions close', process)

        # The row's secondary click reaches the same exact-project menu without moving
        # selection; its ordinary keyboard equivalent remains Shift+F10.
        xdo('mousemove', '--window', window, '100', '126')
        xdo('click', '--window', window, '3')
        eventually(lambda: listing(app).get_name() == 'Project actions' and
                   title(window).endswith('/BetaAction'), 'Beta row context menu', process)
        xdo('key', 'Escape')
        rows = eventually(lambda: project_rows(app), 'return from context menu', process)
        assert selected(rows[0]) and not selected(rows[1])

        # A held press can enter the newly opened host menu. Releasing on Open shell must
        # target Beta even though Alpha was still selected when the menu opened.
        xdo('mousemove', '--window', window, '756', '126')
        xdo('mousedown', '--window', window, '1')
        eventually(lambda: listing(app).get_name() == 'Project actions' and
                   title(window).endswith('/BetaAction'), 'Beta drag menu', process)
        xdo('mousemove', '--window', window, '100', '126')
        eventually(lambda: listing(app).get_child_at_index(1).get_state_set().contains(
            Atspi.StateType.SELECTED), 'drag highlighted Open shell', process)
        xdo('mouseup', '--window', window, '1')
        rows = eventually(lambda: project_rows(app) if project_rows(app) and
                          selected(project_rows(app)[1]) else None,
                          'drag release opened Beta shell', process, timeout=20)
        frame = app.get_child_at_index(0)
        assert any(frame.get_child_at_index(index).get_role_name() == 'terminal'
                   for index in range(frame.get_child_count())), 'menu release did not mount terminal'
        assert selected(rows[1]) and not selected(rows[0])
        print('PASS project ellipsis pixels, per-row AT-SPI bounds/actions, exact-ID pointer '
              'and keyboard menus, preserved menu selection, header pointer, row right-click, '
              'drag release target')
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
