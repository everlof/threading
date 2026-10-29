"""Move a real Scratchpad through the Linux Chats page and return it to default."""
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


binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'scratchpad-settings'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
home, store, project, destination = (root / name for name in
    ('home', 'store', 'Project', 'Elsewhere'))
for folder in (home, project, destination):
    folder.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'))
subprocess.run([host, '--add-project', str(store), str(project)], env=environment,
               check=True, capture_output=True, timeout=12)
source = Path(subprocess.check_output([host, '--ensure-scratchpad', str(store)],
    env=environment, text=True, timeout=12).strip())
(source / 'README.md').write_text('My own Scratchpad notes\n')
target = destination / 'Scratchpad'
Atspi.init()
process = None
log = None


def eventually(read, label, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None:
            assert process.poll() is None, f'{label}: {Path(log.name).read_text()[-4000:]}'
        try:
            result = read()
            if result:
                return result
        except (IndexError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(f'{label}: {Path(log.name).read_text()[-4000:]}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, timeout=5).strip()


def descendants(node):
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


def launch(name):
    global process, log, window
    log = (output / f'{name}.log').open('w+')
    process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
        env=environment, stdout=log, stderr=log)
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
        process.pid, '--name', '^Threading').splitlines()[0], 'workspace window')
    xdo('windowfocus', '--sync', window)


def close():
    global process, log
    xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
    assert process.wait(timeout=8) == 0, Path(log.name).read_text()[-4000:]
    log.close()
    process = log = None


def chats_page():
    settings = eventually(lambda: control('sidebar.settings'), 'Settings footer')
    assert settings.get_action_iface().do_action(0)
    eventually(lambda: 'SETTINGS_OPENED' in Path(log.name).read_text(), 'Settings opened')
    pattern = r'SETTINGS_PAGE_ANCHOR value=General x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)'
    x, y, width, height = map(float, eventually(lambda: re.findall(pattern,
        Path(log.name).read_text()), 'page selector')[-1])
    window_height = int(re.search(r'^HEIGHT=(\d+)$',
        xdo('getwindowgeometry', '--shell', window), re.MULTILINE).group(1))
    xdo('mousemove', '--window', window, round(240 + x + width / 2),
        round(window_height - y - height / 2), 'click', 1)
    eventually(lambda: 'SETTINGS_POPUP_OPENED rows=2' in Path(log.name).read_text(),
               'Settings destinations')
    xdo('key', 'Down', 'Return')
    eventually(lambda: 'SETTINGS_PAGE_SELECTED value=Chats' in Path(log.name).read_text(),
               'Chats page')
    xdo('windowsize', window, 1120, 900)
    xdo('windowmove', window, 0, 0)
    eventually(lambda: 'SETTINGS_FRAME 880x859' in Path(log.name).read_text(),
               'tall Chats page')
    eventually(lambda: float(re.findall(
        r'SETTINGS_SCRATCHPAD_ANCHOR kind=choose x=[\d.]+ y=([\d.-]+)',
        Path(log.name).read_text())[-1]) > 0, 'Scratchpad controls laid out')


def click_anchor(category, kind):
    pattern = rf'SETTINGS_{category}_ANCHOR kind={kind} x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)'
    x, y, width, height = map(float, eventually(lambda: re.findall(pattern,
        Path(log.name).read_text()), f'{kind} button')[-1])
    window_height = int(re.search(r'^HEIGHT=(\d+)$',
        xdo('getwindowgeometry', '--shell', window), re.MULTILINE).group(1))
    xdo('mousemove', '--window', window, round(240 + x + width / 2),
        round(window_height - y - height / 2), 'click', 1)


def project_id(path):
    with sqlite3.connect(store / 'threading.db') as database:
        for identifier, payload in database.execute('SELECT id, data FROM project'):
            if json.loads(payload).get('isScratchpad'):
                assert json.loads(payload)['folderPath'] == str(path)
                return identifier
    raise AssertionError('Scratchpad project missing')


try:
    original_id = project_id(source)
    launch('choose')
    chats_page()
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-default.png')],
                   check=True, timeout=5)
    click_anchor('SCRATCHPAD', 'help')
    eventually(lambda: 'SETTINGS_HELP_OPENED' in Path(log.name).read_text(),
               'Scratchpad help popover')
    eventually(lambda: 'help=true' in Path(log.name).read_text().split(
        'SETTINGS_HELP_OPENED', 1)[-1], 'Scratchpad help rendered')
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-help.png')],
                   check=True, timeout=5)
    xdo('key', 'Escape')
    eventually(lambda: 'SETTINGS_HELP_CLOSED' in Path(log.name).read_text(),
               'Scratchpad help dismissed')
    for kind, artifact in [
        ('new-chat-0', 'new-chats-help.png'),
        ('opening-message', 'opening-message-help.png'),
    ]:
        opened = Path(log.name).read_text().count('SETTINGS_HELP_OPENED')
        closed = Path(log.name).read_text().count('SETTINGS_HELP_CLOSED')
        click_anchor('CHAT_HELP', kind)
        eventually(lambda: Path(log.name).read_text().count('SETTINGS_HELP_OPENED') > opened,
                   f'{kind} opened')
        eventually(lambda: 'help=true' in Path(log.name).read_text().rsplit(
            'SETTINGS_HELP_OPENED', 1)[-1], f'{kind} rendered')
        subprocess.run(['import', '-window', window, str(output / artifact)],
                       check=True, timeout=5)
        xdo('key', 'Escape')
        eventually(lambda: Path(log.name).read_text().count('SETTINGS_HELP_CLOSED') > closed,
                   f'{kind} dismissed')
    xdo('windowsize', window, 660, 900)
    xdo('windowmove', window, 0, 0)
    eventually(lambda: 'SETTINGS_FRAME 420x859' in Path(log.name).read_text(),
               'narrow Scratchpad page')
    xdo('mousemove', '--window', window, 500, 600)
    xdo('click', '--repeat', '35', '--delay', '80', 5)
    eventually(lambda: float(re.findall(
        r'SETTINGS_SCRATCHPAD_ANCHOR kind=choose x=[\d.]+ y=([\d.-]+)',
        Path(log.name).read_text())[-1]) >= 30, 'narrow Scratchpad fully visible', timeout=60)
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-narrow.png')],
                   check=True, timeout=5)
    opened = Path(log.name).read_text().count('SETTINGS_HELP_OPENED')
    click_anchor('SCRATCHPAD', 'help')
    eventually(lambda: Path(log.name).read_text().count('SETTINGS_HELP_OPENED') > opened,
               'narrow Scratchpad help opened')
    eventually(lambda: 'help=true' in Path(log.name).read_text().rsplit(
        'SETTINGS_HELP_OPENED', 1)[-1], 'narrow Scratchpad help rendered')
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-help-narrow.png')],
                   check=True, timeout=5)
    xdo('key', 'Escape')
    xdo('windowsize', window, 1120, 900)
    xdo('windowmove', window, 0, 0)
    eventually(lambda: 'SETTINGS_FRAME 880x859' in Path(log.name).read_text().split(
        'SETTINGS_FRAME 420x859', 1)[-1], 'wide Scratchpad page restored')
    click_anchor('SCRATCHPAD', 'choose')
    picker = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--name',
        'Choose the folder to keep the scratchpad in').splitlines()[0], 'folder picker')
    xdo('windowfocus', '--sync', picker, 'key', 'ctrl+l')
    xdo('type', '--clearmodifiers', '--delay', '5', str(destination))
    xdo('key', 'Return')
    if not target.exists():
        xdo('key', 'Return')
    eventually(lambda: f'SCRATCHPAD_MOVED {target}' in Path(log.name).read_text(),
               'Scratchpad relocated')
    eventually(lambda: 'SETTINGS_FRAME' in Path(log.name).read_text().split(
        f'SCRATCHPAD_MOVED {target}', 1)[-1], 'relocated row rendered')
    assert not source.exists() and (target / 'README.md').read_text() == 'My own Scratchpad notes\n'
    assert project_id(target) == original_id
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-moved.png')],
                   check=True, timeout=5)
    close()

    launch('return')
    chats_page()
    click_anchor('SCRATCHPAD', 'default')
    eventually(lambda: f'SCRATCHPAD_MOVED {source}' in Path(log.name).read_text(),
               'Scratchpad returned')
    eventually(lambda: 'SETTINGS_FRAME' in Path(log.name).read_text().split(
        f'SCRATCHPAD_MOVED {source}', 1)[-1], 'default row rendered')
    assert not target.exists() and (source / 'README.md').read_text() == 'My own Scratchpad notes\n'
    assert project_id(source) == original_id
    subprocess.run(['import', '-window', window, str(output / 'scratchpad-returned.png')],
                   check=True, timeout=5)
    close()

    fresh_home = root / 'fresh-home'
    fresh_parent = root / 'UnusedPlace'
    fresh_home.mkdir(); fresh_parent.mkdir()
    fresh_environment = dict(environment, HOME=str(fresh_home),
                             XDG_CONFIG_HOME=str(fresh_home / '.config'))
    fresh_store = root / 'fresh-store'
    subprocess.run([host, '--init-store', str(fresh_store)], env=fresh_environment,
                   check=True, capture_output=True, timeout=12)
    fresh_source = fresh_home / 'Threading' / 'Scratchpad'
    fresh_target = fresh_parent / 'Scratchpad'
    subprocess.run([host, '--relocate-scratchpad', str(fresh_store),
                    str(fresh_source), str(fresh_target)], env=fresh_environment,
                   check=True, capture_output=True, timeout=12)
    assert not fresh_target.exists(), 'choosing a location made the lazy folder early'
    chosen = subprocess.check_output([host, '--ensure-scratchpad', str(fresh_store)],
        env=fresh_environment, text=True, timeout=12).strip()
    assert chosen == str(fresh_target) and (fresh_target / 'README.md').is_file()
    print('PASS Scratchpad Settings: chooser, durable move, retained notes and project identity, default return, lazy first location')
finally:
    if process is not None:
        process.kill()
        process.wait(timeout=5)
    if log is not None:
        log.close()
