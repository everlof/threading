"""Exercise the app-owned one-field prompt as a real X11 window."""
import os
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, evidence = sys.argv[1:]
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
Atspi.init()


def window_for(process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        assert process.poll() is None, process.stderr.read().decode()
        result = subprocess.run(['xdotool', 'search', '--all', '--onlyvisible',
                                 '--pid', str(process.pid), '--name', '^New Worktree$'],
                                capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.splitlines()[0]
        time.sleep(.05)
    raise AssertionError('New Worktree window did not appear')


def eventually(read, label, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = read()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(label)


def accessible_prompt(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app.get_process_id() != process.pid or app.get_name() != 'Threading Linux':
            continue
        frame = app.get_child_at_index(0)
        return frame.get_child_at_index(0)
    return None


def child_with_id(parent, identity):
    return next((parent.get_child_at_index(index)
                 for index in range(parent.get_child_count())
                 if parent.get_child_at_index(index).get_accessible_id() == identity), None)


for dark in (False, True):
    environment = os.environ.copy()
    environment['THREADING_LINUX_PROMPT_DARK'] = '1' if dark else '0'
    process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               env=environment)
    window = window_for(process)
    prompt = eventually(lambda: accessible_prompt(process), 'accessible prompt before capture')
    subprocess.run(['import', '-window', window,
                    str(output / ('worktree-prompt-dark.png' if dark
                                  else 'worktree-prompt-light.png'))], check=True, timeout=5)
    subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
    subprocess.run(['xdotool', 'type', '--clearmodifiers', 'feature/prompt'], check=True)
    field = child_with_id(prompt, 'linux.prompt.branch')
    eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'feature/prompt',
               'typed prompt value before capture')
    subprocess.run(['import', '-window', window,
                    str(output / ('worktree-typed-dark.png' if dark
                                  else 'worktree-typed-light.png'))], check=True, timeout=5)
    subprocess.run(['xdotool', 'key', 'Return'], check=True)
    stdout, stderr = process.communicate(timeout=8)
    assert process.returncode == 0, (process.returncode, stdout, stderr.decode())
    assert stdout == b'feature/prompt\n', stdout

process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
window = window_for(process)
prompt = eventually(lambda: accessible_prompt(process), 'accessible prompt for space')
subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
subprocess.run(['xdotool', 'type', '--clearmodifiers', 'one two'], check=True)
field = child_with_id(prompt, 'linux.prompt.branch')
eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'one two',
           'space typed in focused field')
subprocess.run(['xdotool', 'key', 'Return'], check=True)
stdout, stderr = process.communicate(timeout=8)
assert process.returncode == 0, (process.returncode, stdout, stderr.decode())
assert stdout == b'one two\n', stdout

process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
window = window_for(process)
subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
subprocess.run(['xdotool', 'key', 'Escape'], check=True)
stdout, stderr = process.communicate(timeout=8)
assert process.returncode == 2, stderr.decode()
assert stdout == b'', stdout

process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
window = window_for(process)
eventually(lambda: accessible_prompt(process), 'accessible prompt before tab')
subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
subprocess.run(['xdotool', 'key', 'Tab', 'space'], check=True)
stdout, stderr = process.communicate(timeout=8)
assert process.returncode == 2, stderr.decode()
assert stdout == b'', stdout

process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
window_for(process)
prompt = eventually(lambda: accessible_prompt(process), 'accessible prompt')
assert prompt.get_role_name() == 'dialog'
assert prompt.get_name() == 'New Worktree'
field = child_with_id(prompt, 'linux.prompt.branch')
cancel = child_with_id(prompt, 'linux.prompt.cancel')
create = child_with_id(prompt, 'linux.prompt.create')
assert field and cancel and create
assert field.get_role_name() == 'entry'
assert field.get_name() == 'branch name'
assert field.get_editable_text_iface().set_text_contents('via-accessibility')
eventually(lambda: Atspi.Text.get_text(field.get_text_iface(), 0, -1) == 'via-accessibility',
           'AT-SPI text edit')
assert create.get_action_iface().do_action(0)
stdout, stderr = process.communicate(timeout=8)
assert process.returncode == 0, (process.returncode, stdout, stderr.decode())
assert stdout == b'via-accessibility\n', stdout

process = subprocess.Popen([binary, '--text-prompt', 'worktree'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
window_for(process)
prompt = eventually(lambda: accessible_prompt(process), 'accessible prompt for cancel')
assert child_with_id(prompt, 'linux.prompt.cancel').get_action_iface().do_action(0)
stdout, stderr = process.communicate(timeout=8)
assert process.returncode == 2, stderr.decode()
assert stdout == b'', stdout
print('PASS themed text prompt light/dark, keyboard focus and AT-SPI submit/cancel')
