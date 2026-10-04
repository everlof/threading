#!/usr/bin/env python3
"""Protected controller snapshots and isolated, disarmed restores. Never starts services.

capture DATABASE SNAPSHOT_DIR   An online, read-only backup of the store plus the store's owner-only
                                secrets/ directory, into a new owner-only directory.
restore SNAPSHOT DATABASE       A disarmed copy of the store at DATABASE (a new file), and the
                                snapshot's secrets into DATABASE's directory as secrets/ (which must
                                not exist yet). SNAPSHOT is a capture directory, or a database file
                                from an older host-state.py (which captured no secrets).

The schemas accepted are the ones the bundle's threading-controller reports it can open (its
`--version`), not a list written here.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys

DATABASE_NAME = 'controller.db'
SECRETS_NAME = 'secrets'
MANIFEST_NAME = 'snapshot.json'
SNAPSHOT_FORMAT = 1
# The controller's own bounds (SecretName, `secret-set`'s 16 KiB): a secret it could not have
# written is not one to carry forward. The count bounds the scan, not just the result.
SECRET_NAME = re.compile(r'[A-Za-z0-9_-]{1,64}')
SECRET_BYTES = 16_384
SECRET_COUNT = 4096
CONTROLLER_NAME = 'threading-controller'


def private_parent(path):
    parent = path.parent
    if not parent.is_dir() or parent.is_symlink() or parent.stat().st_uid != os.getuid() or parent.stat().st_mode & 0o077:
        raise ValueError('owner_only_parent_required')
    if path.exists() or path.is_symlink():
        raise ValueError('new_destination_required')


def supported_schemas(controller):
    """1 through the schema the controller binary reads and writes. It migrates any older store
    forward on first open and refuses a newer one; 0 is an empty file, not a store."""
    controller = Path(controller) if controller else Path(__file__).resolve().parent / CONTROLLER_NAME
    try:
        reported = json.loads(subprocess.check_output([str(controller), '--version'], timeout=10))
        newest = int(reported['schema'])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        raise ValueError('controller_version_unavailable: pass --controller PATH') from None
    return range(1, newest + 1)


def copy_database(source, destination, schemas, disarm):
    """Writes an integrity-checked backup of `source` to the new file `destination`."""
    if not source.is_file() or source.is_symlink():
        raise ValueError('regular_source_required')
    # Exclusive reservation prevents overwriting an existing recovery artifact.
    os.close(os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    with contextlib.closing(sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True)) as original, \
            contextlib.closing(sqlite3.connect(destination)) as target:
        original.backup(target)
        if target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('integrity_failed')
        version = target.execute('PRAGMA user_version').fetchone()[0]
        if version not in schemas:
            raise ValueError('unsupported_schema')
        if disarm:
            disarm_store(target)
        target.commit()
    return version


def disarm_store(target):
    if not target.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='record'").fetchone():
        return
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


def read_secrets(directory):
    """{name: (mode, bytes)} from an owner-only secrets directory, or {} when there is none.

    Refuses rather than skips: a backup that silently left out a secret is found missing only
    when it is needed. Symlinks are refused (the directory itself and every entry), every file
    must be the caller's, regular, owner-only and within the controller's own size bound."""
    try:
        info = os.lstat(directory)
    except FileNotFoundError:
        return {}
    if stat.S_ISLNK(info.st_mode):
        raise ValueError('secrets_symlink_refused')
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('secrets_not_owner_only')
    secrets = {}
    with os.scandir(directory) as entries:
        for entry in entries:
            if len(secrets) >= SECRET_COUNT:
                raise ValueError('too_many_secrets')
            if entry.is_symlink():
                raise ValueError('secrets_symlink_refused')
            if not SECRET_NAME.fullmatch(entry.name):
                raise ValueError('secret_name_invalid')
            descriptor = os.open(entry.path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, 'O_NONBLOCK', 0))
            with os.fdopen(descriptor, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise ValueError('secrets_not_owner_only')
                if info.st_size > SECRET_BYTES:
                    raise ValueError('secret_too_large')
                data = stream.read(SECRET_BYTES + 1)
                if len(data) > SECRET_BYTES:
                    raise ValueError('secret_too_large')
            secrets[entry.name] = (stat.S_IMODE(info.st_mode), data)
    return secrets


def write_secrets(directory, secrets):
    os.mkdir(directory, 0o700)
    os.chmod(directory, 0o700)
    for name, (mode, data) in secrets.items():
        descriptor = os.open(directory / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            os.fchmod(stream.fileno(), mode)


def capture(source, destination, controller=None):
    private_parent(destination)
    schemas = supported_schemas(controller)
    # Read first: a refused secret leaves no half-made snapshot behind.
    secrets = read_secrets(source.parent / SECRETS_NAME)
    os.mkdir(destination, 0o700)
    try:
        os.chmod(destination, 0o700)
        version = copy_database(source, destination / DATABASE_NAME, schemas, disarm=False)
        if secrets:
            write_secrets(destination / SECRETS_NAME, secrets)
        manifest = {'format': SNAPSHOT_FORMAT, 'schema': version, 'secrets': len(secrets)}
        descriptor = os.open(destination / MANIFEST_NAME, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(manifest, stream)
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    return {'schema': version, 'integrity': 'ok', 'secrets': len(secrets), 'disarmed': False, 'servicesStarted': False}


def restore(snapshot, destination, controller=None):
    private_parent(destination)
    schemas = supported_schemas(controller)
    if snapshot.is_dir() and not snapshot.is_symlink():
        try:
            manifest = json.loads((snapshot / MANIFEST_NAME).read_text())
        except (OSError, ValueError):
            raise ValueError('snapshot_manifest_unreadable') from None
        if manifest.get('format') != SNAPSHOT_FORMAT:
            raise ValueError('unsupported_snapshot_format')
        database = snapshot / DATABASE_NAME
        secrets = read_secrets(snapshot / SECRETS_NAME)
        if len(secrets) != manifest.get('secrets'):
            raise ValueError('snapshot_secrets_incomplete')
    else:
        database, secrets = snapshot, {}  # an older single-file snapshot: no secrets were captured
    secrets_destination = destination.parent / SECRETS_NAME
    if secrets and (secrets_destination.exists() or secrets_destination.is_symlink()):
        raise ValueError('secrets_destination_exists: move the existing secrets/ aside first')
    try:
        version = copy_database(database, destination, schemas, disarm=True)
        if secrets:
            write_secrets(secrets_destination, secrets)
    except BaseException:
        destination.unlink(missing_ok=True)
        if secrets:
            shutil.rmtree(secrets_destination, ignore_errors=True)
        raise
    return {'schema': version, 'integrity': 'ok', 'secrets': len(secrets), 'disarmed': True, 'servicesStarted': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('operation', choices=['capture', 'restore'])
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--controller', type=Path,
                        help=f'the {CONTROLLER_NAME} whose schemas to accept (default: the one beside this script)')
    args = parser.parse_args()
    operation = capture if args.operation == 'capture' else restore
    try:
        result = operation(args.source, args.destination, args.controller)
    except ValueError as error:
        print(f'host-state: {error}', file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
