"""Require a real IME to keep preedit off the PTY and commit one Unicode string."""
import os
from pathlib import Path
import select
import sys
import time
import tty

root = Path(sys.argv[1])
tty.setraw(0)
os.write(1, b'\x1b]0;IME READY\x07')

deadline = time.monotonic() + 15
while not (root / 'ime-preedit-started').exists():
    assert time.monotonic() < deadline, 'IME never began composition'
    assert not select.select([0], [], [], .05)[0], 'uncommitted preedit reached the PTY'

until = time.monotonic() + 1
while time.monotonic() < until:
    assert not select.select([0], [], [], .05)[0], 'uncommitted preedit reached the PTY'
(root / 'ime-preedit-clean').write_text('preedit stayed out of the PTY')

expected = '你好'.encode()
received = b''
deadline = time.monotonic() + 12
while len(received) < len(expected):
    assert time.monotonic() < deadline, f'IME commit incomplete: {received!r}'
    if select.select([0], [], [], .1)[0]:
        received += os.read(0, len(expected) - len(received))
assert received == expected, (received, expected)
assert not select.select([0], [], [], .4)[0], 'IME sent a duplicate commit or shortcut key'
(root / 'ime-committed').write_text(received.decode())
os.write(1, b'\x1b]0;IME COMMITTED\x07')
deadline = time.monotonic() + 10
while not (root / 'ime-release').exists():
    assert time.monotonic() < deadline, 'IME test did not release the child'
    time.sleep(.05)
