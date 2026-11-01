#!/usr/bin/env python3
"""Opt-in real Codex idle-mail probe. Uses only a local mock API and a disposable account.

python3 scripts/test_codex_terminal_mail.py --codex /absolute/path/to/codex

Compiles the shipping supervisor generator, launches the actual TUI, queues a notice while
an unsent draft is present, submits that draft, and asserts both model requests and cleanup.
No user account, live session, real API or provider usage is involved.
"""
import argparse
import base64
import fcntl
import json
import os
import pty
import select
import shlex
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import threading
import time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--codex', required=True, type=Path)
args = parser.parse_args()
binary = str(args.codex.resolve(strict=True))
repo = Path(__file__).resolve().parent.parent
scratch = tempfile.TemporaryDirectory(prefix='threading-codex-mail-', dir='/tmp')
root = Path(scratch.name).resolve()
home = root / 'home'
home.mkdir()
(root / 'main.swift').write_text("""import Foundation
typealias SessionID = UUID
final class ManagedAgentRuntimeStore {
    func resolve(_ command: ShellCommand) -> (command: ShellCommand, environment: [String: String]) {
        (command, [:])
    }
}
var server = ShellCommand(word: CommandLine.arguments[1])
server.append(flag: "--dangerously-bypass-hook-trust")
server.append(word: "app-server")
server.append(flag: "--listen", value: "unix://" + CommandLine.arguments[2])
print(CodexTerminalLaunch.script(server: server, socketPath: CommandLine.arguments[2]))
""")
subprocess.run(['xcrun', 'swiftc', str(repo / 'Sources/Threading/Core/Agent/ShellCommand.swift'), str(repo / 'Sources/Threading/Core/Agent/CodexTerminalLaunch.swift'), str(root / 'main.swift'), '-o', str(root / 'generate')], check=True, timeout=60)
calls = []

class Handler(BaseHTTPRequestHandler):

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data":[]}')

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get('content-length', '0'))))
        calls.append(request)
        rid = 'resp_probe_' + str(len(calls))
        events = [{'type': 'response.created', 'response': {'id': rid}}, {'type': 'response.output_item.done', 'item': {'type': 'message', 'role': 'assistant', 'id': 'msg_' + rid, 'content': [{'type': 'output_text', 'text': 'PROBE_ACK'}]}}, {'type': 'response.completed', 'response': {'id': rid, 'usage': {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0}}}]
        body = ''.join(('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
api = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=api.serve_forever, daemon=True).start()
(home / 'config.toml').write_text(f"""model = "gpt-5.4"
model_provider = "probe"
check_for_update_on_startup = false
approval_policy = "never"
sandbox_mode = "workspace-write"
[model_providers.probe]
name = "Probe"
base_url = "http://127.0.0.1:{api.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
[projects.{json.dumps(str(root))}]
trust_level = "trusted"
[notice]
hide_full_access_warning = true
""")
# Trust bypass applies only to these two fixture-owned commands in the disposable account.
trace = root / 'lifecycle.txt'
(home / 'hooks.json').write_text(json.dumps({'hooks': {
    event: [{'hooks': [{'type': 'command', 'command':
        "cat >/dev/null; printf '%s\\n' " + shlex.quote(event) + " >> " + shlex.quote(str(trace))}]}]
    for event in ('UserPromptSubmit', 'Stop')
}}))
env = {'HOME': str(home), 'CODEX_HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TERM': 'xterm-256color'}
endpoint = root / 's'
endpoint.unlink(missing_ok=True)
log = open(root / 'server.log', 'w')
script = subprocess.check_output([str(root / 'generate'), binary, str(endpoint)], text=True)
(root / 'supervisor.sh').write_text(script)

def run_terminal(previous=None):
    draft = 'UNSENT_HUMAN_DRAFT_' + ('RESUMED' if previous else 'FRESH')
    notice = 'MAIL_WAKE_NOTICE_' + ('RESUMED' if previous else 'FRESH')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 120, 0, 0))
    tui = subprocess.Popen(['/bin/sh', str(root / 'supervisor.sh'), binary, '--no-alt-screen', '-c', 'check_for_update_on_startup=false'] + (['resume', previous] if previous else ['--dangerously-bypass-hook-trust']), cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    first_request = len(calls)
    client = None
    output = bytearray()
    try:
        for i in range(100):
            if endpoint.exists():
                break
            if tui.poll() is not None:
                raise RuntimeError('supervisor exited')
            time.sleep(0.1)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        client.connect(str(endpoint))
        f = client.makefile('rb')
        seq = 0
        client.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + base64.b64encode(os.urandom(16)) + b'\r\nSec-WebSocket-Version: 13\r\n\r\n')
        assert f.readline().startswith(b'HTTP/1.1 101 '), 'WebSocket upgrade failed'
        while f.readline() != b'\r\n':
            pass

        def send(obj):
            data = json.dumps(obj).encode()
            mask = os.urandom(4)
            size = len(data)
            header = bytes([129, 128 | size]) if size < 126 else bytes([129, 254]) + struct.pack('!H', size)
            client.sendall(header + mask + bytes((b ^ mask[i % 4] for i, b in enumerate(data))))

        def receive():
            head = f.read(2)
            if not head:
                raise RuntimeError('eof')
            size = head[1] & 127
            if size == 126:
                size = struct.unpack('!H', f.read(2))[0]
            if size == 127:
                size = struct.unpack('!Q', f.read(8))[0]
            return json.loads(f.read(size))

        def rpc(method, params):
            nonlocal seq
            seq += 1
            send({'id': seq, 'method': method, 'params': params})
            while True:
                d = receive()
                if d.get('id') == seq:
                    if 'error' in d:
                        raise RuntimeError(d['error'])
                    return d['result']
        rpc('initialize', {'clientInfo': {'name': 'threading-probe', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
        send({'method': 'initialized'})
        start = time.monotonic()
        typed = False
        queued = False
        submitted = False
        while time.monotonic() - start < 90:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                    output.extend(chunk)
                except OSError:
                    break
                if b'\x1b[6n' in chunk:
                    os.write(master, b'\x1b[1;1R')
                if b'\x1b]11;?' in chunk:
                    os.write(master, b'\x1b]11;rgb:0000/0000/0000\x1b\\')
                if b'\x1b[c' in chunk:
                    os.write(master, b'\x1b[?1;2c')
            elapsed = time.monotonic() - start
            if not typed and elapsed > 5:
                loaded = rpc('thread/loaded/list', {'limit': 100})
                if not loaded['data']:
                    continue
                assert len(loaded['data']) == 1, loaded
                tid = loaded['data'][0]
                if previous:
                    assert tid == previous, 'Resume switched conversations'
                os.write(master, draft.encode())
                typed = True
                typed_at = elapsed
            if typed and not queued and elapsed > typed_at + 3:
                q = subprocess.run([binary, 'queue', '--remote', 'unix://' + str(endpoint), '--thread', tid, '--message', notice], env=env, capture_output=True, text=True, timeout=10)
                assert q.returncode == 0, q.stderr
                queued = True
                queued_at = elapsed
            if queued and not submitted and elapsed > queued_at + 6:
                os.write(master, b'\r')
                submitted = True
            if submitted and elapsed > queued_at + 12:
                break
            if tui.poll() is not None:
                break
        assert tui.poll() is None, 'TUI exited unexpectedly: ' + output.decode(errors='replace')[-2000:]
        assert calls[first_request:] and notice in json.dumps(calls[first_request]), 'Idle mail did not start a turn: ' + output.decode(errors='replace')[-2500:]
        assert draft not in json.dumps(calls[first_request]), 'Mail consumed the draft'
        assert any((draft in json.dumps(c) for c in calls[first_request + 1:])), 'Draft was lost'
        if not previous:
            # Resume must exercise persisted trust. The CLI's invocation bypass does not
            # survive every remote resume path. Trust only this fixture's exact definitions.
            listing = rpc('hooks/list', {'cwds': [str(root)]})
            hooks = listing['data'][0]['hooks']
            assert len(hooks) == 2 and all(h['sourcePath'] == str(home / 'hooks.json') for h in hooks), listing
            rpc('config/value/write', {
                'keyPath': 'hooks.state', 'mergeStrategy': 'upsert',
                'filePath': str(home / 'config.toml'),
                'value': {h['key']: {'enabled': True, 'trusted_hash': h['currentHash']} for h in hooks}
            })
        os.write(master, b'\x04')
        deadline = time.monotonic() + 8
        while tui.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.05)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
        tui.wait(timeout=1)
        assert not endpoint.exists(), 'Supervisor left a socket after the TUI exited'
        print(('resumed' if previous else 'fresh') + ': idle wake, draft preserved and submitted, server retired')
    finally:
        (root / 'requests.json').write_text(json.dumps(calls, indent=2))
        (root / 'terminal.txt').write_bytes(output)
        if client:
            client.close()
        os.close(master)
        for p in (tui,):
            if p and p.poll() is None:
                print(subprocess.run(['ps', '-p', str(p.pid), '-o', 'pid,ppid,pgid,uid,state,comm'], capture_output=True, text=True).stdout, flush=True)
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except PermissionError:
                    p.terminate()
                try:
                    p.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    if p.poll() is None:
                        try:
                            os.killpg(p.pid, signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            p.kill()
                    p.wait(timeout=5)
    return tid
try:
    run_terminal(run_terminal())
    events = trace.read_text().splitlines()
    assert events.count('UserPromptSubmit') >= 4, events
    assert events.count('Stop') >= 4, events
    print('PASS: fresh/resumed delivery, drafts, cleanup, and ordinary turn hooks')
finally:
    api.shutdown()
    log.close()
