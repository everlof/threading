"""A dormant saved chat opens the shared restoration card in the real X11 shell."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import uuid


binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'session-hover-card'
root.mkdir()
store, project, home = root / 'store', root / 'Project', root / 'home'
repository = root / 'Repo'
subprocess.run(['git', 'init', '-q', '-b', 'main', str(repository)], check=True, timeout=8)
subprocess.run(['git', '-C', str(repository), 'config', 'user.name', 'Fixture'],
               check=True, timeout=8)
subprocess.run(['git', '-C', str(repository), 'config', 'user.email',
                'fixture@example.invalid'], check=True, timeout=8)
(repository / 'README').write_text('hover card fixture\n')
subprocess.run(['git', '-C', str(repository), 'add', 'README'], check=True, timeout=8)
subprocess.run(['git', '-C', str(repository), 'commit', '-q', '-m', 'Initial'],
               check=True, timeout=8)
subprocess.run(['git', '-C', str(repository), 'worktree', 'add', '-q', '-b',
                'live-feature', str(project)], check=True, timeout=8)
home.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   THREADING_LINUX_NAVIGATION_TRACE='1')
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh',
                '/bin/true', 'Dormant session'], env=environment, input=b'',
               capture_output=True, check=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    session_id, encoded = database.execute('SELECT id, data FROM session').fetchone()
    session = json.loads(encoded)
    session['branch'] = 'saved-feature'
    session['handoff'] = {
        'endpoints': [
            {'sessionID': str(uuid.uuid4()).upper(), 'kind': 'claude',
             'model': 'claude-sonnet-4', 'title': 'Source'},
            {'sessionID': session_id, 'kind': 'codex',
             'model': 'gpt-5', 'title': 'Dormant session'},
        ],
        'omittedEndpointCount': 0,
        'createdAt': session['createdAt'],
    }
    database.execute('UPDATE session SET data = ? WHERE id = ?',
                     (json.dumps(session), session_id))
    database.execute('DELETE FROM app_state WHERE key = ?', ('selectedSessionID',))
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('runningSessionIDs', ''))

output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
log_path = output / 'session-hover-card.log'


def eventually(check, label, process):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()[-5000:]
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()[-5000:]}')


with log_path.open('w') as log:
    process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                '/bin/sh', '/bin/true'], env=environment,
                               stdout=log, stderr=log)
    try:
        window = eventually(lambda: subprocess.run([
            'xdotool', 'search', '--all', '--onlyvisible', '--pid', str(process.pid),
            '--name', '^Threading'], capture_output=True, text=True).stdout.splitlines(),
            'native window', process)[0]
        eventually(lambda: 'STARTUP_RESTORE_PLAN count=0' in log_path.read_text(),
                   'restoration ledger', process)
        subprocess.run(['xdotool', 'mousemove', '--window', window, '80', '128'],
                       check=True, timeout=5)
        card = eventually(lambda: re.search(
            rf'SESSION_HOVER_CARD id={re.escape(session_id)} height=(\d+) '
            r'reason=true branch=true handoff=true worktree=true',
            log_path.read_text()),
            'hover card with saved branch, linked worktree, handoff and restoration reason',
            process)
        assert int(card.group(1)) >= 170, f'collapsed hover card: {card.group(0)}'
        time.sleep(.15)
        subprocess.run(['import', '-window', window, str(output / 'session-hover-card.png')],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'click', '1'], check=True, timeout=5)
        eventually(lambda: 'stage=selection index=2' in log_path.read_text(),
                   'row click through hover card', process)
        subprocess.run(['xdotool', 'windowfocus', '--sync', window, 'key', 'Return'],
                       check=True, timeout=5)
        def row_selected():
            with sqlite3.connect(store / 'threading.db') as database:
                row = database.execute('SELECT value FROM app_state WHERE key = ?',
                                       ('selectedSessionID',)).fetchone()
            return row is not None and row[0] == session_id
        eventually(row_selected, 'keyboard activation of clicked row', process)
        subprocess.run(['xdotool', 'windowfocus', '--sync', window, 'key', 'alt+F4'],
                       check=True, timeout=5)
        assert process.wait(timeout=10) == 0, log_path.read_text()[-5000:]
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

print('PASS shared session hover card: saved branch, worktree, handoff, reason and click-through')
