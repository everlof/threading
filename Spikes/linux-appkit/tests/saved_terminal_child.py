"""Record each actual saved-shell start, including argv, cwd and the initial PTY grid."""
import fcntl
import json
import os
from pathlib import Path
import struct
import sys
import termios
import tty

marker = Path(sys.argv[1])
records = marker.read_text().splitlines() if marker.exists() else []
number = len(records) + 1
rows, columns, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
with marker.open('a') as output:
    output.write(json.dumps({'pid': os.getpid(), 'cwd': str(Path.cwd()), 'arguments': sys.argv[2:],
                             'columns': columns, 'rows': rows}) + '\n')
tty.setraw(0)
print(f'Saved shell start {number}\r\nPID {os.getpid()}\r\n{Path.cwd()}\r\n', end='', flush=True)
print(f'\033]0;SAVED SHELL {number} READY\007', end='', flush=True)
while True:
    key = os.read(0, 1)
    if key == b'q':
        raise SystemExit(0)
    if key == b'p':
        print(f'\033]0;SAVED SHELL {number} LIVE\007', end='', flush=True)
    else:
        raise AssertionError(f'unexpected input: {key!r}')
