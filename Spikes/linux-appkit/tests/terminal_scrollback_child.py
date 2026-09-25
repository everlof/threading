"""Keep a real PTY busy while the native window browses its normal-buffer history."""
import os
import select
import tty

tty.setraw(0)


def receive(expected):
    assert select.select([0], [], [], 5)[0], "scrollback input timed out"
    assert os.read(0, 1) == expected, "unexpected scrollback input"


os.write(1, b"\x1b[2J\x1b[H")
for row in range(60):
    os.write(1, f"ROW {row:03d}\r\n".encode())
os.write(1, b"\x1b]0;SCROLL READY\x07")
receive(b".")
os.write(1, b"ROW 060\r\n\x1b]0;SCROLL NEW\x07")
receive(b"q")
