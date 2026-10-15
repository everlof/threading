import {message} from './value.js';
const api = globalThis.browser || chrome;
api.runtime.onMessage.addListener((request, sender, reply) => { if (request.type === 'ping') reply(message); });
console.error('coverage-module-background-error');
