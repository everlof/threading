"""Inspect the native third workspace region with the shared attachment shell mounted."""
from pathlib import Path
import re
import subprocess
import sys
import time


binary, evidence = sys.argv[1:]
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
log_path = output / 'display-pane.log'
with log_path.open('w') as log:
    process = subprocess.Popen([binary, '--display-pane-fixture'], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 5
        window = None
        while time.monotonic() < deadline:
            assert process.poll() is None, log_path.read_text()
            if 'DISPLAY_PANE_FRAME sidebar=240 terminal=530 attachments=350 rows=3' \
                    in log_path.read_text():
                found = subprocess.run(
                    ['xdotool', 'search', '--all', '--onlyvisible', '--pid', str(process.pid)],
                    capture_output=True, text=True, timeout=5)
                if found.returncode == 0 and found.stdout.strip():
                    window = found.stdout.strip().splitlines()[-1]
                    break
            time.sleep(.05)
        assert window is not None, log_path.read_text()
        image = output / 'display-pane.png'
        subprocess.run(['import', '-window', window, str(image)], check=True, timeout=5)

        def pixel(x, y):
            return subprocess.check_output(
                ['convert', str(image), '-format', f'%[pixel:p{{{x},{y}}}]', 'info:'],
                text=True, timeout=5).strip()

        sidebar = pixel(120, 300)
        terminal = pixel(500, 300)
        attachments = pixel(805, 300)
        assert len({sidebar, terminal, attachments}) == 3, (
            f'workspace regions were not distinct: {sidebar}, {terminal}, {attachments}'
        )
        assert pixel(239, 300) == sidebar
        assert pixel(240, 300) == terminal
        assert pixel(769, 300) == terminal
        assert pixel(770, 300) != terminal
        frame = re.search(r'foldRuleY=(\d+) filterSegments=(\d+)', log_path.read_text())
        assert frame is not None, 'shared fold and filter geometry were not published'
        fold_y, segments = map(int, frame.groups())
        assert segments == 3, f'shared filter mounted {segments} segments'
        assert pixel(800, fold_y) != pixel(800, fold_y - 1), 'shared fold rule was not drawn'
        assert pixel(800, fold_y + 1) == pixel(800, fold_y - 1), \
            'shared fold grew beyond its hairline'

        subprocess.run(['xdotool', 'mousemove', '--window', window, '990', '19'],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'click', '1'], check=True, timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and \
                'DISPLAY_FILTER_PRESENTED index=1' not in log_path.read_text():
            time.sleep(.05)
        assert 'DISPLAY_FILTER_SELECTED index=1' in log_path.read_text(), \
            'display pointer did not activate the shared filter'
        assert 'DISPLAY_FILTER_PRESENTED index=1' in log_path.read_text(), \
            'shared filter selection was not presented'
        selected = output / 'display-pane-filter-selected.png'
        subprocess.run(['import', '-window', window, str(selected)], check=True, timeout=5)
        def filter_signature(path):
            return subprocess.check_output(
                ['convert', str(path), '-crop', '230x26+880+6', '-format', '%#', 'info:'],
                text=True, timeout=5).strip()
        assert filter_signature(selected) != filter_signature(image), \
            'shared filter did not redraw its selected segment'

        subprocess.run(['xdotool', 'mousemove', '--window', window, '800', '300'],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'click', '5'], check=True, timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and \
                'DISPLAY_POINTER action=7' not in log_path.read_text():
            time.sleep(.05)
        assert 'DISPLAY_POINTER action=7' in log_path.read_text(), \
            'display wheel escaped into terminal scrolling'

        subprocess.run(['xdotool', 'mousemove', '--window', window, '800', str(fold_y)],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'mousedown', '1'], check=True, timeout=5)
        subprocess.run(['xdotool', 'mousemove', '--window', window, '600', '180'],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'mouseup', '1'], check=True, timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and \
                'DISPLAY_POINTER action=3 x=-170' not in log_path.read_text():
            time.sleep(.05)
        assert 'DISPLAY_POINTER action=2 x=-170' in log_path.read_text(), \
            'display drag escaped into the terminal'
        assert 'DISPLAY_POINTER action=3 x=-170' in log_path.read_text(), \
            'display release escaped into the terminal'
    finally:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=5)

print('PASS shared attachment shell in three-region native workspace')
