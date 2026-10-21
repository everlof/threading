"""Drop a real Xdnd image on the installed opening composer and submit its path."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi


binary, host, daemon, endpoint, fixture, evidence = sys.argv[1:7]
delayed_owner_binary = sys.argv[7] if len(sys.argv) > 7 else None
root = Path(fixture) / 'attachment-fixture'
root.mkdir(exist_ok=True)
output = Path(evidence)
output.mkdir(parents=True, exist_ok=True)
store = root / 'store'
project = root / 'AttachmentProject'
project.mkdir()
subprocess.run([host, '--add-project', str(store), str(project)], check=True, timeout=8)
image = root / 'red blue.png'
subprocess.run(['convert', '-size', '120x80', 'xc:#db493f', str(image)], check=True)
child = root / 'record-agent'
child.write_text('''#!/usr/bin/python3
import json, os, sys, termios, tty
from pathlib import Path
tty.setraw(0)
Path('attachment-agent.json').write_text(json.dumps({'argv': sys.argv[1:]}))
os.read(0, 1)
''')
child.chmod(0o700)
state = root / 'daemon'
state.mkdir()
Atspi.init()


def eventually(read, label, process, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        assert process.poll() is None, f'{label}: process exited; {window_log.read_text()}'
        try:
            value = read()
            if value:
                return value
        except Exception as error:
            last = error
        time.sleep(.05)
    raise AssertionError(f'{label}: {last}; {window_log.read_text()}')


def xdo(*args):
    return subprocess.run(['xdotool', *args], check=True, capture_output=True,
                          text=True, timeout=5).stdout.strip()


def application(process):
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        item = desktop.get_child_at_index(index)
        if item.get_name() == 'Threading Linux' and item.get_process_id() == process.pid:
            return item
    return None


def child_by_id(parent, identity):
    return next((parent.get_child_at_index(index)
                 for index in range(parent.get_child_count())
                 if parent.get_child_at_index(index).get_accessible_id() == identity), None)


def panel(app):
    frame = app.get_child_at_index(0)
    return next(frame.get_child_at_index(index)
                for index in range(frame.get_child_count())
                if frame.get_child_at_index(index).get_role_name() == 'panel')


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


daemon_process = process = source = delayed_owner = None
window_log = output / 'window.log'
try:
    with (output / 'daemon.log').open('w') as log:
        daemon_process = subprocess.Popen([daemon, '--socket', endpoint, '--state', str(state)],
                                          stdout=log, stderr=log)
    eventually(lambda: Path(endpoint).exists(), 'daemon socket', daemon_process)
    home = root / 'home'
    home.mkdir()
    with window_log.open('w') as log:
        process = subprocess.Popen([binary, '--app-agents-project', str(store), endpoint,
                                    '/bin/sh', str(child), str(child), str(project)],
                                   env=dict(os.environ, HOME=str(home)), stdout=log, stderr=log)
        app = eventually(lambda: application(process), 'application', process)
        window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
                                         str(process.pid)).splitlines()[0], 'window', process)
        composer = eventually(lambda: panel(app) if child_by_id(panel(app),
            'linux.composer.editor') else None, 'composer', process)
        editor = child_by_id(composer, 'linux.composer.editor')
        action = child_by_id(composer, 'linux.placeholder.action')
        provider = child_by_id(composer, 'linux.composer.provider')
        assert provider.get_action_iface().do_action(0)
        choices = eventually(lambda: child_by_id(composer, 'linux.composer.choices'),
                             'provider menu', process)
        codex = next(choices.get_child_at_index(index)
                     for index in range(choices.get_child_count())
                     if choices.get_child_at_index(index).get_name() == 'Codex')
        assert codex.get_action_iface().do_action(0)
        eventually(lambda: provider.get_name() == 'Identity: Codex', 'Codex choice', process)
        assert not action.get_state_set().contains(Atspi.StateType.ENABLED)

        source = subprocess.Popen(['/usr/bin/python3',
            str(Path(__file__).with_name('gtk_file_drag_source.py')), str(image)],
            stdout=subprocess.DEVNULL, stderr=(output / 'drag-source.log').open('w'))
        source_window = eventually(lambda: xdo('search', '--all', '--onlyvisible', '--pid',
            str(source.pid)).splitlines()[0], 'drag source', source)
        xdo('windowmove', source_window, '0', '900')
        def drop_on_editor():
            bounds = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
            xdo('mousemove', '--sync', '--window', source_window, '50', '50')
            xdo('mousedown', '1')
            xdo('mousemove', '--sync', '--window', source_window, '82', '50')
            time.sleep(.2)
            xdo('mousemove', '--sync', '--window', window,
                str(bounds.x + bounds.width // 2), str(bounds.y + bounds.height // 2))
            # Xdnd's enter/position handshake is processed by the same loop that paints the
            # composer. Let it finish a frame before releasing under loaded build machines.
            time.sleep(1.5)
            xdo('mouseup', '1')

        drop_on_editor()
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'image-only brief enabled by attached preview', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == ''
        subprocess.run(['import', '-window', window, str(output / 'image-attached.png')],
                       check=True, timeout=5)
        xdo('windowsize', '--sync', window, '560', '180')
        eventually(lambda: editor.get_component_iface().get_extents(
            Atspi.CoordType.WINDOW).width < 300, 'compact attached prompt', process)
        subprocess.run(['import', '-window', window, str(output / 'image-attached-compact.png')],
                       check=True, timeout=5)
        xdo('windowsize', '--sync', window, '1120', '480')
        eventually(lambda: editor.get_component_iface().get_extents(
            Atspi.CoordType.WINDOW).width > 600, 'restored attached prompt', process)
        attached_editor = editor.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        subprocess.run(['xclip', '-selection', 'clipboard', '-t', 'text/uri-list', '-i'],
                       input=(image.as_uri() + '\r\n').encode(), check=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        eventually(lambda: 'text/uri-list' in subprocess.check_output(
            ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
            text=True, timeout=5), 'URI clipboard owner', process)
        xdo('windowfocus', '--sync', window)
        xdo('mousemove', '--window', window, str(attached_editor.x + 100),
            str(attached_editor.y + 20))
        xdo('click', '1')
        xdo('key', '--clearmodifiers', 'ctrl+v')
        def preview_count():
            rail = child_by_id(composer, 'linux.composer.attachments')
            return rail.get_child_count() if rail else 0
        eventually(lambda: preview_count() == 2,
                   'two previews share the horizontal rail', process)
        subprocess.run(['import', '-window', window, str(output / 'image-attached-pair.png')],
                       check=True, timeout=5)
        xdo('mousemove', '--window', window, str(attached_editor.x + 68),
            str(attached_editor.y - 78))
        xdo('click', '1')
        eventually(lambda: preview_count() == 1,
                   'remaining preview reflows after removal', process)
        assert action.get_state_set().contains(Atspi.StateType.ENABLED)
        xdo('click', '1')
        eventually(lambda: not action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'remove button clears image-only brief', process)
        xdo('windowsize', '--sync', window, '560', '180')
        time.sleep(.2)
        eventually(lambda: 'HEIGHT=180' in xdo('getwindowgeometry', '--shell', window),
                   'unattached window restores 180-pixel minimum', process)
        xdo('windowsize', '--sync', window, '1120', '480')
        xdo('windowfocus', '--sync', window)
        xdo('mousemove', '--window', window, str(attached_editor.x + 100),
            str(attached_editor.y + 20))
        xdo('click', '1')
        xdo('key', '--clearmodifiers', 'ctrl+v')
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'file URL paste attaches preview', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == ''
        rail = eventually(lambda: child_by_id(composer, 'linux.composer.attachments'),
                          'accessible attachment rail', process)
        preview = rail.get_child_at_index(0)
        assert preview.get_role_name() == 'image' and preview.get_name() == image.name
        remove = child_by_id(preview, 'linux.composer.attachment.remove.0')
        assert remove is not None and remove.get_role_name() == 'push button'
        assert remove.get_name() == f'Remove {image.name}'
        bounds = remove.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
        assert bounds.width > 0 and bounds.height > 0
        subprocess.run(['import', '-window', window, str(output / 'file-url-pasted.png')],
                       check=True, timeout=5)
        assert remove.get_action_iface().do_action(0)
        eventually(lambda: not action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'accessible removal clears pasted file URL', process)
        eventually(lambda: child_by_id(composer, 'linux.composer.attachments') is None,
                   'accessible rail retires after removal', process)
        assert remove.get_action_iface().get_n_actions() == 0, 'retired attachment action remained live'
        subprocess.run(['xclip', '-selection', 'clipboard', '-i'], input=b'Plain text paste',
                       check=True, timeout=5, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        eventually(lambda: subprocess.check_output(
            ['xclip', '-selection', 'clipboard', '-o'], timeout=5)
            == b'Plain text paste', 'plain text clipboard owner', process)
        xdo('mousemove', '--window', window, str(attached_editor.x + 100),
            str(attached_editor.y + 20))
        xdo('click', '1')
        xdo('key', '--clearmodifiers', 'ctrl+v')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1)
                   == 'Plain text paste', 'plain text paste fallback', process)
        xdo('key', '--clearmodifiers', 'ctrl+a')
        xdo('key', '--clearmodifiers', 'BackSpace')
        eventually(lambda: Atspi.Text.get_text(editor.get_text_iface(), 0, -1)
                   == '', 'plain text cleared', process)
        if delayed_owner_binary:
            delayed_owner = subprocess.Popen([delayed_owner_binary], stdout=subprocess.PIPE,
                                             text=True)
            assert select.select([delayed_owner.stdout], [], [], 5)[0], 'clipboard owner did not start'
            assert delayed_owner.stdout.readline().strip() == 'READY'
            editable = editor.get_editable_text_iface()
            text = editor.get_text_iface()
            for after_paste, expected, continued in [
                ('End', 'left paste right!', 'left paste right!?'),
                ('Home', '!left paste right', '!?left paste right')
            ]:
                assert editable.set_text_contents('left right')
                assert text.set_caret_offset(5)
                xdo('windowfocus', '--sync', window)
                xdo('key', '--clearmodifiers', 'ctrl+v')
                xdo('key', after_paste)
                xdo('type', '--clearmodifiers', '!')
                eventually(lambda: Atspi.Text.get_text(text, 0, -1) == expected,
                           'delayed paste remains at keypress selection', process)
                xdo('type', '--clearmodifiers', '?')
                eventually(lambda: Atspi.Text.get_text(text, 0, -1) == continued,
                           'later caret survives delayed paste', process)
                subprocess.run(['import', '-window', window,
                                str(output / f'delayed-text-{after_paste.lower()}.png')],
                               check=True, timeout=5)
            stop(delayed_owner)
            delayed_owner = None
            assert editable.set_text_contents('')
            print('PASS delayed clipboard text stays at its original caret', flush=True)
        tiff = root / 'clipboard.tiff'
        subprocess.run(['convert', str(image), str(tiff)], check=True, timeout=5)
        subprocess.run(['xclip', '-selection', 'clipboard', '-t', 'image/tiff', '-i'],
                       input=tiff.read_bytes(), check=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        eventually(lambda: 'image/tiff' in subprocess.check_output(
            ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
            text=True, timeout=5), 'TIFF clipboard owner', process)
        xdo('windowfocus', '--sync', window)
        xdo('key', '--clearmodifiers', 'ctrl+v')
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'TIFF paste attaches preview', process)
        tiff_rail = eventually(lambda: child_by_id(composer, 'linux.composer.attachments'),
                               'TIFF accessible rail', process)
        tiff_remove = child_by_id(tiff_rail.get_child_at_index(0),
                                  'linux.composer.attachment.remove.0')
        assert tiff_remove.get_name().startswith('Remove threading-attachment-')
        assert tiff_remove.get_name().endswith('.png'), 'TIFF paste should hand over PNG'
        subprocess.run(['import', '-window', window, str(output / 'tiff-pasted.png')],
                       check=True, timeout=5)
        assert tiff_remove.get_action_iface().do_action(0)
        eventually(lambda: not action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'TIFF preview removal', process)
        subprocess.run(['xclip', '-selection', 'clipboard', '-t', 'image/png', '-i'],
                       input=image.read_bytes(), check=True, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        eventually(lambda: 'image/png' in subprocess.check_output(
            ['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
            text=True, timeout=5), 'PNG clipboard owner', process)
        xdo('windowfocus', '--sync', window)
        xdo('mousemove', '--window', window, str(attached_editor.x + 100),
            str(attached_editor.y + 20))
        xdo('click', '1')
        xdo('key', '--clearmodifiers', 'ctrl+v')
        eventually(lambda: action.get_state_set().contains(Atspi.StateType.ENABLED),
                   'raw PNG paste attaches preview', process)
        assert Atspi.Text.get_text(editor.get_text_iface(), 0, -1) == ''
        remove.get_action_iface().do_action(0)
        time.sleep(.2)
        assert action.get_state_set().contains(Atspi.StateType.ENABLED), \
            'retired removal affected a later attachment'
        subprocess.run(['import', '-window', window, str(output / 'raw-png-pasted.png')],
                       check=True, timeout=5)
        assert action.get_action_iface().do_action(0)
        marker = project / 'attachment-agent.json'
        report = eventually(lambda: json.loads(marker.read_text()) if marker.exists() else None,
                            'agent submitted image path', process)
        assert report['argv'][-2] == '--' and len(report['argv'][-1:]) == 1, report
        pasted_path = Path(report['argv'][-1].strip('"'))
        assert pasted_path.name.startswith('threading-attachment-')
        assert pasted_path.read_bytes() == image.read_bytes()
        print('PASS Xdnd, URI-list, TIFF-to-PNG, raw PNG and plain-text paste, removal, image-only submit, exact PNG bytes',
              flush=True)
finally:
    stop(delayed_owner)
    stop(source)
    stop(process)
    stop(daemon_process)
