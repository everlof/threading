"""Immediate saved-shell admission respects picker/runtime limits and import refresh."""
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time
import uuid

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture)
store = root / 'terminal-catalogue-limits-store'
projects = [root / f'CatalogueLimit{index:02d}' for index in range(1, 10)]
for project in projects:
    project.mkdir()
    subprocess.run([host, '--add-project', str(store), str(project)], check=True,
                   capture_output=True, timeout=10)
marker = root / 'terminal-catalogue-limits-starts.jsonl'
child = Path(__file__).with_name('saved_terminal_child.py').resolve()
log_path = Path('out/terminal-catalogue-limits.log')
process = None
chooser_identity = None
Atspi.init()


def records():
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        return list(database.execute('SELECT id, data FROM project ORDER BY position'))


with sqlite3.connect(store / 'threading.db') as database:
    project_id, payload = database.execute('SELECT id, data FROM project ORDER BY position LIMIT 1').fetchone()
    record = json.loads(payload)
    assert record['folderPath'] == str(projects[0]) and record['terminals'] == []
    seeded = [{'id': str(uuid.uuid4()).upper(), 'title': f'Saved shell {index:03d}',
               'currentDirectory': str(projects[0]), 'createdAt': 0} for index in range(512)]
    record['terminals'] = seeded
    database.execute('UPDATE project SET data = ? WHERE id = ?', (json.dumps(record), project_id))
    database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
project_ids = [identifier for identifier, _ in records()]


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, 'window exited: ' + log_path.read_text()
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def title(pattern, pid=None):
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                  str(pid if pid is not None else process.pid), '--name', pattern)
                      .splitlines()[0], 'native title ' + pattern)


def key(value, window_id=None):
    xdo('windowfocus', '--sync', str(window if window_id is None else window_id),
        'key', '--delay', '50', value)


def project_title(index):
    return title('^Threading experiment - ' + re.escape(str(projects[index])) + '$')


def picker():
    return title('^Threading terminals - ' + re.escape(str(projects[0])) + '$')


def ready(number):
    return title(r'^Threading terminal - SAVED SHELL ' + str(number)
                 + r' (READY|LIVE)( \[(history cut|restored)\])?$')


def starts():
    return [json.loads(line) for line in marker.read_text().splitlines()] if marker.exists() else []


def sessions():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def listed():
    result = app.get_child_at_index(0).get_child_at_index(0)
    assert result.get_role_name() == 'list'
    assert result.get_child_count() <= 8, 'offscreen rows mounted in AT-SPI'
    return result


def assert_picker():
    def read():
        listing = listed()
        assert listing.get_name() == 'Saved terminals (512 of 513)', listing.get_name()
        assert listing.get_description() == 'Showing 1 through 8 of 512 items'
        assert listing.get_child_count() == 8
        expected = [fresh_id] + [row['id'] for row in reversed(seeded[-7:])]
        actual = [listing.get_child_at_index(index).get_accessible_id() for index in range(8)]
        assert actual == expected, actual
        first = listing.get_child_at_index(0)
        assert first.get_state_set().contains(Atspi.StateType.SELECTED)
        assert first.get_name().endswith(' retained')
        return True
    eventually(read, 'capped saved picker admits new retained row first')


def assert_project_count(index, count):
    def read():
        listing = listed()
        for offset in range(listing.get_child_count()):
            row = listing.get_child_at_index(offset)
            if row.get_accessible_id() == project_ids[index]:
                assert row.get_name() == f'{projects[index].name} [0 agents, {count} terminals] retained'
                return True
        return False
    eventually(read, 'authoritative project count after native admission/refresh')


def assert_children(number):
    entries = starts()
    assert len(entries) == number, entries
    assert len({entry['pid'] for entry in entries}) == number
    values = [json.loads(payload) for _, payload in records()]
    assert len(values[0]['terminals']) == 513
    assert [row['id'] for row in values[0]['terminals'][:-1]] == [row['id'] for row in seeded]
    assert values[0]['terminals'][-1]['id'] == fresh_id
    assert [len(value['terminals']) for value in values[1:]] == [1] * (number - 1) + [0] * (9 - number)
    owned = {'terminal-' + value['terminals'][-1]['id'] for value in values[:number]}
    live = [row for row in sessions() if row['id'] in owned and row.get('exit') is None]
    assert len(live) == number and {row['pid'] for row in live} == {entry['pid'] for entry in entries}
    return owned


def folder_dialog_pid():
    # Process launches the GTK chooser from a worker; its child can belong to any native task.
    children = set()
    for task in list((Path('/proc') / str(process.pid) / 'task').iterdir())[:32]:
        try:
            children.update(int(value) for value in (task / 'children').read_text()[:4096].split())
        except FileNotFoundError:
            pass
    for pid in sorted(children)[:32]:
        try:
            if (Path('/proc') / str(pid) / 'comm').read_text().strip() == 'zenity':
                return pid
        except FileNotFoundError:
            pass
    return None


with log_path.open('w+') as log:
    try:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                    str(child), str(marker)], stdout=log, stderr=log)
        window = project_title(0)
        app = eventually(application, 'fixture AT-SPI registration')
        key('Return')
        ready(1)
        first = json.loads(records()[0][1])
        fresh_id = first['terminals'][-1]['id']
        assert fresh_id not in {row['id'] for row in seeded}
        assert_children(1)
        key('ctrl+shift+p')
        project_title(0)
        assert_project_count(0, 513)
        key('Right')
        picker()
        assert_picker()
        subprocess.run(['import', '-window', window, 'out/terminal-catalogue-cap.png'],
                       check=True, timeout=5)
        # Reopening this freshly admitted saved row must not allocate a second runtime slot.
        key('Return')
        ready(1)
        assert_children(1)
        key('ctrl+shift+p')
        picker()
        key('Escape')
        project_title(0)
        for index in range(1, 8):
            key('Down')
            project_title(index)
            key('Return')
            ready(index + 1)
            assert_children(index + 1)
            key('ctrl+shift+p')
            project_title(index)
            assert_project_count(index, 1)
        # At eight slots the same saved owner remains usable, even though new admission is full.
        for index in reversed(range(7)):
            key('Up')
            project_title(index)
        key('Right')
        picker()
        assert_picker()
        key('Return')
        ready(1)
        key('p')
        title(r'^Threading terminal - SAVED SHELL 1 LIVE$')
        assert_children(8)
        key('ctrl+shift+p')
        picker()
        key('Escape')
        project_title(0)

        before_refresh = records()
        key('ctrl+shift+p')
        chooser_pid = eventually(folder_dialog_pid, 'owned GTK folder chooser')
        chooser_identity = (chooser_pid, (Path('/proc') / str(chooser_pid) / 'stat').read_text().split()[21])
        dialog = title('^Add project folder$', pid=chooser_pid)
        subprocess.run(['xclip', '-selection', 'clipboard'], input=str(projects[0]), text=True,
                       check=True, timeout=5)
        key('ctrl+l', dialog)
        time.sleep(.2)  # GTK creates its location entry after handling Ctrl+L.
        key('ctrl+a', dialog)
        key('ctrl+v', dialog)
        time.sleep(.2)  # GTK clipboard insertion is asynchronous.
        key('ctrl+a', dialog)
        key('ctrl+c', dialog)
        selected_path = subprocess.check_output(['xclip', '-o', '-selection', 'clipboard'],
                                                text=True, timeout=5)
        assert Path(selected_path).resolve() == projects[0].resolve(), selected_path
        key('Return', dialog)
        eventually(lambda: 'PROJECT_IMPORTED ' in log_path.read_text(), 'duplicate-folder snapshot refresh')
        project_title(0)
        assert_project_count(0, 513)
        assert records() == before_refresh, 'refresh duplicated or rewrote terminal records'
        assert_children(8)
        key('Right')
        picker()
        assert_picker()
        key('Escape')
        project_title(0)
        for index in range(1, 9):
            key('Down')
            project_title(index)
        before_refusal = records()
        key('Return')
        title(r'^Threading experiment - limit of 8 open terminals$')
        assert records() == before_refusal
        assert_children(8)
        subprocess.run(['import', '-window', window, 'out/terminal-catalogue-eight-limit.png'],
                       check=True, timeout=5)
        key('Escape')
        assert process.wait(timeout=5) == 0
        print('PASS immediate 512-row picker cap, new row first, 8 mounted rows; 8 shared runtime slots; '
              'same saved owner usable at capacity; ninth refused; folder refresh preserves exact counts', flush=True)
    except BaseException:
        print(log_path.read_text()[-16384:], file=sys.stderr)
        raise
    finally:
        if chooser_identity is not None:
            try:
                pid, started = chooser_identity
                if (Path('/proc') / str(pid) / 'stat').read_text().split()[21] == started:
                    os.kill(pid, signal.SIGTERM)
            except (FileNotFoundError, ProcessLookupError):
                pass
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        try:
            owned_pids = {entry['pid'] for entry in starts()}
            identities = {'terminal-' + terminal['id'] for _, payload in records()
                          for terminal in json.loads(payload)['terminals']}
            for runtime in sessions():
                if (runtime['id'] in identities and runtime.get('exit') is None
                        and runtime['pid'] in owned_pids):
                    try:
                        os.kill(runtime['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        except Exception as error:
            print(f'fixture child cleanup failed: {error}', file=sys.stderr)
