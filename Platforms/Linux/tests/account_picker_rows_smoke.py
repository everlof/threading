"""Installed picker: bounded 28pt menu rows, accessible geometry, scroll and choice."""
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, endpoint, folder = sys.argv[1:]
root = Path(folder)
root.mkdir(parents=True, exist_ok=True)
home = root / 'account-picker-home'
home.mkdir()
for number in range(31):
    account = home / f'.codex-{number:02d}'
    account.mkdir()
    (account / 'auth.json').write_text('{}')
project = root / 'AccountPickerProject'
project.mkdir()
store = root / 'account-picker-store'
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=10)
Atspi.init()


def xdo(*arguments):
    return subprocess.run(['xdotool', *arguments], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def eventually(read, description, process, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{description}: {log_path.read_text()}'
        answer = read()
        if answer:
            return answer
        time.sleep(.05)
    raise AssertionError(f'{description}: {log_path.read_text()}')


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def account_list(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    return matches[0] if len(matches) == 1 and matches[0].get_name() == 'Codex accounts' else None


def rows(listed):
    return [listed.get_child_at_index(index) for index in range(listed.get_child_count())]


def bounds(row):
    return row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)


def selected_id(listed):
    child = listed.get_selection_iface().get_selected_child(0)
    return child.get_accessible_id() if child is not None else None


def capture(window, name):
    subprocess.run(['import', '-window', window, str(root / name)], check=True, timeout=5)


log_path = root / 'account-picker-rows.log'
process = None
try:
    xdo('mousemove', '0', '0')
    with log_path.open('w+') as log:
        environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / '.codex'))
        environment.pop('THREADING_LINUX_CODEX_ACCOUNT', None)
        process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                    '/bin/sh', '/bin/true'], env=environment,
                                   stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI app', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native project window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window, 'key', 'ctrl+shift+i')
        listed = eventually(lambda: account_list(app), 'account list', process)
        initial = rows(listed)
        assert len(initial) == 7, (len(initial), log_path.read_text())
        assert listed.get_description() == 'Showing 1 through 7 of 32 items'
        assert selected_id(listed) == 'default'
        for index, row in enumerate(initial):
            rect = bounds(row)
            assert (rect.x, rect.y, rect.width, rect.height) == (12, 86 + index * 56, 776, 56), \
                (index, rect.x, rect.y, rect.width, rect.height)
        capture(window, 'account-picker-first.png')

        xdo('windowfocus', '--sync', window, 'key', '--repeat', '31', '--delay', '65', 'Down')
        eventually(lambda: 'selected=codex-30 total=32' in log_path.read_text(),
                   'keyboard scroll to last account', process)
        listed = account_list(app)
        assert listed.get_description() == 'Showing 26 through 32 of 32 items'
        assert selected_id(listed) == 'codex-30'
        last = rows(listed)
        assert len(last) == 7
        for index, row in enumerate(last):
            rect = bounds(row)
            assert (rect.x, rect.y, rect.width, rect.height) == (12, 86 + index * 56, 776, 56), \
                (index, rect.x, rect.y, rect.width, rect.height)
        capture(window, 'account-picker-last.png')

        assert listed.get_selection_iface().select_child(0)
        eventually(lambda: selected_id(account_list(app)) == 'codex-24',
                   'AT-SPI selection of first visible account', process)
        last_row = bounds(rows(account_list(app))[-1])
        xdo('mousemove', '--window', window, str(last_row.x + 100),
            str(last_row.y + last_row.height // 2), 'click', '1')
        eventually(lambda: xdo('getwindowname', window).startswith('Threading experiment - '),
                   'pointer account choice', process)
        xdo('windowfocus', '--sync', window, 'key', 'ctrl+shift+i')
        listed = eventually(lambda: account_list(app) if selected_id(account_list(app)) == 'codex-30'
                            else None, 'chosen account on reopen', process)
        assert 'active' in listed.get_selection_iface().get_selected_child(0).get_name()
        capture(window, 'account-picker-active.png')
        xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
        assert process.wait(timeout=5) == 0
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=3)

print('PASS account picker: 32 identities, 7 mounted 28pt rows, AT-SPI geometry, scroll and pointer choice')
