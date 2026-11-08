"""Exercise the shared model/effort grid through the installed shell and real PTY daemon."""
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
from saved_catalog_menu import open_saved_agents

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'composer-models'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
socket = Path(endpoint)
process = daemon_process = None
window_log = output / 'window.log'
Atspi.init()


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        if process is not None:
            assert process.poll() is None, f'process exited {process.returncode}: {window_log.read_text()}'
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


def cell(name):
    menu = control('linux.composer.choices')
    if menu is None:
        return None
    return next((menu.get_child_at_index(i) for i in range(menu.get_child_count())
                 if menu.get_child_at_index(i).get_name() == name), None)


def enabled(node):
    return node is not None and node.get_state_set().contains(Atspi.StateType.ENABLED)


def open_models():
    chip = eventually(lambda: control('linux.composer.model-effort'), 'model chip')
    eventually(lambda: enabled(chip), 'account catalogue')
    assert chip.get_action_iface().do_action(0)
    menu = eventually(lambda: control('linux.composer.choices'), 'model grid')
    assert menu.get_name() == 'Model and effort'
    assert 0 < menu.get_child_count() <= 128, menu.get_child_count()
    return menu


def select_cell(name, pointer=False):
    node = eventually(lambda: cell(name), name)
    assert enabled(node), name
    if pointer:
        bounds = node.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
        xdo('mousemove', bounds.x + bounds.width // 2, bounds.y + bounds.height // 2)
        xdo('click', 1)
    else:
        assert node.get_action_iface().do_action(0)
    eventually(lambda: control('linux.composer.choices') is None, 'grid dismissed')
    eventually(lambda: editor.get_state_set().contains(Atspi.StateType.FOCUSED), 'editor focus')


def select_account(fragment):
    assert control('linux.composer.provider').get_action_iface().do_action(0)
    row = eventually(lambda: next((node for node in descendants(app)
        if node.get_role_name() == 'list item' and fragment in node.get_name()), None), 'account row')
    assert row.get_action_iface().do_action(0)
    eventually(lambda: control('linux.composer.choices') is None, 'identity closed')


def option(identifier, name, efforts, default='high'):
    return dict(slug=identifier, display_name=name, visibility='list',
                default_reasoning_level=default,
                supported_reasoning_levels=[dict(effort=e, description=e) for e in efforts])


def catalog(directory, options, default, effort='medium'):
    directory.mkdir(exist_ok=True)
    (directory / 'auth.json').write_text('{}')
    (directory / 'config.toml').write_text(f'model = "{default}"\nmodel_reasoning_effort = "{effort}"\n')
    (directory / 'models_cache.json').write_text(json.dumps(dict(client_version='fixture', models=options)))


agent = root / 'record-agent'
agent.write_text('''#!/usr/bin/python3
import datetime, json, os, sys, tty, uuid
from pathlib import Path
args = sys.argv[1:]
resume = 'resume' in args
provider_id = args[args.index('resume') + 1] if resume else str(uuid.uuid4())
if os.environ['MODEL_FIXTURE_PROVIDER'] == 'codex':
    base = Path(os.environ.get('CODEX_HOME', str(Path(os.environ['HOME']) / '.codex')))
    day = datetime.datetime.now(datetime.timezone.utc)
    sessions = base / 'sessions' / day.strftime('%Y/%m/%d')
    sessions.mkdir(parents=True, exist_ok=True)
    (sessions / ('rollout-' + provider_id + '.jsonl')).write_text(json.dumps({
        'type': 'session_meta', 'payload': {'id': provider_id, 'cwd': os.getcwd()}}) + '\\n')
report = {'argv': args, 'cwd': os.getcwd(), 'provider_id': provider_id,
          'codex_home': os.getenv('CODEX_HOME'), 'claude_home': os.getenv('CLAUDE_CONFIG_DIR')}
Path('model-resume.json' if resume else 'model-launch.json').write_text(json.dumps(report))
if os.environ.get('MODEL_FIXTURE_KEEPALIVE') == '1':
    tty.setraw(0)
    os.write(1, b'\\x1b]0;MODEL FIXTURE READY\\x07')
    assert os.read(0, 1) == b'q'
''')
agent.chmod(0o700)
base_options = [option('model-alpha', 'Alpha', ['low', 'medium', 'high', 'ultra'], 'medium'),
                option('model-beta', 'Beta', ['low', 'high'], 'low'),
                option('model-plain', 'Plain', [], None)]
cases = [('codex', 'keyboard'), ('codex', 'inherit'), ('claude', 'pointer'),
         ('claude', 'inherit'), ('codex', 'account'), ('codex', 'large'),
         ('codex', 'stale'), ('codex', 'visibility'), ('codex', 'remember')]
requested_case = os.getenv('THREADING_MODEL_CASE')
if requested_case:
    cases = [(provider, scenario) for provider, scenario in cases
             if f'{provider}-{scenario}' == requested_case]
    assert cases, requested_case
try:
    state = root / 'daemon'
    state.mkdir()
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', str(socket), '--state', str(state)],
                                          stdout=log, stderr=log)
        eventually(lambda: socket.exists(), 'daemon socket')
    for provider, scenario in cases:
        case = f'{provider}-{scenario}'
        directory = root / case
        directory.mkdir()
        home, project, store = directory / 'home', directory / 'Project', directory / 'store'
        home.mkdir(); project.mkdir()
        codex = home / '.codex'
        catalog(codex, base_options, 'model-alpha')
        claude = home / '.claude'
        claude.mkdir()
        (claude / 'settings.json').write_text(json.dumps(dict(model='sonnet', effortLevel='medium')))
        (claude / '.claude.json').write_text(json.dumps(dict(additionalModelOptionsCache=[
            dict(value='vendor-preview', label='Preview', description='Preview · account model')])) )
        if scenario in ('account', 'remember'):
            catalog(home / '.codex-work', [option('work-default', 'Work default', ['high']),
                option('work-other', 'Work other', ['high'])], 'work-default', 'high')
        if scenario == 'large':
            levels = [f'custom-{i:02d}' for i in range(40)]
            catalog(codex, [option(f'model-{i:03d}', f'Model {i:03d}', levels, levels[0])
                            for i in range(600)], 'model-000', levels[0])
        subprocess.run([host, '--add-project', str(store), str(project)],
                       check=True, capture_output=True, timeout=8)
        environment = dict(os.environ, HOME=str(home), THREADING_LINUX_DATA_DIR=str(directory / 'data'),
                           MODEL_FIXTURE_PROVIDER=provider,
                           MODEL_FIXTURE_KEEPALIVE='1' if scenario == 'keyboard' else '0')
        command = [binary, '--app-agents-project', str(store), str(socket), '/bin/sh',
                   str(agent), str(agent), str(project)]
        window_log = output / f'{case}.log'
        with window_log.open('w') as log:
            process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        app = eventually(application, 'application')
        editor = eventually(lambda: control('linux.composer.editor'), 'editor')
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
            '--name', '^Threading experiment - '), 'window').splitlines()[0]
        xdo('windowfocus', '--sync', window)
        select_account('Claude Code' if provider == 'claude' else 'Codex')
        prompt = f'Model test {case} $(literal) 日本語'
        assert editor.get_editable_text_iface().set_text_contents(prompt)
        expected_model = expected_effort = None
        menu = open_models()
        if scenario == 'large':
            xdo('key', 'End')
            last = eventually(lambda: cell('Model 511 · Auto'), 'capped last model')
            assert last.get_state_set().contains(Atspi.StateType.FOCUSED)
            xdo('key', *(['Right'] * 32))
            last = eventually(lambda: cell('Model 511 · Custom 31'), 'horizontal viewport')
            assert last.get_state_set().contains(Atspi.StateType.FOCUSED)
            assert control('linux.composer.choices').get_child_count() <= 128
            capture('codex-large-last-cell')
            xdo('key', 'Return')
            expected_model, expected_effort = 'model-511', 'custom-31'
        elif provider == 'claude':
            assert eventually(lambda: cell('Sonnet · Auto'), 'account default row').get_description() == 'Account default'
            capture(f'{case}-grid')
            if scenario == 'inherit':
                select_cell('Sonnet · Auto')
            else:
                xdo('key', 'End') # The extra account model is below the compact viewport.
                select_cell('Preview · Max', pointer=True)
                expected_model, expected_effort = 'vendor-preview', 'max'
        else:
            unavailable = eventually(lambda: cell('Beta · Ultra'), 'unavailable combination')
            assert not enabled(unavailable) and unavailable.get_action_iface().get_n_actions() == 0
            assert cell('Alpha · Auto').get_description() == 'Account default'
            capture(f'{case}-grid')
            if scenario == 'visibility':
                plain = eventually(lambda: cell('Plain · Auto'), 'model to hide')
                bounds = plain.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
                xdo('mousemove', bounds.x - 22, bounds.y + bounds.height // 2)
                time.sleep(.1)
                capture('codex-hide-model-hover')
                xdo('click', 1)
                eventually(lambda: control('linux.composer.choices') is None, 'hide closes picker')
                visibility_file = directory / 'data/model-visibility.json'
                eventually(lambda: visibility_file.exists(), 'saved account visibility')
                open_models()
                assert cell('Plain · Auto') is None
                capture('codex-hidden-model-footer')
                footer = eventually(lambda: control('model-effort.show-hidden-models'), 'accessible footer')
                assert footer.get_role_name() == 'push button'
                assert footer.get_name() == 'Show hidden models (1)'
                assert footer.get_action_iface().get_n_actions() == 1
                xdo('key', 'Tab')
                eventually(lambda: footer.get_state_set().contains(Atspi.StateType.FOCUSED),
                           'keyboard footer focus')
                capture('codex-hidden-model-footer-focused')
                xdo('key', 'shift+Tab')
                eventually(lambda: not footer.get_state_set().contains(Atspi.StateType.FOCUSED),
                           'keyboard return to grid')
                xdo('key', 'Escape')
                process.terminate(); process.wait(timeout=5); process = None
                window_log = output / 'codex-visibility-restart.log'
                with window_log.open('w') as log:
                    process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
                app = eventually(application, 'restarted application')
                editor = eventually(lambda: control('linux.composer.editor'), 'restarted editor')
                window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                    '--name', '^Threading experiment - '), 'restarted window').splitlines()[0]
                xdo('windowfocus', '--sync', window)
                # No session was committed, so the restarted draft uses the configured agent.
                # Hidden-model preferences belong to the account we are testing, not that default.
                select_account('Codex')
                assert editor.get_editable_text_iface().set_text_contents(prompt)
                menu = open_models()
                assert cell('Plain · Auto') is None, 'hidden model must survive restart'
                eventually(lambda: control('model-effort.show-hidden-models'), 'persisted hidden-model footer')
                xdo('key', 'Tab', 'space')
                eventually(lambda: control('linux.composer.choices') is None, 'show hidden closes picker')
                open_models()
                eventually(lambda: cell('Plain · Auto'), 'restored model')
                capture('codex-restored-model-grid')
                plain = cell('Plain · Auto')
                bounds = plain.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
                xdo('mousemove', bounds.x - 22, bounds.y + bounds.height // 2)
                xdo('click', 1)
                eventually(lambda: control('linux.composer.choices') is None, 'second hide closes picker')
                open_models()
                footer = eventually(lambda: control('model-effort.show-hidden-models'),
                                    'accessible footer after second hide')
                assert footer.get_action_iface().do_action(0)
                eventually(lambda: control('linux.composer.choices') is None,
                           'AT-SPI show hidden closes picker')
                open_models()
                eventually(lambda: cell('Plain · Auto'), 'AT-SPI restored model')
                select_cell('Beta · High')
                expected_model, expected_effort = 'model-beta', 'high'
            elif scenario == 'inherit':
                select_cell('Alpha · Auto')
            elif scenario == 'keyboard':
                select_cell('Alpha · Ultra', pointer=True)
                open_models()
                capture('codex-selected-ultra-light')
                xdo('key', 'ctrl+shift+t')
                eventually(lambda: 'THEME_APPEARANCE dark' in window_log.read_text(), 'dark theme')
                def dark_frame():
                    capture('codex-selected-ultra-dark')
                    image = output / 'codex-selected-ultra-dark.png'
                    width, height = map(int, subprocess.check_output(
                        ['identify', '-format', '%w %h', str(image)], text=True).split())
                    red = float(subprocess.check_output(['convert', str(image), '-format',
                        f'%[fx:p{{{width - 10},{height // 2}}}.r]', 'info:'], text=True))
                    return red < 0.2
                eventually(dark_frame, 'presented dark model grid')
                xdo('key', 'Escape')
                open_models()
                # Move to Auto, down one model, then skip Beta's unsupported Medium column.
                xdo('key', *(['Left'] * 4), 'Down', 'Right', 'Right')
                focused = eventually(lambda: cell('Beta · High'), 'keyboard target')
                assert focused.get_state_set().contains(Atspi.StateType.FOCUSED)
                xdo('key', 'space')
                expected_model, expected_effort = 'model-beta', 'high'
            else:
                select_cell('Beta · High')
                expected_model, expected_effort = 'model-beta', 'high'
            if scenario == 'account':
                select_account('codex-work')
                eventually(lambda: 'Work default' in control('linux.composer.model-effort').get_name(), 'named catalogue')
                assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == prompt
                open_models()
                assert cell('Beta · High') is None
                select_cell('Work other · High')
                expected_model, expected_effort = 'work-other', 'high'
            if scenario == 'stale':
                (codex / 'models_cache.json').write_text(json.dumps(dict(models=[base_options[0]])))
        eventually(lambda: control('linux.composer.choices') is None, 'choice dismissed')
        assert control('linux.placeholder.action').get_action_iface().do_action(0)
        marker = project / 'model-launch.json'
        if scenario == 'stale':
            eventually(lambda: 'unavailable' in xdo('getwindowname', window), 'fresh catalogue refusal')
            assert not marker.exists()
            with sqlite3.connect(store / 'threading.db') as database:
                assert database.execute('SELECT COUNT(*) FROM session').fetchone()[0] == 0
        else:
            report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None, 'launch')
            args = report['argv']
            assert report['cwd'] == str(project) and args[-2:] == ['--', prompt], report
            if expected_model is None:
                assert '--model' not in args, args
            else:
                assert args[args.index('--model') + 1] == expected_model, args
            if provider == 'codex':
                efforts = [value for value in args if value.startswith('model_reasoning_effort=')]
                assert efforts == ([] if expected_effort is None else [f'model_reasoning_effort="{expected_effort}"']), args
            elif expected_effort is None:
                assert '--effort' not in args, args
            else:
                assert args[args.index('--effort') + 1] == expected_effort, args
            with sqlite3.connect(store / 'threading.db') as database:
                records = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
            assert len(records) == 1 and records[0].get('model') == expected_model, records
            assert records[0].get('reasoningEffort') == expected_effort and records[0]['hasLaunched'], records
            if scenario == 'account':
                assert report['codex_home'] == str(home / '.codex-work'), report
            (output / f'{case}-launch.json').write_text(json.dumps(report, indent=2))
        if scenario == 'keyboard':
            def discovered():
                with sqlite3.connect(store / 'threading.db') as database:
                    record = json.loads(database.execute('SELECT data FROM session').fetchone()[0])
                return record if record.get('agentSessionID') == report['provider_id'] else None
            eventually(discovered, 'provider identity recorded')
            xdo('key', 'q')
            eventually(lambda: 'exited' in xdo('getwindowname', window), 'first child exited')
            process.terminate(); process.wait(timeout=5); process = None
            window_log = output / 'codex-resume.log'
            with window_log.open('w') as log:
                process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            app = eventually(application, 'resume application')
            window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                '--name', '^Threading'), 'resume window').splitlines()[0]
            xdo('windowfocus', '--sync', window)
            open_saved_agents(lambda key: xdo('key', key))
            xdo('key', 'Return')
            resume_path = project / 'model-resume.json'
            resumed = eventually(lambda: json.loads(resume_path.read_text()) if resume_path.exists() else None, 'resume')
            args = resumed['argv']
            assert args[args.index('--model') + 1] == expected_model, resumed
            assert f'model_reasoning_effort="{expected_effort}"' in args, resumed
            assert args[-2:] == ['resume', report['provider_id']], resumed
            xdo('key', 'q')
        if scenario == 'remember':
            preference = directory / 'data/new-session-run-choice.json'
            def remembered_choice():
                if not preference.exists():
                    return None
                accounts = json.loads(preference.read_text())['accounts']
                if len(accounts) != 1:
                    return None
                return next(iter(accounts.values()))
            assert eventually(remembered_choice, 'accepted account choice') == {
                'model': 'model-beta', 'reasoningEffort': 'high'}

            def restart(label):
                global process, app, editor, window, window_log
                process.terminate(); process.wait(timeout=5); process = None
                window_log = output / f'{case}-{label}.log'
                with window_log.open('w') as log:
                    process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
                app = eventually(application, label + ' application')
                window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                    '--name', '^Threading').splitlines()[0], label + ' window')
                xdo('windowfocus', '--sync', window)

            restart('remembered')
            editor = eventually(lambda: control('linux.composer.editor'), 'restarted composer editor')
            chip = eventually(lambda: control('linux.composer.model-effort'), 'remembered model chip')
            eventually(lambda: 'Beta · High' in chip.get_name(), 'restored account run choice')
            capture('codex-remembered-choice')
            select_account('codex-work')
            eventually(lambda: 'Work default' in chip.get_name(), 'other account keeps its own default')
            assert control('linux.composer.provider').get_action_iface().do_action(0)
            identity_menu = eventually(lambda: control('linux.composer.choices'), 'identity menu')
            assert identity_menu.get_child_at_index(0).get_action_iface().do_action(0)
            eventually(lambda: 'Beta · High' in chip.get_name(), 'restored original account choice')
            open_models()
            select_cell('Alpha · Auto')
            eventually(lambda: 'Alpha' in chip.get_name(), 'automatic model choice')
            assert editor.get_editable_text_iface().set_text_contents('Clear remembered choice')
            assert control('linux.placeholder.action').get_action_iface().do_action(0)
            def cleared_choice():
                if not preference.exists():
                    return False
                with sqlite3.connect(store / 'threading.db') as database:
                    count = database.execute('SELECT COUNT(*) FROM session').fetchone()[0]
                return count == 2 and json.loads(preference.read_text())['accounts'] == {}
            eventually(cleared_choice, 'automatic choice cleared after accepted creation')
            restart('cleared')
            eventually(lambda: control('linux.composer.editor'), 'cleared composer editor')
            chip = eventually(lambda: control('linux.composer.model-effort'), 'cleared model chip')
            eventually(lambda: 'Alpha' in chip.get_name() and 'Beta' not in chip.get_name(),
                       'provider default restored after restart')
            capture('codex-cleared-choice')
        process.terminate(); process.wait(timeout=5); process = None
        print(f'PASS model/effort {case}: real grid, exact account, persistence and launch', flush=True)
finally:
    for child in (process, daemon_process):
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=5)
