"""A newly created shell immediately joins the native saved picker with one runtime owner."""
from saved_catalog_menu import open_saved_terminals
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture)
store = root / 'terminal-catalogue-store'
project = root / 'CatalogueProject'
project.mkdir()
marker = root / 'terminal-catalogue-starts.jsonl'
child = Path(__file__).with_name('saved_terminal_child.py').resolve()
log_path = Path('out/terminal-catalogue-window.log')
subprocess.run([host, '--add-project', str(store), str(project)], check=True,
               capture_output=True, timeout=10)
# This catalog journey checks the collapsed project's aggregate count beside its saved picker.
with sqlite3.connect(store / 'threading.db') as database:
    identity, payload = database.execute('SELECT id,data FROM project').fetchone()
    record = json.loads(payload)
    assert record['isExpanded'] is True
    record['isExpanded'] = False
    database.execute('UPDATE project SET data=? WHERE id=?', (json.dumps(record).encode(), identity))
process = None
saved_id = None
Atspi.init()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, 'native window exited: ' + log_path.read_text()
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True,
                          check=True, timeout=5).stdout.strip()


def title(pattern):
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid),
                                  '--name', pattern).splitlines()[0], 'native title ' + pattern)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def projects():
    return title('^Threading experiment - ' + re.escape(str(project)) + '$')


def picker():
    return title('^Threading terminals - ' + re.escape(str(project)) + '$')


def ready(number):
    return title(r'^Threading terminal - SAVED SHELL ' + str(number)
                 + r' (READY|LIVE)( \[(history cut|restored)\])?$')


def starts():
    return [json.loads(line) for line in marker.read_text().splitlines()] if marker.exists() else []


def sessions():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def persisted():
    with sqlite3.connect(store / 'threading.db') as database:
        rows = list(database.execute('SELECT id, data FROM project ORDER BY position'))
        assert len(rows) == 1
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        return rows[0]


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def terminal_header(expected_name):
    def read():
        frame = app.get_child_at_index(0)
        for index in range(frame.get_child_count()):
            child = frame.get_child_at_index(index)
            if child.get_accessible_id() == 'linux.page-title' and child.get_name() == expected_name:
                return child
        return None
    return eventually(read, 'saved terminal name in the live page header')


def row(identifier, terminal=False, retained=True):
    def read():
        listed = app.get_child_at_index(0).get_child_at_index(0)
        assert listed.get_role_name() == 'list'
        if terminal:
            assert listed.get_child_count() == 1
            assert listed.get_description() == 'Showing 1 through 1 of 1 items'
            assert listed.get_name() == 'Saved terminals (1 of 1)'
        else:
            assert listed.get_name() == 'Projects' and listed.get_child_count() == 2
        item = next(listed.get_child_at_index(index) for index in range(listed.get_child_count())
                    if listed.get_child_at_index(index).get_accessible_id() == identifier)
        assert item.get_state_set().contains(Atspi.StateType.SELECTED)
        if terminal:
            label = item.get_name()
            assert '[' + identifier[:8] + ']' in label, label
            assert (' retained' in label) == retained, (label, retained)
        return item
    return eventually(read, 'one catalogue row with its durable identity and current lifecycle')


def assert_owner(number):
    entries = starts()
    assert len(entries) == number, entries
    assert len({entry['pid'] for entry in entries}) == number
    assert all(entry['cwd'] == str(project) for entry in entries), entries
    runtime = next(item for item in sessions() if item['id'] == 'terminal-' + saved_id)
    assert runtime['pid'] == entries[-1]['pid'] and runtime.get('exit') is None, runtime
    assert runtime['attached'], runtime
    assert persisted() == saved_record, 'cached navigation or restart changed the stored terminal'
    with sqlite3.connect(store / 'threading.db') as database:
        state = dict(database.execute('SELECT key, value FROM app_state'))
        assert state.get('selectedTerminalID') == saved_id and 'selectedSessionID' not in state
    return runtime['pid']


with log_path.open('w+') as log:
    try:
        project_id, original = persisted()
        assert json.loads(original)['terminals'] == [], 'import must start without a shell'
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                    str(child), str(marker)], stdout=log, stderr=log)
        window = projects()
        app = eventually(application, 'fixture AT-SPI registration')
        key('Return')
        ready(1)
        eventually(lambda: json.loads(persisted()[1])['isExpanded'] is True,
                   'creation reveals its persisted parent')
        saved_record = persisted()
        terminals = json.loads(saved_record[1])['terminals']
        assert len(terminals) == 1, terminals
        saved_id = terminals[0]['id']
        terminal_header(terminals[0]['title'])
        first_pid = assert_owner(1)

        key('ctrl+shift+p')
        projects()
        row(saved_id)
        open_saved_terminals(key)
        picker()
        row(saved_id, terminal=True)
        subprocess.run(['import', '-window', window, 'out/terminal-catalogue-new-row.png'],
                       check=True, timeout=5)
        key('Return')
        ready(1)
        key('p')
        title(r'^Threading terminal - SAVED SHELL 1 LIVE$')
        assert assert_owner(1) == first_pid, 'saved picker duplicated the new shell'

        key('q')
        title(r'^Threading terminal - exited 0( \[(history cut|restored)\])?$')
        key('ctrl+shift+p')
        picker()
        row(saved_id, terminal=True, retained=False)
        key('Return')
        ready(2)
        restarted_pid = assert_owner(2)
        assert restarted_pid != first_pid
        key('ctrl+shift+p')
        picker()
        row(saved_id, terminal=True)
        key('Escape')
        projects()
        row(project_id)
        key('Return')
        ready(2)
        key('p')
        title(r'^Threading terminal - SAVED SHELL 2 LIVE$')
        assert assert_owner(2) == restarted_pid, 'project route retained the exited runtime owner'
        subprocess.run(['import', '-window', window, 'out/terminal-catalogue-shared-runtime.png'],
                       check=True, timeout=5)
        key('q')
        title(r'^Threading terminal - exited 0( \[(history cut|restored)\])?$')
        key('ctrl+shift+p')
        projects()
        # Fold the automatically revealed child before exercising an explicit header reveal.
        key('Left')
        key('Left')
        eventually(lambda: json.loads(persisted()[1])['isExpanded'] is False and
                   log_path.read_text().count('OUTLINE_EXPANSION_PENDING ') ==
                   log_path.read_text().count('OUTLINE_EXPANSION_SAVED '), 'folded header target')
        expected_folded = json.loads(saved_record[1])
        expected_folded['isExpanded'] = False
        assert json.loads(persisted()[1]) == expected_folded
        saved_record = persisted()
        # The cached project route must keep the same terminal page identity. Its native
        # accessibility action reveals that child, including a previously folded parent.
        assert terminal_header(terminals[0]['title']).get_action_iface().do_action(0)
        def revealed():
            listed = app.get_child_at_index(0).get_child_at_index(0)
            chosen = listed.get_selection_iface().get_selected_child(0)
            return (listed.get_name() == 'Projects' and chosen is not None
                    and chosen.get_accessible_id() == saved_id
                    and chosen.get_state_set().contains(Atspi.StateType.FOCUSED)
                    and json.loads(persisted()[1])['isExpanded'] is True)
        eventually(revealed, 'terminal header reveals and focuses the exact saved child')
        expected_project = json.loads(saved_record[1])
        expected_project['isExpanded'] = True
        assert json.loads(persisted()[1]) == expected_project
        saved_record = persisted()
        subprocess.run(['import', '-window', window, 'out/terminal-catalogue-header-reveal.png'],
                       check=True, timeout=5)
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        assert persisted() == saved_record
        print('PASS newly created shell appears immediately in saved picker with one retained row; '
              'saved/project routes share live PID and restarted same-ID runtime without duplicate records',
              flush=True)
    except BaseException:
        print(log_path.read_text()[-16384:], file=sys.stderr)
        raise
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        # The fixture child outlives the window. Signal only its exact daemon-held identity/PID,
        # after matching our start marker, rather than an arbitrary recycled PID from the log.
        if saved_id is not None:
            try:
                owned_pids = {entry['pid'] for entry in starts()}
                for runtime in sessions():
                    if (runtime['id'] == 'terminal-' + saved_id and runtime.get('exit') is None
                            and runtime['pid'] in owned_pids):
                        try:
                            os.kill(runtime['pid'], signal.SIGTERM)
                        except ProcessLookupError:
                            pass
            except Exception as error:
                print(f'fixture child cleanup failed: {error}', file=sys.stderr)
