"""Installed custom Snooze picker: rendered sheet, keyboard selection, exact future date."""
from datetime import datetime, timedelta
from pathlib import Path
import subprocess
import sys
import time

binary, evidence = sys.argv[1:3]
interaction = sys.argv[3] if len(sys.argv) > 3 else 'pointer'
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
process = subprocess.Popen([binary, '--snooze-picker'], stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True)


def eventually(read, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            stdout, stderr = process.communicate(timeout=2)
            raise AssertionError(f'{label}: exit={process.returncode} {stdout!r} {stderr!r}')
        try:
            value = read()
            if value:
                return value
        except (IndexError, subprocess.CalledProcessError):
            pass
        time.sleep(.05)
    raise AssertionError(f'{label}: no visible picker')


try:
    window = eventually(lambda: subprocess.check_output(
        ['xdotool', 'search', '--onlyvisible', '--name', '^Snooze session$'],
        text=True).splitlines()[0], 'picker window')
    time.sleep(1.5)
    subprocess.run(['import', '-window', window, str(output / 'custom-snooze-picker.png')],
                   check=True, timeout=8)
    if interaction == 'keyboard':
        subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True, timeout=5)
        subprocess.run(['xdotool', 'key', 'Left'], check=True, timeout=5)
        time.sleep(.2)
        subprocess.run(['xdotool', 'key', 'Down'], check=True, timeout=5)
        time.sleep(.2)
        subprocess.run(['xdotool', 'key', 'Return'], check=True, timeout=5)
    else:
        subprocess.run(['xdotool', 'mousemove', '--window', window, '100', '190'],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
        time.sleep(.2)
        subprocess.run(['xdotool', 'mousemove', '--window', window, '450', '420'],
                       check=True, timeout=5)
        subprocess.run(['xdotool', 'click', '--window', window, '1'], check=True, timeout=5)
    stdout, stderr = process.communicate(timeout=8)
    assert process.returncode == 0, (process.returncode, stdout, stderr)
    chosen = datetime.fromtimestamp(float(stdout.strip()))
    assert chosen.date() == (datetime.now() + timedelta(days=1)).date(), (chosen, stderr)
    assert chosen.minute % 15 == 0 and chosen.second == 0, chosen
    print(f'PASS installed custom Snooze picker {interaction} selects tomorrow quarter-hour')
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
