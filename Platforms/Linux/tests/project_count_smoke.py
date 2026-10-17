"""Project count, disclosure, and inline terminal selection in the native shell."""
import os
import json
import sqlite3
from pathlib import Path
import signal
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, endpoint, fixture, evidence = sys.argv[1:]
window_width = 1120
root = Path(fixture) / 'project-count-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
alpha, beta = root / 'AlphaCount', root / 'BetaEmpty'
alpha.mkdir()
beta.mkdir()
for folder in (alpha, beta):
    subprocess.run([host, '--add-project', str(store), str(folder)],
                   check=True, capture_output=True, timeout=8)
# The saved terminal remains a child of Alpha after /bin/true exits. No terminal is opened
# in this fixture's window; explicitly start both projects collapsed to inspect their badges.
subprocess.run([host, str(store), endpoint, 'run', str(alpha), '/bin/true'],
               stdin=subprocess.DEVNULL, check=True, capture_output=True, timeout=12)
with sqlite3.connect(store / 'threading.db') as database:
    for identity, payload in database.execute('SELECT id,data FROM project').fetchall():
        value = json.loads(payload)
        value['isExpanded'] = False
        database.execute('UPDATE project SET data=? WHERE id=?', (json.dumps(value), identity))
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


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def project_list(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    return matches[0] if len(matches) == 1 and matches[0].get_child_count() == 2 else None


def expanded_project_list(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    return matches[0] if len(matches) == 1 and matches[0].get_child_count() == 3 else None


def selected(listed, index):
    return listed.get_child_at_index(index).get_state_set().contains(Atspi.StateType.SELECTED)


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def capture(window, name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    dimensions = subprocess.check_output(['identify', '-format', '%wx%h', str(path)],
                                         text=True, timeout=5)
    assert dimensions == f'{window_width}x480', dimensions
    rgb = subprocess.check_output(['convert', str(path), '-depth', '8', 'RGB:-'], timeout=5)
    assert len(rgb) == window_width * 480 * 3
    return rgb


def pixel(rgb, x, y):
    offset = (y * window_width + x) * 3
    return tuple(rgb[offset:offset + 3])


# The full 240-point outline retains AppKit’s 16-point outer cell band.
# This fixture renders at 2× and subtracts that band before sampling the count/actions.
def trailing_ink(rgb, rect):
    row_right = rect.x + rect.width - 32
    background = pixel(rgb, row_right - 88, rect.y + rect.height // 2)
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in range(rect.y + 10, rect.y + 37)
               for x in range(row_right - 40, row_right - 13))


def slot_ink(rgb, rect, trailing_start, trailing_end):
    row_right = rect.x + rect.width - 32
    background = pixel(rgb, row_right - 88, rect.y + rect.height // 2)
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in range(rect.y + 10, rect.y + 37)
               for x in range(row_right - trailing_start, row_right - trailing_end))


def count_digit_ink(rgb, rect):
    # The production ellipsis replaces the count in this slot. Its three dots cross the
    # digit's middle, so sample the count's upper and lower strokes outside the dots.
    row_right = rect.x + rect.width - 32
    background = pixel(rgb, row_right - 88, rect.y + rect.height // 2)
    center = rect.y + rect.height // 2
    rows = list(range(center - 12, center - 5)) + list(range(center + 4, center + 10))
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in rows for x in range(row_right - 23, row_right - 13))


def terminal_content_ink(rgb, rect, leading_start, leading_end):
    background = pixel(rgb, rect.x + rect.width - 80, rect.y + rect.height // 2)
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in range(rect.y + 8, rect.y + rect.height - 8)
               for x in range(rect.x + leading_start, rect.x + leading_end))


process = None
try:
    # Xvfb keeps the pointer position from the preceding UI fixture. Start this
    # window with the pointer above its project rows so its first frame is neutral.
    xdo('mousemove', '0', '0')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                   env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1', THREADING_LINUX_UI_SCALE='2'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI registration', process)
        listed = eventually(lambda: project_list(app), 'two project rows', process)
        first, second = (listed.get_child_at_index(i) for i in range(2))
        assert first.get_name().startswith('AlphaCount [0 agents, 1 terminals]')
        assert second.get_name().startswith('BetaEmpty [0 agents, 0 terminals]')
        assert selected(listed, 0) and not selected(listed, 1)
        row_rects = [row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                     for row in (first, second)]
        for index, rect in enumerate(row_rects):
            assert (rect.x, rect.y, rect.width, rect.height) == (0, 110 + index * 60, 480, 60)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        # This pixel fixture has a fixed viewport; startup fitting is covered by multi_project_outline.
        xdo('windowsize', '--sync', window, '1120', '480')
        eventually(lambda: 'IDLE_PANE_FRAME 640x480 ' in log_path.read_text(), 'fixed viewport', process)
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') >= 1,
                   'initial neutral project frame', process)
        initial = capture(window, 'project-count-alpha.png')
        # At 2× the capsule begins at x=20 and the project's icon slot begins at x=58.
        # The previous host painted the identity at x=20, outside its own selection.
        center = row_rects[0].y + row_rects[0].height // 2
        selection = pixel(initial, 300, center)
        assert pixel(initial, 21, center) == selection, 'project identity escaped the selection gutter'
        assert pixel(initial, 60, center) != selection, 'project identity is absent from the inset cell'
        assert trailing_ink(initial, row_rects[0]) >= 8, 'nonzero count absent from trailing slot'
        assert trailing_ink(initial, row_rects[1]) == 0, 'zero count painted in trailing slot'

        before_hover = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        rect = row_rects[0]
        xdo('mousemove', '--window', window, str(rect.x + 88), str(rect.y + rect.height // 2))
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before_hover,
                   'counted row hover repaint', process)
        hovered = capture(window, 'project-count-alpha-hover.png')
        assert count_digit_ink(initial, rect) >= 4, 'baseline count digits missing'
        assert count_digit_ink(hovered, rect) == 0, 'count did not yield its trailing slot'
        assert slot_ink(hovered, rect, 42, 22) >= 5, 'project ellipsis absent on row hover'
        assert slot_ink(hovered, rect, 88, 60) >= 5, 'project creation plus absent on row hover'
        assert project_list(app).get_child_at_index(0).get_name().startswith(
            'AlphaCount [0 agents, 1 terminals]'), 'hover changed AT-SPI totals'
        xdo('mousemove', '--window', window, '400', '300')

        xdo('windowfocus', '--sync', window, 'key', 'Down')
        eventually(lambda: selected(listed, 1) and not selected(listed, 0),
                   'keyboard selected the empty project', process)
        after_key = capture(window, 'project-count-beta-selected.png')
        assert trailing_ink(after_key, row_rects[0]) >= 8, 'count disappeared when selection moved'
        assert trailing_ink(after_key, row_rects[1]) == 0, 'selected empty project painted a count'

        xdo('mousemove', '--window', window, str(rect.x + 100), str(rect.y + rect.height // 2))
        xdo('click', '--window', window, '1')
        eventually(lambda: selected(listed, 0) and not selected(listed, 1),
                   'row click selected the counted project', process)
        assert first.get_name().startswith('AlphaCount [0 agents, 1 terminals]')
        xdo('mousemove', '--window', window, str(rect.x + 36), str(rect.y + rect.height // 2))
        xdo('click', '--window', window, '1')
        expanded = eventually(lambda: expanded_project_list(app),
                              'project disclosure opened inline terminal', process)
        child = expanded.get_child_at_index(1)
        child_rect = child.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert (child_rect.x, child_rect.y, child_rect.width, child_rect.height) == (0, 170, 480, 56)
        assert child.get_accessible_id() not in (first.get_accessible_id(), second.get_accessible_id())
        assert selected(expanded, 0) and not selected(expanded, 1)
        expanded_pixels = capture(window, 'project-count-alpha-expanded.png')
        assert terminal_content_ink(expanded_pixels, child_rect, 86, 118) >= 16, \
            'shared terminal identity glyph absent from inline child'
        assert terminal_content_ink(expanded_pixels, child_rect, 130, 240) >= 16, \
            'shared terminal title absent from inline child'
        xdo('key', 'Down')
        eventually(lambda: selected(expanded, 1), 'inline terminal keyboard selection', process)
        selected_terminal = capture(window, 'project-count-alpha-terminal-selected.png')
        assert terminal_content_ink(selected_terminal, child_rect, 86, 118) >= 16, \
            'selected terminal identity glyph disappeared'
        assert terminal_content_ink(selected_terminal, child_rect, 130, 240) >= 16, \
            'selected terminal title disappeared'
        before_theme = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        xdo('key', 'ctrl+shift+t')
        eventually(lambda: 'THEME_APPEARANCE dark' in log_path.read_text()
                   and log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before_theme,
                   'dark outline repaint', process)
        dark_terminal = capture(window, 'project-count-alpha-terminal-dark.png')
        assert terminal_content_ink(dark_terminal, child_rect, 86, 118) >= 16, \
            'dark selected terminal identity disappeared'
        assert terminal_content_ink(dark_terminal, child_rect, 130, 240) >= 16, \
            'dark selected terminal title disappeared'
        assert pixel(dark_terminal, 400, child_rect.y + child_rect.height // 2) != \
            pixel(selected_terminal, 400, child_rect.y + child_rect.height // 2), \
            'selected outline did not adopt the dark palette'
        xdo('key', 'Up')
        eventually(lambda: selected(expanded, 0), 'project keyboard selection', process)
        xdo('key', 'space')
        eventually(lambda: project_list(app), 'space collapsed inline terminal', process)
        xdo('key', 'space')
        expanded = eventually(lambda: expanded_project_list(app),
                              'space reopened inline terminal', process)
        xdo('key', 'Down')
        eventually(lambda: selected(expanded, 1), 'terminal selected for activation', process)
        xdo('key', 'Return')
        eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(),
                   'inline terminal activated through retained runtime route', process)
        print('PASS trailing count/action hover crossfade, zero-count omission, AT-SPI totals, '
              'keyboard and click selection, inline child expansion and activation')
finally:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
