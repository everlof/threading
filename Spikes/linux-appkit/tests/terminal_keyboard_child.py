"""A real PTY child checks bytes produced by native X key events, including mode transitions."""
import os
import tty

tty.setraw(0)
def stage(name, expected, mode=b""):
    os.write(1, mode + b"\x1b]0;KEY " + name.encode() + b"\x07")
    # The '.' text event follows keyup on the host's ordered input worker. It is a barrier:
    # don't switch keyboard modes while the preceding native key is still held.
    expected += b"."
    received = b""
    while len(received) < len(expected):
        received += os.read(0, len(expected) - len(received))
    assert received == expected, (name, received, expected)

stage("NORMAL", b"\x1b[A")
stage("APP", b"\x1bOA", b"\x1b[?1h")
stage("MOD", b"\x1b[1;5C")
stage("KITTY TAB", b"\x1b[9;5u", b"\x1b[>3u")
stage("KITTY UP", b"\x1b[A\x1b[1;1:3A")
stage("NAV", b"\x1bOH\x1bOF\x1b[5~\x1b[6~\x1b[3~\x1bOQ", b"\x1b[<u")
stage("ORDER", b"a\x7fb\r")
os.write(1, b"\x1b[2J\x1b[HKEYBOARD MODES OK\r\nNormal / application cursor\r\nModifiers / navigation / function keys\r\nKitty press and release\r\nText and editing order preserved\r\n")
