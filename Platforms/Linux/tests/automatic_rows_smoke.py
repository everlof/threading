"""Drive the shared conversation cell host and shim automatic heights in the native shell."""
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
process = subprocess.Popen([binary, '--automatic-rows-ui-fixture', str(output)], stdout=log, stderr=log)


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


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=8)


def paragraph(current):
    return next((c for c in current['controls'] if c['title'].startswith('Select this')), None)


def copied_text(expected):
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', 'UTF8_STRING', '-o'],
                            capture_output=True, timeout=3)
    return result.returncode == 0 and result.stdout == expected.encode('utf-8')


def page(key):
    actions = state()['navigationActions']
    xdo('key', key)
    return eventually(lambda s: s['navigationActions'] > actions, 'native page action')


try:
    first = eventually(lambda s: paragraph(s) is not None, 'automatic first viewport')
    first_seconds = time.monotonic() - started
    assert first['totalRows'] > 60 and first['mountedRows'] < 12, first
    assert first['constructedCells'] < 12, first
    wide = paragraph(first)
    assert 80 < wide['y'] < 500 and wide['height'] > 70, wide
    window = subprocess.check_output(['xdotool', 'search', '--name', 'Threading document renderer'], text=True).splitlines()[-1]
    xdo('windowfocus', '--sync', window)
    capture('automatic-open.png')
    xdo('mousemove', '--window', window, wide['x'] + 20, wide['y'] + 20, 'click', 1)
    serial = state()['serial']
    xdo('key', 'ctrl+a', 'ctrl+c')
    eventually(lambda s: s['serial'] > serial and any(c['selectedLength'] > 0 for c in s['controls']), 'automatic selected copy')
    eventually(lambda s: copied_text(wide['title']), 'native clipboard receipt')
    xdo('windowsize', '--sync', window, 840, 640)
    narrow = eventually(lambda s: paragraph(s) is not None and paragraph(s)['width'] < wide['width'], 'automatic width reflow')
    assert paragraph(narrow)['height'] > wide['height'], paragraph(narrow)
    assert narrow['mountedRows'] < 12 and narrow['constructedCells'] < 16, narrow
    capture('automatic-narrow.png')
    xdo('windowsize', '--sync', window, 1120, 900)
    eventually(lambda s: paragraph(s) is not None and paragraph(s)['width'] == wide['width'], 'restored automatic width')
    xdo('mousemove', '--window', window, 1000, 500)
    for _ in range(2):
        page('Next')
    middle = eventually(lambda s: paragraph(s) is None and any(c['title'].startswith('Paragraph ') for c in s['controls']), 'middle viewport')
    anchor = next(c for c in middle['controls'] if c['title'].startswith('Paragraph '))
    configured = middle['configuredCells']
    total = middle['totalRows']
    (output / 'middle-state.json').write_text(json.dumps(middle, indent=2))
    capture('automatic-middle.png')
    xdo('key', 'F6')
    inserted = eventually(lambda s: s['totalRows'] == total + 1, 'insert above viewport')
    (output / 'inserted-state.json').write_text(json.dumps(inserted, indent=2))
    retained = next(c for c in inserted['controls'] if c['title'] == anchor['title'])
    assert retained['y'] == anchor['y'] and retained['selectedLength'] == anchor['selectedLength'], (anchor, retained)
    assert inserted['configuredCells'] == configured and inserted['liveContents'] == inserted['mountedRows'], inserted
    capture('automatic-insert.png')
    xdo('key', 'F7')
    removed = eventually(lambda s: s['totalRows'] == total, 'remove above viewport')
    assert next(c for c in removed['controls'] if c['title'] == anchor['title'])['y'] == anchor['y'], removed
    assert removed['configuredCells'] == configured and removed['liveContents'] == removed['mountedRows'], removed
    xdo('key', 'F8')
    appended = eventually(lambda s: s['totalRows'] == total + 1, 'offscreen tail append')
    assert appended['configuredCells'] == configured and appended['liveContents'] == appended['mountedRows'], appended
    xdo('key', 'F9')
    trimmed = eventually(lambda s: s['totalRows'] == total, 'offscreen tail removal')
    assert trimmed['configuredCells'] == configured, trimmed
    for _ in range(20):
        current = state()
        if any(c['title'].startswith('Paragraph 60.') for c in current['controls']):
            break
        page('Next')
    else:
        raise AssertionError('last automatic row never mounted')
    tail = state()
    assert tail['mountedRows'] < 12 and tail['constructedCells'] < 20, tail
    assert paragraph(tail) is None, 'offscreen paragraph remained mounted'
    capture('automatic-tail.png')
    for _ in range(20):
        if paragraph(state()) is not None:
            break
        page('Prior')
    else:
        raise AssertionError('first paragraph did not remount')
    capture('automatic-return.png')
    print(f'PASS shared automatic conversation hosts: native Unicode copy, width reflow, anchored incremental insert/remove, offscreen tail edits, bounded cells, tail and return; first frame {first_seconds:.3f}s', flush=True)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    log.close()
