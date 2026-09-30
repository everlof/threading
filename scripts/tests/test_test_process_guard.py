"""Ownership policy tests plus isolated real macOS child cleanup (no Xcode required)."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
import uuid

MODULE = Path(__file__).resolve().parents[1] / 'test_process_guard.py'
spec = importlib.util.spec_from_file_location('guard', MODULE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def row(pid, parent=1, name='sleep', stamp=10, group=None):
    return dict(pid=pid, ppid=parent, pgid=pid if group is None else group,
                seconds=stamp, microseconds=23, name=name)


def procargs(argv, environment):
    return (len(argv).to_bytes(4, sys.byteorder, signed=True) + b'/fixture\0\0' +
            b'\0'.join(argv) + b'\0' + b'\0'.join(environment) + b'\0')


class Processes:
    def __init__(self, values, token=True):
        self.values = iter(values)
        self.token = token
        self.signals = []

    def info(self, pid):
        value = next(self.values)
        if isinstance(value, Exception):
            raise value
        return value

    def token_matches(self, pid, token):
        if isinstance(self.token, Exception):
            raise self.token
        return self.token

    def signal(self, record, number):
        self.signals.append((record, number))


class ProcessGuardTests(unittest.TestCase):
    def test_only_test_host_tree_belongs_to_run(self):
        root = row(10, name='xcodebuild')
        rows = [root, row(11, 10, 'ibtoold'), row(12, 11, 'worker'),
                row(20, 10, 'Threading'), row(21, 20, 'daemon'), row(22, 21),
                row(30, 1, 'Threading'), row(31, 30), row(40, 10, 'xctest')]
        self.assertEqual([r['pid'] for r in guard.owned_tree({r['pid']: r for r in rows}, root)],
                         [20, 21, 22, 40])

    def test_reused_root_cannot_adopt_a_new_tree(self):
        self.assertEqual(guard.owned_tree({10: row(10, stamp=11),
                                         20: row(20, 10, 'Threading')}, row(10)), [])

    def test_environment_token_is_exact_and_never_matched_in_argv(self):
        token = b'THREADING_TEST_RUN_TOKEN=one'
        self.assertTrue(guard.environment_contains_token(procargs([b'fixture'], [token]), 'one'))
        for argv, env in [([b'fixture', token], []), ([b'fixture'], [token + b'-other']),
                          ([b'fixture'], [b'PREFIX_' + token]),
                          ([b'fixture'], [b'OTHER=' + token])]:
            self.assertFalse(guard.environment_contains_token(procargs(argv, env), 'one'))
        with self.assertRaises(guard.GuardError):
            guard.environment_contains_token(b'bad', 'one')

    def test_reused_pid_and_unrelated_token_are_not_signalled(self):
        for process in [Processes([row(4, stamp=11)]), Processes([row(4)], token=False)]:
            result = guard.inspect_records(process, [row(4)], 'one', signal.SIGTERM)
            self.assertEqual(result, {'owned': [], 'errors': []})
            self.assertEqual(process.signals, [])

    def test_identity_and_token_lookup_failure_are_fail_closed(self):
        for process in [Processes([guard.GuardError('identity unavailable')]),
                        Processes([row(4)], token=guard.GuardError('token unavailable'))]:
            result = guard.inspect_records(process, [row(4)], 'one', signal.SIGTERM)
            self.assertEqual(result['owned'], [])
            self.assertTrue(result['errors'])
            self.assertEqual(process.signals, [])

    def test_incarnation_or_group_change_during_token_read_is_refused(self):
        for changed in [row(4, stamp=11), row(4, group=100), None]:
            process = Processes([row(4), changed])
            result = guard.inspect_records(process, [row(4)], 'one', signal.SIGKILL)
            self.assertEqual(result['owned'], [])
            self.assertEqual(process.signals, [])

    def test_escalation_rechecks_identity_and_leak_still_fails(self):
        original = row(4)
        process = Processes([original, original, original, original, row(4, stamp=11)])
        def inspect(request):
            return guard.inspect_records(process, request['records'], request['token'],
                                         request.get('signal'))
        self.assertTrue(guard.cleanup([original], 'one', interrupted=True,
                                      call=inspect, sleep=lambda _: None))
        self.assertEqual(process.signals, [(original, signal.SIGTERM)])

    def test_timed_out_lookup_fails_without_unverified_signals(self):
        requests = []
        def timeout(request):
            requests.append(request)
            raise guard.GuardError('inspection timed out')
        self.assertTrue(guard.cleanup([row(4)], 'one', call=timeout))
        self.assertEqual(len(requests), 1)
        self.assertNotIn('signal', requests[0])
        with patch.object(guard.os, 'fork', return_value=555), \
             patch.object(guard, 'wait_owned_child', return_value=None) as wait, \
             patch.object(guard.os, 'kill') as kill:
            with self.assertRaisesRegex(guard.GuardError, 'still exiting after SIGKILL'):
                guard.bounded_worker({'action': 'info', 'pid': 4}, timeout=.01)
        kill.assert_called_once_with(555, signal.SIGKILL)
        self.assertEqual([call.args for call in wait.call_args_list], [(555, .01), (555, .25)])

    def test_multithreaded_supervisor_refuses_to_fork(self):
        ready = threading.Event()
        thread = threading.Thread(target=lambda: ready.wait(5))
        thread.start()
        try:
            with patch.object(guard.os, 'fork') as fork:
                with self.assertRaisesRegex(guard.GuardError, 'single-threaded'):
                    guard.bounded_worker({'action': 'info', 'pid': os.getpid()})
            fork.assert_not_called()
        finally:
            ready.set()
            thread.join(timeout=2)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_fork_worker_uses_loaded_interpreter_and_resets_handlers(self):
        parent = os.getpid()
        with patch.object(guard.subprocess, 'Popen', side_effect=AssertionError('must not re-exec')):
            result = guard.bounded_worker({'action': 'info', 'pid': parent})
        self.assertEqual(result['pid'], parent)
        def inspect_worker(request):
            return {'pid': os.getpid(), 'parent': os.getppid(),
                    'term_default': signal.getsignal(signal.SIGTERM) == signal.SIG_DFL,
                    'int_default': signal.getsignal(signal.SIGINT) == signal.SIG_DFL}
        with patch.object(guard, 'worker', side_effect=inspect_worker):
            result = guard.bounded_worker({'action': 'fixture'})
        self.assertNotEqual(result['pid'], parent)
        self.assertEqual(result['parent'], parent)
        self.assertTrue(result['term_default'])
        self.assertTrue(result['int_default'])
        with self.assertRaises(ChildProcessError):
            os.waitpid(result['pid'], os.WNOHANG)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_fork_worker_timeout_is_bounded_and_reaped(self):
        with tempfile.TemporaryFile(mode='w+') as receipt:
            def stalled_worker(request):
                receipt.write(str(os.getpid()))
                receipt.flush()
                time.sleep(10)
            with patch.object(guard, 'worker', side_effect=stalled_worker):
                start = time.monotonic()
                with self.assertRaisesRegex(guard.GuardError, 'deadline.*worker stopped'):
                    guard.bounded_worker({'action': 'fixture'}, timeout=.1)
                self.assertLess(time.monotonic() - start, 1)
            receipt.seek(0)
            pid = int(receipt.read())
            with self.assertRaises(ChildProcessError):
                os.waitpid(pid, os.WNOHANG)

    def test_unreadable_descendant_fails_discovery(self):
        process = guard.DarwinProcesses.__new__(guard.DarwinProcesses)
        process.children_of = Mock(return_value=[100])
        process.info = Mock(side_effect=guard.GuardError('live metadata unavailable'))
        with self.assertRaisesRegex(guard.GuardError, 'live metadata unavailable'):
            process.snapshot(row(10))
        process.info = Mock(return_value=None)
        self.assertEqual(process.snapshot(row(10)), {10: row(10)})

    def test_child_enumeration_failure_and_capacity_are_refused(self):
        process = guard.DarwinProcesses.__new__(guard.DarwinProcesses)
        process.proc = Mock()
        for count in (-1, guard.MAX_RECORDS):
            process.proc.proc_listchildpids.return_value = count
            with self.assertRaisesRegex(guard.GuardError, 'complete child list'):
                process.children_of(10)

    def test_exec_and_reparent_do_not_change_captured_identity(self):
        root = row(10, name='xcodebuild')
        host = row(20, 10, 'Threading')
        changed = row(20, 1, 'sleep')
        for current, expected in [(changed, [changed]), (row(20, 1, 'sleep', stamp=11), [])]:
            process = Mock()
            process.info.side_effect = [root, root, current]
            process.snapshot.return_value = {10: root, 20: host}
            with patch.object(guard, 'DarwinProcesses', return_value=process):
                self.assertEqual(guard.worker({'action': 'capture', 'root': root}), expected)
        process = Processes([changed, changed])
        self.assertEqual(guard.verified_process(process, host, 'one'), changed)

    def test_failed_initial_lookup_stops_only_direct_child_and_does_not_retry(self):
        for interrupted in (False, True):
            child = Mock(pid=555)
            child.poll.return_value = None
            child.wait.return_value = -signal.SIGTERM
            handlers = {}
            def install(number, handler):
                handlers[number] = handler
            def fail_lookup(request):
                if interrupted:
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
                raise guard.GuardError('identity unavailable')
            with patch.dict(os.environ, THREADING_TEST_RUN_TOKEN='one'), \
                 patch.object(guard.signal, 'signal', side_effect=install), \
                 patch.object(guard.subprocess, 'Popen', return_value=child), \
                 patch.object(guard, 'bounded_worker', side_effect=fail_lookup) as lookup, \
                 patch.object(guard, 'cleanup', return_value=False):
                self.assertEqual(guard.supervise(['fixture'], '/unused'), 143 if interrupted else 1)
            self.assertEqual(lookup.call_count, 1)
            child.send_signal.assert_called_once_with(signal.SIGTERM)
            child.wait.assert_called_once_with(timeout=.5)

    def test_unexpected_inspection_or_ledger_error_stops_direct_child(self):
        for failure in ('inspection launch', 'ledger write'):
            child = Mock(pid=555)
            child.poll.return_value = None
            child.wait.return_value = -signal.SIGTERM
            lookup = Mock(side_effect=OSError('inspection launch failed')) if failure == 'inspection launch' else Mock(return_value=row(555))
            with patch.dict(os.environ, THREADING_TEST_RUN_TOKEN='one'), \
                 patch.object(guard.signal, 'signal'), \
                 patch.object(guard.subprocess, 'Popen', return_value=child), \
                 patch.object(guard, 'bounded_worker', lookup), \
                 patch.object(guard, 'cleanup', return_value=False), \
                 patch('builtins.open', side_effect=OSError('ledger write failed')):
                with self.assertRaisesRegex(OSError, failure):
                    guard.supervise(['fixture'], '/unused')
            child.send_signal.assert_called_once_with(signal.SIGTERM)
            child.wait.assert_called_once_with(timeout=.5)

    def test_direct_child_cleanup_never_waits_without_a_deadline(self):
        child = Mock(pid=555)
        child.poll.return_value = None
        child.wait.side_effect = subprocess.TimeoutExpired('fixture', .01)
        with patch('sys.stderr') as errors:
            guard.stop_direct_child(child)
        self.assertEqual([call.args[0] for call in child.send_signal.call_args_list],
                         [signal.SIGTERM, signal.SIGKILL])
        self.assertEqual([call.kwargs for call in child.wait.call_args_list],
                         [{'timeout': .5}, {'timeout': .25}])
        self.assertIn('cleanup incomplete', ''.join(str(c) for c in errors.write.call_args_list))

    def test_group_signal_requires_current_group_leader(self):
        process = guard.DarwinProcesses.__new__(guard.DarwinProcesses)
        with patch.object(guard.os, 'kill') as kill, patch.object(guard.os, 'killpg') as killpg:
            process.signal(row(4, group=100), signal.SIGTERM)
            kill.assert_called_once_with(4, signal.SIGTERM)
            killpg.assert_not_called()
        with patch.object(guard.os, 'kill') as kill, patch.object(guard.os, 'killpg') as killpg:
            process.signal(row(4), signal.SIGTERM)
            killpg.assert_called_once_with(4, signal.SIGTERM)
            kill.assert_not_called()

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_owned_group_cleanup_keeps_unrelated_child_alive(self):
        token = str(uuid.uuid4())
        environment = dict(os.environ, THREADING_TEST_RUN_TOKEN=token)
        owned = subprocess.Popen(['/bin/sleep', '30'], env=environment, start_new_session=True)
        unrelated = subprocess.Popen(['/bin/sleep', '30'],
                                     env=dict(os.environ, THREADING_TEST_RUN_TOKEN=token + '-other'),
                                     start_new_session=True)
        try:
            process = guard.DarwinProcesses()
            self.assertEqual(ctypes.sizeof(guard.BSDInfo), 136)
            owned_record = process.info(owned.pid)
            other_record = process.info(unrelated.pid)
            self.assertEqual(owned_record['pgid'], owned.pid)
            self.assertTrue(guard.cleanup([owned_record, other_record], token, interrupted=True))
            self.assertEqual(owned.wait(timeout=3), -signal.SIGTERM)
            self.assertIsNone(unrelated.poll())
        finally:
            for child in (owned, unrelated):
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=3)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_descendant_walk_never_reads_unrelated_sibling(self):
        parent = subprocess.Popen(['/bin/sh', '-c', 'sleep 30 & wait'], start_new_session=True)
        unrelated = subprocess.Popen(['/bin/sleep', '30'], start_new_session=True)
        try:
            process = guard.DarwinProcesses()
            root = process.info(parent.pid)
            original = process.info
            seen = []
            def observed_info(pid):
                seen.append(pid)
                return original(pid)
            process.info = observed_info
            deadline = time.monotonic() + 3
            while True:
                table = process.snapshot(root)
                if len(table) >= 2 or time.monotonic() >= deadline:
                    break
                time.sleep(.02)
            self.assertTrue(any(record['ppid'] == parent.pid for record in table.values()))
            self.assertNotIn(unrelated.pid, table)
            self.assertNotIn(unrelated.pid, seen)
        finally:
            for child in (parent, unrelated):
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=3)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_exec_and_reparent_preserve_owned_incarnation(self):
        token = str(uuid.uuid4())
        code = """import os, select, sys, time
pid = os.fork()
if pid == 0:
    if not select.select([sys.stdin], [], [], 5)[0]:
        os._exit(2)
    sys.stdin.readline()
    os.execl('/bin/sleep', 'sleep', '30')
print(pid, flush=True)
time.sleep(.5)
"""
        process = guard.DarwinProcesses()
        recorded = None
        with tempfile.TemporaryFile(mode='w+') as output:
            parent = subprocess.Popen([sys.executable, '-c', code], stdin=subprocess.PIPE,
                                      stdout=output, env=dict(os.environ, THREADING_TEST_RUN_TOKEN=token),
                                      start_new_session=True, text=True)
            try:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    output.seek(0)
                    text = output.read()
                    if text.endswith('\n'):
                        recorded = process.info(int(text.strip()))
                        break
                    time.sleep(.02)
                self.assertIsNotNone(recorded, 'fixture child was not observed')
                self.assertEqual(recorded['ppid'], parent.pid)
                self.assertEqual(parent.wait(timeout=3), 0)
                parent.stdin.write('exec\n')
                parent.stdin.flush()
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    current = process.info(recorded['pid'])
                    if current is not None and current['name'] == 'sleep' and current['ppid'] != parent.pid:
                        break
                    time.sleep(.02)
                self.assertEqual(current['name'], 'sleep')
                self.assertNotEqual(current['ppid'], parent.pid)
                self.assertEqual(guard.identity(current), guard.identity(recorded))
                self.assertEqual(guard.verified_process(process, recorded, token), current)
            finally:
                parent.stdin.close()
                if parent.poll() is None:
                    parent.terminate()
                    parent.wait(timeout=3)
                if recorded is not None:
                    guard.inspect_records(process, [recorded], token, signal.SIGKILL)
                    deadline = time.monotonic() + 3
                    while process.info(recorded['pid']) is not None and time.monotonic() < deadline:
                        time.sleep(.02)
                    self.assertIsNone(process.info(recorded['pid']), 'fixture child survived cleanup')

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_real_interrupt_stops_the_launched_command(self):
        environment = dict(os.environ, THREADING_TEST_RUN_TOKEN=str(uuid.uuid4()))
        with tempfile.TemporaryDirectory(prefix='threading-guard-interrupt-') as directory:
            ledger = Path(directory) / 'ledger'
            supervisor = subprocess.Popen([sys.executable, str(MODULE), str(ledger), '--',
                                           '/bin/sleep', '30'], env=environment,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            recorded = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if ledger.exists() and ledger.read_text().endswith('\n'):
                        recorded = json.loads(ledger.read_text().splitlines()[0])
                        break
                    time.sleep(.02)
                self.assertIsNotNone(recorded, 'supervisor did not record its child')
                supervisor.terminate()
                self.assertEqual(supervisor.wait(timeout=5), 143)
                self.assertIsNone(guard.DarwinProcesses().info(recorded['pid']))
            finally:
                if supervisor.poll() is None:
                    supervisor.terminate()
                    supervisor.wait(timeout=5)
                if recorded is not None:
                    guard.inspect_records(guard.DarwinProcesses(), [recorded],
                                          environment['THREADING_TEST_RUN_TOKEN'], signal.SIGKILL)

    @unittest.skipUnless(sys.platform == 'darwin', 'requires macOS process APIs')
    def test_supervisor_preserves_clean_child_exit_status(self):
        environment = dict(os.environ, THREADING_TEST_RUN_TOKEN=str(uuid.uuid4()))
        with tempfile.TemporaryDirectory(prefix='threading-guard-test-') as directory:
            for command, status in [('exit 0', 0), ('exit 7', 7), ('kill -TERM $$', 143)]:
                result = subprocess.run([sys.executable, str(MODULE), str(Path(directory) / 'ledger'),
                                         '--', '/bin/sh', '-c', f'sleep .3; {command}'],
                                        env=environment, timeout=10, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)


if __name__ == '__main__':
    unittest.main()
