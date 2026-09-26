"""A clean Linux profile imports a project, then reopens its saved navigator and terminal."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

script, host, daemon, bin_dir, fixture = sys.argv[1:6]
assert sys.argv[6:] in ([], ['--bundled']), 'usage: app_startup_smoke.py SCRIPT HOST DAEMON BIN_DIR FIXTURE [--bundled]'
bundled = sys.argv[6:] == ['--bundled']
root = Path(fixture)
project = root / 'StartupProject'
project.mkdir()
other_project = root / 'StartupOtherProject'
other_project.mkdir()
data = root / 'startup-data'
runtime = root / 'startup-runtime'
socket = runtime / 'pty.sock'
store = data / 'store'
environment = dict(os.environ, THREADING_LINUX_DATA_DIR=str(data),
                   THREADING_LINUX_RUNTIME_DIR=str(runtime), THREADING_LINUX_SHELL='/bin/sh',
                   THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='')
if bundled:
    environment.pop('THREADING_LINUX_BIN_DIR', None)
    environment.pop('THREADING_LINUX_DAEMON_BIN', None)
else:
    environment['THREADING_LINUX_BIN_DIR'] = bin_dir
    environment['THREADING_LINUX_DAEMON_BIN'] = daemon


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


def choose_folder(path):
    dialog = title(process, 'Add project folder')
    subprocess.run(['xclip', '-selection', 'clipboard'], input=str(path),
                   text=True, check=True, timeout=5)
    key(dialog, 'ctrl+l')
    time.sleep(.2)  # GTK creates the location entry after handling the shortcut.
    assert xdo('key', 'ctrl+a', 'BackSpace').returncode == 0
    assert xdo('key', 'ctrl+v').returncode == 0
    time.sleep(.2)
    assert xdo('key', 'ctrl+a', 'ctrl+c').returncode == 0
    selected = subprocess.check_output(['xclip', '-o', '-selection', 'clipboard'],
                                       text=True, timeout=5)
    assert Path(selected).is_dir() and Path(selected).resolve() == path.resolve(), \
        f'GTK selected {selected!r}, expected {str(path)!r}'
    assert xdo('key', 'Return').returncode == 0
    return dialog


def wait_event(marker, count=1):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        contents = Path(log.name).read_text()
        if contents.count(marker) >= count:
            return
        assert process.poll() is None, f'app exited before {marker}: {contents}'
        time.sleep(.05)
    raise AssertionError(f'missing {marker} ({count}): {Path(log.name).read_text()}')


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


def launch(log_name, project_argument=project, codex=None, claude=None):
    log = (root / log_name).open('w+')
    command = [script]
    if project_argument is not None:
        command.append(str(project_argument))
    process = subprocess.Popen(command, cwd=root,
                               env=dict(environment, THREADING_LINUX_CODEX=codex or '',
                                        THREADING_LINUX_CLAUDE=claude or ''),
                               stdout=log, stderr=log)
    return process, log


daemon_pid = None
process = None
log = None
try:
    process, log = launch('startup-first.log', project_argument=None)
    window = title(process, 'Threading experiment - empty store')
    daemon_pid = int((runtime / 'daemon.pid').read_text())
    assert os.stat(data).st_mode & 0o777 == 0o700
    assert os.stat(runtime).st_mode & 0o777 == 0o700
    assert (store / 'threading.db').is_file()
    assert held() == [], 'opening an empty project list spawned a child'
    subprocess.run(['import', '-window', window, 'out/startup-empty-projects.png'], check=True, timeout=5)
    assert xdo('mousemove', '--window', window, '100', '78', 'click', '1').returncode == 0
    choose_folder(project)
    wait_event('PROJECT_IMPORTED ', 1)
    window = title(process, 'Threading experiment - ' + str(project))
    assert held() == [], 'importing a folder spawned a child'
    listing = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert listing.count(str(project)) == 1, listing
    subprocess.run(['import', '-window', window, 'out/startup-imported-project.png'], check=True, timeout=5)
    key(window, 'ctrl+shift+p')
    choose_folder(project)
    wait_event('PROJECT_IMPORTED ', 2)
    title(process, 'Threading experiment - ' + str(project))
    listing = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert listing.count(str(project)) == 1, 'duplicate folder import made a second project'
    key(window, 'ctrl+shift+p')
    dialog = title(process, 'Add project folder')
    key(dialog, 'Escape')
    wait_event('PROJECT_IMPORT_CANCELLED')
    title(process, 'Threading experiment - ' + str(project))
    assert held() == [], 'cancelling the picker spawned a child'
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

    # Both configured providers use the combined targeted entry point before any agent starts.
    process, log = launch('startup-other-project.log', other_project.name,
                          codex='/bin/true', claude='/bin/true')
    window = title(process, 'Threading experiment - ' + str(other_project))
    assert int((runtime / 'daemon.pid').read_text()) == daemon_pid, 'relaunch replaced the live daemon'
    subprocess.run(['import', '-window', window, 'out/startup-target-project.png'], check=True, timeout=5)
    assert next(row for row in held() if row['id'] == first['id'])['pid'] == first['pid']
    assert sum(line.startswith('  ') for line in subprocess.check_output(
        [host, str(store), str(socket), 'list'], text=True, timeout=5).splitlines()) == 1
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
    assert after.count(str(project)) == 1 and after.count(str(other_project)) == 1, after
    assert sum(line.startswith('  ') for line in after.splitlines()) == 1, after
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    # Reopening without a path uses the saved catalogue and does not import or start a child.
    process, log = launch('startup-untargeted.log', project_argument=None)
    window = title(process, 'Threading experiment - ' + str(project))
    assert int((runtime / 'daemon.pid').read_text()) == daemon_pid
    assert len(held()) == 1 and held()[0]['pid'] == first['pid'], held()
    listing = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert listing.count(str(project)) == 1 and listing.count(str(other_project)) == 1, listing
    assert sum(line.startswith('  ') for line in listing.splitlines()) == 1, listing
    key(window, 'Right')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Return')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not any(
            row['id'] == first['id'] and row['attached'] for row in held()):
        time.sleep(.05)
    assert next(row for row in held() if row['id'] == first['id'])['pid'] == first['pid']
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    # The generic provider-enabled path also exposes every saved project without spawning.
    process, log = launch('startup-untargeted-agents.log', project_argument=None,
                          codex='/bin/true', claude='/bin/true')
    window = title(process, 'Threading experiment - ' + str(project))
    key(window, 'Down')
    title(process, 'Threading experiment - ' + str(other_project))
    key(window, 'Right')
    title(process, 'Threading experiment - no saved terminals')
    assert len(held()) == 1 and held()[0]['pid'] == first['pid'], held()
    key(window, 'Escape')
    assert process.wait(timeout=5) == 0
    print('PASS clean-profile native folder import, cancel, duplicate, no-argument reopen, daemon reuse and same-child native reattach', flush=True)
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
