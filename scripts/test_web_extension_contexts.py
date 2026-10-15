#!/usr/bin/env python3
"""Context coverage through the production helper and the examples users open in Threading."""
import argparse
import asyncio
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources/Threading/Resources/WebExtensions'))
from workbench import Workbench, stage, discover


class ContextContracts(unittest.TestCase):
    def test_public_hooks_do_not_expose_credentials_and_wildcards_exclude_private_hooks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            shutil.copytree(ROOT / 'Examples/WebExtensions/contexts', source)
            manifest = json.loads((source / 'manifest.json').read_text())
            manifest['web_accessible_resources'] = [dict(resources=['*'], matches=['<all_urls>'])]
            (source / 'manifest.json').write_text(json.dumps(manifest))
            output = root / 'output'
            stage(source, output, 'http://127.0.0.1:9999/private-route', 'private-token', 'chromium', root)
            for name in ['threading_main.js', 'threading_sandbox.js']:
                value = (output / name).read_text()
                self.assertNotIn('private-token', value)
                self.assertNotIn('private-route', value)
            staged = json.loads((output / 'manifest.json').read_text())
            resources = staged['web_accessible_resources'][0]['resources']
            self.assertIn('main.js', resources)
            self.assertFalse(any(Path(path).name.startswith('threading_') for path in resources))
            main = next(group for group in staged['content_scripts'] if group.get('world') == 'MAIN')
            self.assertEqual(main['js'], ['threading_main.js', 'main.js'])
            bridge = staged['content_scripts'][staged['content_scripts'].index(main) - 1]
            self.assertEqual(bridge['world'], 'ISOLATED')
            self.assertEqual(bridge['js'], ['threading_diagnostics.js'])
            self.assertEqual((source / 'main.js').read_bytes(), (output / 'main.js').read_bytes())
            self.assertIn('threading_options.js', (output / 'options.html').read_text())
            self.assertIn('threading_devtools.js', (output / 'devtools.html').read_text())

    def test_a_page_shared_by_several_surfaces_keeps_generic_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            (source / 'manifest.json').write_text(json.dumps(dict(manifest_version=3, name='Shared', version='1',
                action=dict(default_popup='shared.html'), options_ui=dict(page='shared.html'))))
            (source / 'shared.html').write_text('<!doctype html><head></head><body>Shared</body>')
            stage(source, root / 'output', 'http://127.0.0.1:9999/route', 'token', 'chromium', root)
            self.assertIn('threading_diagnostics.js', (root / 'output/shared.html').read_text())

    def test_event_assertions_cannot_pass_on_old_or_other_target_diagnostics(self):
        async def exercise():
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                worker = Workbench(root, root / 'state')
                try:
                    run = dict(target='target', build='build')
                    with self.assertRaisesRegex(ValueError, 'accepts'):
                        await worker.expect_event(run, {'payload': 'secret'}, 0)
                    worker.journal.add('target', dict(kind='console', context='background', message='expected', build='build'))
                    after = worker.journal.sequence
                    worker.journal.add('other', dict(kind='console', context='background', message='expected', build='build'))
                    worker.journal.add('target', dict(kind='console', context='background', message='expected', build='old'))
                    pending = asyncio.create_task(worker.expect_event(run, {'kind': 'console', 'message': 'expected'}, after))
                    await asyncio.sleep(0.15)
                    self.assertFalse(pending.done())
                    worker.journal.add('target', dict(kind='console', context='background', message='expected', build='build'))
                    await asyncio.wait_for(pending, 1)
                    # A test verdict has its own kind, so it cannot satisfy a later console assertion.
                    self.assertEqual(worker.journal.page()['events'][-1]['kind'], 'test')
                finally:
                    await worker.close()
        asyncio.run(exercise())


async def exercise_target(identity, headed):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        project = root / 'project'
        shutil.copytree(ROOT / 'Examples/WebExtensions', project)
        worker = Workbench(project, root / 'state')
        try:
            await asyncio.wait_for(worker.start(identity, headless=not headed), 120)
            result = await asyncio.wait_for(worker.test(identity), 150)
            if not result['passed']:
                raise AssertionError(result)
            with worker.journal.lock:
                events = list(worker.journal.events)
            if 'contexts' in identity:
                assert 'coverage-private-payload' not in json.dumps(events), 'A port/native-message payload leaked'
                children = [event for event in events if event['kind'] == 'console' and event['message'] == 'coverage-content-child']
                assert children and all(event['frame'] and event['tab'] is not None for event in children), 'Child-frame provenance was lost'
            await worker.stop(identity)
            print(f'PASS {identity}: {result["completed"]} declared page, diagnostic and lifecycle steps', flush=True)
        except Exception:
            print('DIAGNOSTICS', json.dumps(worker.journal.page(limit=200)['events'], indent=2), flush=True)
            raise
        finally:
            await worker.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--e2e', nargs='*')
    parser.add_argument('--headed', action='store_true')
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContextContracts)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        sys.exit(1)
    if args.e2e is not None:
        targets = [target['id'] for target in discover(ROOT / 'Examples/WebExtensions')]
        for identity in args.e2e or targets:
            if identity not in targets:
                parser.error('Unknown example target: ' + identity)
            asyncio.run(exercise_target(identity, args.headed))
