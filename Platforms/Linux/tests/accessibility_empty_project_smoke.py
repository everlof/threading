"""Open and cancel the empty navigator's project import through its AT-SPI action."""
from pathlib import Path
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi

binary, store, socket, fixture = sys.argv[1:]
log_path = Path(fixture) / 'accessibility-empty-project.log'
Atspi.init()


def eventually(read, label):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            result = read()
            if result:
                return result
        except Exception:
            pass
        assert process.poll() is None, f'{label}: window exited; {log_path.read_text()}'
        time.sleep(.05)
    raise AssertionError(f'{label}: {log_path.read_text()}')


def application():
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        child = desktop.get_child_at_index(index)
        if child.get_name() == 'Threading Linux' and child.get_process_id() == process.pid:
            return child
    return None


def dialog_window():
    # GTK can publish its title before mapping the window; X_SetInputFocus rejects that
    # intermediate state with BadMatch. Wait for the actual focusable native dialog.
    found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Add project folder$'],
                           capture_output=True, text=True, timeout=5)
    return found.stdout.splitlines()[0] if found.returncode == 0 else None


with log_path.open('w+') as log:
    process = subprocess.Popen([binary, '--app', store, socket, '/bin/sh'],
                               stdout=log, stderr=log)
    try:
        app = eventually(application, 'AT-SPI app registration')
        frame = app.get_child_at_index(0)
        listed = eventually(lambda: frame.get_child_at_index(0)
                            if frame.get_child_at_index(0).get_child_count() == 0 else None,
                            'empty navigator')
        assert listed.get_role_name() == 'list'
        assert 'No Projects' in listed.get_description()
        add = next(frame.get_child_at_index(i) for i in range(frame.get_child_count())
                   if frame.get_child_at_index(i).get_accessible_id() == 'linux.add-project')
        assert add.get_action_iface().do_action(0), 'Add Project accessible action refused'
        menu = eventually(lambda: frame.get_child_at_index(0)
                          if frame.get_child_at_index(0).get_name() == 'Add Project' else None,
                          'Add Project menu')
        existing = next(menu.get_child_at_index(i) for i in range(menu.get_child_count())
                        if menu.get_child_at_index(i).get_name() == 'Use an Existing Folder…')
        assert existing.get_action_iface().do_action(1), 'existing-folder accessible action refused'
        dialog = eventually(dialog_window, 'native project dialog')
        subprocess.run(['xdotool', 'windowfocus', '--sync', dialog, 'key', 'Escape'],
                       check=True, timeout=5)
        eventually(lambda: 'PROJECT_IMPORT_CANCELLED' in log_path.read_text(),
                   'dialog cancellation')
        assert frame.get_child_at_index(0).get_child_count() == 0
        window = subprocess.check_output(['xdotool', 'search', '--all', '--onlyvisible',
                                          '--pid', str(process.pid), '--name',
                                          '^Threading experiment - empty store$'], text=True).splitlines()[0]
        subprocess.run(['xdotool', 'windowfocus', '--sync', window, 'key', 'alt+F4'],
                       check=True, timeout=5)
        assert process.wait(timeout=5) == 0
        print('PASS empty navigator Add Project AT-SPI menu, GTK dialog, cancel and unchanged store')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
