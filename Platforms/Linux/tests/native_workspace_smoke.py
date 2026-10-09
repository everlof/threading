"""A saved native conversation selected from the ordinary workspace, with a real daemon child."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'native-workspace'
root.mkdir()
store, project, home = root / 'store', root / 'NativeProject', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(nativeUI=True, hasLaunched=False, lastExitCode=None, agentSessionID=None,
                  customTitle='Native conversation')
    database.execute('UPDATE session SET data = ? WHERE id = ?', (json.dumps(record), identifier))

peer = root / 'codex-peer'
peer.write_text(r'''#!/usr/bin/python3
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
''')
peer.chmod(0o700)
output = Path(evidence)
output.mkdir(parents=True)
log_path = output / 'window.log'
log = log_path.open('w')
command = [binary, '--app-codex', str(store), endpoint, '/bin/sh', str(peer)]
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


def turns():
    return [json.loads(line) for line in (project / 'native-turns.jsonl').read_text().splitlines()]


def ready(turn=0):
    frames = [line for line in log_path.read_text().splitlines() if line.startswith('CONVERSATION_FRAME ')]
    return (xdo('getwindowname', window) == 'Threading conversation · Ready' and frames
            and f'turns={turn} prepared=true' in frames[-1] and frames[-1].endswith('status=Ready'))


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


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
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0], 'window')
    xdo('windowsize', window, '1120', '900')
    key('Left')
    eventually(lambda: xdo('getwindowname', window).startswith('Threading agents -'), 'saved agent picker')
    key('Return')
    eventually(ready, 'ordinary native pane ready')
    resize_native()
    assert 'TERMINAL_FRAME ' not in log_path.read_text(), 'saved native UI opened an emulator'
    capture('native-ready.png')
    first = 'First native prompt 日本語 café 👩🏽‍🚀'
    paste(first)
    key('Return')
    eventually(lambda: len(turns()) == 1, 'first prompt received')
    eventually(lambda: ready(1), 'first native reply')
    assert turns()[0]['text'] == first, turns()
    pid = turns()[0]['pid']
    capture('native-first-reply.png')
    paste('Second line 日本語')
    key('shift+Return')
    paste('Another line café 👩🏽‍🚀')
    key('Return')
    eventually(lambda: len(turns()) == 2, 'multiline second prompt')
    eventually(lambda: ready(2), 'second native reply')
    assert turns()[1]['text'] == 'Second line 日本語\nAnother line café 👩🏽‍🚀', turns()
    assert turns()[1]['pid'] == pid, 'turn replaced the persistent child'
    key('ctrl+shift+t')
    eventually(lambda: ready(2) and 'dark=true' in log_path.read_text().split('CONVERSATION_FRAME ')[-1], 'dark theme')
    capture('native-dark.png')

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
    key('Left')
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
    process = subprocess.Popen([binary, '--app-codex', str(store), endpoint, '/bin/sh', str(peer)],
                               env=environment, stdout=log, stderr=log)
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0], 'reopened window')
    xdo('windowsize', window, '1120', '900')
    eventually(ready, 'replayed native conversation after restart')
    resize_native()
    frames = [line for line in log_path.read_text().splitlines() if line.startswith('CONVERSATION_FRAME ')]
    assert int(frames[-1].split('rows=')[1].split()[0]) >= 6, frames[-1]
    capture('native-replayed.png')
    paste('After restart résumé 日本語')
    key('Return')
    eventually(lambda: len(turns()) == 4, 'resumed provider turn')
    eventually(lambda: ready(1), 'resumed native reply')
    assert turns()[3]['thread'] == turns()[0]['thread'] and turns()[3]['pid'] != pid, turns()
    capture('native-resumed.png')
    print('PASS ordinary saved native UI: production Codex app-server, Unicode/multiline input, three turns on one daemon child, retained draft/pane, terminal switch, dark theme, durable provider identity, restart replay and same-thread resume')
finally:
    subprocess.run(['xdotool', 'key', 'alt+F4'], check=False)
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
