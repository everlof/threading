#!/usr/bin/env python3
"""Bounded macOS XCTest process ownership guard; never enumerates global argv/env."""
from __future__ import annotations

import ctypes
import errno
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time

MAX_RECORDS = 4096
MAX_ARGUMENT_BYTES = 1024 * 1024
LOOKUP_TIMEOUT = 2.0
TOKEN_KEY = b'THREADING_TEST_RUN_TOKEN='
TEST_HOSTS = {'Threading', 'ThreadingTests', 'xctest'}


def diagnostic_stage(api, pid=None):
    if sys.argv[1:2] == ['_worker']:
        print(f'stage monotonic={time.monotonic():.6f} api={api} pid={pid}',
              file=sys.stderr, flush=True)


class GuardError(RuntimeError):
    pass


def identity(record):
    return record['pid'], record['seconds'], record['microseconds']


def descendants(table, roots):
    children = {}
    for row in table.values():
        children.setdefault(row['ppid'], []).append(row['pid'])
    found, pending = set(), list(roots)
    while pending:
        pid = pending.pop()
        if pid not in found:
            found.add(pid)
            pending.extend(children.get(pid, ()))
    return found


def owned_tree(table, root):
    current = table.get(root['pid'])
    if current is None or identity(current) != identity(root):
        return []
    under_root = descendants(table, [root['pid']])
    hosts = [pid for pid in under_root if table.get(pid, {}).get('name') in TEST_HOSTS]
    return [table[pid] for pid in sorted(descendants(table, hosts)) if pid in table]


def environment_contains_token(payload, token):
    """KERN_PROCARGS2: argc, executable, alignment nulls, exactly argc argv, environment."""
    if len(payload) < ctypes.sizeof(ctypes.c_int):
        raise GuardError('truncated process arguments')
    argc = int.from_bytes(payload[:4], sys.byteorder, signed=True)
    if argc < 1 or argc > MAX_ARGUMENT_BYTES:
        raise GuardError('invalid process argument count')
    end = payload.find(b'\0', 4)
    if end <= 4:
        raise GuardError('missing executable path')
    offset = end + 1
    while offset < len(payload) and payload[offset] == 0:
        offset += 1
    for _ in range(argc):
        end = payload.find(b'\0', offset)
        if end < 0:
            raise GuardError('truncated process argument vector')
        offset = end + 1
    return TOKEN_KEY + token.encode('ascii') in payload[offset:].split(b'\0')


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid',
                 'ruid', 'rgid', 'svuid', 'svgid', 'rfu1')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in
                ('nfiles', 'pgid', 'pjobc', 'e_tdev', 'e_tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64),
                 ('microseconds', ctypes.c_uint64)]


class DarwinProcesses:
    def __init__(self):
        if sys.platform != 'darwin':
            raise GuardError('the XCTest guard requires macOS libproc')
        diagnostic_stage('load_libproc')
        self.proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                          ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_pidinfo.restype = ctypes.c_int
        self.proc.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_listchildpids.restype = ctypes.c_int
        self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint,
                                    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t),
                                    ctypes.c_void_p, ctypes.c_size_t]
        self.libc.sysctl.restype = ctypes.c_int

    def info(self, pid):
        row = BSDInfo()
        size = ctypes.sizeof(row)
        ctypes.set_errno(0)
        diagnostic_stage('proc_pidinfo_full', pid)
        read = self.proc.proc_pidinfo(pid, 3, 0, ctypes.byref(row), size)  # PROC_PIDTBSDINFO
        if read != size:
            if ctypes.get_errno() == errno.ESRCH:
                return None
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return None
            except PermissionError:
                pass
            raise GuardError(f'cannot read process identity for pid {pid}')
        if row.status == 5:  # A zombie has no executable process left to signal.
            return None
        if row.pid != pid or row.seconds == 0:
            raise GuardError(f'invalid process identity for pid {pid}')
        return dict(pid=pid, ppid=row.ppid, pgid=row.pgid, seconds=row.seconds,
                    microseconds=row.microseconds,
                    name=bytes(row.comm).split(b'\0')[0].decode(errors='replace'))

    def children_of(self, pid):
        children = (ctypes.c_int * MAX_RECORDS)()
        ctypes.set_errno(0)
        diagnostic_stage('proc_listchildpids', pid)
        count = self.proc.proc_listchildpids(pid, children, ctypes.sizeof(children))
        error = ctypes.get_errno()
        if count < 0 or count >= len(children) or (count == 0 and error not in (0, errno.ESRCH)):
            raise GuardError(f'cannot enumerate complete child list for pid {pid}')
        return list(children[:count])

    def snapshot(self, root):
        # Walk only this command's tree. Querying every system process made an unrelated
        # protected/busy process part of the test deadline. Each discovered row carries its
        # full start identity immediately; mutable name/parent are not later identity checks.
        table = {root['pid']: root}
        pending = [root['pid']]
        while pending:
            parent = pending.pop()
            for pid in self.children_of(parent):
                if pid <= 0 or pid in table:
                    continue
                record = self.info(pid)
                if record is None:
                    continue
                if len(table) >= MAX_RECORDS:
                    raise GuardError('process descendant tree exceeded its bound')
                table[pid] = record
                pending.append(pid)
        return table

    def token_matches(self, pid, token):
        mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
        payload = ctypes.create_string_buffer(MAX_ARGUMENT_BYTES)
        size = ctypes.c_size_t(len(payload))
        ctypes.set_errno(0)
        diagnostic_stage('sysctl_procargs2', pid)
        if self.libc.sysctl(mib, 3, payload, ctypes.byref(size), None, 0) != 0:
            if ctypes.get_errno() == errno.ESRCH:
                return False
            raise GuardError(f'cannot verify process run token for pid {pid}')
        return environment_contains_token(payload.raw[:size.value], token)

    def signal(self, record, number):
        try:
            if record['pid'] == record['pgid']:
                os.killpg(record['pgid'], number)
            else:
                os.kill(record['pid'], number)
        except ProcessLookupError:
            pass


def verified_process(processes, recorded, token):
    current = processes.info(recorded['pid'])
    if current is None or identity(current) != identity(recorded):
        return None
    if not processes.token_matches(current['pid'], token):
        return None
    # Both incarnation and group are current at the decision, not from an old ledger snapshot.
    again = processes.info(current['pid'])
    if again is None or identity(again) != identity(current) or again['pgid'] != current['pgid']:
        return None
    return again


def inspect_records(processes, records, token, number=None):
    if len(records) > MAX_RECORDS:
        raise GuardError('process ledger exceeded its bound')
    owned, errors = [], []
    for record in records:
        try:
            current = verified_process(processes, record, token)
            if current is not None:
                owned.append(current)
                if number is not None:
                    processes.signal(current, number)
        except (GuardError, OSError) as error:
            errors.append(str(error))
    return {'owned': owned, 'errors': errors}


def worker(request):
    diagnostic_stage('action_' + request['action'], request.get('pid'))
    processes = DarwinProcesses()
    action = request['action']
    if action == 'info':
        return processes.info(request['pid'])
    if action == 'capture':
        root = request['root']
        current = processes.info(root['pid'])
        if current is None or identity(current) != identity(root):
            return []
        table = processes.snapshot(current)
        current = processes.info(root['pid'])
        if current is None or identity(current) != identity(root):
            return []
        if root['pid'] not in table:
            raise GuardError('live test root missing from process snapshot')
        table[root['pid']] = current
        records = []
        for candidate in owned_tree(table, root):
            record = processes.info(candidate['pid'])
            if record is not None:
                if identity(record) == identity(candidate):
                    records.append(record)
        return records
    return inspect_records(processes, request['records'], request['token'], request.get('signal'))


def wait_owned_child(pid, timeout):
    deadline = time.monotonic() + timeout
    while True:
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            return os.waitstatus_to_exitcode(status)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        time.sleep(min(.01, remaining))


def bounded_worker(request, timeout=LOOKUP_TIMEOUT):
    # This standalone, non-Cocoa supervisor is deliberately single-threaded. Forking its
    # loaded interpreter avoids re-exec startup stalls observed before the first worker
    # statement under host load. Never transplant this into the app or XCTest host.
    if threading.active_count() != 1:
        raise GuardError('process inspection requires a single-threaded supervisor')
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            os.dup2(errors.fileno(), 2)
            sys.argv = [sys.argv[0], '_worker']
            status = 1
            try:
                output.write(json.dumps(worker(request)).encode())
                output.flush()
                status = 0
            except BaseException as error:
                message = ('test process guard: ' + str(error))[-2048:]
                print(message, file=sys.stderr, flush=True)
            finally:
                # Do not run inherited atexit handlers or flush the supervisor's buffers.
                os._exit(status)
        status = wait_owned_child(child, timeout)
        if status is None:
            os.kill(child, signal.SIGKILL)
            status = wait_owned_child(child, .25)
            detail = 'worker stopped' if status is not None else f'worker pid {child} still exiting after SIGKILL'
            errors.seek(0, 2)
            errors.seek(max(0, errors.tell() - 1024))
            stages = errors.read(1024).decode(errors='replace').splitlines()
            stage = stages[-1] if stages else 'no worker stage reached (fork scheduling)'
            raise GuardError(f"process inspection exceeded its deadline; action={request['action']}; {detail}; {stage}")
        if status != 0:
            errors.seek(0, 2)
            errors.seek(max(0, errors.tell() - 2048))
            detail = errors.read(2048).decode(errors='replace').strip()
            raise GuardError('process inspection failed: ' + detail)
        output.seek(0)
        payload = output.read(2 * 1024 * 1024 + 1)
        if len(payload) > 2 * 1024 * 1024:
            raise GuardError('process inspection response exceeded its bound')
        try:
            return json.loads(payload)
        except (ValueError, TypeError) as error:
            raise GuardError('invalid process inspection response') from error


def cleanup(records, token, interrupted=False, call=bounded_worker, sleep=time.sleep):
    failed = False
    owned = []
    deadline = time.monotonic() + (0 if interrupted else 2)
    while True:
        try:
            result = call(dict(action='inspect', records=records, token=token))
            owned = result['owned']
            failed |= bool(result['errors'])
            if result['errors']:
                print('test process guard: ' + '; '.join(result['errors'][:3]), file=sys.stderr)
        except GuardError as error:
            print('test process guard: ' + str(error), file=sys.stderr)
            return True
        if not owned or time.monotonic() >= deadline:
            break
        sleep(.1)
    leaked = bool(owned)
    if leaked:
        print(f'test process guard found {len(owned)} run-owned processes after xcodebuild; reaping them',
              file=sys.stderr)
        for record in owned:
            print(f"  pid={record['pid']} pgid={record['pgid']} name={record['name']}", file=sys.stderr)
        for number in (signal.SIGTERM, signal.SIGKILL):
            try:
                # Re-read exact token/start/group before every signal, including escalation.
                result = call(dict(action='inspect', records=owned, token=token, signal=number))
                failed |= bool(result['errors'])
                if result['errors']:
                    print('test process guard: ' + '; '.join(result['errors'][:3]), file=sys.stderr)
            except GuardError as error:
                print('test process guard: ' + str(error), file=sys.stderr)
                failed = True
            if number == signal.SIGTERM:
                sleep(.5)
    return failed or leaked


def stop_direct_child(child):
    # Popen owns this unreaped child, so the PID cannot be reused under us. This is only
    # the launched command, never an inferred descendant or process group.
    if child.poll() is not None:
        return
    for number, timeout in ((signal.SIGTERM, .5), (signal.SIGKILL, .25)):
        child.send_signal(number)
        try:
            child.wait(timeout=timeout)
            return
        except subprocess.TimeoutExpired:
            pass
    print(f'test process guard: directly owned command pid {child.pid} still exiting; '
          'cleanup incomplete', file=sys.stderr)


def supervise(command, ledger):
    token = os.environ.get('THREADING_TEST_RUN_TOKEN', '')
    if not token or not token.isascii() or len(token) > 128:
        raise GuardError('missing or invalid test run token')
    interrupted = 0

    def interrupted_by(number, _frame):
        nonlocal interrupted
        interrupted = number

    signal.signal(signal.SIGTERM, interrupted_by)
    signal.signal(signal.SIGINT, interrupted_by)
    child = subprocess.Popen(command)
    records = {}
    failed = False
    root = None

    def remember(row):
        key = identity(row)
        if key not in records:
            if len(records) >= MAX_RECORDS:
                raise GuardError('test process ledger exceeded its bound')
            records[key] = row
            with open(ledger, 'a') as output:
                output.write(json.dumps(row) + '\n')

    try:
        while True:
            try:
                if root is None:
                    root = bounded_worker(dict(action='info', pid=child.pid))
                    if root is not None:
                        remember(root)
                if root is not None:
                    for row in bounded_worker(dict(action='capture', root=root)):
                        remember(row)
            except GuardError as error:
                failed = True
                print('test process guard: ' + str(error), file=sys.stderr)
                # A failed guard cannot certify the run. Abort without spawning replacement
                # inspection workers for the remainder of a long build.
                break
            if child.poll() is not None or interrupted:
                break
            time.sleep(.2)
    finally:
        if child.poll() is None:
            stop_direct_child(child)
        failed |= cleanup(list(records.values()), token, interrupted=bool(interrupted or failed))
    if interrupted:
        return 128 + interrupted
    if failed:
        return 1
    return child.returncode if child.returncode >= 0 else 128 - child.returncode


def main():
    if sys.argv[1:2] == ['_worker']:
        request = json.loads(sys.stdin.buffer.read(4 * 1024 * 1024))
        print(json.dumps(worker(request)))
        return 0
    if len(sys.argv) < 4 or sys.argv[2] != '--':
        raise GuardError('usage: test_process_guard.py LEDGER -- COMMAND [ARG ...]')
    return supervise(sys.argv[3:], sys.argv[1])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (GuardError, OSError, ValueError, KeyError) as error:
        print('test process guard: ' + str(error), file=sys.stderr)
        sys.exit(1)
