"""The production long-user-message bubble, including complete-label worker delivery."""
import json
from pathlib import Path
import subprocess
import sys
import time

binary, output_path = sys.argv[1:]
output = Path(output_path)
output.mkdir(parents=True, exist_ok=True)
log = (output / 'window.log').open('w')
process = subprocess.Popen([binary, '--user-bubble-ui-fixture', str(output)], stdout=log, stderr=subprocess.STDOUT)


def state():
    assert process.poll() is None, (output / 'window.log').read_text()[-3000:]
    try:
        return json.loads((output / 'state.json').read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def eventually(predicate, description, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = state()
        if value and predicate(value):
            return value
        time.sleep(.05)
    current = state()
    if current:
        current = dict(current, controls=[dict(c, title=c['title'][:80]) for c in current['controls']])
    raise AssertionError(f'{description}: {current}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *args], text=True, timeout=8).strip()


def click(control):
    xdo('mousemove', '--window', window, str(control['x'] + control['width'] // 2),
        str(control['y'] + control['height'] // 2), 'click', '1')


def field(value):
    return next(control for control in value['controls'] if control['title'].startswith('FIRST user message'))


def button(value, title):
    return next(control for control in value['controls'] if control['title'] == title)


def clipboard_matches(text):
    result = subprocess.run(['xclip', '-selection', 'clipboard', '-target', 'UTF8_STRING', '-o'],
                            capture_output=True, timeout=3)
    return result.returncode == 0 and result.stdout == text.encode('utf-8')


def capture(name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=8)


try:
    initial = eventually(lambda value: any(c['title'] == 'Show full message' for c in value['controls']), 'collapsed bubble')
    window = xdo('search', '--onlyvisible', '--pid', str(process.pid), '--name', 'Threading document renderer').splitlines()[0]
    xdo('windowfocus', '--sync', window)
    source = field(initial)['title']
    assert len(source.encode()) > 4096 and source.endswith('TAIL USER MESSAGE é 👩🏽‍🚀')
    assert initial['timelineRows'] == 1 and initial['mountedRows'] == 1
    assert field(initial)['height'] < 600
    click(button(initial, 'Copy'))
    eventually(lambda _: clipboard_matches(source), 'collapsed whole-message copy')
    capture('user-collapsed.png')

    click(button(state(), 'Show full message'))
    expanded = eventually(lambda value: field(value)['completeTextReady'] and
                          field(value)['completeViewportReady'] and field(value)['height'] > 10000,
                          'complete expanded text and automatic row height')
    assert expanded['constructedCells'] == initial['constructedCells']
    capture('user-expanded-head.png')
    xdo('mousemove', '--window', window, '700', '650', 'click', '--repeat', '12', '--delay', '1', '5')
    eventually(lambda value: value['scrollY'] > 0, 'native wheel advances the expanded document')
    xdo('key', 'F9')
    bottom = eventually(lambda value: button(value, 'Copy')['y'] < 850 and field(value)['completeViewportReady'], 'expanded footer in viewport')
    assert bottom['scrollY'] > 1000
    capture('user-expanded-tail.png')
    click(button(bottom, 'Copy'))
    eventually(lambda _: clipboard_matches(source), 'expanded whole-message copy')
    xdo('key', 'ctrl+shift+t')
    eventually(lambda value: value['dark'] and field(value)['completeViewportReady'], 'dark expanded tail')
    capture('user-expanded-dark.png')
    click(button(state(), 'Show less'))
    collapsed = eventually(lambda value: any(c['title'] == 'Show full message' for c in value['controls']) and
                           field(value)['height'] < 600, 'recollapse releases complete height')
    assert collapsed['constructedCells'] == initial['constructedCells']
    print('PASS production user bubble: fade/collapse, whole copy, complete expanded head/tail, worker repaint, automatic height and dark appearance')
finally:
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=8)
    log.close()
