"""The headless Linux host resumes one saved Claude row under its recorded login."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import uuid

host, daemon, socket, fixture = sys.argv[1:]
root = Path(fixture) / 'headless-claude'
root.mkdir()
store = root / 'store'
project = root / 'Project_v1.2 å'
project.mkdir()
home = root / 'home'
home.mkdir()
account = home / '.claude-work'
account.mkdir()
marker = account / 'settings.json'
marker.write_text('{}')
capture = root / 'launches.jsonl'
child = root / 'claude-child'
child.write_text('''#!/usr/bin/python3
import json, os, sys, tty
from pathlib import Path
tty.setraw(0)
args = sys.argv[1:]
account = Path(os.environ['CLAUDE_CONFIG_DIR'])
assert account == Path(os.environ['HOME']) / '.claude-work'
units = os.getcwd().encode('utf-16-le')
slug = ''.join(chr(int.from_bytes(units[i:i+2], 'little'))
    if (65 <= int.from_bytes(units[i:i+2], 'little') <= 90
        or 97 <= int.from_bytes(units[i:i+2], 'little') <= 122
        or 48 <= int.from_bytes(units[i:i+2], 'little') <= 57) else '-'
    for i in range(0, len(units), 2))
if '--session-id' in args:
    identifier = args[args.index('--session-id') + 1]
    transcript = account / 'projects' / slug / (identifier + '.jsonl')
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text('{}\\n')
elif '--resume' in args:
    identifier = args[args.index('--resume') + 1]
    transcript = account / 'projects' / slug / (identifier + '.jsonl')
    assert transcript.is_file()
else:
    raise AssertionError(args)
with open(os.environ['THREADING_HEADLESS_CAPTURE'], 'a') as output:
    output.write(json.dumps({'id': identifier, 'argv': args, 'account': str(account),
                             'cwd': os.getcwd(), 'pid': os.getpid()}) + '\\n')
assert os.read(0, 1) == b'q'
''')
child.chmod(0o700)
environment = dict(os.environ, HOME=str(home), CLAUDE_CONFIG_DIR=str(root / 'wrong-login'),
                   THREADING_HEADLESS_CAPTURE=str(capture))


def launches():
    return [json.loads(line) for line in capture.read_text().splitlines()] if capture.exists() else []


def session_rows():
    with sqlite3.connect(store / 'threading.db') as database:
        return database.execute('SELECT id, data FROM session ORDER BY id').fetchall()


def invoke(*arguments, env=environment, input=b''):
    return subprocess.run([host, str(store), socket, *arguments], env=env,
                          input=input, capture_output=True, timeout=20)


def run_child(*arguments):
    # A piped host has no local tty. Sending q before the child selects raw mode leaves it
    # buffered by the PTY's canonical discipline, so wait for the child's recorder first.
    expected = len(launches()) + 1
    process = subprocess.Popen([host, str(store), socket, *arguments], env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while len(launches()) < expected:
            assert process.poll() is None and time.monotonic() < deadline
            time.sleep(.02)
        stdout, stderr = process.communicate(input=b'q', timeout=20)
        return process.returncode, stdout, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def expect_refusal(message, *arguments, env=environment):
    before = session_rows()
    seen = launches()
    result = invoke(*arguments, env=env)
    assert result.returncode != 0 and message.encode() in result.stderr, result
    assert session_rows() == before, 'refusal modified saved rows'
    assert launches() == seen, 'refusal launched Claude'


def wait_release(identifier):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = subprocess.run([daemon, 'sessions', '--json', '--socket', socket],
                                check=True, capture_output=True, text=True, timeout=8)
        if not any(identifier.lower() in item['id'].lower() for item in json.loads(result.stdout)):
            return
        time.sleep(.1)
    raise AssertionError('daemon retained exited Claude child')


missing_store = root / 'missing-store'
result = subprocess.run([host, str(missing_store), socket, 'resume-claude',
                         str(uuid.uuid4()), '/bin/sh', str(child)], env=environment,
                        input=b'q', capture_output=True, timeout=10)
assert result.returncode != 0 and not missing_store.exists(), result

code, _, stderr = run_child('claude', str(project), '/bin/sh', str(child), 'opening', 'claude-work')
assert code == 0, (code, stderr)
rows = session_rows()
assert len(rows) == 1, rows
saved_id = rows[0][0]
payload = json.loads(rows[0][1])
assert payload['accountHandle'] == 'claude-work'
assert payload['agentSessionID'] == saved_id.lower()
assert launches()[0]['id'] == saved_id.lower()
assert launches()[0]['account'] == str(account)
wait_release(saved_id)

# The fixture child records the provider's actual path; derive that one from its captured ID.
transcript = next((account / 'projects').glob(f'*/{saved_id.lower()}.jsonl'))
transcript.unlink()
resume = ('resume-claude', saved_id, '/bin/sh', str(child))
expect_refusal('missing from its account', *resume)
transcript.write_text('{}\n')
marker.unlink()
expect_refusal('saved Claude account is unavailable', *resume)
marker.write_text('{}')
other_home = root / 'other-home'
other_home.mkdir()
expect_refusal('saved Claude account is unavailable', *resume,
               env=dict(environment, HOME=str(other_home)))

# An unrelated unreadable session must not force a whole-graph decode or be rewritten.
corrupt_id = str(uuid.uuid4()).upper()
with sqlite3.connect(store / 'threading.db') as database:
    project_id = database.execute('SELECT id FROM project').fetchone()[0]
    database.execute('INSERT INTO session (id, project_id, position, kind, last_active_at, data) '
                     'VALUES (?, ?, ?, ?, ?, ?)',
                     (corrupt_id, project_id, 1000, 'claude', time.time(), '{'))
before_ids = {row[0] for row in session_rows()}
before_resume = dict(session_rows())[saved_id]
time.sleep(.02)
code, _, stderr = run_child(*resume)
assert code == 0, (code, stderr)
assert {row[0] for row in session_rows()} == before_ids
assert dict(session_rows())[saved_id] != before_resume, 'admitted resume did not record its launch'
with sqlite3.connect(store / 'threading.db') as database:
    assert database.execute('SELECT data FROM session WHERE id = ?', (corrupt_id,)).fetchone()[0] == '{'
resumed = launches()[1]
assert resumed['id'] == saved_id.lower() and resumed['account'] == str(account)
assert resumed['cwd'] == str(project)
assert resumed['argv'] == ['--permission-mode', 'manual', '--resume', saved_id.lower()]
wait_release(saved_id)

# A disconnected watcher leaves the child with the daemon. A second resume must not start a
# competing writer for the same provider transcript; attach-agent remains the live-child route.
watcher = subprocess.Popen([host, str(store), socket, *resume], env=environment,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 10
    while len(launches()) < 3:
        assert watcher.poll() is None and time.monotonic() < deadline
        time.sleep(.05)
    watcher.terminate()
    watcher.wait(timeout=10)
    before_refusal = session_rows()
    refused = invoke(*resume)
    assert refused.returncode != 0 and b'alreadyExists' in refused.stderr, refused
    assert len(launches()) == 3 and session_rows() == before_refusal
    attached = invoke('attach-agent', saved_id, input=b'q')
    assert attached.returncode == 0, (attached.returncode, attached.stderr)
    wait_release(saved_id)
finally:
    if watcher.poll() is None:
        watcher.kill()
        watcher.wait(timeout=5)

print('PASS headless Claude exact-account resume, preflight refusals, live-child guard and indexed row preservation',
      flush=True)
