"""A named Codex login stays bound to its own home through create and resume."""
import datetime
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import uuid

window_binary, host, daemon, endpoint, folder = sys.argv[1:]
root = Path(folder)
store = str(root / 'named-codex-store')
project = root / 'NamedCodexProject'
project.mkdir()
home = root / 'named-home'
home.mkdir()
account = home / '.codex-work'
account.mkdir()
(account / 'auth.json').write_text('{}')
for number in range(40):
    (home / f'.codex-{number:02d}').mkdir()
foreign = root / 'named-foreign'
foreign.mkdir()
child = root / 'named-codex-child'
child.write_text('''#!/usr/bin/python3
import datetime, json, os, sys, tty, uuid
from pathlib import Path
tty.setraw(0)
account = Path(os.environ['CODEX_HOME'])
assert account == Path(os.environ['HOME']) / '.codex-work', account
if 'resume' in sys.argv[1:]:
    provider_id = sys.argv[sys.argv.index('resume') + 1]
    Path('named-resumed.json').write_text(json.dumps({
        'account': str(account), 'id': provider_id, 'argv': sys.argv[1:]}))
    os.write(1, b'\\x1b]0;NAMED RESUMED\\x07')
    assert os.read(0, 1) == b'q'
    sys.exit(0)
provider_id = str(uuid.uuid4())
day = datetime.datetime.now(datetime.timezone.utc)
sessions = account / 'sessions' / day.strftime('%Y/%m/%d')
sessions.mkdir(parents=True, exist_ok=True)
(sessions / ('rollout-' + provider_id + '.jsonl')).write_text(json.dumps({
    'type': 'session_meta', 'payload': {'id': provider_id, 'cwd': os.getcwd()}
}) + '\\n')
Path('named-created.json').write_text(json.dumps({
    'account': str(account), 'id': provider_id, 'argv': sys.argv[1:]}))
os.write(1, b'\\x1b]0;NAMED CREATED\\x07')
assert os.read(0, 1) == b'q'
sys.exit(0)
''')
child.chmod(0o700)
environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(foreign),
                   THREADING_LINUX_CODEX_ACCOUNT='codex-missing')
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
    raise AssertionError('daemon retained exited named agent')


def visit(log_name, action):
    log = root / log_name
    with log.open('w+') as output:
        process = subprocess.Popen([window_binary, '--app-codex', store, endpoint,
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
    key(window, 'ctrl+shift+i')
    title(process, 'Threading Codex accounts - ' + str(project), log)
    key(window, 'Down')
    deadline = time.monotonic() + 5
    while 'selected=codex-work total=2' not in log.read_text():
        assert time.monotonic() < deadline, log.read_text()
        time.sleep(.05)
    subprocess.run(['import', '-window', window, 'out/codex-account-picker.png'],
                   check=True, timeout=5)
    # The production menu row commits on a pointer release; choosing this login must
    # still carry its exact handle through the host-owned launch route.
    xdo('mousemove', '--window', window, '120', '170', 'click', '1')
    title(process, 'Threading experiment - ' + str(project), log)
    key(window, 'ctrl+shift+i')
    title(process, 'Threading Codex accounts - ' + str(project), log)
    subprocess.run(['import', '-window', window, 'out/codex-account-picker-active.png'],
                   check=True, timeout=5)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)
    key(window, 'ctrl+shift+a')
    title(process, 'Threading terminal - NAMED CREATED', log)
    created = json.loads((project / 'named-created.json').read_text())
    assert created['account'] == str(account), created
    deadline = time.monotonic() + 5
    while True:
        rows = session_rows()
        if len(rows) == 1 and json.loads(rows[0][1]).get('agentSessionID') == created['id']:
            break
        assert time.monotonic() < deadline, rows
        time.sleep(.05)
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading experiment - ' + str(project), log)
    key(window, 'Left')
    title(process, 'Threading agents - ' + str(project), log)
    subprocess.run(['import', '-window', window, 'out/named-codex-picker.png'],
                   check=True, timeout=5)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('named-create.log', create)
rows = session_rows()
assert len(rows) == 1, rows
saved_id, payload = rows[0]
record = json.loads(payload)
created = json.loads((project / 'named-created.json').read_text())
assert record['accountHandle'] == 'codex-work', record
assert record['agentSessionID'] == created['id'], record
await_release(saved_id)


def open_saved(process, window, log, expected):
    key(window, 'Left')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Return')
    title(process, 'Threading terminal - ' + expected, log)


def resume(process, window, log):
    open_saved(process, window, log, 'NAMED RESUMED')
    resumed = json.loads((project / 'named-resumed.json').read_text())
    assert resumed['account'] == str(account) and resumed['id'] == created['id'], resumed
    assert resumed['argv'][-2:] == ['resume', created['id']], resumed
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('named-resume.log', resume)
assert len(session_rows()) == 1
await_release(saved_id)
resumed_bytes = (project / 'named-resumed.json').read_bytes()


def refuse(process, window, log):
    open_saved(process, window, log, 'unavailable')
    assert (project / 'named-resumed.json').read_bytes() == resumed_bytes
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


(account / 'auth.json').unlink()
visit('named-unverified.log', refuse)
(account / 'auth.json').write_text('{}')
environment['HOME'] = str(foreign)
visit('named-wrong-home.log', refuse)
assert len(session_rows()) == 1, 'refused resumes wrote another record'

# The headless adapter accepts the same explicit handle and uses the same account route.
environment['HOME'] = str(home)
cli_project = root / 'NamedCodexCLI'
cli_project.mkdir()
cli_child = root / 'named-cli-child'
cli_child.write_text('''#!/usr/bin/python3
import json, os
from pathlib import Path
Path('named-cli.json').write_text(json.dumps({'home': os.environ.get('CODEX_HOME')}))
''')
cli_child.chmod(0o700)
subprocess.run([host, store, endpoint, 'codex', str(cli_project), '/bin/sh',
                str(cli_child), 'inspect', 'codex-work'], env=environment,
               input=b'', capture_output=True, check=True, timeout=15)
assert json.loads((cli_project / 'named-cli.json').read_text())['home'] == str(account)
assert len(session_rows()) == 2
print('PASS named Codex create, exact resume, missing-login/wrong-home refusal and CLI route',
      flush=True)
