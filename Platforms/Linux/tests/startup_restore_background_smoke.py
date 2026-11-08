"""The graphical host consumes a saved quit record and staggers two unseen agents."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time


binary, host, daemon, endpoint, fixture, *options = sys.argv[1:]
assert not options or options == ['many'], options
many = options == ['many']
count = 9 if many else 2
root = Path(fixture) / ('startup-restore-many' if many else 'startup-restore-background')
root.mkdir()
store, project, home = root / 'store', root / 'Project', root / 'home'
project.mkdir()
home.mkdir()
(home / '.claude').mkdir()
(home / '.claude' / 'settings.json').write_text('{}')
capture = root / 'launches.jsonl'
child = root / 'fake-claude'
child.write_text('''#!/usr/bin/python3
import json, os, sys, time, tty
from pathlib import Path
tty.setraw(0)
args = sys.argv[1:]
identifier = args[args.index('--session-id') + 1] if '--session-id' in args else args[args.index('--resume') + 1]
slug = ''.join(chr(value) if (65 <= value <= 90 or 97 <= value <= 122 or 48 <= value <= 57) else '-'
               for value in [int.from_bytes(os.getcwd().encode('utf-16-le')[index:index+2], 'little')
                             for index in range(0, len(os.getcwd().encode('utf-16-le')), 2)])
transcript = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'projects' / slug / (identifier + '.jsonl')
transcript.parent.mkdir(parents=True, exist_ok=True)
if '--session-id' in args:
    transcript.write_text('{}\\n')
else:
    assert transcript.is_file(), transcript
with open(os.environ['THREADING_RESTORE_CAPTURE'], 'a') as output:
    output.write(json.dumps({'id': identifier, 'resume': '--resume' in args,
                             'at': time.monotonic(), 'pid': os.getpid()}) + '\\n')
assert os.read(0, 1) == b'q'
''')
child.chmod(0o700)
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   THREADING_RESTORE_CAPTURE=str(capture))


def launches():
    return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(label)


for number in range(count):
    process = subprocess.Popen([host, str(store), endpoint, 'claude', str(project),
                                '/bin/sh', str(child), f'Seed {number}'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment)
    eventually(lambda: len(launches()) == number + 1, 'seed child did not launch')
    stdout, stderr = process.communicate(input=b'q', timeout=15)
    assert process.returncode == 0, (stdout, stderr)

with sqlite3.connect(store / 'threading.db') as database:
    ids = [row[0] for row in database.execute('SELECT id FROM session ORDER BY position')]
    assert len(ids) == count, ids
    database.execute('DELETE FROM app_state WHERE key = ?', ('selectedSessionID',))
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('runningSessionIDs', ' '.join(ids)))


def childrenReleased():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            check=True, capture_output=True, text=True, timeout=5)
    held = json.loads(result.stdout)
    return not any(identifier.lower() in item['id'].lower() for item in held for identifier in ids)


eventually(childrenReleased, 'seed children remained in daemon')
log_path = root / 'window.log'
with log_path.open('w') as log:
    process = subprocess.Popen([binary, '--app-claude', str(store), endpoint,
                                '/bin/sh', str(child)], env=environment,
                               stdout=log, stderr=log)
    try:
        def window():
            assert process.poll() is None, log_path.read_text()[-4000:]
            result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                     '--pid', str(process.pid), '--name', '^Threading'],
                                    capture_output=True, text=True, timeout=5)
            return result.stdout.splitlines()[0] if result.stdout else None
        eventually(window, 'graphical window did not open')
        try:
            resumed = eventually(lambda: [item for item in launches() if item['resume']]
                                 if len([item for item in launches() if item['resume']]) == count else None,
                                 'saved agents did not resume', timeout=count * 3 + 20)
        except AssertionError as error:
            raise AssertionError(f'{error}: launches={launches()} '
                                 f'window={log_path.read_text()[-5000:]}') from error
        assert {item['id'].lower() for item in resumed} == {item.lower() for item in ids}, resumed
        assert all(later['at'] - earlier['at'] >= .7
                   for earlier, later in zip(resumed, resumed[1:])), resumed
        # SDL can replace its first X11 handle while creating the renderer.
        wid = eventually(window, 'restored background window disappeared')
        subprocess.run(['xdotool', 'windowfocus', '--sync', wid, 'key', 'alt+F4'],
                       check=True, timeout=5)
        assert process.wait(timeout=10) == 0, log_path.read_text()[-5000:]
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

assert log_path.read_text().count('STARTUP_RESTORE_LAUNCH') == count, log_path.read_text()[-5000:]
with sqlite3.connect(store / 'threading.db') as database:
    record = database.execute('SELECT value FROM app_state WHERE key = ?',
                              ('runningSessionIDs',)).fetchone()
assert record and all(identifier.lower() in record[0].lower() for identifier in ids), record

if many:
    print('PASS Linux startup background: nine paced agents crossed the old host cap')
    sys.exit(0)

# A selected saved conversation resumes on screen after its daemon child has gone away.
# The same quit record's other session still takes the paced background route.
for identifier in ids:
    stopped = subprocess.run([host, str(store), endpoint, 'attach-agent', identifier],
                             input=b'q', env=environment, capture_output=True, timeout=15)
    assert stopped.returncode == 0, (identifier, stopped.stderr)
eventually(childrenReleased, 'resumed children remained in daemon')
with sqlite3.connect(store / 'threading.db') as database:
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('selectedSessionID', ids[0]))

prior = len(launches())
selected_log = root / 'selected-window.log'
with selected_log.open('w') as log:
    process = subprocess.Popen([binary, '--app-claude', str(store), endpoint,
                                '/bin/sh', str(child)], env=environment,
                               stdout=log, stderr=log)
    try:
        def selected_window():
            assert process.poll() is None, selected_log.read_text()[-4000:]
            result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                     '--pid', str(process.pid), '--name', '^Threading'],
                                    capture_output=True, text=True, timeout=5)
            return result.stdout.splitlines()[0] if result.stdout else None
        eventually(selected_window, 'selected restore window did not open')
        eventually(lambda: 'TERMINAL_FRAME ' in selected_log.read_text(),
                   f'selected saved session did not open: {selected_log.read_text()[-5000:]}')
        resumed = eventually(lambda: launches()[prior:] if len(launches()) >= prior + 2 else None,
                             f'selected and background sessions did not resume: '
                             f'{selected_log.read_text()[-5000:]}', timeout=25)
        assert {item['id'].lower() for item in resumed} == {item.lower() for item in ids}, resumed
        wid = eventually(selected_window, 'selected restore window disappeared')
        subprocess.run(['xdotool', 'windowfocus', '--sync', wid, 'key', 'alt+F4'],
                       check=True, timeout=5)
        assert process.wait(timeout=10) == 0, selected_log.read_text()[-5000:]
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

assert selected_log.read_text().count('STARTUP_RESTORE_LAUNCH') == 1, \
    selected_log.read_text()[-5000:]
print('PASS Linux startup background: two paced agents, selected visible resume and durable quit')
