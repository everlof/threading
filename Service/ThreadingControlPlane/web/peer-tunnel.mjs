// Browser implementation of ThreadingPeerTransport's v1 byte-stream tunnel. No remote HTTP
// request leaves this channel. Bounds match the native multiplexer; readers return credit only
// as they consume chunks. Expected: one peer, 2 live sockets and a handful of REST requests.
export const bounds = Object.freeze({ streams: 32, window: 256 * 1024, chunk: 48 * 1024,
  chunks: 512, queued: 2 * 1024 * 1024, response: 16 * 1024 * 1024, timeout: 30000 });
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
export const bytes = value => typeof value === 'string' ? encoder.encode(value) : new Uint8Array(value);
export function join(parts) {
  const output = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0; for (const part of parts) { output.set(part, offset); offset += part.length; }
  return output;
}
function deferred() { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {promise,resolve,reject}; }
export function deadline(promise, ms = bounds.timeout) {
  let timer; return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Connection timed out. Try again.')), ms);
  })]).finally(() => clearTimeout(timer));
}
export function frame(op, id, value = 0, payload = new Uint8Array()) {
  const output = new Uint8Array(12 + payload.length), view = new DataView(output.buffer);
  view.setUint16(0, 0x5452); view.setUint8(2, 1); view.setUint8(3, op);
  view.setUint32(4, id); view.setUint32(8, value); output.set(payload, 12); return output;
}
export class Tunnel {
  constructor(channel) {
    this.channel = channel; this.streams = new Map(); this.nextID = 1; this.closed = false;
    channel.binaryType = 'arraybuffer';
    channel.onmessage = event => { try { this.receive(event.data); } catch { this.close(); } };
    channel.onclose = () => this.close(); channel.onerror = () => this.close();
  }
  send(op, id, value = 0, payload) {
    if (this.closed || this.channel.readyState !== 'open') throw new Error('Connection closed.');
    const data = frame(op, id, value, payload);
    // The stream windows normally keep this below the bound. Fail instead of queueing unlimited
    // writes when a suspended tab or network stops draining SCTP.
    if (this.channel.bufferedAmount + data.length > bounds.queued) throw new Error('Connection is too slow. Reconnect.');
    this.channel.send(data);
  }
  async open() {
    if (this.closed || this.streams.size >= bounds.streams) throw new Error('Connection unavailable.');
    const id = this.nextID; this.nextID += 2;
    if (id > 0xffffffff) { this.close(); throw new Error('Connection exhausted.'); }
    const stream = new Stream(this, id); this.streams.set(id, stream);
    try { this.send(1, id); await deadline(stream.opened.promise, 10000); return stream; }
    catch (error) { stream.reset(); throw error; }
  }
  receive(data) {
    if (!(data instanceof ArrayBuffer) || data.byteLength < 12 || data.byteLength > bounds.chunk + 12) throw Error();
    const view = new DataView(data), op = view.getUint8(3), id = view.getUint32(4), value = view.getUint32(8);
    if (view.getUint16(0) !== 0x5452 || view.getUint8(2) !== 1 || !id || op < 2 || op > 6) throw Error();
    const payload = new Uint8Array(data, 12);
    if (op === 3 ? value !== payload.length : payload.length !== 0 || (op !== 4 && value !== 0)) throw Error();
    if (op === 4 && (!value || value > bounds.window)) throw Error();
    const stream = this.streams.get(id);
    // Frames already in flight after a local reset are harmless and never recreate a stream.
    if (!stream) { if (id < this.nextID && id % 2) return; throw Error(); }
    if (op === 2) { if (stream.isOpen) throw Error(); stream.isOpen = true; stream.opened.resolve(); }
    else if (op === 6) stream.fail(new Error('The Mac closed this request.'));
    else {
      if (!stream.isOpen) throw Error();
      if (op === 3) {
        if (stream.ended || stream.buffered + value > bounds.window || stream.queue.length >= bounds.chunks) throw Error();
        stream.buffered += value; stream.queue.push(payload); stream.notify();
      } else if (op === 4) {
        if (stream.credit + value > bounds.window) throw Error();
        stream.credit += value; stream.notifyCredit();
      } else if (op === 5) { if (stream.ended) throw Error(); stream.ended = true; stream.notify(); }
    }
  }
  close() {
    if (this.closed) return; this.closed = true;
    for (const stream of [...this.streams.values()]) stream.fail(new Error('Connection closed.'));
    this.channel.close(); this.onclose?.();
  }
}
class Stream {
  constructor(tunnel, id) {
    Object.assign(this, { tunnel, id, opened: deferred(), isOpen: false, credit: bounds.window,
      queue: [], buffered: 0, ended: false, error: null, writing: false });
    this.opened.promise.catch(() => {});
  }
  notify() { this.reader?.resolve(); this.reader = null; }
  notifyCredit() { this.writer?.resolve(); this.writer = null; }
  fail(error) {
    this.error = error; this.queue = []; this.buffered = 0;
    this.opened.reject(error); this.notify(); this.notifyCredit(); this.tunnel.streams.delete(this.id);
  }
  reset() {
    if (this.error) return;
    try { this.tunnel.send(6, this.id); } catch {}
    this.fail(new Error('Request closed.'));
  }
  async write(data) {
    if (this.writing) throw new Error('Concurrent stream write.');
    this.writing = true;
    try {
      for (let offset = 0; offset < data.length; offset += bounds.chunk) {
        const chunk = data.subarray(offset, offset + bounds.chunk);
        while (!this.error && this.credit < chunk.length) {
          this.writer = deferred(); await deadline(this.writer.promise);
        }
        if (this.error) throw this.error;
        this.credit -= chunk.length; this.tunnel.send(3, this.id, chunk.length, chunk);
      }
    } catch (error) { this.reset(); throw error; }
    finally { this.writing = false; }
  }
  async read() {
    while (!this.queue.length) {
      if (this.error) throw this.error;
      if (this.ended) return null;
      if (this.reader) throw new Error('Concurrent stream read.');
      this.reader = deferred(); await this.reader.promise;
    }
    const data = this.queue.shift(); this.buffered -= data.length;
    if (data.length) this.tunnel.send(4, this.id, data.length);
    return data;
  }
}
export class Reader {
  constructor(stream) { this.stream = stream; this.buffer = new Uint8Array(); }
  async take(count) {
    if (!Number.isSafeInteger(count) || count < 0 || count > bounds.response) throw Error('Response is too large.');
    const parts = []; let remaining = count;
    while (remaining) {
      if (!this.buffer.length) {
        this.buffer = await this.stream.read();
        if (this.buffer === null) throw new Error('The Mac closed the response early.');
      }
      const n = Math.min(remaining, this.buffer.length);
      parts.push(this.buffer.subarray(0, n)); this.buffer = this.buffer.subarray(n); remaining -= n;
    }
    return join(parts);
  }
  async head() {
    // Byte scanning is linear and bounded at 32 KiB; the body stays in the chunk buffer.
    const parts = []; let marker = 0;
    while (parts.length < 32768) {
      const value = (await this.take(1))[0]; parts.push(value);
      marker = ((marker << 8) | value) >>> 0;
      if (marker === 0x0d0a0d0a) {
        const lines = decoder.decode(new Uint8Array(parts)).trimEnd().split('\r\n');
        const match = /^HTTP\/1\.[01] (\d{3})(?: .*)?$/.exec(lines.shift());
        if (!match) throw Error('Invalid HTTP response.');
        const headers = new Headers();
        for (const line of lines) {
          const colon = line.indexOf(':'); if (colon <= 0) throw Error('Invalid HTTP header.');
          headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
        }
        return { status: Number(match[1]), headers };
      }
    }
    throw Error('Response headers are too large.');
  }
}
export async function tunnelFetch(tunnel, path, options = {}) {
  if (!/^\/api\/[A-Za-z0-9/_?=&.%:-]+$/.test(path)) throw Error('Unsupported request.');
  const method = options.method || 'GET'; if (!['GET','POST','DELETE','PUT','PATCH'].includes(method)) throw Error('Unsupported method.');
  const body = bytes(options.body || ''); if (body.length > bounds.queued) throw Error('Request is too large.');
  const headers = new Headers(options.headers);
  headers.set('Host', 'localhost'); headers.set('Connection', 'close'); headers.set('Content-Length', String(body.length));
  headers.delete('Accept-Encoding'); headers.delete('Transfer-Encoding');
  let stream;
  const abort = () => stream?.reset();
  if (options.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
  options.signal?.addEventListener('abort', abort, { once: true });
  try {
    return await deadline((async () => {
      stream = await tunnel.open();
      if (options.signal?.aborted) throw new DOMException('Aborted', 'AbortError');
      const head = method + ' ' + path + ' HTTP/1.1\r\n' + [...headers].map(([k,v]) => k + ': ' + v + '\r\n').join('') + '\r\n';
      await stream.write(join([bytes(head), body]));
      const reader = new Reader(stream), response = await reader.head();
      const length = response.headers.get('content-length');
      if (!length || !/^\d+$/.test(length) || response.headers.has('transfer-encoding') || response.headers.has('content-encoding')) throw Error('Unsupported response framing.');
      const data = await reader.take(Number(length));
      return new Response([204,205,304].includes(response.status) ? null : data, response);
    })());
  } finally { options.signal?.removeEventListener('abort', abort); stream?.reset(); }
}
export function webSocketFrame(op, payload) {
  if (payload.length > bounds.response) throw Error('Message too large.');
  const size = payload.length, extended = size < 126 ? 0 : size <= 65535 ? 2 : 8;
  const result = new Uint8Array(2 + extended + 4 + size), view = new DataView(result.buffer);
  result[0] = 0x80 | op; result[1] = 0x80 | (extended === 0 ? size : extended === 2 ? 126 : 127);
  if (extended === 2) view.setUint16(2, size);
  if (extended === 8) { view.setUint32(2, 0); view.setUint32(6, size); }
  const mask = crypto.getRandomValues(new Uint8Array(4)); result.set(mask, 2 + extended);
  for (let i = 0; i < size; i++) result[6 + extended + i] = payload[i] ^ mask[i % 4];
  return result;
}
export function socketClass(getTunnel) {
  return class TunnelWebSocket {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = 'blob'; this.bufferedAmount = 0; this.queue = Promise.resolve();
      const path = new URL(url).pathname;
      if (!/^\/ws\/(events|(?:session|terminal)\/[A-Za-z0-9_-]+)$/.test(path)) throw Error('Unsupported socket.');
      this.run(path).catch(() => { this.onError(); this.finish(1006); });
    }
    onError() { this.onerror?.(new Event('error')); }
    async run(path) {
      const tunnel = await getTunnel(); if (this.readyState !== 0) return;
      const stream = await tunnel.open(); this.stream = stream;
      if (this.readyState !== 0) { stream.reset(); return; }
      const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
      await stream.write(bytes('GET ' + path + ' HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ' + key + '\r\n\r\n'));
      const reader = new Reader(stream), head = await deadline(reader.head());
      const expected = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest('SHA-1', bytes(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')))));
      if (head.status !== 101 || head.headers.get('sec-websocket-accept') !== expected) throw Error('Socket refused.');
      this.readyState = 1; this.onopen?.(new Event('open'));
      let fragments = [], fragmentSize = 0, fragmentOp = 0;
      while (this.readyState === 1) {
        const prefix = await reader.take(2), op = prefix[0] & 15, final = !!(prefix[0] & 128);
        if ((prefix[0] & 112) || (prefix[1] & 128)) throw Error('Invalid WebSocket frame.');
        let length = prefix[1] & 127;
        if (length === 126) length = new DataView((await reader.take(2)).buffer).getUint16(0);
        else if (length === 127) {
          const wide = new DataView((await reader.take(8)).buffer);
          if (wide.getUint32(0)) throw Error('Message too large.'); length = wide.getUint32(4);
        }
        if (op >= 8 && (!final || length > 125)) throw Error('Invalid control frame.');
        const payload = await reader.take(length);
        if (op === 8) { this.finish(1000); return; }
        if (op === 9) { this.enqueue(10, payload); continue; }
        if (op === 10) continue;
        if (op !== 0 && op !== 1 && op !== 2 || (op === 0 ? !fragmentOp : fragmentOp !== 0)) throw Error('Invalid fragmentation.');
        if (op) fragmentOp = op;
        fragmentSize += length;
        if (fragmentSize > bounds.response || fragments.length >= 4096) throw Error('Message too large.');
        fragments.push(payload);
        if (final) {
          const data = join(fragments);
          this.onmessage?.({ data: fragmentOp === 1 ? decoder.decode(data) : this.binaryType === 'arraybuffer' ? data.buffer : new Blob([data]) });
          fragments = []; fragmentSize = 0; fragmentOp = 0;
        }
      }
    }
    enqueue(op, payload) {
      if (this.bufferedAmount + payload.length > bounds.queued) { this.onError(); this.finish(1006); return; }
      this.bufferedAmount += payload.length;
      this.queue = this.queue.then(() => this.stream.write(webSocketFrame(op, payload)))
        .catch(() => this.finish(1006)).finally(() => { this.bufferedAmount -= payload.length; });
    }
    send(value) {
      if (this.readyState !== 1) throw new DOMException('Socket is not open', 'InvalidStateError');
      this.enqueue(typeof value === 'string' ? 1 : 2, bytes(value));
    }
    close() { this.finish(1000); }
    finish(code) {
      if (this.readyState === 3) return; this.readyState = 3; this.stream?.reset();
      this.onclose?.({ code, reason: '', wasClean: code === 1000 });
    }
  };
}
