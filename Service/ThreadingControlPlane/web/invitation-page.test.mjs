import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { transform } from 'esbuild';

// Exercise the script in the served page, rather than a second copy of its decoder.
const source = await readFile(new URL('../src/invitation-page.ts', import.meta.url), 'utf8');
const { code } = await transform(source, { loader: 'ts', format: 'esm' });
const { invitationPage } = await import('data:text/javascript;base64,' + Buffer.from(code).toString('base64'));
const html = await invitationPage().text();
const script = html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/)?.[1];
assert.ok(script, 'the shipping page must contain its handoff script');

function openPage(fragment, overrides = {}) {
  const elements = new Map(['open', 'browser', 'message', 'help', 'network', 'h1'].map(id =>
    [id, { hidden: ['open', 'browser', 'network'].includes(id), href: '', textContent: '' }]));
  runInNewContext(script, {
    URL, atob, decodeURIComponent,
    location: { hash: '#' + fragment, href: 'https://remote.threading.codes/join#' + fragment },
    document: {
      getElementById: id => elements.get(id),
      querySelector: selector => elements.get(selector),
    },
    ...overrides,
  }, { timeout: 1000 });
  return elements;
}

const appPayload = 'THREADING://PAIR#' + Buffer.from(JSON.stringify({
  v: 1, s: 'https://remote.threading.codes', h: 'host', d: 'invite-chat',
  c: 'transport-only', b: 'chat-only', e: Date.now() / 1000 + 3600,
})).toString('base64url');
const fragment = Buffer.from(appPayload).toString('base64url');
const escaped = [...fragment].map((character, index) => index % 128 === 0
  ? '%' + character.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0')
  : character).join('');

for (const [name, encoded] of [['legacy', fragment], ['percent-encoded', escaped]]) {
  test(`${name} invitation hands the identical authority to the app and browser`, () => {
    const elements = openPage(encoded);
    assert.equal(elements.get('open').hidden, false);
    assert.equal(elements.get('open').href, appPayload);
    assert.equal(elements.get('browser').hidden, false);
    assert.equal(elements.get('browser').href, '/join/chat#' + fragment);
  });
}

test('malformed URL escapes do not expose either handoff', () => {
  const elements = openPage('%E0%A4%ZZ');
  assert.equal(elements.get('open').hidden, true);
  assert.equal(elements.get('browser').hidden, true);
  assert.equal(elements.get('h1').textContent, 'This invitation is incomplete');
});

test('the URL bound is checked before decoding externally sized content', () => {
  let decodes = 0;
  const elements = openPage('A'.repeat(8192), {
    decodeURIComponent: () => { decodes++; throw Error('oversized input must not be decoded'); },
  });
  assert.equal(decodes, 0);
  assert.equal(elements.get('open').hidden, true);
  assert.equal(elements.get('browser').hidden, true);
});
