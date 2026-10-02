"""The native window creates, resumes and refuses missing Claude conversations."""
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time

window_binary, host, daemon, endpoint, folder = sys.argv[1:]
root = Path(folder)
store = str(root / 'native-claude-store')
project = root / 'Claude.project_v1.2'
project.mkdir()
home = root / 'native-claude-home'
home.mkdir()
child = root / 'native-claude-child'
child.write_text('''#!/usr/bin/python3
import json, os, signal, sys, tty
from pathlib import Path
tty.setraw(0)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(7))
assert 'CLAUDE_CONFIG_DIR' not in os.environ, os.environ['CLAUDE_CONFIG_DIR']
units = os.getcwd().encode('utf-16-le')
slug = ''.join(chr(int.from_bytes(units[i:i+2], 'little'))
    if (65 <= int.from_bytes(units[i:i+2], 'little') <= 90
        or 97 <= int.from_bytes(units[i:i+2], 'little') <= 122
        or 48 <= int.from_bytes(units[i:i+2], 'little') <= 57) else '-'
    for i in range(0, len(units), 2))
account = Path(os.environ['HOME']) / '.claude'
args = sys.argv[1:]
if '--session-id' in args:
    identifier = args[args.index('--session-id') + 1]
    transcript = account / 'projects' / slug / (identifier + '.jsonl')
    transcript.parent.mkdir(parents=True, exist_ok=True)
    transcript.write_text('{}\\n')
    Path('claude-created.json').write_text(json.dumps({
        'id': identifier, 'argv': args, 'transcript': str(transcript),
        'home': os.environ['HOME'], 'pid': os.getpid()}))
    os.write(1, b'\\x1b]0;CLAUDE CREATED\\x07')
elif '--resume' in args:
    identifier = args[args.index('--resume') + 1]
    assert (account / 'projects' / slug / (identifier + '.jsonl')).exists()
    Path('claude-resumed.json').write_text(json.dumps({
        'id': identifier, 'argv': args, 'pid': os.getpid()}))
    os.write(1, b'\\x1b]0;CLAUDE RESUMED\\x07')
else:
    raise AssertionError(args)
assert os.read(0, 1) == b'q'
''')
child.chmod(0o700)
environment = dict(os.environ, HOME=str(home), CLAUDE_CONFIG_DIR=str(root / 'wrong-account'))
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


def saved_record():
    return json.loads(session_rows()[0][1])


def daemon_row(saved_id):
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            check=True, capture_output=True, text=True, timeout=8)
    return next((item for item in json.loads(result.stdout)
                 if saved_id.lower() in item['id'].lower()), None)


def await_release(saved_id):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                                check=True, capture_output=True, text=True, timeout=8)
        if not any(saved_id.lower() in item['id'].lower() for item in json.loads(result.stdout)):
            return
        time.sleep(.1)
    raise AssertionError('daemon retained exited Claude session')


def visit(name, action, targeted=False):
    log = root / name
    with log.open('w+') as output:
        command = [window_binary, '--app-agents-project' if targeted else '--app-agents',
                   store, endpoint, '/bin/sh', '/bin/true', str(child)]
        if targeted:
            command.append(str(project))
        process = subprocess.Popen(command, env=environment,
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
    subprocess.run(['import', '-window', window, 'out/claude-project-list.png'],
                   check=True, timeout=5)
    key(window, 'ctrl+shift+l')
    title(process, 'Threading terminal - CLAUDE CREATED', log)
    created = json.loads((project / 'claude-created.json').read_text())
    rows = session_rows()
    assert len(rows) == 1, rows
    saved_id, payload = rows[0]
    record = json.loads(payload)
    assert record['kind'] == 'claude' and record['agentSessionID'] == created['id'], record
    assert created['id'] == saved_id.lower(), created
    assert created['argv'] == ['--permission-mode', 'manual', '--session-id', saved_id.lower()], created
    assert created['home'] == str(home), created
    assert Path(created['transcript']).is_file(), created
    key(window, 'ctrl+shift+p')
    title(process, 'Threading experiment - ' + str(project), log)
    key(window, 'Left')
    title(process, 'Threading agents - ' + str(project), log)
    subprocess.run(['import', '-window', window, 'out/claude-agent-picker.png'],
                   check=True, timeout=5)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('native-claude-create.log', create)
saved_id, payload = session_rows()[0]
created = json.loads((project / 'claude-created.json').read_text())
os.kill(created['pid'], 0)

# A targeted reopening attaches the daemon-held process without spawning a second Claude.
reattach_log = root / 'native-claude-reattach.log'
with reattach_log.open('w+') as output:
    process = subprocess.Popen([window_binary, '--app-agents-project', store, endpoint,
                                '/bin/sh', '/bin/true', str(child), str(project)],
                               env=environment, stdout=output, stderr=output)
    try:
        deadline = time.monotonic() + 15
        window = None
        while time.monotonic() < deadline:
            assert process.poll() is None, reattach_log.read_text()
            result = xdo('search', '--name', '^Threading terminal - CLAUDE CREATED \\[.*\\]$')
            if result.returncode == 0:
                window = result.stdout.splitlines()[0]
                break
            time.sleep(.05)
        assert window is not None, reattach_log.read_text()
        os.kill(created['pid'], 0)
        assert len(session_rows()) == 1
        key(window, 'q')
        title(process, 'Threading terminal - exited 0 [history cut]', reattach_log)
        key(window, 'ctrl+shift+p')
        title(process, 'Threading agents - ' + str(project), reattach_log)
        key(window, 'Escape')
        title(process, 'Threading experiment - ' + str(project), reattach_log)
        key(window, 'alt+F4')
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
await_release(saved_id)
assert saved_record()['lastExitCode'] == 0, saved_record()


def reopened_after_exit(process, window, log):
    assert saved_record()['lastExitCode'] == 0


visit('native-claude-reopen-after-exit.log', reopened_after_exit, targeted=True)


def open_saved(process, window, log, expected):
    key(window, 'Left')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Return')
    title(process, 'Threading terminal - ' + expected, log)


def resume(process, window, log):
    open_saved(process, window, log, 'CLAUDE RESUMED')
    assert saved_record().get('lastExitCode') is None, saved_record()
    resumed = json.loads((project / 'claude-resumed.json').read_text())
    assert resumed['id'] == created['id'], resumed
    assert resumed['argv'] == ['--permission-mode', 'manual', '--resume', created['id']], resumed
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('native-claude-resume.log', resume, targeted=True)
assert len(session_rows()) == 1
await_release(saved_id)
assert saved_record()['lastExitCode'] == 0, saved_record()


def leave_child_with_daemon(process, window, log):
    open_saved(process, window, log, 'CLAUDE RESUMED')
    assert saved_record().get('lastExitCode') is None, saved_record()
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('native-claude-background-child.log', leave_child_with_daemon)
background = json.loads((project / 'claude-resumed.json').read_text())
os.kill(background['pid'], signal.SIGTERM)
deadline = time.monotonic() + 10
while True:
    held = daemon_row(saved_id)
    if held is not None and held['exit'] == 7:
        break
    assert time.monotonic() < deadline, held
    time.sleep(.05)
assert saved_record().get('lastExitCode') is None, saved_record()


def reconcile_and_resume(process, window, log):
    assert saved_record()['lastExitCode'] == 7, saved_record()
    open_saved(process, window, log, 'CLAUDE RESUMED')
    assert saved_record().get('lastExitCode') is None, saved_record()
    key(window, 'q')
    title(process, 'Threading terminal - exited 0', log)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('native-claude-background-reconcile.log', reconcile_and_resume, targeted=True)
await_release(saved_id)
resumed_bytes = (project / 'claude-resumed.json').read_bytes()
Path(created['transcript']).unlink()


def refuse(process, window, log):
    open_saved(process, window, log, 'unavailable')
    assert (project / 'claude-resumed.json').read_bytes() == resumed_bytes
    key(window, 'ctrl+shift+p')
    title(process, 'Threading agents - ' + str(project), log)
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project), log)


visit('native-claude-missing.log', refuse)
assert len(session_rows()) == 1
print('PASS native Claude create, same-child reattach, durable foreground/background exits, '
      'accepted resume and missing-transcript refusal',
      flush=True)
