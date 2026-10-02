"""Drive the native clipboard shortcut through Xvfb and a real PTY child."""
from pathlib import Path
import subprocess
import sys
import time

binary, store, socket, folder = sys.argv[1:]
root = Path(folder)
log_path = root / 'clipboard-window.log'


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=4)


def title(name):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert process.poll() is None, f'window exited before {name}'
        result = xdo('search', '--name', '^Threading terminal - CLIPBOARD ' + name + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError(f'missing clipboard stage {name}')


def key(value):
    assert xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value).returncode == 0


def clipboard(text):
    # xclip forks an X11 selection owner; it must not keep communicate()'s pipes open.
    subprocess.run(['xclip', '-selection', 'clipboard', '-i'], input=text,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--terminal', store, socket, str(root / 'Alpha'),
                                '/usr/bin/python3', str(Path(__file__).with_name('terminal_clipboard_child.py'))],
                               stdout=log, stderr=log)
    try:
        window = title('BRACKETED')
        clipboard('héllo\nsecond line'.encode())
        key('ctrl+shift+v')
        key('period')
        assert title('PLAIN') == window
        clipboard('plain 🙂'.encode())
        key('ctrl+shift+v')
        key('period')
        assert title('BOUNDED') == window
        clipboard(b'X' * (64 * 1024 + 1))
        key('ctrl+shift+v')
        deadline = time.monotonic() + 5
        while 'CLIPBOARD_REFUSED clipboard exceeds 64 KiB' not in log_path.read_text():
            assert time.monotonic() < deadline, 'oversize clipboard was not refused'
            time.sleep(.05)
        clipboard(b'ok')
        key('ctrl+shift+v')
        key('period')
        deadline = time.monotonic() + 10
        while xdo('getwindowname', window).stdout.strip() != 'Threading terminal - exited 0':
            assert process.poll() is None and time.monotonic() < deadline, 'paste child did not exit cleanly'
            time.sleep(.05)
        key('alt+F4')
        assert process.wait(timeout=5) == 0
        print('PASS native clipboard: Unicode, bracketed/plain paste, ordered shortcut and 64 KiB refusal',
              flush=True)
    except BaseException:
        log.seek(0)
        print(log.read(), file=sys.stderr)
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
