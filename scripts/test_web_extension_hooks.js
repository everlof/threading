#!/usr/bin/env node
// Protocol invariants that are awkward to force reliably in a real browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const resources = path.join(__dirname, '../Sources/Threading/Resources/WebExtensions');

function bridge() {
  const events = [], listeners = {}, timers = [], window = {};
  const port = {onDisconnect: {addListener() {}}, disconnect() {}, postMessage(value) { events.push(...value.events); }};
  const sandbox = {
    window, document: {}, location: {href: 'http://fixture.test'},
    chrome: {runtime: {connect: () => port}},
    fetch: async () => ({ok: true}), performance: {now: () => 0},
    console: Object.fromEntries(['debug', 'log', 'info', 'warn', 'error', 'trace'].map(key => [key, () => {}])),
    setTimeout(fn) { timers.push(fn); return timers.length; }, clearTimeout() {},
    addEventListener(name, fn) { listeners[name] = fn; },
  };
  const source = fs.readFileSync(path.join(resources, 'diagnostics.js'), 'utf8').replace('__THREADING_CONFIG__',
    JSON.stringify({context: 'content-script', channel: 'public-channel', token: 'private-token', build: 'host-build'}));
  vm.runInNewContext(source, sandbox);
  function send(source, event) {
    listeners.message({source, data: {threadingChannel: 'public-channel', event}});
  }
  send({}, {message: 'wrong-window', kind: 'console'});
  send(window, {message: 'accepted', kind: 'console', level: 'error', build: 'forged-build', context: 'background', contextID: 'forged-id'});
  timers[0]();
  assert.equal(events.some(event => event.message === 'wrong-window'), false);
  const accepted = events.find(event => event.message === 'accepted');
  assert.equal(accepted.context, 'main-world-untrusted');
  assert.equal(accepted.build, 'host-build');
  assert.notEqual(accepted.contextID, 'forged-id');
  assert.equal(events.some(event => JSON.stringify(event).includes('private-token')), false);
}

async function runtimeHooks() {
  const calls = [], events = [], portListeners = {};
  const payload = {secret: 'private-payload'};
  const port = {
    name: 'application-port',
    postMessage(value) { assert.equal(value, payload); return 'sent'; },
    disconnect() { return 'closed'; },
    onMessage: {addListener(fn) { portListeners.message = fn; }},
    onDisconnect: {addListener(fn) { portListeners.disconnect = fn; }},
  };
  const api = {runtime: {connect: () => port}, scripting: {
    executeScript(details, callback) {
      calls.push(details);
      if (details.files?.includes('threading_diagnostics.js') && details.target.tabId === -1) return Promise.reject(Error('preflight refused'));
      if (callback) { callback([{result: 42}]); return; }
      return Promise.resolve([{result: 42}]);
    },
    registerContentScripts(scripts) { calls.push(scripts); return Promise.resolve('registered'); },
    updateContentScripts(scripts) { calls.push(scripts); return Promise.resolve('updated'); },
  }};
  vm.runInNewContext(fs.readFileSync(path.join(resources, 'runtime-hooks.js'), 'utf8'))({
    api, runtime: api.runtime, emit: (...args) => events.push(args), text: String,
    contextID: 'owned', traceMessages() {}, relay: {name: 'threading-diagnostics'},
  });
  const func = () => 42, target = {tabId: 1};
  const result = await api.scripting.executeScript({target, func});
  assert.equal(result[0].result, 42);
  assert.equal(calls[0].target, target);
  assert.equal(calls[1].func, func);
  let complete;
  const callbackDone = new Promise(resolve => { complete = resolve; });
  const callbackResult = api.scripting.executeScript({target, func}, value => { assert.equal(value[0].result, 42); complete(); });
  assert.equal(callbackResult, undefined);
  await callbackDone;
  calls.length = 0;
  await api.scripting.executeScript({target, world: 'MAIN', func});
  assert.equal(calls.length, 3);
  assert.equal(calls[0].world, undefined);
  assert.equal(calls[1].world, 'MAIN');
  assert.equal(calls[1].files[0], 'threading_main.js');
  assert.equal(calls[2].func, func);
  calls.length = 0;
  await api.scripting.executeScript({target: {tabId: -1}, func});
  assert.equal(calls[1].func, func, 'A refused hook must not suppress the application injection');
  assert(events.some(event => event[1] === 'instrumentation-gap'));
  const main = {id: 'main', world: 'MAIN', js: ['app.js']};
  const unknownWorld = {id: 'existing', js: ['app.js']};
  const isolated = {id: 'isolated', js: ['app.js']};
  calls.length = 0;
  await api.scripting.registerContentScripts([main, isolated]);
  assert.equal(calls[0][0], main, 'MAIN registration must never receive the private hook');
  assert.equal(calls[0][1].id, isolated.id);
  assert.equal(calls[0][1].js[0], 'threading_diagnostics.js');
  assert.deepEqual(isolated.js, ['app.js'], 'Caller-owned details must remain unchanged');
  await api.scripting.updateContentScripts([unknownWorld]);
  assert.equal(calls[1][0], unknownWorld, 'An update may refer to an existing MAIN registration');
  const observed = api.runtime.connect({name: 'application-port'});
  assert.equal(observed, port);
  assert.equal(observed.postMessage(payload), 'sent');
  portListeners.message(payload);
  assert.equal(observed.disconnect(), 'closed');
  assert.equal(JSON.stringify(events).includes('private-payload'), false);
  assert(events.some(event => event[1] === 'port-received'));
}

(async () => {
  bridge();
  await runtimeHooks();
  process.stdout.write('PASS public-world provenance, callback/Promise injection, safe registration updates and port payload privacy\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
