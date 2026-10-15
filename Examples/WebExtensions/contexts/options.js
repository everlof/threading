const api = globalThis.browser || chrome;
document.querySelector('#ping').addEventListener('click', async () => {
  document.querySelector('#ping-result').textContent = (await api.runtime.sendMessage({type: 'ping'})).text;
});
document.querySelector('#storage').addEventListener('click', async () => {
  document.querySelector('#storage-result').textContent = (await api.storage.local.get('coverage')).coverage || 'empty';
});
document.querySelector('#exercise').addEventListener('click', async () => {
  try {
    const tabs = await api.tabs.query({});
    const tab = tabs.find(item => item.url?.startsWith('http://127.0.0.1:'));
    if (!tab) throw new Error('Open the fixture page first.');
    await api.storage.local.set({coverage: 'retained'});
    await new Promise((resolve, reject) => {
      const port = api.runtime.connect({name: 'coverage-echo'});
      const timer = setTimeout(() => reject(Error('Port reply timed out')), 5000);
      port.onMessage.addListener(message => {
        if (message !== 'coverage-private-payload') return reject(Error('Port reply changed'));
        clearTimeout(timer); port.disconnect(); resolve();
      });
      port.postMessage('coverage-private-payload');
    });
    await api.scripting.executeScript({target: {tabId: tab.id, allFrames: true}, files: ['dynamic.js']});
    const returned = await api.scripting.executeScript({target: {tabId: tab.id}, func: () => {
      console.info('coverage-dynamic-function'); return 42;
    }});
    if (returned[0].result !== 42) throw Error('Function result changed');
    const mainResult = await api.scripting.executeScript({target: {tabId: tab.id}, world: 'MAIN', func: () => {
      console.info('coverage-dynamic-main'); return 43;
    }});
    if (mainResult[0].result !== 43) throw Error('MAIN function result changed');
    // Chromium supports both callbacks and Promises. Firefox's browser namespace is Promise-only.
    if (!globalThis.browser) await new Promise((resolve, reject) => {
      const result = api.scripting.executeScript({target: {tabId: tab.id}, func: () => 44}, results => {
        if (api.runtime.lastError) return reject(Error(api.runtime.lastError.message));
        results[0].result === 44 ? resolve() : reject(Error('Callback result changed'));
      });
      if (result !== undefined) reject(Error('Callback return changed'));
    });
    await api.scripting.unregisterContentScripts({ids: ['coverage-registered']}).catch(() => {});
    await api.scripting.registerContentScripts([{id: 'coverage-registered', matches: ['http://127.0.0.1/*'],
      js: ['registered.js'], runAt: 'document_idle', allFrames: true}]);
    await api.permissions.contains({permissions: ['storage']});
    try { await api.runtime.sendNativeMessage('codes.threading.coverage_missing', {secret: 'coverage-private-payload'}); }
    catch { /* Missing-host failure is expected; no native host is installed by this fixture. */ }
    await new Promise(resolve => {
      const port = api.runtime.connectNative('codes.threading.coverage_missing');
      port.onDisconnect.addListener(() => { void api.runtime.lastError; resolve(); });
    });
    const blocked = new URL('/fixture?blocked=1', tab.url).href;
    await api.declarativeNetRequest.updateDynamicRules({removeRuleIds: [91], addRules: [{id: 91, priority: 1,
      action: {type: 'block'}, condition: {urlFilter: '|' + blocked + '|', resourceTypes: ['xmlhttprequest']}}]});
    let rejected = false;
    try { await fetch(blocked); } catch { rejected = true; }
    if (!rejected) throw Error('Request rule did not block the fixture request');
    await api.declarativeNetRequest.updateDynamicRules({removeRuleIds: [91]});
    await new Promise(resolve => {
      const xhr = new XMLHttpRequest(); xhr.open('GET', new URL('/missing-xhr', tab.url));
      xhr.addEventListener('loadend', resolve, {once: true}); xhr.send();
    });
    if (api.offscreen) {
      if (await api.offscreen.hasDocument()) await api.offscreen.closeDocument();
      await api.offscreen.createDocument({url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'Exercise local diagnostic capture'});
    }
    document.querySelector('#result').textContent = 'coverage-passed';
  } catch (error) {
    console.error('coverage-exercise-failed', error);
    document.querySelector('#result').textContent = 'failed: ' + error.message;
  }
});
