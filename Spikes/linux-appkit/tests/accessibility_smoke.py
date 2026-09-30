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
        listed = eventually(lambda: content(app) if content(app).get_child_count() == 8 else None,
                            'bounded project list')
        assert listed.get_role_name() == 'list'
        assert listed.get_description() == 'Showing 1 through 8 of 15 items'
        assert listed.get_child_count() == 8
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
        assert rect(frame_component) == (0, 0, 800, 480)
        assert rect(list_component) == (0, 52, 800, 428)
        assert rect(first_component) == (12, 56, 776, 44)
        assert rect(first_component, Atspi.CoordType.PARENT) == (12, 4, 776, 44)
        assert list_component.get_accessible_at_point(
            40, 78, Atspi.CoordType.WINDOW).get_accessible_id() == first.get_accessible_id()
        assert list_component.get_accessible_at_point(40, 101, Atspi.CoordType.WINDOW) is None
        geometry = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', window_id],
                                  capture_output=True, text=True, check=True, timeout=5)
        window_geometry = dict(re.findall(r'^(X|Y|WIDTH|HEIGHT)=(-?\d+)$',
                                          geometry.stdout, re.MULTILINE))
        assert rect(frame_component, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']), int(window_geometry['Y']), 800, 480)
        assert rect(first_component, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']) + 12, int(window_geometry['Y']) + 56, 776, 44)
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
        assert selection.select_child(1), 'AT-SPI list selection was refused'
        eventually(lambda: window_title().endswith('/Project02'), 'AT-SPI list selected second project')
        eventually(lambda: selection.get_selected_child(0)
                   if selection.is_child_selected(1) else None, 'AT-SPI list selected-child projection')
        assert selection.get_n_selected_children() == 1
        assert not selection.is_child_selected(0)
        subprocess.run(['xdotool', 'mousemove', '--window', window_id, '40', '124', 'click', '1'],
                       check=True, timeout=5)
        eventually(lambda: window_title().endswith('/Project02'), 'second row native click')
        subprocess.run(['xdotool', 'mousemove', '--window', window_id, '40', '78', 'click', '1'],
                       check=True, timeout=5)
        eventually(lambda: window_title().endswith('/Project01'), 'first row native click')
        eventually(lambda: selection.is_child_selected(0), 'pointer selection projected through AT-SPI')
        subprocess.run(['import', '-window', window_id,
                        str(Path.cwd() / 'out' / 'accessibility-list.png')], check=True, timeout=5)
        subprocess.run(['xdotool', 'windowsize', window_id, '801', '481'], check=True, timeout=5)
        eventually(lambda: rect(list_component) if rect(list_component) ==
                   (0, 52, 801, 429) else None, 'odd-size navigator frame')
        assert rect(first_component) == (12, 56, 776, 44)
        subprocess.run(['import', '-window', window_id,
                        str(Path.cwd() / 'out' / 'accessibility-list-odd.png')], check=True, timeout=5)
        subprocess.run(['xdotool', 'windowsize', window_id, '800', '480'], check=True, timeout=5)
        eventually(lambda: rect(list_component) if rect(list_component) ==
                   (0, 52, 800, 428) else None, 'restored navigator frame')
        assert first.get_state_set().contains(Atspi.StateType.FOCUSABLE)
        eventually(lambda: first if first.get_state_set().contains(Atspi.StateType.FOCUSED)
                   else None, 'selected project keyboard focus')
        for step in range(1, 11):
            subprocess.run(['xdotool', 'key', 'Down'], check=True, timeout=5)
            project_name = f'Project{step + 1:02d}' + ('-界' if step + 1 == 6 else '')
            eventually(lambda: window_title().endswith('/' + project_name),
                       f'keyboard selected {project_name}')
        listed = eventually(lambda: content(app)
                            if content(app).get_description() == 'Showing 4 through 11 of 15 items'
                            else None, 'scrolled accessible viewport')
        assert listed.get_child_count() == 8
        assert listed.get_child_at_index(7).get_state_set().contains(Atspi.StateType.SELECTED)
        assert listed.get_child_at_index(7).get_state_set().contains(Atspi.StateType.FOCUSED)
        assert selection.get_n_selected_children() == 1
        assert selection.is_child_selected(7)
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
        eventually(lambda: terminal.get_name().endswith('A11Y TERMINAL READY'),
                   'accessible terminal title')
        assert frame.get_child_count() == 2
        assert content(app).get_role_name() == 'list'
        assert listed.get_state_set().contains(Atspi.StateType.SHOWING)
        assert terminal.get_state_set().contains(Atspi.StateType.SHOWING)
        assert terminal.get_child_count() == 0
        terminal_component = terminal.get_component_iface()
        assert terminal_component is not None
        eventually(lambda: rect(frame_component) == (0, 0, 1120, 480)
                   and rect(terminal_component) == (320, 0, 800, 480)
                   and rect(list_component) == (0, 52, 320, 428), 'simultaneous workspace geometry')
        assert rect(selected.get_component_iface()) == (12, 56 + target_index * 48, 296, 44)
        assert frame_component.get_accessible_at_point(
            360, 78, Atspi.CoordType.WINDOW).get_role_name() == 'terminal'
        assert frame_component.get_accessible_at_point(
            40, 78, Atspi.CoordType.WINDOW).get_role_name() == 'list'
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
        assert rect(terminal_component) == (320, 0, 800, 480)
        assert selected.get_action_iface().get_n_actions() == 2
        subprocess.run(['xdotool', 'key', 'Tab'], check=True, timeout=5)
        eventually(lambda: terminal.get_state_set().contains(Atspi.StateType.FOCUSED)
                   and not selected.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'Tab restores terminal focus without unmounting sidebar')
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
        assert character_rect(wide) == (400, character_row * 22, 20, 22)
        assert character_rect(wide, Atspi.CoordType.PARENT) == (400, character_row * 22, 20, 22)
        assert terminal_text.get_offset_at_point(415, character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == wide
        assert terminal_text.get_offset_at_point(95, character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == -1
        accented = initial.index('e\u0301', wide)
        assert character_rect(accented) == (430, character_row * 22, 10, 22)
        assert character_rect(accented + 1) == character_rect(accented)
        assert terminal_text.get_offset_at_point(435, character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == accented
        newline = initial.index('\n', accented)
        assert character_rect(newline) == (440, character_row * 22, 0, 22)
        # AT-SPI may normalize ATK's unavailable horizontal corners on the wire.
        invalid = character_rect(len(initial))
        assert invalid[0] < 0 and invalid[1] == -1 and invalid[3] == -1, invalid
        assert terminal_text.get_offset_at_point(1119, character_row * 22 + 11,
                                                 Atspi.CoordType.WINDOW) == -1
        geometry = subprocess.run(['xdotool', 'getwindowgeometry', '--shell', window_id],
                                  capture_output=True, text=True, check=True, timeout=5)
        window_geometry = dict(re.findall(r'^(X|Y|WIDTH|HEIGHT)=(-?\d+)$',
                                          geometry.stdout, re.MULTILINE))
        assert character_rect(wide, Atspi.CoordType.SCREEN) == (
            int(window_geometry['X']) + 400,
            int(window_geometry['Y']) + character_row * 22, 20, 22)
        assert not terminal_text.set_caret_offset(0), 'read-only terminal accepted remote caret movement'
        subprocess.run(['xdotool', 'key', 'x'], check=True, timeout=5)
        updated = eventually(lambda: screen_text()
                             if 'UPDATED VISIBLE' in screen_text() else None,
                             'live accessible terminal update')
        assert 'VISIBLE 界 e\u0301' not in updated, updated
        assert terminal_text.get_character_count() == len(updated)
        assert character_rect(updated.index('UPDATED')) == (320, 0, 10, 22)
        invalid = character_rect(len(updated))
        assert invalid[0] < 0 and invalid[1] == -1 and invalid[3] == -1, invalid
        subprocess.run(['xdotool', 'windowsize', window_id, '1280', '600'], check=True, timeout=5)
        eventually(lambda: re.search(r'TERMINAL_FRAME 960x600', log_path.read_text()),
                   'resized terminal frame')
        eventually(lambda: rect(terminal_component) if rect(terminal_component) ==
                   (320, 0, 960, 600) else None, 'resized terminal component')
        assert rect(frame_component) == (0, 0, 1280, 600)
        assert rect(list_component) == (0, 52, 320, 548)
        assert frame.get_child_count() == 2
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
        assert frame.get_child_count() == 2
        assert content(app, 'terminal').get_state_set().contains(Atspi.StateType.SHOWING)
        assert rect(terminal_component) == (320, 0, 960, 600)
        assert screen_text() == resized_text
        assert terminal_text.get_offset_at_point(5, 5, Atspi.CoordType.WINDOW) == -1
        assert character_rect(0) == (320, 0, 10, 22)
        assert terminal_text.get_offset_at_point(325, 5, Atspi.CoordType.WINDOW) == 0
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
