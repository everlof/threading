"""Owned Chromium CDP pipe: attach to pages, never pause extension workers.

posix_spawn maps Chromium's documented protocol pipes to fds 3/4 without running
Python after fork in a threaded process. No listening debug port or personal profile.
"""
import asyncio
import base64
import fcntl
import json
import os
from pathlib import Path
import signal
import threading
import time


class Chromium:
    def __init__(self, binary, profile, headless, on_event):
        self.loop = asyncio.get_running_loop()
        self.pending = {}
        self.sequence = 0
        self.on_event = on_event
        self.closed = False
        self.stopping = False
        self.sessions = {}
        self.stderr_tail = ''
        self.event_slots = threading.BoundedSemaphore(128)
        self.write_lock = threading.Lock()
        incoming, self.writer = os.pipe()
        self.reader, outgoing = os.pipe()
        self.error_reader, errors = os.pipe()
        child_in = fcntl.fcntl(incoming, fcntl.F_DUPFD_CLOEXEC, 10)
        child_out = fcntl.fcntl(outgoing, fcntl.F_DUPFD_CLOEXEC, 10)
        child_errors = fcntl.fcntl(errors, fcntl.F_DUPFD_CLOEXEC, 10)
        os.close(incoming)
        os.close(outgoing)
        os.close(errors)
        null = os.open(os.devnull, os.O_RDWR)
        arguments = [str(binary), '--remote-debugging-pipe', '--enable-unsafe-extension-debugging',
                     '--user-data-dir=' + str(profile), '--no-first-run', '--no-default-browser-check',
                     '--disable-background-timer-throttling', '--disable-renderer-backgrounding', 'about:blank']
        if headless:
            arguments.insert(1, '--headless=new')
        actions = [(os.POSIX_SPAWN_DUP2, null, fd) for fd in (0, 1)]
        actions += [(os.POSIX_SPAWN_DUP2, child_errors, 2)]
        actions += [(os.POSIX_SPAWN_DUP2, child_in, 3), (os.POSIX_SPAWN_DUP2, child_out, 4)]
        try:
            self.pid = os.posix_spawn(str(binary), arguments, dict(os.environ), file_actions=actions, setpgroup=0)
        except BaseException:
            os.close(self.reader)
            os.close(self.writer)
            os.close(self.error_reader)
            raise
        finally:
            for fd in (child_in, child_out, child_errors, null):
                os.close(fd)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
        self.error_thread = threading.Thread(target=self.read_errors, daemon=True)
        self.error_thread.start()

    def read_errors(self):
        try:
            while not self.stopping:
                chunk = os.read(self.error_reader, 4096)
                if not chunk:
                    break
                self.stderr_tail = (self.stderr_tail + chunk.decode(errors='replace'))[-16384:]
        except OSError:
            pass
        finally:
            os.close(self.error_reader)

    def read(self):
        buffer = bytearray()
        try:
            while not self.stopping:
                chunk = os.read(self.reader, 65536)
                if not chunk:
                    break
                buffer.extend(chunk)
                if len(buffer) > 8 * 1024 * 1024:
                    raise ValueError('Browser protocol exceeded 8 MiB.')
                while (end := buffer.find(b'\0')) >= 0:
                    value = json.loads(buffer[:end])
                    del buffer[:end + 1]
                    if 'id' in value:
                        self.loop.call_soon_threadsafe(self.receive, value)
                    elif (end <= 65536 and value.get('method') == 'Runtime.exceptionThrown'
                          and self.event_slots.acquire(blocking=False)):
                        self.loop.call_soon_threadsafe(self.receive_event, value)
        except (OSError, ValueError):
            pass
        finally:
            os.close(self.reader)
            if not self.loop.is_closed():
                self.loop.call_soon_threadsafe(self.disconnected)

    def receive_event(self, value):
        try:
            self.receive(value)
        finally:
            self.event_slots.release()

    def receive(self, message):
        if 'id' in message:
            future = self.pending.pop(message['id'], None)
            if future is not None and not future.done():
                if error := message.get('error'):
                    future.set_exception(ValueError(error.get('message', str(error))))
                else:
                    future.set_result(message.get('result', {}))
        elif message.get('method') == 'Runtime.exceptionThrown':
            self.on_event(message['method'], message.get('params', {}))

    def disconnected(self):
        self.closed = True
        for future in self.pending.values():
            if not future.done():
                future.set_exception(ValueError('Development browser disconnected. Stop and restart this target.'))
        self.pending.clear()

    async def send(self, method, params=None, session=None, timeout=20):
        if self.closed:
            raise ValueError('Development browser disconnected.')
        self.sequence += 1
        identity = self.sequence
        request = dict(id=identity, method=method, params=params or {})
        if session:
            request['sessionId'] = session
        data = json.dumps(request).encode() + b'\0'
        future = self.loop.create_future()
        self.pending[identity] = future
        try:
            await asyncio.to_thread(self.write, data)
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as error:
            raise ValueError(f'Browser did not answer {method} within {timeout} seconds. ' + self.stderr_tail[-2000:]) from error
        finally:
            self.pending.pop(identity, None)

    def write(self, data):
        with self.write_lock:
            while data:
                written = os.write(self.writer, data)
                data = data[written:]

    async def attach(self, target):
        if target not in self.sessions:
            result = await self.send('Target.attachToTarget', dict(targetId=target, flatten=True))
            session = result['sessionId']
            self.sessions[target] = session
            await self.send('Runtime.enable', session=session)
            await self.send('Page.enable', session=session)
        return self.sessions[target]

    async def new_page(self, url='about:blank'):
        result = await self.send('Target.createTarget', dict(url='about:blank'))
        target = result['targetId']
        await self.attach(target)
        if url != 'about:blank':
            await self.navigate(target, url)
        return target

    async def evaluate(self, target, expression, timeout=20):
        result = await self.send('Runtime.evaluate', dict(expression=expression, returnByValue=True,
                                                         awaitPromise=True, userGesture=True),
                                 session=await self.attach(target), timeout=timeout)
        if details := result.get('exceptionDetails'):
            raise ValueError(details.get('exception', {}).get('description', details.get('text', 'JavaScript failed')))
        return result.get('result', {}).get('value')

    async def navigate(self, target, url):
        result = await self.send('Page.navigate', dict(url=url), session=await self.attach(target))
        if result.get('errorText'):
            raise ValueError(result['errorText'])
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            try:
                frame = await self.send('Page.getFrameTree', session=await self.attach(target))
                committed = not result.get('loaderId') or frame['frameTree']['frame'].get('loaderId') == result['loaderId']
                if committed and await self.evaluate(target, 'document.readyState === "complete"'):
                    return
            except ValueError:
                pass
            await asyncio.sleep(0.05)
        raise ValueError('Browser navigation timed out: ' + url)

    async def screenshot(self, target, path):
        result = await self.send('Page.captureScreenshot', dict(format='png', captureBeyondViewport=False),
                                 session=await self.attach(target), timeout=5)
        await asyncio.to_thread(Path(path).write_bytes, base64.b64decode(result['data']))

    async def close_page(self, target):
        await self.send('Target.closeTarget', dict(targetId=target))
        self.sessions.pop(target, None)

    async def close(self):
        try:
            if not self.closed:
                await self.send('Browser.close', timeout=3)
        except (OSError, ValueError, asyncio.TimeoutError):
            pass
        for number in (None, signal.SIGTERM, signal.SIGKILL):
            try:
                if os.waitpid(self.pid, os.WNOHANG)[0]:
                    break
                if number:
                    os.killpg(self.pid, number)
                deadline = time.monotonic() + (0.5 if number == signal.SIGKILL else 2)
                while time.monotonic() < deadline:
                    if os.waitpid(self.pid, os.WNOHANG)[0]:
                        break
                    await asyncio.sleep(0.05)
                else:
                    continue
                break
            except ChildProcessError:
                break
        self.disconnected()
        self.stopping = True
        try:
            os.close(self.writer)
        except OSError:
            pass
        # Reader threads own their descriptors. Closing one here can let an old reader
        # consume a newly launched browser's reused fd before it notices shutdown.
        await asyncio.to_thread(self.thread.join, 1)
        await asyncio.to_thread(self.error_thread.join, 1)
