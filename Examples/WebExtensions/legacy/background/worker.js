browser.runtime.onMessage.addListener((request, sender, reply) => { if (request.type === 'ping') reply('legacy-ready'); });
console.error('coverage-legacy-background-error');
