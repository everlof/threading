"""Opt-in real-PTY renderer workload: run as WindowHarness --terminal's executable arguments.

Use a 1280x900 window for the 128x40-cell maximum. The child emits 300 complete visible grids,
then stops changing output so the host must stop preparing frames. Window logs report worker draw
and UI presentation milliseconds. This does not claim IME, accessibility or many-session coverage.
"""
import fcntl
import os
import struct
import sys
import termios
import time
import tty
import select

tty.setraw(0)
os.write(1, b"\x1b]0;STRESS READY\x07")
assert os.read(0, 1) == b"g"
os.write(1, b"\x1b]0;STRESS RUNNING\x07")
for frame in range(300):
    if select.select([0], [], [], 0)[0]:
        assert os.read(0, 1) == b"p"
        os.write(1, b"\x1b]0;STRESS ACK\x07")
    rows, columns, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8))
    content = ["\x1b[?25l"]
    for row in range(rows):
        content.append(f"\x1b[{row + 1};1H\x1b[38;5;{16 + (row + frame) % 216}m")
        content.append(("0123456789abcdef" * ((columns + 15) // 16))[:columns])
    sys.stdout.buffer.write("".join(content).encode())
    sys.stdout.buffer.flush()
    time.sleep(1 / 60)
os.write(1, b"\x1b[0m\x1b[?25h\x1b]0;STRESS COMPLETE\x07")
