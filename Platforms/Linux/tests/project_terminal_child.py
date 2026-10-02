"""Raw child for the native project/runtime journey; one marker per actual spawn."""
import json
import os
from pathlib import Path
import sys
import tty

tty.setraw(sys.stdin.fileno())
project = Path.cwd().name
record = Path('navigation-child.json')
assert not record.exists(), 'project activation spawned a duplicate child'
record.write_text(json.dumps({'pid': os.getpid(), 'cwd': str(Path.cwd())}))

def title(value):
    print(f'\033]0;NAV {project} {value}\007', end='', flush=True)

print(f'Project {project}\r\nPID {os.getpid()}\r\n{Path.cwd()}\r\n', end='', flush=True)
title('READY')
while True:
    byte = os.read(sys.stdin.fileno(), 1)
    if byte == b'p':
        print('SAME CHILD AND SCREEN\r\n', end='', flush=True)
        title('REVISITED')
    elif byte == b'q':
        sys.exit(0)
    else:
        raise AssertionError(f'unexpected terminal input: {byte!r}')
