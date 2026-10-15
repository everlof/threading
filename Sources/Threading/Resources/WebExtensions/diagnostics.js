/* Injected into a disposable development copy only. No payload/body/cookie capture. */
(() => {
  if (globalThis.__threadingDiagnostics) return;
  Object.defineProperty(globalThis, '__threadingDiagnostics', {value: true});
  const config = __THREADING_CONFIG__;
  // Public worlds never receive collector credentials or trust a page-provided chrome object.
  const api = config.public ? undefined : globalThis.browser || globalThis.chrome;
  // A sandboxed extension page has no extension API at all.
  const runtime = api?.runtime;
  const originalFetch = globalThis.fetch.bind(globalThis);
  const originalConnect = runtime?.connect?.bind(runtime);
  // randomUUID exists only in secure contexts, and a content script on a plain-http site is not one.
  const contextID = globalThis.crypto?.randomUUID?.() ??
    `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  const location = () => globalThis.location?.href || '';
  const context = config.context || (config.background ? 'background' :
    /^(chrome|moz|safari-web)-extension:/.test(location()) ? 'extension-page' : 'content-script');
  const relay = {name: 'threading-diagnostics', batch: 50, queue: 200, delay: 100, idle: 5000};
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
  const post = event => originalFetch(config.endpoint, {method: 'POST', headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(event), signal: AbortSignal.timeout(2000)}).catch(() => {});
  // The background and extension pages hold the loopback host permission and post directly.
  // A content script makes requests under its page's origin rules, so it batches events over one
  // named port to the background instead. A port reaches only onConnect listeners, never the
  // extension's own onMessage handlers, and batching makes background wake-ups follow bursts of
  // diagnostics rather than every single event.
  let port = null, pending = [], flushTimer = 0, idleTimer = 0;
  const flush = () => {
    clearTimeout(flushTimer);
    flushTimer = 0;
    if (!pending.length || !originalConnect) return;
    try {
      if (!port) {
        port = originalConnect({name: relay.name});
        port.onDisconnect.addListener(() => { void runtime.lastError; port = null; });
      }
      port.postMessage({token: config.token, events: pending.splice(0, relay.batch)});
    } catch {
      // A port the background closed, or a context orphaned by a reload. That batch is lost; the
      // bounded queue waits for the next event to try a fresh port.
      port = null;
      return;
    }
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { try { port?.disconnect(); } catch {} port = null; }, relay.idle);
    if (pending.length) flushTimer = setTimeout(flush, relay.delay);
  };
  const deliver = event => {
    // A bounded fire-and-forget diagnostics channel must never break the application.
    try {
      if (config.public) {
        const destination = config.context === 'sandbox-untrusted' ? globalThis.parent : globalThis;
        destination.postMessage({threadingChannel: config.channel, event}, '*');
        return;
      }
      if (context !== 'content-script') return void post(event);
      if (pending.length < relay.queue) pending.push(event);
      if (!flushTimer) flushTimer = setTimeout(flush, relay.delay);
    } catch {}
  };
  if (context === 'content-script') globalThis.addEventListener('pagehide', flush);
  const emit = (level, kind, message, stack = '', observedContext = context) => {
    const now = Date.now();
    if (now - windowStart > 1000) { windowStart = now; sent = 0; }
    if (++sent > 100) {
      if (sent === 101) deliver({level: 'warning', kind: 'dropped', message: 'Context exceeded 100 events/second',
        context, contextID, build: config.build, url: location()});
      return;
    }
    deliver({level, kind, message: message.slice(0, 8192), stack: stack.slice(0, 8192),
      context: observedContext, contextID, sequence: ++sequence, build: config.build, url: location(), time: now});
  };
  if (!config.public && globalThis.document) globalThis.addEventListener('message', received => {
    if (received.data?.threadingChannel !== config.channel) return;
    let observedContext;
    // Firefox's content-script globalThis is a separate sandbox, even though it prints as
    // [object Window]. MessageEvent.source is the document's window in both browser families.
    if (context === 'content-script' && received.source === window) observedContext = 'main-world-untrusted';
    else if (context !== 'content-script') {
      // Only a declared sandbox frame embedded by this extension can use the parent relay.
      const frames = document.getElementsByTagName('iframe');
      for (let i = 0; i < Math.min(frames.length, 32); i++) {
        if (frames[i].contentWindow === received.source &&
            config.sandboxes?.some(path => frames[i].src === runtime?.getURL(path))) {
          observedContext = 'sandbox-untrusted'; break;
        }
      }
    }
    const event = received.data?.event;
    if (!observedContext || !event || typeof event.message !== 'string') return;
    const level = ['debug', 'log', 'info', 'warning', 'error', 'trace'].includes(event.level) ? event.level : 'warning';
    const kind = ['console', 'exception', 'unhandled-rejection', 'network', 'connected', 'dropped'].includes(event.kind)
      ? event.kind : 'console';
    emit(level, kind, event.message.slice(0, 8192), typeof event.stack === 'string' ? event.stack.slice(0, 8192) : '', observedContext);
  });
  if (config.background && runtime) {
    runtime.onConnect.addListener(port => {
      if (port.name !== relay.name || port.sender?.id !== runtime.id) return;
      port.onMessage.addListener(message => {
        if (message?.token !== config.token || !Array.isArray(message.events)) return;
        for (const event of message.events.slice(0, relay.batch)) {
          if (event && typeof event === 'object') post({...event, tab: port.sender?.tab?.id, frame: port.sender?.frameId});
        }
      });
    });
    // Records the extension's own traffic. Returning nothing never claims a response channel.
    runtime.onMessage.addListener((message, sender) => {
      emit('debug', 'message-received', `runtime.onMessage from tab ${sender.tab?.id ?? 'extension'} / frame ${sender.frameId ?? 0}`);
    });
  }
  // Preserve callback/Promise behavior; record the operation, never its payload or reply.
  // Correlation is local to the sending context. Do not mutate application messages to carry IDs.
  let messageSequence = 0;
  const traceMessages = (owner, key, label, family = 'message') => {
    if (!owner?.[key]) return;
    const original = owner[key].bind(owner);
    owner[key] = (...args) => {
      const operation = `${contextID}/${++messageSequence}`;
      const started = performance.now();
      const stack = new Error().stack || '';
      emit('debug', family === 'message' ? 'message-sent' : 'api-call', `${label} ${operation}`, stack);
      const done = error => emit(error ? 'error' : 'debug', error ? `${family}-failed` : `${family}-reply`,
        `${label} ${operation} (${Math.round(performance.now() - started)} ms)${error ? ': ' + text(error) : ''}`, stack);
      const callback = typeof args.at(-1) === 'function' ? args.pop() : null;
      if (callback) args.push((...reply) => { const error = runtime.lastError; done(error?.message); callback(...reply); });
      try {
        const result = original(...args);
        if (!callback && result?.then) return result.then(value => { done(); return value; }, error => { done(error); throw error; });
        return result;
      } catch (error) { done(error); throw error; }
    };
  };
  traceMessages(runtime, 'sendMessage', 'runtime.sendMessage');
  traceMessages(runtime, 'sendNativeMessage', 'runtime.sendNativeMessage');
  traceMessages(api?.tabs, 'sendMessage', 'tabs.sendMessage');
  /*__THREADING_RUNTIME_HOOKS__*/
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
  if (globalThis.XMLHttpRequest) {
    const prototype = XMLHttpRequest.prototype, requests = new WeakMap();
    const open = prototype.open, send = prototype.send;
    prototype.open = function(...args) {
      const result = Reflect.apply(open, this, args);
      requests.set(this, {method: String(args[0]).slice(0, 16), url: String(args[1]).slice(0, 2048)});
      return result;
    };
    prototype.send = function(...args) {
      const request = requests.get(this), started = performance.now(), stack = new Error().stack || '';
      const finished = () => {
        if (request && (this.status === 0 || this.status >= 400)) emit('error', 'network',
          `XHR ${request.method} ${this.status} ${request.url} (${Math.round(performance.now() - started)} ms)`, stack);
      };
      this.addEventListener('loadend', finished, {once: true});
      try { return Reflect.apply(send, this, args); }
      catch (error) { this.removeEventListener('loadend', finished); emit('error', 'network', `XHR: ${text(error)}`, stack); throw error; }
    };
  }
  emit('info', 'connected', `${context} connected`);
})();
