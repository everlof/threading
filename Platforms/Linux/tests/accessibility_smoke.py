"""Query the native window through AT-SPI, then use a row action to open its PTY."""
from pathlib import Path
import ctypes
import ctypes.util
import os
import re
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, store, socket, folder = sys.argv[1:]
root = Path(folder)
log_path = root / 'accessibility-window.log'
Atspi.init()


def eventually(read, label, timeout=12):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {label}: {log_path.read_text()}'
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; window log: {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def content(app, role='list'):
    frame = app.get_child_at_index(0)
    assert frame.get_role_name() == 'frame'
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == role]
    assert len(matches) == 1, f'expected one mounted {role}'
    return matches[0]


def window_title():
    result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible', '--pid', str(process.pid),
                             '--name', '^Threading experiment - '],
                            capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return ''
    window = result.stdout.splitlines()[0]
    title = subprocess.run(['xdotool', 'getwindowname', window], capture_output=True,
                           text=True, timeout=5)
    return title.stdout.strip() if title.returncode == 0 else ''


def expose(window):
    """Damage the actual X drawable and request an exposure event without changing layout."""
    x11 = ctypes.CDLL(ctypes.util.find_library('X11'))
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XClearArea.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                              ctypes.c_uint, ctypes.c_uint, ctypes.c_int]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    assert display, 'fixture could not connect to its X display'
    try:
        x11.XClearArea(display, int(window), 0, 0, 0, 0, 1)
        x11.XSync(display, 0)
    finally:
        x11.XCloseDisplay(display)


def pixels(window):
    return subprocess.run(['import', '-window', window, 'rgba:-'],
                          check=True, capture_output=True, timeout=5).stdout


with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app', store, socket, '/usr/bin/python3',
                                str(Path(__file__).with_name('accessibility_child.py'))],
                               env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1'),
                               stdout=log, stderr=log)
    try:
        app = eventually(application, 'AT-SPI application registration')
        listed = eventually(lambda: content(app) if content(app).get_child_count() == 7 else None,
                            'bounded project list')
        assert listed.get_role_name() == 'list'
        assert listed.get_description() == 'Showing 1 through 7 of 15 items'
        assert listed.get_child_count() == 7
        first = listed.get_child_at_index(0)
        assert first.get_role_name() == 'list item'
        assert re.fullmatch(r'[0-9A-Fa-f-]{36}', first.get_accessible_id())
        assert first.get_state_set().contains(Atspi.StateType.SELECTED)
        selection = listed.get_selection_iface()
        assert selection is not None
        assert selection.get_n_selected_children() == 1
        assert selection.get_selected_child(0).get_accessible_id() == first.get_accessible_id()
        assert selection.is_child_selected(0)
        assert not selection.is_child_selected(1)
        assert not selection.clear_selection(), 'single-selection list accepted an empty selection'
        assert not selection.deselect_child(0)
        assert not selection.select_all(), 'single-selection list accepted all rows'
        window = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible', '--pid', str(process.pid),
                                 '--name', '^Threading experiment - '],
                                capture_output=True, text=True, timeout=5)
        assert window.returncode == 0
        window_id = window.stdout.splitlines()[0]
        subprocess.run(['xdotool', 'windowfocus', '--sync', window_id], check=True, timeout=5)
        frame = app.get_child_at_index(0)
        frame_component = frame.get_component_iface()
        list_component = listed.get_component_iface()
        first_component = first.get_component_iface()
        assert frame_component and list_component and first_component
        def rect(component, coordinates=Atspi.CoordType.WINDOW):
            value = component.get_extents(coordinates)
            return value.x, value.y, value.width, value.height
        def mounted_idle():
            pane = content(app, 'panel')
            if pane.get_child_count() != 3:
                return None
            return pane if pane.get_child_at_index(0).get_name() == 'No Session Selected' else None
        idle = eventually(mounted_idle, 'idle right-pane accessibility panel')
        assert [frame.get_child_at_index(i).get_role_name() for i in range(frame.get_child_count())] == [
            'list', 'panel', 'push button', 'push button']
        assert [idle.get_child_at_index(i).get_role_name() for i in range(idle.get_child_count())] == [
            'label', 'label', 'push button']
        assert idle.get_child_at_index(0).get_name() == 'No Session Selected'
        assert idle.get_child_at_index(1).get_name() == 'Select a session in the sidebar, or start one here.'
        idle_button = idle.get_child_at_index(2)
        assert idle_button.get_accessible_id() == 'linux.placeholder.action'
        assert idle_button.get_name() == 'New Session'
        assert idle_button.get_child_count() == 0
        idle_action = idle_button.get_action_iface()
        assert idle_action.get_n_actions() == 1
        assert idle_action.get_action_name(0) == 'press'
        assert rect(frame_component) == (0, 0, 1120, 480)
        assert rect(list_component) == (0, 82, 320, 398)
        assert rect(idle.get_component_iface()) == (320, 0, 800, 480)
        button_rect = rect(idle_button.get_component_iface())
        assert 320 <= button_rect[0] < 1120 and button_rect[2] > 0
        assert button_rect[0] + button_rect[2] <= 1120
        assert 0 <= button_rect[1] < 480 and button_rect[3] > 0
        assert button_rect[1] + button_rect[3] <= 480
        assert rect(idle_button.get_component_iface(), Atspi.CoordType.PARENT) == (
            button_rect[0] - 320, button_rect[1], button_rect[2], button_rect[3])
        assert idle.get_component_iface().get_accessible_at_point(
            button_rect[0] + button_rect[2] // 2,
            button_rect[1] + button_rect[3] // 2,
            Atspi.CoordType.WINDOW).get_accessible_id() == 'linux.placeholder.action'
        assert rect(first_component) == (12, 86, 296, 60)
        assert rect(first_component, Atspi.CoordType.PARENT) == (12, 4, 296, 60)
        assert list_component.get_accessible_at_point(
            40, 108, Atspi.CoordType.WINDOW).get_accessible_id() == first.get_accessible_id()
        assert list_component.get_accessible_at_point(40, 148, Atspi.CoordType.WINDOW) is None
        geometry = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', window_id],
                                  capture_output=True, text=True, check=True, timeout=5)
        window_geometry = dict(re.findall(r'^(X|Y|WIDTH|HEIGHT)=(-?\d+)$',
                                          geometry.stdout, re.MULTILINE))
        assert rect(frame_component, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']), int(window_geometry['Y']), 1120, 480)
        assert rect(first_component, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']) + 12, int(window_geometry['Y']) + 86, 296, 60)
        before_pixels = pixels(window_id)
        before_rasters = log_path.read_text().count('stage=raster.begin')
        before_repaints = log_path.read_text().count('stage=repaint.end')
        expose(window_id)
        eventually(lambda: log_path.read_text().count('stage=repaint.end') > before_repaints
                   or log_path.read_text().count('stage=raster.begin') > before_rasters,
                   'native exposure handled')
        assert log_path.read_text().count('stage=raster.begin') == before_rasters, \
            'unchanged native exposure rasterized the navigator again'
        assert pixels(window_id) == before_pixels, 'retained repaint changed native pixels'
        subprocess.run(['xdotool', 'mousemove', '--window', window_id,
                        str(button_rect[0] + button_rect[2] // 2),
                        str(button_rect[1] + button_rect[3] // 2)], check=True, timeout=5)
        eventually(lambda: 'stage=event kind=39 action=0' in log_path.read_text(),
                   'idle-pane pointer hover')
        navigator_crossings = log_path.read_text().count('stage=event kind=27 action=6')
        subprocess.run(['xdotool', 'mousemove', '--window', window_id, '40', '108'],
                       check=True, timeout=5)
        eventually(lambda: log_path.read_text().count('stage=event kind=27 action=6')
                   > navigator_crossings, 'sidebar hover from one cross-pane motion')
        assert idle_action.do_action(0), 'idle action refused AT-SPI press'
        eventually(lambda: content(app) if content(app).get_name() == 'New in Project'
                   else None, 'idle New Session opened project creation choices')
        assert content(app, 'panel').get_child_at_index(2).get_name() == 'New Session'
        subprocess.run(['xdotool', 'key', 'Escape'], check=True, timeout=5)
        eventually(lambda: content(app) if content(app).get_name() == 'Projects'
                   else None, 'idle action menu dismissed')
        first = content(app).get_child_at_index(0)
        first_component = first.get_component_iface()
        assert first.get_action_iface().do_action(0), 'could not focus navigator before Tab'
        eventually(lambda: first if first.get_state_set().contains(Atspi.StateType.FOCUSED)
                   else None, 'navigator focus before idle Tab')
        subprocess.run(['xdotool', 'key', 'Tab'], check=True, timeout=5)
        eventually(lambda: idle_button if idle_button.get_state_set().contains(
            Atspi.StateType.FOCUSED) else None, 'idle action keyboard focus')
        subprocess.run(['xdotool', 'key', 'Return'], check=True, timeout=5)
        eventually(lambda: content(app) if content(app).get_name() == 'New in Project'
                   else None, 'idle keyboard action opened project creation choices')
        subprocess.run(['xdotool', 'key', 'Escape'], check=True, timeout=5)
        eventually(lambda: content(app) if content(app).get_name() == 'Projects'
                   else None, 'idle keyboard action menu dismissed')
        first = content(app).get_child_at_index(0)
        first_component = first.get_component_iface()
        assert selection.select_child(1), 'AT-SPI list selection was refused'
        eventually(lambda: window_title().endswith('/Project02'), 'AT-SPI list selected second project')
        eventually(lambda: selection.get_selected_child(0)
                   if selection.is_child_selected(1) else None, 'AT-SPI list selected-child projection')
        assert selection.get_n_selected_children() == 1
        assert not selection.is_child_selected(0)
        subprocess.run(['xdotool', 'mousemove', '--window', window_id, '40', '108', 'click', '1'],
                       check=True, timeout=5)
        eventually(lambda: window_title().endswith('/Project01'), 'first row native click')
        eventually(lambda: selection.is_child_selected(0), 'pointer selection projected through AT-SPI')
        second_bounds = rect(listed.get_child_at_index(1).get_component_iface())
        second_center = (second_bounds[0] + second_bounds[2] // 2,
                         second_bounds[1] + second_bounds[3] // 2)
        subprocess.run(['xdotool', 'mousemove', '--window', window_id,
                        *map(str, second_center), 'click', '1'], check=True, timeout=5)
        eventually(lambda: window_title().endswith('/Project02'), 'second row native click')
        subprocess.run(['xdotool', 'mousemove', '--window', window_id, '40', '108', 'click', '1'],
                       check=True, timeout=5)
        eventually(lambda: window_title().endswith('/Project01'), 'restored first row selection')
        subprocess.run(['import', '-window', window_id,
                        str(Path.cwd() / 'out' / 'accessibility-list.png')], check=True, timeout=5)
        subprocess.run(['xdotool', 'windowsize', window_id, '1121', '481'], check=True, timeout=5)
        eventually(lambda: rect(list_component) if rect(list_component) ==
                   (0, 82, 320, 399) else None, 'odd-size navigator frame')
        assert rect(idle.get_component_iface()) == (320, 0, 801, 481)
        assert rect(first_component) == (12, 86, 296, 60)
        subprocess.run(['import', '-window', window_id,
                        str(Path.cwd() / 'out' / 'accessibility-list-odd.png')], check=True, timeout=5)
        subprocess.run(['xdotool', 'windowsize', window_id, '1120', '480'], check=True, timeout=5)
        eventually(lambda: rect(list_component) if rect(list_component) ==
                   (0, 82, 320, 398) else None, 'restored navigator frame')
        assert first.get_state_set().contains(Atspi.StateType.FOCUSABLE)
        eventually(lambda: first if first.get_state_set().contains(Atspi.StateType.FOCUSED)
                   else None, 'selected project keyboard focus')
        for step in range(1, 11):
            subprocess.run(['xdotool', 'key', 'Down'], check=True, timeout=5)
            project_name = f'Project{step + 1:02d}' + ('-界' if step + 1 == 6 else '')
            eventually(lambda: window_title().endswith('/' + project_name),
                       f'keyboard selected {project_name}')
        listed = eventually(lambda: content(app)
                            if content(app).get_description() == 'Showing 5 through 11 of 15 items'
                            else None, 'scrolled accessible viewport')
        assert listed.get_child_count() == 7
        assert listed.get_child_at_index(6).get_state_set().contains(Atspi.StateType.SELECTED)
        assert listed.get_child_at_index(6).get_state_set().contains(Atspi.StateType.FOCUSED)
        assert selection.get_n_selected_children() == 1
        assert selection.is_child_selected(6)
        target_index = next(index for index in range(listed.get_child_count())
                            if '界' in listed.get_child_at_index(index).get_name())
        target = listed.get_child_at_index(target_index)
        assert re.fullmatch(r'[0-9A-Fa-f-]{36}', target.get_accessible_id())
        assert not target.get_state_set().contains(Atspi.StateType.SELECTED)
        name = target.get_name().split(' [', 1)[0]
        assert name.startswith('Project'), name
        assert '界' in name, name
        action = target.get_action_iface()
        assert action.get_n_actions() == 2
        assert action.get_action_name(0) == 'select'
        assert action.get_action_name(1) == 'open'
        assert action.do_action(0), 'AT-SPI select action was refused'
        eventually(lambda: window_title().endswith('/' + name), 'AT-SPI selected project')
        selected = eventually(lambda: content(app).get_child_at_index(target_index)
                              if content(app).get_child_at_index(target_index).get_state_set()
                              .contains(Atspi.StateType.SELECTED) else None,
                              'AT-SPI selection state')
        assert selected.get_name().startswith(name)
        assert selected.get_state_set().contains(Atspi.StateType.FOCUSED)
        eventually(lambda: selection.is_child_selected(target_index),
                   'row action projected through AT-SPI selection')
        assert selection.get_selected_child(0).get_accessible_id() == target.get_accessible_id()
        assert selected.get_action_iface().do_action(1), 'AT-SPI open action was refused'
        terminal = eventually(lambda: content(app, 'terminal'), 'terminal accessible after row action')
        assert idle_action.get_n_actions() == 0
        eventually(lambda: terminal.get_name().endswith('A11Y TERMINAL READY'),
                   'accessible terminal title')
        assert [frame.get_child_at_index(i).get_role_name() for i in range(frame.get_child_count())] == ['list', 'push button', 'terminal', 'push button', 'push button']
        page_title = frame.get_child_at_index(1)
        assert page_title.get_accessible_id() == 'linux.page-title'
        assert page_title.get_name() == name
        assert page_title.get_child_count() == 0
        title_action = page_title.get_action_iface()
        assert title_action.get_n_actions() == 1
        assert title_action.get_action_name(0) == 'press'
        assert page_title.get_state_set().contains(Atspi.StateType.FOCUSABLE)
        assert frame.get_child_at_index(3).get_accessible_id() == 'linux.actions'
        assert frame.get_child_at_index(4).get_accessible_id() == 'linux.add-project'
        assert content(app).get_role_name() == 'list'
        assert listed.get_state_set().contains(Atspi.StateType.SHOWING)
        assert terminal.get_state_set().contains(Atspi.StateType.SHOWING)
        assert terminal.get_child_count() == 0
        terminal_component = terminal.get_component_iface()
        assert terminal_component is not None
        eventually(lambda: rect(frame_component) == (0, 0, 1120, 480)
                   and rect(terminal_component) == (320, 82, 800, 398)
                   and rect(list_component) == (0, 82, 320, 398), 'simultaneous workspace geometry')
        title_component = page_title.get_component_iface()
        title_bounds = rect(title_component)
        assert 320 <= title_bounds[0] < 1120 and title_bounds[2] > 0
        assert title_bounds[0] + title_bounds[2] <= 1120
        assert 0 <= title_bounds[1] < 82 and title_bounds[3] > 0
        assert title_bounds[1] + title_bounds[3] <= 82
        assert rect(title_component, Atspi.CoordType.PARENT) == title_bounds
        title_center = (title_bounds[0] + title_bounds[2] // 2,
                        title_bounds[1] + title_bounds[3] // 2)
        assert frame_component.get_accessible_at_point(
            *title_center, Atspi.CoordType.WINDOW).get_accessible_id() == 'linux.page-title'
        selected_bounds = rect(selected.get_component_iface())
        assert selected_bounds[0] == 12 and selected_bounds[2:] == (296, 60), selected_bounds
        assert 82 <= selected_bounds[1] and selected_bounds[1] + 60 <= 480, selected_bounds
        assert frame_component.get_accessible_at_point(
            360, 108, Atspi.CoordType.WINDOW).get_role_name() == 'terminal'
        assert frame_component.get_accessible_at_point(
            40, 108, Atspi.CoordType.WINDOW).get_role_name() == 'list'
        eventually(lambda: terminal if terminal.get_state_set().contains(Atspi.StateType.FOCUSED)
                   else None, 'terminal keyboard focus after row action')
        assert not selected.get_state_set().contains(Atspi.StateType.FOCUSED)
        # Selecting an already-selected child is a successful no-op. Its explicit row action
        # also focuses the sidebar, even while the PTY remains visible beside it.
        assert selection.select_child(target_index), 'visible sidebar refused AT-SPI selection'
        assert selected.get_action_iface().do_action(0), 'visible sidebar refused select action'
        eventually(lambda: window_title().endswith('/' + name), 'sidebar selected beside terminal')
        eventually(lambda: selected.get_state_set().contains(Atspi.StateType.FOCUSED)
                   and not terminal.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'AT-SPI action transfers focus to mounted sidebar')
        assert rect(terminal_component) == (320, 82, 800, 398)
        assert selected.get_action_iface().get_n_actions() == 2
        subprocess.run(['xdotool', 'key', 'Tab'], check=True, timeout=5)
        eventually(lambda: terminal.get_state_set().contains(Atspi.StateType.FOCUSED)
                   and not selected.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'Tab restores terminal focus without unmounting sidebar')
        page_id = selected.get_accessible_id()
        assert selection.select_child(0), 'could not move navigator away from page'
        eventually(lambda: content(app).get_selection_iface().get_selected_child(0)
                   if content(app).get_selection_iface().get_selected_child(0).get_accessible_id() != page_id
                   else None, 'navigator moved away from mounted page')
        assert title_action.do_action(0), 'page title refused AT-SPI press'
        eventually(lambda: content(app).get_selection_iface().get_selected_child(0)
                   if content(app).get_selection_iface().get_selected_child(0).get_accessible_id() == page_id
                   else None, 'page title revealed owning navigator row')
        assert content(app).get_selection_iface().get_selected_child(0).get_state_set().contains(
            Atspi.StateType.FOCUSED)
        subprocess.run(['xdotool', 'key', 'Tab'], check=True, timeout=5)
        eventually(lambda: terminal.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'Tab restores terminal focus after title reveal')
        assert terminal.get_state_set().contains(Atspi.StateType.FOCUSABLE)
        assert terminal.get_description() == 'Visible terminal screen; read only.'
        terminal_text = terminal.get_text_iface()
        assert terminal_text is not None
        def screen_text():
            return Atspi.Text.get_text(terminal_text, 0, -1)
        initial = eventually(lambda: screen_text()
                             if 'VISIBLE 界 e\u0301' in screen_text() else None,
                             'accessible visible Unicode text')
        assert 'OFFSCREEN_ONLY' not in initial, initial
        assert 'CONCEALED_MARKER' not in initial, initial
        assert terminal_text.get_character_count() == len(initial)
        assert terminal_text.get_character_at_offset(initial.index('界')) == ord('界')
        assert 0 <= terminal_text.get_caret_offset() <= len(initial)
        def character_rect(offset, coordinates=Atspi.CoordType.WINDOW):
            value = terminal_text.get_character_extents(offset, coordinates)
            return value.x, value.y, value.width, value.height
        wide = initial.index('界')
        character_row = initial[:wide].count('\n')
        assert character_rect(wide) == (400, 82 + character_row * 22, 20, 22)
        assert character_rect(wide, Atspi.CoordType.PARENT) == (80, character_row * 22, 20, 22)
        assert terminal_text.get_offset_at_point(95, character_row * 22 + 11,
                                                 Atspi.CoordType.PARENT) == wide
        assert terminal_text.get_offset_at_point(415, 82 + character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == wide
        assert terminal_text.get_offset_at_point(95, character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == -1
        accented = initial.index('e\u0301', wide)
        assert character_rect(accented) == (430, 82 + character_row * 22, 10, 22)
        assert character_rect(accented + 1) == character_rect(accented)
        assert terminal_text.get_offset_at_point(435, 82 + character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == accented
        newline = initial.index('\n', accented)
        assert character_rect(newline) == (440, 82 + character_row * 22, 0, 22)
        # AT-SPI may normalize ATK's unavailable horizontal corners on the wire.
        invalid = character_rect(len(initial))
        assert invalid[0] < 0 and invalid[1] == -1 and invalid[3] == -1, invalid
        assert terminal_text.get_offset_at_point(1119, 82 + character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == -1
        geometry = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', window_id],
                                  capture_output=True, text=True, check=True, timeout=5)
        window_geometry = dict(re.findall(r'^(X|Y|WIDTH|HEIGHT)=(-?\d+)$',
                                          geometry.stdout, re.MULTILINE))
        assert character_rect(wide, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']) + 400,
            int(window_geometry['Y']) + 82 + character_row * 22, 20, 22)
        assert not terminal_text.set_caret_offset(0), 'read-only terminal accepted remote caret movement'
        subprocess.run(['xdotool', 'key', 'x'], check=True, timeout=5)
        updated = eventually(lambda: screen_text()
                             if 'UPDATED VISIBLE' in screen_text() else None,
                             'live accessible terminal update')
        assert 'VISIBLE 界 e\u0301' not in updated, updated
        assert terminal_text.get_character_count() == len(updated)
        assert character_rect(updated.index('UPDATED')) == (320, 82, 10, 22)
        invalid = character_rect(len(updated))
        assert invalid[0] < 0 and invalid[1] == -1 and invalid[3] == -1, invalid
        # Keep the resized window wholly on the Xvfb screen; ImageMagick otherwise captures
        # only the visible right edge after SDL's initially centered window grows.
        subprocess.run(['xdotool', 'windowmove', window_id, '0', '0',
                        'windowsize', window_id, '1280', '600'], check=True, timeout=5)
        eventually(lambda: re.search(r'TERMINAL_FRAME 960x518', log_path.read_text()),
                   'resized terminal frame')
        eventually(lambda: rect(terminal_component) if rect(terminal_component) ==
                   (320, 82, 960, 518) else None, 'resized terminal component')
        assert rect(frame_component) == (0, 0, 1280, 600)
        assert rect(list_component) == (0, 82, 320, 518)
        assert [frame.get_child_at_index(i).get_role_name() for i in range(frame.get_child_count())] == ['list', 'push button', 'terminal', 'push button', 'push button']
        assert frame.get_child_at_index(1).get_accessible_id() == 'linux.page-title'
        assert frame.get_child_at_index(3).get_accessible_id() == 'linux.actions'
        assert frame.get_child_at_index(4).get_accessible_id() == 'linux.add-project'
        resized_text = screen_text()
        assert 'UPDATED VISIBLE' in resized_text
        subprocess.run(['import', '-window', window_id,
                        str(Path.cwd() / 'out' / 'accessibility-terminal.png')], check=True, timeout=5)
        with (root / 'accessibility-other-window.log').open('w+') as other_log:
            other = subprocess.Popen([binary, store], stdout=other_log, stderr=other_log)
            try:
                def other_window():
                    found = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible', '--pid', str(other.pid),
                                            '--name', '^Threading experiment - '],
                                           capture_output=True, text=True, timeout=5)
                    return next((value for value in found.stdout.splitlines()
                                 if value != window_id), None)
                other_id = eventually(other_window, 'second native window')
                subprocess.run(['xdotool', 'windowfocus', '--sync', other_id],
                               check=True, timeout=5)
                eventually(lambda: True if not terminal.get_state_set().contains(
                    Atspi.StateType.FOCUSED) else None, 'terminal focus lost to second window')
                subprocess.run(['xdotool', 'windowfocus', '--sync', other_id,
                                'key', 'alt+F4'], check=True, timeout=5)
                assert other.wait(timeout=5) == 0, other_log.read()
                subprocess.run(['xdotool', 'windowfocus', '--sync', window_id],
                               check=True, timeout=5)
                eventually(lambda: terminal if terminal.get_state_set().contains(
                    Atspi.StateType.FOCUSED) else None, 'terminal focus restored')
            finally:
                if other.poll() is None:
                    other.kill()
                other.wait(timeout=3)
        assert re.search(r'TERMINAL_FRAME .*A11Y TERMINAL READY', log_path.read_text())
        subprocess.run(['xdotool', 'key', 'ctrl+shift+p'], check=True, timeout=5)
        eventually(lambda: content(app).get_selection_iface().get_selected_child(0)
                   .get_state_set().contains(Atspi.StateType.FOCUSED)
                   and not terminal.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'sidebar focus while terminal remains mounted')
        assert [frame.get_child_at_index(i).get_role_name() for i in range(frame.get_child_count())] == ['list', 'push button', 'terminal', 'push button', 'push button']
        assert frame.get_child_at_index(1).get_accessible_id() == 'linux.page-title'
        assert frame.get_child_at_index(3).get_accessible_id() == 'linux.actions'
        assert frame.get_child_at_index(4).get_accessible_id() == 'linux.add-project'
        assert content(app, 'terminal').get_state_set().contains(Atspi.StateType.SHOWING)
        assert rect(terminal_component) == (320, 82, 960, 518)
        assert screen_text() == resized_text
        assert terminal_text.get_offset_at_point(5, 5, Atspi.CoordType.WINDOW) == -1
        assert character_rect(0) == (320, 82, 10, 22)
        assert terminal_text.get_offset_at_point(325, 5, Atspi.CoordType.WINDOW) == -1
        assert terminal_text.get_offset_at_point(325, 87, Atspi.CoordType.WINDOW) == 0
        subprocess.run(['xdotool', 'windowfocus', window_id,
                        'key', 'alt+F4'], check=True, timeout=5)
        assert process.wait(timeout=5) == 0
        print('PASS AT-SPI: bounded navigator, simultaneous panes, exact native/text geometry and independent focus',
              flush=True)
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
