"""A clean Linux profile imports a project, then reopens its saved navigator and terminal."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
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
        result = xdo('search', '--onlyvisible', '--name', '^' + expected + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError('missing title: ' + expected)


def key(window, value):
    result = xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)
    assert result.returncode == 0, (window, value, result.stdout, result.stderr)


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


def fixture_daemon_pid():
    """The launcher may start its daemon before the first window becomes observable."""
    try:
        with (runtime / 'daemon.pid').open('rb') as source:
            pid = int(source.read(32))
        if pid <= 1:
            return None
        with Path(f'/proc/{pid}/cmdline').open('rb') as source:
            arguments = source.read(16384).split(b'\0')
        expected = [os.fsencode(daemon), b'--socket', os.fsencode(socket),
                    b'--state', os.fsencode(data / 'daemon')]
        return pid if arguments[:5] == expected else None
    except (OSError, ValueError):
        return None


def capture_startup_failure(error):
    """Keep bounded fixture evidence before cleanup, without collecting the environment."""
    evidence = [f'{type(error).__name__}: {str(error)[:4096]}']
    for name, path in [('launcher', Path(log.name) if log is not None else None),
                       ('daemon', data / 'daemon.log')]:
        try:
            if path is None:
                continue
            with path.open('rb') as source:
                source.seek(0, os.SEEK_END)
                source.seek(max(0, source.tell() - 16384))
                evidence.append(f'{name} log (last 16 KiB):\n' + source.read(16384).decode('utf-8', 'replace'))
        except OSError as failure:
            evidence.append(f'{name} log unavailable: {failure}')

    pending = [pid for pid in (process.pid if process is not None else None,
                               fixture_daemon_pid()) if pid is not None]
    seen = set()
    while pending and len(seen) < 32:
        pid = pending.pop(0)
        if pid in seen:
            continue
        seen.add(pid)
        try:
            with Path(f'/proc/{pid}/stat').open('rb') as source:
                status = source.read(1024).decode('utf-8', 'replace')
            with Path(f'/proc/{pid}/wchan').open('rb') as source:
                waiting = source.read(128).decode('utf-8', 'replace')
            evidence.append(f'fixture process: {status.rstrip()} wait={waiting}')
            with os.scandir(f'/proc/{pid}/task') as tasks:
                for index, task in enumerate(tasks):
                    if index >= 32:
                        break
                    try:
                        with (Path(task.path) / 'children').open('rb') as source:
                            children = [int(child) for child in source.read(4096).split()
                                        if child.isdigit()]
                            pending.extend(children[:max(0, 32 - len(seen) - len(pending))])
                    except OSError:
                        pass
        except OSError as failure:
            evidence.append(f'fixture process {pid} unavailable: {failure}')

    deadline = time.monotonic() + 8

    def diagnostic_command(arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return ''
        try:
            with tempfile.TemporaryFile() as output:
                subprocess.run(arguments, stdout=output, stderr=subprocess.STDOUT,
                               timeout=min(1, remaining), check=False)
                output.seek(0)
                return output.read(4096).decode('utf-8', 'replace')
        except (OSError, subprocess.TimeoutExpired) as failure:
            evidence.append(f'diagnostic command unavailable: {type(failure).__name__}')
            return ''

    windows = set()
    for pid in sorted(seen):
        found = diagnostic_command(['xdotool', 'search', '--onlyvisible', '--all',
                                    '--pid', str(pid), '--name', '.'])
        for window in found.splitlines():
            if window.isdecimal() and window not in windows and len(windows) < 16:
                windows.add(window)
                title = diagnostic_command(['xdotool', 'getwindowname', window])
                evidence.append(f'fixture window {window}: {title.rstrip()}')
    Path('out/startup-failure.log').write_text('\n\n'.join(evidence) + '\n')


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
    key(window, 'alt+F4')
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
    key(window, 'alt+F4')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    process, log = launch('startup-second.log', project.name)
    window = title(process, 'Threading terminal - .*')
    assert int((runtime / 'daemon.pid').read_text()) == daemon_pid, 'relaunch replaced the live daemon'
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
    key(window, 'alt+F4')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    # Reopening without a path attaches the saved child directly, without spawning another.
    process, log = launch('startup-untargeted.log', project_argument=None)
    window = title(process, 'Threading terminal - .*')
    assert int((runtime / 'daemon.pid').read_text()) == daemon_pid
    assert len(held()) == 1 and held()[0]['pid'] == first['pid'], held()
    listing = subprocess.check_output([host, str(store), str(socket), 'list'], text=True, timeout=5)
    assert listing.count(str(project)) == 1 and listing.count(str(other_project)) == 1, listing
    assert sum(line.startswith('  ') for line in listing.splitlines()) == 1, listing
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not any(
            row['id'] == first['id'] and row['attached'] for row in held()):
        time.sleep(.05)
    assert next(row for row in held() if row['id'] == first['id'])['pid'] == first['pid']
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'alt+F4')
    assert process.wait(timeout=5) == 0
    log.close()
    process = None

    # Provider availability does not displace the saved standalone-terminal route.
    process, log = launch('startup-untargeted-agents.log', project_argument=None,
                          codex='/bin/true', claude='/bin/true')
    window = title(process, 'Threading terminal - .*')
    key(window, 'ctrl+shift+p')
    title(process, 'Threading terminals - ' + str(project))
    key(window, 'Escape')
    title(process, 'Threading experiment - ' + str(project))
    key(window, 'Down')
    title(process, 'Threading experiment - ' + str(other_project))
    key(window, 'Right')
    title(process, 'Threading experiment - no saved terminals')
    assert len(held()) == 1 and held()[0]['pid'] == first['pid'], held()
    key(window, 'alt+F4')
    assert process.wait(timeout=5) == 0
    print('PASS clean-profile native folder import, cancel, duplicate, no-argument reopen, daemon reuse and same-child native reattach', flush=True)
except BaseException as error:
    try:
        capture_startup_failure(error)
    except Exception as failure:
        print(f'startup diagnostics unavailable: {type(failure).__name__}', file=sys.stderr)
    raise
finally:
    try:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired) as failure:
        print(f'startup launcher cleanup failed: {type(failure).__name__}', file=sys.stderr)
    try:
        if log is not None:
            log.close()
    except OSError as failure:
        print(f'startup log cleanup failed: {type(failure).__name__}', file=sys.stderr)
    cleanup_daemon_pid = fixture_daemon_pid()
    if cleanup_daemon_pid is not None:
        try:
            os.kill(cleanup_daemon_pid, signal.SIGTERM)
        except OSError as failure:
            print(f'startup daemon cleanup failed: {type(failure).__name__}', file=sys.stderr)
