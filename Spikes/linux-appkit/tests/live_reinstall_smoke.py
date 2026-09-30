"""Keep a non-root terminal alive while the parent reinstalls the actual .deb."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, daemon, fixture, manifest = sys.argv[1:5]
root = Path(fixture)
project = root / 'UpgradeProject'
project.mkdir()
data = root / 'data'
runtime = root / 'runtime'
socket = runtime / 'pty.sock'
environment = dict(os.environ, THREADING_LINUX_DATA_DIR=str(data),
                   THREADING_LINUX_RUNTIME_DIR=str(runtime), THREADING_LINUX_SHELL='/bin/sh',
                   THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='')
generation = next(line.removeprefix('daemon_generation=') for line in Path(manifest).read_text().splitlines()
                  if line.startswith('daemon_generation='))


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=5)


def title(process, expected, prefix=False):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        assert process.poll() is None, f'app exited before {expected}'
        pattern = '^' + expected + ('' if prefix else '$')
        result = xdo('search', '--onlyvisible', '--name', pattern)
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError('missing title: ' + expected)


def key(window, value):
    result = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert result.returncode == 0, (value, result.stdout, result.stderr)


def held():
    import json
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', str(socket)],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def live_terminal():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        rows = [row for row in held() if row['id'].startswith('terminal-') and row.get('exit') is None]
        if len(rows) == 1:
            return rows[0]
        time.sleep(.05)
    raise AssertionError('daemon did not retain a live terminal')


def check_daemon(expected_pid, expected_child):
    assert int((runtime / 'daemon.pid').read_text()) == expected_pid
    row = live_terminal()
    assert row['id'] == expected_child['id'] and row['pid'] == expected_child['pid'], row
    status = subprocess.check_output([daemon, 'status', '--socket', str(socket)],
                                     text=True, timeout=5)
    assert f'build {generation}, pid {expected_pid},' in status, status
    return row


def launch(log_name, path=None):
    log = (root / log_name).open('w+')
    command = [script] + ([str(path)] if path is not None else [])
    return subprocess.Popen(command, cwd=root, env=environment, stdout=log, stderr=log), log


process = None
log = None
daemon_pid = None
try:
    process, log = launch('first.log', project)
    window = title(process, 'Threading experiment - ' + str(project))
    key(window, 'Return')
    first = live_terminal()
    daemon_pid = int((runtime / 'daemon.pid').read_text())
    check_daemon(daemon_pid, first)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None
    deadline = time.monotonic() + 10
    while live_terminal()['attached']:
        assert time.monotonic() < deadline, 'closing the app did not detach its live terminal'
        time.sleep(.05)

    # The root runner owns dpkg; this user owns the XDG store and daemon. Synchronize so package
    # replacement happens after app exit but while the old daemon and its child are still alive.
    (root / 'ready').write_text(f'{daemon_pid} {first["pid"]}\n')
    deadline = time.monotonic() + 45
    while not (root / 'reinstalled').exists():
        assert time.monotonic() < deadline, 'timed out waiting for package reinstall'
        assert live_terminal()['pid'] == first['pid'], 'child exited during reinstall'
        time.sleep(.1)

    check_daemon(daemon_pid, first)
    process, log = launch('after-reinstall.log')
    window = title(process, 'Threading terminal - ', prefix=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        row = check_daemon(daemon_pid, first)
        if row['attached']:
            break
        time.sleep(.05)
    else:
        raise AssertionError('installed replacement did not automatically reattach the existing child')
    subprocess.run(['import', '-window', window, 'out/reinstall-reattached.png'],
                   check=True, timeout=5)
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    print('PASS live daemon and terminal child survive .deb reinstall and automatically reattach from installed launcher', flush=True)
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
