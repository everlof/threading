"""A PTY child checks native SDL mouse input against its live DEC tracking modes."""
import os
import select
import tty

tty.setraw(0)


def receive(count):
    result = b""
    while len(result) < count:
        assert select.select([0], [], [], 5)[0], ("mouse input timed out", result)
        result += os.read(0, count - len(result))
    return result


def stage(name, mode):
    os.write(1, mode + b"\x1b]0;MOUSE " + name.encode() + b"\x07")


def no_more_input():
    assert not select.select([0], [], [], 0.25)[0], "unexpected mouse report"


stage("OFF", b"\x1b[?1000l\x1b[?1006l")
assert receive(1) == b"."  # The window is visible before the refusal interval starts.
no_more_input()

stage("X10", b"\x1b[?9h\x1b[?1006h")
assert receive(len(b"\x1b[<0;3;2M")) == b"\x1b[<0;3;2M"
no_more_input()  # X10 reports a press, not a release.

stage("VT200", b"\x1b[?9l\x1b[?1000h")
expected = b"\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;3;2M\x1b[<65;3;2M"
assert receive(len(expected)) == expected
no_more_input()

os.write(1, b"\x1b[2J\x1b[HMOUSE MODES OK\r\n")
