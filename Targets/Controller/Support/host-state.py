#!/usr/bin/env python3
"""Protected controller snapshots and isolated, disarmed restores. Never starts services."""
import argparse
import json
import os
from pathlib import Path
import sqlite3


def private_parent(path):
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink() or parent.stat().st_uid != os.getuid() or parent.stat().st_mode & 0o077:
        raise ValueError('owner_only_parent_required')
    if path.exists() or path.is_symlink():
        raise ValueError('new_destination_required')


def snapshot(source, destination, disarm=False):
    private_parent(destination)
    if not source.is_file() or source.is_symlink():
        raise ValueError('regular_source_required')
    # Exclusive reservation prevents overwriting an existing recovery artifact.
    descriptor = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        with sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True) as original, sqlite3.connect(destination) as target:
            original.backup(target)
            if target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('integrity_failed')
            version = target.execute('PRAGMA user_version').fetchone()[0]
            if version not in (6, 7, 8, 9, 10):
                raise ValueError('unsupported_schema')
            if disarm:
                for sequence, kind, payload in target.execute("SELECT sequence,kind,payload FROM record WHERE kind IN ('workerPolicy','automation','source','trigger','mailPeer')").fetchall():
                    value = json.loads(payload)
                    if kind == 'mailPeer':
                        value['push'] = value['pull'] = False
                    else:
                        value['enabled'] = False
                    value['revision'] = value.get('revision', 0) + 1
                    target.execute('UPDATE record SET payload=? WHERE sequence=?', (json.dumps(value), sequence))
                for table in ('automation_due', 'source_due'):
                    if target.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                        target.execute(f'DELETE FROM {table}')
            target.commit()
        return {'schema': version, 'integrity': 'ok', 'disarmed': disarm, 'servicesStarted': False}
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['capture', 'restore'])
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(json.dumps(snapshot(args.source, args.destination, args.operation == 'restore')))


if __name__ == '__main__':
    main()
