"""Drive the installed SDL window with compositor-originated Wayland input."""
import os
from pathlib import Path
import socket
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


with log_path.open('w') as log:
    process = subprocess.Popen([launcher, project], env=environment, stdout=log, stderr=log)
    try:
        app = eventually(application, 'installed Wayland application')
        header = eventually(lambda: control('linux.actions'), 'header Actions button')
        initial = eventually(menu_name, 'project list')
        assert initial != 'Project actions', initial
        eventually(lambda: (capture / 'normal.bmp').is_file(), 'initial frame')
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
        protocol_log = log_path.read_text()
        assert 'wl_pointer@' in protocol_log and '.button(' in protocol_log, 'no Wayland pointer button event'
        assert 'wl_keyboard@' in protocol_log and '.key(' in protocol_log, 'no Wayland keyboard key event'
        print('PASS installed Wayland header/add/project Create and Actions pointer, row right-click, Shift+F10 and drag release')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        input_socket.close()
