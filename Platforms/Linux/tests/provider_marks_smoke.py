"""Installed catalogue provider marks beside a live PTY, including absent-resource fallback."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, host, daemon, endpoint, fixture = sys.argv[1:]
root = Path(fixture) / 'provider-marks'
root.mkdir()
store, project, home = root / 'store', root / 'ProviderMarks', root / 'home'
project.mkdir()
home.mkdir()
environment = dict(os.environ, HOME=str(home))
for name in ('THREADING_LINUX_CODEX_ACCOUNT', 'THREADING_LINUX_CLAUDE_ACCOUNT'):
    environment.pop(name, None)
for provider in ('claude', 'codex'):
    subprocess.run([host, str(store), endpoint, provider, str(project), '/bin/sh', '/bin/true',
                    'Provider mark fixture'], input=b'', env=environment, capture_output=True,
                   check=True, timeout=20)
expected = {}
provider_ids = {}
with sqlite3.connect(store / 'threading.db') as database:
    records = list(database.execute('SELECT id, kind, data FROM session ORDER BY position'))
    assert len(records) == 2
    database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
    for position, (identifier, kind, payload) in enumerate(records):
        record = json.loads(payload)
        assert kind in ('claude', 'codex'), kind
        is_claude = kind == 'claude'
        provider = 'Claude Code' if is_claude else 'Codex'
        provider_ids[kind] = identifier
        # Below the accessible byte bound, far beyond the 320px visual row. Provider/account/ID
        # must remain available even when the visible title is ellipsized by shaped text.
        title = ('解析 Claude 界 e\u0301 — ' if is_claude else 'Ångström Codex 日本語 — ') + 'A readable long session title ' * 3
        account = 'provider-mark-work-account' if is_claude else 'provider-mark-personal-account'
        record.update(customTitle=title, accountHandle=account, hasLaunched=False)
        database.execute('UPDATE session SET data = ? WHERE id = ?', (json.dumps(record), identifier))
        expected[identifier] = f'[{provider}] {title} [{account}] [{identifier[:8]}]'
    before = dict(database.execute('SELECT id, data FROM session'))
marker = root / 'shell-starts.jsonl'
child = Path(__file__).with_name('saved_terminal_child.py').resolve()
owned = None
process = None
Atspi.init()


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


def title(pattern):
    return eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', str(process.pid),
                                  '--name', pattern).splitlines()[0], pattern)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def panes():
    frame = app.get_child_at_index(0)
    children = [frame.get_child_at_index(i) for i in range(frame.get_child_count())]
    listed = next(item for item in children if item.get_role_name() == 'list')
    terminal = next(item for item in children if item.get_role_name() == 'terminal')
    assert [item.get_role_name() for item in children] == ['list', 'terminal', 'push button', 'push button']
    assert children[2].get_accessible_id() == 'linux.actions'
    assert children[3].get_accessible_id() == 'linux.add-project'
    assert terminal.get_component_iface().get_extents(Atspi.CoordType.WINDOW).x == 320
    assert terminal.get_state_set().contains(Atspi.StateType.SHOWING)
    return listed, terminal


def idle_labels():
    frame = app.get_child_at_index(0)
    children = [frame.get_child_at_index(i) for i in range(frame.get_child_count())]
    assert [item.get_role_name() for item in children] == ['list', 'push button', 'push button'], \
        'expiry must work before any terminal exists'
    assert children[2].get_accessible_id() == 'linux.add-project'
    listed = children[0]
    assert listed.get_child_count() == 2
    actual = {listed.get_child_at_index(i).get_accessible_id(): listed.get_child_at_index(i).get_name()
              for i in range(2)}
    assert actual == expected, actual
    return listed.get_selection_iface().get_selected_child(0).get_accessible_id()


def labels(selected):
    listed, terminal = panes()
    assert listed.get_child_count() == 2
    actual = {listed.get_child_at_index(i).get_accessible_id(): listed.get_child_at_index(i).get_name()
              for i in range(2)}
    assert actual == expected, actual
    assert listed.get_selection_iface().get_selected_child(0).get_accessible_id() == selected
    assert not terminal.get_state_set().contains(Atspi.StateType.FOCUSED)
    assert 'Saved shell start 1' in Atspi.Text.get_text(terminal.get_text_iface(), 0, -1)
    return True


def select(identifier):
    def read():
        listed, _ = panes()
        for index in range(listed.get_child_count()):
            row = listed.get_child_at_index(index)
            if row.get_accessible_id() == identifier:
                action = row.get_action_iface()
                for number in range(action.get_n_actions()):
                    if action.get_action_name(number) == 'select':
                        assert action.do_action(number)
                        return True
        return None
    eventually(read, 'select exact provider row')


def sessions():
    return json.loads(subprocess.run([daemon, 'sessions', '--json', '--socket', endpoint],
                     check=True, capture_output=True, text=True, timeout=5).stdout)


def same_shell():
    global owned
    records = [json.loads(line) for line in marker.read_text().splitlines()]
    assert len(records) == 1, 'opening the picker or fallback replaced the live shell'
    with sqlite3.connect(store / 'threading.db') as database:
        assert dict(database.execute('SELECT id, data FROM session')) == before
        saved = json.loads(database.execute('SELECT data FROM project').fetchone()[0])['terminals']
    assert len(saved) == 1
    current = ('terminal-' + saved[0]['id'], records[0]['pid'])
    if owned is not None:
        assert current == owned
    owned = current
    runtime = next(item for item in sessions() if item['id'] == current[0])
    assert runtime['pid'] == current[1] and runtime.get('exit') is None
    return True


def capture(name):
    destination = Path('out') / (name + '.png')
    subprocess.run(['import', '-window', window, str(destination)], check=True, timeout=5)
    crops = []
    listed, _ = panes()
    for index in range(2):
        rect = listed.get_child_at_index(index).get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        # Specimen.Row's 13pt glyph occupies26px, offset15px inside the native44px row.
        geometry = f'26x26+{rect.x + 15}+{rect.y + (rect.height - 26) // 2}'
        raw = subprocess.run(['convert', str(destination), '-crop', geometry, '+repage',
                              '-depth', '8', 'rgba:-'], check=True, capture_output=True, timeout=5).stdout
        assert len(raw) == 26 * 26 * 4
        pixels = [raw[i:i + 4] for i in range(0, len(raw), 4)]
        background = pixels[0]
        mask = tuple(pixel != background for pixel in pixels)
        assert 20 < sum(mask) < 26 * 26 - 20, (name, index, 'empty or opaque-square mark', sum(mask))
        assert not any(mask[y * 26 + x] for x, y in [(0, 0), (25, 0), (0, 25), (25, 25)])
        # Identity is its own second line, so a long primary title cannot consume its pixels.
        # The lower eight pixels were blank under the previous single centered text run.
        detail_geometry = f'{rect.width - 64}x8+{rect.x + 52}+{rect.y + 34}'
        detail = subprocess.run(['convert', str(destination), '-crop', detail_geometry, '+repage',
                                 '-depth', '8', 'rgba:-'], check=True, capture_output=True, timeout=5).stdout
        assert len(detail) == (rect.width - 64) * 8 * 4
        assert any(detail[i:i + 4] != background for i in range(0, len(detail), 4)), \
            (name, index, 'provider/account detail was lost below the long title')
        crops.append(mask)
    return crops


try:
    silhouettes = {}
    for missing in (False, True):
        label = 'fallback' if missing else 'bundled'
        launch_binary = binary
        if missing:
            isolated = root / 'without-resources'
            isolated.mkdir()
            launch_binary = str(isolated / 'WindowHarness')
            shutil.copy2(binary, launch_binary)
        # Return to the ordinary project entry point; the existing terminal is explicitly reused.
        with sqlite3.connect(store / 'threading.db') as database:
            database.execute("DELETE FROM app_state WHERE key IN ('selectedSessionID', 'selectedTerminalID')")
            # JSONEncoder stores Date as seconds since 2001. Both an empty workspace and a
            # retained terminal must refresh an idle picker across a real snooze deadline.
            now = time.time() - 978307200
            identifier = provider_ids['codex']
            record = json.loads(database.execute('SELECT data FROM session WHERE id = ?',
                                                  (identifier,)).fetchone()[0])
            record.update(snoozedAt=now - 60, snoozedUntil=now + 20)
            database.execute('UPDATE session SET data = ? WHERE id = ?', (json.dumps(record), identifier))
            expected[identifier] += ' Snoozed'
            before = dict(database.execute('SELECT id, data FROM session'))
        log_path = Path('out/provider-marks-' + label + '.log')
        with log_path.open('w+') as log:
            process = subprocess.Popen([launch_binary, '--app', str(store), endpoint, '/usr/bin/python3',
                                        str(child), str(marker)], env=environment, stdout=log, stderr=log)
            try:
                window = title('^Threading experiment - ' + re.escape(str(project)) + '$')
                app = eventually(application, 'native accessibility registration')
                if not missing:
                    key('Left')
                    title('^Threading agents - ' + re.escape(str(project)) + '$')
                    selected_id = eventually(idle_labels, 'snoozed row before any terminal exists')
                    subprocess.run(['import', '-window', window, 'out/provider-marks-idle-snoozed.png'],
                                   check=True, timeout=5)
                    expected[provider_ids['codex']] = expected[provider_ids['codex']].removesuffix(' Snoozed')
                    # No key, pointer event or action may wake the Swift loop during this wait.
                    # AT-SPI property reads alone must keep responding through the deadline.
                    assert eventually(idle_labels, 'no-terminal snooze deadline expires', timeout=25) == selected_id
                    subprocess.run(['import', '-window', window, 'out/provider-marks-idle-expired.png'],
                                   check=True, timeout=5)
                    assert not marker.exists(), 'viewing/expiring a saved row spawned a child'
                    key('Escape')
                    title('^Threading experiment - ' + re.escape(str(project)) + '$')
                if missing:
                    key('Right')
                    title('^Threading terminals - ' + re.escape(str(project)) + '$')
                key('Return')
                title(r'^Threading terminal - SAVED SHELL 1 READY( \[(history cut|restored)\])?$')
                eventually(same_shell, 'single retained live shell')
                key('ctrl+shift+p')
                if missing:
                    title('^Threading terminals - ' + re.escape(str(project)) + '$')
                    key('Escape')
                title('^Threading experiment - ' + re.escape(str(project)) + '$')
                key('Left')
                title('^Threading agents - ' + re.escape(str(project)) + '$')
                identifiers = [provider_ids['claude'], provider_ids['codex']]
                select(identifiers[0])
                eventually(lambda: labels(identifiers[0]), 'provider/account/ID in selected Claude row')
                silhouettes[label] = capture('provider-marks-' + label + '-claude-selected')
                select(identifiers[1])
                eventually(lambda: labels(identifiers[1]), 'provider/account/ID in selected Codex row')
                capture('provider-marks-' + label + '-codex-selected')
                if missing:
                    expected[provider_ids['codex']] = expected[provider_ids['codex']].removesuffix(' Snoozed')
                    # No input or selection change drives this update. The visible expiry must
                    # invalidate both the cached raster and accessibility while preserving UUID.
                    eventually(lambda: labels(identifiers[1]), 'visible snooze deadline expires', timeout=25)
                    capture('provider-marks-snooze-expired')
                eventually(same_shell, 'picker preserved child and durable titles')
                key('Tab')
                title(r'^Threading terminal - SAVED SHELL 1 READY( \[(history cut|restored)\])?$')
                key('alt+F4')
                assert process.wait(timeout=8) == 0
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
        if not missing:
            assert 'cached=2' in log_path.read_text(), 'installed bundle did not load both catalogue assets'
        if missing:
            assert 'cached=0' in log_path.read_text(), 'copied binary unexpectedly loaded bundle artwork'
    assert all(bundled != fallback for bundled, fallback in
               zip(silhouettes['bundled'], silhouettes['fallback'])), 'provider marks rendered as generic fallback dots'
    assert silhouettes['bundled'][0] != silhouettes['bundled'][1], 'two providers share the same glyph'
    print('PASS installed provider glyphs, selected/unselected states, Unicode titles, full account/ID '
          'accessibility, live terminal identity, and absent-artwork fallback', flush=True)
finally:
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    if owned is None and marker.exists():
        records = [json.loads(line) for line in marker.read_text().splitlines()]
        with sqlite3.connect(store / 'threading.db') as database:
            saved = json.loads(database.execute('SELECT data FROM project').fetchone()[0])['terminals']
        if len(records) == len(saved) == 1:
            owned = ('terminal-' + saved[0]['id'], records[0]['pid'])
    if owned is not None:
        for runtime in sessions():
            if (runtime['id'], runtime['pid']) == owned and runtime.get('exit') is None:
                try:
                    os.kill(runtime['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
