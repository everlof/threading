#!/usr/bin/env python3
"""Deterministic worker contracts; --e2e runs the shipping worker with real installed browsers."""
import argparse
import asyncio
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources/Threading/Resources/WebExtensions'))
from workbench import Journal, Workbench, contained, discover, error_message, stage
from project import scaffold, resolve_source
from chromium import Chromium


class Contracts(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        self.project = self.root / 'project'
        self.project.mkdir()

    def tearDown(self):
        self.scratch.cleanup()

    def test_starter_is_portable_and_never_overwrites_work(self):
        scaffold(self.project)
        targets = discover(self.project)
        self.assertEqual([x['browser'] for x in targets], ['chromium', 'chrome', 'firefox', 'safari'])
        config = self.project / '.threading/web-extensions.json'
        before = config.read_bytes()
        with self.assertRaises(ValueError):
            scaffold(self.project)
        self.assertEqual(config.read_bytes(), before)

    def test_staging_preserves_original_and_source_line_numbers(self):
        scaffold(self.project)
        source = self.project / 'web-extension'
        before = {x.name: x.read_bytes() for x in source.iterdir()}
        output = self.root / 'staged'
        build = stage(source, output, 'http://127.0.0.1:1234/events/token', 'token', 'chromium', self.project)
        self.assertEqual(len(build), 16)
        self.assertEqual(before, {x.name: x.read_bytes() for x in source.iterdir()})
        self.assertEqual((output / 'background.js').read_bytes(), before['background.js'])
        manifest = json.loads((output / 'manifest.json').read_bytes())
        self.assertEqual(manifest['background']['service_worker'], 'threading_worker.js')
        self.assertEqual(manifest['content_scripts'][0]['js'][0], 'threading_diagnostics.js')
        self.assertIn('http://127.0.0.1/*', manifest['host_permissions'])
        self.assertTrue((output / 'threading_reload.html').exists())

    def test_symlinks_and_escaping_sources_are_refused(self):
        scaffold(self.project)
        source = self.project / 'web-extension'
        (source / 'outside').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            stage(source, self.root / 'staged', '', '', 'chromium', self.project)
        with self.assertRaises(ValueError):
            contained(self.project, '../outside')

    def test_source_map_resolves_only_checkout_files(self):
        source = self.project / 'dist'
        source.mkdir()
        original = self.project / 'source.ts'
        original.write_text("throw Error('sample')")
        (source / 'main.js').write_text("throw Error('sample');\n//# sourceMappingURL=main.js.map")
        mapping = dict(version=3, sources=['../source.ts'], mappings='AAAA')
        (source / 'main.js.map').write_text(json.dumps(mapping))
        result = resolve_source(self.project, source, 'at run (chrome-extension://test/main.js:1:10)')
        self.assertEqual(result['path'], str(original.resolve()))
        self.assertTrue(result['mapped'])
        mapping['sources'] = ['../../secret']
        (source / 'main.js.map').write_text(json.dumps(mapping))
        self.assertFalse(resolve_source(self.project, source, 'chrome-extension://test/main.js:1:10')['mapped'])

    def test_journal_bounds_paging_and_redaction(self):
        journal = Journal()
        for i in range(5000):
            journal.budget = (0, 0)
            journal.add('chrome', dict(message=f'event {i} token=secret', level='error'))
        page = journal.page(limit=200)
        self.assertEqual(page['retained'], 2000)
        self.assertEqual(len(page['events']), 200)
        self.assertEqual(page['oldest'], 3001)
        self.assertNotIn('secret', json.dumps(page))
        next_page = journal.page(after=page['cursor'])
        self.assertEqual(next_page['events'][0]['id'], 3201)
        self.assertEqual(journal.page(query='missing')['events'], [])

    def test_invalid_rebuild_preserves_the_previous_development_copy(self):
        scaffold(self.project)
        source = self.project / 'web-extension'
        output = self.root / 'staged'
        stage(source, output, '', '', 'chromium', self.project)
        previous = (output / 'manifest.json').read_bytes()
        (source / 'threading_reload.html').write_text('user-owned file')
        with self.assertRaises(ValueError):
            stage(source, output, '', '', 'chromium', self.project)
        self.assertEqual((output / 'manifest.json').read_bytes(), previous)

    def test_unicode_event_pages_fit_the_transport_without_losing_the_cursor(self):
        journal = Journal()
        for _ in range(200):
            journal.add('chrome', dict(message='😀' * 4096, stack='😀' * 8192))
        page = journal.page(limit=200)
        self.assertLess(len(json.dumps(page)), 2 * 1024 * 1024 + 1024)
        self.assertLess(page['cursor'], 200)
        following = journal.page(after=page['cursor'])
        self.assertEqual(following['events'][0]['id'], page['cursor'] + 1)

    def test_empty_directory_fanout_is_bounded(self):
        scaffold(self.project)
        source = self.project / 'web-extension'
        for index in range(4100):
            (source / str(index)).mkdir()
        with self.assertRaisesRegex(ValueError, '4096 entries'):
            stage(source, self.root / 'staged', '', '', 'chromium', self.project)

    def test_chromium_and_firefox_receive_their_own_background_manifest(self):
        scaffold(self.project)
        for browser in ['chromium', 'firefox']:
            output = self.root / browser
            stage(self.project / 'web-extension', output, '', '', browser, self.project)
            background = json.loads((output / 'manifest.json').read_text())['background']
            self.assertEqual('service_worker' in background, browser == 'chromium')
            self.assertEqual('scripts' in background, browser == 'firefox')

    def test_discovery_completes_optional_fields_and_rejects_malformed_targets(self):
        config = self.project / '.threading/web-extensions.json'
        config.parent.mkdir()
        config.write_text(json.dumps(dict(version=1, targets=[dict(id='a', browser='chromium')])))
        # The panel decodes source as required; an omitted one is completed, never passed through.
        self.assertEqual(discover(self.project), [dict(id='a', browser='chromium', source='.', build=[])])
        for targets in ([5], [dict(id='a', browser='chromium', source=3)], [dict(id=4, browser='chromium')]):
            config.write_text(json.dumps(dict(version=1, targets=targets)))
            with self.assertRaises(ValueError):
                discover(self.project)
        config.write_text('[]')
        with self.assertRaisesRegex(ValueError, 'version: 1'):
            discover(self.project)

    def test_service_worker_in_a_folder_keeps_its_import_base(self):
        source = self.project / 'extension'
        (source / 'background').mkdir(parents=True)
        (source / 'background/main.js').write_text("importScripts('helper.js');")
        (source / 'background/helper.js').write_text('')
        for kind, expected in [(None, 'importScripts("../threading_background.js","./main.js");'),
                               ('module', 'import "../threading_background.js";\nimport "./main.js";')]:
            background = dict(service_worker='/background/main.js')
            if kind:
                background['type'] = kind
            (source / 'manifest.json').write_text(json.dumps(dict(manifest_version=3, name='x', version='1', background=background)))
            output = self.root / f'staged-{kind}'
            stage(source, output, '', '', 'chromium', self.project)
            manifest = json.loads((output / 'manifest.json').read_text())
            # importScripts('helper.js') in main.js resolves against the registered worker's URL.
            self.assertEqual(manifest['background']['service_worker'], 'background/threading_worker.js')
            self.assertEqual((output / 'background/threading_worker.js').read_text(), expected)
        (source / 'background/threading_worker.js').write_text('user-owned')
        with self.assertRaisesRegex(ValueError, 'reserved'):
            stage(source, self.root / 'staged-reserved', '', '', 'chromium', self.project)

    def test_source_lookup_skips_development_files_beside_originals(self):
        source = self.project / 'dist'
        (source / 'background').mkdir(parents=True)
        (source / 'background/main.js').write_text('run()')
        stack = ('at (chrome-extension://id/background/threading_worker.js:1:1)\n'
                 'at run (chrome-extension://id/background/main.js:1:4)')
        self.assertEqual(resolve_source(self.project, source, stack)['path'], str((source / 'background/main.js').resolve()))

    def test_a_cursor_from_an_earlier_worker_restarts_and_one_event_is_found_by_id(self):
        journal = Journal()
        for index in range(3):
            journal.add('chrome', dict(message=f'event {index}'))
        self.assertEqual([row['id'] for row in journal.page(after=1500)['events']], [1, 2, 3])
        self.assertEqual(journal.page(after=3)['events'], [])
        self.assertEqual(journal.find(2)['message'], 'event 1')
        self.assertIsNone(journal.find(2, target='firefox'))

    def test_error_replies_are_never_empty(self):
        self.assertIn('did not finish within 150 seconds', error_message(asyncio.TimeoutError(), 'start', 150))
        self.assertEqual(error_message(TimeoutError()), 'A browser or network step timed out.')
        self.assertEqual(error_message(KeyError('source')), "Missing required field 'source'.")
        self.assertEqual(error_message(ValueError()), 'ValueError without a message.')
        self.assertIn('Install Development Tools', error_message(ImportError('No module named selenium')))


class PipeContracts(unittest.IsolatedAsyncioTestCase):
    async def test_commands_name_missing_executables_and_overrun_deadlines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project').mkdir()
            worker = Workbench(root / 'project', root / 'state')
            try:
                with self.assertRaisesRegex(ValueError, 'was not found on PATH'):
                    await worker.command(['threading-missing-build-tool'], 'chrome')
                with self.assertRaisesRegex(ValueError, 'did not finish within 0.2 seconds'):
                    await worker.command([sys.executable, '-c', 'import time; time.sleep(30)'], 'chrome', timeout=0.2)
            finally:
                await worker.close()

    async def test_close_removes_its_generation_but_keeps_safari_packages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project').mkdir()
            package = root / 'session/Safari/safari'
            package.mkdir(parents=True)
            worker = Workbench(root / 'project', root / 'session/generation')
            (worker.state / 'safari/profile').mkdir(parents=True)
            await worker.close()
            self.assertFalse((root / 'session/generation').exists())
            self.assertTrue(package.exists())
            # A state directory that holds the checkout is never removed.
            misconfigured = Workbench(root / 'project', root)
            await misconfigured.close()
            self.assertTrue((root / 'project').exists())

    async def test_event_ids_carry_their_worker_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project').mkdir()
            worker = Workbench(root / 'project', root / 'state')
            try:
                worker.event('chrome', 'console', 'first')
                page = await worker.call(dict(action='events'))
                self.assertEqual(page['generation'], worker.generation)
                single = await worker.call(dict(action='events', event=1, generation=worker.generation))
                self.assertEqual([row['message'] for row in single['events']], ['first'])
                with self.assertRaisesRegex(ValueError, 'earlier development worker'):
                    await worker.call(dict(action='events', event=1, generation='earlier'))
                with self.assertRaisesRegex(ValueError, 'earlier development worker'):
                    await worker.call(dict(action='source', target='chrome', event=1, generation='earlier'))
            finally:
                await worker.close()

    async def test_page_script_exceptions_are_not_reported_as_extension_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'project').mkdir()
            worker = Workbench(root / 'project', root / 'state')
            try:
                run = dict(target='chrome', build='build', extension_id='abc')
                def thrown(url):
                    return {'exceptionDetails': {'text': 'Uncaught', 'url': url, 'lineNumber': 0, 'columnNumber': 4,
                                                 'exception': {'description': 'TypeError: boom'}}}
                worker.native_event(run, 'Runtime.exceptionThrown', thrown('https://example.test/site.js'))
                worker.native_event(run, 'Runtime.exceptionThrown', thrown('chrome-extension://abc/content.js'))
                rows = worker.journal.page()['events']
                self.assertEqual([(row['kind'], row['level']) for row in rows],
                                 [('page-exception', 'warning'), ('native-exception', 'error')])
                self.assertEqual(rows[1]['stack'], 'chrome-extension://abc/content.js:1:5')
            finally:
                await worker.close()

    async def test_collector_requires_live_target_route_and_revokes_it_on_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / 'project'
            project.mkdir()
            scaffold(project)
            worker = Workbench(project, root / 'state')
            try:
                await worker.start('safari', headless=True)
                endpoint = worker.runs['safari']['endpoint']
                def post(url):
                    request = urllib.request.Request(url, data=b'{"message":"collector-fixture","context":"background"}',
                                                     headers={'Content-Type': 'application/json'})
                    try:
                        with urllib.request.urlopen(request, timeout=3) as reply:
                            return reply.status
                    except urllib.error.HTTPError as error:
                        return error.code
                self.assertEqual(await asyncio.to_thread(post, endpoint + '-wrong'), 403)
                self.assertEqual(await asyncio.to_thread(post, endpoint), 204)
                self.assertEqual(worker.journal.page(query='collector-fixture')['events'][0]['target'], 'safari')
                await worker.stop('safari')
                self.assertEqual(await asyncio.to_thread(post, endpoint), 403)
            finally:
                await worker.close()

    async def test_protocol_descriptors_responses_errors_and_shutdown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'browser'
            binary.write_text('#!' + sys.executable + '\n' + '''import os,json
buffer=b''
while True:
 data=os.read(3,65536)
 if not data: break
 buffer+=data
 while b'\\0' in buffer:
  line,buffer=buffer.split(b'\\0',1)
  command=json.loads(line)
  response={'id':command['id'],'result':{'product':'Fixture/1'}}
  if command['method']=='Refuse': response={'id':command['id'],'error':{'message':'explicit refusal'}}
  os.write(4,json.dumps(response).encode()+b'\\0')
  if command['method']=='Browser.close': os._exit(0)
''')
            binary.chmod(0o755)
            for _ in range(3):
                browser = Chromium(binary, root / 'profile', True, lambda *_: None)
                try:
                    self.assertEqual((await browser.send('Browser.getVersion'))['product'], 'Fixture/1')
                    with self.assertRaisesRegex(ValueError, 'explicit refusal'):
                        await browser.send('Refuse')
                finally:
                    await browser.close()
                self.assertTrue(browser.closed)


async def browser_e2e(browser, headless=True):
    with tempfile.TemporaryDirectory(prefix='threading-extension-e2e-') as directory:
        root = Path(directory)
        project = root / 'project'
        project.mkdir()
        scaffold(project)
        background = project / 'web-extension/background.js'
        # The extension's own onMessage handler must never receive diagnostics traffic.
        background.write_text(background.read_text() + "\nconsole.error('e2e-background-error');\nsetTimeout(() => { throw new Error('e2e-unhandled'); }, 200);\n"
                              "api.runtime.onMessage.addListener(message => { if (message?.type !== 'hello') console.error('e2e-foreign-message'); });\n")
        content = project / 'web-extension/content.js'
        content.write_text(content.read_text() + "\nconsole.warn('e2e-content-warning');\napi.runtime.sendMessage('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', {token: 'e2e-private-payload'}).catch(() => {});\n")
        original = {x.name: x.read_bytes() for x in (project / 'web-extension').iterdir()}
        worker = Workbench(project, root / 'state')
        try:
            run = await asyncio.wait_for(worker.start(browser, headless=headless), 120)
            print(f'{browser}: started {run["status"]}', flush=True)
            result = await worker.test(browser)
            assert result['passed'], result
            deadline = asyncio.get_running_loop().time() + 10
            while asyncio.get_running_loop().time() < deadline:
                records = worker.journal.page(limit=200)['events']
                if all(any(message in row['message'] for row in records)
                       for message in ['e2e-background-error', 'e2e-content-warning', 'e2e-unhandled']) and any(row['kind'] == 'message-failed' for row in records) \
                        and any(row['context'] == 'extension-page' and 'Popup connected' in row['message'] for row in records):
                    break
                await asyncio.sleep(0.1)
            else:
                raise AssertionError('Missing cross-context error telemetry: ' + json.dumps(records))
            error = next(row for row in records if row['kind'] == 'console' and 'e2e-background-error' in row['message'])
            mapped = await worker.call(dict(action='source', target=browser, event=error['id']))
            assert Path(mapped['path']) == background.resolve(), mapped
            assert original == {x.name: x.read_bytes() for x in (project / 'web-extension').iterdir()}
            assert 'e2e-private-payload' not in json.dumps(records)
            assert not any('e2e-foreign-message' in row['message'] for row in records), 'Diagnostics reached the extension’s onMessage'
            assert any(row['context'] == 'content-script' and row['tab'] is not None for row in records), 'Relayed events lost their tab'
            internal = worker.runs[browser]
            if context := internal.get('context'):
                await context.evaluate(internal['test_page'], "chrome.storage.local.set({threadingE2E: 'retained'})")
            else:
                await asyncio.to_thread(internal['driver'].execute_script, "return browser.storage.local.set({threadingE2E: 'retained'})")
            before = run['build']
            background.write_text(background.read_text() + "\nconsole.info('e2e-after-reload');\n")
            reloaded = await asyncio.wait_for(worker.reload(browser), 30)
            assert reloaded['build'] != before
            assert (await worker.test(browser))['passed']
            if context := internal.get('context'):
                storage = await context.evaluate(internal['test_page'], "chrome.storage.local.get('threadingE2E')")
            else:
                storage = await asyncio.to_thread(internal['driver'].execute_script, "return browser.storage.local.get('threadingE2E')")
            assert storage['threadingE2E'] == 'retained', storage
            try:
                await worker.call(dict(action='source', target=browser, event=error['id']))
                raise AssertionError('Old-build source was opened against the new build')
            except ValueError as failure:
                assert 'older build' in str(failure)
            config_path = project / '.threading/web-extensions.json'
            config = json.loads(config_path.read_text())
            next(target for target in config['targets'] if target['id'] == browser)['build'] = [sys.executable, '-c', 'raise SystemExit(7)']
            config_path.write_text(json.dumps(config))
            try:
                await worker.reload(browser)
                raise AssertionError('Failed build was reported as a successful reload')
            except ValueError as failure:
                assert 'exited 7' in str(failure)
            assert worker.runs[browser]['build'] == reloaded['build']
            await worker.stop(browser)
            assert not worker.runs
            print(f'PASS {browser}: install, content/background/popup, message failures, exceptions, source, reload/storage, failed-build recovery, stop', flush=True)
        except Exception:
            print('DIAGNOSTICS', [(e['context'], e['kind'], e['message']) for e in worker.journal.page(limit=200)['events']], flush=True)
            raise
        finally:
            await worker.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--headed', action='store_true', help='Exercise the same visible-browser launch used by the panel')
    parser.add_argument('--e2e', nargs='*', choices=['chromium', 'chrome', 'firefox'])
    args = parser.parse_args()
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(test)
                               for test in (Contracts, PipeContracts)])
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        sys.exit(1)
    if args.e2e is not None:
        for browser in args.e2e or ['chromium', 'firefox']:
            asyncio.run(browser_e2e(browser, headless=not args.headed))
