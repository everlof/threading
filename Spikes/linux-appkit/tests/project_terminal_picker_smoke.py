"""Select and reattach a persisted terminal from the graphical project browser."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

binary, host, endpoint, folder, child = sys.argv[1:]
store = folder + '/picker-store'
project = folder + '/Alpha'
log_path = Path(folder) / 'project-terminal-picker.log'


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def title(expected):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert process.poll() is None, 'window exited early'
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.04)
    raise AssertionError('missing title: ' + expected)


def key(value):
    assert xdo('windowfocus', window, 'key', value).returncode == 0


def listing():
    return subprocess.run([host, store, endpoint, 'list'], check=True, capture_output=True,
                          text=True, timeout=8).stdout


def move_picker(value, expected):
    before = sum(line.startswith('TERMINAL_PICKER_FRAME ') for line in log_path.read_text().splitlines())
    key(value)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        frames = [line for line in log_path.read_text().splitlines()
                  if line.startswith('TERMINAL_PICKER_FRAME ')]
        if any('selected=' + expected in line for line in frames[before:]):
            return
        assert process.poll() is None
        time.sleep(.04)
    raise AssertionError('picker did not select: ' + expected)


with log_path.open('w+') as log:
    # Leave one older dormant record so the picker must expose multiple identities while choosing
    # the newest live terminal first.
    subprocess.run([host, store, endpoint, 'run', project, '/bin/true'], input='', text=True,
                   check=True, capture_output=True, timeout=8)
    process = subprocess.Popen([binary, '--terminal', store, endpoint, project,
                               '/usr/bin/timeout', '120', '/usr/bin/python3', child],
                               stdout=log, stderr=log)
    try:
        window = title('Threading terminal - ATTACH READY')
        assert xdo('windowsize', window, '960', '660').returncode == 0
        deadline = time.monotonic() + 10
        while 'TERMINAL_FRAME 960x660' not in log_path.read_text():
            assert time.monotonic() < deadline
            time.sleep(.04)
        key('g')
        title('Threading terminal - ATTACH DETACHED')
        original = json.loads((Path(project) / 'attach-child.json').read_text())
        saved = listing()
        ids = [line.strip().split('\t')[0] for line in saved.splitlines()
               if line.startswith('  ') and not line.startswith('  agent ')]
        assert len(ids) == 2, saved
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        os.kill(original['pid'], 0)

        process = subprocess.Popen([binary, '--app', store, endpoint, '/bin/sh'],
                                   stdout=log, stderr=log)
        window = title('Threading experiment - ' + project)
        key('Right')
        title('Threading terminals - ' + project)
        subprocess.run(['import', '-window', window, 'out/project-terminal-picker.png'],
                       check=True, timeout=15)
        move_picker('Down', ids[0])
        move_picker('Up', ids[-1])
        key('Return')
        title('Threading terminal - ATTACH DETACHED [history cut]')
        geometry = xdo('getwindowgeometry', '--shell', window).stdout
        assert 'WIDTH=960\n' in geometry and 'HEIGHT=660\n' in geometry, geometry
        assert json.loads((Path(project) / 'attach-child.json').read_text()) == original
        key('p')
        title('Threading terminal - ATTACH LIVE [history cut]')
        key('q')
        title('Threading terminal - exited 7 [history cut]')
        key('ctrl+shift+p')
        title('Threading terminals - ' + project)
        key('Left')
        title('Threading experiment - ' + project)
        key('Right')
        title('Threading terminals - ' + project)
        key('Escape')
        title('Threading experiment - ' + project)
        key('Right')
        title('Threading terminals - ' + project)
        key('alt+F4')
        assert process.wait(timeout=5) == 0, 'window close acted like picker back'
        assert listing() == saved, 'picker attachment changed durable terminal records'
        picker_frames = [line for line in log_path.read_text().splitlines()
                         if line.startswith('TERMINAL_PICKER_FRAME ')]
        assert picker_frames and 'mounted=2' in picker_frames[0] and 'total=2 capped=0' in picker_frames[0]
        assert ids[-1] in picker_frames[0], 'picker did not select the newest terminal first'
        print('PASS persisted-terminal picker: bounded row, same child/grid/history, keyboard back and real window close', flush=True)
    except BaseException:
        log.seek(0)
        print(log.read(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        Path('out/project-terminal-picker-session.log').write_text(log_path.read_text())
