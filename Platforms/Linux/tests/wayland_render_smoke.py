"""Prove the installed Wayland window presents two distinct project states."""
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time

launcher, evidence = sys.argv[1:3]
scale = int(sys.argv[3]) if len(sys.argv) == 4 else 1
assert scale in (1, 2), scale
# The runner owns a 1280×800 Weston output. The 2× request must fit that output.
window_width, window_height = (1120, 480) if scale == 1 else (1280, 800)
sidebar_width = 240 * scale
evidence = Path(evidence)
capture = evidence / 'capture'
capture.mkdir(parents=True)
environment = dict(os.environ, THREADING_LINUX_CODEX='', THREADING_LINUX_CLAUDE='',
                   THREADING_LINUX_UI_SCALE=str(scale),
                   THREADING_LINUX_DATA_DIR=f'/tmp/threading-wayland-render-data-{scale}',
                   THREADING_LINUX_RUNTIME_DIR=f'/tmp/threading-wayland-render-runtime-{scale}',
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
    project.mkdir(exist_ok=True)
    (capture / 'trigger').write_text('\n')
    log_path = evidence / f'{state}.log'
    with log_path.open('w') as log:
        process = subprocess.Popen([launcher, str(project)], env=environment,
                                   stdout=log, stderr=log)
        try:
            image = capture / f'{state}.bmp'
            deadline = time.monotonic() + 15
            pane_frame = f'IDLE_PANE_FRAME {window_width - sidebar_width}x{window_height}'
            while not (pane_frame in log_path.read_text()
                       and f'FRAME {sidebar_width}x{window_height}' in log_path.read_text()):
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
                daemon_pid = int((Path(environment['THREADING_LINUX_RUNTIME_DIR']) / 'daemon.pid').read_text())
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
    # libwayland uses @ in older debug logs and # in Ubuntu 26.04. Match an actual
    # surface commit in either format rather than unrelated surface/method substrings.
    assert re.search(r'\bwl_surface[@#]\d+\.commit\(\)', content), 'no Wayland buffer commit'
    assert f'Threading experiment - {project}' in content, 'wrong selected project title'
    bitmap = image.read_bytes()
    assert bitmap[:2] == b'BM' and len(bitmap) > 320 * 180 * 3, 'invalid SDL render readback'
    width, height = struct.unpack_from('<ii', bitmap, 18)
    assert (width, height) == (window_width, window_height), (width, height)
    pixel_offset = struct.unpack_from('<I', bitmap, 10)[0]
    assert 54 <= pixel_offset < len(bitmap), pixel_offset
    return bitmap[pixel_offset:]


normal = render('WaylandProject', 'normal')
alternate = render('WaylandProjectOther', 'alternate')
input_socket.close()
assert normal != alternate, 'two selected projects produced identical rendered pixels'
print(f'PASS installed Wayland scale={scale}, toplevel, buffer commits and two distinct '
      f'{window_width}x{window_height} split workspace frames')
