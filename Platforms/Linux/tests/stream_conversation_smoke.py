"""Drive a live stream-json child through the production transport into the native rows."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

binary, agent, destination = sys.argv[1:]
output = Path(destination)
output.mkdir(parents=True, exist_ok=True)
log = (output / 'window.log').open('w')
started = time.monotonic()
# Deltas a second apart keep the partial frame on screen long enough to capture.
environment = dict(os.environ, STREAM_FIXTURE_DELTA_PAUSE='1.0')
process = subprocess.Popen([binary, '--stream-ui-fixture', str(output), sys.executable, agent],
                           stdout=log, stderr=log, env=environment)
SECOND = 'Keep the same process for a second turn: é, 中文, 👩🏽‍🚀.'


def state(name='state.json'):
    try:
        return json.loads((output / name).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def eventually(predicate, name, timeout=35, file='state.json'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if file == 'state.json':
            assert process.poll() is None, (output / 'window.log').read_text()[-3000:]
        current = state(file)
        if current and current.get('stream') and predicate(current):
            return current
        time.sleep(.02)
    raise AssertionError(f'{name}: {state(file)}')


def xdo(*args):
    subprocess.run(['xdotool', *map(str, args)], check=True, timeout=8)


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=8)


def pane_has_ink(name):
    # The pane right of the 320-pixel sidebar, below its header: a uniform ground means the
    # capture raced a repaint rather than showing the streamed row.
    spread = subprocess.check_output(['convert', str(output / name), '-crop', '760x700+340+90',
                                      '-format', '%[fx:standard_deviation]', 'info:'], text=True)
    return float(spread) > 0.01


def copied(expected):
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', 'UTF8_STRING', '-o'],
                            capture_output=True, timeout=3)
    return result.returncode == 0 and result.stdout == expected.encode('utf-8')


def control(current, prefix):
    return next((c for c in current['controls'] if c['title'].startswith(prefix)), None)


try:
    window = None
    for _ in range(200):
        found = subprocess.run(['xdotool', 'search', '--name', 'Threading document renderer'],
                               text=True, capture_output=True).stdout.split()
        if found:
            window = found[-1]
            break
        time.sleep(.05)
    assert window, 'stream window did not open'
    partial = eventually(lambda s: s['stream']['streaming'] and s['stream']['longestStreamingText'] > 0,
                         'visible streaming tail')
    for _ in range(20):
        capture('stream-partial.png')
        if pane_has_ink('stream-partial.png'):
            break
        time.sleep(.05)
    assert pane_has_ink('stream-partial.png'), 'partial stream capture shows no row'
    still = state()['stream']
    assert still['settledTurns'] == 0 and still['diffRows'] == 0, ('capture outlived the stream', still)
    assert partial['stream']['settledTurns'] == 0 and partial['stream']['diffRows'] == 0, partial
    settled = eventually(lambda s: s['stream']['settledTurns'] == 1 and not s['stream']['streaming'],
                         'first settled turn')
    first_seconds = time.monotonic() - started
    stream = settled['stream']
    assert stream['outcome'] == 'completed' and stream['model'] == 'fixture-model', stream
    assert stream['lines'] == 7 and stream['malformedLines'] == 0 and stream.get('failure') is None, stream
    assert stream['streamingUpdates'] == 3, stream
    assert stream['markdownBlocks'] == 4 and stream['diffRows'] == 1, stream
    assert settled['appDiffViews'] == 1 and settled['totalRows'] == 5, settled
    paragraph = control(settled, 'This reply arrived')
    assert paragraph and 'räksmörgås, 中文 and 👩🏽‍🚀' in paragraph['title'], settled['controls']
    capture('stream-settled.png')
    xdo('windowfocus', '--sync', window)
    xdo('mousemove', '--window', window, paragraph['x'] + 20, paragraph['y'] + 12, 'click', 1)
    xdo('key', 'ctrl+a', 'ctrl+c')
    eventually(lambda s: copied(paragraph['title']), 'transport-fed Unicode copy')
    xdo('key', 'F10')
    second = eventually(lambda s: s['stream']['settledTurns'] == 2 and not s['stream']['streaming'],
                        'second turn on the same child')
    echo = control(second, 'Second turn, same process.')
    assert echo and echo['title'].endswith(SECOND), second['controls']
    assert second['stream']['lines'] == 10 and second['stream']['markdownBlocks'] == 5, second['stream']
    capture('stream-second-turn.png')
    xdo('key', 'F11')
    final = eventually(lambda s: s['stream'].get('exitStatus') is not None, 'child exit after stdin EOF',
                       file='final.json')
    assert final['stream']['exitStatus'] == 0, final['stream']
    assert final['stream']['diagnostic'] == ('stream fixture agent ready\n'
                                             'stream fixture agent answered 2 turns'), final['stream']
    process.wait(timeout=10)
    assert process.returncode == 0, process.returncode
    print(f'PASS live stream-json child: production transport, parser and timeline into shared rows; '
          f'streaming tail, settled reply and edit diff, Unicode copy, second turn on one process, '
          f'clean EOF and bounded diagnostic; first turn {first_seconds:.3f}s', flush=True)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
