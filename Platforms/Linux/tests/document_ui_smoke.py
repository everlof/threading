"""Exercise the production Markdown document in WindowHarness's native shell."""
import json
from pathlib import Path
import subprocess
import sys
import time
from x11_cursor import NativeCursor

binary, output_path = sys.argv[1:]
output = Path(output_path)
output.mkdir(parents=True, exist_ok=True)
log = (output / 'window.log').open('w')
started = time.monotonic()
process = subprocess.Popen([binary, '--document-ui-fixture', str(output)], stdout=log, stderr=subprocess.STDOUT)
cursor = NativeCursor()


def state():
    if process.poll() is not None:
        raise AssertionError(f'window exited {process.returncode}: {(output / "window.log").read_text()[-2500:]}')
    try:
        return json.loads((output / 'state.json').read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def eventually(predicate, description, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = state()
        if current is not None and predicate(current):
            return current
        time.sleep(.05)
    raise AssertionError(f'timed out: {description}')


def xdo(*args):
    subprocess.run(['xdotool', *map(str, args)], check=True, timeout=8)


def click(control):
    xdo('mousemove', '--window', window, control['x'] + control['width'] // 2,
        control['y'] + control['height'] // 2, 'click', 1)


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=8)


try:
    opened = eventually(lambda s: any(c['title'].startswith('Select this') for c in s['controls']), 'first document frame')
    first_frame_seconds = time.monotonic() - started
    assert opened['timelineRows'] == 2 and opened['streamingCleared'], opened
    window = subprocess.check_output(['xdotool', 'search', '--name', 'Threading document renderer'], text=True).splitlines()[-1]
    xdo('windowfocus', '--sync', window)
    paragraph = next(c for c in opened['controls'] if c['title'].startswith('Select this'))
    code = next(c for c in opened['controls'] if c['title'].startswith('let greeting'))
    assert paragraph['y'] > 0 and paragraph['height'] >= 52, paragraph
    assert code['height'] >= 40, code
    assert 60 < code['y'] < 760, code
    assert len(opened['controls']) < 100, len(opened['controls'])
    capture('document-open.png')
    serial = state()['serial']
    xdo('mousemove', '--window', window, 600, 30)
    eventually(lambda s: s['serial'] > serial, 'header pointer delivered')
    arrow = cursor.read(output / 'cursor-arrow.png')
    click(paragraph)
    eventually(lambda s: cursor.read() != arrow, 'native selectable paragraph cursor')
    cursor.read(output / 'cursor-text.png')
    serial = state()['serial']
    xdo('mousemove', '--window', window, 600, 30)
    eventually(lambda s: s['serial'] > serial, 'pointer returned to header')
    eventually(lambda s: cursor.read() == arrow, 'header restores native arrow')
    click(paragraph)
    xdo('key', 'ctrl+a')
    selected = eventually(lambda s: any(c['title'] == paragraph['title'] and c['selectedLength'] > 0
                                       for c in s['controls']), 'selected paragraph')
    serial = state()['serial']
    xdo('key', 'ctrl+c')
    eventually(lambda s: s['serial'] > serial, 'copy key handled')
    copied = subprocess.check_output(['xclip', '-selection', 'clipboard', '-o'], text=True, timeout=8)
    assert copied == paragraph['title'], (copied, paragraph['title'])
    xdo('key', 'BackSpace')
    eventually(lambda s: s['serial'] > selected['serial'], 'read-only key redraw')
    assert any(c['title'] == copied for c in state()['controls'])
    capture('document-selected.png')

    xdo('key', 'ctrl+shift+t')
    eventually(lambda s: s['dark'], 'live dark appearance')
    capture('document-dark.png')
    xdo('key', 'ctrl+shift+t')
    eventually(lambda s: not s['dark'], 'live light appearance')
    heading = next(c for c in state()['controls'] if c['title'].startswith('A shared conversation'))
    wide_paragraph = next(c for c in state()['controls'] if c['title'].startswith('Select this'))
    gap_y = (heading['y'] + heading['height'] + wide_paragraph['y']) // 2
    xdo('mousemove', '--window', window, 600, gap_y)
    eventually(lambda s: cursor.read() == arrow, 'native arrow in document gap')
    xdo('windowsize', '--sync', window, 840, 640)
    narrow = eventually(lambda s: any(c['title'].startswith('Select this') and c['width'] < paragraph['width']
                                      for c in s['controls']), 'narrow document reflow')
    narrow_paragraph = next(c for c in narrow['controls'] if c['title'].startswith('Select this'))
    assert narrow_paragraph['height'] >= paragraph['height'], narrow_paragraph
    assert narrow_paragraph['y'] > 0, narrow_paragraph
    eventually(lambda s: cursor.read() != arrow, 'stationary pointer follows resized heading')
    cursor.read(output / 'cursor-resize-heading.png')
    capture('document-narrow.png')
    xdo('windowsize', '--sync', window, 1120, 900)
    eventually(lambda s: any(c['title'].startswith('Select this') and c['width'] == paragraph['width']
                             for c in s['controls']), 'restored document width')
    eventually(lambda s: cursor.read() == arrow, 'restored size returns stationary pointer to gap')

    for _ in range(12):
        current = state()
        next_button = next(c for c in current['controls'] if c['title'] == 'Next')
        if 60 < next_button['y'] < 840:
            break
        serial = current['serial']
        xdo('key', 'Next')
        eventually(lambda s: s['serial'] > serial, 'page-down scroll')
    else:
        raise AssertionError('document pager never entered viewport')
    capture('document-pager.png')
    click(next_button)
    last = eventually(lambda s: any(c['title'].startswith('Paragraph 60.') for c in s['controls']), 'last document page')
    assert not any(c['title'].startswith('Select this') for c in last['controls'])
    assert len(last['controls']) < len(opened['controls'])
    capture('document-last-page.png')
    print(f'PASS production wire/timeline/shared document: native cursors with stationary resize, wrapping, code, selected Unicode copy, readonly text, theme, resize and bounded paging; first frame {first_frame_seconds:.3f}s', flush=True)
finally:
    cursor.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    log.close()
