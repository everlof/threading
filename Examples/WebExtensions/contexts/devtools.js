const api = globalThis.browser || chrome;
api.devtools.panels.create('Threading Coverage', '', 'options.html');
console.error('coverage-devtools-error');
