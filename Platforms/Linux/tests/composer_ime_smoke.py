"""Drive a real IBus Pinyin composition through the Linux session composer."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'composer-ime-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
project = root / 'PinyinProject'
project.mkdir()
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=8)
agent = root / 'record-agent'
agent.write_text('''#!/usr/bin/python3
import json, os, sys, tty
from pathlib import Path
tty.setraw(0)
Path('composer-ime-agent.json').write_text(json.dumps({
    'pid': os.getpid(), 'cwd': os.getcwd(), 'argv': sys.argv[1:]
}))
assert os.read(0, 1) == b'q', 'composer input leaked into the agent PTY'
Path('composer-ime-agent-complete').write_text('ok')
''')
agent.chmod(0o700)
state = root / 'daemon'
state.mkdir()
socket = Path(endpoint)
window_log = output / 'window.log'
marker = project / 'composer-ime-agent.json'
Atspi.init()


def eventually(read, label, process, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: {window_log.read_text()}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {window_log.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def frame(app):
    return app.get_child_at_index(0)


def panel(app):
    return next(frame(app).get_child_at_index(index)
                for index in range(frame(app).get_child_count())
                if frame(app).get_child_at_index(index).get_role_name() == 'panel')


def menu(app, name):
    return next(frame(app).get_child_at_index(index)
                for index in range(frame(app).get_child_count())
                if frame(app).get_child_at_index(index).get_role_name() == 'list'
                and frame(app).get_child_at_index(index).get_name() == name)


def editor_in(app):
    composer = panel(app)
    return next((composer.get_child_at_index(index)
                 for index in range(composer.get_child_count())
                 if composer.get_child_at_index(index).get_accessible_id()
                 == 'linux.composer.editor'), None)


def session_count():
    with sqlite3.connect(store / 'threading.db') as database:
        return database.execute('SELECT COUNT(*) FROM session JOIN project '
                                'ON session.project_id = project.id '
                                'WHERE project.folder_path = ?', (str(project),)).fetchone()[0]


def ibus_engine():
    result = subprocess.run(['ibus', 'engine'], capture_output=True, text=True, timeout=3)
    return result.stdout.strip() if result.returncode == 0 else ''


daemon_process = None
process = None
try:
    assert os.environ.get('XMODIFIERS') == '@im=ibus'
    assert os.environ.get('SDL_IM_MODULE') == 'ibus'
    deadline = time.monotonic() + 8
    while ibus_engine() != 'libpinyin':
        assert time.monotonic() < deadline, 'IBus Pinyin engine was not selected'
        time.sleep(.1)
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'PTY daemon socket', daemon_process)
    with window_log.open('w') as log:
        process = subprocess.Popen([binary, '--app-codex-project', str(store), str(socket),
                                    '/bin/sh', str(agent), str(project)],
                                   env=os.environ.copy(), stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI application', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)
        idle = eventually(lambda: panel(app) if panel(app).get_child_at_index(0).get_name()
                          == 'No Session Selected' else None, 'idle pane', process)
        assert idle.get_child_at_index(2).get_action_iface().do_action(0)
        create = eventually(lambda: menu(app, 'New in Project'), 'creation menu', process)
        assert create.get_child_at_index(0).get_action_iface().do_action(1)
        providers = eventually(lambda: menu(app, 'New Chat providers'), 'provider menu', process)
        assert providers.get_child_at_index(0).get_action_iface().do_action(1)
        eventually(lambda: panel(app) if panel(app).get_child_at_index(0).get_name()
                   == 'Start a Codex session' else None, 'composer pane', process)
        editor = eventually(lambda: editor_in(app), 'AT-SPI editor', process)
        assert editor.get_state_set().contains(Atspi.StateType.FOCUSED)
        text = editor.get_text_iface()
        time.sleep(1)

        def exact_text(expected):
            observed = Atspi.Text.get_text(text, 0, -1)
            assert observed == expected, f'expected {expected!r}, observed {observed!r}'
            return observed

        xdo('type', '--delay', '180', 'ni')
        eventually(lambda: exact_text('你'), 'IBus ni candidate in the editor', process)
        assert not marker.exists() and session_count() == 0, 'preedit launched an agent'
        subprocess.run(['import', '-window', window, str(output / 'composer-preedit.png')],
                       check=True, timeout=5)

        xdo('key', 'Escape')
        eventually(lambda: Atspi.Text.get_text(text, 0, -1) == '',
                   'Escape removes marked preedit', process)
        assert panel(app).get_child_at_index(0).get_name() == 'Start a Codex session'
        assert editor.get_state_set().contains(Atspi.StateType.FOCUSED)
        assert not marker.exists() and session_count() == 0, 'Escape launched an agent'

        xdo('type', '--delay', '180', 'nihao')
        eventually(lambda: exact_text('你好'), 'IBus nihao candidate in the editor', process)
        assert not marker.exists() and session_count() == 0, 'second preedit launched an agent'
        xdo('key', 'space')
        eventually(lambda: Atspi.Text.get_text(text, 0, -1) == '你好',
                   'committed Chinese candidate', process)
        assert text.get_caret_offset() == 2
        assert not marker.exists() and session_count() == 0, 'IME commit launched an agent'
        subprocess.run(['import', '-window', window, str(output / 'composer-committed.png')],
                       check=True, timeout=5)

        xdo('key', 'Return')
        eventually(lambda: Atspi.Text.get_text(text, 0, -1) == '你好\n',
                   'bare Return inserts a line without launching', process)
        assert not marker.exists() and session_count() == 0, 'Return launched an agent'
        xdo('key', 'super+Return')
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'explicit composer launch', process)
        assert report['cwd'] == str(project), report
        assert report['argv'][-2:] == ['--', '你好\n'], report
        assert session_count() == 1
        subprocess.run(['ibus', 'engine', 'xkb:us::eng'], check=True, capture_output=True,
                       timeout=5)
        eventually(lambda: ibus_engine() == 'xkb:us::eng', 'plain keyboard engine', process)
        xdo('key', 'q')
        eventually(lambda: (project / 'composer-ime-agent-complete').exists(),
                   'agent received only post-launch terminal input', process)
        print('PASS IBus composer: preedit, Escape, 你好 commit, no early launch', flush=True)
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if daemon_process is not None and daemon_process.poll() is None:
        daemon_process.terminate()
        try:
            daemon_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon_process.kill()
            daemon_process.wait(timeout=5)
