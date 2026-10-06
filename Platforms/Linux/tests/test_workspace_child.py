"""Keep the native workspace recorder alive across input and resize-signal interleavings."""
import ast
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest


def recorder_source():
    source = Path(__file__).with_name('workspace_smoke.py').read_text()
    calls = [node for node in ast.walk(ast.parse(source)) if isinstance(node, ast.Call)
             and isinstance(node.func, ast.Attribute)
             and isinstance(node.func.value, ast.Name) and node.func.value.id == 'child'
             and node.func.attr == 'write_text']
    assert len(calls) == 1, 'expected the canonical workspace recorder'
    return ast.literal_eval(calls[0].args[0])


@unittest.skipUnless(hasattr(os, 'openpty') and hasattr(signal, 'SIGWINCH'), 'requires a POSIX PTY')
class WorkspaceRecorderTests(unittest.TestCase):
    def test_resize_between_snapshot_write_and_replace_preserves_child_and_input(self):
        source = recorder_source()
        with tempfile.TemporaryDirectory(prefix='workspace-recorder-') as directory:
            root = Path(directory)
            child = root / 'recorder.py'
            child.write_text(source)
            master, slave = os.openpty()
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 20, 80, 0, 0))
            process = subprocess.Popen([sys.executable, str(child), str(root)], cwd=root,
                stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
                env=dict(os.environ, THREADING_WORKSPACE_RESIZE_INTERLEAVING=root.name))
            os.close(slave)
            output = bytearray()
            target = root / (root.name + '.json')

            def read_until(predicate):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if select.select([master], [], [], .01)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            pass
                    self.assertIsNone(process.poll(), output.decode(errors='replace'))
                    if target.exists():
                        value = json.loads(target.read_text())
                        if predicate(value):
                            return value
                self.fail('recorder did not publish expected state: ' + output.decode(errors='replace'))

            try:
                read_until(lambda value: value['rows'] == 20 and value['cols'] == 80)
                os.write(master, b'q')
                read_until(lambda value: value['input'] == '71')
                os.kill(process.pid, signal.SIGUSR1)
                read_until(lambda value: value['mouse'])
                fcntl.ioctl(master, termios.TIOCSWINSZ,
                            struct.pack('HHHH', 31, 92, 0, 0))
                os.kill(process.pid, signal.SIGWINCH)
                read_until(lambda value: value['rows'] == 31 and value['cols'] == 92
                           and value['input'] == '71' and value['mouse'])
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
                os.close(master)
