import json
import os
from pathlib import Path
import signal
import struct
import sys
import termios
import tty
import fcntl

tty.setraw(0)
changes = 0

def resized(*_):
    global changes
    changes += 1

signal.signal(signal.SIGWINCH, resized)

def query():
    os.write(1, b'\x1b[6n')
    reply = b''
    while not reply.endswith(b'R'):
        reply += os.read(0, 1)
    assert reply.startswith(b'\x1b['), reply


def title(value):
    os.write(1, ('\x1b]0;' + value + '\x07').encode())

os.write(1, ('Original child PID %d\r\n' % os.getpid()).encode())
query()
title('ATTACH READY')
assert os.read(0, 1) == b'g'
rows, cols, _, _ = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\0' * 8))
assert (cols, rows) == (96, 30), (cols, rows)
Path('attach-child.json').write_text(json.dumps({'pid': os.getpid(), 'cols': cols, 'rows': rows}))
before = changes
title('ATTACH DETACHED')
assert os.read(0, 1) == b'p', 'historical query answered again'
assert changes == before, 'reattachment resized the child'
query()  # Live replies must resume after history, not remain suppressed.
os.write(1, b'SAME CHILD, GRID AND HISTORY\r\n')
title('ATTACH LIVE')
assert os.read(0, 1) == b'q'
sys.exit(7)
