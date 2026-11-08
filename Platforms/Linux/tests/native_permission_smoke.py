"""A native Codex conversation asks for approval and answers through the production cards."""
from saved_catalog_menu import open_saved_agents
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
sidebar_width = 240 * scale
root = Path(fixture) / 'native-permission'
root.mkdir()
store, project, home = root / 'store', root / 'PermissionProject', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home), THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, str(store), endpoint, 'codex', str(project), '/bin/sh', '/bin/true', 'Seed'],
               input=b'', env=environment, check=True, capture_output=True, timeout=20)
with sqlite3.connect(store / 'threading.db') as database:
    identifier, payload = database.execute('SELECT id, data FROM session').fetchone()
    record = json.loads(payload)
    record.update(nativeUI=True, hasLaunched=False, lastExitCode=None, agentSessionID=None,
                  customTitle='Permission conversation', permissionMode='manual')
    database.execute('UPDATE session SET data = ? WHERE id = ?', (json.dumps(record), identifier))

# The app-server asks before each command and waits for the answer, as Codex does. A read-only
# command is answered by policy without a card; a write needs the person.
peer = root / 'codex-peer'
peer.write_text(r'''#!/usr/bin/python3
import json, os, sys, uuid
from pathlib import Path
thread = str(uuid.uuid4())
turn = 0
plans = {1: ['ls -la', 'touch approved.txt'], 2: ['touch approved.txt', 'rm -f approved.txt']}
def emit(value): print(json.dumps(value, ensure_ascii=False), flush=True)
def reply(request, result): emit({'id': request['id'], 'result': result})
def note(method, params): emit({'method': method, 'params': params})
def approve(command, serial, tid):
    emit({'id': 'approval-' + str(serial), 'method': 'item/commandExecution/requestApproval',
          'params': {'threadId': thread, 'turnId': tid, 'itemId': 'command-' + str(serial),
                     'command': command, 'cwd': os.getcwd(), 'reason': 'fixture'}})
    while True:
        answer = json.loads(sys.stdin.readline())
        if answer.get('id') == 'approval-' + str(serial): break
        raise AssertionError(answer)
    decision = answer['result']['decision']
    with Path('native-approvals.jsonl').open('a') as target:
        target.write(json.dumps({'command': command, 'decision': decision}) + '\n')
    return decision
def ask(serial, tid):
    emit({'id': 'question-' + str(serial), 'method': 'item/tool/requestUserInput',
          'params': {'threadId': thread, 'turnId': tid, 'questions': [
              {'id': 'color', 'header': 'Color', 'question': 'Which colour should the fixture use?',
               'options': [{'label': 'Red', 'description': 'Warm'}, {'label': 'Blue', 'description': 'Cool'}]},
              {'id': 'name', 'header': 'Name', 'question': 'What should it be called?', 'options': None}]}})
    answer = json.loads(sys.stdin.readline())
    assert answer.get('id') == 'question-' + str(serial), answer
    with Path('native-questions.jsonl').open('a') as target:
        target.write(json.dumps(answer['result'], ensure_ascii=False) + '\n')
    return answer['result']['answers']
serial = 0
while True:
    line = sys.stdin.readline()
    if not line: break
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize': reply(request, {})
    elif method == 'initialized': pass
    elif method in ('thread/start', 'thread/resume'):
        reply(request, {'thread': {'id': thread, 'model': 'fixture'}})
    elif method == 'skills/list': reply(request, {'data': [{'cwd': os.getcwd(), 'skills': [], 'errors': []}]})
    elif method == 'turn/start':
        turn += 1
        tid = 'turn-' + str(turn)
        reply(request, {'turn': {'id': tid, 'status': 'inProgress', 'items': []}})
        note('turn/started', {'threadId': thread, 'turn': {'id': tid}})
        decisions = []
        if turn in plans:
            for command in plans[turn]:
                serial += 1
                item = {'type': 'commandExecution', 'id': 'command-' + str(serial), 'command': command}
                if command == 'ls -la':
                    note('item/started', {'threadId': thread, 'turnId': tid, 'item': item})
                decisions.append(approve(command, serial, tid))
                if command == 'ls -la':
                    note('item/completed', {'threadId': thread, 'turnId': tid, 'item': dict(item,
                         status='completed', exitCode=0, aggregatedOutput='alpha.txt\nbeta.txt\n日本語.txt')})
        else:
            serial += 1
            decisions = [value['answers'][0] for value in ask(serial, tid).values()]
        answer = f'Turn {turn} decisions: ' + ', '.join(decisions)
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
process = subprocess.Popen([binary, '--app-codex', str(store), endpoint, '/bin/sh', str(peer)],
                           env=environment, stdout=log, stderr=log)


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
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, timeout=5).strip()


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '40', value)


def paste(value):
    subprocess.run(['xclip', '-selection', 'clipboard'], input=value.encode(), check=True, timeout=5)
    key('ctrl+v')


def approvals():
    return [json.loads(line) for line in (project / 'native-approvals.jsonl').read_text().splitlines()]


def frames():
    return log_path.read_text().splitlines()


def ready(turn):
    lines = [line for line in frames() if line.startswith('CONVERSATION_FRAME ')]
    return (lines and f'turns={turn} prepared=true' in lines[-1] and lines[-1].endswith('status=Ready'))


def card():
    """The presented card's action centres, from the newest frame, or None once it has gone."""
    lines = [line for line in frames() if line.startswith(('PERMISSION_FRAME ', 'CONVERSATION_FRAME '))]
    if len(lines) < 2 or not lines[-2].startswith('PERMISSION_FRAME ') or 'prepared=true' not in lines[-1]:
        return None
    fields = lines[-2].split()[2:]
    return {name: tuple(map(int, value.split(','))) for name, value in (field.split('=') for field in fields)}


def question():
    """The question card's controls, from the newest frame, or None when none is shown."""
    lines = [line for line in frames() if line.startswith(('PERMISSION_FRAME ', 'QUESTION_FRAME ', 'CONVERSATION_FRAME '))]
    if not lines or not lines[-1].startswith('CONVERSATION_FRAME ') or 'prepared=true' not in lines[-1]:
        return None
    for line in reversed(lines[:-1]):
        if line.startswith('CONVERSATION_FRAME '):
            return None
        if line.startswith('QUESTION_FRAME '):
            fields = line.split()[1:]
            return {name: tuple(map(int, value.split(','))) for name, value in (field.split('=') for field in fields)}
    return None


def click(point):
    x, y = point
    xdo('mousemove', '--window', window, x, y)
    xdo('click', '1')


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=5)


try:
    eventually(lambda: 'IDLE_PANE_FRAME ' in log_path.read_text(), 'workspace presentation')
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0], 'window')
    xdo('windowmove', window, 0, 0)
    xdo('windowsize', window, 1120, 900)
    open_saved_agents(key)
    eventually(lambda: xdo('getwindowname', window).startswith('Threading agents -'), 'saved agent picker')
    key('Return')
    eventually(lambda: ready(0), 'native pane ready')
    # Selecting the pane applies its initial viewport; size the window afterwards so the card
    # and composer sit where the captures and the composer click below expect them.
    xdo('windowmove', window, 0, 0)
    xdo('windowsize', window, 1120, 900)
    eventually(lambda: 'WIDTH=1120' in (geometry := xdo('getwindowgeometry', '--shell', window))
               and 'HEIGHT=900' in geometry, 'native resize')
    eventually(lambda: ready(0) and f'AGENT_PICKER_FRAME {sidebar_width}x900' in log_path.read_text(), 'resized pane')

    paste('Run the fixture commands')
    key('Return')
    actions = eventually(lambda: (card() or {}).get('Deny') and card(), 'permission card')
    assert set(actions) == {'Allow', 'Allow_for_Session', 'Deny'}, actions
    assert approvals() == [{'command': 'ls -la', 'decision': 'accept'}], 'read-only command needed a card'
    assert 'Threading conversation · Working' == xdo('getwindowname', window)
    # Return in the composer stays a send; it must not answer a request that just arrived.
    key('Return')
    time.sleep(.5)
    assert len(approvals()) == 1, approvals()
    capture('permission-card.png')
    click(actions['Deny'])
    eventually(lambda: len(approvals()) == 2, 'denied command answered')
    assert approvals()[1] == {'command': 'touch approved.txt', 'decision': 'decline'}, approvals()
    eventually(lambda: ready(1) and card() is None, 'card retired after denial')
    capture('permission-denied.png')

    def tool_rows():
        lines = frames()
        last = max(index for index, line in enumerate(lines) if line.startswith('CONVERSATION_FRAME '))
        block = []
        for line in reversed(lines[:last]):
            if line.startswith('CONVERSATION_FRAME '):
                break
            if line.startswith('TOOL_FRAME '):
                point, height, opened = line.split()[1:]
                block.append((tuple(map(int, point.split(','))), int(height.split('=')[1]), int(opened.split('=')[1])))
        return block
    rows = eventually(tool_rows, 'collapsed tool row')
    assert len(rows) == 1 and rows[0][2] == 0, rows
    collapsed = rows[0][1]
    click(rows[0][0])
    opened = eventually(lambda: (lambda r: r and r[0][2] == 1 and r[0][1] > collapsed + 20 and r)(tool_rows()),
                        'tool row opened by a click')
    capture('tool-row-open.png')
    # The open body takes clicks for its own text selection; the header closes the row. The
    # logged centre is in window pixels and the height in points, so the top subtracts
    # half the scaled height.
    (x, y), height, _ = opened[0]
    click((x, y - height * scale // 2 + 9 * scale))
    eventually(lambda: (lambda r: r and r[0][2] == 0 and r[0][1] == collapsed)(tool_rows()), 'tool row closed again')

    # The production button takes the keyboard when clicked, as on the Mac, and its card has
    # left. Focus the editor above its footer using the geometry of the presented composer.
    def focus_composer():
        line = next(line for line in reversed(frames()) if line.startswith('COMPOSER_FRAME '))
        frame = dict(part.split('=', 1) for part in line.split()[1:])
        click((int(frame['x']) + 24, int(frame['y']) + 24))

    focus_composer()
    paste('Run them again')
    key('Return')
    actions = eventually(lambda: (card() or {}).get('Allow_for_Session') and card(), 'second permission card')
    click(actions['Allow_for_Session'])
    # Allow for Session answers the next shell request by policy, without another card.
    eventually(lambda: len(approvals()) == 4, 'session approval covered the next command')
    assert approvals()[2:] == [{'command': 'touch approved.txt', 'decision': 'accept'},
                               {'command': 'rm -f approved.txt', 'decision': 'accept'}], approvals()
    eventually(lambda: ready(2) and card() is None, 'card retired after approval')
    assert sum(line.startswith('PERMISSION_FRAME 2 ') for line in frames()) > 0, 'second card never shown'
    assert not any(line.startswith('PERMISSION_FRAME 3 ') for line in frames()), 'session approval still asked'
    capture('permission-allowed.png')

    focus_composer()
    paste('Ask me two things')
    key('Return')
    controls = eventually(lambda: (question() or {}).get('Blue') and question(), 'question card')
    assert {'Red', 'Blue', 'Cancel'} <= set(controls), controls
    composer_line = next(line for line in reversed(frames()) if line.startswith('COMPOSER_FRAME '))
    composer = dict(part.split('=', 1) for part in composer_line.split()[1:])
    viewport_bottom = int(composer['y']) - 36 * scale
    assert all(41 * scale < y < viewport_bottom for _, y in controls.values()), (
        'question controls must follow the measured tail into the transcript viewport', controls)
    capture('question-card.png')
    click(controls['Blue'])
    click(eventually(lambda: (question() or {}).get('Next'), 'next question'))
    controls = eventually(lambda: (question() or {}).get('field') and question(), 'free-text question')
    click(controls['field'])
    paste('Fixture 日本語 café')
    send = eventually(lambda: (question() or {}).get('Send_answer'), 'answer ready to send')
    capture('question-answer.png')
    click(send)
    answered = eventually(lambda: (project / 'native-questions.jsonl').exists()
                          and json.loads((project / 'native-questions.jsonl').read_text()), 'answers sent')
    assert answered == {'answers': {'color': {'answers': ['Blue']}, 'name': {'answers': ['Fixture 日本語 café']}}}, answered
    eventually(lambda: ready(3) and question() is None, 'question card retired')
    capture('question-answered.png')
    print('PASS native decisions: policy auto-allow, permission card, Return stays a send, deny, allow for session, production tool row opened and closed, two-page question with choice and edited answer')
finally:
    subprocess.run(['xdotool', 'key', 'alt+F4'], check=False)
    try: process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
