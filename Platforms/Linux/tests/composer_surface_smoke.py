"""Create a native conversation from the standing composer and deliver its opening brief."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, daemon, endpoint, fixture, evidence, *selected = sys.argv[1:]
provider = selected[0] if selected else 'codex'
mode = selected[1] if len(selected) > 1 else 'baseline'
assert provider in ('codex', 'claude')
assert mode in ('baseline', 'speed-terminal', 'speed-native', 'speed-live',
                'configuration-live', 'remember-native', 'context', 'attachment', 'checkout')
scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
inherited_mode = os.environ.get('THREADING_TEST_INHERITED_MODE') == '1'
last_used_mode = os.environ.get('THREADING_TEST_LAST_USED_MODE') == '1'
observed_mode = os.environ.get('THREADING_TEST_OBSERVED_MODE') == '1'
assert not last_used_mode or provider == 'claude'
assert not observed_mode or (provider == 'claude' and mode == 'baseline')
root = Path(fixture) / (f'composer-surface-{provider}-{mode}'
    + ('-inherited' if inherited_mode else '') + ('-last-used' if last_used_mode else '')
    + ('-observed' if observed_mode else ''))
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store, project, home = root / 'store', root / 'Project', root / 'home'
project.mkdir(); home.mkdir()
if mode != 'baseline' or inherited_mode or last_used_mode:
    if provider == 'codex':
        account = home / '.codex'
        account.mkdir()
        config = 'model = "speed-model"\nservice_tier = "priority"\n'
        if inherited_mode:
            config += 'approval_policy = "untrusted"\nsandbox_mode = "read-only"\n'
        (account / 'config.toml').write_text(config)
        models = [dict(slug='speed-model', display_name='Speed Model', visibility='list',
            service_tiers=[dict(id='priority', name='Fast')], default_service_tier='default',
            default_reasoning_level='medium', supported_reasoning_levels=[
                dict(effort='low', description='Quick'), dict(effort='medium', description='Balanced')])]
        if mode in ('configuration-live', 'remember-native'):
            models.append(dict(slug='other-model', display_name='Other Model', visibility='list',
                default_reasoning_level='medium', supported_reasoning_levels=[
                    dict(effort='medium', description='Balanced'),
                    dict(effort='high', description='Thorough')]))
            models += [dict(slug=f'extra-model-{index}', display_name=f'Extra Model {index}',
                visibility='list') for index in range(2, 14)]
        (account / 'models_cache.json').write_text(json.dumps(dict(models=models)))
    else:
        account = home / '.claude'
        account.mkdir()
        settings = dict(model='opus', fastMode=True)
        if inherited_mode:
            settings['permissions'] = dict(defaultMode='plan')
        (account / 'settings.json').write_text(json.dumps(settings))
        if last_used_mode:
            recent = account / 'projects' / 'recent'
            recent.mkdir(parents=True)
            (recent / 'conversation.jsonl').write_text(
                '{"type":"permission-mode","permissionMode":"manual"}\n'
                '{"type":"permission-mode","permissionMode":"auto"}\n')
subprocess.run([host, '--add-project', str(store), str(project)], check=True, timeout=8)
if mode == 'checkout':
    sibling = root / 'FeatureCheckout'
    for arguments in [
        ['git', 'init', '-b', 'main', str(project)],
        ['git', '-C', str(project), 'config', 'user.name', 'Fixture'],
        ['git', '-C', str(project), 'config', 'user.email', 'fixture@example.invalid'],
    ]:
        subprocess.run(arguments, check=True, capture_output=True, timeout=8)
    (project / 'README').write_text('checkout fixture\n')
    for arguments in [
        ['git', '-C', str(project), 'add', 'README'],
        ['git', '-C', str(project), 'commit', '-m', 'Initial'],
        ['git', '-C', str(project), 'worktree', 'add', '-b', 'feature', str(sibling)],
    ]:
        subprocess.run(arguments, check=True, capture_output=True, timeout=8)
    subprocess.run([host, '--add-project', str(store), str(sibling)], check=True, timeout=8)
peer = root / (provider + '-peer')
codex_peer = '''#!/usr/bin/python3
import json, os, sys, uuid
from pathlib import Path
Path('surface-launch.json').write_text(json.dumps({'args': sys.argv[1:]}))
if 'app-server' not in sys.argv[1:]: sys.exit(0)
thread = str(uuid.uuid4())
turn = 0
def emit(value): print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': emit({'id': request['id'], 'result': {}})
    elif method == 'initialized': pass
    elif method == 'thread/start':
        emit({'id': request['id'], 'result': {'thread': {'id': thread, 'model': 'fixture'}}})
    elif method == 'skills/list':
        emit({'id': request['id'], 'result': {'data': [{'cwd': os.getcwd(), 'skills': [], 'errors': []}]}})
    elif method == 'turn/start':
        turn += 1
        prompt = request['params']['input'][0]['text']
        with Path('surface-turns.jsonl').open('a') as target:
            target.write(json.dumps({'prompt': prompt, 'thread': thread,
                'serviceTier': request['params'].get('serviceTier'),
                'model': request['params'].get('model'),
                'effort': request['params'].get('effort')}) + '\\n')
        emit({'id': request['id'], 'result': {'turn': {'id': 'first'}}})
        emit({'method': 'turn/started', 'params': {'threadId': thread, 'turn': {'id': 'first'}}})
        emit({'method': 'item/agentMessage/delta', 'params': {'threadId': thread,
              'turnId': 'first', 'delta': 'Native answer'}})
        emit({'method': 'item/completed', 'params': {'threadId': thread, 'turnId': 'first',
              'item': {'type': 'agentMessage', 'id': 'answer', 'text': 'Native answer'}}})
        if os.environ.get('THREADING_TEST_CONTEXT_METER') == '1' and turn == 2:
            emit({'method': 'thread/tokenUsage/updated', 'params': {'threadId': thread,
                'turnId': 'first', 'tokenUsage': {'last': {'totalTokens': 950,
                    'outputTokens': 25}, 'total': {}, 'modelContextWindow': 1000}}})
        emit({'method': 'turn/completed', 'params': {'threadId': thread,
              'turn': {'id': 'first', 'status': 'completed', 'items': []}}})
    elif method == 'turn/interrupt': emit({'id': request['id'], 'result': {}})
    else: raise AssertionError(request)
'''
claude_peer = '''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
Path('surface-launch.json').write_text(json.dumps({'args': args}))
if '--print' not in args: sys.exit(0)
for flag in ('--print', '--verbose', '--include-partial-messages'):
    assert flag in args, args
assert args[args.index('--input-format') + 1] == 'stream-json', args
assert args[args.index('--output-format') + 1] == 'stream-json', args
thread = args[args.index('--session-id') + 1]
turn = 0
def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
for line in sys.stdin:
    message = json.loads(line)
    if message.get('type') == 'control_request':
        with Path('surface-control.jsonl').open('a') as target:
            target.write(json.dumps(message) + '\\n')
        emit({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': message['request_id'], 'response': {'commands': []}}})
        continue
    assert message.get('type') == 'user', message
    turn += 1
    prompt = ''.join(block['text'] for block in message['message']['content']
                     if block.get('type') == 'text')
    with Path('surface-turns.jsonl').open('a') as target:
        target.write(json.dumps({'prompt': prompt, 'thread': thread}, ensure_ascii=False) + '\\n')
    if os.environ.get('THREADING_TEST_OBSERVED_MODE') == '1':
        turn_count = len(Path('surface-turns.jsonl').read_text().splitlines())
        posture = 'manual' if turn_count == 1 else 'auto'
        slug = ''.join(character if character.isascii() and character.isalnum()
            else '-' for character in os.getcwd())
        transcript = Path.home() / '.claude' / 'projects' / slug / (thread + '.jsonl')
        transcript.parent.mkdir(parents=True, exist_ok=True)
        with transcript.open('a') as target:
            target.write(json.dumps({'type': 'permission-mode', 'permissionMode': posture}) + '\\n')
    emit({'type': 'system', 'subtype': 'init', 'session_id': thread, 'model': 'fixture'})
    emit({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Native answer'}]}})
    result = {'type': 'result', 'subtype': 'success', 'result': 'Native answer',
          'is_error': False, 'session_id': thread, 'duration_ms': 10}
    if os.environ.get('THREADING_TEST_CONTEXT_METER') == '1' and turn == 2:
        result['usage'] = {'input_tokens': 100, 'cache_read_input_tokens': 200,
            'cache_creation_input_tokens': 300, 'output_tokens': 10}
    emit(result)
'''
peer.write_text(codex_peer if provider == 'codex' else claude_peer)
peer.chmod(0o700)
Atspi.init()
process = daemon_process = drag_source = None
window_log = output / 'window.log'


def eventually(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None:
            assert process.poll() is None, f'{label}: {window_log.read_text()[-5000:]}'
        try:
            value = read()
        except (IndexError, subprocess.CalledProcessError):
            value = None
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{label}: {window_log.read_text()[-5000:]}')


def descendants(node):
    if node is None:
        return
    yield node
    for index in range(node.get_child_count()):
        yield from descendants(node.get_child_at_index(index))


def control(identity):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() == process.pid:
            return next((node for node in descendants(app)
                         if node.get_accessible_id() == identity), None)
    return None


def xdo(*arguments):
    return subprocess.check_output(['xdotool', *map(str, arguments)], text=True, timeout=5).strip()


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


try:
    (root / 'daemon').mkdir()
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', endpoint,
                                           '--state', str(root / 'daemon')], stdout=log, stderr=log)
    eventually(lambda: Path(endpoint).exists(), 'daemon socket')
    command = [binary, '--app-agents-project', str(store), endpoint, '/bin/sh',
               str(peer), str(peer), str(project)]
    environment = dict(os.environ, HOME=str(home))
    if mode == 'context':
        environment['THREADING_TEST_CONTEXT_METER'] = '1'
    if mode == 'remember-native':
        environment['THREADING_LINUX_DATA_DIR'] = str(root / 'data')
    with window_log.open('w') as log:
        process = subprocess.Popen(command, env=environment,
                                   stdout=log, stderr=log)
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                     '--name', '^Threading experiment - ').splitlines()[0], 'window')
    xdo('windowfocus', '--sync', window)
    if mode == 'baseline':
        eventually(lambda: control('linux.composer.project'), 'opening composer controls')
        capture('opening-composer.png')
    if mode == 'checkout':
        location = eventually(lambda: control('linux.composer.project'), 'location chip')
        eventually(lambda: location.get_name() == 'Project: Project › main', 'main branch')
        assert location.get_action_iface().do_action(0)
        checkouts = eventually(lambda: control('linux.composer.choices'), 'checkout choices')
        sibling_row = next(checkouts.get_child_at_index(index)
            for index in range(checkouts.get_child_count())
            if checkouts.get_child_at_index(index).get_name() == 'feature')
        assert sibling_row.get_action_iface().do_action(0)
        eventually(lambda: location.get_name() == 'Project: Project › feature', 'sibling branch')
        project = sibling
        capture('native-checkout-selected.png')
    if provider == 'claude':
        identity = eventually(lambda: control('linux.composer.provider'), 'Identity chip')
        assert identity.get_action_iface().do_action(0)
        menu = eventually(lambda: control('linux.composer.choices'), 'Identity menu')
        row = next(menu.get_child_at_index(i) for i in range(menu.get_child_count())
                   if menu.get_child_at_index(i).get_name() == 'Claude Code')
        assert row.get_action_iface().do_action(0)
        eventually(lambda: identity.get_name() == 'Identity: Claude Code', 'Claude identity')
    permission_chip = eventually(lambda: control('linux.composer.permissions'), 'opening permission chip')
    inherited_title = ('Manual' if provider == 'codex' else 'Plan') if inherited_mode else "Agent's Setting"
    eventually(lambda: permission_chip.get_name() == f'Permissions: {inherited_title}',
        'opening inherited permission title')
    assert permission_chip.get_action_iface().do_action(0)
    opening_modes = eventually(lambda: control('linux.composer.choices'), 'opening permission choices')
    if inherited_mode:
        expected_default = 'Manual  (default)' if provider == 'codex' else 'Plan  (default)'
        assert any(opening_modes.get_child_at_index(i).get_name() == expected_default
            for i in range(opening_modes.get_child_count()))
    else:
        assert opening_modes.get_child_at_index(0).get_name() == "Use Agent's Setting"
    if last_used_mode and not inherited_mode:
        remembered = next(opening_modes.get_child_at_index(i)
            for i in range(opening_modes.get_child_count())
            if opening_modes.get_child_at_index(i).get_name() == 'Auto  (last used)')
        assert remembered.get_action_iface().do_action(0)
        eventually(lambda: permission_chip.get_name() == 'Permissions: Auto', 'pin last used mode')
        assert permission_chip.get_action_iface().do_action(0)
        opening_modes = eventually(lambda: control('linux.composer.choices'), 'reopened permission choices')
        assert opening_modes.get_child_at_index(0).get_action_iface().do_action(0)
        eventually(lambda: permission_chip.get_name() == "Permissions: Agent's Setting",
            'restore provider inheritance')
        assert permission_chip.get_action_iface().do_action(0)
        opening_modes = eventually(lambda: control('linux.composer.choices'), 'restored permission choices')
    if last_used_mode and inherited_mode:
        assert all('(last used)' not in opening_modes.get_child_at_index(i).get_name()
            for i in range(opening_modes.get_child_count()))
    capture('opening-mode-menu.png')
    xdo('key', 'Escape')
    if mode in ('speed-terminal', 'speed-native', 'speed-live', 'configuration-live'):
        speed = eventually(lambda: control('linux.composer.speed'), 'Speed chip')
        assert speed.get_name() == 'Speed: Fast', speed.get_name()
        assert speed.get_action_iface().do_action(0)
        speed_menu = eventually(lambda: control('linux.composer.choices'), 'Speed menu')
        assert speed_menu.get_name() == 'Speed'
        assert [speed_menu.get_child_at_index(i).get_name() for i in range(3)] == [
            'Follow Agent Setting', 'Standard', 'Fast']
        capture('speed-menu.png')
        speed_index = 1 if mode == 'speed-terminal' else 2
        assert speed_menu.get_child_at_index(speed_index).get_action_iface().do_action(0)
        eventually(lambda: speed.get_name() ==
                   ('Speed: Standard' if speed_index == 1 else 'Speed: Fast'), 'selected speed')
        if mode == 'speed-terminal':
            assert speed.get_action_iface().do_action(0)
            inherited = eventually(lambda: control('linux.composer.choices'), 'inheritance menu')
            assert inherited.get_child_at_index(0).get_action_iface().do_action(0)
            eventually(lambda: speed.get_name() == 'Speed: Fast', 'restored agent speed')
            assert speed.get_action_iface().do_action(0)
            standard = eventually(lambda: control('linux.composer.choices'), 'Standard menu')
            assert standard.get_child_at_index(1).get_action_iface().do_action(0)
            eventually(lambda: speed.get_name() == 'Speed: Standard', 'restored Standard override')
        capture('speed-selected.png')
        xdo('windowsize', window, 560 * scale, 180 * scale)
        eventually(lambda: 'IDLE_PANE_FRAME' in window_log.read_text(), 'compact form')
        time.sleep(.15)
        footer = [control('linux.composer.model-effort'),
                  control('linux.composer.permissions'), speed,
                  control('linux.composer.surface')]
        bounds = [node.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                  for node in footer]
        assert all(left.x + left.width <= right.x for left, right in zip(bounds, bounds[1:])), bounds
        capture('speed-compact.png')
        xdo('windowsize', window, 960 * scale, 600 * scale)
    if mode == 'speed-terminal':
        editor = eventually(lambda: control('linux.composer.editor'), 'opening editor')
        assert editor.get_editable_text_iface().set_text_contents('Speed terminal brief')
        action = eventually(lambda: control('linux.placeholder.action'), 'Start Session')
        assert action.get_action_iface().do_action(0)
        launch = eventually(lambda: json.loads((project / 'surface-launch.json').read_text())
                            if (project / 'surface-launch.json').exists() else None, 'terminal launch')
        args = launch['args']
        if provider == 'codex':
            assert 'service_tier="default"' in args, args
        else:
            settings = Path(args[args.index('--settings') + 1])
            assert json.loads(settings.read_text()) == {'fastMode': False}
            assert settings.stat().st_mode & 0o777 == 0o600
        with sqlite3.connect(store / 'threading.db') as database:
            sessions = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
        assert len(sessions) == 1 and sessions[0]['fastMode'] is False, sessions
        print(f'PASS {provider} Standard terminal speed: command and durable session')
        sys.exit(0)
    if mode == 'remember-native':
        model = eventually(lambda: control('linux.composer.model-effort'), 'opening model chip')
        eventually(lambda: model.get_state_set().contains(Atspi.StateType.ENABLED), 'model catalogue')
        assert model.get_action_iface().do_action(0)
        choices = eventually(lambda: control('linux.composer.choices'), 'opening model choices')
        chosen = next(choices.get_child_at_index(i) for i in range(choices.get_child_count())
            if choices.get_child_at_index(i).get_name() == 'Other Model · High')
        assert chosen.get_action_iface().do_action(0)
        eventually(lambda: 'Other Model · High' in model.get_name(), 'explicit opening model')
        capture('opening-remembered-model.png')
    chip = eventually(lambda: control('linux.composer.surface'), 'Interface chip')
    terminal_title = 'Codex UI' if provider == 'codex' else 'Claude Code UI'
    assert chip.get_name() == f'Interface: {terminal_title}', chip.get_name()
    editor = eventually(lambda: control('linux.composer.editor'), 'opening editor')
    action = eventually(lambda: control('linux.placeholder.action'), 'Start Session')
    bounds = chip.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    assert bounds.width > 50 * scale and bounds.height == 26 * scale, bounds
    capture('terminal-choice.png')
    assert chip.get_action_iface().do_action(0)
    menu = eventually(lambda: control('linux.composer.choices'), 'Interface menu')
    assert menu.get_name() == 'Interface'
    assert [menu.get_child_at_index(i).get_name() for i in range(menu.get_child_count())] == [
        terminal_title, 'Native (Experimental)']
    capture('interface-menu.png')
    assert menu.get_child_at_index(1).get_action_iface().do_action(0)
    eventually(lambda: chip.get_name() == 'Interface: Native (Experimental)', 'native choice')
    prompt = 'Fresh native brief 日本語 café 👩🏽‍🚀'
    assert editor.get_editable_text_iface().set_text_contents(prompt)
    eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED), 'submit enabled')
    capture('native-choice.png')
    assert action.get_action_iface().do_action(0)
    eventually(lambda: 'NATIVE_CREATION_COMMITTED ' in window_log.read_text(), 'durable creation')
    turns = project / 'surface-turns.jsonl'
    eventually(lambda: turns.exists() and turns.read_text().strip(), 'opening provider turn')
    assert [json.loads(line)['prompt'] for line in turns.read_text().splitlines()] == [prompt]
    eventually(lambda: 'CONVERSATION_FRAME ' in window_log.read_text(), 'native conversation pane')
    eventually(lambda: any('turns=1 prepared=true' in line and line.endswith('status=Ready')
                           for line in window_log.read_text().splitlines()
                           if line.startswith('CONVERSATION_FRAME ')), 'rendered first reply')
    assert 'TERMINAL_FRAME ' not in window_log.read_text(), 'terminal mounted for native choice'
    with sqlite3.connect(store / 'threading.db') as database:
        sessions = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
    assert len(sessions) == 1 and sessions[0]['nativeUI'] and sessions[0]['kind'] == provider, sessions
    if mode == 'checkout':
        assert sessions[0]['branch'] == 'feature', sessions
    assert sessions[0].get('permissionMode') is None, sessions
    launch_args = json.loads((project / 'surface-launch.json').read_text())['args']
    if provider == 'codex':
        assert '--ask-for-approval' not in launch_args, launch_args
        assert launch_args[launch_args.index('--sandbox') + 1] == 'workspace-write', launch_args
        assert not any(argument.startswith('approvals_reviewer=') for argument in launch_args), launch_args
    else:
        assert '--permission-mode' not in launch_args, launch_args
    if mode in ('speed-native', 'speed-live', 'configuration-live'):
        assert sessions[0]['fastMode'] is True, sessions
        args = json.loads((project / 'surface-launch.json').read_text())['args']
        if provider == 'codex':
            assert 'service_tier="priority"' in args, args
            assert 'features.fast_mode=true' in args, args
            assert json.loads(turns.read_text().splitlines()[0])['serviceTier'] == 'priority'
        else:
            settings = Path(args[args.index('--settings') + 1])
            assert json.loads(settings.read_text()) == {'fastMode': True}
            assert settings.stat().st_mode & 0o777 == 0o600
            controls = [json.loads(line) for line in (project / 'surface-control.jsonl').read_text().splitlines()]
            assert any('apply_flag_settings' in json.dumps(control) for control in controls), controls
    capture('native-first-turn.png')
    if mode == 'attachment':
        image = project / 'native picture.png'
        subprocess.run(['convert', '-size', '120x80', 'xc:#db493f', str(image)], check=True)
        with (output / 'drag-source.log').open('w') as drag_log:
            drag_source = subprocess.Popen(['/usr/bin/python3',
                str(Path(__file__).with_name('gtk_file_drag_source.py')), str(image)],
                stdout=drag_log, stderr=drag_log)
            source_window = eventually(lambda: xdo('search', '--all', '--onlyvisible',
                '--pid', drag_source.pid).splitlines()[0], 'native drag source')
            xdo('windowmove', source_window, 0, 900)
            def composer_frame():
                lines = [line for line in window_log.read_text().splitlines()
                         if line.startswith('COMPOSER_FRAME ')]
                return lines[-1] if lines else ''
            before = composer_frame()
            match = re.search(r'x=(\d+) y=(\d+) width=(\d+) height=(\d+)', before)
            assert match, before
            x, y, width, height = map(int, match.groups())
            xdo('mousemove', '--sync', '--window', source_window, 50, 50)
            xdo('mousedown', 1)
            xdo('mousemove', '--sync', '--window', source_window, 82, 50)
            time.sleep(.2)
            xdo('mousemove', '--sync', '--window', window, x + width // 2, y + height // 2)
            time.sleep(.3)
            xdo('mouseup', 1)
            attached = eventually(lambda: composer_frame() if composer_frame() != before
                and 'enabled=true' in composer_frame() else None, 'native image-only reply')
            drag_source.terminate()
            drag_source.wait(timeout=5)
            drag_source = None
            xdo('windowraise', window)
            xdo('windowfocus', '--sync', window)
            time.sleep(.2)
            capture('native-image-attached.png')
            send = re.search(r'send=(\d+),(\d+)', attached)
            assert send, attached
            xdo('mousemove', '--window', window, *map(int, send.groups()))
            xdo('click', 1)
            def image_turn():
                parsed = [json.loads(line) for line in turns.read_text().splitlines()]
                return parsed if len(parsed) == 2 else None
            replies = eventually(image_turn, 'native image path reached provider')
            assert replies[1]['prompt'] == f'"{image}"', replies
            eventually(lambda: any('turns=2 prepared=true' in line
                for line in window_log.read_text().splitlines()
                if line.startswith('CONVERSATION_FRAME ')), 'native attached reply rendered')
            capture('native-image-sent.png')
            subprocess.run(['xclip', '-selection', 'clipboard', '-t', 'image/png', '-i'],
                           input=image.read_bytes(), check=True, timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            eventually(lambda: 'image/png' in subprocess.check_output(
                ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
                text=True, timeout=5), 'native PNG clipboard owner')
            xdo('mousemove', '--window', window, x + width // 2, y + height // 2)
            xdo('click', 1)
            before = composer_frame()
            xdo('key', '--clearmodifiers', 'ctrl+v')
            attached = eventually(lambda: composer_frame() if composer_frame() != before
                and 'enabled=true' in composer_frame() else None, 'native pasted image reply')
            capture('native-image-pasted.png')
            remove = eventually(lambda: control('linux.conversation.attachment.remove.0'),
                                'native accessible attachment removal')
            assert remove.get_name().startswith('Remove threading-attachment-')
            assert remove.get_name().endswith('.png')
            assert remove.get_action_iface().do_action(0)
            eventually(lambda: 'enabled=false' in composer_frame(),
                       'native accessible removal disables empty reply')
            eventually(lambda: control('linux.conversation.attachments') is None,
                       'native accessible rail retires after removal')
            assert remove.get_action_iface().get_n_actions() == 0
            before = composer_frame()
            xdo('key', '--clearmodifiers', 'ctrl+v')
            attached = eventually(lambda: composer_frame() if composer_frame() != before
                and 'enabled=true' in composer_frame() else None,
                'native image can be pasted again after accessible removal')
            remove.get_action_iface().do_action(0)
            time.sleep(.2)
            assert 'enabled=true' in composer_frame(), 'retired removal affected a later image'
            send = re.search(r'send=(\d+),(\d+)', attached)
            assert send, attached
            xdo('mousemove', '--window', window, *map(int, send.groups()))
            xdo('click', 1)
            pasted = eventually(lambda: [json.loads(line) for line in turns.read_text().splitlines()]
                if len(turns.read_text().splitlines()) == 3 else None,
                'native pasted image reached provider')
            pasted_path = Path(pasted[2]['prompt'].strip('"'))
            assert pasted_path.name.startswith('threading-attachment-'), pasted
            assert pasted_path.read_bytes() == image.read_bytes()
            capture('native-image-paste-sent.png')
            eventually(lambda: any('turns=3' in line and 'status=Ready' in line
                for line in window_log.read_text().splitlines()
                if line.startswith('CONVERSATION_FRAME ')), 'third image reply settled')
            tiff = root / 'clipboard.tiff'
            subprocess.run(['convert', str(image), str(tiff)], check=True, timeout=5)
            subprocess.run(['xclip', '-selection', 'clipboard', '-t', 'image/tiff', '-i'],
                           input=tiff.read_bytes(), check=True, timeout=5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            eventually(lambda: 'image/tiff' in subprocess.check_output(
                ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
                text=True, timeout=5), 'native TIFF clipboard owner')
            xdo('mousemove', '--window', window, x + width // 2, y + height // 2)
            xdo('click', 1)
            before = composer_frame()
            xdo('key', '--clearmodifiers', 'ctrl+v')
            attached = eventually(lambda: composer_frame() if composer_frame() != before
                and 'enabled=true' in composer_frame() else None, 'native TIFF reply')
            capture('native-tiff-pasted.png')
            frame = re.search(r'x=(\d+) y=(\d+) width=(\d+) height=(\d+)', attached)
            assert frame, attached
            composer_x, composer_y, _, composer_height = map(int, frame.groups())
            xdo('mousemove', '--window', window, composer_x + 120 * scale,
                composer_y + composer_height - 55 * scale)
            xdo('click', 1)
            eventually(lambda: 'focused=true' in composer_frame(),
                       'native TIFF editor focus')
            xdo('key', 'Return')
            tiff_turns = eventually(lambda: [json.loads(line) for line in turns.read_text().splitlines()]
                if len(turns.read_text().splitlines()) == 4 else None,
                'native converted TIFF reached provider')
            converted_path = Path(tiff_turns[3]['prompt'].strip('"'))
            assert converted_path.suffix == '.png', tiff_turns
            assert converted_path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
            pixel = lambda path: subprocess.check_output(
                ['convert', str(path), '-alpha', 'off', '-format', '%[pixel:p{0,0}]', 'info:'],
                text=True, timeout=5).strip()
            assert pixel(converted_path) == pixel(image)
    if mode == 'context':
        assert control('linux.conversation.context') is None, 'context appeared without provider usage'
        xdo('type', '--clearmodifiers', '--delay', '5', 'Second context turn')
        xdo('key', 'Return')
        eventually(lambda: len(turns.read_text().splitlines()) == 2, 'second context turn')
        expected = '95% context' if provider == 'codex' else '610 context'
        context = eventually(lambda: control('linux.conversation.context'), 'reply context meter')
        eventually(lambda: context.get_name() == expected, 'provider context reading')
        assert context.get_role_name() == 'label', context.get_role_name()
        bounds = context.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert bounds.width > 0 and bounds.x > 300 * scale, (
            bounds.x, bounds.y, bounds.width, bounds.height)
        capture('native-context-light.png')
        if provider == 'codex':
            frames = window_log.read_text().count('CONVERSATION_FRAME ')
            xdo('windowsize', window, 560 * scale, 180 * scale)
            eventually(lambda: window_log.read_text().count('CONVERSATION_FRAME ') > frames,
                'compact context frame')
            compact = eventually(lambda: control('linux.conversation.context'), 'compact context meter')
            compact_bounds = compact.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            assert compact.get_name() == expected and compact_bounds.width > 0
            assert compact_bounds.x + compact_bounds.width <= 560 * scale, (
                compact_bounds.x, compact_bounds.width)
            capture('native-context-compact.png')
            xdo('windowsize', window, 1120 * scale, 480 * scale)
            xdo('key', 'ctrl+shift+t')
            eventually(lambda: 'THEME_APPEARANCE dark' in window_log.read_text(), 'dark context theme')
            def dark_context_frame():
                capture('native-context-dark.png')
                image = output / 'native-context-dark.png'
                width, height = map(int, subprocess.check_output(
                    ['identify', '-format', '%w %h', str(image)], text=True).split())
                red = float(subprocess.check_output(['convert', str(image), '-format',
                    f'%[fx:p{{{width - 10},{height // 2}}}.r]', 'info:'], text=True))
                return red < 0.2
            eventually(dark_context_frame, 'dark context render')
        xdo('type', '--clearmodifiers', '--delay', '5', 'Third context turn')
        xdo('key', 'Return')
        eventually(lambda: len(turns.read_text().splitlines()) == 3, 'third context turn')
        eventually(lambda: any('turns=3 prepared=true' in line and line.endswith('status=Ready')
            for line in window_log.read_text().splitlines() if line.startswith('CONVERSATION_FRAME ')),
            'third context reply')
        assert context.get_name() == expected, 'later turn erased latest reading'
        capture('native-context-retained.png')
    if observed_mode:
        permission = eventually(lambda: control('linux.conversation.mode'), 'observed Mode chip')
        first_title = 'Plan' if inherited_mode else 'Manual'
        eventually(lambda: permission.get_name() == f'Mode: {first_title}', 'first live posture')
        assert permission.get_action_iface().do_action(0)
        observed_menu = eventually(lambda: control('linux.conversation.mode.choices'), 'observed Mode menu')
        if inherited_mode:
            assert any(observed_menu.get_child_at_index(i).get_name() == 'Plan  (default)'
                for i in range(observed_menu.get_child_count()))
            assert all('(last used)' not in observed_menu.get_child_at_index(i).get_name()
                for i in range(observed_menu.get_child_count()))
        else:
            assert observed_menu.get_child_at_index(0).get_name() == "Use Agent's Setting"
            assert any(observed_menu.get_child_at_index(i).get_name() == 'Manual  (last used)'
                for i in range(observed_menu.get_child_count()))
        capture('native-observed-manual.png')
        xdo('key', 'Escape')
        xdo('type', '--clearmodifiers', '--delay', '5', 'Second observed turn')
        xdo('key', 'Return')
        eventually(lambda: len(turns.read_text().splitlines()) == 2, 'second observed provider turn')
        next_title = 'Plan' if inherited_mode else 'Auto'
        eventually(lambda: permission.get_name() == f'Mode: {next_title}', 'updated live posture')
        with sqlite3.connect(store / 'threading.db') as database:
            saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
        assert len(saved) == 1 and saved[0].get('permissionMode') is None, saved
        capture('native-observed-auto.png')
    if mode == 'configuration-live':
        model = eventually(lambda: control('linux.conversation.model'), 'reply Model chip')
        xdo('windowsize', window, 560 * scale, 180 * scale)
        time.sleep(.2)
        permission = eventually(lambda: control('linux.conversation.mode'), 'compact Mode chip')
        footer = [model, permission]
        if provider == 'codex':
            footer.append(eventually(lambda: control('linux.conversation.effort'), 'compact Effort chip'))
        footer.append(eventually(lambda: control('linux.conversation.speed'), 'compact Speed chip'))
        bounds = [node.get_component_iface().get_extents(Atspi.CoordType.WINDOW) for node in footer]
        assert all(left.x + left.width <= right.x for left, right in zip(bounds, bounds[1:])), bounds
        assert all(0 <= bound.x and bound.x + bound.width <= 560 * scale for bound in bounds), bounds
        compact_frame = next(line for line in reversed(window_log.read_text().splitlines())
            if line.startswith('COMPOSER_FRAME '))
        send_x, send_y = map(int, compact_frame.split(' send=')[1].split(' ')[0].split(','))
        assert 0 <= send_x <= 560 * scale and 0 <= send_y <= 180 * scale, compact_frame
        capture('native-compact-configuration.png')
        compact_model_y = bounds[0].y
        xdo('windowsize', window, 960 * scale, 600 * scale)
        def resized_model():
            current = control('linux.conversation.model')
            if current is None:
                return None
            position = current.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            return current if position.y != compact_model_y else None
        model = eventually(resized_model, 'resized reply Model chip')
        assert model.get_action_iface().do_action(0)
        model_menu = eventually(lambda: control('linux.conversation.model.choices'), 'reply Model choices')
        assert model_menu.get_child_count() <= 6, model_menu.get_child_count()
        capture('native-model-menu.png')
        if provider == 'codex':
            xdo('key', 'End')
            eventually(lambda: control('linux.conversation.model.option.13'), 'last virtual model row')
            assert model_menu.get_child_count() <= 6, model_menu.get_child_count()
            capture('native-model-last-page.png')
            xdo('key', 'Home')
            eventually(lambda: control('linux.conversation.model.option.1'), 'first virtual model page')
        chosen = next(model_menu.get_child_at_index(i) for i in range(model_menu.get_child_count())
            if ('Other Model' if provider == 'codex' else 'Sonnet')
            in model_menu.get_child_at_index(i).get_name())
        assert chosen.get_action_iface().do_action(0)
        eventually(lambda: not control('linux.conversation.model.choices'), 'reply Model choices close')
        def saved_model():
            with sqlite3.connect(store / 'threading.db') as database:
                saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
            return len(saved) == 1 and saved[0].get('model') == (
                'other-model' if provider == 'codex' else 'sonnet') and saved[0].get('fastMode') is False
        eventually(saved_model, 'durable reply model and Fast reset')
        capture('native-model-selected.png')
        permission = eventually(lambda: control('linux.conversation.mode'), 'reply Mode chip')
        assert permission.get_name() == f'Mode: {inherited_title}', permission.get_name()
        assert permission.get_action_iface().do_action(0)
        permission_menu = eventually(lambda: control('linux.conversation.mode.choices'), 'reply Mode choices')
        assert permission_menu.get_child_count() <= 6
        if inherited_mode:
            expected_default = 'Manual  (default)' if provider == 'codex' else 'Plan  (default)'
            assert any(permission_menu.get_child_at_index(i).get_name() == expected_default
                for i in range(permission_menu.get_child_count()))
        else:
            assert permission_menu.get_child_at_index(0).get_name() == "Use Agent's Setting"
        if last_used_mode and not inherited_mode:
            assert any(permission_menu.get_child_at_index(i).get_name() == 'Auto  (last used)'
                for i in range(permission_menu.get_child_count()))
        if last_used_mode and inherited_mode:
            assert all('(last used)' not in permission_menu.get_child_at_index(i).get_name()
                for i in range(permission_menu.get_child_count()))
        capture('native-mode-menu.png')
        chosen_mode = 'Auto (Approve for me)' if provider == 'codex' else 'Accept Edits'
        chosen = next(permission_menu.get_child_at_index(i)
            for i in range(permission_menu.get_child_count())
            if permission_menu.get_child_at_index(i).get_name() == chosen_mode)
        assert chosen.get_action_iface().do_action(0)
        eventually(lambda: permission.get_name() == f'Mode: {chosen_mode}', 'selected reply mode')
        def saved_mode():
            with sqlite3.connect(store / 'threading.db') as database:
                saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
            return len(saved) == 1 and saved[0].get('permissionMode') == (
                'auto' if provider == 'codex' else 'acceptEdits')
        eventually(saved_mode, 'durable reply mode')
        if provider == 'codex':
            assert permission.get_action_iface().do_action(0)
            eventually(lambda: control('linux.conversation.mode.choices'), 'record-only Mode menu')
            xdo('key', 'End')
            note_index = 6 if inherited_mode else 7
            note = eventually(lambda: control(f'linux.conversation.mode.option.{note_index}'),
                'next launch Mode note')
            assert note.get_name() == 'Applies the next time this chat starts.'
            assert note.get_action_iface().get_n_actions() == 0
            capture('native-mode-next-launch.png')
            xdo('key', 'Escape')
        else:
            def live_mode():
                controls = [json.loads(line) for line in (project / 'surface-control.jsonl').read_text().splitlines()]
                return any(control.get('request', {}).get('subtype') == 'set_permission_mode'
                    and control.get('request', {}).get('mode') == 'acceptEdits' for control in controls)
            eventually(live_mode, 'Claude live mode control')
        capture('native-mode-selected.png')
        if provider == 'codex':
            effort = eventually(lambda: control('linux.conversation.effort'), 'reply Effort chip')
            assert effort.get_action_iface().do_action(0)
            effort_menu = eventually(lambda: control('linux.conversation.effort.choices'), 'reply Effort choices')
            assert effort_menu.get_child_count() == 3, effort_menu.get_child_count()
            capture('native-effort-menu.png')
            high = next(effort_menu.get_child_at_index(i) for i in range(effort_menu.get_child_count())
                if effort_menu.get_child_at_index(i).get_name() == 'High')
            assert high.get_action_iface().do_action(0)
            eventually(lambda: not control('linux.conversation.effort.choices'), 'reply Effort choices close')
            def saved_effort():
                with sqlite3.connect(store / 'threading.db') as database:
                    saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
                return len(saved) == 1 and saved[0].get('reasoningEffort') == 'high'
            eventually(saved_effort, 'durable reply effort')
            capture('native-effort-selected.png')
        else:
            assert control('linux.conversation.effort') is None
            def live_model():
                controls = [json.loads(line) for line in (project / 'surface-control.jsonl').read_text().splitlines()]
                return any(control.get('request', {}).get('subtype') == 'set_model'
                    and control.get('request', {}).get('model') == 'sonnet' for control in controls)
            eventually(live_model, 'Claude live model control')
        xdo('type', '--clearmodifiers', '--delay', '5', 'Configured native turn')
        xdo('key', 'Return')
        def configured_turn():
            parsed = [json.loads(line) for line in turns.read_text().splitlines()]
            return parsed if len(parsed) == 2 else None
        second = eventually(configured_turn, 'configured provider turn')
        if provider == 'codex':
            assert second[1]['model'] == 'other-model', second
            assert second[1]['effort'] == 'high', second
            assert second[1]['serviceTier'] == 'default', second
        eventually(lambda: any('turns=2 prepared=true' in line for line in window_log.read_text().splitlines()
            if line.startswith('CONVERSATION_FRAME ')), 'rendered configured reply')
        capture('native-configured-turn.png')
        if inherited_mode:
            control_count = len((project / 'surface-control.jsonl').read_text().splitlines()) if provider == 'claude' else 0
            assert permission.get_action_iface().do_action(0)
            inherited_menu = eventually(lambda: control('linux.conversation.mode.choices'), 'inherited Mode menu')
            xdo('key', 'Home')
            expected_default = 'Manual  (default)' if provider == 'codex' else 'Plan  (default)'
            default_row = eventually(lambda: next((inherited_menu.get_child_at_index(i)
                for i in range(inherited_menu.get_child_count())
                if inherited_menu.get_child_at_index(i).get_name() == expected_default), None),
                'default Mode row')
            assert default_row.get_action_iface().do_action(0)
            eventually(lambda: permission.get_name() ==
                ('Mode: Manual' if provider == 'codex' else 'Mode: Plan'), 'inherited Mode title')
            def saved_inherited_mode():
                with sqlite3.connect(store / 'threading.db') as database:
                    saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
                return len(saved) == 1 and saved[0].get('permissionMode') is None
            eventually(saved_inherited_mode, 'durable inherited Mode')
            if provider == 'claude':
                assert len((project / 'surface-control.jsonl').read_text().splitlines()) == control_count
            capture('native-mode-inherited.png')
    if mode == 'speed-live':
        speed = eventually(lambda: control('linux.conversation.speed'), 'native reply Speed chip')
        assert speed.get_name() == 'Speed: Fast', speed.get_name()
        assert speed.get_action_iface().do_action(0)
        menu = eventually(lambda: control('linux.conversation.speed.choices'), 'native Speed menu')
        assert [menu.get_child_at_index(i).get_name() for i in range(3)] == [
            'Follow Agent Setting', 'Standard', 'Fast']
        assert menu.get_child_at_index(2).get_state_set().contains(Atspi.StateType.SELECTED)
        capture('native-speed-menu.png')
        assert menu.get_child_at_index(1).get_action_iface().do_action(0)
        eventually(lambda: speed.get_name() == 'Speed: Standard', 'native Standard selection')
        eventually(lambda: not control('linux.conversation.speed.choices'), 'native Speed menu closed')
        def saved_standard():
            with sqlite3.connect(store / 'threading.db') as database:
                saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
            return len(saved) == 1 and saved[0].get('fastMode') is False
        eventually(saved_standard, 'durable native Standard selection')
        if provider == 'claude':
            def live_standard():
                controls = [json.loads(line) for line in (project / 'surface-control.jsonl').read_text().splitlines()]
                return any(control.get('request', {}).get('subtype') == 'apply_flag_settings'
                           and control.get('request', {}).get('settings', {}).get('fastMode') is False
                           for control in controls)
            eventually(live_standard, 'Claude live Standard control')
        capture('native-speed-standard.png')
        xdo('type', '--clearmodifiers', '--delay', '5', 'Second native turn')
        xdo('key', 'Return')
        def second_turn():
            if not turns.exists(): return None
            parsed = [json.loads(line) for line in turns.read_text().splitlines()]
            return parsed if len(parsed) == 2 else None
        second = eventually(second_turn, 'second native turn')
        assert [turn['prompt'] for turn in second] == [prompt, 'Second native turn'], second
        if provider == 'codex':
            assert second[1]['serviceTier'] == 'default', second
        eventually(lambda: any('turns=2 prepared=true' in line for line in window_log.read_text().splitlines()
                               if line.startswith('CONVERSATION_FRAME ')), 'rendered second reply')
        capture('native-second-turn.png')
        control_count = len((project / 'surface-control.jsonl').read_text().splitlines()) if provider == 'claude' else 0
        assert speed.get_action_iface().do_action(0)
        menu = eventually(lambda: control('linux.conversation.speed.choices'), 'native inheritance menu')
        inherited = menu.get_child_at_index(0).get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        xdo('mousemove', '--window', window, inherited.x + inherited.width // 2,
            inherited.y + inherited.height // 2, 'click', '1')
        eventually(lambda: speed.get_name() == 'Speed: Fast', 'inherited agent speed title')
        def saved_inheritance():
            with sqlite3.connect(store / 'threading.db') as database:
                saved = [json.loads(row[0]) for row in database.execute('SELECT data FROM session')]
            return len(saved) == 1 and saved[0].get('fastMode') is None
        eventually(saved_inheritance, 'durable native inheritance')
        capture('native-speed-inherited.png')
        xdo('type', '--clearmodifiers', '--delay', '5', 'Third native turn')
        xdo('key', 'Return')
        def third_turn():
            parsed = [json.loads(line) for line in turns.read_text().splitlines()]
            return parsed if len(parsed) == 3 else None
        third = eventually(third_turn, 'third native turn')
        assert third[2]['prompt'] == 'Third native turn', third
        if provider == 'codex':
            assert third[2]['serviceTier'] == 'default', third
        else:
            assert len((project / 'surface-control.jsonl').read_text().splitlines()) == control_count
        eventually(lambda: any('turns=3 prepared=true' in line for line in window_log.read_text().splitlines()
                               if line.startswith('CONVERSATION_FRAME ')), 'rendered third reply')
    if mode == 'remember-native':
        assert sessions[0].get('model') == 'other-model', sessions
        assert sessions[0].get('reasoningEffort') == 'high', sessions
        assert launch_args[launch_args.index('--model') + 1] == 'other-model', launch_args
        preference = root / 'data/new-session-run-choice.json'
        def saved_opening_choice():
            if not preference.exists(): return None
            accounts = json.loads(preference.read_text())['accounts']
            return next(iter(accounts.values())) if len(accounts) == 1 else None
        assert eventually(saved_opening_choice, 'native accepted run choice') == {
            'model': 'other-model', 'reasoningEffort': 'high'}
        process.terminate(); process.wait(timeout=5); process = None
        fresh_store, fresh_project = root / 'fresh-store', root / 'FreshProject'
        fresh_project.mkdir()
        subprocess.run([host, '--add-project', str(fresh_store), str(fresh_project)],
            check=True, timeout=8)
        fresh_command = [binary, '--app-agents-project', str(fresh_store), endpoint,
            '/bin/sh', str(peer), str(peer), str(fresh_project)]
        window_log = output / 'native-remembered-restart.log'
        with window_log.open('w') as log:
            process = subprocess.Popen(fresh_command, env=environment, stdout=log, stderr=log)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
            '--name', '^Threading').splitlines()[0], 'restarted window')
        xdo('windowfocus', '--sync', window)
        model = eventually(lambda: control('linux.composer.model-effort'), 'restarted model chip')
        eventually(lambda: 'Other Model · High' in model.get_name(), 'native choice restored')
        capture('native-remembered-model.png')
    print(f'PASS {provider} composer {mode}, AT-SPI menu, durable native session and provider turns')
finally:
    if drag_source is not None:
        drag_source.terminate()
        try: drag_source.wait(timeout=5)
        except subprocess.TimeoutExpired: drag_source.kill(); drag_source.wait(timeout=5)
    if process is not None:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
    if daemon_process is not None:
        daemon_process.terminate()
        try: daemon_process.wait(timeout=5)
        except subprocess.TimeoutExpired: daemon_process.kill(); daemon_process.wait(timeout=5)
