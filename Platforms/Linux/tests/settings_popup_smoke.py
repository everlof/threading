"""The production Settings pop-up opens a shared menu in the native Linux window."""
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
root = Path(fixture) / 'settings-popup'
root.mkdir()
project = root / 'Project'
project.mkdir()
store = root / 'store'
home = root / 'home'
home.mkdir()
(home / '.config').mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   THREADING_LINUX_DATA_DIR=str(root / 'data'),
                   THREADING_LINUX_SETTINGS_POPUP_FIXTURE='1')
subprocess.run([host, '--add-project', str(store), str(project)],
               env=environment, check=True, capture_output=True, timeout=10)
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
log_path = output / 'settings-popup.log'
Atspi.init()


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)],
                                   text=True, timeout=5).strip()


def eventually(read, label, process):
    deadline = time.monotonic() + 15
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: {log_path.read_text()}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                '/bin/sh', '/bin/true'], env=environment,
                               stdout=log, stderr=log)
    try:
        def application():
            desktop = Atspi.get_desktop(0)
            for index in range(desktop.get_child_count()):
                candidate = desktop.get_child_at_index(index)
                if candidate.get_process_id() == process.pid and candidate.get_name() == 'Threading Linux':
                    return candidate
            return None

        app = eventually(application, 'AT-SPI application', process)
        frame = eventually(lambda: app.get_child_at_index(0), 'AT-SPI frame', process)

        def accessible(identifier=None, name=None):
            panel = next((frame.get_child_at_index(index)
                          for index in range(frame.get_child_count())
                          if frame.get_child_at_index(index).get_accessible_id() == 'settings.panel'), None)
            if panel is None:
                return None
            return next((panel.get_child_at_index(index)
                         for index in range(panel.get_child_count())
                         if (identifier and panel.get_child_at_index(index).get_accessible_id() == identifier)
                         or (name and panel.get_child_at_index(index).get_name() == name)), None)

        def open_settings():
            window_id = xdo('search', '--all', '--onlyvisible', '--pid',
                            process.pid).splitlines()[0]
            footer = next((frame.get_child_at_index(index)
                           for index in range(frame.get_child_count())
                           if frame.get_child_at_index(index).get_accessible_id() == 'sidebar.settings'), None)
            if footer is None or not footer.get_action_iface().do_action(0):
                return None
            return window_id

        window = eventually(open_settings, 'native Settings window', process)
        eventually(lambda: 'SETTINGS_OPENED' in log_path.read_text(),
                   'Settings destination', process)
        fixture_control = eventually(lambda: accessible('settings.popup.fixture'),
                                     'shared fixture popup in Settings panel', process)
        assert fixture_control.get_name() == 'Pop-up control fixture'
        restore = eventually(lambda: accessible('settings.general.restore-last-session'),
                             'shared General toggle', process)
        assert restore.get_name() == 'Reopen the last session at launch'
        assert accessible('settings.general.done') is not None
        changes = log_path.read_text().count('SETTINGS_RESTORE_CHANGED')
        for expected in (changes + 1, changes + 2):
            assert restore.get_action_iface().do_action(0)
            eventually(lambda: log_path.read_text().count('SETTINGS_RESTORE_CHANGED') >= expected,
                       'Settings toggle AT-SPI action', process)
        anchor = eventually(lambda: re.findall(
            r'SETTINGS_POPUP_ANCHOR x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)',
            log_path.read_text()), 'mounted production pop-up', process)[-1]
        assert anchor
        frames = log_path.read_text().count('SETTINGS_FRAME')
        assert fixture_control.get_action_iface().do_action(0)
        eventually(lambda: 'SETTINGS_POPUP_OPENED rows=3' in log_path.read_text(),
                   'shared menu opened', process)
        choice = eventually(lambda: accessible(name='Second choice'),
                            'shared menu choice in Settings panel', process)
        assert choice.get_action_iface().get_n_actions() == 1
        eventually(lambda: log_path.read_text().count('SETTINGS_FRAME') > frames,
                   'open menu rendered', process)
        time.sleep(.15)  # SDL presents the rendered bitmap to X11 after this log line.
        subprocess.run(['import', '-window', window, str(output / 'settings-popup-open.png')],
                       check=True, timeout=5)
        frames = log_path.read_text().count('SETTINGS_FRAME')
        xdo('windowfocus', '--sync', window, 'key', 'Down')
        eventually(lambda: 'SETTINGS_POPUP_HIGHLIGHTED entry=1' in log_path.read_text(),
                   'keyboard moved highlight', process)
        eventually(lambda: log_path.read_text().count('SETTINGS_FRAME') > frames,
                   'keyboard highlight rendered', process)
        frames = log_path.read_text().count('SETTINGS_FRAME')
        xdo('windowfocus', '--sync', window, 'key', 'Return')
        eventually(lambda: 'SETTINGS_POPUP_CHOSEN Second choice' in log_path.read_text(),
                   'keyboard chose second value', process)
        eventually(lambda: log_path.read_text().count('SETTINGS_FRAME') > frames,
                   'chosen value rendered', process)
        eventually(lambda: re.search(r'SETTINGS_FRAME [^\n]+ popup=false [^\n]*choice=1',
                                     log_path.read_text(), re.IGNORECASE),
                   'chosen state reached renderer', process)
        eventually(lambda: choice.get_action_iface().get_n_actions() == 0,
                   'retired menu choice cannot be pressed', process)
        time.sleep(.15)
        subprocess.run(['import', '-window', window, str(output / 'settings-popup-chosen.png')],
                       check=True, timeout=5)
        fixture_control = eventually(lambda: accessible('settings.popup.fixture'),
                                     'fixture popup after choice', process)
        assert fixture_control.get_action_iface().do_action(0)
        third = eventually(lambda: accessible(name='Third choice'),
                           'third shared menu choice', process)
        assert third.get_action_iface().do_action(0)
        eventually(lambda: 'SETTINGS_POPUP_CHOSEN Third choice' in log_path.read_text(),
                   'AT-SPI menu choice applied', process)
        policy_anchor = eventually(lambda: re.findall(
            r'SETTINGS_POLICY_ANCHOR x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)',
            log_path.read_text()), 'shared Startup policy row', process)[-1]
        x, y, width, height = map(float, policy_anchor)
        popup_x = round(240 + x + width / 2)
        popup_y = round(480 - y - height / 2)
        opened = log_path.read_text().count('SETTINGS_POPUP_OPENED rows=3')
        xdo('mousemove', '--window', window, popup_x, popup_y, 'click', 1)
        eventually(lambda: log_path.read_text().count('SETTINGS_POPUP_OPENED rows=3') > opened,
                   'Startup policy menu opened', process)
        xdo('windowfocus', '--sync', window, 'key', 'Down')
        xdo('windowfocus', '--sync', window, 'key', 'Return')
        eventually(lambda: 'SETTINGS_POLICY_CHANGED value=recentlyUsed' in log_path.read_text(),
                   'Startup policy choice applied', process)
        eventually(lambda: re.search(
            r'SETTINGS_POLICY_CHANGED value=recentlyUsed[\s\S]*SETTINGS_FRAME [^\n]+ popup=false',
            log_path.read_text()),
                   'chosen Startup policy rendered', process)
        time.sleep(.7)
        subprocess.run(['import', '-window', window, str(output / 'settings-policy-chosen.png')],
                       check=True, timeout=5)
        for anchor_name, changed in [
                ('SETTINGS_IDLE_WINDOW_ANCHOR', 'SETTINGS_IDLE_WINDOW_CHANGED days=2'),
                ('SETTINGS_IDLE_LIMIT_ANCHOR', 'SETTINGS_IDLE_LIMIT_CHANGED limit=8')]:
            anchor = eventually(lambda: re.findall(
                rf'{anchor_name} x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)',
                log_path.read_text()), anchor_name, process)[-1]
            x, y, width, height = map(float, anchor)
            popup_x = round(240 + x + width / 2)
            popup_y = round(480 - y - height / 2)
            opened = log_path.read_text().count('SETTINGS_POPUP_OPENED rows=6')
            xdo('mousemove', '--window', window, popup_x, popup_y, 'click', 1)
            eventually(lambda: log_path.read_text().count('SETTINGS_POPUP_OPENED rows=6') > opened,
                       f'{anchor_name} menu opened', process)
            xdo('windowfocus', '--sync', window, 'key', 'Down')
            xdo('windowfocus', '--sync', window, 'key', 'Return')
            eventually(lambda: changed in log_path.read_text(), changed, process)
        time.sleep(.15)
        subprocess.run(['import', '-window', window, str(output / 'settings-idle-chosen.png')],
                       check=True, timeout=5)
        xdo('windowsize', window, 1120, 760)
        eventually(lambda: 'SETTINGS_FRAME 880x719' in log_path.read_text(),
                   'tall Settings layout', process)
        page_selector = eventually(lambda: accessible('settings.page'),
                                   'shared page selector', process)
        assert page_selector.get_action_iface().do_action(0)
        chats_choice = eventually(lambda: accessible(name='Chats'),
                                  'Chats menu choice', process)
        assert chats_choice.get_action_iface().do_action(0)
        eventually(lambda: 'SETTINGS_PAGE_SELECTED value=Chats' in log_path.read_text(),
                   'Chats destination', process)
        eventually(lambda: restore.get_action_iface().get_n_actions() == 0,
                   'General control retired after page switch', process)
        help_button = eventually(lambda: accessible('settings.chats.new-chats-help-0'),
                                 'shared New Chats help', process)
        assert help_button.get_action_iface().do_action(0)
        eventually(lambda: 'SETTINGS_HELP_OPENED' in log_path.read_text(),
                   'New Chats help opened via AT-SPI', process)
        xdo('windowfocus', '--sync', window, 'key', 'Escape')
        eventually(lambda: 'SETTINGS_HELP_CLOSED' in log_path.read_text(),
                   'New Chats help dismissed', process)
        prefix = eventually(lambda: accessible('settings.chats.new-chat-opening-prefix'),
                            'Opening Message field', process)
        assert prefix.get_name() == 'Before the task you write'
        assert prefix.get_action_iface().get_n_actions() == 1
        frames = log_path.read_text().count('SETTINGS_FRAME')
        assert prefix.get_action_iface().do_action(0), 'Opening Message field focus refused'
        eventually(lambda: log_path.read_text().count('SETTINGS_FRAME') > frames,
                   'Opening Message field focused and rendered', process)
        eventually(lambda: prefix.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'Opening Message AT-SPI focus', process)
        assert accessible('settings.chats.default-agent') is not None
        assert accessible('settings.chats.new-chats-help-0') is not None
        subprocess.run(['import', '-window', window, str(output / 'settings-chats-accessible.png')],
                       check=True, timeout=5)
        xdo('windowfocus', '--sync', window, 'type', '--clearmodifiers', '--delay', 5, 'A11y')
        eventually(lambda: 'SETTINGS_OPENING_CHANGED kind=prefix bytes=4'
                   in log_path.read_text(), 'Opening Message typed after AT-SPI focus', process)
        eventually(lambda: 'A11y' in (prefix.get_description() or ''),
                   'Opening Message value published to AT-SPI', process)
        xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

reopened_log = output / 'settings-policy-reopened.log'
with reopened_log.open('w+') as log:
    process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                '/bin/sh', '/bin/true'], env=environment,
                               stdout=log, stderr=log)
    try:
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        process.pid).splitlines()[0],
                            'reopened native window', process)
        xdo('mousemove', '--window', window, 50, 459, 'click', 1)
        eventually(lambda: 'SETTINGS_POLICY_LOADED value=recentlyUsed'
                   in reopened_log.read_text(), 'saved Startup policy', process)
        eventually(lambda: 'SETTINGS_IDLE_LOADED days=2 limit=8'
                   in reopened_log.read_text(), 'saved Idle Agents settings', process)
        eventually(lambda: 'SETTINGS_FRAME' in reopened_log.read_text(),
                   'saved Startup policy rendered', process)
        time.sleep(.15)
        subprocess.run(['import', '-window', window, str(output / 'settings-policy-reopened.png')],
                       check=True, timeout=5)
        xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

print('PASS Settings AT-SPI controls, shared menus, Chats field focus and native render')
