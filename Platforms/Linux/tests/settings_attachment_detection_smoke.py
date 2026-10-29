"""The shared Attachments Settings card controls the installed Linux scanners."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'settings-attachment-detection'
root.mkdir()
project = root / 'Project'
project.mkdir()
store = root / 'store'
home = root / 'home'
home.mkdir()
(home / '.config').mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, '--add-project', str(store), str(project)], env=environment,
               check=True, capture_output=True, timeout=15)
Atspi.init()


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)],
                                   text=True, timeout=5).strip()


def pixel(path, x, y):
    return subprocess.check_output(
        ['convert', str(path), '-format', f'%[pixel:p{{{x},{y}}}]', 'info:'],
        text=True, timeout=5).strip()


def capture_matching(window, path, x, y, expected):
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    return pixel(path, x, y) == expected


def eventually(read, label, process, seconds=20):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: process exited'
        try:
            value = read()
            if value:
                return value
        except (IndexError, subprocess.CalledProcessError) as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def descendants(node):
    yield node
    for index in range(node.get_child_count()):
        yield from descendants(node.get_child_at_index(index))


def control(process, identity):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() == process.pid:
            return next((node for node in descendants(app)
                         if node.get_accessible_id() == identity), None)
    return None


for visit in ('first', 'reopened'):
    log_path = output / f'settings-attachments-{visit}.log'
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                    '/bin/sh', '/bin/true'], env=environment,
                                   stdout=log, stderr=log)
        try:
            window = eventually(lambda: xdo('search', '--all', '--onlyvisible',
                                             '--pid', process.pid).splitlines()[-1],
                                'main window', process)
            footer = eventually(lambda: control(process, 'sidebar.settings'),
                                'Settings footer', process)
            assert footer.get_action_iface().do_action(0)
            page = eventually(lambda: control(process, 'settings.page'),
                              'Settings page selector', process)
            assert page.get_action_iface().do_action(0)
            chats = eventually(lambda: control(process, 'settings.menu.settings.page.1'),
                               'Chats page choice', process)
            assert chats.get_action_iface().do_action(0)
            eventually(lambda: 'SETTINGS_PAGE_SELECTED value=Chats' in log_path.read_text(),
                       'Chats page', process)

            def resize_settings_window():
                candidates = xdo('search', '--all', '--onlyvisible',
                                 '--pid', process.pid).splitlines()
                for candidate in reversed(candidates):
                    try:
                        xdo('windowsize', candidate, 1120, 900)
                        return candidate
                    except subprocess.CalledProcessError:
                        continue
                return None

            window = eventually(resize_settings_window, 'resizable Settings window', process)
            xdo('windowmove', window, 0, 0)
            eventually(lambda: re.search(r'^HEIGHT=900$',
                       xdo('getwindowgeometry', '--shell', window), re.MULTILINE),
                       '900-pixel Settings window', process)
            eventually(lambda: 'SETTINGS_FRAME 880x859' in log_path.read_text(),
                       'full-height Chats page', process)
            xdo('mousemove', '--window', window, 650, 600)
            toggle_id = 'settings.chats.codex-attachment-detection'

            def scratchpad_y():
                anchors = re.findall(
                    r'SETTINGS_SCRATCHPAD_ANCHOR kind=choose x=[\d.]+ y=([\d.-]+)',
                    log_path.read_text())
                return float(anchors[-1]) if anchors else float('-inf')

            for _ in range(45):
                if scratchpad_y() >= 30:
                    break
                before_scroll_frames = log_path.read_text().count('SETTINGS_FRAME ')
                xdo('click', 5)
                eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ')
                           > before_scroll_frames, 'Settings scroll rendered', process,
                           seconds=8)
            assert scratchpad_y() >= 30, 'Attachments card did not scroll into view'
            toggle = eventually(lambda: control(process, toggle_id),
                                'shared attachment toggle', process)
            assert toggle.get_name() == 'Detect attachments from Codex'
            outside = eventually(
                lambda: control(process, 'settings.chats.outside-project-attachments'),
                'outside-project attachment toggle', process)
            assert outside.get_name() == 'Include files outside the project'
            loaded = ('SETTINGS_ATTACHMENT_DETECTION_LOADED kind=codex '
                      + f'enabled={visit == "first"}').lower()
            assert loaded in log_path.read_text().lower()
            scope_loaded = ('SETTINGS_OUTSIDE_PROJECT_LOADED '
                            + f'enabled={visit == "reopened"}').lower()
            assert scope_loaded in log_path.read_text().lower()
            if visit == 'first':
                time.sleep(.2)
                initial_capture = output / 'settings-attachments-enabled.png'
                subprocess.run(['import', '-window', window, str(initial_capture)],
                               check=True, timeout=5)
                on_track = pixel(initial_capture, 1004, 490)
                off_track = pixel(initial_capture, 1004, 748)
                assert on_track != off_track, 'attachment scope track did not distinguish states'
                assert toggle.get_action_iface().do_action(0)
                eventually(lambda: 'SETTINGS_ATTACHMENT_DETECTION_CHANGED '
                           'kind=codex enabled=false' in log_path.read_text(),
                           'Codex detection disabled', process)
                before_scope_frames = log_path.read_text().count('SETTINGS_FRAME ')
                assert outside.get_action_iface().do_action(0)
                eventually(lambda: 'SETTINGS_OUTSIDE_PROJECT_CHANGED enabled=true'
                           in log_path.read_text(), 'outside scope enabled', process)
                eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ')
                           > before_scope_frames, 'outside scope repainted', process)
                eventually(lambda: capture_matching(
                    window, output / 'settings-outside-project-enabled.png',
                    1004, 748, on_track), 'outside scope rendered on', process,
                    seconds=12)
            else:
                time.sleep(.2)
                subprocess.run(['import', '-window', window,
                                str(output / 'settings-attachments-disabled.png')],
                               check=True, timeout=5)
                before_scope_frames = log_path.read_text().count('SETTINGS_FRAME ')
                assert outside.get_action_iface().do_action(0)
                eventually(lambda: 'SETTINGS_OUTSIDE_PROJECT_CHANGED enabled=false'
                           in log_path.read_text(), 'outside scope disabled', process)
                eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ')
                           > before_scope_frames, 'outside scope repainted', process)
                eventually(lambda: capture_matching(
                    window, output / 'settings-outside-project-disabled.png',
                    1004, 748, off_track), 'outside scope rendered off', process,
                    seconds=12)
            xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
            assert process.wait(timeout=8) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

print('PASS shared Attachments Settings card, persisted scanner and outside-scope toggles, repainted X11 captures')
