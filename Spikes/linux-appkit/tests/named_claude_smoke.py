"""A named Claude login stays bound to its own config home through create and resume."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

window_binary, host, daemon, endpoint, folder = sys.argv[1:]
root = Path(folder)
store = str(root / 'named-claude-store')
project = root / 'NamedClaude.project_v1'
project.mkdir()
home = root / 'named-claude-home'
home.mkdir()
account = home / '.claude-work'
account.mkdir()
marker = account / 'settings.json'
marker.write_text('{}')
for number in range(40):
    (home / f'.claude-{number:02d}').mkdir()
science = home / '.claude-science'
science.mkdir()
(science / 'settings.json').write_text('{}')
wrong = root / 'wrong-claude-home'
wrong.mkdir()
child = root / 'named-claude-child'
child.write_text('''#!/usr/bin/python3
import json, os, sys, tty
from pathlib import Path
tty.setraw(0)
account = Path(os.environ['CLAUDE_CONFIG_DIR'])
assert account == Path(os.environ['HOME']) / '.claude-work', account
units = os.getcwd().encode('utf-16-le')
slug = ''.join(chr(int.from_bytes(units[i:i+2], 'little'))
    if (65 <= int.from_bytes(units[i:i+2], 'little') <= 90
        or 97 <= int.from_bytes(units[i:i+2], 'little') <= 122
        or 48 <= int.from_bytes(units[i:i+2], 'little') <= 57) else '-'
    for i in range(0, len(units), 2))
args = sys.argv[1:]
if '--session-id' in args:
    identifier = args[args.index('--session-id') + 1]
    transcript = account / 'projects' / slug / (identifier + '.jsonl')
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text('{}\\n')
    Path('named-claude-created.json').write_text(json.dumps({
        'id': identifier, 'account': str(account), 'transcript': str(transcript), 'argv': args}))
    os.write(1, b'\\x1b]0;NAMED CLAUDE CREATED\\x07')
elif '--resume' in args:
    identifier = args[args.index('--resume') + 1]
    assert (account / 'projects' / slug / (identifier + '.jsonl')).is_file()
    Path('named-claude-resumed.json').write_text(json.dumps({
        'id': identifier, 'account': str(account), 'argv': args}))
    os.write(1, b'\\x1b]0;NAMED CLAUDE RESUMED\\x07')
else:
    raise AssertionError(args)
assert os.read(0, 1) == b'q'
''')
child.chmod(0o700)
environment = dict(os.environ, HOME=str(home), CLAUDE_CONFIG_DIR=str(wrong),
                   THREADING_LINUX_CLAUDE_ACCOUNT='claude-missing')
subprocess.run([host, '--add-project', store, str(project)], check=True, capture_output=True,
               timeout=10)


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=5)


def key(window, value):
    result = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert result.returncode == 0, result.stderr


def title(process, expected, log):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, log.read_text()
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing title {expected}: {log.read_text()}')


def session_rows():
    with sqlite3.connect(str(Path(store) / 'threading.db')) as database:
        return database.execute('SELECT id, data FROM session').fetchall()


def await_release(saved_id):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                                check=True, capture_output=True, text=True, timeout=8)
        if not any(saved_id.lower() in item['id'].lower() for item in json.loads(result.stdout)):
            return
        time.sleep(.1)
    raise AssertionError('daemon retained exited named Claude session')


def visit(name, action):
    log = root / name
    with log.open('w+') as output:
        process = subprocess.Popen([window_binary, '--app-claude', store, endpoint,
                                    '/bin/sh', str(child)], env=environment,
                                   stdout=output, stderr=output)
        try:
            window = title(process, 'Threading experiment - ' + str(project), log)
            action(process, window, log)
            key(window, 'alt+F4')
            assert process.wait(timeout=5) == 0
        except BaseException:
            output.flush()
            print(log.read_text(), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)


def create(process, window, log):
    key(window, 'ctrl+shift+o')
    title(process, 'Threading Claude accounts - ' + str(project), log)
    key(window, 'Down')
    deadline = time.monotonic() + 5
    while 'selected=claude-work total=2' not in log.read_text():
        assert time.monotonic() < deadline, log.read_text()
        time.sleep(.05)
    subprocess.run(['import', '-window', window, 'out/claude-account-picker.png'],
                   check=True, timeout=5)
    key(window, 'Return')
    title(process, 'Threading experiment - ' + str(project), log)
    subprocess.run(['import', '-window', window, 'out/claude-named-project.png'],
                   check=True, timeout=5)
    key(window, 'ctrl+shift+l')
    title(process, 'Threading terminal - NAMED CLAUDE CREATED', log)
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading experiment - ' + str(project), log)


visit('named-claude-create.log', create)
rows = session_rows()
assert len(rows) == 1, rows
saved_id, payload = rows[0]
created = json.loads((project / 'named-claude-created.json').read_text())
record = json.loads(payload)
assert record['accountHandle'] == 'claude-work', record
assert record['agentSessionID'] == created['id'] == saved_id.lower(), record
assert created['account'] == str(account), created
assert created['argv'] == ['--permission-mode', 'manual', '--session-id', saved_id.lower()], created
await_release(saved_id)


def open_saved(process, window, log, expected):
    key(window, 'Left')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Return')
    title(process, 'Threading terminal - ' + expected, log)


def resume(process, window, log):
    open_saved(process, window, log, 'NAMED CLAUDE RESUMED')
    resumed = json.loads((project / 'named-claude-resumed.json').read_text())
    assert resumed['account'] == str(account) and resumed['id'] == created['id'], resumed
    assert resumed['argv'] == ['--permission-mode', 'manual', '--resume', created['id']], resumed
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('named-claude-resume.log', resume)
await_release(saved_id)
resumed_bytes = (project / 'named-claude-resumed.json').read_bytes()


def refuse(process, window, log):
    open_saved(process, window, log, 'unavailable')
    assert (project / 'named-claude-resumed.json').read_bytes() == resumed_bytes
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


marker.unlink()
visit('named-claude-unverified.log', refuse)
marker.write_text('{}')
environment['HOME'] = str(wrong)
visit('named-claude-wrong-home.log', refuse)
assert len(session_rows()) == 1, 'refused resumes wrote another record'

# The headless adapter accepts the same explicit handle and rejects an unavailable one.
environment['HOME'] = str(home)
cli_project = root / 'NamedClaudeCLI'
cli_project.mkdir()
cli_child = root / 'named-claude-cli-child'
cli_child.write_text('''#!/usr/bin/python3
import json, os
from pathlib import Path
Path('named-claude-cli.json').write_text(json.dumps({
    'account': os.environ.get('CLAUDE_CONFIG_DIR')}))
''')
cli_child.chmod(0o700)
subprocess.run([host, store, endpoint, 'claude', str(cli_project), '/bin/sh',
                str(cli_child), 'inspect', 'claude-work'], env=environment,
               input=b'', capture_output=True, check=True, timeout=15)
assert json.loads((cli_project / 'named-claude-cli.json').read_text())['account'] == str(account)
assert len(session_rows()) == 2
result = subprocess.run([host, store, endpoint, 'claude', str(cli_project), '/bin/sh',
                         str(cli_child), 'inspect', 'claude-unknown'], env=environment,
                        input=b'', capture_output=True, timeout=15)
assert result.returncode != 0 and len(session_rows()) == 2, result
print('PASS named Claude create, exact resume, missing-login/wrong-home refusal and CLI route',
      flush=True)
