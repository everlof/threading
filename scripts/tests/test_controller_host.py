#!/usr/bin/env python3
"""Actual SQLite backup/restore and host bundle install contract, with synthetic state only."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sqlite3
import sys
import socket
import tempfile
import time
import unittest
import uuid

CONTROLLER = os.path.abspath(sys.argv[1]); del sys.argv[1]
# Optional: the threading-ptyd under test, for the installer's live-socket refusal.
PTYD = os.path.abspath(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else None
SUPPORT = Path(__file__).resolve().parents[2] / 'Targets/Controller/Support'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


state = module('host_state', SUPPORT / 'host-state.py')
installer = module('host_install', SUPPORT / 'install-host.py')


class HostTests(unittest.TestCase):
    def test_snapshot_restores_identity_and_memory_without_starting_work(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp)
            db = root / 'controller.db'
            def call(*args):
                return json.loads(subprocess.check_output([CONTROLLER, '--database', str(db), *args]))
            worker = str(uuid.uuid4())
            call('worker-add', worker, 'Fixture')
            host = call('host')
            note = root / 'note'; note.write_text('Synthetic memory')
            call('memory-put', worker, 'profile', '0', str(note))
            backup = root / 'backup.sqlite'; restored = root / 'restored.sqlite'
            self.assertEqual(state.snapshot(db, backup)['integrity'], 'ok')
            self.assertTrue(state.snapshot(backup, restored, True)['disarmed'])
            db = restored
            self.assertEqual(call('host'), host)
            self.assertEqual(call('memory-get', worker, 'profile')['content'], 'Synthetic memory')
            with self.assertRaisesRegex(ValueError, 'new_destination'):
                state.snapshot(backup, restored, True)

    def test_legacy_snapshot_disarms_before_migration(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp)
            source = root / 'legacy.db'
            with sqlite3.connect(source) as db:
                db.execute('PRAGMA user_version=6')
                db.execute('CREATE TABLE record(sequence INTEGER,kind TEXT,payload TEXT)')
                db.execute("INSERT INTO record VALUES(1,'workerPolicy',?)", (json.dumps({'enabled': True, 'revision': 1}),))
            restored = root / 'restored.db'
            self.assertEqual(state.snapshot(source, restored, True)['schema'], 6)
            with sqlite3.connect(restored) as db:
                self.assertEqual(json.loads(db.execute('SELECT payload FROM record').fetchone()[0]), {'enabled': False, 'revision': 2})

    def test_install_checks_integrity_and_refuses_implicit_upgrade(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp); home = root / 'home'; home.mkdir(mode=0o700)
            bundle = root / 'bundle'; bundle.mkdir()
            for name in installer.FILES:
                if name == 'threading-controller':
                    (bundle / name).write_bytes(Path(CONTROLLER).read_bytes())
                else:
                    (bundle / name).write_text('fixture')
                (bundle / name).chmod(0o700)
            metadata = json.loads(subprocess.check_output([CONTROLLER, '--version']))
            manifest = {'version': 1, 'system': 'Linux', 'machine': platform.machine(), 'controller': metadata,
                        'files': {name: hashlib.sha256((bundle / name).read_bytes()).hexdigest() for name in installer.FILES}}
            (bundle / 'manifest.json').write_text(json.dumps(manifest))
            self.assertFalse(installer.install(bundle, home)['servicesStarted'])
            self.assertFalse(installer.install(bundle, home)['servicesStarted'])
            (bundle / 'threading-ptyd').write_text('modified')
            with self.assertRaisesRegex(ValueError, 'digest_mismatch'):
                installer.install(bundle, home)


    def test_install_splits_controller_and_agent_user_units(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp); bundle = self.bundle(root)
            single = root / 'single'; single.mkdir(mode=0o700)
            installer.install(bundle, single)
            unit = (single / '.config/systemd/user/threading-controller.service').read_text()
            self.assertIn('supervise 2000\n', unit)
            self.assertIn('UMask=0077', (single / '.config/systemd/user/threading-ptyd.service').read_text())

            controller = root / 'controller'; controller.mkdir(mode=0o700)
            result = installer.install(bundle, controller, role='controller', agent_socket='/srv/threading-shared/agent.sock')
            self.assertEqual(result['units'], ['threading-controller'])
            units = controller / '.config/systemd/user'
            self.assertFalse((units / 'threading-ptyd.service').exists())
            self.assertIn('supervise 2000 --agent-socket /srv/threading-shared/agent.sock\n',
                          (units / 'threading-controller.service').read_text())

            agent = root / 'agent'; agent.mkdir(mode=0o700)
            result = installer.install(bundle, agent, role='ptyd', ptyd_socket='/srv/threading-shared/ptyd.sock')
            self.assertEqual(result['units'], ['threading-ptyd'])
            text = (agent / '.config/systemd/user/threading-ptyd.service').read_text()
            self.assertIn('--socket /srv/threading-shared/ptyd.sock', text)
            self.assertIn('--group-socket', text)
            self.assertIn('UMask=0027', text)
            for bad in [dict(role='ptyd', agent_socket='/x/a.sock'), dict(role='controller', agent_socket='relative'),
                        dict(role='controller', agent_socket='/x/../a.sock'), dict(role='nobody')]:
                with self.assertRaises(ValueError):
                    installer.install(bundle, root / 'agent', **bad)

    def test_ptyd_install_marks_its_directory_for_the_mac(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp); bundle = self.bundle(root)
            for role in ('all', 'ptyd', 'controller'):
                home = root / role; home.mkdir(mode=0o700)
                result = installer.install(bundle, home, role=role)
                [release] = (home / '.local/lib/threading/hosts').iterdir()
                self.assertEqual(release.name, result['generation'])
                marker = release / '.threading-managed-by'
                if role == 'controller':
                    self.assertFalse(marker.exists(), 'a controller-only install installs no daemon to mark')
                else:
                    # First line, exactly what RemoteHostProvenance reads as external.
                    self.assertEqual(marker.read_text().splitlines()[0], 'external:threading-host-bundle')
                    self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
                    installer.install(bundle, home, role=role)  # idempotent over its own marker
            foreign = root / 'foreign'; foreign.mkdir(mode=0o700)
            result = installer.install(bundle, foreign, role='controller')
            (foreign / '.local/lib/threading/hosts' / result['generation'] / '.threading-managed-by').write_text('threading-mac\n')
            with self.assertRaisesRegex(ValueError, 'marked_by_another_installer'):
                installer.install(bundle, foreign, role='ptyd')

    def test_agent_binary_reaches_the_supervisor_command(self):
        with tempfile.TemporaryDirectory(prefix='host-') as temp:
            root = Path(temp); bundle = self.bundle(root)
            agent_binary = root / 'opt-controller'
            agent_binary.write_bytes(Path(CONTROLLER).read_bytes()); agent_binary.chmod(0o755)
            home = root / 'controller'; home.mkdir(mode=0o700)
            installer.install(bundle, home, role='controller', agent_socket='/srv/threading/broker/agent.sock',
                              agent_binary=str(agent_binary))
            unit = (home / '.config/systemd/user/threading-controller.service').read_text()
            self.assertIn(f'supervise 2000 --agent-socket /srv/threading/broker/agent.sock --agent-binary {agent_binary}\n', unit)
            (root / 'not-executable').write_text('x')
            for bad in ['relative/controller', str(root / 'missing'), str(root / 'not-executable'), str(root / '..' / 'x'), str(root)]:
                with self.assertRaisesRegex(ValueError, 'agent_binary'):
                    installer.install(bundle, home, role='controller', agent_binary=bad)
            with self.assertRaisesRegex(ValueError, 'option_does_not_apply_to_role'):
                installer.install(bundle, home, role='ptyd', agent_binary=str(agent_binary))

    @unittest.skipUnless(PTYD, 'needs the threading-ptyd under test as the second argument')
    def test_ptyd_install_refuses_a_socket_another_live_daemon_answers(self):
        # Short names: the default socket path under this home must fit sun_path (104 bytes).
        with tempfile.TemporaryDirectory(prefix='ih-', dir='/tmp' if os.path.isdir('/tmp') else None) as temp:
            root = Path(temp); bundle = self.bundle(root)
            home = root / 'h'; home.mkdir(mode=0o700)
            pty = home / '.local/state/threading/pty'; pty.mkdir(parents=True, mode=0o700)
            sock = pty / 'ptyd.sock'
            units = home / '.config/systemd/user'

            # The Mac's remote-host layout: same socket, state directory .../pty rather than .../pty/host.
            other = self.daemon(sock, pty)
            try:
                with self.assertRaisesRegex(ValueError, rf'ptyd_socket_in_use: {sock} .*pid {other.pid}.*state {pty}'):
                    installer.install(bundle, home)
                self.assertFalse(units.exists(), 'a refused install writes no unit')
                self.assertIsNone(other.poll(), 'the other daemon is left running')
                completed = subprocess.run([sys.executable, str(SUPPORT / 'install-host.py'), str(bundle), '--home', str(home)],
                                           capture_output=True, text=True)
                self.assertEqual(completed.returncode, 1)
                self.assertIn('install-host: ptyd_socket_in_use', completed.stderr)
                # A controller-only install has no daemon to collide.
                installer.install(bundle, home, role='controller')
            finally:
                self.stop(other)

            # A crashed daemon's leftover socket is not a conflict. (A terminated ptyd leaves one.)
            if not sock.exists():
                leftover = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); leftover.bind(str(sock)); leftover.close()
            self.assertTrue(sock.is_socket())
            self.assertIsNone(installer.socket_occupant(sock))
            # Nor is this installation's own daemon, already running from its unit.
            own = self.daemon(sock, pty / 'host')
            try:
                self.assertEqual(installer.install(bundle, home, role='ptyd')['units'], ['threading-ptyd'])
            finally:
                self.stop(own)

    def daemon(self, sock, state):
        process = subprocess.Popen([PTYD, '--socket', str(sock), '--state', str(state)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if installer.socket_occupant(sock) is not None:
                return process
            if process.poll() is not None:
                self.fail(f'threading-ptyd exited {process.returncode} before listening')
            time.sleep(0.05)
        self.stop(process); self.fail('threading-ptyd never listened')

    @staticmethod
    def stop(process):
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait()

    def bundle(self, root):
        bundle = root / 'bundle'; bundle.mkdir()
        for name in installer.FILES:
            if name == 'threading-controller':
                (bundle / name).write_bytes(Path(CONTROLLER).read_bytes())
            else:
                (bundle / name).write_text('fixture')
            (bundle / name).chmod(0o700)
        metadata = json.loads(subprocess.check_output([CONTROLLER, '--version']))
        manifest = {'version': 1, 'system': 'Linux', 'machine': platform.machine(), 'controller': metadata,
                    'files': {name: hashlib.sha256((bundle / name).read_bytes()).hexdigest() for name in installer.FILES}}
        (bundle / 'manifest.json').write_text(json.dumps(manifest))
        return bundle


if __name__ == '__main__':
    unittest.main()
