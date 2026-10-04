"""Enter a multiline opening brief in the installed right-pane composer and launch once."""
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
root = Path(fixture) / 'composer-fixture'
root.mkdir(exist_ok=True)
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
project = root / 'ComposerProject'
project.mkdir()
subprocess.run([host, '--add-project', str(store), str(project)],
               check=True, capture_output=True, timeout=8)
other_project = root / 'ComposerOther'
other_project.mkdir()
subprocess.run([host, '--add-project', str(store), str(other_project)],
               check=True, capture_output=True, timeout=8)
child = root / 'record-agent'
child.write_text('''#!/usr/bin/python3
import json, os, sys, termios, tty
from pathlib import Path
tty.setraw(0)
Path('composer-agent.json').write_text(json.dumps({
    'pid': os.getpid(), 'cwd': os.getcwd(), 'argv': sys.argv[1:]
}))
os.write(1, b'\\x1b]0;COMPOSER READY\\x07')
assert os.read(0, 1) == b'q', 'editor input leaked into PTY'
Path('composer-agent-complete').write_text('ok')
''')
child.chmod(0o700)
state = root / 'daemon'
state.mkdir()
socket = Path(endpoint)
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


def child_by_id(parent, identity):
    return next((parent.get_child_at_index(index)
                 for index in range(parent.get_child_count())
                 if parent.get_child_at_index(index).get_accessible_id() == identity), None)


def menu(app, name):
    return next(frame(app).get_child_at_index(index)
                for index in range(frame(app).get_child_count())
                if frame(app).get_child_at_index(index).get_role_name() == 'list'
                and frame(app).get_child_at_index(index).get_name() == name)


def open_composer(app, process):
    idle = eventually(lambda: panel(app) if panel(app).get_child_at_index(0).get_name()
                      == 'No Session Selected' else None, 'idle pane', process)
    assert idle.get_child_at_index(2).get_action_iface().do_action(0)
    create = eventually(lambda: menu(app, 'New in Project'), 'creation menu', process)
    assert create.get_child_at_index(0).get_action_iface().do_action(1)
    providers = eventually(lambda: menu(app, 'New Chat providers'), 'provider menu', process)
    assert providers.get_child_at_index(0).get_action_iface().do_action(1)
    return eventually(lambda: panel(app) if panel(app).get_child_at_index(0).get_name()
                      == 'Start a Codex session' else None, 'composer pane', process)


daemon_process = None
process = None
window_log = output / 'window.log'
try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'PTY daemon socket', daemon_process)
    home = root / 'home'
    home.mkdir()
    with window_log.open('w') as log:
        process = subprocess.Popen([binary, '--app-agents-project', str(store), str(socket),
                                    '/bin/sh', str(child), str(child), str(project)],
                                   env=dict(os.environ, HOME=str(home)), stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'AT-SPI app', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                        str(process.pid), '--name', '^Threading experiment - '),
                            'native window', process).splitlines()[0]
        xdo('windowfocus', '--sync', window)
        composer = open_composer(app, process)
        xdo('key', 'Escape')
        eventually(lambda: panel(app).get_child_at_index(0).get_name() == 'No Session Selected',
                   'Escape cancels composer', process)
        composer = open_composer(app, process)
        editor = eventually(lambda: child_by_id(composer, 'linux.composer.editor'),
                            'AT-SPI composer editor', process)
        xdo('type', '--clearmodifiers', '--delay', '20', 'Draft stays')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays',
                   'draft before choice change', process)
        project_chip = eventually(lambda: child_by_id(composer, 'linux.composer.project'),
                                  'AT-SPI project chip', process)
        assert project_chip.get_role_name() == 'combo box'
        assert project_chip.get_action_iface().do_action(0)
        choices = eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                             'AT-SPI project choices', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-project-menu.png')],
                       check=True, timeout=5)
        other_row = eventually(lambda: next((choices.get_child_at_index(index)
            for index in range(choices.get_child_count())
            if choices.get_child_at_index(index).get_name() == other_project.name), None),
            'other project choice', process)
        assert other_row.get_action_iface().do_action(0)
        eventually(lambda: composer.get_child_at_index(1).get_name().startswith('In ComposerOther'),
                   'composer project changed', process)
        provider_chip = eventually(lambda: child_by_id(composer, 'linux.composer.provider'),
                                   'AT-SPI provider chip', process)
        assert provider_chip.get_action_iface().do_action(0)
        choices = eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                             'AT-SPI provider choices', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-provider-menu.png')],
                       check=True, timeout=5)
        claude_row = eventually(lambda: next((choices.get_child_at_index(index)
            for index in range(choices.get_child_count())
            if choices.get_child_at_index(index).get_name() == 'Claude Code'), None),
            'Claude provider choice', process)
        assert claude_row.get_action_iface().do_action(0)
        eventually(lambda: composer.get_child_at_index(0).get_name() == 'Start a Claude Code session',
                   'composer provider changed', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        provider_bounds = provider_chip.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window,
            str(provider_bounds.x + provider_bounds.width // 2),
            str(provider_bounds.y + provider_bounds.height // 2))
        xdo('click', '1')
        choices = eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                             'pointer-opened provider choices', process)
        codex_row = next(choices.get_child_at_index(index)
                         for index in range(choices.get_child_count())
                         if choices.get_child_at_index(index).get_name() == 'Codex')
        codex_bounds = codex_row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window,
            str(codex_bounds.x + codex_bounds.width // 2),
            str(codex_bounds.y + codex_bounds.height // 2))
        xdo('click', '1')
        eventually(lambda: composer.get_child_at_index(0).get_name() == 'Start a Codex session',
                   'pointer provider choice', process)
        xdo('mousemove', '--window', window,
            str(provider_bounds.x + provider_bounds.width // 2),
            str(provider_bounds.y + provider_bounds.height // 2))
        xdo('click', '1')
        eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                   'keyboard provider choices', process)
        xdo('key', 'Down', 'Up')
        xdo('type', '--clearmodifiers', 'C')
        xdo('key', 'Return')
        eventually(lambda: composer.get_child_at_index(0).get_name() == 'Start a Claude Code session',
                   'keyboard provider choice', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        xdo('key', 'Tab')
        eventually(lambda: not editor.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'composer action focus', process)
        subprocess.run(['import', '-window', window,
                        str(output / 'composer-empty-placeholder.png')], check=True, timeout=5)
        xdo('mousemove', '--window', window, '700', '400')
        xdo('click', '1')
        eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'composer editor refocus', process)
        xdo('key', 'ctrl+a')
        opening = 'Please inspect $(literal) 🦉'
        subprocess.run(['xclip', '-selection', 'clipboard'], input=opening.encode(),
                       check=True, timeout=5)
        xdo('key', 'ctrl+v')
        xdo('key', 'Return')
        xdo('type', '--clearmodifiers', '--delay', '20', 'Second line')
        prompt = opening + '\nSecond line'
        editor_text = editor.get_text_iface()
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1) == prompt,
                   'AT-SPI composer value', process)
        assert editor_text.get_caret_offset() == len(prompt)
        assert editor.get_state_set().contains(Atspi.StateType.EDITABLE)
        assert editor.get_state_set().contains(Atspi.StateType.FOCUSED)
        screenshot = output / 'composer.png'
        def rendered_text():
            subprocess.run(['import', '-window', window, str(screenshot)], check=True, timeout=5)
            pixels = subprocess.check_output(['convert', str(screenshot), '-crop',
                                              '420x35+390+390', '+repage', '-colorspace',
                                              'Gray', '-depth', '8', 'gray:-'], timeout=5)
            return sum(pixel < 120 for pixel in pixels) > 100
        eventually(rendered_text, 'second line painted in the real window', process)
        assert subprocess.check_output(['identify', '-format', '%wx%h', str(screenshot)],
                                       text=True, timeout=5) == '1120x480'
        xdo('key', 'ctrl+a')
        eventually(lambda: editor_text.get_n_selections() == 1,
                   'AT-SPI editor selection', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-selection.png')],
                       check=True, timeout=5)
        xdo('key', 'Right')
        eventually(lambda: editor_text.get_n_selections() == 0,
                   'AT-SPI editor selection cleared', process)
        editable = editor.get_editable_text_iface()
        editable.set_text_contents('Delete me🦉\nSecond line')
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1)
                   == 'Delete me🦉\nSecond line', 'AT-SPI set contents', process)
        editable.delete_text(0, len('Delete me'))
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1)
                   == '🦉\nSecond line', 'AT-SPI delete range', process)
        editable.delete_text(1, 2)
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1)
                   == '🦉Second line', 'AT-SPI scalar offset after emoji', process)
        editable.insert_text(1, '\n', 1)
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1)
                   == '🦉\nSecond line', 'AT-SPI insert after emoji', process)
        editable.insert_text(0, 'Please inspect ', len('Please inspect '))
        prompt = 'Please inspect 🦉\nSecond line'
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1) == prompt,
                   'AT-SPI insert text', process)
        prefix = 'Please inspect '
        editable.copy_text(0, len(prefix))
        eventually(lambda: subprocess.check_output(['xclip', '-selection', 'clipboard', '-o'],
                   timeout=3).decode() == prefix, 'AT-SPI copy text', process)
        editable.cut_text(0, len(prefix))
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1)
                   == '🦉\nSecond line', 'AT-SPI cut text', process)
        editable.paste_text(0)
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1) == prompt,
                   'AT-SPI paste text', process)
        assert editor_text.add_selection(len(prefix), len(prefix) + 1)
        eventually(lambda: editor_text.get_n_selections() == 1,
                   'AT-SPI select emoji', process)
        assert editor_text.remove_selection(0)
        eventually(lambda: editor_text.get_n_selections() == 0,
                   'AT-SPI clear selection', process)
        subprocess.run(['import', '-window', window,
                        str(output / 'composer-accessibility-edited.png')],
                       check=True, timeout=5)
        xdo('key', 'super+Return')
        marker = other_project / 'composer-agent.json'
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'agent with opening brief', process)
        assert report['cwd'] == str(other_project), report
        assert report['argv'][-2:] == ['--', prompt], report
        with sqlite3.connect(str(store / 'threading.db')) as database:
            count = database.execute('SELECT COUNT(*) FROM session JOIN project '
                                     'ON session.project_id = project.id '
                                     'WHERE project.folder_path = ?', (str(other_project),)).fetchone()[0]
        assert count == 1, count
        xdo('key', 'q')
        eventually(lambda: (other_project / 'composer-agent-complete').exists(),
                   'agent received only its own terminal input', process)
        print('PASS right-pane composer, project/provider choices, keyboard and AT-SPI '
              'multiline Unicode edits, exact project and one agent launch', flush=True)
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
