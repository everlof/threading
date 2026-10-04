#!/usr/bin/env python3
"""Install a verified controller/ptyd bundle for the current service account. No public port.
Existing services are never restarted implicitly; --start is for a new installation.

One account (the default, --role all) runs both units. To run agents under their own Unix user,
install twice from the same bundle: as the controller user with --role controller,
--agent-socket in a group-shared directory and --agent-binary naming a controller copy the agent
user can execute, and as the agent user with --role ptyd and --ptyd-socket in a group-shared
directory (the daemon then listens 0660 and writes 0027). The accounts, the shared group, the
directories, the agent-binary copy, linger and the recipes' socketPath are manual steps, as
autonomous-controller.md ("Running agents as another Unix user") describes; this script creates
no users, groups or directories outside the service account's home.

A ptyd install writes `external:threading-host-bundle` into its release directory's `.threading-managed-by`,
so the Mac's Remote Hosts setup never retires, disables or prunes it, and refuses to write a ptyd
unit whose socket another live daemon already answers.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import stat
import struct
import subprocess
import sys

FILES = {'threading-controller', 'threading-ptyd', 'host-state.py', 'install-host.py'}


ROLES = ('all', 'controller', 'ptyd')
SAFE_PATH = r'/[A-Za-z0-9/_.-]+'
# The provenance marker the Mac's Remote Hosts setup reads (RemoteHostDefaults): an install
# directory whose first line is `external:<name>` is another installer's, never retired or pruned.
MARKER = '.threading-managed-by'
PROVENANCE = 'external:threading-host-bundle'

# The ptyd wire (docs/architecture/pty-host.md, "Framing"): [u8 kind][u8 flags][u16][u32 length].
FRAME_HEADER = struct.Struct('<BBHI')
FRAME_CONTROL = 0
FRAME_LIMIT = 1 << 20
PTYD_PROTOCOL = 1
PROBE_SECONDS = 3


def safe_path(path):
    return path is not None and re.fullmatch(SAFE_PATH, str(path)) and '..' not in str(path).split('/')


def socket_occupant(path, timeout=PROBE_SECONDS):
    """None when nothing listens at `path`: no file, not a socket, or a refused connect (a crashed
    daemon's leftover). Otherwise a dict describing the live listener, with the daemon's `pid` and
    `build` when it answered `hello` and `pid` None when it accepted but said something else or
    nothing. The same rule threading-ptyd applies to its own socket at startup; never sends `retire`."""
    try:
        if not stat_is_socket(path):
            return None
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError:
        return None
    with client:
        client.settimeout(timeout)
        try:
            client.connect(str(path))
        except (ConnectionRefusedError, FileNotFoundError, NotADirectoryError):
            return None
        except OSError as error:
            return {'pid': None, 'detail': f'connect failed: {error.strerror or error}'}
        hello = json.dumps({'type': 'hello', 'body': {'protocol': PTYD_PROTOCOL, 'minimumSupported': PTYD_PROTOCOL,
                                                       'build': 'install-host', 'pid': os.getpid()}}).encode()
        try:
            client.sendall(FRAME_HEADER.pack(FRAME_CONTROL, 0, 0, len(hello)) + hello)
            kind, _, _, length = FRAME_HEADER.unpack(receive(client, FRAME_HEADER.size))
            if kind != FRAME_CONTROL or length > FRAME_LIMIT:
                return {'pid': None, 'detail': 'answered with something other than a ptyd hello'}
            frame = json.loads(receive(client, length))
        except (OSError, ValueError, struct.error):
            return {'pid': None, 'detail': 'accepted a connection and did not answer hello'}
        if frame.get('type') == 'hello':
            body = frame.get('body') or {}
            return {'pid': body.get('pid'), 'build': body.get('build'), 'detail': 'a threading-ptyd answered hello'}
        return {'pid': None, 'detail': f'a threading-ptyd answered {frame.get("type")}'}


def stat_is_socket(path):
    try:
        return stat.S_ISSOCK(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False


def receive(client, count):
    data = b''
    while len(data) < count:
        chunk = client.recv(count - len(data))
        if not chunk:
            raise ValueError('closed')
        data += chunk
    return data


def daemon_state_directory(pid):
    """The `--state` a running threading-ptyd was started with, or None when unreadable."""
    try:
        arguments = Path(f'/proc/{int(pid)}/cmdline').read_bytes().decode().split('\0')
    except (OSError, ValueError, TypeError):
        try:
            arguments = subprocess.check_output(['ps', '-ww', '-o', 'command=', '-p', str(int(pid))],
                                                timeout=5, text=True).split()
        except (OSError, ValueError, TypeError, subprocess.SubprocessError):
            return None
    if '--state' in arguments and arguments.index('--state') + 1 < len(arguments):
        return arguments[arguments.index('--state') + 1]
    return None


def refuse_foreign_daemon(socket_path, state_directory):
    """A live daemon of another state directory on our socket: writing a unit there would either
    fail to start (ptyd refuses a live socket) or, with an older ptyd, strand that daemon's agents."""
    occupant = socket_occupant(socket_path)
    if occupant is None:
        return
    pid = occupant.get('pid')
    running = daemon_state_directory(pid) if pid else None
    if running and os.path.realpath(running) == os.path.realpath(state_directory):
        return  # this installation's own daemon, already running
    who = f"pid {pid}, build {occupant.get('build')}, state {running or 'unknown'}" if pid else occupant['detail']
    raise ValueError(f'ptyd_socket_in_use: {socket_path} is answered by another live daemon ({who}); '
                     f'stop it or install with a different --ptyd-socket')


def install(bundle, home, start=False, role='all', agent_socket=None, ptyd_socket=None, agent_binary=None):
    if role not in ROLES:
        raise ValueError('invalid_role')
    for path in (agent_socket, ptyd_socket):
        if path is not None and not safe_path(path):
            raise ValueError('invalid_socket_path')
    if (agent_socket is not None or agent_binary is not None) and role == 'ptyd' or ptyd_socket is not None and role == 'controller':
        raise ValueError('option_does_not_apply_to_role')
    if agent_binary is not None:
        # The controller copy agents of another Unix user run their tools with (supervise
        # --agent-binary). Checked here so a typo is an install error, not every launch's.
        candidate = Path(agent_binary)
        if not safe_path(agent_binary) or not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise ValueError('agent_binary_must_be_an_absolute_executable_path')
    manifest_bytes = (bundle / 'manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest.get('version') != 1 or manifest.get('system') != 'Linux' or manifest.get('machine') != platform.machine():
        raise ValueError('incompatible_bundle')
    if set(manifest.get('files', {})) != FILES:
        raise ValueError('invalid_manifest')
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+', str(home)) or home.is_symlink() or home.stat().st_uid != os.getuid():
        raise ValueError('owned_service_home_required')
    for name, digest in manifest['files'].items():
        source = bundle / name
        if source.is_symlink() or hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise ValueError('bundle_digest_mismatch')
    reported = json.loads(subprocess.check_output([str(bundle / 'threading-controller'), '--version'], timeout=10))
    if reported != manifest['controller']:
        raise ValueError('controller_capability_mismatch')
    generation = hashlib.sha256(manifest_bytes).hexdigest()
    release = home / '.local/lib/threading/hosts' / generation
    state = home / '.local/state/threading'
    units = home / '.config/systemd/user'
    installs_ptyd = role in ('all', 'ptyd')
    ptyd_socket_path = ptyd_socket or f'{state}/pty/ptyd.sock'
    if installs_ptyd:
        refuse_foreign_daemon(ptyd_socket_path, f'{state}/pty/host')
    for directory in [release, state / 'controller', state / 'pty', units]:
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, digest in manifest['files'].items():
        target = release / name
        if target.exists():
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError('installed_digest_mismatch')
        else:
            with target.open('xb') as stream:
                stream.write((bundle / name).read_bytes())
            target.chmod(0o700)
    if installs_ptyd:
        # Never overwritten: a directory another installer marked stays that installer's.
        marker = release / MARKER
        if marker.is_symlink() or marker.exists() and marker.read_text().split('\n', 1)[0].strip() != PROVENANCE:
            raise ValueError('install_directory_marked_by_another_installer')
        if not marker.exists():
            with marker.open('x') as stream:
                stream.write(PROVENANCE + '\n')
            marker.chmod(0o600)
    # A separate agent user: ptyd's socket is group-shared and what agents write (transcripts the
    # controller's usage collector reads) is group-readable. One account keeps 0600/0077.
    shared = role == 'ptyd' and ptyd_socket is not None
    ptyd = f'{release}/threading-ptyd --socket {ptyd_socket_path} --state {state}/pty/host'
    controller = f'{release}/threading-controller --database {state}/controller/controller.db supervise 2000'
    definitions = {
        'threading-ptyd': ptyd + (' --group-socket' if shared else ''),
        'threading-controller': controller + (f' --agent-socket {agent_socket}' if agent_socket else '')
        + (f' --agent-binary {agent_binary}' if agent_binary else ''),
    }
    if role != 'all':
        definitions = {name: command for name, command in definitions.items() if name == f'threading-{role}'}
    for name, command in definitions.items():
        unit = units / f'{name}.service'
        text = f'''[Unit]
Description=Threading {name}
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=simple
ExecStart={command}
Restart=on-failure
RestartSec=10
TimeoutStopSec=30
UMask={'0027' if name == 'threading-ptyd' and shared else '0077'}
NoNewPrivileges=yes
MemoryMax={'8G' if name == 'threading-ptyd' else '512M'}
TasksMax={'512' if name == 'threading-ptyd' else '128'}
[Install]
WantedBy=default.target
'''
        if unit.exists() and unit.read_text() != text:
            raise ValueError('existing_service_requires_explicit_upgrade')
        unit.write_text(text)
        unit.chmod(0o600)
    if start:
        if home != Path.home() or os.getuid() == 0:
            raise ValueError('start_requires_current_nonroot_service_account')
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True, timeout=30)
        subprocess.run(['systemctl', '--user', 'enable', '--now', *definitions], check=True, timeout=30)
    return {'generation': generation, 'schema': reported['schema'], 'servicesStarted': start, 'units': sorted(definitions)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--start', action='store_true')
    parser.add_argument('--role', choices=ROLES, default='all',
                        help='which units this account runs: both, or one half of a separate-agent-user host')
    parser.add_argument('--agent-socket', help='controller: serve agent tools here (a group-shared directory)')
    parser.add_argument('--agent-binary',
                        help='controller: the controller executable agents run their tools with, when they are '
                             'another Unix user and cannot execute the service copy (an absolute path you created)')
    parser.add_argument('--ptyd-socket', help='ptyd: listen here 0660 (a group-shared directory)')
    args = parser.parse_args()
    try:
        result = install(args.bundle.resolve(), args.home.resolve(), args.start, args.role,
                         args.agent_socket, args.ptyd_socket, args.agent_binary)
    except ValueError as error:
        print(f'install-host: {error}', file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))
