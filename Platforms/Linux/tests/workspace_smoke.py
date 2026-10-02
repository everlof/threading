"""Exercise the installed two-pane workspace through native input, AT-SPI and real PTYs."""
import json
import fcntl
import os
from pathlib import Path
import re
import shlex
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture) / 'workspace-fixture'
root.mkdir()
store = root / 'store'
projects = [root / f'Workspace{index:02d}' for index in range(1, 13)]
for project in projects:
    project.mkdir()
    subprocess.run([host, '--add-project', str(store), str(project)],
                   check=True, capture_output=True, timeout=10)
home = root / 'home'
home.mkdir()
child = root / 'workspace_child.py'
# An actual daemon PTY runs a plain bash exec of this recorder. Raw input provides exact
# evidence that navigation keys never reached either child, rather than relying on shell echo.
child.write_text(r'''
import fcntl, json, os, pathlib, signal, struct, sys, termios, tty
root = pathlib.Path(sys.argv[1])
name = pathlib.Path.cwd().name
target = root / (name + '.json')
received = bytearray()
mouse = False
tty.setraw(0)
def publish(*unused):
    rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
    value = {'pid': os.getpid(), 'cwd': os.getcwd(), 'input': received.hex(),
             'rows': rows, 'cols': cols, 'mouse': mouse}
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    temporary.replace(target)
    os.write(1, ('\x1b[2J\x1b[HVISIBLE 界 e\u0301\r\n' + name
                 + '\r\nINPUT ' + received.hex() + '\r\n'
                 + '\x1b]0;WORKSPACE ' + name + (' MOUSE' if mouse else '') + '\x07').encode())
def toggle_mouse(*unused):
    global mouse
    mouse = not mouse
    os.write(1, b'\x1b[?1002h\x1b[?1006h' if mouse else b'\x1b[?1002l\x1b[?1006l')
    publish()
signal.signal(signal.SIGWINCH, publish)
signal.signal(signal.SIGUSR1, toggle_mouse)
publish()
while True:
    data = os.read(0, 4096)
    if not data:
        break
    received.extend(data)
    publish()
''')
environment = dict(os.environ, HOME=str(home), PROMPT_COMMAND='')
environment.pop('BASH_ENV', None)
environment.pop('ENV', None)
log_path = Path('out/workspace-window.log')
process = None
owned = {}
Atspi.init()


def tail():
    with log_path.open('rb') as source:
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
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                  str(process.pid), '--name', pattern).splitlines()[0],
                      'native title ' + pattern)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def project_title(index):
    return title('^Threading experiment - ' + re.escape(str(projects[index])) + '$')


def terminal_title(index, mouse=False):
    return title('^Threading terminal - WORKSPACE ' + projects[index].name
                 + (' MOUSE' if mouse else '')
                 + r'( \[(history cut|restored)\])?$')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def panes():
    frame = app.get_child_at_index(0)
    children = [frame.get_child_at_index(index) for index in range(frame.get_child_count())]
    lists = [item for item in children if item.get_role_name() == 'list']
    terminals = [item for item in children if item.get_role_name() == 'terminal']
    assert [item.get_role_name() for item in children] == ['list', 'terminal', 'push button', 'push button']
    assert children[2].get_accessible_id() == 'linux.actions'
    assert children[3].get_accessible_id() == 'linux.add-project'
    assert len(lists) == len(terminals) == 1
    assert 0 < lists[0].get_child_count() <= 12
    assert lists[0].get_state_set().contains(Atspi.StateType.SHOWING)
    assert terminals[0].get_state_set().contains(Atspi.StateType.SHOWING)
    return frame, lists[0], terminals[0]


def rect(item, coordinates=Atspi.CoordType.WINDOW):
    value = item.get_component_iface().get_extents(coordinates)
    return value.x, value.y, value.width, value.height


def focus(terminal_focused):
    def read():
        _, listed, terminal = panes()
        selected = listed.get_selection_iface().get_selected_child(0)
        assert selected is not None
        assert terminal.get_state_set().contains(Atspi.StateType.FOCUSED) == terminal_focused
        assert selected.get_state_set().contains(Atspi.StateType.FOCUSED) != terminal_focused
        return True
    eventually(read, 'exclusive pane keyboard focus')


def state(index):
    path = root / (projects[index].name + '.json')
    return json.loads(path.read_text()) if path.exists() else None


def sessions():
    result = subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                            capture_output=True, text=True, check=True, timeout=5)
    return json.loads(result.stdout)


def durable():
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        return [json.loads(row[0]) for row in database.execute('SELECT data FROM project ORDER BY position')]


def verify_owner(index):
    def read():
        recorded = state(index)
        if not recorded:
            return None
        project = durable()[index]
        assert project['folderPath'] == str(projects[index])
        assert len(project['terminals']) == 1
        identity = 'terminal-' + project['terminals'][0]['id']
        runtime = next(item for item in sessions() if item['id'] == identity)
        assert runtime['pid'] == recorded['pid'] and runtime.get('exit') is None
        assert runtime['attached'] and recorded['cwd'] == str(projects[index])
        if index in owned:
            assert owned[index] == (identity, recorded['pid']), 'navigation replaced the child'
        owned[index] = (identity, recorded['pid'])
        return recorded
    return eventually(read, 'same durable runtime owner')


def click_row(index):
    _, listed, _ = panes()
    item = listed.get_child_at_index(index)
    x, y, width, height = rect(item)
    xdo('mousemove', '--window', window, str(x + min(30, width // 2)),
        str(y + height // 2), 'click', '1')


def geometry():
    frame, listed, terminal = panes()
    fx, fy, fw, fh = rect(frame)
    tx, ty, tw, th = rect(terminal)
    lx, ly, lw, lh = rect(listed)
    assert (fx, fy) == (0, 0)
    assert (tx, ty, tw, th) == (320, 0, fw - 320, fh)
    assert lx == 0 and lw == 320 and ly >= 0 and ly + lh <= fh
    assert listed.get_child_count() <= min(12, int(lh // 48))
    component = frame.get_component_iface()
    assert component.get_accessible_at_point(tx + 5, ty + 5,
                                             Atspi.CoordType.WINDOW).get_role_name() == 'terminal'
    text = terminal.get_text_iface()
    screen = Atspi.Text.get_text(text, 0, -1)
    assert screen.startswith('VISIBLE 界 e\u0301'), screen
    wide = screen.index('界')
    bounds = text.get_character_extents(wide, Atspi.CoordType.WINDOW)
    assert (bounds.x, bounds.y, bounds.width, bounds.height) == (400, 0, 20, 22)
    assert text.get_offset_at_point(415, 11, Atspi.CoordType.WINDOW) == wide
    assert text.get_offset_at_point(95, 11, Atspi.CoordType.WINDOW) == -1
    parent = text.get_character_extents(wide, Atspi.CoordType.PARENT)
    # The terminal's accessible parent is the frame, so PARENT retains the pane offset.
    assert (parent.x, parent.y, parent.width, parent.height) == (400, 0, 20, 22)
    return tw, th


def screenshot(name):
    subprocess.run(['import', '-window', window, 'out/workspace-' + name + '.png'],
                   check=True, timeout=5)


def render_counts():
    text = log_path.read_text()
    return text.count('NAVIGATOR_TEXT mounted='), text.count('TERMINAL_FRAME ')


with log_path.open('w+') as log:
    try:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/bash',
                                    '--noprofile', '--norc', '-c',
                                    'exec /usr/bin/python3 ' + shlex.quote(str(child))
                                    + ' ' + shlex.quote(str(root))],
                                   env=environment, stdout=log, stderr=log)
        window = project_title(0)
        app = eventually(application, 'fixture AT-SPI application')
        key('Return')
        terminal_title(0)
        first = verify_owner(0)
        eventually(panes, 'simultaneous navigator and terminal siblings')
        focus(True)
        initial_width, initial_height = eventually(geometry, 'initial pane and text geometry')
        assert initial_width == 800, 'opening sidebar changed the initial terminal width'
        eventually(lambda: state(0)['cols'] == initial_width // 10
                   and state(0)['rows'] == initial_height // 22, 'initial child PTY grid')
        assert first['input'] == ''
        screenshot('terminal-focused')

        key('ctrl+shift+p')
        project_title(0)
        focus(False)
        before = state(0)['input']
        key('Down')
        project_title(1)
        key('Up')
        project_title(0)
        # Selection by pointer changes focus; opening still needs Enter.
        click_row(1)
        project_title(1)
        focus(False)
        screenshot('navigator-focused')
        assert state(0)['input'] == before, 'sidebar navigation leaked into first PTY'
        key('Return')
        terminal_title(1)
        second = verify_owner(1)
        assert second['pid'] != first['pid'] and second['input'] == ''
        focus(True)

        # Terminal Tab/Escape are ordinary PTY bytes, not workspace commands.
        key('Tab')
        key('Escape')
        eventually(lambda: state(1)['input'] == '091b', 'terminal Tab and Escape reach child')
        key('ctrl+shift+p')
        project_title(1)
        focus(False)
        click_row(0)
        project_title(0)
        key('Return')
        terminal_title(0)
        verify_owner(0)
        assert state(0)['input'] == before
        assert state(1)['input'] == '091b', 'sidebar activation leaked into second PTY'

        # Pane focus return must neither reopen the selected child nor forward the focus key.
        key('ctrl+shift+p')
        project_title(0)
        key('Tab')
        terminal_title(0)
        focus(True)
        before_sidebar_focus, _ = render_counts()
        key('ctrl+shift+p')
        project_title(0)
        eventually(lambda: render_counts()[0] > before_sidebar_focus,
                   'sidebar focus render completed before cache baseline')
        before_terminal_focus, _ = render_counts()
        key('Escape')
        terminal_title(0)
        focus(True)
        eventually(lambda: render_counts()[0] > before_terminal_focus,
                   'terminal focus render completed before cache baseline')
        # The known focus invalidations have now rendered; shell output alone must reuse
        # the existing navigator. Admission already settled before the same-owner return.
        navigator_renders, terminal_renders = render_counts()
        payload = '日本語 workspace e\u0301'
        subprocess.run(['xclip', '-selection', 'clipboard'], input=payload, text=True,
                       check=True, timeout=5)
        key('ctrl+shift+v')
        eventually(lambda: state(0)['input'] == payload.encode().hex(),
                   'Unicode clipboard reaches only focused terminal')
        def pasted_frame():
            terminal = panes()[2]
            screen = Atspi.Text.get_text(terminal.get_text_iface(), 0, -1)
            return ('INPUT ' + payload.encode().hex() in screen
                    and render_counts()[1] > terminal_renders)
        eventually(pasted_frame, 'pasted bytes rendered in the real terminal pane')
        assert render_counts()[0] == navigator_renders, \
            'terminal output unnecessarily rasterized or shaped the navigator'
        verify_owner(0)

        xdo('windowsize', window, '1280', '528')
        eventually(lambda: geometry() == (960, 528), 'resized pane and text geometry')
        eventually(lambda: state(0)['cols'] == 96 and state(0)['rows'] == 24,
                   'actual child PTY resize excludes sidebar')
        key('ctrl+shift+p')
        project_title(0)
        # Seek beyond the mounted viewport without admitting more runtimes.
        for index in range(1, 12):
            key('Down')
            project_title(index)
        _, listed, _ = panes()
        assert listed.get_child_count() <= 9
        assert listed.get_description() == 'Showing 4 through 12 of 12 items'
        assert listed.get_selection_iface().get_selected_child(0).get_name().startswith('Workspace12 ')
        assert len([value for value in durable() if value['terminals']]) == 2
        assert state(0)['input'] == payload.encode().hex()
        assert state(1)['input'] == '091b'
        screenshot('resized-navigator')
        key('Escape')
        terminal_title(0)
        focus(True)
        # Selecting a project alone must not replace the terminal shown beside it.
        verify_owner(0)
        verify_owner(1)
        screenshot('resized-terminal')
        key('ctrl+shift+p')
        project_title(11)
        xdo('mousemove', '--window', window, '325', '5', 'mousedown', '1')
        time.sleep(.05)
        xdo('mousemove', '--window', window, '395', '5')
        time.sleep(.05)
        xdo('mouseup', '1')
        terminal_title(0)
        focus(True)
        key('ctrl+shift+c')
        def copied():
            result = subprocess.run(['xclip', '-selection', 'clipboard', '-o'],
                                    capture_output=True, text=True, check=True, timeout=3)
            return result.stdout == 'VISIBLE'
        eventually(copied, 'offset pointer selection copied from terminal pane')
        assert state(0)['input'] == payload.encode().hex()
        screenshot('terminal-selection')

        # Begin on A, switch to B with the physical button still down, then release.
        # Each child enables real VT mouse reporting only after the local-selection proof.
        for index in (0, 1):
            recorded = verify_owner(index)
            os.kill(recorded['pid'], signal.SIGUSR1)
            eventually(lambda index=index: state(index)['mouse'], 'child mouse mode enabled')
        terminal_title(0, mouse=True)  # OSC follows the mode bytes through the emulator.
        input_a = state(0)['input']
        input_b = state(1)['input']
        press = b'\x1b[<0;3;2M'.hex()
        release = b'\x1b[<0;3;2m'.hex()
        try:
            xdo('mousemove', '--window', window, '345', '33', 'mousedown', '1')
            eventually(lambda: state(0)['input'] == input_a + press, 'mouse press delivered to A')
            key('ctrl+shift+p')
            project_title(11)
            eventually(lambda: state(0)['input'] == input_a + press + release,
                       'focus loss completes held gesture on its original child')
            for index in range(10, 0, -1):
                key('Up')
                project_title(index)
            key('Return')
            terminal_title(1, mouse=True)
            focus(True)
            verify_owner(1)
            xdo('mousemove', '--window', window, '365', '55')
        finally:
            # Always release the fixture's X button, including assertion failure paths.
            xdo('mouseup', '1')
        # A subsequent raw byte is an ordering barrier through B's PTY input worker.
        # Its exact suffix proves that preceding motion/release produced no orphan bytes.
        assert state(1)['input'] == input_b
        key('z')
        eventually(lambda: state(1)['input'] == input_b + b'z'.hex(),
                   'new child receives only explicit input, no orphan gesture')
        assert state(0)['input'] == input_a + press + release
        screenshot('mouse-owner-switch')
        # Middle-click is unsupported in the sidebar and must not silently change only the
        # native focus owner. The following byte traverses the real terminal PTY worker.
        before = state(1)['input']
        xdo('mousemove', '--window', window, '40', '78', 'click', '2')
        key('x')
        eventually(lambda: state(1)['input'] == before + b'x'.hex(),
                   'unsupported middle-click preserves terminal input ownership')
        focus(True)
        terminal_title(1, mouse=True)

        # Right-click is now a supported project-row context menu. Resolve a different
        # visible row by its durable ID: the viewport's first slot can change after deep
        # navigation, so a fixed y-position is not a project identity. Escape restores the
        # active Workspace02 terminal without selecting the menu's target project.
        before = state(1)['input']
        _, listing, _ = panes()
        active_id = durable()[1]['id']
        target_row = next(listing.get_child_at_index(index)
                          for index in range(listing.get_child_count())
                          if listing.get_child_at_index(index).get_accessible_id() != active_id)
        target_id = target_row.get_accessible_id()
        target_path = next(row['folderPath'] for row in durable() if row['id'] == target_id)
        rx, ry, rw, rh = rect(target_row)
        xdo('mousemove', '--window', window, str(rx + min(30, rw // 2)),
            str(ry + rh // 2), 'click', '3')
        eventually(lambda: panes()[1].get_name() == 'Project actions',
                   'right-click opened project Actions')
        title('^Threading actions - ' + re.escape(target_path) + '$')
        assert state(1)['input'] == before, 'right-click sent bytes to terminal'
        key('Escape')
        terminal_title(1, mouse=True)
        focus(True)
        key('x')
        eventually(lambda: state(1)['input'] == before + b'x'.hex(),
                   'right-click dismissal restored terminal input ownership')
        verify_owner(1)

        # A blocked durable selection must not suspend input to the still-visible old child.
        # SQLite's write lock holds the worker after it acquires host.lock, without adding
        # product hooks or relying on timing between Return and the selection commit.
        key('ctrl+shift+p')
        project_title(1)
        key('Up')
        project_title(0)
        old_input = state(1)['input']
        with (store / 'host.lock').open('a+b') as host_lock:
            def selection_worker_holds_lock():
                try:
                    fcntl.flock(host_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return True
                fcntl.flock(host_lock, fcntl.LOCK_UN)
                return False
            with sqlite3.connect(store / 'threading.db', timeout=0) as blocked_store:
                blocked_store.execute('BEGIN IMMEDIATE')
                try:
                    key('Return')
                    eventually(selection_worker_holds_lock,
                               'selection worker waiting behind SQLite write lock', timeout=2)
                    key('Tab')
                    terminal_title(1, mouse=True)
                    focus(True)
                    assert selection_worker_holds_lock(), 'selection gate escaped the held lock'
                    key('v')
                    eventually(lambda: state(1)['input'] == old_input + b'v'.hex(),
                               'old terminal receives input while durable selection is blocked', timeout=2)
                    assert selection_worker_holds_lock(), 'write lock released before input proof'
                    assert len([value for value in durable() if value['terminals']]) == 2
                finally:
                    blocked_store.rollback()
        terminal_title(0, mouse=True)
        focus(True)
        verify_owner(0)
        verify_owner(1)
        assert state(1)['input'] == old_input + b'v'.hex()
        screenshot('storage-pending-input')
        key('alt+F4')
        assert process.wait(timeout=5) == 0, tail()
        print('PASS simultaneous workspace panes, bounded navigator, exact child reuse, '
              'focus-isolated input, cached navigator during output, Unicode clipboard, '
              'offset text/selection, gesture ownership, input during blocked selection and real PTY resize',
              flush=True)
    except BaseException:
        print(tail(), file=sys.stderr)
        raise
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
        # A daemon child survives window close; match both fixture durable ID and recorded PID.
        try:
            # Also recover ownership if an assertion failed between spawn and verify_owner.
            cleanup = set(owned.values())
            for index, project in enumerate(durable()):
                recorded = state(index)
                if recorded and recorded['cwd'] == str(projects[index]):
                    for terminal in project['terminals']:
                        cleanup.add(('terminal-' + terminal['id'], recorded['pid']))
            for runtime in sessions():
                if ((runtime['id'], runtime['pid']) in cleanup
                        and runtime.get('exit') is None):
                    try:
                        os.kill(runtime['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        except Exception as error:
            print(f'workspace fixture child cleanup failed: {error}', file=sys.stderr)
