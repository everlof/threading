"""Explicit activation restarts a saved shell; ordinary relaunch only reattaches live children."""
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture)
store = root / 'terminal-restart-store'
project = root / 'RestartProject'
preferred = project / '日本語 working'
preferred.mkdir(parents=True)
marker = root / 'saved-shell-starts.jsonl'
child = Path(__file__).with_name('saved_terminal_child.py').resolve()
shell_arguments = ['argument with spaces', '日本語', '--literal-argument']
subprocess.run([host, str(store), endpoint, 'run', str(project), '/bin/true'],
               stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=12)
database_path = store / 'threading.db'
with sqlite3.connect(database_path) as database:
    project_id, payload = database.execute('SELECT id, data FROM project').fetchone()
    record = json.loads(payload)
    assert len(record['terminals']) == 1
    terminal = record['terminals'][0]
    terminal['currentDirectory'] = str(preferred)
    terminal['customTitle'] = 'Saved shell 界'
    saved_id = terminal['id']
    expected_payload = json.dumps(record)
    database.execute('UPDATE project SET data = ? WHERE id = ?', (expected_payload, project_id))
    database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")

process = None
log = None


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, Path(log.name).read_text()
        value = read()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{label}: {Path(log.name).read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=4)


def title(pattern):
    def find():
        result = xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid), '--name', pattern)
        return result.stdout.splitlines()[0] if result.returncode == 0 else None
    return eventually(find, 'native title ' + pattern)


def key(value):
    result = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert result.returncode == 0, result.stderr


def starts():
    return [json.loads(line) for line in marker.read_text().splitlines()] if marker.exists() else []


def daemon_sessions():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def assert_record(count, cwd):
    entries = starts()
    assert len(entries) == count, entries
    assert entries[-1]['cwd'] == str(cwd), entries[-1]
    assert entries[-1]['arguments'] == shell_arguments, entries[-1]
    assert len({item['pid'] for item in entries}) == count, 'restart must create a fresh child'
    if cwd == project:
        def fallback_saved():
            with sqlite3.connect(database_path) as database:
                payload = database.execute('SELECT data FROM project WHERE id = ?', (project_id,)).fetchone()[0]
                return json.loads(payload)['terminals'][0]['currentDirectory'] == str(project)
        eventually(fallback_saved, 'live fallback directory persisted')
    with sqlite3.connect(database_path) as database:
        actual = database.execute('SELECT data FROM project WHERE id = ?', (project_id,)).fetchone()[0]
        if cwd == project:
            expected = json.loads(expected_payload)
            expected['terminals'][0]['currentDirectory'] = str(project)
            assert json.loads(actual) == expected, 'fallback changed metadata beyond live cwd'
        else:
            assert actual == expected_payload
        assert database.execute('SELECT COUNT(*) FROM project').fetchone()[0] == 1
        state = dict(database.execute('SELECT key, value FROM app_state'))
        assert state['selectedTerminalID'] == saved_id and 'selectedSessionID' not in state
    runtime = next(row for row in daemon_sessions() if row['id'] == 'terminal-' + saved_id)
    assert runtime['pid'] == entries[-1]['pid'] and runtime.get('exit') is None and runtime['attached'], runtime
    return entries[-1]


def launch(name):
    global process, log
    log = Path('out/terminal-restart-' + name + '.log').open('w+')
    process = subprocess.Popen([binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                str(child), str(marker), *shell_arguments], stdout=log, stderr=log)


def picker():
    title('^Threading terminals - ' + re.escape(str(project)) + '$')


def projects():
    return title('^Threading experiment - ' + re.escape(str(project)) + '$')


def ready(number):
    return title(r'^Threading terminal - SAVED SHELL ' + str(number) + r' (READY|LIVE)( \[(history cut|restored)\])?$')


def close_from_terminal():
    global process, log
    key('ctrl+shift+p')
    picker()
    key('Escape')
    projects()
    key('Escape')
    assert process.wait(timeout=5) == 0, Path(log.name).read_text()
    log.close()
    process = log = None


try:
    launch('explicit')
    window = projects()
    assert not starts(), 'opening the project must not restart its saved shell'
    assert xdo('windowsize', window, '960', '600').returncode == 0
    eventually(lambda: 'FRAME 960x600' in Path(log.name).read_text(), 'resized native navigator')
    key('Right')
    picker()
    key('Return')
    ready(1)
    first = assert_record(1, preferred)
    assert (first['columns'], first['rows']) == (96, 27), first
    subprocess.run(['import', '-window', window, 'out/terminal-restart-recorded-directory.png'],
                   check=True, timeout=5)

    # Repeated explicit activation while live must reuse the same child, including cached routes.
    for _ in range(2):
        key('ctrl+shift+p')
        picker()
        key('Return')
        ready(1)
        key('p')
        title(r'^Threading terminal - SAVED SHELL 1 LIVE$')
        assert_record(1, preferred)
    key('q')
    title(r'^Threading terminal - exited 0( \[(history cut|restored)\])?$')
    key('ctrl+shift+p')
    picker()
    key('Return')
    ready(2)
    assert_record(2, preferred)
    close_from_terminal()

    # Normal reopening attaches this live incarnation rather than taking the new start route.
    launch('live-reopen')
    window = ready(2)
    assert_record(2, preferred)
    close_from_terminal()

    # This activation has neither a cached surface nor startup restoration: openTerminal must
    # discover the live child and attach rather than create a duplicate incarnation.
    with sqlite3.connect(database_path) as database:
        database.execute("DELETE FROM app_state WHERE key = 'selectedTerminalID'")
    launch('uncached-live')
    window = projects()
    key('Right')
    picker()
    key('Return')
    ready(2)
    live = assert_record(2, preferred)
    close_from_terminal()

    # Observe an offline exit through the daemon's summary only. No watcher consumes the exit;
    # explicit reopen must also work for its longer-lived unobserved tombstone.
    os.kill(live['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 10
    while True:
        held = next(row for row in daemon_sessions() if row['id'] == 'terminal-' + saved_id)
        if held.get('exit') is not None:
            assert not held['attached'], held
            break
        assert time.monotonic() < deadline, held
        time.sleep(.05)
    preferred.rmdir()

    # An exited selected shell remains dormant at startup. Explicit activation falls back to
    # its owning project when the recorded directory disappeared. Live cwd tracking then updates
    # only that field; identity, creation, custom title and settings remain the saved record's.
    launch('fallback')
    window = projects()
    assert len(starts()) == 2
    key('Right')
    picker()
    key('Return')
    ready(3)
    assert_record(3, project)
    subprocess.run(['import', '-window', window, 'out/terminal-restart-project-fallback.png'],
                   check=True, timeout=5)
    key('q')
    title(r'^Threading terminal - exited 0( \[(history cut|restored)\])?$')
    close_from_terminal()
    print('PASS saved shell restart: same ID/settings, fresh PID, stored cwd and persisted live fallback, exact argv/grid, cached and uncached live attach, offline exit and attach-only startup', flush=True)
finally:
    if process is not None:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
    if log is not None:
        log.close()
