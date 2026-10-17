"""A saved native conversation selected from the ordinary workspace, with a real daemon child."""
from saved_catalog_menu import open_saved_agents, selected_outline_row
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

from runtime_pixel_contract import assert_composer_focus_chrome, assert_sidebar_pane_chrome, assert_sidebar_region_colors

binary, host, daemon, endpoint, fixture, evidence, *selected = sys.argv[1:]
theme = json.loads((Path(binary).parent / 'LinuxAppKitSpike_WindowHarness.resources/Theme/threading.json').read_text())
provider = selected[0] if selected else 'codex'
assert provider in ('codex', 'claude', 'grok', 'cursor'), provider
# The ACP providers are seeded as Codex records and re-kinded below; LinuxHost seeds only the
# two providers it can launch as terminal agents.
seed = provider if provider in ('codex', 'claude') else 'codex'
scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
sidebar_width = 240 * scale
root = Path(fixture) / ('native-workspace' if provider == 'codex' else 'native-workspace-' + provider)
root.mkdir()
store, project, home = root / 'store', root / 'NativeProject', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, seed, str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(nativeUI=True, hasLaunched=False, lastExitCode=None, agentSessionID=None,
                  customTitle='Native conversation', kind=provider)
    if provider == 'cursor':
        # The Codex seed's Manual permission mode is not a Cursor launch setting.
        record.pop('permissionMode', None)
    database.execute('UPDATE session SET data = ?, kind = ? WHERE id = ?', (json.dumps(record), provider, identifier))

peer = root / (provider + '-peer')
codex_peer = r'''#!/usr/bin/python3
import datetime, json, os, sys, uuid
from pathlib import Path
assert 'app-server' in sys.argv and '--listen' in sys.argv and 'stdio://' in sys.argv, sys.argv
assert '--no-alt-screen' not in sys.argv, sys.argv
thread = str(uuid.uuid4())
turn = 0
rollout = None
def record(value):
    with rollout.open('a') as target: target.write(json.dumps(value, ensure_ascii=False) + '\n')
def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
def reply(request, result): emit({'id': request['id'], 'result': result})
def note(method, params): emit({'method': method, 'params': params})
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': reply(request, {})
    elif method == 'initialized': pass
    elif method in ('thread/start', 'thread/resume'):
        if method == 'thread/resume': thread = request['params']['threadId']
        folder = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions' / '2026' / '10' / '09'
        folder.mkdir(parents=True, exist_ok=True)
        rollout = folder / ('rollout-native-' + thread + '.jsonl')
        if not rollout.exists(): record({'type': 'session_meta', 'payload': {'id': thread, 'cwd': os.getcwd()}})
        reply(request, {'thread': {'id': thread, 'model': 'fixture'}})
    elif method == 'skills/list': reply(request, {'data': [{'cwd': os.getcwd(), 'skills': [], 'errors': []}]})
    elif method == 'turn/start':
        turn += 1
        text = request['params']['input'][0]['text']
        with Path('native-turns.jsonl').open('a') as target:
            target.write(json.dumps({'pid': os.getpid(), 'text': text, 'thread': thread}, ensure_ascii=False) + '\n')
        tid = 'turn-' + str(turn)
        reply(request, {'turn': {'id': tid}})
        note('turn/started', {'threadId': thread, 'turn': {'id': tid}})
        answer = f'## Native reply {turn}\n\nUnicode 日本語 café 👩🏽‍🚀 is intact.\n\nYou said: {text}'
        record({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': text}})
        record({'type': 'event_msg', 'payload': {'type': 'agent_message', 'message': answer}})
        note('item/agentMessage/delta', {'threadId': thread, 'turnId': tid, 'delta': answer})
        note('item/completed', {'threadId': thread, 'turnId': tid,
            'item': {'type': 'agentMessage', 'id': 'answer-' + str(turn), 'text': answer}})
        note('turn/completed', {'threadId': thread, 'turn': {'id': tid, 'status': 'completed', 'items': []}})
    elif method == 'turn/interrupt': reply(request, {})
    else: raise AssertionError(request)
'''
# Claude's headless stream-json wire: the capability handshake, then per turn the init record,
# a partial delta, the assistant message and a result, with the dialogue the CLI writes to its
# account transcript so a restart replays it.
claude_peer = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
for flag in ('--print', '--verbose', '--include-partial-messages'): assert flag in args, args
assert args[args.index('--input-format') + 1] == 'stream-json', args
assert args[args.index('--output-format') + 1] == 'stream-json', args
assert 'CLAUDE_CONFIG_DIR' not in os.environ, os.environ['CLAUDE_CONFIG_DIR']
units = os.getcwd().encode('utf-16-le')
codes = [int.from_bytes(units[i:i + 2], 'little') for i in range(0, len(units), 2)]
slug = ''.join(chr(c) if chr(c).isascii() and chr(c).isalnum() else '-' for c in codes)
if '--session-id' in args:
    thread = args[args.index('--session-id') + 1]
elif '--resume' in args:
    thread = args[args.index('--resume') + 1]
else:
    raise AssertionError(args)
transcript = Path.home() / '.claude' / 'projects' / slug / (thread + '.jsonl')
transcript.parent.mkdir(parents=True, exist_ok=True)
if '--resume' in args: assert transcript.exists(), transcript
else: transcript.touch()
def record(value):
    with transcript.open('a') as target: target.write(json.dumps(value, ensure_ascii=False) + '\n')
def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
turn = 0
for line in sys.stdin:
    if not line.strip(): continue
    message = json.loads(line)
    if message.get('type') == 'control_request':
        request = message['request']
        assert request['subtype'] == 'initialize', message
        emit({'type': 'control_response', 'response': {'subtype': 'success',
              'request_id': message['request_id'], 'response': {'commands': []}}})
        continue
    assert message.get('type') == 'user', message
    turn += 1
    text = ''.join(block['text'] for block in message['message']['content'] if block.get('type') == 'text')
    with Path('native-turns.jsonl').open('a') as target:
        target.write(json.dumps({'pid': os.getpid(), 'text': text, 'thread': thread}, ensure_ascii=False) + '\n')
    answer = f'## Native reply {turn}\n\nUnicode 日本語 café 👩🏽‍🚀 is intact.\n\nYou said: {text}'
    record({'type': 'user', 'sessionId': thread, 'message': {'role': 'user', 'content': text}})
    record({'type': 'assistant', 'sessionId': thread, 'message': {'role': 'assistant',
            'content': [{'type': 'text', 'text': answer}]}})
    emit({'type': 'system', 'subtype': 'init', 'session_id': thread, 'model': 'fixture'})
    emit({'type': 'stream_event', 'event': {'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': answer[:18]}}})
    emit({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': answer}]}})
    emit({'type': 'result', 'subtype': 'success', 'result': answer, 'is_error': False,
          'session_id': thread, 'duration_ms': 10})
'''
# The Agent Client Protocol peer for Grok and Cursor: initialize, session/new or session/load,
# then a prompt per turn answered with message chunks. It keeps its own history and replays it on
# load, as the real CLIs do, so a restart shows the conversation the provider remembers.
acp_peer = r'''#!/usr/bin/python3
import json, os, sys, uuid
from pathlib import Path
args = sys.argv[1:]
kind = os.environ['ACP_FIXTURE_KIND']
if kind == 'grok':
    if '--permission-mode' in args:
        mode_index = args.index('--permission-mode')
        assert mode_index == 0 and args[2] == 'agent', args
    else:
        assert args[0] == 'agent', args
    assert args[-1] == 'stdio', args
else:
    assert args == ['acp'], args
    assert os.environ.get('NO_OPEN_BROWSER') == '1', os.environ
history_root = Path(os.environ['HOME']) / '.acp-fixture'
history_root.mkdir(exist_ok=True)
def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
def reply(request, result): emit({'jsonrpc': '2.0', 'id': request['id'], 'result': result})
def chunk(session, update, text):
    emit({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session,
          'update': {'sessionUpdate': update, 'content': {'type': 'text', 'text': text}}}})
session = None
turn = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        reply(request, {'protocolVersion': 1, 'agentCapabilities': {'loadSession': True}})
    elif method == 'session/new':
        session = str(uuid.uuid4())
        reply(request, {'sessionId': session})
    elif method == 'session/load':
        session = request['params']['sessionId']
        history = history_root / (session + '.jsonl')
        assert history.exists(), history
        for entry in history.read_text().splitlines():
            role, text = json.loads(entry)
            chunk(session, 'user_message_chunk' if role == 'user' else 'agent_message_chunk', text)
        reply(request, None)
    elif method == 'session/prompt':
        turn += 1
        text = ''.join(block['text'] for block in request['params']['prompt'] if block.get('type') == 'text')
        with Path('native-turns.jsonl').open('a') as target:
            target.write(json.dumps({'pid': os.getpid(), 'text': text, 'thread': session}, ensure_ascii=False) + '\n')
        answer = f'## Native reply {turn}\n\nUnicode 日本語 café 👩🏽‍🚀 is intact.\n\nYou said: {text}'
        with (history_root / (session + '.jsonl')).open('a') as target:
            target.write(json.dumps(['user', text], ensure_ascii=False) + '\n')
            target.write(json.dumps(['agent', answer], ensure_ascii=False) + '\n')
        chunk(session, 'agent_message_chunk', answer)
        reply(request, {'stopReason': 'end_turn'})
    elif method == 'session/cancel':
        pass
    else:
        raise AssertionError(request)
'''
peer.write_text({'codex': codex_peer, 'claude': claude_peer}.get(provider, acp_peer))
peer.chmod(0o700)
output = Path(evidence)
output.mkdir(parents=True)
log_path = output / 'window.log'
log = log_path.open('w')
if provider in ('grok', 'cursor'):
    # The ACP CLIs reach a saved native conversation through the launcher's environment.
    environment.update({'THREADING_LINUX_' + provider.upper(): str(peer), 'ACP_FIXTURE_KIND': provider})
app_mode = '--app-' + (provider if provider in ('codex', 'claude') else 'codex')
app_agent = str(peer) if provider in ('codex', 'claude') else '/bin/false'
command = [binary, app_mode, str(store), endpoint, '/bin/sh', app_agent]
if environment.get('THREADING_NATIVE_GDB') == '1':
    command = ['gdb', '-q', '-batch', '-ex', 'run', '-ex', 'thread apply all bt', '--args'] + command
process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)


def eventually(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, f'exit={process.returncode}: ' + log_path.read_text()[-6000:]
        try:
            value = read()
            if value:
                return value
        except (FileNotFoundError, json.JSONDecodeError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(label + ': ' + log_path.read_text()[-6000:])


def xdo(*args):
    return subprocess.check_output(['xdotool', *args], text=True, timeout=5).strip()


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '40', value)


def paste(value):
    subprocess.run(['xclip', '-selection', 'clipboard'], input=value.encode(), check=True, timeout=5)
    key('ctrl+v')


def composer_frame():
    frames = [line for line in log_path.read_text().splitlines() if line.startswith('COMPOSER_FRAME ')]
    return dict(part.split('=', 1) for part in frames[-1].split()[1:]) if frames else {}


def click(x, y):
    xdo('mousemove', '--window', window, str(x), str(y), 'click', '1')


def turns():
    return [json.loads(line) for line in (project / 'native-turns.jsonl').read_text().splitlines()]


def ready(turn=0, dark=None):
    # Judge one frame from one read. Combining a prepared frame from one read with a theme
    # from another accepted the light frame before a switch as the dark frame after it.
    frames = [line for line in log_path.read_text().splitlines() if line.startswith('CONVERSATION_FRAME ')]
    return (xdo('getwindowname', window) == 'Threading conversation · Ready' and frames
            and f'turns={turn} prepared=true' in frames[-1] and frames[-1].endswith('status=Ready')
            and (dark is None or f'dark={str(dark).lower()} ' in frames[-1]))


def capture(name):
    # SDL can publish the resized conversation before it repaints the sidebar. Capture only
    # once both retained surfaces report the same appearance and the requested full height.
    def shell_prepared():
        lines = log_path.read_text().splitlines()
        sidebar = conversation = None
        dark = False
        for line in lines:
            if line.startswith('WORKSPACE_GEOMETRY '):
                sidebar = conversation = None
                dark = False
            elif line.startswith('THEME_APPEARANCE '):
                dark = line.endswith('dark')
            elif line.startswith('AGENT_PICKER_FRAME '):
                sidebar = (line.split()[1], 'dark=true' in line)
            elif line.startswith('FRAME '):
                sidebar = (line.split()[1], dark)
            elif line.startswith('CONVERSATION_FRAME '):
                conversation = line
        return (sidebar == (f'{sidebar_width}x900', 'dark=true' in (conversation or ''))
                and conversation and 'prepared=true' in conversation)

    eventually(shell_prepared, 'complete native shell ready for capture')
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


def brightness(path, x, y, width, height, statistic):
    return float(subprocess.check_output(['convert', str(path), '-crop', f'{width}x{height}+{x}+{y}',
        '+repage', '-colorspace', 'Gray', '-format', f'%[fx:{statistic}]', 'info:'], text=True, timeout=5))


def resize_native(turn=0):
    # Selecting a pane applies its initial viewport. Resize after selection so these captures
    # exercise the conversation at the requested height rather than the picker's initial size.
    def sized():
        geometry = xdo('getwindowgeometry', '--shell', window)
        return 'WIDTH=1120' in geometry and 'HEIGHT=900' in geometry

    # A larger centered window can extend below Xvfb's screen; ImageMagick then silently clips
    # the screenshot. Keep the complete product window on screen for inspected evidence.
    xdo('windowmove', window, '0', '0')
    if sized():
        eventually(lambda: ready(turn), 'conversation prepared at requested size')
        return
    previous_frames = log_path.read_text().count('CONVERSATION_FRAME ')
    xdo('windowsize', window, '1120', '900')
    eventually(sized, 'native resize')
    eventually(lambda: log_path.read_text().count('CONVERSATION_FRAME ') > previous_frames and ready(turn),
               'resized conversation prepared')


try:
    # SDL briefly owns a startup window while preparing the workspace. A title search alone
    # can return that soon-destroyed XID; wait for the retained product pane before selecting it.
    eventually(lambda: 'IDLE_PANE_FRAME ' in log_path.read_text(), 'workspace presentation')
    assert f'WORKSPACE_GEOMETRY scale={scale} sidebar={sidebar_width} header={41 * scale}' in log_path.read_text()
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0], 'window')
    xdo('windowsize', window, '1120', '900')
    open_saved_agents(key)
    eventually(lambda: xdo('getwindowname', window).startswith('Threading agents -'), 'saved agent picker')
    key('Return')
    eventually(ready, 'ordinary native pane ready')
    resize_native()
    assert 'TERMINAL_FRAME ' not in log_path.read_text(), 'saved native UI opened an emulator'
    capture('native-ready.png')
    assert_sidebar_pane_chrome(output / 'native-ready.png', sidebar_width, scale)
    assert_sidebar_region_colors(output / 'native-ready.png', theme['light'], scale)
    resting_height = int(composer_frame()['height'])
    assert composer_frame()['enabled'] == 'false', 'empty draft can submit'
    paste('\n'.join(f'Composer growth line {index}' for index in range(12)))
    eventually(lambda: composer_frame().get('scrolls') == 'true', 'long draft reaches scrolling ceiling')
    assert int(composer_frame()['height']) == 180 * scale > resting_height, composer_frame()
    capture('native-composer-grown.png')
    key('ctrl+a')
    key('BackSpace')
    eventually(lambda: composer_frame().get('enabled') == 'false'
               and int(composer_frame()['height']) == resting_height, 'cleared draft returns to resting height')
    first = 'First native prompt 日本語 café 👩🏽‍🚀'
    paste(first)
    eventually(lambda: composer_frame().get('enabled') == 'true', 'draft enables send')
    capture('native-composer-focused.png')
    click(100, 450)
    eventually(lambda: composer_frame().get('focused') == 'false', 'sidebar focus releases reply editor')
    capture('native-composer-unfocused.png')
    assert_composer_focus_chrome(output / 'native-composer-focused.png',
                                output / 'native-composer-unfocused.png', composer_frame(), scale)
    click(*map(int, composer_frame()['send'].split(',')))
    eventually(lambda: len(turns()) == 1, 'first prompt received')
    eventually(lambda: ready(1), 'first native reply')
    assert turns()[0]['text'] == first, turns()
    pid = turns()[0]['pid']
    capture('native-first-reply.png')
    frame = composer_frame()
    click(int(frame['x']) + 24, int(frame['y']) + 24)
    eventually(lambda: composer_frame().get('focused') == 'true', 'pointer focuses reply editor')
    paste('Second line 日本語')
    key('shift+Return')
    paste('Another line café 👩🏽‍🚀')
    key('Return')
    eventually(lambda: len(turns()) == 2, 'multiline second prompt')
    eventually(lambda: ready(2), 'second native reply')
    assert turns()[1]['text'] == 'Second line 日本語\nAnother line café 👩🏽‍🚀', turns()
    assert turns()[1]['pid'] == pid, 'turn replaced the persistent child'
    key('ctrl+shift+t')
    eventually(lambda: ready(2, dark=True), 'dark theme')
    capture('native-dark.png')
    assert_sidebar_pane_chrome(output / 'native-dark.png', sidebar_width, scale)
    assert_sidebar_region_colors(output / 'native-dark.png', theme['dark'], scale)
    # Sample the navigator and the status strip below the measured composer.
    assert brightness(output / 'native-dark.png', 20, 200, sidebar_width - 40, 100, 'mean') < .2, 'sidebar stayed light'
    frame = composer_frame()
    status_top = int(frame['y']) + int(frame['height']) + 6 * scale
    assert brightness(output / 'native-dark.png', int(frame['x']), status_top,
                      int(frame['width']), 22 * scale, 'maxima') > .5, 'status ink stayed dark'

    draft = 'Retained draft 日本語 café'
    paste(draft)
    key('ctrl+a')
    key('ctrl+c')
    assert subprocess.check_output(['xclip', '-selection', 'clipboard', '-o'], text=True, timeout=5) == draft
    key('Right')
    key('ctrl+shift+p')
    key('Escape')
    key('Return')
    eventually(lambda: 'TERMINAL_FRAME ' in log_path.read_text(), 'project terminal beside conversation')
    key('ctrl+shift+p')
    open_saved_agents(key)
    key('Return')
    eventually(lambda: ready(2), 'retained native pane')
    key('Return')
    eventually(lambda: len(turns()) == 3, 'retained draft sent')
    eventually(lambda: ready(3), 'third native reply')
    assert turns()[2]['text'] == draft and turns()[2]['pid'] == pid, turns()
    with sqlite3.connect(store / 'threading.db') as database:
        saved = json.loads(database.execute('SELECT data FROM session WHERE id = ?', (identifier,)).fetchone()[0])
        assert saved['nativeUI'] and saved['hasLaunched'] and saved['agentSessionID'] == turns()[0]['thread'], saved
    records = json.loads(subprocess.check_output([daemon, 'sessions', '--json', '--socket', endpoint], text=True, timeout=5))
    owned = next(item for item in records if item['id'] == identifier)
    assert owned['pid'] == pid, records
    capture('native-return.png')
    key('alt+F4')
    assert process.wait(timeout=8) == 0
    # Reopening the selected conversation must reveal it even if its project was folded away.
    with sqlite3.connect(store / 'threading.db') as database:
        project_id, payload = database.execute('SELECT id,data FROM project').fetchone()
        project_record = json.loads(payload)
        project_record['isExpanded'] = False
        database.execute('UPDATE project SET data=? WHERE id=?', (json.dumps(project_record), project_id))
    previous_frames = log_path.read_text().count('CONVERSATION_FRAME ')
    process = subprocess.Popen([binary, app_mode, str(store), endpoint, '/bin/sh', app_agent],
                               env=environment, stdout=log, stderr=log)
    eventually(lambda: log_path.read_text().count('CONVERSATION_FRAME ') > previous_frames,
               'reopened conversation presentation')
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0], 'reopened window')
    xdo('windowsize', window, '1120', '900')
    eventually(ready, 'replayed native conversation after restart')
    resize_native()
    eventually(lambda: selected_outline_row(process.pid, identifier), 'restored conversation selected in ordinary outline')
    eventually(lambda: 'OUTLINE_EXPANSION_SAVED ' in log_path.read_text(), 'restored conversation parent expansion persisted')
    with sqlite3.connect(store / 'threading.db') as database:
        assert json.loads(database.execute('SELECT data FROM project WHERE id=?', (project_id,)).fetchone()[0])['isExpanded']
    frames = [line for line in log_path.read_text().splitlines() if line.startswith('CONVERSATION_FRAME ')]
    assert int(frames[-1].split('rows=')[1].split()[0]) >= 6, frames[-1]
    capture('native-replayed.png')
    paste('After restart résumé 日本語')
    key('Return')
    eventually(lambda: len(turns()) == 4, 'resumed provider turn')
    eventually(lambda: ready(1), 'resumed native reply')
    assert turns()[3]['thread'] == turns()[0]['thread'] and turns()[3]['pid'] != pid, turns()
    capture('native-resumed.png')
    wire = {'codex': 'Codex app-server', 'claude': 'Claude stream-json'}.get(provider, provider.capitalize() + ' ACP')
    print(f'PASS ordinary saved native UI: production {wire}, composer growth/scroll ceiling/reset, rendered focus border, pointer send, Unicode/multiline input, three turns on one daemon child, retained draft/pane, terminal switch, dark theme, durable provider identity, restart replay and same-thread resume')
finally:
    subprocess.run(['xdotool', 'key', 'alt+F4'], check=False)
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
