"""A saved agent session survives its CLI client and reopens in the native window."""
import json
import fcntl
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time
import uuid

binary, host, endpoint, folder = sys.argv[1:]
root = Path(folder)
store = str(root / 'agent-window-store')
project = root / 'AgentProject'
project.mkdir()
other_project = root / 'OtherAgentProject'
other_project.mkdir()
subprocess.run([host, '--add-project', store, str(other_project)], check=True,
               capture_output=True, timeout=8)
child = root / 'agent-window-child'
child.write_text('''#!/usr/bin/python3
import json, os, signal, sys, termios, tty
from pathlib import Path
tty.setraw(0)
changes = [0]
signal.signal(signal.SIGWINCH, lambda *_: changes.__setitem__(0, changes[0] + 1))
Path('agent-child.json').write_text(json.dumps({'pid': os.getpid(), 'argv': sys.argv[1:]}))
os.write(1, b'Original agent child\\r\\n\\x1b]0;AGENT READY\\x07')
before = changes[0]
assert os.read(0, 1) == b'p'
assert changes[0] == before, 'graphical attach resized the agent PTY'
os.write(1, b'SAME AGENT CHILD\\r\\n\\x1b]0;AGENT LIVE\\x07')
assert os.read(0, 1) == b'q'
sys.exit(9)
''')
child.chmod(0o700)
log_path = root / 'agent-window.log'
older_child = root / 'agent-older-child'
older_child.write_text('''#!/usr/bin/python3
import json, os, sys, tty
from pathlib import Path
tty.setraw(0)
Path('older-agent-child.json').write_text(json.dumps({'pid': os.getpid()}))
os.write(1, b'\\x1b]0;OLDER AGENT READY\\x07')
assert os.read(0, 1) == b'q'
sys.exit(0)
''')
older_child.chmod(0o700)
# An observed exited PTY is retained for only five seconds. Seed a live older agent so
# this picker test exercises two durable identities regardless of test-machine speed.
with (root / 'agent-older-host.log').open('w+') as older_log:
    older_cli = subprocess.Popen([host, store, endpoint, 'codex', str(project), '/bin/sh',
                                  str(older_child), 'older session'], stdin=subprocess.PIPE,
                                 stdout=older_log, stderr=older_log)
    try:
        deadline = time.monotonic() + 15
        older_marker = project / 'older-agent-child.json'
        while not older_marker.exists():
            assert older_cli.poll() is None and time.monotonic() < deadline, 'older agent did not start'
            time.sleep(.05)
        older_pid = json.loads(older_marker.read_text())['pid']
        older_cli.send_signal(signal.SIGTERM)
        assert older_cli.wait(timeout=5) == 143
        older_cli.stdin.close()
        os.kill(older_pid, 0)
    finally:
        if older_cli.poll() is None:
            older_cli.kill()
        older_cli.wait(timeout=3)


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def await_title(process, expected, output=log_path):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {expected}: {output.read_text()}'
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing title {expected}: {output.read_text()}')


def listing():
    return subprocess.run([host, store, endpoint, 'list'], check=True, capture_output=True,
                          text=True, timeout=8).stdout


def selected_session():
    with sqlite3.connect(str(Path(store) / 'threading.db')) as database:
        row = database.execute("SELECT value FROM app_state WHERE key='selectedSessionID'").fetchone()
        return row[0] if row else None


def await_selection(output, expected, previous_count):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        frames = [line for line in output.read_text().splitlines()
                  if line.startswith('AGENT_PICKER_FRAME ')]
        if any('selected=' + expected in line for line in frames[previous_count:]):
            return
        time.sleep(.05)
    raise AssertionError(f'agent picker did not select {expected}: {output.read_text()}')


with log_path.open('w+') as log:
    cli = subprocess.Popen([host, store, endpoint, 'codex', str(project), '/bin/sh', str(child),
                            'inspect this project'], stdin=subprocess.PIPE, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 15
        marker = project / 'agent-child.json'
        while not marker.exists():
            assert cli.poll() is None and time.monotonic() < deadline, 'agent did not start'
            time.sleep(.05)
        original = json.loads(marker.read_text())
        assert original['argv'][-2:] == ['--', 'inspect this project'], original
        cli.send_signal(signal.SIGTERM)
        assert cli.wait(timeout=5) == 143
        cli.stdin.close()
        os.kill(original['pid'], 0)
        saved = listing()
        agents = [line.strip().split()[1] for line in saved.splitlines() if line.startswith('  agent ')]
        assert len(agents) == 2, saved
        with (root / 'agent-attachment.log').open('w+') as window_log:
            process = subprocess.Popen([binary, '--attach-agent', store, endpoint, agents[-1]],
                                       stdout=window_log, stderr=window_log)
            try:
                window = await_title(process, 'Threading terminal - AGENT READY [history cut]', root / 'agent-attachment.log')
                geometry = xdo('getwindowgeometry', '--shell', window).stdout
                assert 'WIDTH=800\n' in geometry and 'HEIGHT=528\n' in geometry, geometry
                assert json.loads(marker.read_text()) == original
                assert xdo('windowfocus', window, 'key', 'alt+F4').returncode == 0
                assert process.wait(timeout=5) == 0
            except BaseException:
                window_log.flush()
                print((root / 'agent-attachment.log').read_text(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        os.kill(original['pid'], 0)
        app_log_path = root / 'agent-app.log'
        with app_log_path.open('w+') as app_log:
            process = subprocess.Popen([binary, '--app-project', store, endpoint, '/bin/sh',
                                        str(other_project)],
                                       stdout=app_log, stderr=app_log)
            try:
                window = await_title(process, 'Threading experiment - ' + str(other_project),
                                     app_log_path)
                assert selected_session() == agents[-1], 'project targeting changed agent selection'
                assert xdo('windowfocus', window, 'key', 'Down').returncode == 0
                await_title(process, 'Threading experiment - ' + str(project), app_log_path)
                assert xdo('windowfocus', window, 'key', 'Left').returncode == 0
                await_title(process, 'Threading agents - ' + str(project), app_log_path)
                deadline = time.monotonic() + 5
                while f'AGENT_PICKER_FRAME 800x480 mounted=2 selected={agents[-1]} total=2 capped=0' not in app_log_path.read_text():
                    assert time.monotonic() < deadline, app_log_path.read_text()
                    time.sleep(.05)
                with (Path(store) / 'host.lock').open('rb') as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    assert xdo('windowfocus', window, 'key', 'Return').returncode == 0
                    deadline = time.monotonic() + 8
                    while 'SELECTION_REFUSED' not in app_log_path.read_text():
                        assert time.monotonic() < deadline, app_log_path.read_text()
                        time.sleep(.05)
                    assert selected_session() == agents[-1], 'refused selection changed the store'
                previous_count = app_log_path.read_text().count('AGENT_PICKER_FRAME ')
                assert xdo('windowfocus', window, 'key', 'Down').returncode == 0
                await_selection(app_log_path, agents[0], previous_count)
                assert xdo('windowfocus', window, 'key', 'Return').returncode == 0
                await_title(process, 'Threading terminal - OLDER AGENT READY [history cut]', app_log_path)
                assert selected_session() == agents[0], 'opening an older agent did not save selection'
                os.kill(older_pid, 0)
                assert xdo('windowfocus', window, 'key', 'q').returncode == 0
                await_title(process, 'Threading terminal - exited 0 [history cut]', app_log_path)
                assert xdo('windowfocus', window, 'key', 'ctrl+shift+p').returncode == 0
                await_title(process, 'Threading agents - ' + str(project), app_log_path)
                previous_count = app_log_path.read_text().count('AGENT_PICKER_FRAME ')
                assert xdo('windowfocus', window, 'key', 'Up').returncode == 0
                await_selection(app_log_path, agents[-1], previous_count)
                subprocess.run(['import', '-window', window, 'out/agent-picker.png'], check=True, timeout=5)
                assert xdo('windowfocus', window, 'key', 'Return').returncode == 0
                await_title(process, 'Threading terminal - AGENT READY [history cut]', app_log_path)
                assert selected_session() == agents[-1], 'reopening the live agent did not save selection'
                assert json.loads(marker.read_text()) == original
                assert xdo('windowfocus', window, 'key', 'p').returncode == 0
                await_title(process, 'Threading terminal - AGENT LIVE [history cut]', app_log_path)
                assert xdo('windowfocus', window, 'key', 'ctrl+shift+p').returncode == 0
                await_title(process, 'Threading agents - ' + str(project), app_log_path)
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                await_title(process, 'Threading experiment - ' + str(project), app_log_path)
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            except BaseException:
                app_log.flush()
                print(app_log_path.read_text(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        # Put the selected live agent beyond the 512-row recent window. A normal launch must
        # find its owning project and this identity without mounting the rest of the archive.
        with sqlite3.connect(str(Path(store) / 'threading.db')) as database:
            project_id, kind, active_at, payload = database.execute(
                'SELECT project_id, kind, last_active_at, data FROM session WHERE id = ?',
                (agents[-1],)).fetchone()
            next_position = database.execute(
                'SELECT MAX(position) + 1 FROM session WHERE project_id = ?',
                (project_id,)).fetchone()[0]
            for offset in range(513):
                filler_id = str(uuid.uuid4()).upper()
                filler = json.loads(payload)
                filler['id'] = filler_id
                filler['title'] = f'Dormant fixture {offset}'
                filler['hasLaunched'] = False
                database.execute(
                    'INSERT INTO session (id, project_id, position, kind, last_active_at, data) '
                    'VALUES (?, ?, ?, ?, ?, ?)',
                    (filler_id, project_id, next_position + offset, kind, active_at,
                     json.dumps(filler)))
            assert database.execute('SELECT COUNT(*) FROM session WHERE project_id = ?',
                                    (project_id,)).fetchone()[0] == 515
        filled_listing = listing()
        # Restoration is attach-only, even when the selected agent is outside the recent page.
        with (root / 'agent-reopened.log').open('w+') as reopened_log:
            process = subprocess.Popen([binary, '--app', store, endpoint, '/bin/sh'],
                                       stdout=reopened_log, stderr=reopened_log)
            try:
                window = await_title(process, 'Threading terminal - AGENT LIVE [history cut]',
                                     root / 'agent-reopened.log')
                assert json.loads(marker.read_text()) == original, 'startup spawned a replacement child'
                assert xdo('windowfocus', window, 'key', 'q').returncode == 0
                await_title(process, 'Threading terminal - exited 9 [history cut]',
                            root / 'agent-reopened.log')
                assert xdo('windowfocus', window, 'key', 'ctrl+shift+p').returncode == 0
                await_title(process, 'Threading agents - ' + str(project), root / 'agent-reopened.log')
                deadline = time.monotonic() + 5
                while not any(f'selected={agents[-1]} total=515 capped=1' in line
                              for line in (root / 'agent-reopened.log').read_text().splitlines()
                              if line.startswith('AGENT_PICKER_FRAME ')):
                    assert time.monotonic() < deadline, (root / 'agent-reopened.log').read_text()
                    time.sleep(.05)
                subprocess.run(['import', '-window', window, 'out/agent-deep-selection.png'],
                               check=True, timeout=5)
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                await_title(process, 'Threading experiment - ' + str(project), root / 'agent-reopened.log')
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            except BaseException:
                reopened_log.flush()
                print((root / 'agent-reopened.log').read_text(), file=sys.stderr)
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        assert listing() == filled_listing, 'graphical attach changed the saved agent records'
        # Once the child has exited, a normal relaunch still opens the selected agent's
        # project, but leaves the exited session in its picker for explicit resume.
        with (root / 'agent-exited-reopen.log').open('w+') as exited_log:
            process = subprocess.Popen([binary, '--app', store, endpoint, '/bin/sh'],
                                       stdout=exited_log, stderr=exited_log)
            try:
                window = await_title(process, 'Threading experiment - ' + str(project),
                                     root / 'agent-exited-reopen.log')
                assert selected_session() == agents[-1]
                assert json.loads(marker.read_text()) == original
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        with (root / 'agent-other-project.log').open('w+') as other_log:
            process = subprocess.Popen([binary, '--app-project', store, endpoint, '/bin/sh',
                                        str(other_project)], stdout=other_log, stderr=other_log)
            try:
                window = await_title(process, 'Threading experiment - ' + str(other_project),
                                     root / 'agent-other-project.log')
                assert selected_session() == agents[-1], 'project targeting changed agent selection'
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        # A shell takes selection away from the prior agent, so the next targeted launch opens
        # the project instead of restoring a conversation that is no longer selected.
        with (root / 'agent-to-shell.log').open('w+') as shell_log:
            process = subprocess.Popen([binary, '--app', store, endpoint, '/bin/sh'],
                                       stdout=shell_log, stderr=shell_log)
            try:
                window = await_title(process, 'Threading experiment - ' + str(project),
                                     root / 'agent-to-shell.log')
                assert xdo('windowfocus', window, 'key', 'Return').returncode == 0
                await_title(process, 'Threading terminal - running', root / 'agent-to-shell.log')
                deadline = time.monotonic() + 8
                while selected_session() is not None:
                    assert time.monotonic() < deadline, 'shell did not clear selected agent'
                    time.sleep(.05)
                assert xdo('windowfocus', window, 'key', 'ctrl+shift+p').returncode == 0
                await_title(process, 'Threading experiment - ' + str(project),
                            root / 'agent-to-shell.log')
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        with (root / 'agent-cleared-reopen.log').open('w+') as cleared_log:
            process = subprocess.Popen([binary, '--app-project', store, endpoint, '/bin/sh', str(project)],
                                       stdout=cleared_log, stderr=cleared_log)
            try:
                window = await_title(process, 'Threading experiment - ' + str(project),
                                     root / 'agent-cleared-reopen.log')
                assert xdo('windowfocus', window, 'key', 'Escape').returncode == 0
                assert process.wait(timeout=5) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=3)
        missing = subprocess.run([binary, '--attach-agent', store, endpoint, str(uuid.uuid4())],
                                 capture_output=True, timeout=8)
        assert missing.returncode != 0 and b'session is not in this store' in missing.stderr, missing
        print('PASS graphical agent picker: cross-project relaunch, bounded attach-only restore, shell clearing, same child and exit 9', flush=True)
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if cli.poll() is None:
            cli.kill()
        cli.wait(timeout=3)
