"""Enter and launch an opening brief through the installed Wayland window."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


launcher, project_name, evidence_name = sys.argv[1:]
evidence = Path(evidence_name)
capture = evidence / 'capture'
capture.mkdir(parents=True)
project = evidence / project_name
project.mkdir()
home = evidence / 'home'
home.mkdir()
agent = evidence / 'record-agent'
agent.write_text('''#!/usr/bin/python3
import json, os, sys, tty
from pathlib import Path
tty.setraw(0)
Path('wayland-agent.json').write_text(json.dumps({
    'cwd': os.getcwd(), 'argv': sys.argv[1:], 'pid': os.getpid()
}))
Path('wayland-agent-input').write_bytes(os.read(0, 1))
''')
agent.chmod(0o700)
data = evidence / 'data'
runtime = evidence / 'runtime'
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_SHELL='/bin/sh',
                   THREADING_LINUX_CODEX=str(agent), THREADING_LINUX_CLAUDE='',
                   THREADING_LINUX_DATA_DIR=str(data),
                   THREADING_LINUX_RUNTIME_DIR=str(runtime),
                   THREADING_WAYLAND_CAPTURE_DIR=str(capture),
                   WAYLAND_DEBUG='client', LD_PRELOAD='/tmp/wayland_capture.so')
log_path = evidence / 'app.log'
Atspi.init()


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f'{label}: app exited {process.returncode}; '
                                 f'{log_path.read_text()[-4000:]}')
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()[-4000:]}')


def descendants(root):
    pending = [(root, 0)]
    while pending:
        node, depth = pending.pop(0)
        yield node
        if depth < 5:
            for index in range(min(node.get_child_count(), 20)):
                child = node.get_child_at_index(index)
                if child is not None:
                    pending.append((child, depth + 1))


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_process_id() == process.pid and child.get_role_name() == 'application':
            return child
    return None


def control(identifier):
    return next((item for item in descendants(app)
                 if item.get_accessible_id() == identifier), None)


def listing(name):
    return next((item for item in descendants(app)
                 if item.get_role_name() == 'list' and item.get_name() == name), None)


def panel(title):
    return next((item for item in descendants(app)
                 if item.get_role_name() == 'panel'
                 and item.get_child_count() > 0
                 and item.get_child_at_index(0).get_name() == title), None)


input_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
input_socket.bind(str(evidence / 'input-client'))
input_socket.settimeout(3)


def inject(command):
    input_socket.sendto(command.encode(), os.environ['THREADING_WESTON_INPUT_SOCKET'])
    answer = input_socket.recv(128)
    if command == 'origin':
        assert answer.startswith(b'ORIGIN '), (command, answer)
        return tuple(map(int, answer.decode().split()[1:]))
    assert answer == b'OK', (command, answer)


def move_to(node):
    bounds = node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert bounds.width > 0 and bounds.height > 0, bounds
    origin_x, origin_y = inject('origin')
    inject(f'move {origin_x + bounds.x + bounds.width // 2} '
           f'{origin_y + bounds.y + bounds.height // 2}')


def click(node):
    move_to(node)
    inject('button down')
    inject('button up')


# Weston receives Linux input-event codes. Its Swedish XKB map makes key 26 a
# real Unicode å through wl_keyboard/SDL_TEXTINPUT, with no test-only SDL event.
keys = {'a': 30, 'd': 32, 'g': 34, 'k': 37, 'n': 49, 'r': 19,
        's': 31, 't': 20, 'v': 47, 'å': 26, ' ': 57, '\n': 28}


def type_brief(value):
    for character in value:
        key = keys[character]
        inject(f'key {key} down')
        inject(f'key {key} up')


def valid_bitmap(path):
    bitmap = path.read_bytes()
    assert bitmap[:2] == b'BM', 'invalid compositor capture'
    width, height = struct.unpack_from('<ii', bitmap, 18)
    assert (width, height) == (1120, 480), (width, height)
    return bitmap


process = None
try:
    with log_path.open('w') as log:
        process = subprocess.Popen([launcher, str(project)], env=environment,
                                   stdout=log, stderr=log)
        app = eventually(application, 'installed Wayland application')
        idle = eventually(lambda: panel('No Session Selected'), 'idle pane')
        (capture / 'trigger').write_text('normal\n')
        move_to(idle.get_child_at_index(2))
        idle_image = eventually(lambda: valid_bitmap(capture / 'normal.bmp')
                                if (capture / 'normal.bmp').is_file() else None,
                                'idle compositor capture')
        click(eventually(lambda: control('linux.placeholder.action'), 'New Session'))
        create = eventually(lambda: listing('New in Project'), 'project create menu')
        click(create.get_child_at_index(0))
        providers = eventually(lambda: listing('New Chat providers'), 'provider menu')
        click(providers.get_child_at_index(0))
        composer = eventually(lambda: panel('Start a Codex session'), 'composer pane')
        editor = eventually(lambda: control('linux.composer.editor'), 'composer editor')
        assert editor.get_state_set().contains(Atspi.StateType.FOCUSED)
        assert editor.get_state_set().contains(Atspi.StateType.EDITABLE)

        prompt = 'granska å\nrad två'
        type_brief(prompt)
        text = editor.get_text_iface()
        def has_prompt():
            observed = Atspi.Text.get_text(text, 0, -1)
            (evidence / 'observed-text.txt').write_text(repr(observed) + '\n')
            return observed == prompt
        eventually(has_prompt,
                   'Unicode multiline native editor input')
        assert text.get_caret_offset() == len(prompt)
        (capture / 'trigger').write_text('open\n')
        action = composer.get_child_at_index(composer.get_child_count() - 1)
        assert action.get_name() == 'Start Session', action.get_name()
        move_to(action)
        composer_image = eventually(lambda: valid_bitmap(capture / 'open.bmp')
                                    if (capture / 'open.bmp').is_file() else None,
                                    'composer compositor capture')
        assert idle_image != composer_image, 'composer did not change rendered pixels'
        click(action)

        marker = project / 'wayland-agent.json'
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'exact project agent launch')
        assert report['cwd'] == str(project), report
        assert report['argv'][-2:] == ['--', prompt], report
        with sqlite3.connect(data / 'store' / 'threading.db') as database:
            count = database.execute('SELECT COUNT(*) FROM session JOIN project '
                                     'ON session.project_id = project.id '
                                     'WHERE project.folder_path = ?', (str(project),)).fetchone()[0]
        assert count == 1, count
        time.sleep(.2)
        child_input = project / 'wayland-agent-input'
        assert not child_input.exists(), 'composer input leaked into the agent PTY'
        inject('key 16 down')  # KEY_Q, now owned by the terminal
        inject('key 16 up')
        eventually(lambda: child_input.is_file(), 'terminal received post-launch input')
        assert child_input.read_bytes() == b'q', child_input.read_bytes()
        protocol = log_path.read_text()
        assert 'wl_keyboard@' in protocol and '.key(' in protocol, 'no Wayland keyboard delivery'
        print('PASS installed Wayland Unicode composer, exact project launch and PTY isolation',
              flush=True)
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    input_socket.close()
