import Foundation

enum BrowserNetworkCaptureScripts {
    static func installation(options: BrowserNetworkCaptureOptions, generation: Int) -> String {
        source + "\n" + configuration(options: options, generation: generation)
    }

    static func configuration(options: BrowserNetworkCaptureOptions, generation: Int) -> String {
        "globalThis.__threadingConfigureNetworkCapture?.(\(options.scriptValue), \(generation));"
    }

    // This runs in the page process. Body readers are bounded by bytes, concurrency and time;
    // they never await on the page's fetch promise or consume the response the page receives.
    static let source = #"""
    (() => {
      if (globalThis.__threadingNetworkInstalled) return;
      globalThis.__threadingNetworkInstalled = true;
      let configuration = {}, generation = 0, activeReaders = 0, sequence = 0;
      const documentID = globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const encoder = new TextEncoder();
      const maxBytes = 8192, maxHeaders = 32;
      const post = payload => {
        try { webkit.messageHandlers.threadingNetwork.postMessage(payload); } catch (_) {}
      };
      const clean = (value, maximum = 2000) =>
        String(value || '').replace(/\s+/g, ' ').trim().slice(0, maximum);
      const bounded = value => {
        const prefix = String(value).slice(0, maxBytes);
        const bytes = encoder.encode(prefix);
        const truncated = String(value).length > maxBytes || bytes.length > maxBytes;
        return new TextDecoder().decode(bytes.slice(0, maxBytes - 64))
          + (truncated || bytes.length > maxBytes - 64 ? '\n[truncated]' : '');
      };
      const sensitive = name => /authorization|cookie|password|passwd|token|secret|api[-_]?key|credential/i.test(name);
      const safeURL = value => {
        try {
          const url = new URL(String(value || ''), location.href);
          url.username = ''; url.password = ''; url.hash = '';
          for (const name of url.searchParams.keys()) {
            if (/access_token|auth|code|credential|key|password|secret|session|signature|token/i.test(name)) {
              url.searchParams.set(name, '[redacted]');
            }
          }
          return url.href.slice(0, 2000);
        } catch (_) { return clean(value); }
      };
      const headers = input => {
        const result = [];
        try {
          for (const [name, value] of new Headers(input || {})) {
            result.push([clean(name, 128), sensitive(name) ? '[redacted]' : clean(value, 512)]);
            if (result.length >= maxHeaders) break;
          }
        } catch (_) {}
        return result;
      };
      const textual = type => !type || /^(text\/|application\/(.*json|.*xml|javascript|x-www-form-urlencoded))/i.test(type);
      const scrubJSON = (value, budget, depth = 0) => {
        if (--budget.remaining < 0 || depth > 16) return '[omitted]';
        if (!value || typeof value !== 'object') return value;
        if (Array.isArray(value)) return value.slice(0, 128).map(item => scrubJSON(item, budget, depth + 1));
        const result = Object.create(null);
        for (const name of Object.keys(value).slice(0, 128)) {
          result[name] = sensitive(name) ? '[redacted]' : scrubJSON(value[name], budget, depth + 1);
        }
        return result;
      };
      const safeBody = (value, type = '') => {
        if (!textual(type) || /event-stream/i.test(type)) return '[binary or streaming body omitted]';
        const text = bounded(value);
        // Parsing is bounded by the 8 KiB input; nested keys get the same redaction as top-level keys.
        try {
          if (/^\s*[\[{]/.test(text)) {
            return bounded(JSON.stringify(scrubJSON(JSON.parse(text), { remaining: 1024 })));
          }
        } catch (_) {}
        return text.replace(/("[^"\\]*(?:password|passwd|token|secret|cookie|authorization|api[-_]?key|credential)[^"\\]*"\s*:\s*)("(?:[^"\\]|\\.)*"|[^,}\]\n]+)/gi,
          (_, prefix) => prefix + '"[redacted]"')
          .replace(/(^|&)([^=&]+)=([^&]*)/g, (match, separator, name) =>
            sensitive(name) ? separator + name + '=[redacted]' : match);
      };
      const readBody = async (body, type = '') => {
        if (!body) return '';
        if (!textual(type) || /event-stream/i.test(type)) return '[binary or streaming body omitted]';
        const reader = body.getReader();
        const chunks = []; let length = 0, truncated = false;
        let timer;
        const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(Error('timeout')), 1000); });
        try {
          while (length < maxBytes && chunks.length < 64) {
            const part = await Promise.race([reader.read(), deadline]);
            if (part.done) break;
            const bytes = part.value.subarray(0, maxBytes - length);
            chunks.push(bytes); length += bytes.length;
            if (bytes.length < part.value.length || length === maxBytes) { truncated = true; break; }
          }
          const bytes = new Uint8Array(length); let offset = 0;
          for (const part of chunks) { bytes.set(part, offset); offset += part.length; }
          return safeBody(new TextDecoder().decode(bytes) + (truncated ? '\n[truncated]' : ''), type);
        } catch (_) { return '[body unavailable or timed out]'; }
        finally { clearTimeout(timer); reader.cancel().catch(() => {}); }
      };
      const requestBody = (input, init) => {
        try {
          const type = new Headers(init && 'headers' in init ? init.headers : input?.headers || {})
            .get('content-type') || '';
          const value = init && 'body' in init ? init.body : undefined;
          if (typeof value === 'string' || value instanceof URLSearchParams) {
            return Promise.resolve(safeBody(String(value), type));
          }
          if (value != null) return Promise.resolve('[non-text request body omitted]');
          if (input instanceof Request && input.body) {
            const copy = input.clone();
            return readBody(copy.body, copy.headers.get('content-type') || '');
          }
        } catch (_) { return Promise.resolve('[request body unavailable]'); }
        return Promise.resolve('');
      };
      const report = (id, method, url, kind, status, started, error = null) => post({
        capture_id: id,
        method: clean(method || 'GET', 24).toUpperCase(), url: safeURL(url),
        kind: clean(kind || 'other', 40).toLowerCase(),
        status: Number.isFinite(status) ? status : null,
        duration: Number.isFinite(started) ? Math.max(0, performance.now() - started) : null,
        error: error ? 'Request failed or was blocked' : null
      });
      const options = () => globalThis === globalThis.top ? { ...configuration, generation } : {};
      const details = (id, policy, values) => {
        if (policy.generation !== generation) return;
        const payload = { details: true, capture_id: id, generation };
        for (const [key, value] of Object.entries(values)) {
          if (value !== undefined) payload[key] = value;
        }
        post(payload);
      };
      globalThis.__threadingConfigureNetworkCapture = (value, revision) => {
        configuration = value || {}; generation = revision;
      };

      if (typeof globalThis.fetch === 'function') {
        const originalFetch = globalThis.fetch.bind(globalThis);
        globalThis.fetch = async (input, init) => {
          const id = documentID + ':' + (++sequence), started = performance.now();
          const method = init?.method || input?.method || 'GET';
          const url = typeof input === 'string' || input instanceof URL ? input : input?.url;
          const policy = options();
          const capturing = Object.values(policy).some(value => value === true);
          const reading = capturing && (policy.request_body || policy.response_body) && activeReaders < 4;
          let body, requestHeaders;
          if (capturing) {
            if (reading) activeReaders++;
            body = policy.request_body
              ? (reading ? requestBody(input, init) : Promise.resolve('[body capture busy]'))
              : Promise.resolve(undefined);
            requestHeaders = policy.request_headers
              ? headers(init && 'headers' in init ? init.headers : input?.headers) : undefined;
          }
          try {
            const response = await originalFetch(input, init);
            report(id, method, response.url || url, 'fetch', response.status, started);
            if (capturing) {
              let responseBody = Promise.resolve(undefined);
              if (policy.response_body && !reading) responseBody = Promise.resolve('[body capture busy]');
              if (policy.response_body && reading) {
                try {
                  const type = response.headers.get('content-type') || '';
                  responseBody = textual(type) && !/event-stream/i.test(type)
                    ? readBody(response.clone().body, type)
                    : Promise.resolve('[binary or streaming body omitted]');
                } catch (_) { responseBody = Promise.resolve('[response body unavailable]'); }
              }
              Promise.all([body, responseBody]).then(([request_body, response_body]) => details(id, policy, {
                request_headers: requestHeaders,
                response_headers: policy.response_headers ? headers(response.headers) : undefined,
                request_body, response_body
              })).catch(() => {}).finally(() => { if (reading) activeReaders--; });
            }
            return response;
          } catch (error) {
            report(id, method, url, 'fetch', null, started, true);
            if (capturing) {
              body.then(request_body => details(id, policy, {
                request_headers: requestHeaders, request_body
              })).catch(() => {}).finally(() => { if (reading) activeReaders--; });
            }
            throw error;
          }
        };
      }
      if (globalThis.XMLHttpRequest) {
        const requests = new WeakMap();
        const originalOpen = XMLHttpRequest.prototype.open, originalSend = XMLHttpRequest.prototype.send;
        const originalHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          requests.set(this, { method, url, headers: [] });
          return originalOpen.call(this, method, url, ...rest);
        };
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
          const result = originalHeader.call(this, name, value);
          const state = requests.get(this);
          if (state && String(name).toLowerCase() === 'content-type') state.contentType = clean(value, 128);
          if (configuration.request_headers && state?.headers.length < maxHeaders) {
            state.headers.push([clean(name, 128), sensitive(name) ? '[redacted]' : clean(value, 512)]);
          }
          return result;
        };
        XMLHttpRequest.prototype.send = function(value) {
          const state = requests.get(this) || { method: 'GET', url: '', headers: [] };
          const policy = options(), started = performance.now(), id = documentID + ':' + (++sequence);
          const request_body = policy.request_body
            ? (typeof value === 'string' || value instanceof URLSearchParams
              ? safeBody(String(value), state.contentType || '') : value == null ? '' : '[non-text request body omitted]') : undefined;
          this.addEventListener('loadend', () => {
            report(id, state.method, this.responseURL || state.url, 'xhr', this.status || null, started,
              this.status === 0 && !this.responseURL);
            let response_body;
            if (policy.response_body) {
              try {
                response_body = !this.responseType || this.responseType === 'text'
                  ? safeBody(this.responseText, this.getResponseHeader('content-type') || '')
                  : '[non-text response body omitted]';
              } catch (_) { response_body = '[response body unavailable]'; }
            }
            const response_headers = policy.response_headers
              ? this.getAllResponseHeaders().slice(0, 32768).trim().split(/[\r\n]+/).slice(0, maxHeaders)
                .map(line => { const index = line.indexOf(':'); return [line.slice(0, index), line.slice(index + 1).trim()]; })
              : undefined;
            details(id, policy, { request_headers: policy.request_headers ? state.headers : undefined,
              response_headers, request_body, response_body });
          }, { once: true });
          return originalSend.call(this, value);
        };
      }
      try {
        new PerformanceObserver(list => list.getEntries().forEach(entry => {
          if (['fetch', 'xmlhttprequest'].includes(entry.initiatorType)) return;
          post({ method: 'GET', url: safeURL(entry.name), kind: clean(entry.initiatorType || 'resource', 40),
            status: Number(entry.responseStatus) || null, duration: Math.max(0, Number(entry.duration) || 0) });
        })).observe({ type: 'resource', buffered: true });
      } catch (_) {}
      addEventListener('error', event => {
        const target = event.target;
        if (!target?.tagName || target === globalThis) return;
        const tag = target.tagName.toLowerCase();
        const url = target.currentSrc || target.getAttribute?.('src') || target.getAttribute?.('href');
        if (!url) return;
        const kind = tag === 'link' && target.relList?.contains('stylesheet') ? 'css'
          : ({ img: 'img', script: 'script', audio: 'audio', video: 'video', source: 'media', track: 'media' }[tag] || tag);
        report(null, 'GET', url, kind, null, NaN, true);
      }, true);
    })();
    """#
}
