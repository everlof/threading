"""Prove the installed Wayland window presents two distinct project states."""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time

launcher, evidence = sys.argv[1:]
evidence = Path(evidence)
capture = evidence / 'capture'
capture.mkdir(parents=True)
environment = dict(os.environ, THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='',
                   THREADING_LINUX_DATA_DIR='/tmp/threading-wayland-render-data',
                   THREADING_LINUX_RUNTIME_DIR='/tmp/threading-wayland-render-runtime',
                   THREADING_WAYLAND_CAPTURE_DIR=str(capture), WAYLAND_DEBUG='client',
                   LD_PRELOAD='/tmp/wayland_capture.so')
input_socket = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
input_socket.bind(str(evidence / 'input-client'))
input_socket.settimeout(3)


def inject(command):
    input_socket.sendto(command.encode(), os.environ['THREADING_WESTON_INPUT_SOCKET'])
    response = input_socket.recv(128)
    if command == 'origin':
        assert response.startswith(b'ORIGIN '), response
        return tuple(map(int, response.decode().split()[1:]))
    assert response == b'OK', (command, response)


def render(project_name, state):
    project = Path('/tmp') / project_name
    project.mkdir()
    (capture / 'trigger').write_text('\n')
    log_path = evidence / f'{state}.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([launcher, str(project)], env=environment,
                                   stdout=log, stderr=log)
        try:
            image = capture / f'{state}.bmp'
            deadline = time.monotonic() + 15
            while not ('IDLE_PANE_FRAME 800x480' in log_path.read_text()
                       and 'FRAME 320x480' in log_path.read_text()):
                assert process.poll() is None, f'{state} window exited: {log_path.read_text()[-4000:]}'
                assert time.monotonic() < deadline, f'{state} split frame timed out: {log_path.read_text()[-4000:]}'
                time.sleep(.05)
            # The first SDL present precedes both retained panes. Arm readback after their
            # frames, then ask Weston for a real pointer event to repaint the placeholder.
            (capture / 'trigger').write_text(state + '\n')
            origin_x, origin_y = inject('origin')
            inject(f'move {origin_x + (700 if state == "normal" else 710)} {origin_y + 70}')
            while not image.is_file():
                assert process.poll() is None, f'{state} window exited: {log_path.read_text()[-4000:]}'
                assert time.monotonic() < deadline, f'{state} capture timed out: {log_path.read_text()[-4000:]}'
                time.sleep(.05)
            window_environment = Path(f'/proc/{process.pid}/environ').read_bytes().split(b'\0')
            expected = ('LIBDECOR_PLUGIN_DIR=' +
                        os.environ['THREADING_WAYLAND_EXPECTED_PLUGIN_DIR']).encode()
            assert expected in window_environment, 'window did not receive selected Cairo plugin path'
            if 'LIBDECOR_PLUGIN_DIR' not in os.environ:
                daemon_pid = int(Path('/tmp/threading-wayland-render-runtime/daemon.pid').read_text())
                daemon_environment = Path(f'/proc/{daemon_pid}/environ').read_bytes().split(b'\0')
                assert not any(value.startswith(b'LIBDECOR_PLUGIN_DIR=')
                               for value in daemon_environment), 'launcher injected plugin path into daemon'
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    content = log_path.read_text()
    assert 'get_toplevel(new id xdg_toplevel' in content, 'no Wayland toplevel'
    assert 'wl_surface@' in content and '.commit()' in content, 'no Wayland buffer commit'
    assert f'Threading experiment - {project}' in content, 'wrong selected project title'
    bitmap = image.read_bytes()
    assert bitmap[:2] == b'BM' and len(bitmap) > 320 * 180 * 3, 'invalid SDL render readback'
    width, height = struct.unpack_from('<ii', bitmap, 18)
    assert (width, height) == (1120, 480), (width, height)
    pixel_offset = struct.unpack_from('<I', bitmap, 10)[0]
    assert 54 <= pixel_offset < len(bitmap), pixel_offset
    return bitmap[pixel_offset:]


normal = render('WaylandProject', 'normal')
alternate = render('WaylandProjectOther', 'alternate')
input_socket.close()
assert normal != alternate, 'two selected projects produced identical rendered pixels'
print('PASS installed Wayland toplevel, buffer commits and two distinct 1120x480 split workspace frames')
