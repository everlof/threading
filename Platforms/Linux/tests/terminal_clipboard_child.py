"""A real PTY verifies paste bytes in both terminal modes."""
import os
import tty

tty.setraw(0)


def stage(name, expected, mode=b''):
    os.write(1, mode + b'\x1b]0;CLIPBOARD ' + name.encode() + b'\x07')
    received = b''
    while len(received) < len(expected):
        chunk = os.read(0, len(expected) - len(received))
        assert chunk, (name, received)
        received += chunk
    assert received == expected, (name, received, expected)


# The following '.' is an ordered input barrier. It also catches stray shortcut key bytes.
stage('BRACKETED', b'\x1b[200~' + 'héllo\nsecond line'.encode() + b'\x1b[201~.', b'\x1b[?2004h')
stage('PLAIN', 'plain 🙂'.encode() + b'.', b'\x1b[?2004l')
stage('BOUNDED', b'ok.')
os.write(1, b'\x1b]0;CLIPBOARD OK\x07Clipboard paste bytes OK\r\n')
