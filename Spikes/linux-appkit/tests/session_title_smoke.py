"""Shared session names reach the native picker and AT-SPI, including fresh admission."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import uuid

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, socket, folder = sys.argv[1:]
root = Path(folder)
store = root / 'session-title-store'
project = root / 'SessionNames'
project.mkdir()
log_path = Path('out/session-titles-native.log')
database_path = store / 'threading.db'
home = root / 'session-title-home'
home.mkdir()
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_STARTUP_TRACE='1')
for key in ('THREADING_LINUX_CODEX_ACCOUNT', 'THREADING_LINUX_CLAUDE_ACCOUNT'):
    environment.pop(key, None)

# Obtain the persisted shape through the production host. The provider stand-in exits without
# network or credentials; these are presentation fixtures, not authenticated-provider evidence.
subprocess.run([host, str(store), socket, 'codex', str(project), '/bin/sh', '/bin/true',
                'Seed prompt'], input=b'', env=environment, capture_output=True, check=True, timeout=20)
cases = [
    ({'title': 'Prompt loses', 'terminalTitle': 'Agent loses',
      'customTitle': 'User name 界 Ångström'}, 'User name 界 Ångström'),
    ({'title': 'Prompt loses', 'terminalTitle': 'Agent name 日本語',
      'customTitle': ''}, 'Agent name 日本語'),
    ({'title': 'Prompt name e\u0301', 'terminalTitle': '', 'customTitle': ''}, 'Prompt name e\u0301'),
    ({'title': '', 'terminalTitle': '', 'customTitle': ''}, 'New Session'),
    ({'title': 'Fallback prompt', 'terminalTitle': '', 'customTitle': None}, 'Fallback prompt'),
]
expected = {}
with sqlite3.connect(database_path) as database:
    project_id, kind, active, payload = database.execute(
        'SELECT project_id, kind, last_active_at, data FROM session').fetchone()
    template = json.loads(payload)
    database.execute('DELETE FROM session')
    database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
    for position, (fields, title) in enumerate(cases):
        identifier = str(uuid.uuid4()).upper()
        record = dict(template, **fields, id=identifier, hasLaunched=False)
        database.execute(
            'INSERT INTO session (id, project_id, position, kind, last_active_at, data) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (identifier, project_id, position, kind, active, json.dumps(record)))
        expected[identifier] = '[Codex] ' + title


def stored_rows():
    with sqlite3.connect(database_path) as database:
        return dict(database.execute('SELECT id, data FROM session'))


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; window log: {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def await_title(title):
    # xdotool combines search properties with OR unless --all is requested. Both process
    # identity and the completed-frame title must match before the next native event is sent.
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid), '--name',
                                  '^' + re.escape(title) + '$').splitlines()[0], title)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def assert_names(expected_names):
    def read():
        listed = app.get_child_at_index(0).get_child_at_index(0)
        if listed.get_role_name() != 'list' or listed.get_child_count() != len(expected_names):
            return None
        actual = {}
        for index in range(listed.get_child_count()):
            row = listed.get_child_at_index(index)
            actual[row.get_accessible_id()] = row.get_name()
        if set(actual) != set(expected_names):
            return None
        return actual
    actual = eventually(read, 'complete visible session catalogue')
    for identifier, title in expected_names.items():
        # Freshly admitted runtime has an additional retained-state annotation.
        assert actual[identifier] in (f'{title} [{identifier[:8]}]',
                                      f'{title} [{identifier[:8]}] retained'), actual


before = stored_rows()
Atspi.init()
with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app-claude', str(store), socket,
                                '/bin/sh', '/bin/true'], env=environment, stdout=log, stderr=log)
    try:
        window = await_title('Threading experiment - ' + str(project))
        app = eventually(application, 'AT-SPI application registration')
        key('Left')
        await_title('Threading agents - ' + str(project))
        assert_names(expected)
        subprocess.run(['import', '-window', window, 'out/session-titles-native.png'],
                       check=True, timeout=5)
        assert stored_rows() == before, 'Presenting names must not rewrite stored titles'

        key('Escape')
        await_title('Threading experiment - ' + str(project))
        key('ctrl+shift+l')
        await_title('Threading terminal - exited 0')
        key('ctrl+shift+p')
        await_title('Threading experiment - ' + str(project))
        key('Left')
        await_title('Threading agents - ' + str(project))
        after = stored_rows()
        added = set(after) - set(before)
        assert len(added) == 1, after
        fresh = added.pop()
        assert json.loads(after[fresh])['title'] == ''
        assert all(after[identifier] == payload for identifier, payload in before.items())
        expected[fresh] = '[Claude Code] New Session'
        assert_names(expected)
        subprocess.run(['import', '-window', window, 'out/session-titles-fresh.png'],
                       check=True, timeout=5)
        key('Escape')
        await_title('Threading experiment - ' + str(project))
        key('Escape')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)

# A selected row outside the recent window is read separately. Its name must pass through the
# same projection, and it takes one of the existing 512 slots rather than growing the catalogue.
selected = next(iter(expected))
with sqlite3.connect(database_path) as database:
    record = json.loads(database.execute('SELECT data FROM session WHERE id = ?',
                                        (selected,)).fetchone()[0])
    record['hasLaunched'] = True
    record.pop('lastExitCode', None)
    database.execute('UPDATE session SET data = ? WHERE id = ?', (json.dumps(record), selected))
    position = database.execute('SELECT MAX(position) + 1 FROM session').fetchone()[0]
    for offset in range(513):
        identifier = str(uuid.uuid4()).upper()
        filler = dict(template, id=identifier, title=f'Recent session {offset}', hasLaunched=False)
        database.execute(
            'INSERT INTO session (id, project_id, position, kind, last_active_at, data) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (identifier, project_id, position + offset, kind, active, json.dumps(filler)))
    database.execute("INSERT OR REPLACE INTO app_state (key, value) VALUES ('selectedSessionID', ?)",
                     (selected,))
before_deep = stored_rows()
with log_path.open('a') as log:
    process = subprocess.Popen([binary, '--app', str(store), socket, '/bin/sh'],
                               env=environment, stdout=log, stderr=log)
    try:
        window = await_title('Threading experiment - ' + str(project))
        app = eventually(application, 'restored AT-SPI application')
        key('Left')
        await_title('Threading agents - ' + str(project))

        def deep_row():
            listed = app.get_child_at_index(0).get_child_at_index(0)
            if listed.get_role_name() != 'list' or listed.get_child_count() != 8:
                return None
            first = listed.get_child_at_index(0)
            if first.get_accessible_id() != selected:
                return None
            assert listed.get_description() == 'Showing 1 through 8 of 512 items'
            assert first.get_name() == f'{expected[selected]} [{selected[:8]}]'
            assert first.get_state_set().contains(Atspi.StateType.SELECTED)
            return first

        eventually(deep_row, 'older selected session retains its shared title within the row cap')
        subprocess.run(['import', '-window', window, 'out/session-titles-deep-selection.png'],
                       check=True, timeout=5)
        assert stored_rows() == before_deep
        key('Escape')
        await_title('Threading experiment - ' + str(project))
        key('Escape')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
print('PASS shared user/agent/prompt/unnamed session titles in native picker and AT-SPI; '
      'fresh admission and older selected rows use the same names without rewriting existing records')
