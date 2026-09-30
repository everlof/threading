"""Installed contextual Actions: real button gestures, disabled commands and exact PTY ownership."""
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture) / 'actions-fixture'
root.mkdir()
store, project, home = root / 'store', root / 'ActionsProject', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_NAVIGATION_TRACE='1')
for name in ('THREADING_LINUX_CODEX_ACCOUNT', 'THREADING_LINUX_CLAUDE_ACCOUNT'):
    environment.pop(name, None)
marker = root / 'child.json'
child = root / 'child.py'
child.write_text(r'''
import json, os, pathlib, sys, tty
path = pathlib.Path(sys.argv[1])
received = bytearray()
tty.setraw(0)
def save():
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid': os.getpid(), 'input': received.hex(), 'cwd': os.getcwd()}))
    temporary.replace(path)
    os.write(1, b'\x1b[2J\x1b[HACTIONS CHILD READY\r\n\x1b]0;ACTIONS READY\x07')
# Button-event mouse mode makes an accidentally forwarded UI press/release observable input.
os.write(1, b'\x1b[?1002h\x1b[?1006h')
save()
while True:
    data = os.read(0, 4096)
    if not data: break
    received.extend(data)
    save()
''')
commands = ['project.add', 'linux.project.open-shell', 'linux.project.new-shell',
            'linux.session.new-codex', 'linux.account.choose-codex', 'linux.session.new-claude',
            'linux.account.choose-claude', 'linux.project.saved-agents', 'linux.project.saved-terminals']
process = None
owned = None
agent_owned = set()
agent_store = root / 'agent-store'
agent_project = root / 'AgentActionsProject'
Atspi.init()
# The first real capture clipped "Actions" to "Actio..." in an 88px button. Measure
# the complete label independently of the production rectangle and retain both 12px insets.
button_label_width = int(subprocess.run(
    ['convert', '-density', '72', '-background', 'none', '-font', 'DejaVu-Sans',
     '-pointsize', '18', 'label:Actions', '-format', '%w', 'info:'],
    check=True, capture_output=True, text=True, timeout=5).stdout)


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def eventually(read, label, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def title(pattern):
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid),
                                  '--name', pattern).splitlines()[0], pattern)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def children():
    frame = app.get_child_at_index(0)
    return frame, [frame.get_child_at_index(i) for i in range(frame.get_child_count())]


def listing():
    return next(item for item in children()[1] if item.get_role_name() == 'list')


def button():
    frame, items = children()
    item = next(item for item in items if item.get_accessible_id() == 'linux.actions')
    assert item.get_role_name() == 'push button'
    bounds = item.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    sidebar_width = 320 if any(child.get_role_name() == 'terminal' for child in items) else \
        frame.get_component_iface().get_extents(Atspi.CoordType.WINDOW).width
    assert (bounds.x, bounds.y, bounds.width, bounds.height) == (sidebar_width - 112, 8, 100, 36)
    assert bounds.width >= button_label_width + 24, 'Actions label would be ellipsized'
    assert frame.get_component_iface().get_accessible_at_point(
        bounds.x + 10, bounds.y + 10, Atspi.CoordType.WINDOW).get_accessible_id() == 'linux.actions'
    assert item.get_state_set().contains(Atspi.StateType.ENABLED)
    assert item.get_state_set().contains(Atspi.StateType.SHOWING)
    return item, bounds


def press_accessible():
    action = button()[0].get_action_iface()
    assert action.get_n_actions() == 1 and action.get_action_name(0) == 'press'
    assert action.do_action(0)
    eventually(lambda: listing().get_name() == 'Project actions', 'Actions accessibility activation')


def rows():
    listed = listing()
    assert listed.get_name() == 'Project actions'
    assert 0 < listed.get_child_count() <= 8
    return {listed.get_child_at_index(i).get_accessible_id(): listed.get_child_at_index(i)
            for i in range(listed.get_child_count())}


def command(identifier, enabled):
    def read():
        row = rows().get(identifier)
        if row is None:
            return None
        state = row.get_state_set()
        assert state.contains(Atspi.StateType.ENABLED) == enabled
        assert state.contains(Atspi.StateType.SENSITIVE) == enabled
        assert state.contains(Atspi.StateType.SELECTABLE)
        assert row.get_action_iface().get_n_actions() == (2 if enabled else 1)
        if not enabled:
            assert len(row.get_name().split(' ', 1)) > 1
        return row
    row = eventually(read, 'command state ' + identifier)
    if not enabled:
        # ATK's D-Bus adapter replies TRUE before calling atk_action_do_action and ignores the
        # callback result; a remote TRUE is receipt, not admission. Keep probing invalid open,
        # but prove no SDL enqueue or user-state change after a synchronous GetName barrier.
        # https://github.com/GNOME/at-spi2-core/blob/main/atk-adaptor/adaptors/action-adaptor.c#L184-L205
        def enqueues():
            return [line for line in log_path.read_text().splitlines()
                    if line.startswith('NAVIGATION_TRACE scope=accessibility stage=enqueue ')]
        def identities():
            with sqlite3.connect(store / 'threading.db') as database:
                return (tuple(database.execute('SELECT id FROM project ORDER BY id')),
                        tuple(database.execute('SELECT id FROM session ORDER BY id')),
                        tuple((identifier, tuple(item['id'] for item in json.loads(payload)['terminals']))
                              for identifier, payload in database.execute('SELECT id,data FROM project ORDER BY id')))
        before_events = enqueues()
        assert len(before_events) < 64, 'navigation trace exhausted; no-dispatch proof would be vacuous'
        before_ids = identities()
        selection = listing().get_selection_iface().get_selected_child(0).get_accessible_id()
        action = row.get_action_iface()
        action.do_action(1)
        assert action.get_action_name(0) == 'select'  # synchronous method, after invalid DoAction
        assert enqueues() == before_events, 'invalid disabled action entered the native event queue'
        assert listing().get_name() == 'Project actions'
        assert listing().get_selection_iface().get_selected_child(0).get_accessible_id() == selection
        assert identities() == before_ids, 'invalid disabled action mutated durable identities'
    return row


def invoke(identifier):
    row = command(identifier, True)
    assert row.get_action_iface().do_action(1)


def selected(identifier):
    item = listing().get_selection_iface().get_selected_child(0)
    return item is not None and item.get_accessible_id() == identifier


def close_window():
    key('alt+F4')
    assert process.wait(timeout=8) == 0


def snapshot(name):
    path = Path('out/actions-' + name + '.png')
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=5)
    return path


def button_pixels(name):
    path = snapshot(name)
    _, bounds = button()
    return subprocess.run(['convert', str(path), '-crop', f'{bounds.width}x{bounds.height}+{bounds.x}+{bounds.y}',
                           '+repage', '-depth', '8', 'rgba:-'], check=True, capture_output=True,
                          timeout=5).stdout


def child_state():
    return json.loads(marker.read_text())


def sessions():
    return json.loads(subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                     check=True, capture_output=True, text=True, timeout=5).stdout)


def owner():
    global owned
    with sqlite3.connect(store / 'threading.db') as database:
        assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        records = list(database.execute('SELECT data FROM project'))
    assert len(records) == 1
    terminals = json.loads(records[0][0])['terminals']
    assert len(terminals) == 1
    state = child_state()
    assert state['cwd'] == str(project)
    current = ('terminal-' + terminals[0]['id'], state['pid'])
    if owned:
        assert current == owned, 'Actions replaced the retained child'
    owned = current
    runtime = next(item for item in sessions() if item['id'] == owned[0])
    assert runtime['pid'] == owned[1] and runtime.get('exit') is None
    return True


def terminal_focus():
    item = next(item for item in children()[1] if item.get_role_name() == 'terminal')
    return item.get_state_set().contains(Atspi.StateType.FOCUSED)


try:
    # A true empty store proves disabled commands cannot fabricate a project or runtime.
    subprocess.run([host, '--init-store', str(store)], check=True,
                   capture_output=True, timeout=10)
    log_path = Path('out/actions-empty.log')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                    str(child), str(marker)], env=environment, stdout=log, stderr=log)
        window = title('^Threading experiment - empty store$')
        app = eventually(application, 'empty app accessibility')
        press_accessible()
        command('project.add', True)
        for identifier in commands[1:8]:
            command(identifier, False)
        for _ in range(8):
            key('Down')
        eventually(lambda: selected(commands[-1]), 'ninth bounded command reached')
        command(commands[-1], False)
        key('Return')
        assert not marker.exists()
        assert listing().get_name() == 'Project actions'
        snapshot('empty-disabled')
        key('Escape')
        eventually(lambda: listing().get_name() != 'Project actions', 'cancel empty menu')
        press_accessible()
        invoke('project.add')
        dialog = eventually(lambda: xdo('search', '--onlyvisible', '--name',
                                        '^Add project folder$').splitlines()[0],
                            'Actions opened native folder chooser')
        xdo('windowfocus', '--sync', dialog, 'key', 'Escape')
        eventually(lambda: 'PROJECT_IMPORT_CANCELLED' in log_path.read_text(), 'cancel Actions folder import')
        eventually(lambda: listing().get_name() == 'Projects' and button()[0], 'Actions enabled after cancel')
        with sqlite3.connect(store / 'threading.db') as database:
            assert database.execute('SELECT COUNT(*) FROM project').fetchone()[0] == 0
        assert not marker.exists()
        close_window()
    subprocess.run([host, '--add-project', str(store), str(project)], check=True,
                   capture_output=True, timeout=10)
    log_path = Path('out/actions-window.log')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                    str(child), str(marker)], env=environment, stdout=log, stderr=log)
        window = title('^Threading experiment - ' + re.escape(str(project)) + '$')
        app = eventually(application, 'project accessibility')
        _, bounds = button()
        xdo('mousemove', '--window', window, '10', '150')
        normal = button_pixels('normal')
        xdo('mousemove', '--window', window, str(bounds.x + 20), str(bounds.y + 20))
        hover = eventually(lambda: (value if (value := button_pixels('hover')) != normal else None), 'visible hover state')
        xdo('mousedown', '1')
        pressed = eventually(lambda: (value if (value := button_pixels('pressed')) != hover else None), 'visible pressed state')
        xdo('mousemove', '--window', window, '10', '150', 'mouseup', '1')
        eventually(lambda: button_pixels('cancelled') == normal, 'cancelled press restores normal button')
        assert listing().get_name() != 'Project actions' and not marker.exists()
        # A completed pointer gesture activates; unsupported buttons cannot toggle the picker.
        xdo('mousemove', '--window', window, str(bounds.x + 20), str(bounds.y + 20), 'click', '3')
        assert listing().get_name() != 'Project actions'
        xdo('click', '1')
        eventually(lambda: listing().get_name() == 'Project actions', 'pointer activated Actions')
        key('Escape')
        eventually(lambda: listing().get_name() == 'Projects', 'pointer menu dismissed before first terminal')
        # Before a terminal exists, sidebarWidth is zero. The shortcut release must still clear
        # activation suppression before an accessibility action opens the first child.
        # Keep both modifiers down during Space release; xdotool's combined key command can
        # release modifiers first and bypass the exact shortcut-keyup branch under test.
        xdo('windowfocus', '--sync', window, 'keydown', 'Control_L', 'Shift_L', 'space')
        xdo('keyup', 'space', 'Shift_L', 'Control_L')
        eventually(lambda: listing().get_name() == 'Project actions', 'initial keyboard Actions activation')
        command('linux.session.new-codex', False)
        command('linux.session.new-claude', False)
        invoke('linux.project.open-shell')
        title('^Threading terminal - ACTIONS READY$')
        eventually(owner, 'Actions opened exactly one real shell')
        assert child_state()['input'] == ''
        eventually(terminal_focus, 'terminal initially focused')
        key('i')
        eventually(lambda: child_state()['input'] == b'i'.hex(),
                   'initial Actions shortcut release did not suppress subsequent child text', timeout=5)
        key('ctrl+shift+space')
        eventually(lambda: listing().get_name() == 'Project actions', 'terminal shortcut opened Actions')
        disabled = command('linux.project.new-shell', False)
        assert 'running' in disabled.get_name() or '8' in disabled.get_name()
        assert disabled.get_action_iface().do_action(0)
        eventually(lambda: selected('linux.project.new-shell'), 'select disabled command')
        key('Return')
        owner()
        assert child_state()['input'] == b'i'.hex()
        assert listing().get_name() == 'Project actions'
        snapshot('live-disabled')
        key('Escape')
        eventually(terminal_focus, 'Escape restored prior terminal focus')
        key('v')
        eventually(lambda: child_state()['input'] == b'iv'.hex(), 'menu keys did not reach child')
        press_accessible()
        # Click outside the picker dismisses without replaying that event into the old pane.
        xdo('mousemove', '--window', window, '500', '100', 'click', '1')
        eventually(terminal_focus, 'outside click restored terminal focus')
        key('x')
        eventually(lambda: child_state()['input'] == b'ivx'.hex(), 'dismiss preserved raw input owner')
        # Returning to sidebar focus makes C cancel native held buttons. Swift must not leave
        # stale release suppression behind after that cancellation, or the next real click loses
        # its release and strands the child in a held-button state.
        key('ctrl+shift+p')
        eventually(lambda: listing().get_name() == 'Projects' and not terminal_focus(),
                   'sidebar focused before second outside dismissal')
        press_accessible()
        xdo('mousemove', '--window', window, '500', '100', 'click', '1')
        eventually(lambda: listing().get_name() == 'Projects' and not terminal_focus(),
                   'outside dismissal restored original sidebar focus')
        assert child_state()['input'] == b'ivx'.hex()
        key('Tab')
        eventually(terminal_focus, 'terminal focus after sidebar-return dismissal')
        xdo('mousemove', '--window', window, '500', '100', 'click', '1')
        # The fixed10x22px grid begins at window x320. A left click at500,100 is column19,row5.
        expected_input = b'ivx\x1b[<0;19;5M\x1b[<0;19;5m'
        eventually(lambda: child_state()['input'] == expected_input.hex(),
                   'next genuine mouse gesture retains matching press and release')
        key('a')
        expected_input += b'a'
        eventually(lambda: child_state()['input'] == expected_input.hex(), 'mouse-report ordering barrier')
        press_accessible()
        # Reach the ninth command through the real bounded viewport, then reopen the saved child.
        for _ in range(8):
            key('Down')
        eventually(lambda: selected('linux.project.saved-terminals'), 'saved-terminal command selected')
        invoke('linux.project.saved-terminals')
        title('^Threading terminals - ' + re.escape(str(project)) + '$')
        key('Return')
        title('^Threading terminal - ACTIONS READY$')
        eventually(owner, 'saved action reused exact child ID/PID')
        assert child_state()['input'] == expected_input.hex()
        snapshot('retained-shell')
        close_window()
    # Positive lifecycle uses isolated executable stand-ins for both supported provider routes.
    # They record real PTY input/account environment without credentials or provider requests.
    agent_project.mkdir()
    subprocess.run([host, '--add-project', str(agent_store), str(agent_project)], check=True,
                   capture_output=True, timeout=10)
    for provider, marker_name in [('codex', 'auth.json'), ('claude', 'settings.json')]:
        account = home / ('.' + provider + '-work')
        account.mkdir()
        (account / marker_name).write_text('{}')
        executable = root / ('agent-' + provider)
        executable.write_text('#!/usr/bin/python3\n' + r"""
import json, os, pathlib, sys, tty
provider = pathlib.Path(sys.argv[0]).name.split('-')[-1]
path = pathlib.Path.cwd() / (provider + '.json')
received = bytearray()
tty.setraw(0)
def save():
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid': os.getpid(), 'cwd': os.getcwd(), 'input': received.hex(),
        'account': os.environ.get('CODEX_HOME' if provider == 'codex' else 'CLAUDE_CONFIG_DIR')}))
    temporary.replace(path)
    os.write(1, ('\x1b]0;ACTIONS ' + provider.upper() + ' READY\x07').encode())
save()
while True:
    data = os.read(0, 4096)
    if not data: break
    received.extend(data)
    save()
""")
        executable.chmod(0o700)
    log_path = Path('out/actions-agents.log')
    with log_path.open('w+') as log:
        process = subprocess.Popen([binary, '--app-agents', str(agent_store), endpoint, '/bin/sh',
                                    str(root / 'agent-codex'), str(root / 'agent-claude')],
                                   env=environment, stdout=log, stderr=log)
        window = title('^Threading experiment - ' + re.escape(str(agent_project)) + '$')
        app = eventually(application, 'configured provider accessibility')
        for number, provider in enumerate(('codex', 'claude'), start=1):
            press_accessible()
            invoke('linux.account.choose-' + provider)
            eventually(lambda: listing().get_name() == ('Codex' if provider == 'codex' else 'Claude') + ' accounts',
                       'account chooser through Actions')
            account_rows = {listing().get_child_at_index(i).get_accessible_id(): listing().get_child_at_index(i)
                            for i in range(listing().get_child_count())}
            assert len(account_rows) == 2 and provider + '-work' in account_rows
            assert account_rows[provider + '-work'].get_action_iface().do_action(1)
            eventually(lambda: listing().get_name() == 'Projects', 'account selected without spawning')
            with sqlite3.connect(agent_store / 'threading.db') as database:
                assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == number - 1
            press_accessible()
            invoke('linux.session.new-' + provider)
            title('^Threading terminal - ACTIONS ' + provider.upper() + ' READY$')
            report = json.loads((agent_project / (provider + '.json')).read_text())
            assert report['input'] == '' and report['cwd'] == str(agent_project)
            assert report['account'] == str(home / ('.' + provider + '-work'))
            with sqlite3.connect(agent_store / 'threading.db') as database:
                records = list(database.execute('SELECT id,kind,data FROM session'))
            assert len(records) == number
            identifier, kind, payload = next(row for row in records if row[1] == provider)
            assert json.loads(payload)['accountHandle'] == provider + '-work'
            runtime = next(item for item in sessions() if identifier.lower() in item['id'].lower()
                           and item['pid'] == report['pid'])
            assert runtime.get('exit') is None
            agent_owned.add((runtime['id'], runtime['pid']))
        assert json.loads((agent_project / 'codex.json').read_text())['input'] == ''
        snapshot('provider-commands')
        press_accessible()
        invoke('linux.project.saved-agents')
        title('^Threading agents - ' + re.escape(str(agent_project)) + '$')
        listed = listing()
        assert listed.get_child_count() == 2
        with sqlite3.connect(agent_store / 'threading.db') as database:
            identities = dict(database.execute('SELECT kind,id FROM session'))
        saved_rows = {listed.get_child_at_index(i).get_accessible_id(): listed.get_child_at_index(i)
                for i in range(2)}
        assert set(saved_rows) == set(identities.values())
        for identifier in identities.values():
            assert saved_rows[identifier].get_name().endswith(' retained'), saved_rows[identifier].get_name()
        snapshot('provider-rows-retained')
        # Activate by durable row identity after the layout change; the same cached child owns
        # both the visual row and the terminal. Retained never asserts that an agent is working.
        action = saved_rows[identities['codex']].get_action_iface()
        open_index = next(i for i in range(action.get_n_actions()) if action.get_action_name(i) == 'open')
        assert action.do_action(open_index)
        title('^Threading terminal - ACTIONS CODEX READY$')
        assert json.loads((agent_project / 'codex.json').read_text())['input'] == ''
        live = {(item['id'], item['pid']) for item in sessions() if item.get('exit') is None}
        assert agent_owned <= live, 'saved row activation replaced a retained agent'
        with sqlite3.connect(agent_store / 'threading.db') as database:
            assert dict(database.execute('SELECT kind,id FROM session')) == identities
        close_window()
    print('PASS native Actions button states/cancel, folder chooser/cancel, keyboard and AT-SPI activation, disabled admission, '
          'bounded nine-command list, focus/input isolation, exact shell reuse and named-account provider creation', flush=True)
finally:
    # The fixture owns this isolated X server; never leave explicit keys or a button held.
    try:
        xdo('keyup', 'space', 'Shift_L', 'Control_L')
    except Exception:
        pass
    try:
        xdo('mouseup', '1')
    except Exception:
        pass
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    if owned is None and marker.exists():
        try:
            owner()
        except Exception:
            pass
    # Recover provider ownership if failure occurred after launch but before the assertion.
    if agent_project.exists() and (agent_store / 'threading.db').exists():
        with sqlite3.connect(agent_store / 'threading.db') as database:
            records = list(database.execute('SELECT id,kind FROM session'))
        for runtime in sessions():
            for identifier, kind in records:
                marker_path = agent_project / (kind + '.json')
                if marker_path.exists() and identifier.lower() in runtime['id'].lower():
                    if json.loads(marker_path.read_text())['pid'] == runtime['pid']:
                        agent_owned.add((runtime['id'], runtime['pid']))
    cleanup = agent_owned | ({owned} if owned else set())
    if cleanup:
        for runtime in sessions():
            if (runtime['id'], runtime['pid']) in cleanup and runtime.get('exit') is None:
                try:
                    os.kill(runtime['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
