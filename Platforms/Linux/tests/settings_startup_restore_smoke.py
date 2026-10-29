"""The shared General toggle controls Linux's selected live session on relaunch."""
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib


binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'settings-startup-restore'
root.mkdir()
project = root / 'Project'
project.mkdir()
store = root / 'store'
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
home = root / 'home'
home.mkdir()
config = home / '.config'
config.mkdir()
environment = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config),
                   THREADING_LINUX_DATA_DIR=str(root / 'data'))
subprocess.run([host, '--add-project', str(store), str(project)],
               env=environment, capture_output=True, check=True, timeout=15)
child = Path(__file__).with_name('saved_terminal_child.py').resolve()
marker = root / 'starts.jsonl'
Atspi.init()
process = None
log = None


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: {Path(log.name).read_text()[-4000:]}'
        try:
            result = read()
            if result:
                return result
        except (GLib.GError, IndexError, subprocess.CalledProcessError) as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {Path(log.name).read_text()[-4000:]}')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True, timeout=5).strip()


def title(expected):
    def read():
        matches = xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                      '--name', expected).splitlines()
        return matches[0] if matches else None
    return eventually(read, expected)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def app():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_process_id() == process.pid and candidate.get_name() == 'Threading Linux':
            return candidate
    return None


def launch(name):
    global process, log, window
    log = (output / f'{name}.log').open('w+')
    process = subprocess.Popen([binary, '--app', str(store), endpoint,
                                '/usr/bin/python3', str(child), str(marker)],
                               env=environment, stdout=log, stderr=log)
    window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                    '--name', '^Threading').splitlines()[0], 'native window')


def close():
    global process, log
    key('alt+F4')
    assert process.wait(timeout=6) == 0, Path(log.name).read_text()
    log.close()
    process = log = None


def set_restore(enabled):
    application = eventually(app, 'AT-SPI application')
    def footer():
        frame = application.get_child_at_index(0)
        return next((frame.get_child_at_index(index)
                     for index in range(frame.get_child_count())
                     if frame.get_child_at_index(index).get_accessible_id() == 'sidebar.settings'), None)
    settings = eventually(footer, 'Settings footer')
    assert settings.get_action_iface().do_action(0), 'Settings press refused'
    eventually(lambda: xdo('getwindowname', window) == 'Threading - Settings',
               'General page')
    def settings_control(identifier):
        frame = application.get_child_at_index(0)
        panel = next((frame.get_child_at_index(index)
                      for index in range(frame.get_child_count())
                      if frame.get_child_at_index(index).get_accessible_id() == 'settings.panel'), None)
        if panel is None:
            return None
        return next((panel.get_child_at_index(index)
                     for index in range(panel.get_child_count())
                     if panel.get_child_at_index(index).get_accessible_id() == identifier), None)
    toggle = eventually(lambda: settings_control('settings.general.restore-last-session'),
                        'shared Settings toggle')
    assert toggle.get_name() == 'Reopen the last session at launch'
    assert toggle.get_action_iface().get_n_actions() == 1
    assert settings_control('settings.general.session-restore-policy') is not None
    assert settings_control('settings.general.done') is not None
    anchor = eventually(lambda: re.findall(
        r'SETTINGS_RESTORE_ANCHOR x=([\d.]+) y=([\d.]+) width=([\d.]+) height=([\d.]+)',
        Path(log.name).read_text()), 'Startup toggle geometry')[-1]
    x, y, width, height = map(float, anchor)
    width_pixels, height_pixels, scale = map(int, re.search(
        r'WORKSPACE_WINDOW pixels=(\d+)x(\d+) scale=(\d+)',
        Path(log.name).read_text()).groups())
    sidebar = int(re.search(r'WORKSPACE_GEOMETRY scale=\d+ sidebar=(\d+)',
                            Path(log.name).read_text()).group(1))
    target_x = round((sidebar + x + width / 2) * scale)
    target_y = round(height_pixels - (y + height / 2) * scale)
    assert 0 < target_x < width_pixels and 0 < target_y < height_pixels
    if not enabled:
        subprocess.run(['import', '-window', window, str(output / 'startup-enabled.png')],
                       check=True, timeout=5)
    assert toggle.get_action_iface().do_action(0), 'Settings toggle AT-SPI action refused'
    eventually(lambda: f'SETTINGS_RESTORE_CHANGED enabled={str(enabled).lower()}'
               in Path(log.name).read_text(), 'Startup toggle mutation')
    key('ctrl+comma')
    eventually(lambda: xdo('getwindowname', window) != 'Threading - Settings',
               'workspace return')


try:
    launch('first')
    title('^Threading experiment - ')
    key('Return')
    title('^Threading terminal - SAVED SHELL 1 READY')
    set_restore(False)
    close()

    launch('disabled')
    title('^Threading experiment - ')
    assert len(marker.read_text().splitlines()) == 1, 'disabled restore restarted the shell'
    set_restore(True)
    close()

    launch('enabled')
    title('^Threading terminal - SAVED SHELL 1 READY')
    assert len(marker.read_text().splitlines()) == 1, 'enabled restore duplicated the shell'
    close()
    print('PASS General Startup toggle: durable off/on selection and live reattach')
finally:
    if process is not None:
        process.kill()
        process.wait(timeout=5)
    if log is not None:
        log.close()
