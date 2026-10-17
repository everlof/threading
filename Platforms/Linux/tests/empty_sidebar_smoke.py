"""Real empty sidebar and desktop folder drops, with no fabricated project row."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi
from runtime_pixel_contract import assert_opening_prompt_surface, opening_prompt_frame, assert_placeholder_ink

binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:]
scale = int(os.environ.get('THREADING_LINUX_UI_SCALE', '1'))
root = Path(fixture) / f'empty-sidebar-{scale}'
root.mkdir()
store = root / 'store'
folder = root / 'Dropped å project'
folder.mkdir()
invalid = root / 'ordinary file.txt'
invalid.write_text('A file is not a project directory.')
output = Path(evidence)
output.mkdir(parents=True)
log_path = output / 'journey.log'
subprocess.run([host, '--init-store', str(store)], check=True, capture_output=True)
Atspi.init()
process = None
source = None


def daemon_children(capture_name):
    snapshot = json.loads(subprocess.check_output(
        [daemon, 'sessions', '--json', '--socket', endpoint], text=True, timeout=8))
    (output / (capture_name + '.json')).write_text(json.dumps(snapshot, indent=2) + '\n')
    # Earlier journeys share this daemon. Their uptime advances and children may still
    # be reaped; import must preserve process identity, not freeze mutable metadata.
    return {(item['id'], item['pid']) for item in snapshot}


initial_children = daemon_children('daemon-before')


def xdo(*args):
    return subprocess.check_output(['xdotool', *map(str, args)], text=True,
                                   stderr=subprocess.DEVNULL, timeout=8).strip()


def eventually(read, label):
    deadline = time.monotonic() + 15
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, log_path.read_text()
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.04)
    raise AssertionError(f'{label}: {last}; {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    return next((desktop.get_child_at_index(index) for index in range(desktop.get_child_count())
                 if desktop.get_child_at_index(index).get_process_id() == process.pid), None)


def listing():
    frame = app.get_child_at_index(0)
    return next(frame.get_child_at_index(index) for index in range(frame.get_child_count())
                if frame.get_child_at_index(index).get_role_name() == 'list')


def records():
    with sqlite3.connect(store / 'threading.db') as database:
        return [json.loads(row[0]) for row in database.execute('SELECT data FROM project')]


def capture(name):
    subprocess.run(['import', '-window', window, str(output / (name + '.png'))],
                   check=True, timeout=8)


def key(value):
    xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value)


def drop(path):
    global source
    source_log = (output / 'drag-source.log').open('a')
    source = subprocess.Popen([sys.executable, str(Path(__file__).with_name('folder_drop_source.py')),
                               str(path)], stdout=source_log, stderr=source_log)
    try:
        source_window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', source.pid,
                                               '--name', '^Threading folder drop source$'), 'drag source')
        source_pid = source.pid
        eventually(lambda: f'DRAG_READY {source_pid}' in (output / 'drag-source.log').read_text(),
                   'GTK drag source ready')
        geometry = dict(line.split('=', 1) for line in xdo('getwindowgeometry', '--shell', window).splitlines())
        source_x = int(geometry['WIDTH']) - 190
        xdo('windowmove', '--sync', source_window, source_x, 100)
        # Real XTest pointer input: GTK owns the selection and SDL handles Xdnd on the product window.
        xdo('mousemove', '--sync', source_x + 80, 140, 'mousedown', 1, 'sleep', '.2',
            'mousemove', '--sync', source_x + 60, 140, 'sleep', '.2',
            'mousemove', '--sync', 120 * scale, 180 * scale, 'sleep', '.5', 'mouseup', 1)
        # Keep the selection owner alive until SDL has requested and received the URI.
        # A fixed post-release sleep could kill GTK before Xdnd completed under build load.
        eventually(lambda: f'DRAG_DATA {source_pid}' in (output / 'drag-source.log').read_text()
                   and f'DRAG_END {source_pid}' in (output / 'drag-source.log').read_text(),
                   'native drag transfer completed')
    finally:
        source.terminate()
        source.wait(timeout=5)
        source = None
        source_log.close()


try:
    with log_path.open('w') as log:
        process = subprocess.Popen([binary, '--app', str(store), endpoint, '/bin/sh'],
                                   stdout=log, stderr=log)
        app = eventually(application, 'product accessibility')
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid', process.pid,
                                        '--name', '^Threading experiment - empty store$'), 'product window')
        xdo('windowmove', '--sync', window, 0, 0)
        eventually(lambda: listing().get_child_count() == 0 and 'No Projects' in listing().get_description(),
                   'empty accessible navigator')
        assert listing().get_selection_iface().get_n_selected_children() == 0
        assert 'Drop a folder here, or click + above.' in listing().get_description()
        frame = app.get_child_at_index(0)
        composer = next(frame.get_child_at_index(i) for i in range(frame.get_child_count())
                        if frame.get_child_at_index(i).get_role_name() == 'panel')
        editor = next(composer.get_child_at_index(i) for i in range(composer.get_child_count())
                      if composer.get_child_at_index(i).get_accessible_id() == 'linux.composer.editor')
        editor_bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert opening_prompt_frame(editor_bounds, scale)['height'] == 116 * scale
        palette = json.loads((Path(binary).parent /
            'LinuxAppKitSpike_WindowHarness.resources/Theme/threading.json').read_text())
        project_chip = next(composer.get_child_at_index(i) for i in range(composer.get_child_count())
                            if composer.get_child_at_index(i).get_accessible_id() == 'linux.composer.project')
        chip_bounds = project_chip.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        capture('empty-light')
        assert_opening_prompt_surface(output / 'empty-light.png', editor_bounds, palette['light'], scale)
        assert_placeholder_ink(output / 'empty-light.png', palette['light'], chip_bounds, scale)
        key('ctrl+shift+t')
        eventually(lambda: 'THEME_APPEARANCE dark' in log_path.read_text()
                   and '\nFRAME ' in log_path.read_text().rsplit('THEME_APPEARANCE dark', 1)[-1],
                   'dark appearance presented')
        capture('empty-dark')
        assert_opening_prompt_surface(output / 'empty-dark.png', editor_bounds, palette['dark'], scale)
        assert_placeholder_ink(output / 'empty-dark.png', palette['dark'], chip_bounds, scale)
        key('ctrl+shift+t')
        eventually(lambda: 'THEME_APPEARANCE light' in log_path.read_text()
                   and '\nFRAME ' in log_path.read_text().rsplit('THEME_APPEARANCE light', 1)[-1],
                   'light appearance presented')
        frame = app.get_child_at_index(0)
        composer = next(frame.get_child_at_index(i) for i in range(frame.get_child_count())
                        if frame.get_child_at_index(i).get_role_name() == 'panel')
        controls = {composer.get_child_at_index(i).get_accessible_id(): composer.get_child_at_index(i)
                    for i in range(composer.get_child_count())}
        editor = controls['linux.composer.editor']
        submit = controls['linux.placeholder.action']
        assert not controls['linux.composer.project'].get_state_set().contains(Atspi.StateType.ENABLED)
        assert not controls['linux.composer.provider'].get_state_set().contains(Atspi.StateType.ENABLED)
        assert editor.get_editable_text_iface().set_text_contents('Keep this draft through import')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Keep this draft through import',
                   'standing draft without a project')
        assert not submit.get_state_set().contains(Atspi.StateType.ENABLED)
        assert submit.get_action_iface().get_n_actions() == 0
        drop(invalid)
        eventually(lambda: 'PROJECT_IMPORT_REFUSED selected project directory does not exist' in log_path.read_text(),
                   'ordinary file refused')
        assert records() == [] and listing().get_child_count() == 0
        drop(folder)
        eventually(lambda: log_path.read_text().count('PROJECT_IMPORTED ') == 1, 'native folder imported')
        eventually(lambda: listing().get_child_count() == 1, 'real project replaces empty message')
        first = records()
        assert len(first) == 1 and first[0]['folderPath'] == str(folder)
        assert first[0]['terminals'] == [] and first[0]['sessions'] == []
        assert listing().get_selection_iface().get_selected_child(0).get_accessible_id() == first[0]['id']
        assert 'No Projects' not in listing().get_description()
        eventually(lambda: controls['linux.composer.project'].get_state_set().contains(Atspi.StateType.ENABLED),
                   'import enables project choice')
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == 'Keep this draft through import'
        assert not submit.get_state_set().contains(Atspi.StateType.ENABLED), 'missing agent must still refuse launch'
        capture('imported')
        drop(folder)
        eventually(lambda: log_path.read_text().count('PROJECT_IMPORTED ') == 2, 'duplicate folder handled')
        assert records() == first, 'duplicate drop changed project identity or fields'
        assert daemon_children('daemon-after') == initial_children, 'folder import changed daemon children'
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        print(f'PASS empty sidebar scale={scale}: no fake row, accessible hint, live theme, native Unicode folder drop, file refusal and duplicate identity')
finally:
    if source is not None:
        source.terminate()
        source.wait(timeout=5)
    if process is not None and process.poll() is None:
        process.kill()
        process.wait(timeout=5)
