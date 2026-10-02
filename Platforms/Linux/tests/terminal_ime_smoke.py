"""Exercise IBus Pinyin composition through the SDL window, renderer and real PTY."""
from pathlib import Path
import re
import subprocess
import sys
import time

binary, store, socket, folder = sys.argv[1:]
root = Path(folder)
project = root / 'IME'
project.mkdir()
log_path = root / 'ime-window.log'


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=5)


def title(process, expected):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {expected}: {log_path.read_text()}'
        result = xdo('search', '--name', '^' + re.escape(expected) + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing title {expected}: {log_path.read_text()}')


def pixels(path):
    return subprocess.run(['convert', str(path), '-crop', '400x150+0+0', '-depth', '8', 'rgb:-'],
                          capture_output=True, check=True, timeout=8).stdout


with log_path.open('w+') as log:
    process = subprocess.Popen([
        binary, '--terminal', store, socket, str(project), '/usr/bin/python3',
        str(Path(__file__).with_name('terminal_ime_child.py')), str(root),
    ], stdout=log, stderr=log)
    try:
        window = title(process, 'Threading terminal - IME READY')
        assert xdo('windowfocus', '--sync', window).returncode == 0
        ready = Path('out/terminal-ime-ready.png')
        preedit = Path('out/terminal-ime-preedit.png')
        subprocess.run(['import', '-window', window, str(ready)], check=True, timeout=5)
        baseline = pixels(ready)

        assert xdo('type', '--delay', '180', 'ni').returncode == 0
        (root / 'ime-preedit-started').touch()
        deadline = time.monotonic() + 8
        while not (root / 'ime-preedit-clean').exists():
            assert process.poll() is None and time.monotonic() < deadline, log_path.read_text()
            time.sleep(.05)
        assert 'IME_PREEDIT bytes=' in log_path.read_text(), 'SDL never delivered preedit'
        while True:
            subprocess.run(['import', '-window', window, str(preedit)], check=True, timeout=5)
            captured = pixels(preedit)
            # IBus's own candidate popup can obscure the X window capture. A changed
            # rectangle alone is not proof that the terminal rendered composition.
            blue = b'\x6c\xa8\xff'
            background = b'\x17\x1f\x2b'
            ink = b'\xf4\xf7\xff'
            if (captured != baseline and captured.count(blue) > 10
                    and captured.count(background) > 100 and captured.count(ink) > 10):
                break
            assert time.monotonic() < deadline, 'preedit did not render in the terminal window'
            time.sleep(.05)

        assert xdo('type', '--delay', '180', 'hao').returncode == 0
        assert xdo('key', 'space').returncode == 0
        title(process, 'Threading terminal - IME COMMITTED')
        assert (root / 'ime-committed').read_text() == '你好'
        assert 'IME_COMMIT bytes=6' in log_path.read_text(), 'SDL did not mark the Unicode commit'
        (root / 'ime-release').touch()
        assert xdo('windowfocus', window, 'key', 'alt+F4').returncode == 0
        assert process.wait(timeout=5) == 0
        print('PASS native IBus IME: visible preedit, no PTY input before commit, exact 你好 UTF-8',
              flush=True)
    except BaseException:
        log.flush()
        print(log_path.read_text(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
