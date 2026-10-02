"""A collapsed project count occupies the Mac row's trailing slot in the native shell."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, endpoint, fixture, evidence = sys.argv[1:]
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
# in this fixture's window, so both projects still use the collapsed top-level row shape.
subprocess.run([host, str(store), endpoint, 'run', str(alpha), '/bin/true'],
               stdin=subprocess.DEVNULL, check=True, capture_output=True, timeout=12)
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
    assert dimensions == '800x480', dimensions
    rgb = subprocess.check_output(['convert', str(path), '-depth', '8', 'RGB:-'], timeout=5)
    assert len(rgb) == 800 * 480 * 3
    return rgb


def pixel(rgb, x, y):
    offset = (y * 800 + x) * 3
    return tuple(rgb[offset:offset + 3])


def trailing_ink(rgb, row):
    y0 = 56 + row * 48
    background = pixel(rgb, 700, y0 + 22)
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in range(y0 + 10, y0 + 37) for x in range(748, 779))


def slot_ink(rgb, row, x0, x1):
    y0 = 56 + row * 48
    background = pixel(rgb, 700, y0 + 22)
    return sum(max(abs(channel - ground) for channel, ground in
                   zip(pixel(rgb, x, y), background)) > 35
               for y in range(y0 + 10, y0 + 37) for x in range(x0, x1))


process = None
try:
    # Xvfb keeps the pointer position from the preceding UI fixture. Start this
    # window with the pointer above its project rows so its first frame is neutral.
    xdo('mousemove', '0', '0')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                   env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1'),
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI registration', process)
        listed = eventually(lambda: project_list(app), 'two project rows', process)
        first, second = (listed.get_child_at_index(i) for i in range(2))
        assert first.get_name().startswith('AlphaCount [0 agents, 1 terminals]')
        assert second.get_name().startswith('BetaEmpty [0 agents, 0 terminals]')
        assert selected(listed, 0) and not selected(listed, 1)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') >= 1,
                   'initial neutral project frame', process)
        initial = capture(window, 'project-count-alpha.png')
        assert trailing_ink(initial, 0) >= 8, 'nonzero count absent from trailing slot'
        assert trailing_ink(initial, 1) == 0, 'zero count painted in trailing slot'

        before_hover = log_path.read_text().count('NAVIGATOR_TEXT mounted=')
        xdo('mousemove', '--window', window, '100', '78')
        eventually(lambda: log_path.read_text().count('NAVIGATOR_TEXT mounted=') > before_hover,
                   'counted row hover repaint', process)
        hovered = capture(window, 'project-count-alpha-hover.png')
        assert slot_ink(initial, 0, 768, 778) >= 4, 'baseline count digits missing'
        assert slot_ink(hovered, 0, 768, 778) == 0, 'count did not yield its trailing slot'
        assert slot_ink(hovered, 0, 746, 766) >= 5, 'project ellipsis absent on row hover'
        assert slot_ink(hovered, 0, 700, 728) >= 5, 'project creation plus absent on row hover'
        assert project_list(app).get_child_at_index(0).get_name().startswith(
            'AlphaCount [0 agents, 1 terminals]'), 'hover changed AT-SPI totals'
        xdo('mousemove', '--window', window, '400', '300')

        xdo('windowfocus', '--sync', window, 'key', 'Down')
        eventually(lambda: selected(listed, 1) and not selected(listed, 0),
                   'keyboard selected the empty project', process)
        after_key = capture(window, 'project-count-beta-selected.png')
        assert trailing_ink(after_key, 0) >= 8, 'count disappeared when selection moved'
        assert trailing_ink(after_key, 1) == 0, 'selected empty project painted a count'

        xdo('mousemove', '--window', window, '70', '78')
        xdo('click', '--window', window, '1')
        eventually(lambda: selected(listed, 0) and not selected(listed, 1),
                   'row click selected the counted project', process)
        assert first.get_name().startswith('AlphaCount [0 agents, 1 terminals]')
        print('PASS trailing count/action hover crossfade, zero-count omission, AT-SPI totals, '
              'keyboard and click selection')
finally:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
