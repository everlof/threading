"""Exercise the installed app's Actions control under headless Weston."""
import os
from pathlib import Path
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
environment = dict(os.environ, THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='',
                   THREADING_LINUX_DATA_DIR='/tmp/threading-wayland-data',
                   THREADING_LINUX_RUNTIME_DIR='/tmp/threading-wayland-runtime',
                   THREADING_WAYLAND_CAPTURE_DIR=str(capture),
                   WAYLAND_DEBUG='client',
                   LD_PRELOAD='/tmp/wayland_capture.so')
Atspi.init()
desktop_snapshot = []


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f'{label}: installed window exited {process.returncode}; '
                                 f'{log_path.read_text()[-4000:]}')
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; desktop={desktop_snapshot}; '
                         f'{log_path.read_text()[-4000:]}')


def application():
    desktop_snapshot.clear()
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        name, pid, role = child.get_name(), child.get_process_id(), child.get_role_name()
        desktop_snapshot.append((name, pid, role))
        # Weston publishes the executable's application name through the bridge; the
        # custom ATK root name used by X11 is not the desktop registry name here.
        if pid == process.pid and role == 'application':
            return child
    return None


def descendants():
    pending = [(app, 0)]
    seen = 0
    while pending and seen < 100:
        node, depth = pending.pop(0)
        seen += 1
        yield node
        if depth < 5:
            for index in range(min(node.get_child_count(), 20)):
                child = node.get_child_at_index(index)
                if child is not None:
                    pending.append((child, depth + 1))


def accessibility_tree(node, depth=0):
    """Keep a small diagnostic when a compositor replaces the custom ATK root."""
    if node is None or depth > 3:
        return []
    try:
        lines = [f'{"  " * depth}{node.get_role_name()} name={node.get_name()!r} '
                 f'id={node.get_accessible_id()!r} children={node.get_child_count()}']
        for index in range(min(node.get_child_count(), 12)):
            lines.extend(accessibility_tree(node.get_child_at_index(index), depth + 1))
        return lines
    except Exception as error:
        return [f'{"  " * depth}{type(error).__name__}: {error}']


def listing():
    return next(item for item in descendants() if item.get_role_name() == 'list')


log_path = evidence / 'app.log'
with log_path.open('w') as log:
    process = subprocess.Popen([launcher, project], env=environment, stdout=log, stderr=log)
    try:
        app = eventually(application, 'AT-SPI application')
        try:
            button = eventually(lambda: next((item for item in descendants()
                                              if item.get_accessible_id() == 'linux.actions'), None),
                                'Actions control')
        finally:
            (evidence / 'atspi-tree.txt').write_text('\n'.join(accessibility_tree(app)) + '\n')
        placeholder = eventually(lambda: next((item for item in descendants()
                                               if item.get_role_name() == 'panel'
                                               and item.get_name() == 'Session placeholder'
                                               and item.get_child_count() == 3), None),
                                 'production idle placeholder')
        title, detail, new_session = [placeholder.get_child_at_index(index) for index in range(3)]
        assert (title.get_name(), detail.get_name(), new_session.get_name()) == (
            'No Session Selected', 'Select a session in the sidebar, or start one here.',
            'New Session')
        assert new_session.get_role_name() == 'push button'
        assert new_session.get_accessible_id() == 'linux.placeholder.action'
        assert new_session.get_action_iface().get_n_actions() == 1
        placeholder_bounds = placeholder.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (placeholder_bounds.x, placeholder_bounds.y,
                placeholder_bounds.width, placeholder_bounds.height) == (320, 0, 800, 480), \
            placeholder_bounds
        action_bounds = new_session.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (action_bounds.x >= 320 and action_bounds.x + action_bounds.width <= 1120
                and 240 <= action_bounds.y <= 400
                and action_bounds.y + action_bounds.height <= 480), \
            action_bounds
        assert button.get_role_name() == 'push button'
        assert button.get_state_set().contains(Atspi.StateType.ENABLED)
        bounds = button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        pane_bounds = listing().get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert pane_bounds.y == 82, pane_bounds
        assert (bounds.x, bounds.y, bounds.width, bounds.height) == (
            pane_bounds.width - 56, 20, 40, 40), bounds
        add_project = eventually(lambda: next((item for item in descendants()
                                               if item.get_accessible_id() == 'linux.add-project'), None),
                                 'Add project control')
        assert add_project.get_role_name() == 'push button'
        assert add_project.get_name() == 'Add Project'
        assert add_project.get_state_set().contains(Atspi.StateType.ENABLED)
        add_bounds = add_project.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (add_bounds.x, add_bounds.y, add_bounds.width, add_bounds.height) == (
            pane_bounds.width - 108, 20, 40, 40), add_bounds
        add_action = add_project.get_action_iface()
        assert add_action.get_n_actions() == 1 and add_action.get_action_name(0) == 'press'
        eventually(lambda: (capture / 'normal.bmp').is_file(), 'normal rendered frame')
        normal_name = listing().get_name()
        assert normal_name != 'Project actions', normal_name
        (capture / 'trigger').write_text('open\n')
        action = button.get_action_iface()
        assert action.get_n_actions() == 1 and action.get_action_name(0) == 'press'
        assert action.do_action(0), 'AT-SPI Actions press refused'
        eventually(lambda: listing().get_name() == 'Project actions', 'Actions menu')
        eventually(lambda: (capture / 'open.bmp').is_file(), 'open rendered frame')
        rows = listing()
        assert rows.get_child_count() > 0, 'Actions menu has no rows'
        images = [(capture / f'{state}.bmp').read_bytes() for state in ('normal', 'open')]
        for image in images:
            assert image[:2] == b'BM' and len(image) > 320 * 180 * 3, 'invalid renderer capture'
            width, height = struct.unpack_from('<ii', image, 18)
            assert 320 <= width <= 1600 and 180 <= height <= 900, (width, height)
        assert images[0] != images[1], 'Actions press did not change rendered pixels'
        # A second press closes the same menu via the production native event path.
        assert button.get_action_iface().do_action(0)
        eventually(lambda: listing().get_name() == normal_name, 'Actions menu close')
        project_row = listing().get_child_at_index(0)
        project_button = project_row.get_child_at_index(1)
        assert project_button.get_role_name() == 'push button'
        assert project_button.get_name() == 'Project actions'
        assert project_button.get_accessible_id() == (
            'sidebar.project.actions.' + project_row.get_accessible_id())
        project_bounds = project_button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (project_bounds.width, project_bounds.height) == (40, 40), project_bounds
        assert project_button.get_action_iface().do_action(0), 'project-row AT-SPI press refused'
        eventually(lambda: listing().get_name() == 'Project actions', 'project-row Actions menu')
        assert button.get_action_iface().do_action(0)
        eventually(lambda: listing().get_name() == normal_name, 'project-row menu close')
        project_row = listing().get_child_at_index(0)
        create_button = project_row.get_child_at_index(0)
        assert create_button.get_role_name() == 'push button'
        assert create_button.get_name() == 'New chat or terminal'
        assert create_button.get_accessible_id() == (
            'sidebar.project.create.' + project_row.get_accessible_id())
        create_bounds = create_button.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (create_bounds.width, create_bounds.height) == (40, 40), create_bounds
        assert create_button.get_action_iface().do_action(0), 'project-row Create AT-SPI press refused'
        create_menu = eventually(lambda: listing() if listing().get_name() == 'New in Project' else None,
                                 'project-row Create menu')
        assert [create_menu.get_child_at_index(index).get_accessible_id()
                for index in range(create_menu.get_child_count())] == [
                    'linux.project.new-chat', 'linux.project.new-manager', 'linux.project.new-shell']
        assert not create_menu.get_child_at_index(1).get_state_set().contains(Atspi.StateType.ENABLED)
        assert button.get_action_iface().do_action(0)
        eventually(lambda: listing().get_name() == normal_name, 'project-row Create close')
        assert add_action.do_action(0), 'Add Project AT-SPI press refused'
        project_menu = eventually(lambda: listing() if listing().get_name() == 'Add Project' else None,
                                  'Add Project menu')
        assert [project_menu.get_child_at_index(index).get_accessible_id()
                for index in range(project_menu.get_child_count())] == [
                    'project.new', 'project.add', 'project.scratchpad']
        assert button.get_action_iface().do_action(0)
        eventually(lambda: listing().get_name() == normal_name, 'Add Project menu close')
        print('PASS installed Wayland window, AT-SPI Add Project, row Create and Actions, changed pixels')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
