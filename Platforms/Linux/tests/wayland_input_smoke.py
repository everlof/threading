"""Drive the installed SDL window with compositor-originated Wayland input."""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

launcher, project, evidence = sys.argv[1:]
evidence = Path(evidence)
capture = evidence / 'capture'
capture.mkdir(exist_ok=True)
(capture / 'trigger').write_text('normal\n')
log_path = evidence / 'app.log'
environment = dict(os.environ, THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='',
                   THREADING_LINUX_DATA_DIR='/tmp/threading-wayland-input-data',
                   THREADING_LINUX_RUNTIME_DIR='/tmp/threading-wayland-input-runtime',
                   THREADING_WAYLAND_CAPTURE_DIR=str(capture),
                   WAYLAND_DEBUG='client',
                   LD_PRELOAD='/tmp/wayland_capture.so')
Atspi.init()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f'{label}: app exited {process.returncode}; '
                                 f'{log_path.read_text()[-4000:]}')
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()[-4000:]}')


def descendants(root):
    pending = [(root, 0)]
    while pending:
        node, depth = pending.pop(0)
        yield node
        if depth < 5:
            for index in range(min(node.get_child_count(), 20)):
                child = node.get_child_at_index(index)
                if child is not None:
                    pending.append((child, depth + 1))


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_process_id() == process.pid and child.get_role_name() == 'application':
            return child
    return None


def control(identifier):
    return next((item for item in descendants(app)
                 if item.get_accessible_id() == identifier), None)


def menu_name():
    return next(item for item in descendants(app) if item.get_role_name() == 'list').get_name()


def listing():
    return next(item for item in descendants(app) if item.get_role_name() == 'list')


def selected_project_id():
    selected = listing().get_selection_iface().get_selected_child(0)
    return selected.get_accessible_id() if selected is not None else None


def has_title_focus_ring(path):
    """Sample the left edge of the fixed-palette title, clear when focus returns to the list."""
    bitmap = path.read_bytes()
    assert bitmap[:2] == b'BM', 'invalid Wayland capture'
    offset = struct.unpack_from('<I', bitmap, 10)[0]
    width, height = struct.unpack_from('<ii', bitmap, 18)
    planes, depth = struct.unpack_from('<HH', bitmap, 26)
    assert (width, height, planes, depth) == (1120, 480, 1, 32), \
        (width, height, planes, depth)
    # The production title begins at x=344. A focused title draws a nearly black
    # vertical ring here; its resting and hover plates both stay above RGB 10.
    dark_pixels = 0
    for y in range(16, 63):
        pixel = offset + (height - 1 - y) * width * 4 + 345 * 4
        if all(value < 10 for value in bitmap[pixel:pixel + 3]):
            dark_pixels += 1
    return dark_pixels > 2


def has_placeholder_icon(path, button_bounds):
    bitmap = path.read_bytes()
    assert bitmap[:2] == b'BM', 'invalid idle Wayland capture'
    offset = struct.unpack_from('<I', bitmap, 10)[0]
    width, height = struct.unpack_from('<ii', bitmap, 18)
    planes, depth = struct.unpack_from('<HH', bitmap, 26)
    assert (width, height, planes, depth) == (1120, 480, 1, 32), \
        (width, height, planes, depth)

    def pixel(x, y):
        start = offset + (height - 1 - y) * width * 4 + x * 4
        return bitmap[start:start + 3]

    ground = pixel(1100, 240)
    center = button_bounds.x + button_bounds.width // 2
    # The production stack puts a 44-point icon above its title/detail and a 32-point
    # section gap before the button. Check its own slot, away from text and button ink.
    icon_top = button_bounds.y - 260
    icon_bottom = button_bounds.y - 170
    assert 0 <= icon_top < icon_bottom <= height, button_bounds
    ink = sum(any(abs(channel - background) > 30
                  for channel, background in zip(pixel(x, y), ground))
              for y in range(icon_top, icon_bottom)
              for x in range(center - 44, center + 44))
    return ink > 50


def bmp_pixel(path, x, y):
    bitmap = path.read_bytes()
    assert bitmap[:2] == b'BM', 'invalid Wayland capture'
    offset = struct.unpack_from('<I', bitmap, 10)[0]
    width, height = struct.unpack_from('<ii', bitmap, 18)
    assert 0 <= x < width and 0 <= y < height
    start = offset + (height - 1 - y) * width * 4 + x * 4
    return bitmap[start:start + 3]


input_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
input_socket.bind(str(evidence / 'input-client'))
input_socket.settimeout(3)


def inject(command):
    input_socket.sendto(command.encode(), os.environ['THREADING_WESTON_INPUT_SOCKET'])
    answer = input_socket.recv(128)
    if command == 'origin':
        assert answer.startswith(b'ORIGIN '), (command, answer)
        return tuple(map(int, answer.decode().split()[1:]))
    assert answer == b'OK', (command, answer)


def move_to(button):
    bounds = button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert bounds.width > 0 and bounds.height > 0, bounds
    origin_x, origin_y = inject('origin')
    x = origin_x + bounds.x + bounds.width // 2
    y = origin_y + bounds.y + bounds.height // 2
    inject(f'move {x} {y}')
    return x, y, origin_x, origin_y


def click(button):
    move_to(button)
    inject('button down')
    inject('button up')


def move_window_point(x, y):
    origin_x, origin_y = inject('origin')
    inject(f'move {origin_x + x} {origin_y + y}')


def click_window_point(x, y):
    move_window_point(x, y)
    inject('button down')
    inject('button up')


project_path = Path(project)
other_project = project_path.with_name(project_path.name + 'Other')
other_project.mkdir(exist_ok=True)
data_dir = Path(environment['THREADING_LINUX_DATA_DIR'])
data_dir.mkdir(parents=True, exist_ok=True)
host = Path(launcher).parent / 'bin/LinuxHost'
subprocess.run([str(host), '--add-project', str(data_dir / 'store'), str(other_project)],
               check=True, timeout=10)


with log_path.open('w') as log:
    process = subprocess.Popen([launcher, project], env=environment, stdout=log, stderr=log)
    try:
        app = eventually(application, 'installed Wayland application')
        header = eventually(lambda: control('linux.actions'), 'header Actions button')
        initial = eventually(menu_name, 'project list')
        assert initial != 'Project actions', initial
        eventually(lambda: (capture / 'normal.bmp').is_file(), 'initial frame')
        placeholder_action = eventually(lambda: control('linux.placeholder.action'),
                                        'idle workspace New Session control')
        assert placeholder_action.get_name() == 'New Session'
        (capture / 'trigger').write_text('idle\n')
        move_to(placeholder_action)
        idle_image = capture / 'idle.bmp'
        eventually(idle_image.is_file, 'production idle placeholder frame')
        button_bounds = placeholder_action.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert has_placeholder_icon(idle_image, button_bounds), \
            'production placeholder icon is missing from the centered stack'
        assert not any(item.get_role_name() == 'terminal' for item in descendants(app)), \
            'idle workspace unexpectedly mounted a terminal'
        navigator_frames = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        inject('key 29 down')  # KEY_LEFTCTRL
        inject('key 42 down')  # KEY_LEFTSHIFT
        inject('key 20 down')  # KEY_T
        inject('key 20 up')
        inject('key 42 up')
        inject('key 29 up')
        eventually(lambda: 'THEME_APPEARANCE dark' in log_path.read_text(),
                   'physical Wayland dark appearance')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > navigator_frames,
                   'dark Wayland navigator frame')
        (capture / 'trigger').write_text('dark-idle\n')
        move_window_point(1100, 400)
        dark_idle = capture / 'dark-idle.bmp'
        eventually(dark_idle.is_file, 'dark idle Wayland frame')
        for x, y in [(300, 300), (1100, 400)]:
            assert bmp_pixel(idle_image, x, y) != bmp_pixel(dark_idle, x, y), \
                f'Wayland appearance left pane pixel unchanged at {(x, y)}'
        navigator_frames = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        inject('key 29 down')
        inject('key 42 down')
        inject('key 20 down')
        inject('key 20 up')
        inject('key 42 up')
        inject('key 29 up')
        eventually(lambda: 'THEME_APPEARANCE light' in log_path.read_text(),
                   'physical Wayland light appearance')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > navigator_frames,
                   'restored light Wayland navigator frame')
        (capture / 'trigger').write_text('light-idle\n')
        move_window_point(1100, 405)
        eventually(lambda: (capture / 'light-idle.bmp').is_file(),
                   'restored light idle Wayland frame')
        click(placeholder_action)
        eventually(lambda: menu_name() == 'New in Project',
                   'physical Wayland New Session opened project creation menu')
        assert [listing().get_child_at_index(index).get_accessible_id()
                for index in range(listing().get_child_count())] == [
                    'linux.project.new-chat', 'linux.project.new-manager', 'linux.project.new-shell']
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland New Session close')
        position = move_to(header)
        (evidence / 'pointer.txt').write_text(f'header screen center: {position}\n')
        inject('button down')
        inject('button up')
        eventually(lambda: menu_name() == 'Project actions', 'physical Wayland pointer open')
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland pointer close')

        add_project = eventually(lambda: control('linux.add-project'), 'Add Project button')
        click(add_project)
        eventually(lambda: menu_name() == 'Add Project', 'physical Wayland Add Project menu')
        assert [listing().get_child_at_index(index).get_accessible_id()
                for index in range(listing().get_child_count())] == [
                    'project.new', 'project.add', 'project.scratchpad']
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland Add Project close')

        project_create = eventually(
            lambda: next((item for item in descendants(app)
                          if (item.get_accessible_id() or '').startswith('sidebar.project.create.')), None),
            'project-row Create button')
        click(project_create)
        eventually(lambda: menu_name() == 'New in Project', 'physical Wayland project-row Create menu')
        assert [listing().get_child_at_index(index).get_accessible_id()
                for index in range(listing().get_child_count())] == [
                    'linux.project.new-chat', 'linux.project.new-manager', 'linux.project.new-shell']
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland project-row Create close')

        project_action = eventually(
            lambda: next((item for item in descendants(app)
                          if (item.get_accessible_id() or '').startswith('sidebar.project.actions.')), None),
            'project-row Actions button')
        click(project_action)
        eventually(lambda: menu_name() == 'Project actions', 'physical Wayland project-row pointer open')
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland project-row pointer close')

        project_action = eventually(
            lambda: next((item for item in descendants(app)
                          if (item.get_accessible_id() or '').startswith('sidebar.project.actions.')), None),
            'project-row context source')
        move_to(project_action)
        inject('button right-down')
        inject('button right-up')
        eventually(lambda: menu_name() == 'Project actions', 'physical Wayland project-row context menu')
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland context menu close')

        # The project was selected at launch. A real seat key chord must reach SDL and
        # the native navigator command route without relying on AT-SPI do_action.
        inject('key 42 down')  # KEY_LEFTSHIFT
        inject('key 68 down')  # KEY_F10
        inject('key 68 up')
        inject('key 42 up')
        eventually(lambda: menu_name() == 'Project actions', 'physical Wayland keyboard open')
        click(header)
        eventually(lambda: menu_name() == initial, 'physical Wayland keyboard close')

        project_action = eventually(
            lambda: next((item for item in descendants(app)
                          if (item.get_accessible_id() or '').startswith('sidebar.project.actions.')), None),
            'project-row drag source')
        source_project_id = project_action.get_accessible_id().removeprefix('sidebar.project.actions.')
        other_project_id = next(
            listing().get_child_at_index(index).get_accessible_id()
            for index in range(listing().get_child_count())
            if listing().get_child_at_index(index).get_accessible_id() != source_project_id)
        move_to(project_action)
        inject('button down')
        eventually(lambda: menu_name() == 'Project actions', 'held Wayland row press opens menu')
        open_shell = listing().get_child_at_index(1)
        assert open_shell.get_name().startswith('Open shell'), open_shell.get_name()
        move_to(open_shell)
        eventually(lambda: open_shell.get_state_set().contains(Atspi.StateType.SELECTED),
                   'held Wayland drag highlights Open shell')
        inject('button up')
        eventually(lambda: any(item.get_role_name() == 'terminal' for item in descendants(app)),
                   'Wayland drag release opened shell', timeout=20)
        eventually(lambda: menu_name() == initial, 'Wayland drag menu dismissed')
        eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(),
                   'retained terminal frame')
        (capture / 'trigger').write_text('terminal\n')
        move_window_point(380, 20)
        terminal_image = capture / 'terminal.bmp'
        eventually(terminal_image.is_file, 'terminal page title frame')

        other_row = eventually(
            lambda: next((listing().get_child_at_index(index)
                          for index in range(listing().get_child_count())
                          if listing().get_child_at_index(index).get_accessible_id() == other_project_id), None),
            'other project row')
        click(other_row)
        eventually(lambda: selected_project_id() == other_project_id,
                   'Wayland navigator selected another project')
        (capture / 'trigger').write_text('other-selected\n')
        move_window_point(700, 20)
        other_image = capture / 'other-selected.bmp'
        eventually(other_image.is_file, 'other project selected frame')

        # The page title is drawn by the retained AppKit shim but has no native AT-SPI
        # child yet. Use the compositor seat at its actual right-pane header position.
        click_window_point(380, 20)
        eventually(lambda: selected_project_id() == source_project_id,
                   'Wayland page title revealed its project')
        selected = listing().get_selection_iface().get_selected_child(0)
        assert selected.get_state_set().contains(Atspi.StateType.FOCUSED), \
            'page title reveal did not return keyboard focus to navigator'
        (capture / 'trigger').write_text('title-reveal\n')
        move_window_point(700, 20)
        revealed_image = capture / 'title-reveal.bmp'
        eventually(revealed_image.is_file, 'page title reveal frame')
        assert not has_title_focus_ring(revealed_image), \
            'page title kept its keyboard focus ring after navigator reveal'
        assert terminal_image.read_bytes() != other_image.read_bytes(), \
            'navigator selection did not change the Wayland frame'
        assert other_image.read_bytes() != revealed_image.read_bytes(), \
            'page title reveal did not change the Wayland frame'
        protocol_log = log_path.read_text()
        assert 'wl_pointer@' in protocol_log and '.button(' in protocol_log, 'no Wayland pointer button event'
        assert 'wl_keyboard@' in protocol_log and '.key(' in protocol_log, 'no Wayland keyboard key event'
        print('PASS installed Wayland controls, shell title render, title reveal, row right-click, Shift+F10 and drag release')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        input_socket.close()
