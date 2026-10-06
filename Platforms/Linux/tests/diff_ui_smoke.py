"""Drive the exact upstream diff renderer and shared Threading palette in a native row."""
import json
from pathlib import Path
import subprocess
import sys
import time

binary, destination = sys.argv[1:]
output = Path(destination)
output.mkdir(parents=True, exist_ok=True)
log = (output / 'window.log').open('w')
started = time.monotonic()
process = subprocess.Popen([binary, '--diff-ui-fixture', str(output)], stdout=log, stderr=log)


def state():
    assert process.poll() is None, (output / 'window.log').read_text()[-3000:]
    try:
        return json.loads((output / 'state.json').read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def eventually(predicate, name, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = state()
        if current and predicate(current):
            return current
        time.sleep(.05)
    raise AssertionError(f'{name}: {state()}')


def xdo(*args):
    subprocess.run(['xdotool', *map(str, args)], check=True, timeout=8)


def field(current):
    return next((c for c in current['controls'] if '// Unicode' in c['title']), None)


def capture(name):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=8)
    return path


def check_washes(path, current):
    # Read actual captured window pixels through ImageMagick, available in both runners.
    for sign, role in [('+', 'addedWash'), ('−', 'removedWash')]:
        gutter = next(c for c in current['controls'] if c['title'] == sign)
        x = gutter['x'] + gutter['width'] - 3
        y = gutter['y'] + 3
        raw = subprocess.check_output(['convert', str(path), '-crop', f'1x1+{x}+{y}', '-depth', '8', 'rgba:-'])
        expected = bytes(round(channel * 255) for channel in current[role])
        assert raw == expected, (sign, list(raw), list(expected), gutter)


def copied(expected):
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-o'], text=True,
                            capture_output=True, timeout=3)
    return result.returncode == 0 and result.stdout == expected


try:
    first = eventually(lambda s: field(s) is not None and s['diffLines'] == 8, 'authoritative diff row')
    first_seconds = time.monotonic() - started
    assert first['timelineRows'] == 2 and first['streamingCleared'], first
    assert first['totalRows'] == first['mountedRows'] == first['liveContents'] == 1, first
    assert first['constructedCells'] == first['configuredCells'] == 1, first
    assert first['appDiffViews'] == 1 and first['contextReference'] == 'greeting.swift', first
    assert first['contextPreviewRows'] == 3, first
    wide = field(first)
    assert abs(wide['width'] - 644) <= 2, ('shared host lost its 344-point content width', wide)
    (output / 'wide-state.json').write_text(json.dumps(first, indent=2))
    assert 80 < wide['y'] < 700 and wide['height'] > 30, wide
    window = subprocess.check_output(['xdotool', 'search', '--name', 'Threading document renderer'], text=True).splitlines()[-1]
    xdo('windowfocus', '--sync', window)
    check_washes(capture('diff-light.png'), first)
    xdo('mousemove', '--window', window, wide['x'] + 30, wide['y'] + 8, 'click', 1)
    xdo('key', 'ctrl+a', 'ctrl+c')
    selected = eventually(lambda s: field(s)['selectedLength'] > 0, 'diff text selection')
    eventually(lambda s: copied(wide['title']), 'exact Unicode diff clipboard')
    capture('diff-selected.png')
    xdo('type', '--clearmodifiers', 'MUTATED')
    assert field(state())['title'] == wide['title'], 'diff became editable'
    xdo('key', 'ctrl+shift+t')
    dark = eventually(lambda s: s['dark'] and field(s) is not None, 'diff live dark palette')
    assert dark['addedWash'] != first['addedWash'] and dark['removedWash'] != first['removedWash'], dark
    check_washes(capture('diff-dark.png'), dark)
    xdo('windowsize', '--sync', window, 840, 640)
    narrow = eventually(lambda s: field(s) is not None and field(s)['width'] < wide['width'], 'diff width reflow')
    assert field(narrow)['height'] > wide['height'], (wide, field(narrow))
    (output / 'narrow-state.json').write_text(json.dumps(narrow, indent=2))
    assert narrow['mountedRows'] == narrow['liveContents'] == narrow['constructedCells'] == 1, narrow
    check_washes(capture('diff-narrow.png'), narrow)
    xdo('mousemove', '--window', window, field(narrow)['x'] + 30, field(narrow)['y'] + 8, 'click', 1)
    xdo('key', 'ctrl+a', 'ctrl+c')
    eventually(lambda s: copied(wide['title']), 'narrow Unicode diff clipboard')
    print(f'PASS authoritative edit diff: exact upstream renderer/shared palette, row washes, Unicode copy, readonly text, theme and width reflow; first frame {first_seconds:.3f}s', flush=True)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    log.close()
