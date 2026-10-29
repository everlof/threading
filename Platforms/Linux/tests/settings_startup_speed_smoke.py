"""Shared New Chats defaults persist and reopen through the real Linux shell."""
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
root = Path(fixture) / 'settings-startup-speed'
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


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)],
                                   text=True, timeout=5).strip()


def eventually(read, label, process):
    deadline = time.monotonic() + 20
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
    raise AssertionError(f'{label}: {last}')


def click_anchor(log_path, prefix, process, kind=None):
    filter_kind = f' kind={kind}' if kind else ''
    pattern = rf'{prefix}{filter_kind}(?: value=\w+)? x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)'
    match = eventually(lambda: re.findall(pattern, log_path.read_text()),
                       f'{prefix} {kind or ""}', process)[-1]
    x, y, width, height = map(float, match)
    xdo('mousemove', '--window', window, round(240 + x + width / 2),
        round(480 - y - height / 2), 'click', 1)


def choose_down(times):
    for _ in range(times):
        xdo('windowfocus', '--sync', window, 'key', 'Down')
    xdo('windowfocus', '--sync', window, 'key', 'Return')


def open_settings_footer(process):
    def press():
        candidate = xdo('search', '--all', '--onlyvisible', '--pid', process.pid).splitlines()[-1]
        xdo('mousemove', '--window', candidate, 50, 459, 'click', 1)
        return candidate
    return eventually(press, 'Settings footer', process)


def open_chats(log_path, process):
    eventually(lambda: 'SETTINGS_OPENED' in log_path.read_text(), 'Settings', process)
    click_anchor(log_path, 'SETTINGS_PAGE_ANCHOR', process)
    eventually(lambda: 'SETTINGS_POPUP_OPENED rows=2' in log_path.read_text(),
               'page selector menu', process)
    choose_down(1)
    eventually(lambda: 'SETTINGS_PAGE_SELECTED value=Chats' in log_path.read_text(),
               'Chats destination', process)
    eventually(lambda: 'SETTINGS_STARTUP_SPEED_LOADED kind=claude' in log_path.read_text(),
               'shared speed rows', process)


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
    log_path = output / f'settings-speed-{visit}.log'
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                    '/bin/sh', '/bin/true'], env=environment,
                                   stdout=log, stderr=log)
        try:
            window = open_settings_footer(process)
            open_chats(log_path, process)
            if visit == 'first':
                click_anchor(log_path, 'SETTINGS_NEW_CHAT_ANCHOR', process, 'agent')
                eventually(lambda: log_path.read_text().count('SETTINGS_POPUP_OPENED rows=2') == 2,
                           'default agent menu', process)
                choose_down(1)
                eventually(lambda: 'SETTINGS_DEFAULT_AGENT_CHANGED value=codex'
                           in log_path.read_text(), 'Codex default saved', process)
                click_anchor(log_path, 'SETTINGS_NEW_CHAT_ANCHOR', process, 'permission')
                eventually(lambda: 'SETTINGS_POPUP_OPENED rows=7' in log_path.read_text(),
                           'permission default menu', process)
                eventually(lambda: re.search(r'SETTINGS_FRAME [^\n]+ popup=true',
                           log_path.read_text().split('SETTINGS_POPUP_OPENED rows=7')[-1]),
                           'permission menu rendered', process)
                time.sleep(.75)
                subprocess.run(['import', '-window', window,
                                str(output / 'settings-permission-menu.png')],
                               check=True, timeout=5)
                choose_down(2)
                eventually(lambda: 'SETTINGS_DEFAULT_PERMISSION_CHANGED value=plan'
                           in log_path.read_text(), 'Plan default saved', process)
                click_anchor(log_path, 'SETTINGS_SPEED_ANCHOR', process, 'claude')
                eventually(lambda: log_path.read_text().count('SETTINGS_POPUP_OPENED rows=3') == 1,
                           'Claude speed menu', process)
                eventually(lambda: re.search(r'SETTINGS_FRAME [^\n]+ popup=true',
                           log_path.read_text().split('SETTINGS_POPUP_OPENED rows=3')[-1]),
                           'Claude menu rendered', process)
                time.sleep(.5)
                subprocess.run(['import', '-window', window,
                                str(output / 'settings-speed-menu.png')], check=True, timeout=5)
                choose_down(2)
                eventually(lambda: 'SETTINGS_STARTUP_SPEED_CHANGED kind=claude value=fast'
                           in log_path.read_text(), 'Claude Fast saved', process)
                frames = log_path.read_text().count('SETTINGS_FRAME ')
                click_anchor(log_path, 'SETTINGS_SPEED_ANCHOR', process, 'codex')
                eventually(lambda: log_path.read_text().count('SETTINGS_POPUP_OPENED rows=3') == 2,
                           'Codex speed menu', process)
                eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ') > frames,
                           'Codex menu rendered', process)
                choose_down(1)
                eventually(lambda: 'SETTINGS_STARTUP_SPEED_CHANGED kind=codex value=standard'
                           in log_path.read_text(), 'Codex Standard saved', process)
                eventually(lambda: re.search(r'SETTINGS_FRAME [^\n]+ popup=false',
                           log_path.read_text().split('SETTINGS_STARTUP_SPEED_CHANGED kind=codex')[-1]),
                           'Chats choices rendered', process)
                time.sleep(.25)
                subprocess.run(['import', '-window', window,
                                str(output / 'settings-speed-chats.png')], check=True, timeout=5)
                xdo('windowsize', window, 760, 480)
                eventually(lambda: 'SETTINGS_FRAME 520x439' in log_path.read_text(),
                           'narrow Chats page rendered', process)
                time.sleep(.25)
                subprocess.run(['import', '-window', window,
                                str(output / 'settings-chats-narrow.png')], check=True, timeout=5)
            else:
                assert 'SETTINGS_DEFAULT_AGENT_LOADED value=codex' in log_path.read_text()
                assert 'SETTINGS_DEFAULT_PERMISSION_LOADED value=plan' in log_path.read_text()
                assert 'SETTINGS_STARTUP_SPEED_LOADED kind=claude value=fast' in log_path.read_text()
                assert 'SETTINGS_STARTUP_SPEED_LOADED kind=codex value=standard' in log_path.read_text()
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

log_path = output / 'settings-default-composer.log'
with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app-agents-project', str(store), endpoint,
                                '/bin/sh', '/bin/true', '/bin/true', str(project)],
                               env=environment, stdout=log, stderr=log)
    try:
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                         process.pid).splitlines()[0],
                            'composer window', process)
        identity = eventually(lambda: control(process, 'linux.composer.provider'),
                              'new composer identity', process)
        eventually(lambda: identity.get_name() == 'Identity: Codex',
                   'persisted default agent used by composer', process)
        permission = eventually(lambda: control(process, 'linux.composer.permissions'),
                                'new composer permission', process)
        eventually(lambda: permission.get_name() == 'Permissions: Plan',
                   'persisted default permission used by composer', process)
        subprocess.run(['import', '-window', window,
                        str(output / 'settings-default-composer.png')], check=True, timeout=5)
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

print('PASS New Chats defaults: shared rows, menus, persistence, real X11 screenshots')
