/* Injected into a disposable development copy only. No payload/body/cookie capture. */
(() => {
  if (globalThis.__threadingDiagnostics) return;
  Object.defineProperty(globalThis, '__threadingDiagnostics', {value: true});
  const config = __THREADING_CONFIG__;
  const api = globalThis.browser || globalThis.chrome;
  const originalFetch = globalThis.fetch.bind(globalThis);
  const originalSend = api.runtime.sendMessage.bind(api.runtime);
  const contextID = crypto.randomUUID();
  const location = () => globalThis.location?.href || '';
  const context = config.background ? 'background' :
    /^(chrome|moz|safari-web)-extension:/.test(location()) ? 'extension-page' : 'content-script';
  let sequence = 0, sent = 0, windowStart = Date.now();
  const text = value => {
    try {
      if (value instanceof Error) return value.stack || value.message;
      if (typeof value === 'string') return value.slice(0, 4096);
      const seen = new WeakSet();
      let remaining = 64;
      const preview = (item, depth) => {
        if (typeof item === 'string') return item.slice(0, 512);
        if (!item || typeof item !== 'object') return typeof item === 'bigint' ? String(item) : item;
        if (seen.has(item)) return '[circular]';
        if (!depth || --remaining < 0) return '[object]';
        seen.add(item);
        const result = {};
        let count = 0;
        for (const key in item) {
          if (!Object.hasOwn(item, key)) continue;
          if (++count > 20 || remaining <= 0) { result['…'] = '[truncated]'; break; }
          const descriptor = Object.getOwnPropertyDescriptor(item, key);
          result[key.slice(0, 128)] = descriptor && 'value' in descriptor ? preview(descriptor.value, depth - 1) : '[accessor]';
        }
        return result;
      };
      return JSON.stringify(preview(value, 3))?.slice(0, 4096) || String(value);
    } catch { return '[unserializable]'; }
  };
  const deliver = event => {
    // A bounded fire-and-forget diagnostics channel must never break the application.
    try {
      if (config.background) {
        originalFetch(config.endpoint, {method: 'POST', headers: {'Content-Type': 'application/json'},
          body: JSON.stringify(event), signal: AbortSignal.timeout(2000)}).catch(() => {});
      } else if (globalThis.browser) {
        originalSend({__threading: config.token, event}).catch(() => {});
      } else {
        originalSend({__threading: config.token, event}, () => void api.runtime.lastError);
      }
    } catch {}
  };
  const emit = (level, kind, message, stack = '') => {
    const now = Date.now();
    if (now - windowStart > 1000) { windowStart = now; sent = 0; }
    if (++sent > 100) {
      if (sent === 101) deliver({level: 'warning', kind: 'dropped', message: 'Context exceeded 100 events/second',
        context, contextID, build: config.build, url: location()});
      return;
    }
    deliver({level, kind, message: message.slice(0, 8192), stack: stack.slice(0, 8192),
      context, contextID, sequence: ++sequence, build: config.build, url: location(), time: now});
  };
  if (config.background) {
    api.runtime.onMessage.addListener((message, sender) => {
      if (message?.__threading !== config.token || sender.id !== api.runtime.id) {
        emit('debug', 'message-received', `runtime.onMessage from tab ${sender.tab?.id ?? 'extension'} / frame ${sender.frameId ?? 0}`);
        return;
      }
      const event = message.event;
      if (!event || typeof event !== 'object') return;
      deliver({...event, tab: sender.tab?.id, frame: sender.frameId});
      // Do not claim the response channel of the extension's own messages.
      return false;
    });
  }
  // Preserve callback/Promise behavior; record the operation, never its payload or reply.
  // Correlation is local to the sending context. Do not mutate application messages to carry IDs.
  let messageSequence = 0;
  const traceMessages = (owner, key, label) => {
    if (!owner?.[key]) return;
    const original = owner[key].bind(owner);
    owner[key] = (...args) => {
      const operation = `${contextID}/${++messageSequence}`;
      const started = performance.now();
      const stack = new Error().stack || '';
      emit('debug', 'message-sent', `${label} ${operation}`, stack);
      const done = error => emit(error ? 'error' : 'debug', error ? 'message-failed' : 'message-reply',
        `${label} ${operation} (${Math.round(performance.now() - started)} ms)${error ? ': ' + text(error) : ''}`, stack);
      const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
      if (callback) args.push((...reply) => { const error = api.runtime.lastError; done(error?.message); callback(...reply); });
      try {
        const result = original(...args);
        if (!callback && result?.then) return result.then(value => { done(); return value; }, error => { done(error); throw error; });
        return result;
      } catch (error) { done(error); throw error; }
    };
  };
  traceMessages(api.runtime, 'sendMessage', 'runtime.sendMessage');
  traceMessages(api.tabs, 'sendMessage', 'tabs.sendMessage');
  for (const level of ['debug', 'log', 'info', 'warn', 'error', 'trace']) {
    const original = console[level].bind(console);
    console[level] = (...args) => {
      original(...args);
      emit(level === 'warn' ? 'warning' : level, 'console', args.slice(0, 20).map(text).join(' '), new Error().stack || '');
    };
  }
  globalThis.addEventListener('error', event => {
    emit('error', 'exception', event.message || 'Resource failed to load',
      event.error?.stack || `${event.filename || ''}:${event.lineno || 0}:${event.colno || 0}`);
  });
  globalThis.addEventListener('unhandledrejection', event => {
    emit('error', 'unhandled-rejection', text(event.reason), event.reason?.stack || '');
  });
  globalThis.fetch = async (...args) => {
    const started = performance.now();
    const url = typeof args[0] === 'string' ? args[0] : args[0]?.url || String(args[0]);
    try {
      const response = await originalFetch(...args);
      if (!response.ok) emit('error', 'network', `${response.status} ${url} (${Math.round(performance.now() - started)} ms)`);
      return response;
    } catch (error) {
      emit('error', 'network', `${url}: ${text(error)}`, error.stack || '');
      throw error;
    }
  };
  emit('info', 'connected', `${context} connected`);
})();
