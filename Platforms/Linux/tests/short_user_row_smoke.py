"""The production short-user row in the native document shell."""
import json
from pathlib import Path
import subprocess
import sys
import time

binary, destination = sys.argv[1:]
root = Path(destination)
root.mkdir(parents=True, exist_ok=True)
log = (root / 'window.log').open('w')
process = subprocess.Popen([binary, '--short-user-bubble-ui-fixture', str(root)], stdout=log, stderr=log)


def eventually(predicate, timeout=25):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, (root / 'window.log').read_text()[-3000:]
        try:
            state = json.loads((root / 'state.json').read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(.05)
            continue
        if predicate(state):
            return state
        time.sleep(.05)
    raise AssertionError('short user row did not reach its rendered state')


def bright_text_pixels(state):
    label = state['controls'][0]
    crop = f"{label['width']}x{label['height']}+{label['x']}+{label['y']}"
    pixels = subprocess.check_output(['convert', str(root / 'frame.png'), '-crop', crop,
                                      '+repage', '-depth', '8', 'rgb:-'])
    return sum(min(pixels[index:index + 3]) > 150 for index in range(0, len(pixels), 3))


try:
    state = eventually(lambda value: value['controls'] and value['controls'][0]['completeViewportReady'])
    assert state['totalRows'] == 1
    assert len(state['controls']) == 1, state['controls']
    label = state['controls'][0]
    assert label['title'] == 'Short prompt é 日本語 👩🏽‍🚀', label
    assert label['x'] > 500 and label['width'] < 574, label
    assert state['documentHeight'] < 100, state['documentHeight']
    (root / 'short-light.png').write_bytes((root / 'frame.png').read_bytes())
    subprocess.run(['xdotool', 'key', 'ctrl+shift+t'], check=True)
    eventually(lambda value: value['dark'] and value['controls'][0]['completeViewportReady']
               and bright_text_pixels(value) > 600)
    (root / 'short-dark.png').write_bytes((root / 'frame.png').read_bytes())
    print('PASS short production user row: right alignment, compact height, selectable Unicode, no long-message controls, live dark appearance')
finally:
    subprocess.run(['xdotool', 'key', 'Escape'], check=False)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
