"""A normal Linux relaunch reattaches the selected shell, never creates a replacement."""
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

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture)
store = root / 'terminal-restore-store'
project = root / 'RestoreProject'
other = root / 'OtherProject'
project.mkdir()
other.mkdir()
for folder in (project, other):
    subprocess.run([host, '--add-project', str(store), str(folder)], check=True,
                   capture_output=True, timeout=8)
child = Path(__file__).with_name('project_terminal_child.py')
log_path = root / 'terminal-restore-window.log'


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=4)


def title(process, pattern):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {pattern}: {log_path.read_text()}'
        found = xdo('search', '--onlyvisible', '--name', pattern)
        if found.returncode == 0:
            return found.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing title {pattern}: {log_path.read_text()}')


def key(window, value):
    sent = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert sent.returncode == 0, (value, sent.stderr)


def rows():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def selected():
    with sqlite3.connect(store / 'threading.db') as database:
        return dict(database.execute("SELECT key, value FROM app_state WHERE key IN "
                                     "('selectedSessionID', 'selectedTerminalID')"))


def launch(name, *, target=None, initial=False):
    command = [binary, '--app', str(store), endpoint, '/bin/sh']
    if initial:
        command = [binary, '--app', str(store), endpoint, '/usr/bin/python3', str(child)]
    if target is not None:
        command = [binary, '--app-project', str(store), endpoint, '/bin/sh', str(target)]
    output = log_path.open('w+')
    process = subprocess.Popen(command, stdout=output, stderr=output)
    return process, output


def close(process, output, window, terminal=False, saved_picker=False):
    if terminal:
        key(window, 'ctrl+shift+p')
        if saved_picker:
            title(process, r'^Threading terminals - ' + re.escape(str(project)) + r'$')
            key(window, 'Escape')
        title(process, r'^Threading experiment - ' + re.escape(str(project)) + r'$')
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0, log_path.read_text()
    output.close()


process = None
output = None
try:
    process, output = launch('first', initial=True)
    window = title(process, r'^Threading experiment - ' + re.escape(str(project)) + r'$')
    key(window, 'Return')
    title(process, r'^Threading terminal - NAV RestoreProject READY$')
    marker = project / 'navigation-child.json'
    deadline = time.monotonic() + 10
    while not marker.exists():
        assert process.poll() is None and time.monotonic() < deadline
        time.sleep(.05)
    original = json.loads(marker.read_text())
    deadline = time.monotonic() + 10
    while not selected().get('selectedTerminalID'):
        assert time.monotonic() < deadline
        time.sleep(.05)
    chosen = selected()['selectedTerminalID']
    assert 'selectedSessionID' not in selected()
    live = next(row for row in rows() if row['id'] == 'terminal-' + chosen)
    assert live['pid'] == original['pid'], (live, original)
    close(process, output, window, terminal=True)
    process = output = None

    # The selected identity is outside the most recent 512 rows. Startup must find it while
    # decoding the owning project payload and insert only that one row into the bounded picker.
    with sqlite3.connect(store / 'threading.db') as database:
        project_id, payload = database.execute('SELECT id, data FROM project WHERE folder_path = ?',
                                               (str(project),)).fetchone()
        value = json.loads(payload)
        assert len(value['terminals']) == 1
        original_terminal = value['terminals'][0]
        for index in range(513):
            filler = dict(original_terminal, id=str(uuid.uuid4()).upper(), title=f'Old shell {index}')
            value['terminals'].append(filler)
        assert chosen not in [row['id'] for row in value['terminals'][-512:]]
        database.execute('UPDATE project SET data = ? WHERE id = ?', (json.dumps(value), project_id))

    process, output = launch('explicit-target', target=other)
    window = title(process, r'^Threading experiment - ' + re.escape(str(other)) + r'$')
    assert selected().get('selectedTerminalID') == chosen
    assert next(row for row in rows() if row['id'] == live['id'])['pid'] == original['pid']
    close(process, output, window)
    process = output = None

    process, output = launch('normal-reopen')
    window = title(process, r'^Threading terminal - NAV RestoreProject READY \[(history cut|restored)\]$')
    assert json.loads(marker.read_text()) == original, 'relaunch spawned a replacement child'
    attached = next(row for row in rows() if row['id'] == live['id'])
    assert attached['pid'] == original['pid'] and attached['attached'], attached
    assert 'selected=' + chosen in log_path.read_text() or chosen in selected().values()
    subprocess.run(['import', '-window', window, 'out/terminal-auto-restored.png'],
                   check=True, timeout=5)
    key(window, 'p')
    title(process, r'^Threading terminal - NAV RestoreProject REVISITED \[(history cut|restored)\]$')
    close(process, output, window, terminal=True, saved_picker=True)
    process = output = None

    os.kill(original['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 10
    while True:
        matching = [row for row in rows() if row['id'] == live['id']]
        if not matching or matching[0].get('exit') is not None:
            break
        assert time.monotonic() < deadline, matching
        time.sleep(.05)
    process, output = launch('exited-reopen')
    window = title(process, r'^Threading experiment - ' + re.escape(str(project)) + r'$')
    assert json.loads(marker.read_text()) == original
    subprocess.run(['import', '-window', window, 'out/terminal-exited-reopen.png'],
                   check=True, timeout=5)
    close(process, output, window)
    process = output = None

    # The daemon retains an unobserved exit for up to 30 minutes. An explicit watcher may
    # collect it; that starts the five-second observed-exit retention before the absent case.
    collected = subprocess.run([host, str(store), endpoint, 'attach', chosen],
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=8)
    assert collected.returncode == 143, (collected.returncode, collected.stderr)
    deadline = time.monotonic() + 10
    while any(row['id'] == live['id'] for row in rows()):
        assert time.monotonic() < deadline, 'daemon did not retire exited terminal summary'
        time.sleep(.1)
    process, output = launch('absent-reopen')
    window = title(process, r'^Threading experiment - ' + re.escape(str(project)) + r'$')
    assert json.loads(marker.read_text()) == original
    close(process, output, window)
    process = output = None
    print('PASS selected shell: bounded older-row restore, explicit project precedence, same PID, exited and absent fallback', flush=True)
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    if output is not None:
        output.close()
