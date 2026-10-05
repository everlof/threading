"""Choose a named account in the shared composer chip and launch with its exact home."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'composer-account-fixture'
root.mkdir(exist_ok=True)
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
home = root / 'home'
home.mkdir()
for index in range(8):
    account = home / f'.codex-{index:02d}'
    account.mkdir()
    (account / 'auth.json').write_text('{}')
project = root / 'AccountComposerProject'
project.mkdir()
store = root / 'store'
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=8)
agent = root / 'record-agent'
agent.write_text('''#!/usr/bin/python3
import json, os, sys, termios, tty
from pathlib import Path
tty.setraw(0)
Path('composer-account.json').write_text(json.dumps({
    'cwd': os.getcwd(), 'codex_home': os.environ.get('CODEX_HOME'),
    'argv': sys.argv[1:]}))
os.read(0, 1)
''')
agent.chmod(0o700)
state = root / 'daemon'
state.mkdir()
socket = Path(endpoint)
Atspi.init()
window_log = output / 'window.log'
daemon_process = None
process = None


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process is not None:
            assert process.poll() is None, f'{label}: {window_log.read_text()}'
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {window_log.read_text()}')


def xdo(*arguments):
    return subprocess.run(['xdotool', *arguments], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def frame():
    return app.get_child_at_index(0)


def panel():
    return next(frame().get_child_at_index(index)
                for index in range(frame().get_child_count())
                if frame().get_child_at_index(index).get_role_name() == 'panel')


def child(parent, identity):
    return next((parent.get_child_at_index(index)
                 for index in range(parent.get_child_count())
                 if parent.get_child_at_index(index).get_accessible_id() == identity), None)


def menu(name):
    return next(frame().get_child_at_index(index)
                for index in range(frame().get_child_count())
                if frame().get_child_at_index(index).get_role_name() == 'list'
                and frame().get_child_at_index(index).get_name() == name)


try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'PTY daemon socket')
    environment = dict(os.environ, HOME=str(home), CODEX_HOME=str(home / '.codex'))
    environment.pop('THREADING_LINUX_CODEX_ACCOUNT', None)
    with window_log.open('w') as log:
        process = subprocess.Popen([binary, '--app-agents-project', str(store), str(socket),
                                    '/bin/sh', str(agent), str(agent), str(project)],
                                   env=environment, stdout=log, stderr=log)
        app = eventually(application, 'AT-SPI app')
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window').splitlines()[0]
        xdo('windowfocus', '--sync', window)
        idle = eventually(lambda: panel() if panel().get_child_at_index(0).get_name()
                          == 'No Session Selected' else None, 'idle pane')
        assert idle.get_child_at_index(2).get_action_iface().do_action(0)
        assert eventually(lambda: menu('New in Project'), 'project creation menu')
        assert menu('New in Project').get_child_at_index(0).get_action_iface().do_action(1)
        providers = eventually(lambda: menu('New Chat providers'), 'provider creation menu')
        assert providers.get_child_at_index(0).get_action_iface().do_action(1)
        composer = eventually(lambda: panel() if panel().get_child_at_index(0).get_name()
                              == 'Start a Codex session' else None, 'composer')
        chip = eventually(lambda: child(composer, 'linux.composer.provider'), 'identity chip')
        assert chip.get_action_iface().do_action(0)
        choices = eventually(lambda: child(composer, 'linux.composer.choices'), 'identity choices')
        visible = choices.get_child_count()
        assert 1 <= visible <= 6, visible
        xdo('key', '--repeat', '6', '--delay', '65', 'Down')
        def later_account():
            listed = child(composer, 'linux.composer.choices')
            if listed is None or listed.get_child_count() != visible:
                return None
            return next((listed.get_child_at_index(index)
                         for index in range(listed.get_child_count())
                         if listed.get_child_at_index(index).get_name() == 'Codex · codex-05'), None)
        named = eventually(later_account, 'named account after keyboard scroll')
        assert named.get_action_iface().do_action(0)
        eventually(lambda: chip.get_name() if 'codex-05' in chip.get_name() else None,
                   'selected named account chip')
        subprocess.run(['import', '-window', window, str(output / 'composer-account.png')],
                       check=True, timeout=5)
        editor = eventually(lambda: child(composer, 'linux.composer.editor'), 'composer editor')
        xdo('type', '--clearmodifiers', '--delay', '20', 'Named account brief')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1)
                   == 'Named account brief', 'brief preserved after account choice')
        action = eventually(lambda: child(composer, 'linux.placeholder.action'), 'start action')
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'start action enabled')
        assert action.get_action_iface().do_action(0)
        marker = project / 'composer-account.json'
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'named account agent launch')
        assert report['cwd'] == str(project), report
        assert report['codex_home'] == str(home / '.codex-05'), report
        xdo('key', 'q')
    print('PASS shared composer identity chip: bounded rows, keyboard scroll, named account, exact launch home',
          flush=True)
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
