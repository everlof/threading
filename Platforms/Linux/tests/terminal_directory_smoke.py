"""Real bash cwd tracking survives same-ID restart and attach without OSC 7."""
import copy
import json
import os
from pathlib import Path
import re
import shlex
import signal
import sqlite3
import subprocess
import sys
import time

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture)
store = root / 'terminal-directory-store'
project = root / 'DirectoryOwner'
other = root / 'OtherDirectoryProject'
nested = project / '日本語 spaced folder'
nested.mkdir(parents=True)
other.mkdir()
home = root / 'terminal-directory-home'
home.mkdir()
for directory in (project, other):
    subprocess.run([host, '--add-project', str(store), str(directory)], check=True,
                   capture_output=True, timeout=10)
database_path = store / 'threading.db'
with sqlite3.connect(database_path) as database:
    project_id, payload = database.execute('SELECT id, data FROM project ORDER BY position LIMIT 1').fetchone()
    value = json.loads(payload)
    assert value['folderPath'] == str(project) and value['terminals'] == []
    value['notificationsMuted'] = True
    value['isExpanded'] = False
    database.execute('UPDATE project SET data = ? WHERE id = ?', (json.dumps(value), project_id))
    other_id, other_payload = database.execute('SELECT id, data FROM project ORDER BY position LIMIT 1 OFFSET 1').fetchone()

# A plain prompt and disabled init files ensure cd produces no OSC 7. OSC 0 below is solely
# a command-completion marker; the cwd must be learned from the actual daemon-owned process.
environment = dict(os.environ, HOME=str(home), PS1='cwd fixture> ', PROMPT_COMMAND='')
environment.pop('BASH_ENV', None)
environment.pop('ENV', None)
process = None
log = None
saved_id = None
owned_pids = set()


def tail():
    if log is None:
        return ''
    with Path(log.name).open('rb') as source:
        source.seek(0, 2)
        source.seek(max(0, source.tell() - 16384))
        return source.read().decode('utf-8', 'replace')


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, 'native window exited: ' + tail()
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {tail()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True,
                          check=True, timeout=5).stdout.strip()


def title(pattern):
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid),
                                  '--name', pattern).splitlines()[0], 'native title ' + pattern)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def command(value):
    # Native clipboard paste preserves UTF-8 paths; input still crosses the product PTY path.
    subprocess.run(['xclip', '-selection', 'clipboard'], input=value, text=True,
                   check=True, timeout=5)
    key('ctrl+shift+v')
    key('Return')


def projects():
    return title('^Threading experiment - ' + re.escape(str(project)) + '$')


def picker():
    return title('^Threading terminals - ' + re.escape(str(project)) + '$')


def sessions():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def held():
    return next((row for row in sessions() if row['id'] == 'terminal-' + saved_id), None)


def record():
    with sqlite3.connect(database_path) as database:
        assert database.execute('SELECT COUNT(*) FROM project').fetchone()[0] == 2
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        assert database.execute('SELECT data FROM project WHERE id = ?', (other_id,)).fetchone()[0] == other_payload
        result = json.loads(database.execute('SELECT data FROM project WHERE id = ?',
                                            (project_id,)).fetchone()[0])
    assert result['id'] == project_id and result['folderPath'] == str(project)
    assert result['notificationsMuted'] is True and result['isExpanded'] is False
    return result


def live(directory, previous_pid=None):
    def read():
        runtime = held()
        if runtime is None or runtime.get('exit') is not None or not runtime['attached']:
            return None
        if previous_pid is not None and runtime['pid'] == previous_pid:
            return None
        assert Path(f"/proc/{runtime['pid']}/cwd").resolve() == directory.resolve(), runtime
        return runtime
    runtime = eventually(read, 'live same-ID child in expected directory')
    owned_pids.add(runtime['pid'])
    return runtime['pid']


def persisted_directory(directory):
    def read():
        current = record()
        assert len(current['terminals']) == 1
        terminal = current['terminals'][0]
        assert terminal['id'] == saved_id
        if terminal['currentDirectory'] != str(directory):
            return None
        expected = copy.deepcopy(baseline)
        expected['terminals'][0]['currentDirectory'] = str(directory)
        assert current == expected, 'cwd update changed ownership, settings, or other terminal metadata'
        return True
    eventually(read, 'durable terminal cwd ' + str(directory))


def change_directory(directory, stage):
    command('cd -- ' + shlex.quote(str(directory))
            + " && printf '\\033]0;DIRECTORY " + stage + "\\007' && pwd")
    title('^Threading terminal - DIRECTORY ' + stage + r'( \[(history cut|restored)\])?$')
    live(directory)
    persisted_directory(directory)


def launch(name):
    global process, log
    log = Path('out/terminal-directory-' + name + '.log').open('w+')
    process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/bash',
                                '--noprofile', '--norc'], env=environment, stdout=log, stderr=log)


def close_live(saved_picker):
    global process, log
    key('ctrl+shift+p')
    if saved_picker:
        picker()
        key('Escape')
    projects()
    key('alt+F4')
    assert process.wait(timeout=5) == 0, tail()
    log.close()
    process = log = None


def exit_shell():
    command('exit')
    title(r'^Threading terminal - exited 0( \[(history cut|restored)\])?$')
    def exited():
        runtime = held()
        return runtime if runtime and runtime.get('exit') == 0 else None
    eventually(exited, 'daemon observes shell exit')


try:
    launch('create')
    window = projects()
    key('Return')
    title(r'^Threading terminal - running( \[(history cut|restored)\])?$')
    baseline = record()
    assert len(baseline['terminals']) == 1
    saved_id = baseline['terminals'][0]['id']
    first_pid = live(project)
    change_directory(nested, 'UNICODE')
    subprocess.run(['import', '-window', window, 'out/terminal-directory-unicode.png'],
                   check=True, timeout=5)
    exit_shell()
    key('ctrl+shift+p')
    projects()
    key('Right')
    picker()
    key('Return')
    title(r'^Threading terminal - running( \[(history cut|restored)\])?$')
    second_pid = live(nested, previous_pid=first_pid)
    persisted_directory(nested)
    close_live(saved_picker=True)

    # The live daemon incarnation must survive the app, then acquire fresh cwd observations.
    launch('attach')
    window = title(r'^Threading terminal - running( \[(history cut|restored)\])?$')
    assert live(nested) == second_pid, 'normal reopening replaced the live shell'
    change_directory(other, 'OTHER')
    assert live(other) == second_pid
    subprocess.run(['import', '-window', window, 'out/terminal-directory-owner-preserved.png'],
                   check=True, timeout=5)
    exit_shell()
    # Removing the remembered directory must not remove either durable owning project record.
    other.rmdir()
    key('ctrl+shift+p')
    picker()
    key('Return')
    title(r'^Threading terminal - running( \[(history cut|restored)\])?$')
    third_pid = live(project, previous_pid=second_pid)
    assert len({first_pid, second_pid, third_pid}) == 3
    persisted_directory(project)
    exit_shell()
    close_live(saved_picker=True)
    print('PASS real bash without OSC 7 persists Unicode/spaced cwd; same-ID restart uses remembered cwd; '
          'live app reattach continues tracking; another imported directory preserves owner/settings; '
          'missing remembered directory falls back to owning project', flush=True)
except BaseException:
    print(tail(), file=sys.stderr)
    raise
finally:
    if process is not None:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
    if log is not None:
        log.close()
    if saved_id is not None:
        try:
            runtime = held()
            if runtime and runtime.get('exit') is None and runtime['pid'] in owned_pids:
                try:
                    os.kill(runtime['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        except Exception as error:
            print(f'fixture child cleanup failed: {error}', file=sys.stderr)
