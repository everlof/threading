"""Create a managed agent from the project window and revisit its retained terminal."""
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

binary, host, endpoint, folder = sys.argv[1:]
root = Path(folder)
store = str(root / 'create-agent-store')
project = root / 'CreatedAgent'
project.mkdir()
child = root / 'created-agent-child'
child.write_text('''#!/usr/bin/python3
import datetime, fcntl, json, os, struct, sys, termios, tty, uuid
from pathlib import Path
tty.setraw(0)
rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))
if 'resume' in sys.argv[1:]:
    resumed_id = sys.argv[sys.argv.index('resume') + 1]
    Path('resumed-agent.json').write_text(json.dumps({
        'pid': os.getpid(), 'argv': sys.argv[1:], 'provider_id': resumed_id,
    }))
    os.write(1, b'\\x1b]0;RESUMED AGENT READY\\x07')
    assert os.read(0, 1) == b'q'
    sys.exit(0)
provider_id = str(uuid.uuid4())
day = datetime.datetime.now(datetime.timezone.utc)
sessions = Path(os.environ['CODEX_HOME']) / 'sessions' / day.strftime('%Y/%m/%d')
sessions.mkdir(parents=True, exist_ok=True)
(sessions / ('rollout-' + provider_id + '.jsonl')).write_text(json.dumps({
    'type': 'session_meta', 'payload': {'id': provider_id, 'cwd': os.getcwd()}
}) + '\\n')
Path('created-agent.json').write_text(json.dumps({
    'pid': os.getpid(), 'cwd': os.getcwd(), 'argv': sys.argv[1:],
    'grid': [cols, rows], 'term': os.getenv('TERM'), 'color': os.getenv('COLORTERM'),
    'provider_id': provider_id,
}))
os.write(1, b'\\x1b]0;CREATED AGENT READY\\x07')
assert os.read(0, 1) == b'p', 'activation key leaked into the PTY'
os.write(1, b'\\x1b]0;CREATED AGENT REVISITED\\x07')
assert os.read(0, 1) == b'q'
sys.exit(6)
''')
child.chmod(0o700)
subprocess.run([host, store, endpoint, 'run', str(project), '/bin/true'],
               input=b'', check=True, capture_output=True, timeout=15)


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=5)


def key(window, value):
    result = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert result.returncode == 0, result.stderr


def title(process, expected, log_path):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited: {log_path.read_text()}'
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing title {expected}: {log_path.read_text()}')


def listing():
    return subprocess.run([host, store, endpoint, 'list'], check=True, capture_output=True,
                          text=True, timeout=8).stdout


before = listing()
assert '  agent ' not in before, before
log_path = root / 'agent-create-window.log'
codex_home = root / 'codex-home'
codex_home.mkdir()
environment = dict(os.environ, CODEX_HOME=str(codex_home))
with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app-codex', store, endpoint, '/bin/sh', str(child)],
                               stdout=log, stderr=log, env=environment)
    try:
        window = title(process, 'Threading experiment - ' + str(project), log_path)
        subprocess.run(['import', '-window', window, 'out/agent-create-project.png'], check=True, timeout=5)
        key(window, 'ctrl+shift+a')
        title(process, 'Threading terminal - CREATED AGENT READY', log_path)
        marker = project / 'created-agent.json'
        report = json.loads(marker.read_text())
        assert report['cwd'] == str(project) and report['grid'] == [80, 21], report
        assert report['term'] == 'xterm-256color' and report['color'] == 'truecolor', report
        argv = report['argv']
        assert '--no-alt-screen' in argv and '--ask-for-approval' in argv and '--sandbox' in argv, argv
        assert argv[argv.index('--ask-for-approval') + 1] == 'untrusted', argv
        assert argv[argv.index('--sandbox') + 1] == 'read-only', argv
        assert 'resume' not in argv, argv
        with sqlite3.connect(str(Path(store) / 'threading.db')) as database:
            rows = database.execute('SELECT id, kind, data FROM session').fetchall()
            assert len(rows) == 1 and rows[0][1] == 'codex', rows
            payload = json.loads(rows[0][2])
            assert payload['permissionMode'] == 'manual' and payload['title'] == '', payload
            assert database.execute("SELECT value FROM app_state WHERE key='selectedSessionID'").fetchone()[0] == rows[0][0]
        saved_id = rows[0][0]
        deadline = time.monotonic() + 5
        while True:
            with sqlite3.connect(str(Path(store) / 'threading.db')) as database:
                stored = json.loads(database.execute('SELECT data FROM session WHERE id=?', (saved_id,)).fetchone()[0])
            if stored.get('agentSessionID') == report['provider_id']:
                break
            assert time.monotonic() < deadline, stored
            time.sleep(.05)
        key(window, 'ctrl+shift+p')
        title(process, 'Threading experiment - ' + str(project), log_path)
        subprocess.run(['import', '-window', window, 'out/agent-create-returned.png'], check=True, timeout=5)
        key(window, 'Left')
        title(process, 'Threading agents - ' + str(project), log_path)
        deadline = time.monotonic() + 5
        while f'AGENT_PICKER_FRAME 800x480 mounted=1 selected={saved_id} total=1 capped=0' not in log_path.read_text():
            assert time.monotonic() < deadline, log_path.read_text()
            time.sleep(.05)
        subprocess.run(['import', '-window', window, 'out/agent-create-picker.png'], check=True, timeout=5)
        key(window, 'Return')
        title(process, 'Threading terminal - CREATED AGENT READY', log_path)
        assert json.loads(marker.read_text()) == report
        os.kill(report['pid'], 0)
        key(window, 'p')
        title(process, 'Threading terminal - CREATED AGENT REVISITED', log_path)
        key(window, 'q')
        title(process, 'Threading terminal - exited 6', log_path)
        key(window, 'ctrl+shift+p')
        title(process, 'Threading agents - ' + str(project), log_path)
        key(window, 'Escape')
        title(process, 'Threading experiment - ' + str(project), log_path)
        key(window, 'Escape')
        assert process.wait(timeout=5) == 0
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)

after = listing()
assert sum(line.startswith('  agent ') for line in after.splitlines()) == 1, after
assert sum(line.startswith('  ') for line in after.splitlines()) == sum(
    line.startswith('  ') for line in before.splitlines()) + 1, after
assert saved_id in after
print('PASS native agent creation: shared flags, discovered ID, saved record, retained child and exit 6', flush=True)

# After the first process exits, a new app window attaches if the daemon still has a child,
# otherwise resumes this exact provider conversation under the same Threading identity.
with (root / 'agent-resume-window.log').open('w+') as log:
    process = subprocess.Popen([binary, '--app-codex', store, endpoint, '/bin/sh', str(child)],
                               stdout=log, stderr=log, env=environment)
    try:
        window = title(process, 'Threading experiment - ' + str(project), root / 'agent-resume-window.log')
        key(window, 'Left')
        title(process, 'Threading agents - ' + str(project), root / 'agent-resume-window.log')
        key(window, 'Return')
        title(process, 'Threading terminal - RESUMED AGENT READY', root / 'agent-resume-window.log')
        resumed = json.loads((project / 'resumed-agent.json').read_text())
        assert resumed['provider_id'] == report['provider_id'], resumed
        assert resumed['argv'][-2:] == ['resume', report['provider_id']], resumed
        key(window, 'q')
        title(process, 'Threading terminal - exited 0', root / 'agent-resume-window.log')
        key(window, 'ctrl+shift+p')
        title(process, 'Threading agents - ' + str(project), root / 'agent-resume-window.log')
        key(window, 'Escape')
        title(process, 'Threading experiment - ' + str(project), root / 'agent-resume-window.log')
        key(window, 'Escape')
        assert process.wait(timeout=5) == 0
    except BaseException:
        log.flush()
        print((root / 'agent-resume-window.log').read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
assert listing() == after, 'resuming created another session record'
print('PASS saved Codex agent resumes the discovered provider ID in a new window', flush=True)

# A competing store owner rejects creation before a record or child can appear.
log_path = root / 'agent-create-refusal.log'
with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app-codex', store, endpoint, '/bin/sh', str(child)],
                               stdout=log, stderr=log, env=environment)
    try:
        window = title(process, 'Threading experiment - ' + str(project), log_path)
        with (Path(store) / 'host.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            key(window, 'ctrl+shift+a')
            title(process, 'Threading terminal - unavailable', log_path)
        key(window, 'ctrl+shift+p')
        title(process, 'Threading experiment - ' + str(project), log_path)
        key(window, 'Escape')
        assert process.wait(timeout=5) == 0
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
assert listing() == after, 'refused creation changed the durable store'
print('PASS native agent creation refusal leaves the store unchanged under a competing owner', flush=True)
