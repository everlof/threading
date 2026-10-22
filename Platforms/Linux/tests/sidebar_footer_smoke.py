"""Exercise the shared sidebar footer in the real two-pane Linux window."""
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib

binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'sidebar-footer'
root.mkdir()
project = root / 'Project'
project.mkdir()
store = root / 'store'
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
environment = dict(os.environ, HOME=str(root / 'home'), THREADING_LINUX_UI_SCALE='2',
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
(root / 'home').mkdir()
subprocess.run([host, '--add-project', str(store), str(project)],
               env=environment, check=True, capture_output=True, timeout=20)
log_path = output / 'window.log'
log = log_path.open('w')
process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                           env=environment, stdout=log, stderr=log)
Atspi.init()


def eventually(read, label, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {label}: {log_path.read_text()[-3000:]}'
        try:
            result = read()
            if result:
                return result
        except (GLib.GError, FileNotFoundError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()[-3000:]}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *args], text=True, timeout=5).strip()


def settings_control():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() != process.pid or app.get_name() != 'Threading Linux':
            continue
        frame = app.get_child_at_index(0)
        for child in range(frame.get_child_count()):
            control = frame.get_child_at_index(child)
            if control is not None and control.get_accessible_id() == 'sidebar.settings':
                return control
    return None


def capture(window, name):
    subprocess.run(['import', '-window', window, str(output / name)], check=True, timeout=10)


try:
    eventually(lambda: 'IDLE_PANE_FRAME ' in log_path.read_text(), 'opening workspace')
    window = eventually(lambda: xdo('search', '--onlyvisible', '--name', '^Threading').splitlines()[0],
                        'window')
    xdo('windowsize', window, '1600', '900')
    settings = eventually(settings_control, 'Settings footer accessibility control')
    bounds = settings.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    assert bounds.width > 0 and bounds.height > 0, bounds
    capture(window, 'sidebar-footer.png')

    frames = log_path.read_text().count('SETTINGS_FRAME ')
    assert settings.get_action_iface().do_action(0), 'Settings accessibility press was refused'
    eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ') > frames,
               'rendered Settings pane after accessibility press')
    eventually(lambda: xdo('getwindowname', window) == 'Threading - Settings', 'Settings title')
    capture(window, 'settings-from-accessibility.png')

    xdo('windowfocus', '--sync', window, 'key', 'ctrl+comma')
    eventually(lambda: 'SETTINGS_CLOSED' in log_path.read_text(), 'Settings close shortcut')
    eventually(lambda: xdo('getwindowname', window) != 'Threading - Settings',
               'workspace title restored')

    settings = eventually(settings_control, 'Settings footer after closing')
    bounds = settings.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    frames = log_path.read_text().count('SETTINGS_FRAME ')
    xdo('mousemove', str(bounds.x + bounds.width // 2),
        str(bounds.y + bounds.height // 2), 'click', '1')
    eventually(lambda: log_path.read_text().count('SETTINGS_FRAME ') > frames,
               'rendered Settings pane after pointer press')
    capture(window, 'settings-from-pointer.png')
    print('PASS shared Settings footer: layout, AT-SPI press, close shortcut and pointer press')
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    log.close()
