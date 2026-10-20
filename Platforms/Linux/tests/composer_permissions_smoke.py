"""Choose real footer permissions and verify durable records plus both providers' exact argv."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
from runtime_pixel_contract import assert_composer_focus_chrome, opening_prompt_frame
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'composer-permissions'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
state = root / 'daemon'
state.mkdir()
socket = Path(endpoint)
agent = root / 'record-agent'
agent.write_text("""#!/usr/bin/python3
import json, os, sys
from pathlib import Path
Path('permission-launch.json').write_text(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}))
""")
agent.chmod(0o700)
Atspi.init()
process = None
window_log = output / 'window.log'


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process is not None:
            assert process.poll() is None, window_log.read_text()
        try:
            result = read()
            if result:
                return result
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {window_log.read_text()}')


def descendants(node):
    yield node
    for index in range(node.get_child_count()):
        yield from descendants(node.get_child_at_index(index))


def application():
    desktop = Atspi.get_desktop(0)
    return next((desktop.get_child_at_index(i) for i in range(desktop.get_child_count())
                 if desktop.get_child_at_index(i).get_process_id() == process.pid), None)


def control(identity):
    return next((node for node in descendants(app) if node.get_accessible_id() == identity), None)


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, timeout=5).strip()


def capture(name):
    subprocess.run(['import', '-window', window, str(output / f'{name}.png')], check=True, timeout=8)


def choose(identity):
    # Seven values, at most six mounted rows. Traverse the real viewport rather than reaching
    # an unmounted row through a hidden control or writing state directly.
    if identity == 'bypassPermissions':
        menu = control('linux.composer.choices')
        bounds = menu.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        xdo('mousemove', bounds.x + bounds.width // 2, bounds.y + bounds.height // 2)
        xdo('click', '--repeat', 6, '--delay', 40, 5)
        row = eventually(lambda: control(identity), 'wheel reveals final permission')
        assert menu.get_child_count() <= 6
        capture(f'{provider}-permission-menu-scrolled')
        assert row.get_action_iface().do_action(0)
        return
    for _ in range(8):
        row = control(identity)
        if row is not None:
            assert row.get_action_iface().do_action(0)
            return
        xdo('key', 'Down')
        time.sleep(.1)
    raise AssertionError(f'permission row not reachable: {identity}')


modes = [None, 'manual', 'plan', 'acceptEdits', 'auto', 'dontAsk', 'bypassPermissions']
codex_axes = {
    'manual': ('untrusted', 'read-only', 'user'),
    'plan': ('never', 'read-only', 'user'),
    'acceptEdits': ('untrusted', 'workspace-write', 'user'),
    'auto': ('on-request', 'workspace-write', 'auto_review'),
    'dontAsk': ('never', 'workspace-write', 'user'),
    'bypassPermissions': ('never', 'danger-full-access', 'user'),
}
daemon_process = None
try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'daemon socket')
    for provider in ('codex', 'claude'):
        for mode in modes:
            case = f'{provider}-{mode or "inherit"}'
            directory = root / case
            directory.mkdir()
            store, project, home = directory / 'store', directory / 'Project', directory / 'home'
            project.mkdir()
            home.mkdir()
            subprocess.run([host, '--add-project', str(store), str(project)],
                           check=True, capture_output=True, timeout=8)
            window_log = output / f'{case}.log'
            with window_log.open('w') as log:
                process = subprocess.Popen([binary, '--app-agents-project', str(store), str(socket),
                    '/bin/sh', str(agent), str(agent), str(project)],
                    env=dict(os.environ, HOME=str(home)), stdout=log, stderr=log)
                app = eventually(application, 'application')
                editor = eventually(lambda: control('linux.composer.editor'), 'editor')
                window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                    '--name', '^Threading experiment - '), 'window').splitlines()[0]
                xdo('windowfocus', '--sync', window)
                if provider == 'claude':
                    assert control('linux.composer.provider').get_action_iface().do_action(0)
                    row = eventually(lambda: next((node for node in descendants(app)
                        if node.get_role_name() == 'list item' and node.get_name() == 'Claude Code'), None),
                        'Claude identity')
                    assert row.get_action_iface().do_action(0)
                    eventually(lambda: control('linux.composer.provider').get_name() == 'Identity: Claude Code',
                               'selected provider')
                chip = eventually(lambda: control('linux.composer.permissions'), 'permission chip')
                assert chip.get_name() == "Permissions: Agent's Setting"
                if mode is None:
                    bounds = chip.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
                    xdo('mousemove', bounds.x + bounds.width // 2, bounds.y + bounds.height // 2)
                    xdo('click', 1)
                    eventually(lambda: control('linux.composer.choices'), 'pointer opens permissions')
                    xdo('click', 1)
                    eventually(lambda: control('linux.composer.choices') is None, 'same chip closes permissions')
                    assert chip.get_action_iface().do_action(0)
                    eventually(lambda: control('linux.composer.choices'), 'accessible reopen')
                    xdo('key', 'Escape')
                    eventually(lambda: control('linux.composer.choices') is None, 'Escape dismisses permissions')
                    assert chip.get_name() == "Permissions: Agent's Setting"
                assert chip.get_action_iface().do_action(0)
                menu = eventually(lambda: control('linux.composer.choices'), 'permission menu')
                assert 1 <= menu.get_child_count() <= 6
                if mode == 'plan' and provider == 'codex':
                    plan = eventually(lambda: control('plan'), 'Plan row')
                    assert 'Codex has no plan mode' in plan.get_description()
                    capture('codex-permission-menu')
                if mode == 'auto' and provider == 'claude':
                    capture('claude-permission-menu')
                choose(mode or 'inherit')
                eventually(lambda: control('linux.composer.choices') is None, 'choice dismissed')
                eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED), 'typing focus restored')
                xdo('type', '--clearmodifiers', 'Typing restored')
                eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Typing restored',
                           'physical typing after accessible choice')
                if mode is None:
                    assert chip.get_name() == "Permissions: Agent's Setting"
                if mode == 'auto' and provider == 'codex':
                    assert chip.get_name() == 'Permissions: Auto (Approve for me)'
                prompt = f'Permission test {case} $(literal)'
                assert editor.get_editable_text_iface().set_text_contents(prompt)
                eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == prompt, 'draft')
                if mode == 'acceptEdits':
                    xdo('key', 'Tab')
                    if provider == 'claude':
                        model_chip = control('linux.composer.model-effort')
                        eventually(lambda: model_chip.get_state_set().contains(Atspi.StateType.FOCUSED), 'model key focus')
                        xdo('key', 'Tab')
                    eventually(lambda: chip.get_state_set().contains(Atspi.StateType.FOCUSED), 'footer key focus')
                    capture(f'{provider}-permission-footer-unfocused')
                    xdo('key', 'shift+Tab')
                    if provider == 'claude':
                        eventually(lambda: model_chip.get_state_set().contains(Atspi.StateType.FOCUSED), 'reverse model key focus')
                        xdo('key', 'shift+Tab')
                    eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED), 'editor key focus')
                    capture(f'{provider}-permission-footer-light')
                    assert_composer_focus_chrome(output / f'{provider}-permission-footer-light.png',
                        output / f'{provider}-permission-footer-unfocused.png',
                        opening_prompt_frame(editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)))
                    xdo('key', 'ctrl+shift+t')
                    eventually(lambda: 'THEME_APPEARANCE dark' in window_log.read_text()
                               and '\nFRAME ' in window_log.read_text().rsplit('THEME_APPEARANCE dark', 1)[-1],
                               'dark appearance presented')
                    capture(f'{provider}-permission-footer-dark')
                assert control('linux.placeholder.action').get_action_iface().do_action(0)
                marker = project / 'permission-launch.json'
                report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None, 'launch')
                argv = report['argv']
                assert report['cwd'] == str(project) and argv[-2:] == ['--', prompt], report
                if provider == 'claude':
                    if mode is None:
                        assert '--permission-mode' not in argv, argv
                    else:
                        assert argv[argv.index('--permission-mode') + 1] == mode, argv
                elif mode is None:
                    assert '--ask-for-approval' not in argv and '--sandbox' not in argv, argv
                    assert not any(arg.startswith('approvals_reviewer=') for arg in argv), argv
                else:
                    approval, sandbox, reviewer = codex_axes[mode]
                    assert argv[argv.index('--ask-for-approval') + 1] == approval, argv
                    assert argv[argv.index('--sandbox') + 1] == sandbox, argv
                    assert f'approvals_reviewer="{reviewer}"' in argv, argv
                with sqlite3.connect(store / 'threading.db') as database:
                    rows = database.execute('SELECT data FROM session').fetchall()
                assert len(rows) == 1, rows
                record = json.loads(rows[0][0])
                assert record.get('permissionMode') == mode and record['hasLaunched'], record
                (output / f'{case}-launch.json').write_text(json.dumps(report, indent=2))
                process.terminate()
                process.wait(timeout=5)
                process = None
                print(f'PASS composer permission {case}: selected, persisted, exact launch flags', flush=True)
finally:
    for child in (process, daemon_process):
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
