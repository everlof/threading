"""A clean Linux profile imports a project, starts its daemon and reopens one native terminal."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, host, daemon, bin_dir, fixture = sys.argv[1:]
root = Path(fixture)
project = root / 'StartupProject'
project.mkdir()
data = root / 'startup-data'
runtime = root / 'startup-runtime'
socket = runtime / 'pty.sock'
store = data / 'store'
environment = dict(os.environ, THREADING_LINUX_DATA_DIR=str(data),
                   THREADING_LINUX_RUNTIME_DIR=str(runtime), THREADING_LINUX_BIN_DIR=bin_dir,
                   THREADING_LINUX_DAEMON_BIN=daemon, THREADING_LINUX_SHELL='/bin/sh',
                   THREADING_LINUX_CODEX='')


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=4)


def title(process, expected):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        assert process.poll() is None, f'app exited before {expected}'
        result = xdo('search', '--name', '^' + expected + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError('missing title: ' + expected)


def key(window, value):
    assert xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value).returncode == 0


def held():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', str(socket)],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def terminal_row():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        rows = [row for row in held() if row['id'].startswith('terminal-')]
        if len(rows) == 1:
            return rows[0]
        time.sleep(.05)
    raise AssertionError('daemon did not retain the project terminal')


def launch(log_name, project_argument=None):
    log = (root / log_name).open('w+')
    process = subprocess.Popen([script, project_argument or str(project)], cwd=root,
                               env=environment, stdout=log, stderr=log)
    return process, log


daemon_pid = None
process = None
log = None
try:
    process, log = launch('startup-first.log')
    window = title(process, 'Threading experiment - ' + str(project))
    daemon_pid = int((runtime / 'daemon.pid').read_text())
    assert os.stat(data).st_mode & 0o777 == 0o700
    assert os.stat(runtime).st_mode & 0o777 == 0o700
    key(window, 'Return')
    first = terminal_row()
    listing = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert listing.count(str(project)) == 1 and sum(
        line.startswith('  ') for line in listing.splitlines()) == 1, listing
    key(window, 'ctrl+shift+p')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    process, log = launch('startup-second.log', project.name)
    window = title(process, 'Threading experiment - ' + str(project))
    assert int((runtime / 'daemon.pid').read_text()) == daemon_pid, 'relaunch replaced the live daemon'
    key(window, 'Right')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Return')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not any(
            row['id'] == first['id'] and row['attached'] for row in held()):
        time.sleep(.05)
    second = next(row for row in held() if row['id'] == first['id'])
    assert second['pid'] == first['pid'] and second['attached'], (first, second)
    after = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert after == listing, 'reopening created another project or terminal'
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    print('PASS clean-profile project import, daemon startup/reuse and same-child native reattach', flush=True)
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    if log is not None:
        log.close()
    if daemon_pid is not None:
        try:
            os.kill(daemon_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
