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
import tempfile
import unittest
import uuid

CONTROLLER = os.path.abspath(sys.argv[1]); del sys.argv[1]
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


if __name__ == '__main__':
    unittest.main()
