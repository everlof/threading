"""One native window navigates projects while retaining real daemon children/emulators."""
import json
import fcntl
from pathlib import Path
import subprocess
import sys
import time

binary, host, store, socket, folder, child = sys.argv[1:]


def xdo(*args):
    return subprocess.run(['xdotool', *args], capture_output=True, text=True, timeout=3)


def title(expected):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        assert process.poll() is None, 'app exited during navigation'
        result = xdo('search', '--name', '^' + expected + '$')
        if result.returncode == 0:
            return result.stdout.splitlines()[0]
        time.sleep(.04)
    raise AssertionError('missing title: ' + expected)


def key(value):
    # X11 focus changes are asynchronous. Wait until this window owns focus before sending
    # the key, otherwise XTest can deliver it to the previous surface under a slow VM.
    assert xdo('windowfocus', '--sync', window, 'key', '--delay', '50', value).returncode == 0


def terminal_count():
    listing = subprocess.run([host, store, socket, 'list'], capture_output=True, text=True,
                             check=True, timeout=8).stdout
    return sum(line.startswith('  ') and not line.startswith('  agent ') for line in listing.splitlines())


before_count = terminal_count()
with open(Path(folder) / 'navigation.log', 'w+') as log:
    process = subprocess.Popen([binary, '--app', store, socket, '/usr/bin/python3', child],
                               stdout=log, stderr=log)
    try:
        window = title('Threading experiment - ' + folder + '/Alpha')
        key('Return')
        assert title('Threading terminal - NAV Alpha READY') == window
        alpha = json.loads((Path(folder) / 'Alpha/navigation-child.json').read_text())
        assert alpha['cwd'] == folder + '/Alpha'
        key('ctrl+shift+p')
        assert title('Threading experiment - ' + folder + '/Alpha') == window
        key('ctrl+shift+n')
        title('Threading experiment - terminal may still be running')
        key('Return')
        title('Threading terminal - NAV Alpha READY')
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Alpha')
        key('Down')
        title('Threading experiment - ' + folder + '/Beta')
        key('Return')
        assert title('Threading terminal - NAV Beta READY') == window
        beta = json.loads((Path(folder) / 'Beta/navigation-child.json').read_text())
        assert beta['cwd'] == folder + '/Beta' and beta['pid'] != alpha['pid']
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Beta')
        subprocess.run(['import', '-window', window, 'out/project-terminals.png'], check=True, timeout=5)
        # Refuse Gamma's creation under a real competing store lock, without disturbing Alpha/Beta.
        key('Down')
        title('Threading experiment - ' + folder + '/Gamma')
        with open(Path(store) / 'host.lock', 'a') as store_lock:
            fcntl.flock(store_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            key('Return')
            assert title('Threading terminal - unavailable') == window
            key('q')  # Failed surfaces must never route input to another project's child.
            subprocess.run(['import', '-window', window, 'out/project-terminal-failure.png'], check=True, timeout=5)
            assert xdo('windowsize', window, '320', '480').returncode == 0
            redraw_deadline = time.monotonic() + 8
            while 'FAILURE_FRAME 320x480' not in (Path(folder) / 'navigation.log').read_text():
                assert process.poll() is None and time.monotonic() < redraw_deadline, 'narrow failure redraw missing'
                time.sleep(.04)
            subprocess.run(['import', '-window', window, 'out/project-terminal-failure-narrow.png'], check=True, timeout=5)
        assert not (Path(folder) / 'Gamma/navigation-child.json').exists()
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Gamma')
        key('Return')
        title('Threading terminal - unavailable')  # Revisiting a failed entry cannot silently respawn.
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Gamma')
        assert xdo('windowsize', window, '800', '480').returncode == 0
        key('ctrl+shift+n')
        title('Threading terminal - NAV Gamma READY')
        gamma = json.loads((Path(folder) / 'Gamma/navigation-child.json').read_text())
        key('q')
        title('Threading terminal - exited 0')
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Gamma')
        subprocess.run(['import', '-window', window, 'out/project-terminal-replace.png'], check=True, timeout=5)
        (Path(folder) / 'Gamma/navigation-child.json').unlink()  # A new child is now explicitly expected.
        key('ctrl+shift+n')
        title('Threading terminal - NAV Gamma READY')
        replacement = json.loads((Path(folder) / 'Gamma/navigation-child.json').read_text())
        assert replacement['pid'] != gamma['pid'] and replacement['cwd'] == gamma['cwd']
        key('q')
        title('Threading terminal - exited 0')
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Gamma')
        key('Up')
        title('Threading experiment - ' + folder + '/Beta')
        key('Up')
        title('Threading experiment - ' + folder + '/Alpha')
        key('Return')
        title('Threading terminal - NAV Alpha READY')
        assert json.loads((Path(folder) / 'Alpha/navigation-child.json').read_text()) == alpha
        key('p')
        title('Threading terminal - NAV Alpha REVISITED')
        subprocess.run(['import', '-window', window, 'out/project-terminal-revisited.png'], check=True, timeout=5)
        key('q')
        title('Threading terminal - exited 0')
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Alpha')
        key('Down')
        title('Threading experiment - ' + folder + '/Beta')
        key('Return')
        title('Threading terminal - NAV Beta READY')
        key('q')
        title('Threading terminal - exited 0')
        key('ctrl+shift+p')
        title('Threading experiment - ' + folder + '/Beta')
        key('Escape')
        assert process.wait(timeout=5) == 0
        assert terminal_count() == before_count + 4
        print('PASS one-window projects: selected cwd, safe failed/exited replacement, live refusal, same PID/emulator on revisit, exit and return', flush=True)
    except BaseException:
        log.seek(0)
        print(log.read(), file=sys.stderr)
        (Path('out') / 'project-navigation-failure.log').write_text((Path(folder) / 'navigation.log').read_text())
        raise
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
