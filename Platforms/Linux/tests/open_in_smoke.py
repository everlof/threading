"""Open the active checkout through the shared split control and real GIO desktop handlers."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, socket, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'open-in'
root.mkdir()
project = root / 'Project $(touch INJECTED); name'
project.mkdir()
store = root / 'store'
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=8)
home = root / 'home'
home.mkdir()
applications = home / '.local' / 'share' / 'applications'
applications.mkdir(parents=True)
icons = home / '.local' / 'share' / 'icons' / 'hicolor' / 'scalable' / 'apps'
icons.mkdir(parents=True)
red_icon = root / 'fixture-a.png'
subprocess.run(['convert', '-size', '32x32', 'xc:#e02030', str(red_icon)],
               check=True, timeout=5)
(icons / 'threading-fixture-b.svg').write_text(
    '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" '
    'viewBox="0 0 32 32"><rect x="2" y="2" width="28" height="28" '
    'fill="#16c83a"/></svg>')
configuration = home / '.config'
configuration.mkdir()
receipts = root / 'opened.jsonl'
recorder = root / 'record_open.py'
recorder.write_text('''#!/usr/bin/python3
import json, sys
from pathlib import Path
with Path(__file__).with_name('opened.jsonl').open('a') as output:
    output.write(json.dumps({'app': sys.argv[1], 'path': sys.argv[2]}) + '\\n')
''')
for letter in 'ABCDEFGH':
    icon = str(red_icon) if letter == 'A' else (
        'threading-fixture-b' if letter == 'B' else 'folder')
    (applications / f'threading-fixture-{letter.lower()}.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=Fixture ' + letter + '\n'
        'Exec=/usr/bin/python3 ' + str(recorder) + ' ' + letter + ' %f\n'
        'Icon=' + icon + '\nMimeType=inode/directory;\nTerminal=false\n')
(configuration / 'mimeapps.list').write_text(
    '[Default Applications]\n'
    'inode/directory=threading-fixture-a.desktop;\n'
    '[Added Associations]\n'
    'inode/directory=' + ''.join(
        f'threading-fixture-{letter.lower()}.desktop;' for letter in 'ABCDEFGH') + '\n')
environment = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / '.local' / 'share'),
                   XDG_CONFIG_HOME=str(configuration), XDG_CACHE_HOME=str(home / '.cache'))
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
log_path = output / 'window.log'
Atspi.init()
process = None


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: window exited: {log_path.read_text()[-8000:]}'
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()[-8000:]}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_name() == 'Threading Linux' and app.get_process_id() == process.pid:
            return app
    return None


def child(identity):
    frame = app.get_child_at_index(0)
    return next((frame.get_child_at_index(index) for index in range(frame.get_child_count())
                 if frame.get_child_at_index(index).get_accessible_id() == identity), None)


def opened():
    return [json.loads(line) for line in receipts.read_text().splitlines()] if receipts.exists() else []


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


def icon_color_visible(name, bounds, channel):
    capture(name)
    crop = f'{bounds.width}x{bounds.height}+{bounds.x}+{bounds.y}'
    pixels = subprocess.check_output(
        ['convert', str(output / name), '-crop', crop, '+repage', '-depth', '8', 'RGB:-'],
        timeout=5)
    colors = zip(pixels[0::3], pixels[1::3], pixels[2::3])
    if channel == 'red':
        return sum(r > 150 and r > g * 1.7 and r > b * 1.7
                   for r, g, b in colors) >= 20
    return sum(g > 110 and g > r * 1.5 and g > b * 1.3
               for r, g, b in colors) >= 20


try:
    with log_path.open('w') as log:
        process = subprocess.Popen([binary, '--app', str(store), socket, '/bin/cat'],
                                   env=environment, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=log)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid)).splitlines()[0], 'native window')
        app = eventually(application, 'AT-SPI application')
        xdo('windowfocus', '--sync', window, 'key', 'Return')
        primary = eventually(lambda: child('linux.open-in.primary'), 'Open In primary')
        chooser = eventually(lambda: child('linux.open-in.chooser'), 'Open In chooser')
        assert primary.get_role_name() == chooser.get_role_name() == 'push button'
        primary_bounds = primary.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        chooser_bounds = chooser.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert primary_bounds.width > chooser_bounds.width > 0
        assert primary_bounds.x + primary_bounds.width == chooser_bounds.x
        assert primary.get_name().startswith('Open in Fixture A')
        eventually(lambda: icon_color_visible('open-in-header.png', primary_bounds, 'red'),
                   'absolute PNG app icon painted')

        xdo('key', 'super+o')
        first = eventually(lambda: opened() if len(opened()) == 1 else None,
                           'default app launched')
        assert first == [{'app': 'A', 'path': str(project)}], first
        assert not (root / 'INJECTED').exists(), 'checkout path entered a shell'

        assert chooser.get_action_iface().do_action(0)
        menu = eventually(lambda: child('linux.open-in.choices'), 'Open In app choices')
        rows = [menu.get_child_at_index(index) for index in range(menu.get_child_count())]
        second = next(row for row in rows if row.get_name() == 'Fixture B')
        capture('open-in-choices.png')
        assert second.get_action_iface().do_action(0)
        chosen = eventually(lambda: opened() if len(opened()) == 2 else None,
                            'chosen app launched')
        assert chosen[-1] == {'app': 'B', 'path': str(project)}, chosen
        eventually(lambda: child('linux.open-in.choices') is None,
                   'Open In menu dismissed')

        primary = child('linux.open-in.primary')
        assert primary.get_name().startswith('Open in Fixture B')
        bounds = primary.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        eventually(lambda: icon_color_visible('open-in-selected-b.png', bounds, 'green'),
                   'named SVG app icon painted')
        xdo('mousemove', '--window', window,
            str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2),
            'click', '1')
        repeated = eventually(lambda: opened() if len(opened()) == 3 else None,
                              'last-used primary app launched')
        assert repeated[-1] == {'app': 'B', 'path': str(project)}, repeated

        assert child('linux.open-in.chooser').get_action_iface().do_action(0)
        menu = eventually(lambda: child('linux.open-in.choices'), 'long app chooser')
        first_page = [menu.get_child_at_index(index).get_name()
                      for index in range(menu.get_child_count())]
        assert len(first_page) == 6, first_page
        xdo('windowfocus', '--sync', window, 'key', 'Next')
        def later_row():
            choices = child('linux.open-in.choices')
            if choices is None or choices.get_child_count() > 6:
                return None
            rows = [choices.get_child_at_index(index)
                    for index in range(choices.get_child_count())]
            return next((row for row in rows if row.get_name().startswith('Fixture ')
                         and row.get_name() not in first_page), None)
        later = eventually(later_row, 'virtualized later app')
        later_app = later.get_name().removeprefix('Fixture ')
        assert later.get_action_iface().do_action(0)
        paged = eventually(lambda: opened() if len(opened()) == 4 else None,
                           'later app launched')
        assert paged[-1] == {'app': later_app, 'path': str(project)}, paged

        moved = project.with_name('Removed checkout')
        project.rename(moved)
        primary = child('linux.open-in.primary')
        assert primary.get_action_iface().do_action(0)
        eventually(lambda: 'OPEN_IN_REFUSED' in log_path.read_text(),
                   'missing checkout refused')
        assert len(opened()) == 4, 'missing checkout launched an app'
        assert not (root / 'INJECTED').exists(), 'checkout path entered a shell'
        xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
        assert process.wait(timeout=6) == 0
    print('PASS Open In split control, virtualized GIO choices, last used app, exact path and stale checkout refusal',
          flush=True)
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
