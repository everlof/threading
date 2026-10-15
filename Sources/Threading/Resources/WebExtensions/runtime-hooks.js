/* Embedded inside diagnostics.js in a disposable build. Never records API arguments or messages. */
(({api, runtime, emit, text, contextID, traceMessages, relay}) => {
  if (!runtime) return;
  const ports = new WeakSet();
  let sequence = 0;
  const observePort = (port, label) => {
    if (!port || ports.has(port) || port.name === relay.name) return port;
    ports.add(port);
    const identity = `${contextID}/port-${++sequence}`;
    const stack = new Error().stack || '';
    emit('debug', 'port-connected', `${label} ${identity}`, stack);
    const send = port.postMessage.bind(port), disconnect = port.disconnect.bind(port);
    port.postMessage = (...args) => {
      try {
        const result = send(...args);
        emit('debug', 'port-sent', `${label} ${identity}`, new Error().stack || '');
        return result;
      } catch (error) { emit('error', 'port-failed', `${label} ${identity}: ${text(error)}`, stack); throw error; }
    };
    port.disconnect = (...args) => {
      const result = disconnect(...args);
      emit('debug', 'port-disconnected', `${label} ${identity} (local)`, stack);
      return result;
    };
    port.onMessage.addListener(() => emit('debug', 'port-received', `${label} ${identity}`));
    port.onDisconnect.addListener(() => {
      const error = runtime.lastError?.message || port.error?.message;
      emit(error ? 'error' : 'debug', error ? 'port-failed' : 'port-disconnected',
        `${label} ${identity}${error ? ': ' + error : ' (remote)'}`, stack);
    });
    return port;
  };
  for (const [owner, key, label] of [[runtime, 'connect', 'runtime.connect'],
      [runtime, 'connectNative', 'runtime.connectNative'], [api.tabs, 'connect', 'tabs.connect']]) {
    if (!owner?.[key]) continue;
    const original = owner[key].bind(owner);
    owner[key] = (...args) => {
      try { return observePort(original(...args), label); }
      catch (error) { emit('error', 'port-failed', `${label}: ${text(error)}`, new Error().stack || ''); throw error; }
    };
  }
  runtime.onConnect?.addListener(port => observePort(port, 'runtime.onConnect'));
  runtime.onConnectExternal?.addListener(port => observePort(port, 'runtime.onConnectExternal'));

  // Prepend the same isolated-world hook for file injections. A function injection needs one
  // preflight in the exact target before the caller's unchanged function is sent to the browser.
  // The callback path still returns undefined; the Promise path still returns the original result.
  const scripting = api.scripting;
  if (scripting?.executeScript) {
    const execute = scripting.executeScript.bind(scripting);
    scripting.executeScript = (details, callback) => {
      if (!details || typeof details !== 'object') return execute(details, callback);
      const main = details.world === 'MAIN';
      const hook = main ? 'threading_main.js' : 'threading_diagnostics.js';
      const invoke = () => {
        const value = Array.isArray(details.files) ? {...details, files: [hook, ...details.files]} : details;
        return callback ? execute(value, callback) : execute(value);
      };
      if (!main && Array.isArray(details.files)) return invoke();
      const prepare = async () => {
        try {
          // MAIN scripts cannot access runtime. Install their credential-free relay receiver in
          // the extension's isolated world first. Registration does the same using a companion.
          if (main) await execute({target: details.target, files: ['threading_diagnostics.js'], injectImmediately: true});
          if (!Array.isArray(details.files)) await execute({target: details.target, files: [hook],
            ...(details.world ? {world: details.world} : {}), injectImmediately: true});
        } catch (error) { emit('warning', 'instrumentation-gap', `Injection preflight: ${text(error)}`); }
      };
      const result = prepare().then(invoke);
      if (callback) { result.catch(error => emit('error', 'api-failed', `scripting.executeScript: ${text(error)}`)); return; }
      return result;
    };
  }
  // Registered isolated scripts keep their IDs and browser lifecycle. MAIN registrations are
  // left intact: a hidden companion ID would change get/update/unregister semantics.
  for (const method of ['registerContentScripts', 'updateContentScripts']) {
    if (!scripting?.[method]) continue;
    const original = scripting[method].bind(scripting);
    scripting[method] = (scripts, ...rest) => {
      if (!Array.isArray(scripts) || scripts.length > 256) return original(scripts, ...rest);
      const instrumented = scripts.map(script => {
        if (!script || !Array.isArray(script.js)) return script;
        if (script.world === 'MAIN' || (method === 'updateContentScripts' && script.world !== 'ISOLATED')) {
          emit('warning', 'instrumentation-gap', 'Registered MAIN scripts and updates without an explicit isolated world require native inspection.');
          return script;
        }
        return {...script, js: ['threading_diagnostics.js', ...script.js.filter(path => path !== 'threading_diagnostics.js')]};
      });
      return original(instrumented, ...rest);
    };
  }
  // A fixed allowlist bounds installation work and keeps arbitrary API properties/getters out.
  for (const [namespace, methods] of Object.entries({
    scripting: ['executeScript', 'registerContentScripts', 'updateContentScripts', 'unregisterContentScripts'],
    permissions: ['request', 'remove', 'contains'],
    declarativeNetRequest: ['updateDynamicRules', 'updateSessionRules', 'updateEnabledRulesets', 'testMatchOutcome'],
    offscreen: ['createDocument', 'closeDocument'],
    downloads: ['download', 'cancel'], sidePanel: ['open', 'setOptions'], sidebarAction: ['open', 'close'],
  })) for (const method of methods) traceMessages(api[namespace], method, `${namespace}.${method}`, 'api');
  traceMessages(api.proxy?.settings, 'set', 'proxy.settings.set', 'api');
  traceMessages(api.proxy?.settings, 'clear', 'proxy.settings.clear', 'api');
  for (const name of ['onAdded', 'onRemoved']) api.permissions?.[name]?.addListener(() =>
    emit('info', 'permission-change', `permissions.${name}`));
  for (const name of ['onInstalled', 'onStartup', 'onSuspend', 'onSuspendCanceled']) runtime[name]?.addListener(() =>
    emit('info', 'lifecycle', `runtime.${name}`));
})
