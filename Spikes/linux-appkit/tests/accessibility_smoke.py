"""Query the native window through AT-SPI, then use a row action to open its PTY."""
from pathlib import Path
import re
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, store, socket, folder = sys.argv[1:]
root = Path(folder)
log_path = root / 'accessibility-window.log'
Atspi.init()


def eventually(read, label, timeout=12):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; window log: {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux':
            return child
    return None


def content(app):
    frame = app.get_child_at_index(0)
    assert frame.get_role_name() == 'frame'
    return frame.get_child_at_index(0)


def window_title():
    result = subprocess.run(['xdotool', 'search', '--name', '^Threading experiment - '],
                            capture_output=True, text=True, timeout=5)
    if result.returncode != 0:
        return ''
    window = result.stdout.splitlines()[0]
    title = subprocess.run(['xdotool', 'getwindowname', window], capture_output=True,
                           text=True, timeout=5)
    return title.stdout.strip() if title.returncode == 0 else ''


with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app', store, socket, '/usr/bin/python3',
                                str(Path(__file__).with_name('accessibility_child.py'))],
                               stdout=log, stderr=log)
    try:
        app = eventually(application, 'AT-SPI application registration')
        listed = eventually(lambda: content(app) if content(app).get_child_count() == 8 else None,
                            'bounded project list')
        assert listed.get_role_name() == 'list'
        assert listed.get_description() == 'Showing 1 through 8 of 15 items'
        assert listed.get_child_count() == 8
        first = listed.get_child_at_index(0)
        assert first.get_role_name() == 'list item'
        assert re.fullmatch(r'[0-9A-Fa-f-]{36}', first.get_accessible_id())
        assert first.get_state_set().contains(Atspi.StateType.SELECTED)
        window = subprocess.run(['xdotool', 'search', '--name', '^Threading experiment - '],
                                capture_output=True, text=True, timeout=5)
        assert window.returncode == 0
        window_id = window.stdout.splitlines()[0]
        subprocess.run(['xdotool', 'windowfocus', '--sync', window_id], check=True, timeout=5)
        for step in range(1, 11):
            subprocess.run(['xdotool', 'key', 'Down'], check=True, timeout=5)
            project_name = f'Project{step + 1:02d}' + ('-界' if step + 1 == 6 else '')
            eventually(lambda: window_title().endswith('/' + project_name),
                       f'keyboard selected {project_name}')
        listed = eventually(lambda: content(app)
                            if content(app).get_description() == 'Showing 4 through 11 of 15 items'
                            else None, 'scrolled accessible viewport')
        assert listed.get_child_count() == 8
        assert listed.get_child_at_index(7).get_state_set().contains(Atspi.StateType.SELECTED)
        target_index = next(index for index in range(listed.get_child_count())
                            if '界' in listed.get_child_at_index(index).get_name())
        target = listed.get_child_at_index(target_index)
        assert re.fullmatch(r'[0-9A-Fa-f-]{36}', target.get_accessible_id())
        assert not target.get_state_set().contains(Atspi.StateType.SELECTED)
        name = target.get_name().split(' [', 1)[0]
        assert name.startswith('Project'), name
        assert '界' in name, name
        action = target.get_action_iface()
        assert action.get_n_actions() == 2
        assert action.get_action_name(0) == 'select'
        assert action.get_action_name(1) == 'open'
        assert action.do_action(0), 'AT-SPI select action was refused'
        eventually(lambda: window_title().endswith('/' + name), 'AT-SPI selected project')
        selected = eventually(lambda: content(app).get_child_at_index(target_index)
                              if content(app).get_child_at_index(target_index).get_state_set()
                              .contains(Atspi.StateType.SELECTED) else None,
                              'AT-SPI selection state')
        assert selected.get_name().startswith(name)
        assert selected.get_action_iface().do_action(1), 'AT-SPI open action was refused'
        terminal = eventually(lambda: content(app) if content(app).get_role_name() == 'terminal'
                              else None, 'terminal accessible after row action')
        eventually(lambda: terminal.get_name().endswith('A11Y TERMINAL READY'),
                   'accessible terminal title')
        assert terminal.get_child_count() == 0
        assert terminal.get_description() == 'Visible terminal screen; read only.'
        terminal_text = terminal.get_text_iface()
        assert terminal_text is not None
        def screen_text():
            return Atspi.Text.get_text(terminal_text, 0, -1)
        initial = eventually(lambda: screen_text()
                             if 'VISIBLE 界 e\u0301' in screen_text() else None,
                             'accessible visible Unicode text')
        assert 'OFFSCREEN_ONLY' not in initial, initial
        assert 'CONCEALED_MARKER' not in initial, initial
        assert terminal_text.get_character_count() == len(initial)
        assert terminal_text.get_character_at_offset(initial.index('界')) == ord('界')
        assert 0 <= terminal_text.get_caret_offset() <= len(initial)
        assert not terminal_text.set_caret_offset(0), 'read-only terminal accepted remote caret movement'
        subprocess.run(['xdotool', 'key', 'x'], check=True, timeout=5)
        updated = eventually(lambda: screen_text()
                             if 'UPDATED VISIBLE' in screen_text() else None,
                             'live accessible terminal update')
        assert 'VISIBLE 界 e\u0301' not in updated, updated
        assert terminal_text.get_character_count() == len(updated)
        assert re.search(r'TERMINAL_FRAME .*A11Y TERMINAL READY', log_path.read_text())
        subprocess.run(['xdotool', 'windowfocus', window_id,
                        'key', 'alt+F4'], check=True, timeout=5)
        assert process.wait(timeout=5) == 0
        print('PASS AT-SPI: bounded navigator and live visible terminal text, Unicode, concealment and caret',
              flush=True)
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
