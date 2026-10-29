"""A live PTY child survives a graphical quit and becomes the next launch's record."""
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time


binary, host, endpoint, fixture = sys.argv[1:]
root = Path(fixture) / 'startup-restore-quit'
root.mkdir()
store = root / 'store'
project = root / 'Project'
project.mkdir()
home = root / 'home'
home.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))
agent = root / 'fake-codex'
starts = root / 'starts'
agent.write_text('#!/bin/sh\nprintf "start\\n" >> "$THREADING_TEST_STARTS"\n'
                 'stty raw -echo\nprintf "LIVE RESTORE TARGET\\r\\n"\n'
                 'exec /bin/cat >/dev/null\n')
agent.chmod(0o755)
environment['THREADING_TEST_STARTS'] = str(starts)
seed_log = (root / 'seed.log').open('w+')
seed = subprocess.Popen([host, str(store), endpoint, 'codex', str(project), '/bin/sh',
                         str(agent), 'Restore target'], stdin=subprocess.PIPE,
                        stdout=seed_log, stderr=seed_log, env=environment)
seed.stdin.close()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(label)


try:
    eventually(lambda: starts.exists() and (store / 'threading.db').exists(),
               'seed agent never started')
finally:
    seed.terminate()
    seed.wait(timeout=5)
    seed_log.close()

with sqlite3.connect(store / 'threading.db') as database:
    session_id, = database.execute('SELECT id FROM session').fetchone()
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('selectedSessionID', session_id))


def quit_window(number):
    log_path = root / f'window-{number}.log'
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                    '/bin/sh', '/bin/true'], env=environment,
                                   stdout=log, stderr=log)
        try:
            def window():
                assert process.poll() is None, log_path.read_text()[-3000:]
                matches = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                          '--pid', str(process.pid), '--name', '^Threading'],
                                         capture_output=True, text=True, timeout=5)
                return matches.stdout.splitlines()[0] if matches.stdout else None
            wid = eventually(window, f'window {number} never opened')
            try:
                eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(),
                           f'window {number} did not attach the live agent')
            except AssertionError as error:
                raise AssertionError(f'{error}: {log_path.read_text()[-4000:]}') from error
            subprocess.run(['xdotool', 'windowfocus', '--sync', wid, 'key', 'alt+F4'],
                           check=True, timeout=5)
            assert process.wait(timeout=8) == 0, log_path.read_text()[-5000:]
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
    assert 'recordWritten=true' in log_path.read_text(), \
        'quit did not await its worker record'
    with sqlite3.connect(store / 'threading.db') as database:
        record = database.execute('SELECT value FROM app_state WHERE key = ?',
                                  ('runningSessionIDs',)).fetchone()
    assert record and session_id.lower() in record[0].lower(), \
        f'quit {number} lost its running agent: {record}'


quit_window(1)
quit_window(2)
assert starts.read_text().splitlines() == ['start'], 'relaunch duplicated a daemon-held agent'
print('PASS Linux startup quit: durable running set, quick relaunch and one daemon child')
