"""A saved native ACP conversation resumes unseen, selected, or after a held pipe child."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import uuid


binary, host, endpoint, fixture, *options = sys.argv[1:]
selected = options in (['selected'], ['held'])
held = options == ['held']
assert not options or selected, options
root = Path(fixture) / ('startup-restore-native-held' if held else
                        'startup-restore-native-selected' if selected else
                        'startup-restore-native')
root.mkdir()
store, project, home = root / 'store', root / 'Project', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true',
                'Seed native restore'], env=environment, input=b'', check=True,
               capture_output=True, timeout=20)
provider_id = str(uuid.uuid4())
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(kind='cursor', nativeUI=True, hasLaunched=True, lastExitCode=None,
                  agentSessionID=provider_id, customTitle='Background native restore')
    record.pop('permissionMode', None)
    database.execute('UPDATE session SET data = ?, kind = ? WHERE id = ?',
                     (json.dumps(record), 'cursor', identifier))
    if selected and not held:
        database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                         ('selectedSessionID', identifier))
    else:
        database.execute('DELETE FROM app_state WHERE key = ?', ('selectedSessionID',))
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('runningSessionIDs', identifier))

capture = root / 'peer.jsonl'
peer = root / 'cursor-peer'
peer.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
assert sys.argv[1:] == ['acp'], sys.argv
assert os.environ.get('NO_OPEN_BROWSER') == '1'
capture = Path(os.environ['THREADING_NATIVE_RESTORE_CAPTURE'])
previous = [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []
prior = next((event['pid'] for event in reversed(previous) if event['event'] == 'started'), None)
prior_stat = Path('/proc/%s/stat' % prior) if prior is not None else None
prior_live = prior_stat is not None and prior_stat.exists() and prior_stat.read_text().split()[2] != 'Z'
with capture.open('a') as target:
    target.write(json.dumps({'event': 'started', 'pid': os.getpid(),
                             'priorLive': prior_live}) + '\\n')
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': 1, 'agentCapabilities': {'loadSession': True}}
    elif method == 'session/load':
        with Path(os.environ['THREADING_NATIVE_RESTORE_CAPTURE']).open('a') as target:
            target.write(json.dumps({'event': 'loaded', 'id': request['params']['sessionId']}) + '\\n')
        result = None
    else:
        raise AssertionError(request)
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
''')
peer.chmod(0o700)
environment['THREADING_LINUX_CURSOR'] = str(peer)
environment['THREADING_NATIVE_RESTORE_CAPTURE'] = str(capture)


def eventually(read, label, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = read()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(label() if callable(label) else label)


def events():
    return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []


def seed_released():
    result = subprocess.run([str(Path(binary).with_name('threading-ptyd')),
                             'sessions', '--json', '--socket', endpoint],
                            check=True, capture_output=True, text=True, timeout=5)
    return not any(identifier.lower() in item['id'].lower()
                   for item in json.loads(result.stdout))


eventually(seed_released, 'seed child remained in daemon')


def run_window(stage, show_pane, expected_loads):
    log_path = root / f'{stage}.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                    '/bin/sh', '/bin/true'], env=environment,
                                   stdout=log, stderr=log)
        try:
            def window():
                assert process.poll() is None, log_path.read_text()[-4000:]
                result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                         '--pid', str(process.pid), '--name', '^Threading'],
                                        capture_output=True, text=True, timeout=5)
                return result.stdout.splitlines()[0] if result.stdout else None
            eventually(window, 'native restore window did not open')
            eventually(lambda: sum(event.get('event') == 'loaded'
                                   and event.get('id') == provider_id
                                   for event in events()) >= expected_loads,
                       lambda: f'native session did not load: {log_path.read_text()[-4000:]}')
            if show_pane:
                eventually(lambda: 'CONVERSATION_FRAME' in log_path.read_text(),
                           lambda: f'selected native pane did not render: {log_path.read_text()[-4000:]}')
            # Renderer creation can replace SDL's initial X11 window. Only the handle after
            # native readiness belongs to the rendered pane and can receive capture/quit.
            wid = eventually(window, 'native restore window disappeared after loading')
            if show_pane:
                subprocess.run(['import', '-window', wid,
                                str(root / ('held-native.png' if held else 'selected-native.png'))],
                               check=True, timeout=8)
            subprocess.run(['xdotool', 'windowfocus', '--sync', wid, 'key', 'alt+F4'],
                           check=True, timeout=5)
            assert process.wait(timeout=10) == 0, log_path.read_text()[-5000:]
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            Path(f'out/{root.name}-{stage}.log').write_text(log_path.read_text())
    return log_path.read_text()


if held:
    first_log = run_window('background', False, 1)
    assert f'STARTUP_RESTORE_LAUNCH id={identifier} native=1' in first_log, first_log[-5000:]
    first_pid = next(event['pid'] for event in events() if event['event'] == 'started')
    assert Path(f'/proc/{first_pid}').exists(), 'daemon did not retain the first pipe child'
    with sqlite3.connect(store / 'threading.db') as database:
        database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                         ('selectedSessionID', identifier))
    log_text = run_window('selected', True, 2)
    started = [event for event in events() if event['event'] == 'started']
    assert len(started) == 2 and started[0]['pid'] != started[1]['pid'], started
    assert started[1]['priorLive'] is False, 'replacement started while prior child was live'
    old_status = Path(f'/proc/{first_pid}/stat')
    assert not old_status.exists() or old_status.read_text().split()[2] == 'Z', \
        'selected restore left the old pipe child running'
else:
    log_text = run_window('window', selected, 1)

if selected:
    assert 'STARTUP_RESTORE_LAUNCH' not in log_text, 'selected native session launched twice'
    assert 'CONVERSATION_FRAME' in log_text, 'selected native session did not mount its pane'
else:
    assert f'STARTUP_RESTORE_LAUNCH id={identifier} native=1' in log_text, log_text[-5000:]
    assert 'CONVERSATION_FRAME' not in log_text, 'background native session mounted a hidden pane'
with sqlite3.connect(store / 'threading.db') as database:
    record = database.execute('SELECT value FROM app_state WHERE key = ?',
                              ('runningSessionIDs',)).fetchone()
assert record and identifier.lower() in record[0].lower(), record
print('PASS Linux startup native: ACP resumed ' + ('held then selected' if held else
      'selected' if selected else 'unseen')
      + ' with one pane owner and durable quit')
