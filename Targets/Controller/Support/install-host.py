#!/usr/bin/env python3
"""Install a verified controller/ptyd bundle for the current service account. No public port.
Existing services are never restarted implicitly; --start is for a new installation.

One account (the default, --role all) runs both units. To run agents under their own Unix user,
install twice from the same bundle: as the controller user with --role controller and
--agent-socket in a group-shared directory, and as the agent user with --role ptyd and
--ptyd-socket in a group-shared directory (the daemon then listens 0660 and writes 0027). The
directories, the shared group and the recipes' socketPath are set up as autonomous-controller.md
("Running agents as another Unix user") describes; this script creates no users or groups.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

FILES = {'threading-controller', 'threading-ptyd', 'host-state.py', 'install-host.py'}


ROLES = ('all', 'controller', 'ptyd')
SAFE_PATH = r'/[A-Za-z0-9/_.-]+'


def install(bundle, home, start=False, role='all', agent_socket=None, ptyd_socket=None):
    if role not in ROLES:
        raise ValueError('invalid_role')
    for path in (agent_socket, ptyd_socket):
        if path is not None and (not re.fullmatch(SAFE_PATH, str(path)) or '..' in str(path).split('/')):
            raise ValueError('invalid_socket_path')
    if agent_socket is not None and role == 'ptyd' or ptyd_socket is not None and role == 'controller':
        raise ValueError('option_does_not_apply_to_role')
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
    # A separate agent user: ptyd's socket is group-shared and what agents write (transcripts the
    # controller's usage collector reads) is group-readable. One account keeps 0600/0077.
    shared = role == 'ptyd' and ptyd_socket is not None
    ptyd = f'{release}/threading-ptyd --socket {ptyd_socket or f"{state}/pty/ptyd.sock"} --state {state}/pty/host'
    controller = f'{release}/threading-controller --database {state}/controller/controller.db supervise 2000'
    definitions = {
        'threading-ptyd': ptyd + (' --group-socket' if shared else ''),
        'threading-controller': controller + (f' --agent-socket {agent_socket}' if agent_socket else ''),
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
    parser.add_argument('--ptyd-socket', help='ptyd: listen here 0660 (a group-shared directory)')
    args = parser.parse_args()
    print(json.dumps(install(args.bundle.resolve(), args.home.resolve(), args.start, args.role,
                             args.agent_socket, args.ptyd_socket)))
