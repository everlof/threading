const api = globalThis.browser || chrome;
api.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === 'ping') reply({text: 'background-ready'});
});
api.runtime.onConnect.addListener(port => {
  if (port.name !== 'coverage-echo') return;
  port.onMessage.addListener(message => port.postMessage(message));
});
console.info('coverage-background-started');
