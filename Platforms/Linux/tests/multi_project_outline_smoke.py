"""Independent project disclosures and stable child selection in the native sidebar."""
import json
import fcntl
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'multi-project-outline'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
for name in ('Alpha', 'Beta', 'GammaEmpty'):
    folder = root / name
    folder.mkdir()
    subprocess.run([host, '--add-project', str(store), str(folder)],
                   check=True, capture_output=True, timeout=8)
    if name != 'GammaEmpty':
        subprocess.run([host, str(store), endpoint, 'run', str(folder), '/bin/true'],
                       stdin=subprocess.DEVNULL, check=True, capture_output=True, timeout=12)
# This journey explicitly starts collapsed; fresh product projects default to expanded.
with sqlite3.connect(store / 'threading.db') as database:
    for identity, payload in database.execute('SELECT id,data FROM project').fetchall():
        value = json.loads(payload)
        assert value['isExpanded'] is True, 'new projects must inherit the Mac expanded default'
        value['isExpanded'] = False
        database.execute('UPDATE project SET data=? WHERE id=?', (json.dumps(value), identity))
log_path = output / 'window.log'
Atspi.init()
pointer_over_row = False


def xdo(*args):
    return subprocess.run(['xdotool', *map(str, args)], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def eventually(read, label):
    deadline = time.monotonic() + 12
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
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child


def rows(count):
    frame = app.get_child_at_index(0)
    for index in range(frame.get_child_count()):
        listed = frame.get_child_at_index(index)
        if listed.get_role_name() == 'list' and listed.get_child_count() == count:
            return [listed.get_child_at_index(i) for i in range(count)]


def selected_identity(current):
    return next((row.get_accessible_id() for row in current
                 if row.get_state_set().contains(Atspi.StateType.SELECTED)), None)


def press(row, disclosure=False):
    global pointer_over_row
    wait_for_expansion()
    pointer_over_row = True
    rect = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, 18 * scale if disclosure else 100 * scale,
        rect.y + rect.height // 2)
    xdo('click', '--window', window, 1)


def expansion_state():
    with sqlite3.connect(store / 'threading.db') as database:
        return {json.loads(payload)['name']: json.loads(payload)['isExpanded']
                for (payload,) in database.execute('SELECT data FROM project')}


def wait_for_expansion():
    eventually(lambda: log_path.read_text().count('OUTLINE_EXPANSION_SAVED ') +
               log_path.read_text().count('OUTLINE_EXPANSION_REFUSED ') >=
               log_path.read_text().count('OUTLINE_EXPANSION_PENDING '), 'disclosure committed')


def capture(name):
    global pointer_over_row
    before = log_path.read_text().count('OUTLINE_FRAME ')
    xdo('mousemove', '--window', window, 600, 440)
    if pointer_over_row:
        eventually(lambda: log_path.read_text().count('OUTLINE_FRAME ') > before,
                   'pointer exit repaint')
    pointer_over_row = False
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


def assert_disclosure_pixels(name, row, palette):
    """A quiet disclosure keeps the small chevron role and authored ink in the real row."""
    path = output / name
    width, height = map(int, subprocess.check_output(
        ['identify', '-format', '%w %h', str(path)], timeout=5).split())
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'rgb:-'], timeout=5)
    rect = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    ground = [round(channel * 255) for channel in palette['sidebar.navigatorWell'][:3]]
    ink = palette['text.tertiary']
    delta = [channel * 255 - base for channel, base in zip(ink[:3], ground)]
    magnitude = sum(channel * channel for channel in delta)
    points, opacities = [], []
    for y in range(max(0, rect.y), min(height, rect.y + rect.height)):
        for x in range(12 * scale, 25 * scale):
            offset = (y * width + x) * 3
            difference = [channel - base for channel, base in zip(pixels[offset:offset + 3], ground)]
            if max(abs(channel) for channel in difference) <= 2:
                continue
            points.append((x, y))
            opacities.append(sum(channel * direction for channel, direction in zip(difference, delta)) / magnitude)
    assert points, 'project disclosure disappeared'
    size = (max(x for x, _ in points) - min(x for x, _ in points) + 1,
            max(y for _, y in points) - min(y for _, y in points) + 1)
    assert size[0] <= 6 * scale and size[1] <= 5 * scale, ('oversized disclosure', size)
    assert ink[3] * .3 < max(opacities) <= ink[3] + .015, (
        'disclosure must retain the authored tertiary ink without a second contrast lift', max(opacities), ink[3])
    covered_area = sum(opacities) / ink[3]
    assert covered_area < 5 * scale * scale, (
        'disclosure is too heavy or has an unintended closing edge', covered_area, scale)


process = None
try:
    xdo('mousemove', 0, 0)
    scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                   env=dict(os.environ, THREADING_LINUX_UI_SCALE=str(scale)),
                                   stdout=log, stderr=log)
        app = eventually(application, 'AT-SPI application')
        current = eventually(lambda: rows(3), 'three collapsed projects')
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                        '--name', '^Threading experiment - '), 'native window').splitlines()[0]
        display_width, display_height = map(int, xdo('getdisplaygeometry').split())
        expected_width = max(240 * scale + 320, min(1120 * scale, display_width, 240 * scale + 1280))
        expected_height = max(180, min(480 * scale, display_height, 900))
        geometry = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', window).splitlines())
        assert (int(geometry['WIDTH']), int(geometry['HEIGHT'])) == (expected_width, expected_height), geometry
        eventually(lambda: 'IDLE_PANE_FRAME ' in log_path.read_text(), 'first placeholder paint')
        first_pane = log_path.read_text().split('IDLE_PANE_FRAME ', 1)[1].split(' ', 1)[0]
        assert first_pane == f'{expected_width - 240 * scale}x{expected_height}', (
            'first paint ignored the native startup geometry', first_pane, geometry)
        capture('initial-projects-collapsed.png')
        if os.environ.get('THREADING_TEST_WINDOW_STARTUP_ONLY') == '1':
            print(f'PASS native startup scale={scale}, display={display_width}x{display_height}, '
                  f'window={expected_width}x{expected_height}, first pane={first_pane}')
            raise SystemExit(0)
        alpha_id = current[0].get_accessible_id()
        press(current[0], disclosure=True)
        current = eventually(lambda: rows(4), 'Alpha expanded')
        press(current[2], disclosure=True)
        current = eventually(lambda: rows(5), 'both projects expanded')
        assert selected_identity(current) == alpha_id, 'disclosure selected an unrelated project'
        assert current[0].get_name().startswith('Alpha ')
        assert current[2].get_name().startswith('Beta ')
        assert current[4].get_name().startswith('GammaEmpty ')
        alpha_child, beta_child = current[1].get_accessible_id(), current[3].get_accessible_id()
        assert alpha_child != beta_child
        press(current[3])
        eventually(lambda: selected_identity(rows(5)) == beta_child, 'Beta child selected')
        capture('both-expanded-beta-selected.png')
        palette = json.loads((Path(binary).parent /
            'LinuxAppKitSpike_WindowHarness.resources/Theme/threading.json').read_text())
        assert_disclosure_pixels('both-expanded-beta-selected.png', current[0], palette['light'])

        press(current[0], disclosure=True)
        current = eventually(lambda: rows(4), 'Alpha collapsed independently')
        assert selected_identity(current) == beta_child, 'unrelated collapse changed selected child'
        assert current[2].get_accessible_id() == beta_child, 'Beta child identity changed after collapse'
        press(current[0], disclosure=True)
        current = eventually(lambda: rows(5), 'Alpha reopened independently')
        assert selected_identity(current) == beta_child
        capture('both-expanded-restored.png')

        # An empty branch can change disclosure direction without changing the list or selection.
        before = log_path.read_text().count('OUTLINE_EXPANSION ')
        press(current[4], disclosure=True)
        eventually(lambda: log_path.read_text().count('OUTLINE_EXPANSION ') > before
                   and 'OUTLINE_FRAME ' in log_path.read_text().rsplit('OUTLINE_EXPANSION ', 1)[-1],
                   'empty project expansion')
        assert selected_identity(rows(5)) == beta_child
        capture('empty-project-expanded.png')
        xdo('windowfocus', '--sync', window, 'key', 'ctrl+shift+t')
        eventually(lambda: 'OUTLINE_FRAME ' in log_path.read_text().split('THEME_APPEARANCE dark\n')[-1]
                   and 'THEME_APPEARANCE dark' in log_path.read_text(), 'dark outline')
        capture('all-expanded-dark.png')
        assert_disclosure_pixels('all-expanded-dark.png', current[0], palette['dark'])

        # Keyboard traversal visits both branches in their visible order.
        xdo('key', 'Left')
        eventually(lambda: selected_identity(rows(5)) == current[2].get_accessible_id(), 'Beta parent selected')
        capture('project-selected-dark.png')
        xdo('key', 'Left')
        current = eventually(lambda: rows(4), 'keyboard collapsed Beta only')
        assert current[1].get_accessible_id() == alpha_child
        eventually(lambda: expansion_state()['Beta'] is False, 'keyboard collapse committed')
        xdo('key', 'Right')
        current = eventually(lambda: rows(5), 'keyboard reopened Beta')
        eventually(lambda: expansion_state()['Beta'] is True, 'keyboard expansion committed')
        xdo('key', 'Right')
        assert selected_identity(rows(5)) == current[2].get_accessible_id(), 'Right on an open project moved selection'
        xdo('key', 'Down')
        eventually(lambda: selected_identity(rows(5)) == beta_child, 'keyboard reached Beta child')
        xdo('key', 'Right')
        assert selected_identity(rows(5)) == beta_child, 'Right on a terminal changed selection'
        capture('keyboard-expanded.png')
        # Exercise the standing form at a narrow pane and another 40pt of pressure.
        # Resize the real window so layout, backing scale and accessible action geometry agree.
        for pane_width in (360, 320):
            before = len(log_path.read_text())
            xdo('windowsize', '--sync', window, (240 + pane_width) * scale, 240 * scale)
            eventually(lambda: f'IDLE_PANE_FRAME {pane_width * scale}x{240 * scale} '
                       in log_path.read_text()[before:], f'{pane_width}pt placeholder resize')
            capture(f'placeholder-{pane_width}pt-dark.png')
            frame = app.get_child_at_index(0)
            pane = next(frame.get_child_at_index(index) for index in range(frame.get_child_count())
                        if frame.get_child_at_index(index).get_role_name() == 'panel')
            action = next(pane.get_child_at_index(index) for index in range(pane.get_child_count())
                          if pane.get_child_at_index(index).get_accessible_id() == 'linux.placeholder.action')
            bounds = action.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            assert action.get_name() == 'Start Session'
            assert not action.get_state_set().contains(Atspi.StateType.ENABLED)
            assert 240 * scale <= bounds.x < bounds.x + bounds.width <= (240 + pane_width) * scale
            assert 0 <= bounds.y < bounds.y + bounds.height <= 240 * scale
            assert selected_identity(rows(5)) == beta_child, 'resize changed the selected terminal'
        xdo('key', 'Return')
        eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(), 'terminal pane activated')
        with sqlite3.connect(store / 'threading.db') as database:
            selected_terminal = database.execute(
                "SELECT value FROM app_state WHERE key='selectedTerminalID'").fetchone()
        assert selected_terminal == (beta_child,), ('wrong terminal activated', selected_terminal, beta_child)
        eventually(lambda: expansion_state() == {'Alpha': True, 'Beta': True, 'GammaEmpty': True},
                   'all disclosure states committed')
        # A refusal rolls the visible branch back without damaging persisted state.
        with (store / 'host.lock').open('r+') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            before_refusal = log_path.read_text().count('OUTLINE_EXPANSION_REFUSED ')
            press(rows(5)[2], disclosure=True)
            eventually(lambda: log_path.read_text().count('OUTLINE_EXPANSION_REFUSED ') > before_refusal,
                       'busy store disclosure refusal')
            eventually(lambda: rows(5), 'refused disclosure restored')
        assert expansion_state()['Beta'] is True
        eventually(lambda: selected_identity(rows(5)) == beta_child, 'refused collapse restored selected child')
        # Finish with mixed state, then restart the real app over exactly the same store.
        # Count-based waits above include the refused attempt, so use a direct gesture here.
        rect = rows(5)[0].get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, 18 * scale, rect.y + rect.height // 2)
        xdo('click', '--window', window, 1)
        eventually(lambda: expansion_state() == {'Alpha': False, 'Beta': True, 'GammaEmpty': True},
                   'mixed expansion committed')
        process.terminate()
        process.wait(timeout=5)
        pointer_over_row = True
        log_path = output / 'window-restarted.log'
        with log_path.open('w+') as restarted_log:
            process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                       env=dict(os.environ, THREADING_LINUX_UI_SCALE=str(scale)),
                                       stdout=restarted_log, stderr=restarted_log)
            app = eventually(application, 'restarted AT-SPI application')
            window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                            '--name', '^Threading'), 'restarted window').splitlines()[0]
            current = eventually(lambda: rows(4), 'restored mixed expansion')
            assert current[0].get_accessible_id() == alpha_id
            assert current[2].get_accessible_id() == beta_child
            assert selected_identity(current) == beta_child, 'restored runtime was not selected in the ordinary outline'
            assert current[3].get_name().startswith('GammaEmpty ')
            eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(), 'selected runtime reattached')
            capture('mixed-expansion-restarted.png')
            assert 'OUTLINE_EXPANSION_SAVED ' not in log_path.read_text(), 'restoration rewrote standing state'
            # Empty branch direction must also restore: first click now collapses it.
            press(current[3], disclosure=True)
            eventually(lambda: expansion_state()['GammaEmpty'] is False, 'restored empty branch collapsed')
            capture('empty-expansion-collapsed-after-restart.png')
            # A selected live terminal inside a collapsed project is revealed on the next launch.
            press(rows(4)[1], disclosure=True)
            eventually(lambda: expansion_state()['Beta'] is False, 'selected runtime parent folded away')
            process.terminate()
            process.wait(timeout=5)
            pointer_over_row = True
            log_path = output / 'window-revealed.log'
            with log_path.open('w+') as revealed_log:
                process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                           env=dict(os.environ, THREADING_LINUX_UI_SCALE=str(scale)),
                                           stdout=revealed_log, stderr=revealed_log)
                app = eventually(application, 'revealed AT-SPI application')
                current = eventually(lambda: rows(4) if rows(4) and selected_identity(rows(4)) == beta_child else None,
                                     'selected terminal revealed without a catalog')
                window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                                '--name', '^Threading'), 'revealed window').splitlines()[0]
                eventually(lambda: expansion_state() == {'Alpha': False, 'Beta': True, 'GammaEmpty': False},
                           'only restored runtime parent expanded')
                eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(), 'revealed terminal attached')
                capture('selected-runtime-parent-revealed.png')
                assert 'TERMINAL_PICKER_FRAME ' not in log_path.read_text(), 'restart opened a saved-runtime picker'
                assert log_path.read_text().count('OUTLINE_EXPANSION_SAVED ') == 1
            print('PASS pointer/keyboard/empty expansion persists across restart; busy-store rollback; '
                  'runtime selection and project identities preserved')
        print('PASS independent/empty disclosures, preserved sibling selection, stable child identities, '
              'keyboard traversal and activation in both appearances')
finally:
    if process is not None and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
