"""Enter a multiline opening brief in the installed right-pane composer and launch once."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
from x11_cursor import NativeCursor
from runtime_pixel_contract import assert_composer_focus_chrome, opening_prompt_frame

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
    composer = eventually(lambda: panel(app) if child_by_id(panel(app), 'linux.composer.editor') else None, 'standing composer', process)
    editor = eventually(lambda: child_by_id(composer, 'linux.composer.editor'), 'standing editor', process)
    bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    xdo('mousemove', '--window', window, str(bounds.x + 15), str(bounds.y + 15), 'click', '1')
    eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED), 'editor focus', process)
    return composer



daemon_process = None
process = None
cursor = None
window_log = output / 'window.log'
try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'PTY daemon socket', daemon_process)
    home = root / 'home'
    home.mkdir()
    cursor = NativeCursor()
    cursor.park()
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
        greeting = child_by_id(composer, 'linux.composer.greeting').get_name()
        assert greeting
        xdo('key', 'Escape')
        eventually(lambda: child_by_id(panel(app), 'linux.composer.editor'),
                   'Escape preserves standing composer', process)
        composer = open_composer(app, process)
        editor = eventually(lambda: child_by_id(composer, 'linux.composer.editor'),
                            'AT-SPI composer editor', process)
        action = eventually(lambda: child_by_id(composer, 'linux.placeholder.action'),
                            'AT-SPI composer action', process)
        editor_bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        prompt_frame = opening_prompt_frame(editor_bounds)
        assert prompt_frame['width'] == 720 and prompt_frame['height'] == 116, prompt_frame
        assert prompt_frame['x'] == 320, 'opening form must center its capped column in the pane'
        subprocess.run(['import', '-window', window, str(output / 'opening-prompt-focused.png')],
                       check=True, timeout=5)
        action_bounds = action.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert action.get_name() == 'Start Session'
        assert action_bounds.y >= editor_bounds.y + editor_bounds.height, (
            'composer action should sit below its prompt', editor_bounds, action_bounds)
        assert not action.get_state_set().contains(Atspi.StateType.ENABLED)
        project_chip = eventually(lambda: child_by_id(composer, 'linux.composer.project'),
                                  'AT-SPI project chip', process)
        provider_chip = eventually(lambda: child_by_id(composer, 'linux.composer.provider'),
                                   'AT-SPI provider chip', process)

        permission_chip = eventually(lambda: child_by_id(composer, 'linux.composer.permissions'),
                                     'permission footer', process)
        assert permission_chip.get_name() == 'Permissions: Manual'
        permission_bounds = permission_chip.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert permission_bounds.y == editor_bounds.y + editor_bounds.height + 10
        model_chip = eventually(lambda: child_by_id(composer, 'linux.composer.model-effort'),
                                'model/effort footer', process)
        model_bounds = model_chip.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert model_bounds.x == editor_bounds.x and model_bounds.y == permission_bounds.y
        assert model_bounds.height == permission_bounds.height == 26
        assert permission_bounds.x == model_bounds.x + model_bounds.width + 6
        assert not model_chip.get_state_set().contains(Atspi.StateType.ENABLED), 'missing Codex catalogue must not invent models'

        def focused_only(expected):
            controls = [project_chip, provider_chip, editor, model_chip, permission_chip, action]
            return [control for control in controls
                    if control.get_state_set().contains(Atspi.StateType.FOCUSED)] == [expected]

        xdo('key', 'shift+Tab')
        eventually(lambda: focused_only(provider_chip), 'reverse Tab reaches identity choice', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-identity-focused.png')],
                       check=True, timeout=5)
        assert_composer_focus_chrome(output / 'opening-prompt-focused.png',
                                    output / 'composer-identity-focused.png', prompt_frame)
        xdo('key', 'space')
        eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                   'keyboard identity choice opens', process)
        def highlighted_choice(name):
            choices = child_by_id(composer, 'linux.composer.choices')
            return choices and any(choices.get_child_at_index(index).get_name() == name
                and choices.get_child_at_index(index).get_state_set().contains(Atspi.StateType.SELECTED)
                for index in range(choices.get_child_count()))
        for key, name in [('End', 'Claude Code'), ('Home', 'Codex'),
                          ('Next', 'Claude Code'), ('Prior', 'Codex')]:
            xdo('key', key)
            eventually(lambda name=name: highlighted_choice(name), 'choice boundary/page keys', process)
        xdo('key', 'Escape')
        eventually(lambda: focused_only(provider_chip), 'choice dismissal restores its focus', process)
        xdo('key', 'Tab')
        eventually(lambda: focused_only(editor), 'Tab returns to the editor', process)
        xdo('key', 'Tab')
        eventually(lambda: focused_only(permission_chip), 'Tab reaches permission footer', process)
        xdo('key', 'Tab')
        eventually(lambda: focused_only(project_chip), 'Tab skips disabled submit', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-project-focused.png')],
                       check=True, timeout=5)
        xdo('key', 'space')
        eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                   'keyboard project choice opens', process)
        xdo('key', 'Escape', 'shift+Tab', 'shift+Tab')
        eventually(lambda: focused_only(editor), 'reverse Tab skips disabled submit', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == '', (
            'choice activation must not become draft text')
        xdo('type', '--clearmodifiers', '--delay', '20', 'Draft stays')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays',
                   'draft before choice change', process)
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'composer action enabled for draft', process)
        draft_identity = editor.get_accessible_id()
        xdo('key', 'Escape')
        eventually(lambda: not editor.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'Escape returns focus to sidebar', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        assert child_by_id(composer, 'linux.composer.greeting').get_name() == greeting
        assert child_by_id(panel(app), 'linux.composer.editor').get_accessible_id() == draft_identity
        composer = open_composer(app, process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        assert child_by_id(composer, 'linux.composer.greeting').get_name() == greeting
        for key, target in [('Tab', permission_chip), ('Tab', action), ('Tab', project_chip), ('Tab', provider_chip),
                            ('shift+Tab', project_chip), ('shift+Tab', action),
                            ('shift+Tab', permission_chip), ('shift+Tab', editor)]:
            xdo('key', key)
            eventually(lambda target=target: focused_only(target), 'five-control Tab loop', process)
        text = editor.get_text_iface()
        xdo('key', 'Home')
        eventually(lambda: text.get_caret_offset() == 0, 'native Home reaches line start', process)
        xdo('key', 'End')
        eventually(lambda: text.get_caret_offset() == len('Draft stays'),
                   'native End reaches line end', process)
        assert Atspi.Text.get_text(text, 0, -1) == 'Draft stays', 'navigation changed the draft'
        xdo('windowsize', '--sync', window, '560', '180')

        def controls_fit():
            bounds = [control.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                      for control in [project_chip, provider_chip, editor, model_chip, permission_chip, action]]
            return all(value.x >= 240 and value.y >= 0 and value.width > 0 and value.height > 0
                       and value.x + value.width <= 560 and value.y + value.height <= 180
                       for value in bounds)

        eventually(controls_fit, 'all composer controls fit the minimum window', process)
        assert child_by_id(composer, 'linux.composer.greeting') is None, 'clipped hero exposed at minimum height'
        xdo('key', 'shift+Tab')
        eventually(lambda: focused_only(provider_chip), 'identity focus in the minimum window', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-minimum-window.png')],
                       check=True, timeout=5)
        xdo('key', 'space')
        eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                   'choice opens in the minimum window', process)
        subprocess.run(['import', '-window', window, str(output / 'composer-minimum-choice.png')],
                       check=True, timeout=5)
        xdo('key', 'Escape', 'Tab')
        xdo('windowsize', '--sync', window, '1120', '480')
        eventually(lambda: editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW).width > 600,
                   'composer restores its full viewport', process)
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
        eventually(lambda: project_chip.get_name() == 'Project: ComposerOther',
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
        eventually(lambda: provider_chip.get_name() == 'Identity: Claude Code',
                   'composer provider changed', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        assert child_by_id(composer, 'linux.composer.greeting').get_name() == greeting
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
        eventually(lambda: provider_chip.get_name() == 'Identity: Codex',
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
        eventually(lambda: provider_chip.get_name() == 'Identity: Claude Code',
                   'keyboard provider choice', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Draft stays'
        assert child_by_id(composer, 'linux.composer.greeting').get_name() == greeting
        xdo('key', 'Tab')
        eventually(lambda: not editor.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'composer action focus', process)
        subprocess.run(['import', '-window', window,
                        str(output / 'composer-empty-placeholder.png')], check=True, timeout=5)
        arrow = cursor.settled(output / 'cursor-control.png')
        editor_bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window,
            str(editor_bounds.x + editor_bounds.width // 2),
            str(editor_bounds.y + editor_bounds.height // 2))
        xdo('click', '1')
        eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED),
                   'composer editor refocus', process)
        eventually(lambda: cursor.read() != arrow, 'native composer I-beam cursor', process)
        cursor.read(output / 'cursor-editor.png')
        xdo('mousemove', '--window', window,
            str(provider_bounds.x + provider_bounds.width // 2),
            str(provider_bounds.y + provider_bounds.height // 2))
        eventually(lambda: cursor.read() == arrow, 'composer control restores native arrow', process)
        xdo('mousemove', '--window', window,
            str(editor_bounds.x + editor_bounds.width // 2),
            str(editor_bounds.y + editor_bounds.height // 2))
        eventually(lambda: cursor.read() != arrow, 'native editor cursor restored', process)
        editor_text = editor.get_text_iface()
        editable = editor.get_editable_text_iface()
        long_prompt = '\n'.join(f'Brief line {index:02d} — scroll 🙂' for index in range(40))
        editable.set_text_contents(long_prompt)
        eventually(lambda: Atspi.Text.get_text(editor_text, 0, -1) == long_prompt,
                   'long composer brief', process)
        eventually(lambda: opening_prompt_frame(editor.get_component_iface().get_extents(
            Atspi.CoordType.WINDOW))['height'] == 180, 'opening prompt grows to its 180pt ceiling', process)
        assert editor_text.set_caret_offset(len(long_prompt))
        eventually(lambda: editor_text.get_caret_offset() == len(long_prompt),
                   'caret at end of long brief', process)

        def editor_pixels(name):
            capture = output / name
            subprocess.run(['import', '-window', window, str(capture)], check=True, timeout=5)
            bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            return subprocess.check_output(['convert', str(capture), '-crop',
                f'{bounds.width}x{bounds.height}+{bounds.x}+{bounds.y}', '+repage',
                '-depth', '8', 'rgba:-'], timeout=5)

        xdo('mousemove', '--window', window,
            str(editor_bounds.x + editor_bounds.width // 2),
            str(editor_bounds.y + editor_bounds.height // 2))
        tail_pixels = editor_pixels('composer-scroll-tail.png')
        xdo('click', '--repeat', '12', '--delay', '20', '4')
        eventually(lambda: editor_pixels('composer-scroll-up.png') != tail_pixels,
                   'wheel scrolls long brief without moving caret', process)
        assert Atspi.Text.get_text(editor_text, 0, -1) == long_prompt
        assert editor_text.get_caret_offset() == len(long_prompt)
        assert editor.get_state_set().contains(Atspi.StateType.FOCUSED)
        xdo('click', '--repeat', '12', '--delay', '20', '5')
        eventually(lambda: editor_pixels('composer-scroll-down.png') == tail_pixels,
                   'wheel returns to the same tail pixels', process)
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
            editor_bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            sample_x = editor_bounds.x + 10
            sample_y = editor_bounds.y + 26
            pixels = subprocess.check_output(['convert', str(screenshot), '-crop',
                                              f'210x17+{sample_x}+{sample_y}', '+repage', '-colorspace',
                                              'Gray', '-depth', '8', 'gray:-'], timeout=5)
            return sum(pixel < 120 for pixel in pixels) > 25
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
        action_bounds = action.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window,
            str(action_bounds.x + action_bounds.width // 2),
            str(action_bounds.y + action_bounds.height // 2))
        xdo('click', '1')
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
        print('PASS right-pane composer, Tab focus loop, wheel scrolling, project/provider choices, keyboard and AT-SPI '
              'multiline Unicode edits, exact project and one agent launch', flush=True)
finally:
    if cursor is not None:
        cursor.close()
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
