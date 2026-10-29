"""Six restored native agents share Mac's four-idle-process retention rule."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import uuid


binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'native-retention'
root.mkdir()
store, project, home = root / 'store', root / 'Project', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))

for number in range(6):
    subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh',
                    '/bin/true', f'Seed native {number}'], env=environment,
                   input=b'', check=True, capture_output=True, timeout=20)

with sqlite3.connect(store / 'threading.db') as database:
    rows = database.execute('SELECT id, data FROM session').fetchall()
    assert len(rows) == 6, rows
    identifiers = []
    transcripts = {}
    for identifier, payload in rows:
        record = json.loads(payload)
        transcript_id = str(uuid.uuid4())
        record.update(kind='cursor', nativeUI=True, hasLaunched=True,
                      lastExitCode=None, agentSessionID=transcript_id)
        record.pop('permissionMode', None)
        database.execute('UPDATE session SET data = ?, kind = ? WHERE id = ?',
                         (json.dumps(record), 'cursor', identifier))
        identifiers.append(identifier)
        transcripts[transcript_id.lower()] = identifier.lower()
    database.execute('DELETE FROM app_state WHERE key = ?', ('selectedSessionID',))
    database.execute('INSERT OR REPLACE INTO app_state (key, value) VALUES (?, ?)',
                     ('runningSessionIDs', ' '.join(identifiers)))

capture = root / 'peer.jsonl'
peer = root / 'cursor-peer'
peer.write_text('''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
assert sys.argv[1:] == ['acp'], sys.argv
capture = Path(os.environ['THREADING_NATIVE_RETENTION_CAPTURE'])
with capture.open('a') as target:
    target.write(json.dumps({'event': 'started', 'pid': os.getpid()}) + '\\n')
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        result = {'protocolVersion': 1, 'agentCapabilities': {'loadSession': True}}
    elif method == 'session/load':
        with capture.open('a') as target:
            target.write(json.dumps({'event': 'loaded', 'pid': os.getpid(),
                                     'id': request['params']['sessionId']}) + '\\n')
        result = None
    else:
        raise AssertionError(request)
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
''')
peer.chmod(0o700)
environment['THREADING_LINUX_CURSOR'] = str(peer)
environment['THREADING_NATIVE_RETENTION_CAPTURE'] = str(capture)
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
log_path = output / 'native-retention.log'


def seed_released():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            check=True, capture_output=True, text=True, timeout=5)
    summaries = json.loads(result.stdout)
    return not any(identifier.lower() in summary['id'].lower()
                   for identifier in identifiers for summary in summaries)


deadline = time.monotonic() + 20
while time.monotonic() < deadline and not seed_released():
    time.sleep(.05)
assert seed_released(), 'a seed child remained owned by the daemon'


def events():
    return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []


def alive(pid):
    status = Path(f'/proc/{pid}/stat')
    return status.exists() and status.read_text().split()[2] != 'Z'


def retired_ids():
    return set(re.findall(r'IDLE_NATIVE_RETIRED id=([0-9A-Fa-f-]{36})',
                          log_path.read_text()))


def eventually(check, label, process, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()[-5000:]
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()[-5000:]}')


with log_path.open('w') as log:
    process = subprocess.Popen([binary, '--app-codex', str(store), endpoint,
                                '/bin/sh', '/bin/true'], env=environment,
                               stdout=log, stderr=log)
    try:
        window = eventually(lambda: subprocess.run(
            ['xdotool', 'search', '--all', '--onlyvisible', '--pid', str(process.pid),
             '--name', '^Threading'], capture_output=True, text=True).stdout.splitlines(),
            'window did not open', process)[0]
        eventually(lambda: len([event for event in events() if event['event'] == 'loaded']) == 6,
                   'six native conversations did not load', process)
        retired = eventually(lambda: retired_ids() if len(retired_ids()) == 2 else None,
            'shared four-idle-agent cap did not retire two sessions', process)
        loaded = {transcripts[event['id'].lower()]: event['pid'] for event in events()
                  if event['event'] == 'loaded'}
        eventually(lambda: all(not alive(loaded[identifier.lower()]) for identifier in retired),
                   'retired provider process survived', process)
        assert len([pid for pid in loaded.values() if alive(pid)]) == 4, loaded
        assert 'CONVERSATION_FRAME' not in log_path.read_text(), \
            'background restore built a hidden conversation pane'
        subprocess.run(['xdotool', 'windowfocus', '--sync', window, 'key', 'alt+F4'],
                       check=True, timeout=5)
        assert process.wait(timeout=10) == 0, log_path.read_text()[-5000:]
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

with sqlite3.connect(store / 'threading.db') as database:
    record = database.execute('SELECT value FROM app_state WHERE key = ?',
                              ('runningSessionIDs',)).fetchone()
assert record and len(record[0].split()) == 4, record
print('PASS Linux native retention: six hidden restores, two retired, four kept')
