#!/usr/bin/env python3
"""Session-owned WebExtension development worker. NDJSON stdin/stdout, loopback telemetry.

All filesystem, browser, compiler and source-map work lives outside the application process.
The original extension is never instrumented in place. No telemetry leaves this machine.
"""
import asyncio
import collections
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import secrets
import shutil
import signal
import socketserver
import sys
import threading
import time
import urllib.parse

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))
from project import scaffold, resolve_source
from instrumentation import instrument_pages

MAX_FILES = 4096
MAX_BYTES = 32 * 1024 * 1024
MAX_EVENTS = 2000
MAX_LINE = 65536
MINIMUM_PYTHON = (3, 9)
OPERATION_TIMEOUT = 150
SETUP_TIMEOUT = 330
BUILD_TIMEOUT = 120
SETUP_STEP_TIMEOUT = 150
WORKER_WRAPPER = 'threading_worker.js'
RESERVED_FILES = ('threading_reload.html', WORKER_WRAPPER, 'threading_diagnostics.js', 'threading_background.js')
BROWSERS = {
    'chromium': None,
    'chrome': '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    'edge': '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
    'brave': '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
    'vivaldi': '/Applications/Vivaldi.app/Contents/MacOS/Vivaldi',
    'opera': '/Applications/Opera.app/Contents/MacOS/Opera',
    'arc': '/Applications/Arc.app/Contents/MacOS/Arc',
    'firefox': '/Applications/Firefox.app/Contents/MacOS/firefox',
    'safari': '/Applications/Safari.app',
}


def contained(root, path):
    value = (root / path).resolve()
    if not value.is_relative_to(root.resolve()):
        raise ValueError('Extension paths must stay inside the project checkout.')
    return value


def read_json(path, limit=MAX_LINE):
    with open(path, 'rb') as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f'{path.name} exceeds {limit} bytes.')
    return json.loads(data)


def clean(value):
    value = str(value)[:8192]
    value = re.sub(r'(?i)((?:token|password|secret|authorization|api[_-]?key)[=:\s]+)[^\s&,"\']+', r'\1[redacted]', value)
    return re.sub(r'(https?://)[^/@\s]+:[^/@\s]+@', r'\1[redacted]@', value)


def error_message(error, action='', deadline=None):
    """A reply never carries an empty error. asyncio deadlines stringify to '' and a KeyError to
    its bare key, so both are named here rather than reaching the panel or an agent blank."""
    timed_out = isinstance(error, (TimeoutError, asyncio.TimeoutError))
    if timed_out and deadline is not None:
        return (f'The {action or "development"} operation did not finish within {deadline} seconds. '
                'Inspect the build log in the event list, then try again.')
    if isinstance(error, KeyError):
        return f'Missing required field {error}.'
    message = str(error)
    if isinstance(error, ImportError):
        message += '. Choose Project → Install Development Tools, or call the setup action.'
    if not message and timed_out:
        return 'A browser or network step timed out.'
    return message or f'{type(error).__name__} without a message.'


class Journal:
    def __init__(self):
        self.events = collections.deque(maxlen=MAX_EVENTS)
        self.sequence = 0
        self.lock = threading.Lock()
        self.dropped = 0
        self.evicted = 0
        self.budget = (time.monotonic(), 0)

    def add(self, target, event):
        if not isinstance(event, dict):
            return
        with self.lock:
            now = time.monotonic()
            start, count = self.budget
            if now - start >= 1:
                start, count = now, 0
            self.budget = (start, count + 1)
            if count >= 500:
                self.dropped += 1
                return
            self.sequence += 1
            row = {key: clean(event.get(key, '')) for key in
                   ('level', 'kind', 'message', 'stack', 'context', 'contextID', 'build', 'url')}
            for key in ('level', 'kind', 'context', 'contextID', 'build'):
                row[key] = row[key][:128]
            row['url'] = row['url'][:2048]
            row['message'] = row['message'][:4096]
            row.update(id=self.sequence, target=target, received=time.time(),
                       tab=event.get('tab') if isinstance(event.get('tab'), int) else None,
                       frame=event.get('frame') if isinstance(event.get('frame'), int) else None)
            if len(self.events) == MAX_EVENTS:
                self.evicted += 1
            self.events.append(row)

    def page(self, after=0, limit=100, query='', target=''):
        limit = max(1, min(limit, 200))
        query = query.casefold()
        with self.lock:
            # A cursor past this journal's sequence came from an earlier worker. Restart at
            # its first event instead of skipping everything up to the stale number.
            if after > self.sequence:
                after = 0
            rows, size = [], 0
            for row in self.events:
                if row['id'] <= after or (target and row['target'] != target):
                    continue
                if query and query not in '\n'.join(str(value) for value in row.values()).casefold():
                    continue
                encoded = json.dumps(row)
                # JSON escaping can expand a Unicode character to twelve ASCII bytes.
                # Bound the wire page as well as field lengths and the number of rows.
                if rows and size + len(encoded) > 2 * 1024 * 1024:
                    break
                rows.append(row)
                size += len(encoded)
                if len(rows) == limit:
                    break
            return dict(events=rows, cursor=rows[-1]['id'] if rows else self.sequence,
                        oldest=self.events[0]['id'] if self.events else 0,
                        dropped=self.dropped, evicted=self.evicted, retained=len(self.events))

    def find(self, identity, target=''):
        with self.lock:
            return next((dict(row) for row in self.events
                         if row['id'] == identity and (not target or row['target'] == target)), None)


class Collector(socketserver.ThreadingMixIn, http.server.HTTPServer):
    # Browsers preconnect idle sockets. A bounded pool keeps those sockets from
    # blocking the fixture or starving diagnostics from another extension context.
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, journal):
        self.routes = {}
        self.journal = journal
        self.readers = threading.BoundedSemaphore(16)
        super().__init__(('127.0.0.1', 0), CollectorRequest)
        self.timeout = 0.5

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(2)
        return connection, address

    def process_request(self, request, address):
        if not self.readers.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, address)

    def process_request_thread(self, request, address):
        try:
            try:
                self.finish_request(request, address)
            except (ConnectionError, TimeoutError):
                pass
            finally:
                self.shutdown_request(request)
        finally:
            self.readers.release()


class CollectorRequest(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path not in ('/fixture', '/fixture-frame'):
            self.send_error(404)
            return
        frame = b'<iframe title="Extension test frame" src="/fixture-frame"></iframe>' if self.path == '/fixture' else b''
        data = b'<!doctype html><title>Extension test page</title><body><h1>Extension test page</h1>' + frame + b'</body>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        route = self.server.routes.get(self.path)
        if route is None:
            self.send_error(403)
            return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= MAX_LINE:
                raise ValueError('Invalid event length')
            event = json.loads(self.rfile.read(size))
            self.server.journal.add(route, event)
            self.send_response(204)
            self.end_headers()
        except (ValueError, OSError):
            self.send_error(400)


def discover(project):
    config = project / '.threading/web-extensions.json'
    if config.exists():
        value = read_json(config)
        if not isinstance(value, dict) or value.get('version') != 1 or not isinstance(value.get('targets'), list):
            raise ValueError('web-extensions.json requires version: 1 and targets: [].')
        targets = value['targets']
    else:
        targets = []
        for browser, paths in [('chromium', ['.output/chrome-mv3', 'dist/chrome', 'dist', '.']),
                               ('firefox', ['.output/firefox-mv3', '.output/firefox-mv2', 'dist/firefox', 'dist', '.']),
                               ('safari', ['.output/safari-mv3', '.output/safari-mv2', 'dist/safari', 'dist', '.'])]:
            for path in paths:
                if (contained(project, path) / 'manifest.json').is_file():
                    targets.append(dict(id=browser, browser=browser, source=path, build=[]))
                    break
    if len(targets) > 16:
        raise ValueError('At most 16 development targets may be declared.')
    seen = set()
    normalized = []
    for target in targets:
        if not isinstance(target, dict):
            raise ValueError('Each target must be an object: {id, browser, source, build}.')
        identity = target.get('id', '')
        if not isinstance(identity, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,48}', identity) or identity in seen:
            raise ValueError('Target IDs must be unique, 1–48 letters, digits, underscores or hyphens.')
        seen.add(identity)
        source = target.get('source', '.')
        if not isinstance(source, str) or not source:
            raise ValueError(f'source in target {identity} must be the built extension directory, relative to the checkout.')
        contained(project, source)
        command = target.get('build', [])
        if not isinstance(command, list) or len(command) > 32 or any(not isinstance(x, str) or len(x) > 4096 for x in command):
            raise ValueError('build must be an argv array of at most 32 strings; no shell expansion.')
        browser = target.get('browser')
        if not isinstance(browser, str) or browser not in {*BROWSERS, 'firefox-android', 'safari-ios', 'manual'}:
            raise ValueError(f'Unknown browser in target {identity}.')
        # Every consumer — the panel, an agent and start/reload — reads the same complete record,
        # so an omitted optional field cannot be valid here and missing later.
        normalized.append(dict(target, source=source, build=command))
    return normalized


def stage(source, destination, endpoint, token, target, project):
    manifest = read_json(source / 'manifest.json')
    if manifest.get('manifest_version') not in (2, 3):
        raise ValueError('Only WebExtension Manifest V2 and V3 are supported.')
    pending = destination.with_name(destination.name + '-pending')
    if pending.exists():
        shutil.rmtree(pending)
    pending.mkdir(parents=True)
    count, size = 0, 0
    digest = hashlib.sha256()
    try:
        directories = [source]
        while directories:
            parent = directories.pop()
            entries = []
            with os.scandir(parent) as scan:
                for entry in scan:
                    if entry.name in {'.git', 'node_modules', '.threading', '.build'}:
                        continue
                    count += 1
                    if count > MAX_FILES:
                        raise ValueError('Extension exceeds 4096 entries. Select the built extension directory.')
                    if entry.is_symlink():
                        raise ValueError('Development bundles must not contain symbolic links.')
                    entries.append(entry)
            for entry in sorted(entries, key=lambda entry: entry.name):
                path = Path(entry.path)
                if entry.is_dir():
                    directories.append(path)
                    continue
                if not entry.is_file():
                    raise ValueError('Development bundles may only contain ordinary files and directories.')
                if entry.stat().st_size > MAX_BYTES - size:
                    raise ValueError('Extension exceeds 32 MiB. Select the built extension directory.')
                relative = path.relative_to(source)
                with path.open('rb') as stream:
                    data = stream.read(MAX_BYTES - size + 1)
                size += len(data)
                if size > MAX_BYTES:
                    raise ValueError('A source file grew beyond the bundle budget during staging.')
                digest.update(str(relative).encode() + b'\0' + data)
                output = pending / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(data)
        build = digest.hexdigest()[:16]
        if any((pending / name).exists() for name in RESERVED_FILES):
            raise ValueError('The extension uses a reserved threading_ development filename.')
        (pending / 'threading_reload.html').write_text('<!doctype html><title>Reload extension</title>')
        permission_key = 'host_permissions' if manifest['manifest_version'] == 3 else 'permissions'
        manifest.setdefault(permission_key, [])
        if 'http://127.0.0.1/*' not in manifest[permission_key]:
            manifest[permission_key].append('http://127.0.0.1/*')
        background = manifest.setdefault('background', {})
        if background.get('service_worker'):
            if not isinstance(background['service_worker'], str):
                raise ValueError('background.service_worker must be a path.')
            original = posixpath.normpath(background['service_worker'].lstrip('/'))
            contained(pending, original)
            # importScripts() and self.location resolve against the registered worker's own URL.
            # The wrapper therefore sits beside the original, so a classic worker in a folder keeps
            # the base its relative imports were written against.
            folder = posixpath.dirname(original)
            wrapper = posixpath.join(folder, WORKER_WRAPPER)
            if (pending / wrapper).exists():
                raise ValueError('The extension uses a reserved threading_ development filename.')
            diagnostics = posixpath.relpath('threading_background.js', folder or '.')
            imports = [diagnostics if diagnostics.startswith('.') else './' + diagnostics, './' + posixpath.basename(original)]
            code = '\n'.join('import ' + json.dumps(x) + ';' for x in imports) if background.get('type') == 'module' else 'importScripts(' + ','.join(map(json.dumps, imports)) + ');'
            (pending / wrapper).write_text(code)
            background['service_worker'] = wrapper
        if background.get('scripts') is not None:
            background['scripts'].insert(0, 'threading_background.js')
        if not any(background.get(key) for key in ('scripts', 'service_worker', 'page')):
            if manifest['manifest_version'] == 3 and target not in ('firefox', 'firefox-android'):
                background['service_worker'] = 'threading_background.js'
            else:
                background['scripts'] = ['threading_background.js']
        if target in ('firefox', 'firefox-android'):
            settings = manifest.setdefault('browser_specific_settings', {}).setdefault('gecko', {})
            settings.setdefault('id', hashlib.sha256(str(source).encode()).hexdigest()[:16] + '@threading.local')
            if background.get('service_worker') and not background.get('scripts'):
                original_background = read_json(source / 'manifest.json').get('background', {})
                background['scripts'] = ['threading_background.js', original_background['service_worker']]
            background.pop('service_worker', None)
        elif target in BROWSERS and target != 'safari' and background.get('service_worker'):
            background.pop('scripts', None)
        instrument_pages(pending, manifest, endpoint, token, build)
        encoded_manifest = json.dumps(manifest, indent=2)
        if len(encoded_manifest.encode()) > MAX_LINE:
            raise ValueError('The instrumented manifest exceeds 64 KiB; narrow web-accessible resource patterns.')
        (pending / 'manifest.json').write_text(encoded_manifest)
        previous = destination.with_name(destination.name + '-previous')
        shutil.rmtree(previous, ignore_errors=True)
        if destination.exists():
            destination.rename(previous)
        try:
            pending.rename(destination)
        except Exception:
            if previous.exists():
                previous.rename(destination)
            raise
        shutil.rmtree(previous, ignore_errors=True)
        return build
    except Exception:
        shutil.rmtree(pending, ignore_errors=True)
        raise


class Workbench:
    def __init__(self, project, state):
        self.project, self.state = project.resolve(), state.resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        # Compiled dependencies (Playwright's greenlet) are built per interpreter version, and
        # the host may find a different Python on another machine or after an upgrade.
        self.packages = (Path.home() / 'Library/Caches/Threading/WebExtensionTools/python' /
                         f'{sys.version_info.major}.{sys.version_info.minor}')
        sys.path.insert(0, str(self.packages))
        # Event IDs restart with every worker. The generation tells a reader that a cursor or an
        # event ID it holds was issued by an earlier worker.
        self.generation = secrets.token_hex(8)
        self.journal = Journal()
        self.collector = Collector(self.journal)
        self.thread = threading.Thread(target=self.collector.serve_forever, daemon=True)
        self.thread.start()
        self.runs = {}

    def event(self, target, kind, message, level='info', **fields):
        self.journal.add(target, dict(kind=kind, message=message, level=level, context='host', **fields))

    def command_environment(self):
        return dict(os.environ, PYTHONPATH=str(self.packages),
                    PATH=os.environ.get('PATH', '') + ':/opt/homebrew/bin:/usr/local/bin')

    async def command(self, argv, target, cwd=None, timeout=BUILD_TIMEOUT):
        environment = self.command_environment()
        try:
            process = await asyncio.create_subprocess_exec(*argv, cwd=cwd or self.project, env=environment,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT, start_new_session=True)
        except FileNotFoundError:
            raise ValueError(f'{argv[0]} was not found on PATH ({environment["PATH"]}). Install it, or name '
                             'its absolute path in the target build.') from None
        async def drain():
            total = 0
            while data := await process.stdout.read(4096):
                total += len(data)
                if total <= 1024 * 1024:
                    self.event(target, 'build', data.decode(errors='replace'))
            return await process.wait()
        try:
            try:
                result = await asyncio.wait_for(drain(), timeout)
            except (TimeoutError, asyncio.TimeoutError):
                raise ValueError(f'{Path(argv[0]).name} did not finish within {timeout} seconds and was stopped; '
                                 'inspect the build log.') from None
            if result:
                raise ValueError(f'Command exited {result}; inspect the build log.')
        finally:
            if process.returncode is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(process.wait(), 2)
                except asyncio.TimeoutError:
                    os.killpg(process.pid, signal.SIGKILL)
                    await process.wait()

    async def start(self, identity, headless=False):
        targets = discover(self.project)
        config = next((x for x in targets if x['id'] == identity), None)
        if config is None:
            raise ValueError('Unknown target; inspect the project first.')
        if identity in self.runs:
            return await self.reload(identity)
        if len(self.runs) >= 3:
            raise ValueError('Stop a target before starting another (three live targets maximum).')
        if config.get('build'):
            await self.command(config['build'], identity)
        token = secrets.token_urlsafe(32)
        route = '/events/' + token
        endpoint = f'http://127.0.0.1:{self.collector.server_port}{route}'
        directory = self.state / identity / 'extension'
        source = contained(self.project, config['source'])
        build = await asyncio.to_thread(stage, source, directory, endpoint, token, config['browser'], self.project)
        self.collector.routes[route] = identity
        run = dict(target=identity, browser=config['browser'], source=str(source), directory=str(directory),
                   build=build, status='starting', route=route, endpoint=endpoint, token=token, config=config, headless=headless)
        self.runs[identity] = run
        try:
            await self.launch(run, headless)
            self.event(identity, 'lifecycle', 'Development build loaded: ' + build, build=build)
            return self.public_run(run)
        except BaseException:
            log = self.state / identity / 'firefox-driver.log'
            if log.is_file():
                with log.open('rb') as stream:
                    stream.seek(max(0, log.stat().st_size - 8192))
                    self.event(identity, 'browser', stream.read(8192).decode(errors='replace'), 'error')
            await self.stop(identity)
            raise

    async def launch(self, run, headless):
        browser, identity = run['browser'], run['target']
        profile = str(self.state / identity / 'profile')
        if browser in BROWSERS and browser not in ('safari', 'firefox'):
            from chromium import Chromium
            binary = BROWSERS[browser]
            if binary is None:
                from playwright.async_api import async_playwright
                async with async_playwright() as runtime:
                    binary = runtime.chromium.executable_path
            context = Chromium(binary, profile, headless, lambda method, fields: self.native_event(run, method, fields))
            run['context'] = context
            version = await context.send('Browser.getVersion', timeout=90)
            run['browser_version'] = version['product']
            installed = await context.send('Extensions.loadUnpacked', {'path': run['directory']})
            run['extension_id'] = installed['id']
            run['page'] = await context.new_page(run['config'].get('url') or f'http://127.0.0.1:{self.collector.server_port}/fixture')
            run['status'] = 'running'
        elif browser == 'firefox':
            from selenium import webdriver
            from selenium.webdriver.firefox.service import Service
            options = webdriver.FirefoxOptions()
            options.binary_location = BROWSERS['firefox']
            if headless:
                options.add_argument('-headless')
            # Firefox's extension pages require the documented browser-UI context.
            # This driver owns a fresh development profile, never a personal browser.
            service = Service(log_output=str(self.state / identity / 'firefox-driver.log'), service_args=['--allow-system-access'])
            run['driver_service'] = service
            driver = await asyncio.to_thread(webdriver.Firefox, options=options, service=service)
            run['driver'] = driver
            run['browser_version'] = 'Firefox/' + driver.capabilities['browserVersion']
            run['primary_window'] = driver.current_window_handle
            driver.set_page_load_timeout(20)
            run['extension_id'] = await asyncio.to_thread(driver.install_addon, run['directory'], temporary=True)
            run['status'] = 'running'
            await asyncio.to_thread(driver.get, run['config'].get('url') or f'http://127.0.0.1:{self.collector.server_port}/fixture')
        elif browser == 'firefox-android':
            device = run['config'].get('device')
            if not device:
                raise ValueError('Set device to an exact adb serial in this target.')
            await self.command(['adb', '-s', device, 'reverse', f'tcp:{self.collector.server_port}', f'tcp:{self.collector.server_port}'], identity)
            run['adb_device'] = device
            run['child'] = await asyncio.create_subprocess_exec('web-ext', 'run', '--target', 'firefox-android',
                '--adb-device', device, '--firefox-apk', run['config'].get('application', 'org.mozilla.firefox'),
                '--source-dir', run['directory'], '--no-reload', stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                env=self.command_environment(), start_new_session=True)
            run['child_log'] = asyncio.create_task(self.child_log(run, run['child']))
            run['status'] = 'awaiting-connection'
            run['instructions'] = 'Accept the debugging connection on the selected Android test device.'
        else:
            run['status'] = 'awaiting-installation'
            run['instructions'] = ('Safari → Settings → Developer → Add Temporary Extension: select ' + run['directory'] +
                '. Enable the extension and grant access to the test site. On older Safari or iOS, use Package Safari.'
                if browser.startswith('safari') else 'Load unpacked in the target browser: ' + run['directory'])
            if browser == 'safari' and not headless:
                await self.command(['/usr/bin/open', '-a', 'Safari'], identity)

    async def child_log(self, run, child):
        while chunk := await child.stdout.read(4096):
            self.event(run['target'], 'browser', chunk.decode(errors='replace'))
        code = await child.wait()
        run['status'] = 'stopped'
        self.event(run['target'], 'lifecycle', f'Browser launcher exited {code}', 'warning' if code else 'info')

    def native_event(self, run, method, fields):
        details = fields.get('exceptionDetails') or {}
        message = details.get('exception', {}).get('description') or details.get('text') or method
        frames = details.get('stackTrace', {}).get('callFrames', [])[:40]
        stack = '\n'.join(f"at {f.get('functionName', '')} ({f.get('url', '')}:{f.get('lineNumber', 0) + 1}:{f.get('columnNumber', 0) + 1})" for f in frames)
        url = details.get('url', '')
        if not stack and url:
            stack = f"{url}:{details.get('lineNumber', 0) + 1}:{details.get('columnNumber', 0) + 1}"
        # The protocol reports every exception on an attached page, including the website's own
        # scripts. Only a throw whose code came from this extension is the extension's error.
        origin = 'chrome-extension://' + run.get('extension_id', '')
        if origin in stack or url.startswith(origin):
            kind, level = 'native-exception', 'error'
        else:
            kind, level = 'page-exception', 'warning'
        self.event(run['target'], kind, message, level, stack=stack, url=url, build=run['build'])

    async def reload(self, identity):
        run = self.runs.get(identity)
        if run is None:
            raise ValueError('Start the target before reloading it.')
        config = next((target for target in discover(self.project) if target['id'] == identity), None)
        if not config or config['browser'] != run['browser']:
            raise ValueError('The running target was removed or changed browser. Stop it before starting the new configuration.')
        if config.get('build'):
            await self.command(config['build'], identity)
        source = contained(self.project, config['source'])
        build = await asyncio.to_thread(stage, source, Path(run['directory']), run['endpoint'], run['token'], run['browser'], self.project)
        run.update(build=build, source=str(source), config=config)
        after = self.journal.sequence
        if context := run.get('context'):
            installed = await context.send('Extensions.loadUnpacked', {'path': run['directory']})
            run['extension_id'] = installed['id']
            run.pop('test_page', None)
            await self.wait_for_background(run, after)
        elif driver := run.get('driver'):
            await asyncio.to_thread(driver.switch_to.window, run['primary_window'])
            await asyncio.to_thread(driver.install_addon, run['directory'], temporary=True)
        elif run.get('child'):
            await self.stop_android(run)
            await self.launch(run, False)
        else:
            run['instructions'] = 'Click Reload for this temporary extension in Safari Settings, or rebuild the Safari package.'
        self.event(identity, 'reload', 'Rebuilt extension: ' + build, build=build)
        return self.public_run(run)

    async def wait_for_background(self, run, after):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            with self.journal.lock:
                ready = any(e['id'] > after and e['target'] == run['target'] and e['build'] == run['build']
                            and e['kind'] == 'connected' and e['context'] == 'background' for e in self.journal.events)
            if ready:
                return
            await asyncio.sleep(0.05)
        raise ValueError('Background diagnostics did not reconnect after reload. Open the browser debugger to inspect startup or CSP errors.')

    async def stop(self, identity):
        run = self.runs.pop(identity, None)
        if not run:
            return dict(stopped=True)
        self.collector.routes.pop(run['route'], None)
        if context := run.get('context'):
            await context.close()
        if driver := run.get('driver'):
            await asyncio.to_thread(driver.quit)
        if service := run.get('driver_service'):
            await asyncio.to_thread(service.stop)
        await self.stop_android(run)
        self.event(identity, 'lifecycle', 'Development session stopped')
        return dict(stopped=True)

    async def stop_android(self, run):
        if child := run.pop('child', None):
            if child.returncode is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(child.wait(), 3)
                except asyncio.TimeoutError:
                    os.killpg(child.pid, signal.SIGKILL)
                    await child.wait()
            if log := run.pop('child_log', None):
                await log
        if device := run.pop('adb_device', None):
            await self.command(['adb', '-s', device, 'reverse', '--remove', f'tcp:{self.collector.server_port}'], run['target'])

    def public_run(self, run):
        result = {key: run[key] for key in ('target', 'browser', 'source', 'directory', 'build', 'status', 'instructions', 'extension_id', 'browser_version') if key in run}
        with self.journal.lock:
            contexts = sorted({e['context'] for e in self.journal.events if e['target'] == run['target']
                               and e['build'] == run['build'] and e['context'] != 'host'})
        if run.get('context') and run['context'].closed:
            result['status'] = 'disconnected'
        result['contexts'] = contexts
        if contexts and result['status'] in ('running', 'awaiting-installation', 'awaiting-connection'):
            result['status'] = 'connected'
        return result

    def extension_url(self, run, page):
        manifest = read_json(Path(run['directory']) / 'manifest.json')
        paths = {
            'popup': (manifest.get('action') or manifest.get('browser_action') or {}).get('default_popup'),
            'options': manifest.get('options_ui', {}).get('page') or manifest.get('options_page'),
            'side-panel': manifest.get('side_panel', {}).get('default_path') or manifest.get('sidebar_action', {}).get('default_panel'),
            'new-tab': manifest.get('chrome_url_overrides', {}).get('newtab'),
        }
        relative = paths.get(page)
        if not relative:
            raise ValueError('The manifest has no ' + page + ' page.')
        contained(Path(run['directory']), relative)
        if run.get('context'):
            origin = 'chrome-extension://' + run['extension_id']
        else:
            with self.journal.lock:
                origins = [urllib.parse.urlsplit(e['url']) for e in self.journal.events
                           if e['target'] == run['target'] and e['url'].startswith('moz-extension://')]
            if not origins:
                raise ValueError('The Firefox background has not connected yet; its extension URL is unknown.')
            origin = 'moz-extension://' + origins[-1].netloc
        return origin + '/' + relative.lstrip('/')

    async def open_page(self, identity, page):
        run = self.runs.get(identity)
        if not run:
            raise ValueError('Start this target first.')
        if page == 'debug':
            url = 'chrome://extensions/?id=' + run['extension_id'] if run.get('context') else 'about:debugging#/runtime/this-firefox'
        else:
            url = self.extension_url(run, page)
        if context := run.get('context'):
            tab = await context.new_page(url)
            await context.send('Target.activateTarget', dict(targetId=tab))
        elif driver := run.get('driver'):
            await asyncio.to_thread(driver.switch_to.new_window, 'tab')
            await asyncio.to_thread(self.firefox_navigate, driver, url)
        else:
            raise ValueError('Open this extension in the target browser’s developer tools. Safari: Develop → Web Extension Background Pages.')
        return dict(instructions='Browser developer view opened. Extension-page tabs exercise the page content; toolbar popup dismissal and permission prompts need a browser UI check.')

    async def test(self, identity):
        run = self.runs.get(identity)
        if not run:
            raise ValueError('Start a target before running its tests.')
        steps = run['config'].get('tests', [])
        if not isinstance(steps, list) or not 1 <= len(steps) <= 50:
            raise ValueError('Declare 1–50 tests in the target: {url, selector, text}, optionally click or fill.')
        if not run.get('context') and not run.get('driver'):
            raise ValueError('Automated page steps are unavailable for this target. Validate in the real browser; its diagnostics remain live.')
        started = self.journal.sequence
        completed = 0
        page = run.get('page')
        try:
            for step in steps:
                if not isinstance(step, dict):
                    raise ValueError('Each test step must be an object.')
                if lifecycle := step.get('lifecycle'):
                    started = self.journal.sequence
                    if lifecycle == 'reload':
                        await self.reload(identity)
                    elif lifecycle == 'restart':
                        headless = run['headless']
                        await self.stop(identity)
                        await self.start(identity, headless)
                    elif lifecycle == 'stop-worker':
                        if not run.get('context'):
                            raise ValueError('stop-worker requires a Chromium target; Firefox background suspension needs native inspection.')
                        context = run['context']
                        # Stop workers in this owned profile without attaching a debugger or
                        # leaving ServiceWorker.enable active, which changes worker lifetime.
                        session = await context.attach(run['page'])
                        await context.send('ServiceWorker.enable', session=session)
                        try:
                            await context.send('ServiceWorker.stopAllWorkers', session=session)
                        finally:
                            await context.send('ServiceWorker.disable', session=session)
                        self.event(identity, 'lifecycle', 'Stopped service workers in the development profile', build=run['build'])
                    else:
                        raise ValueError('Unknown test lifecycle: ' + str(lifecycle))
                    run = self.runs[identity]
                    page = run.get('page')
                    completed += 1
                    continue
                if expectation := step.get('event'):
                    await self.expect_event(run, expectation, started)
                    completed += 1
                    continue
                url = step.get('url')
                if url == 'fixture':
                    url = f'http://127.0.0.1:{self.collector.server_port}/fixture'
                if url and urllib.parse.urlparse(url).scheme not in ('http', 'https'):
                    raise ValueError('Test URLs must use http or https.')
                if step.get('page'):
                    url = self.extension_url(run, step['page'])
                selector = step.get('selector')
                if not isinstance(selector, str) or not 1 <= len(selector) <= 2048:
                    raise ValueError('Every step needs a bounded CSS selector.')
                if context := run.get('context'):
                    if step.get('page'):
                        if not run.get('test_page'):
                            run['test_page'] = await context.new_page()
                        page = run['test_page']
                    elif url:
                        page = run['page']
                    if url:
                        await context.navigate(page, url)
                    await self.chromium_step(context, page, step)
                else:
                    await asyncio.to_thread(self.selenium_step, run, step, url)
                completed += 1
                self.event(identity, 'test', f'Step {completed} passed: {selector}', build=run['build'])
            artifact = await self.capture_test(run, page, 'test-result.png')
            return dict(passed=True, completed=completed, build=run['build'], after=started, artifact=artifact,
                        instructions='Declared page assertions passed. Popup chrome, permission prompts and distribution packaging require their own checks.')
        except Exception as error:
            artifact = await self.capture_test(run, page, 'test-failure.png')
            self.event(identity, 'test', f'Step {completed + 1} failed: {error}', 'error', build=run['build'])
            if artifact:
                self.event(identity, 'artifact', artifact, build=run['build'])
            raise

    async def expect_event(self, run, expectation, after):
        if not isinstance(expectation, dict) or not expectation or set(expectation) - {'kind', 'context', 'message', 'level'}:
            raise ValueError('An event assertion accepts kind, context, message and level.')
        if any(not isinstance(value, str) or len(value) > 2048 for value in expectation.values()):
            raise ValueError('Event assertion values must be strings of at most 2048 characters.')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.journal.lock:
                matched = any(row['id'] > after and row['target'] == run['target'] and row['build'] == run['build']
                              and all(value in row[key] if key == 'message' else value == row[key]
                                      for key, value in expectation.items()) for row in self.journal.events)
            if matched:
                self.event(run['target'], 'test', 'Diagnostic assertion passed: ' + json.dumps(expectation), build=run['build'])
                return
            await asyncio.sleep(0.1)
        raise ValueError('Expected diagnostic was not captured: ' + json.dumps(expectation))

    async def capture_test(self, run, page, name):
        path = self.state / run['target'] / name
        try:
            if page:
                await run['context'].screenshot(page, path)
            else:
                await asyncio.to_thread(run['driver'].save_screenshot, str(path))
            return str(path)
        except Exception:
            return None

    @staticmethod
    async def chromium_step(context, page, step):
        selector = json.dumps(step['selector'])
        lookup = f"document.querySelectorAll({selector})"
        deadline = time.monotonic() + 10
        while not await context.evaluate(page, f'{lookup}.length === 1'):
            if time.monotonic() >= deadline:
                raise ValueError('Expected exactly one element: ' + step['selector'])
            await asyncio.sleep(0.1)
        if step.get('click'):
            # DOM-backed coordinates feed real browser input, preserving normal event delivery.
            box = await context.evaluate(page, f"(() => {{ const e={lookup}[0]; e.scrollIntoView({{block:'center'}}); const r=e.getBoundingClientRect(); return {{x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height,disabled:!!e.disabled}}; }})()")
            if box['disabled'] or box['width'] <= 0 or box['height'] <= 0:
                raise ValueError('The selected element is disabled or has no visible box.')
            session = await context.attach(page)
            for kind in ('mousePressed', 'mouseReleased'):
                await context.send('Input.dispatchMouseEvent', dict(type=kind, x=box['x'], y=box['y'], button='left', clickCount=1), session=session)
        if 'fill' in step:
            await context.evaluate(page, f"(() => {{ const e={lookup}[0]; if(e.type==='password') throw Error('Password fields require user input'); if(e.disabled || e.readOnly || !('value' in e)) throw Error('Field is not editable'); e.focus(); const p=e instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype; Object.getOwnPropertyDescriptor(p,'value').set.call(e,{json.dumps(str(step['fill']))}); e.dispatchEvent(new Event('input',{{bubbles:true}})); e.dispatchEvent(new Event('change',{{bubbles:true}})); }})()")
        if 'text' in step:
            deadline = time.monotonic() + 10
            expression = f"{lookup}.length === 1 && {lookup}[0].textContent.trim() === {json.dumps(str(step['text']))}"
            while not await context.evaluate(page, expression):
                if time.monotonic() >= deadline:
                    raise ValueError('Text assertion failed for ' + step['selector'])
                await asyncio.sleep(0.1)

    @staticmethod
    def firefox_navigate(driver, url):
        if not url.startswith('moz-extension://'):
            driver.get(url)
            return
        from selenium.webdriver.support.ui import WebDriverWait
        from selenium.webdriver.support import expected_conditions
        previous = driver.execute_script('return document.documentElement')
        with driver.context(driver.CONTEXT_CHROME):
            driver.execute_script('gBrowser.selectedBrowser.loadURI(Services.io.newURI(arguments[0]), {triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal()});', url)
        # loadURI returns before loading finishes. URL equality alone can click the new DOM
        # before its scripts register listeners, or pass on the old document for a same-URL reload.
        if previous is not None:
            WebDriverWait(driver, 10).until(expected_conditions.staleness_of(previous))
        WebDriverWait(driver, 10).until(lambda browser: browser.current_url == url
                                      and browser.execute_script('return document.readyState') == 'complete')

    @staticmethod
    def selenium_step(run, step, url):
        driver = run['driver']
        from selenium.webdriver.common.by import By
        from selenium.webdriver.support.ui import WebDriverWait
        if url:
            if step.get('page'):
                handle = run.get('extension_window')
                if handle in driver.window_handles:
                    driver.switch_to.window(handle)
                else:
                    driver.switch_to.new_window('tab')
                    run['extension_window'] = driver.current_window_handle
            else:
                driver.switch_to.window(run['primary_window'])
            Workbench.firefox_navigate(driver, url)
        def match(browser):
            elements = browser.find_elements(By.CSS_SELECTOR, step['selector'])
            return elements[0] if len(elements) == 1 else False
        element = WebDriverWait(driver, 10).until(match)
        if step.get('click'):
            element.click()
        if 'fill' in step:
            if element.get_attribute('type') == 'password':
                raise ValueError('Password fields require user input.')
            element.clear()
            element.send_keys(str(step['fill']))
        if 'text' in step:
            WebDriverWait(driver, 10).until(lambda browser: match(browser) and match(browser).text == str(step['text']))

    def require_generation(self, request):
        generation = request.get('generation')
        if generation and generation != self.generation:
            raise ValueError('That event came from an earlier development worker. Read events again and use a current ID.')

    async def call(self, request):
        action = request.get('action', 'inspect')
        identity = request.get('target', '')
        if action == 'scaffold':
            return await asyncio.to_thread(scaffold, self.project)
        if action == 'setup':
            if self.runs:
                raise ValueError('Stop development targets before updating their tools.')
            await self.command([sys.executable, '-m', 'pip', 'install', '--upgrade', '--target', str(self.packages),
                                'playwright==1.64.0', 'selenium==4.51.0'], '', timeout=SETUP_STEP_TIMEOUT)
            importlib.invalidate_caches()
            await self.command([sys.executable, '-m', 'playwright', 'install', 'chromium'], '', timeout=SETUP_STEP_TIMEOUT)
            return dict(instructions='Chromium and desktop development tools installed. Firefox uses the installed Firefox application. Android additionally needs adb and web-ext.')
        if action == 'inspect':
            return dict(targets=discover(self.project), runs=[self.public_run(x) for x in self.runs.values()],
                generation=self.generation,
                runtime=dict(playwright=bool(importlib.util.find_spec('playwright')), selenium=bool(importlib.util.find_spec('selenium'))),
                coverage=dict(instrumented=['console', 'exceptions', 'unhandled-rejections', 'failed-fetch', 'failed-XHR',
                    'message-operations', 'ports', 'native-message-operations', 'selected-browser-API-operations', 'context-lifecycle',
                    'scripting.executeScript', 'isolated-registered-scripts', 'static-MAIN-untrusted', 'embedded-sandbox-untrusted'],
                    excluded=['registered MAIN scripts', 'legacy tabs.executeScript', 'browser-internal errors',
                        'request bodies', 'breakpoints', 'native host process internals', 'closed shadow roots'],
                    mode='Development copy; background requires loopback host permission.'))
        if action == 'start':
            return await self.start(identity, request.get('headless', False))
        if action == 'reload':
            return await self.reload(identity)
        if action == 'test':
            return await self.test(identity)
        if action in ('debug', 'popup', 'options', 'side-panel'):
            return await self.open_page(identity, action)
        if action == 'source':
            self.require_generation(request)
            run = self.runs.get(identity)
            event = self.journal.find(request.get('event'), identity)
            if not run or not event:
                raise ValueError('The target or event is no longer retained.')
            if event['build'] != run['build']:
                raise ValueError('This event belongs to an older build. Reproduce it in the current build before opening source.')
            return await asyncio.to_thread(resolve_source, self.project, Path(run['source']), event['stack'])
        if action == 'stop':
            return await self.stop(identity)
        if action == 'events':
            if request.get('event') is not None:
                self.require_generation(request)
                event = self.journal.find(request['event'], identity)
                if not event:
                    raise ValueError('That event is no longer retained.')
                page = dict(events=[event], cursor=event['id'])
            else:
                page = self.journal.page(int(request.get('after', 0)), int(request.get('limit', 100)),
                                         request.get('query', ''), identity)
            page['runs'] = [self.public_run(run) for run in self.runs.values()]
            page['generation'] = self.generation
            return page
        if action == 'clear':
            with self.journal.lock:
                self.journal.events.clear()
                self.journal.dropped = self.journal.evicted = 0
            return dict(cleared=True)
        if action == 'package-safari':
            run = self.runs.get(identity)
            if not run:
                raise ValueError('Start the Safari target before packaging its development copy.')
            # The generated Xcode project outlives this worker generation: Xcode may still have
            # it open after the panel closes. One folder per target, replaced by the next package.
            output = self.state.parent / 'Safari' / identity
            await self.command(['xcrun', 'safari-web-extension-converter', run['directory'], '--project-location', str(output),
                                '--app-name', 'ExtensionDevelopment', '--bundle-identifier', 'local.threading.extensiondevelopment',
                                '--no-open', '--force'], identity)
            return dict(project=str(output / 'ExtensionDevelopment/ExtensionDevelopment.xcodeproj'), instructions='Run the generated Xcode project on Mac or an iOS Simulator, then enable the extension in Safari. Local diagnostics work on Mac and Simulator. Physical iOS devices use Safari’s remote developer tools.')
        raise ValueError('Unknown workbench action.')

    async def close(self):
        await asyncio.gather(*(self.stop(identity) for identity in list(self.runs)), return_exceptions=True)
        await asyncio.to_thread(self.collector.shutdown)
        self.collector.server_close()
        # Profiles, development copies and screenshots belong to this worker generation alone.
        # Removing them here covers an application quit, where only stdin's EOF reaches us.
        # A state directory that holds the checkout is a misconfiguration, never deleted.
        if not self.project.is_relative_to(self.state):
            await asyncio.to_thread(shutil.rmtree, self.state, ignore_errors=True)


def unsupported_python():
    return (f'Python {MINIMUM_PYTHON[0]}.{MINIMUM_PYTHON[1]} or later is required; {sys.executable} is '
            f'{sys.version.split()[0]}. Install a newer Python 3, then reopen Web Extensions.')


async def main():
    workbench = Workbench(Path(sys.argv[1]), Path(sys.argv[2]))
    task = asyncio.current_task()
    closing = False
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, lambda: None if closing else task.cancel())
    try:
        while line := await asyncio.to_thread(sys.stdin.buffer.readline, MAX_LINE + 1):
            identity, request, action, deadline = None, None, '', None
            started = time.monotonic()
            try:
                if len(line) > MAX_LINE:
                    raise ValueError('Command too large')
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError('A development command must be a JSON object.')
                identity = request.get('id')
                action = str(request.get('action', ''))
                deadline = SETUP_TIMEOUT if action == 'setup' else OPERATION_TIMEOUT
                value = await asyncio.wait_for(workbench.call(request), deadline)
                reply = dict(id=identity, ok=True, result=value)
            except Exception as error:
                expired = deadline is not None and time.monotonic() - started >= deadline
                message = error_message(error, action, deadline if expired else None)
                workbench.event(request.get('target', '') if isinstance(request, dict) else '', 'operation', message, 'error')
                reply = dict(id=identity, ok=False, error=message)
            print(json.dumps(reply), flush=True)
    finally:
        closing = True
        await workbench.close()


if __name__ == '__main__':
    os.setpgrp()
    if sys.version_info < MINIMUM_PYTHON:
        # Answer every command with the reason instead of failing on a newer standard-library API.
        for _ in sys.stdin.buffer:
            print(json.dumps(dict(id=None, ok=False, error=unsupported_python())), flush=True)
    else:
        asyncio.run(main())
