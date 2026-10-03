"""Installed native outline: large catalog, real wheel viewport, and stable row identity."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time
import uuid

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, endpoint, fixture, evidence = sys.argv[1:]
root = Path(fixture) / 'native-outline-fixture'
root.mkdir()
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
project_count = 5_100
saved_count = 1_024
project_paths = [root / 'folders' / f'OutlineProject{index:04d}'
                 for index in range(project_count)]
for index in (0, 2_500, project_count - 1):
    project_paths[index].mkdir(parents=True)
subprocess.run([host, '--add-project', str(store), str(project_paths[0])],
               check=True, capture_output=True, timeout=12)

# Copy one host-authored project payload so this fixture uses the real database contract.
# Only three selected/visible folders need to exist; the remaining rows are catalogue data.
project_ids = []
terminal_ids = []
with sqlite3.connect(store / 'threading.db') as database:
    original_id, payload = database.execute('SELECT id, data FROM project').fetchone()
    original = json.loads(payload)
    project_ids.append(original_id)
    terminals = []
    for index in range(saved_count):
        identity = str(uuid.uuid5(uuid.NAMESPACE_URL, f'native-outline-terminal-{index}')).upper()
        terminal_ids.append(identity)
        terminals.append({'id': identity, 'title': f'Saved outline shell {index:04d}',
                          'currentDirectory': str(project_paths[0]), 'createdAt': 0})
    original['terminals'] = terminals
    database.execute('UPDATE project SET position = 0, data = ? WHERE id = ?',
                     (json.dumps(original), original_id))
    cloned = []
    for index in range(1, project_count):
        identity = str(uuid.uuid5(uuid.NAMESPACE_URL, f'native-outline-project-{index}')).upper()
        project_ids.append(identity)
        record = original.copy()
        record.update(id=identity, name=project_paths[index].name,
                      folderPath=str(project_paths[index]), terminals=[])
        cloned.append((identity, index, record['name'], record['folderPath'],
                       json.dumps(record, separators=(',', ':'))))
    database.executemany('INSERT INTO project (id, position, name, folder_path, data) '
                         'VALUES (?, ?, ?, ?, ?)', cloned)
    assert database.execute('SELECT COUNT(*) FROM project').fetchone()[0] == project_count
project_id_set = set(project_ids)

Atspi.init()
frame_pattern = re.compile(
    r'^OUTLINE_FRAME total=(\d+) first=(\d+) visible=(\d+) mounted=(\d+) '
    r'reusable=(\d+) scrollY=([0-9.eE+-]+)$', re.MULTILINE)
description_pattern = re.compile(r'^Showing (\d+) through (\d+) of (\d+) items$')


def xdo(*arguments):
    return subprocess.run(['xdotool', *arguments], check=True, capture_output=True,
                          text=True, timeout=8).stdout.strip()


def eventually(read, label, process, log_path, timeout=75):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: native window exited: {log_path.read_text()[-8000:]}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; native log: {log_path.read_text()[-8000:]}')


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        candidate = desktop.get_child_at_index(index)
        if candidate.get_name() == 'Threading Linux' and candidate.get_process_id() == process.pid:
            return candidate
    return None


def project_list(app):
    frame = app.get_child_at_index(0)
    matches = [frame.get_child_at_index(index) for index in range(frame.get_child_count())
               if frame.get_child_at_index(index).get_role_name() == 'list']
    return matches[0] if len(matches) == 1 else None


def latest_frame(log_path):
    matches = frame_pattern.findall(log_path.read_text())
    if not matches:
        return None
    total, first, visible, mounted, reusable, scroll_y = matches[-1]
    return (int(total), int(first), int(visible), int(mounted), int(reusable), float(scroll_y))


def selected_id(listed):
    selected = listed.get_selection_iface().get_selected_child(0)
    return selected.get_accessible_id() if selected is not None else None


def visible_ids(listed):
    return [listed.get_child_at_index(index).get_accessible_id()
            for index in range(listed.get_child_count())]


def verify_viewport(app, log_path, expected, total):
    frame = latest_frame(log_path)
    assert frame is not None, 'native outline did not report a frame'
    count, first, visible, mounted, reusable, scroll_y = frame
    assert count == total, frame
    assert 0 <= first < count and 1 <= visible <= 10, frame
    assert mounted == visible and mounted <= 10 and reusable <= 32, frame
    assert scroll_y >= 0, frame
    listed = project_list(app)
    assert listed is not None and listed.get_role_name() == 'list'
    description = description_pattern.fullmatch(listed.get_description())
    assert description is not None, listed.get_description()
    start, end, described_total = map(int, description.groups())
    assert (start, end, described_total) == (first + 1, first + visible, count), \
        (frame, listed.get_description())
    actual = visible_ids(listed)
    assert actual == expected[first:first + visible], \
        (first, actual, expected[first:first + visible])
    window_height = app.get_child_at_index(0).get_component_iface().get_extents(
        Atspi.CoordType.WINDOW).height
    for index in range(listed.get_child_count()):
        row = listed.get_child_at_index(index)
        rect = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert 0 < rect.height <= 44 and rect.width in (264, 296), \
            (index, rect.x, rect.y, rect.width, rect.height)
        assert 82 <= rect.y and rect.y + rect.height <= window_height, \
            (index, rect.y, rect.height, window_height)
        assert rect.x == (12 if expected[first + index] in project_id_set else 44), \
            (index, rect.x, expected[first + index])
    return frame, listed


def capture(window, name, size=(1120, 480)):
    path = output / name
    subprocess.run(['import', '-window', window, str(path)], check=True, timeout=8)
    measured = subprocess.check_output(['identify', '-format', '%wx%h', str(path)],
                                       text=True, timeout=8)
    assert measured == f'{size[0]}x{size[1]}', (name, measured)
    pixels = subprocess.check_output(['convert', str(path), '-depth', '8', 'RGB:-'], timeout=8)
    assert len(pixels) == size[0] * size[1] * 3
    return hashlib.sha256(pixels).hexdigest()


def run_window(name, selected_index, expanded=False):
    log_path = output / f'{name}.log'
    arguments = ([binary, '--app', str(store), endpoint, '/bin/sh'] if selected_index == 0
                 else [binary, '--app-project', str(store), endpoint, '/bin/sh',
                       str(project_paths[selected_index])])
    process = None
    try:
        xdo('mousemove', '0', '0')
        with log_path.open('w+') as log:
            process = subprocess.Popen(arguments,
                                       env=dict(os.environ, THREADING_LINUX_NAVIGATION_TRACE='1'),
                                       stdout=log, stderr=log)
            app = eventually(lambda: application(process), f'{name} AT-SPI app', process, log_path)
            window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                            str(process.pid), '--name', '^Threading experiment - ')
                                .splitlines()[0], f'{name} native window', process, log_path)
            expected = project_ids
            frame, listed = eventually(
                lambda: verify_viewport(app, log_path, expected, project_count),
                f'{name} native outline viewport', process, log_path)
            assert frame[1] <= selected_index < frame[1] + frame[2], frame
            assert selected_id(listed) == project_ids[selected_index]
            assert xdo('getwindowname', window).endswith(str(project_paths[selected_index]))
            baseline = capture(window, f'{name}-first.png')

            if expanded:
                assert frame[1] == 0, frame
                # A wheel changes the clip viewport, not the selected project.
                xdo('mousemove', '--window', window, '180', '280',
                    'click', '--repeat', '4', '--delay', '70', '5')
                frame, listed = eventually(
                    lambda: verify_viewport(app, log_path, expected, project_count)
                    if latest_frame(log_path) and latest_frame(log_path)[1] > 0 else None,
                    'wheel moved outline viewport', process, log_path)
                assert frame[5] > 0
                assert xdo('getwindowname', window).endswith(str(project_paths[0])), \
                    'wheel changed selected project'
                assert capture(window, f'{name}-wheel.png') != baseline, \
                    'wheel moved outline metadata without changing pixels'
                xdo('click', '--repeat', '5', '--delay', '70', '4')
                frame, listed = eventually(
                    lambda: verify_viewport(app, log_path, expected, project_count)
                    if latest_frame(log_path) and latest_frame(log_path)[1] == 0 else None,
                    'wheel returned to first project', process, log_path)
                assert selected_id(listed) == project_ids[0]

                xdo('mousemove', '--window', window, '72', '108', 'click', '1')
                expected = [project_ids[0]] + list(reversed(terminal_ids[-512:])) + project_ids[1:]
                total = project_count + 512
                frame, listed = eventually(
                    lambda: verify_viewport(app, log_path, expected, total)
                    if latest_frame(log_path) and latest_frame(log_path)[0] == total else None,
                    'disclosure mounted saved children', process, log_path)
                assert visible_ids(listed)[1] == terminal_ids[-1]
                assert selected_id(listed) == project_ids[0]
                expanded_pixels = capture(window, f'{name}-expanded.png')
                assert expanded_pixels != baseline

                xdo('mousemove', '--window', window, '180', '280',
                    'click', '--repeat', '4', '--delay', '70', '5')
                frame, listed = eventually(
                    lambda: verify_viewport(app, log_path, expected, total)
                    if latest_frame(log_path) and latest_frame(log_path)[1] > 0 else None,
                    'wheel scrolled expanded children', process, log_path)
                assert frame[5] > 0
                assert capture(window, f'{name}-children-wheel.png') != expanded_pixels
                slot = min(2, listed.get_child_count() - 1)
                chosen_id = expected[frame[1] + slot]
                row = listed.get_child_at_index(slot)
                rect = row.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
                pointer_x, pointer_y = rect.x + 120, rect.y + rect.height // 2
                row_geometry = []
                for index in range(listed.get_child_count()):
                    visible_row = listed.get_child_at_index(index)
                    visible_rect = visible_row.get_component_iface().get_extents(
                        Atspi.CoordType.WINDOW)
                    row_geometry.append((index, visible_row.get_accessible_id(),
                                         visible_rect.x, visible_rect.y,
                                         visible_rect.width, visible_rect.height))
                xdo('mousemove', '--window', window, str(pointer_x), str(pointer_y))
                (output / f'{name}-pointer.txt').write_text(
                    f'frame={frame}\nchosen_slot={slot} chosen_id={chosen_id}\n'
                    f'click=({pointer_x}, {pointer_y})\n'
                    f'xdotool={xdo("getmouselocation", "--shell")}\n'
                    f'rows={row_geometry}\n')
                xdo('click', '1')
                eventually(lambda: selected_id(project_list(app)) == chosen_id,
                           'pointer selected exact saved child', process, log_path)
                xdo('windowfocus', '--sync', window, 'key', 'Down')
                following_id = expected[frame[1] + slot + 1]
                eventually(lambda: selected_id(project_list(app)) == following_id,
                           'keyboard selected next saved child', process, log_path)
                listed = project_list(app)
                assert listed.get_selection_iface().select_child(0), \
                    'AT-SPI refused first visible row'
                eventually(lambda: selected_id(project_list(app)) == expected[frame[1]],
                           'AT-SPI selected exact visible child', process, log_path)

                xdo('windowsize', window, '800', '360')
                resized, listed = eventually(
                    lambda: verify_viewport(app, log_path, expected, total)
                    if latest_frame(log_path) and latest_frame(log_path)[2] <= 7 else None,
                    'resized outline viewport', process, log_path)
                assert resized[3] <= 7
                capture(window, f'{name}-resized.png', size=(800, 360))
            xdo('windowfocus', '--sync', window, 'key', 'alt+F4')
            assert process.wait(timeout=12) == 0
    finally:
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


run_window('outline-start', 0, expanded=True)
run_window('outline-middle', 2_500)
run_window('outline-last', project_count - 1)
print('PASS native outline: 5,100 projects, 1,024 saved terminals, bounded real cells, '
      'wheel viewport, exact AT-SPI identity, pointer, keyboard, resize and middle/tail restore')
