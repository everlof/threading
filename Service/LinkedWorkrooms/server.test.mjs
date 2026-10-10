import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createWorkroomPortal } from './server.mjs';

const exec = promisify(execFile);
const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const controller = join(root, 'Targets/Controller/.build/debug/threading-controller');

test('an unlinked room gains a question, and its named guest can answer only there', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'linked-workrooms-test-'));
  const database = join(directory, 'controller.db');
  const call = async (command, ...args) => {
    const result = await exec(controller, ['--database', database, command, ...args]);
    return JSON.parse(result.stdout);
  };
  const put = async (name, text) => {
    const path = join(directory, name);
    await writeFile(path, text);
    return path;
  };
  const portal = await createWorkroomPortal({ database, controller, scope: 'sonda' });
  try {
    const joinOwner = await fetch(portal.ownerURL, { redirect: 'manual' });
    assert.equal(joinOwner.status, 303);
    const ownerCookie = joinOwner.headers.get('set-cookie').split(';')[0];
    const ownerPage = await fetch(portal.origin, { headers: { cookie: ownerCookie } });
    const ownerHTML = await ownerPage.text();
    assert.match(ownerHTML, /New room/);
    const ownerCSRF = ownerHTML.match(/name="_csrf" value="([A-Za-z0-9_-]+)"/)?.[1];
    assert.ok(ownerCSRF);

    const create = await fetch(`${portal.origin}/rooms`, {
      method: 'POST', redirect: 'manual', headers: { cookie: ownerCookie, origin: 'null',
        'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ _csrf: ownerCSRF, title: 'Classification choice', purpose: 'Ask the domain expert' }),
    });
    assert.equal(create.status, 303);
    const roomPath = create.headers.get('location');
    const roomID = roomPath.split('/').at(-1);
    assert.equal((await call('room', roomID)).title, 'Classification choice');
    assert.equal((await call('room-links', roomID)).items.length, 0);

    const missingToken = await fetch(`${portal.origin}${roomPath}/invite`, {
      method: 'POST', headers: { cookie: ownerCookie, origin: portal.origin,
        'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ name: 'uninvited' }),
    });
    assert.equal(missingToken.status, 403);

    const workerID = randomUUID();
    await call('worker-add', workerID, 'Trial agent');
    const work = await call('room-enqueue', roomID, workerID, 'first', await put('instruction.txt', 'Ask the expert'));
    assert.equal(work.workroomID, roomID);
    const claim = await call('claim', workerID);
    const questionID = randomUUID();
    const presentation = { context: 'Compare <old> and <new> interpretations.',
      choices: ['Keep the current rule', 'Adopt the proposed rule'],
      sources: ['SONDA-123 description; verify before deciding'] };
    await call('ask', claim.execution.id, questionID, 'person:expert',
      await put('question.txt', 'Which rule applies?'), await put('checkpoint.txt', 'Analysis ready'),
      await put('presentation.json', JSON.stringify(presentation)));

    const invitation = await fetch(`${portal.origin}${roomPath}/invite`, {
      method: 'POST', headers: { cookie: ownerCookie, origin: portal.origin,
        'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ _csrf: ownerCSRF, name: 'expert' }),
    });
    assert.equal(invitation.status, 200);
    const invitationHTML = await invitation.text();
    const invitePath = invitationHTML.match(/\/join\/[A-Za-z0-9_-]+/)?.[0];
    assert.ok(invitePath);
    const joinGuest = await fetch(`${portal.origin}${invitePath}`, { redirect: 'manual' });
    const guestCookie = joinGuest.headers.get('set-cookie').split(';')[0];
    const guestPage = await fetch(`${portal.origin}${roomPath}`, { headers: { cookie: guestCookie } });
    const guestHTML = await guestPage.text();
    assert.match(guestHTML, /Which rule applies\?/);
    assert.match(guestHTML, /Possible paths/);
    assert.match(guestHTML, /&lt;old&gt;/);
    assert.doesNotMatch(guestHTML, /Compare <old>/);
    const pdf = await fetch(`${portal.origin}${roomPath}/questions/${questionID}.pdf`,
      { headers: { cookie: guestCookie } });
    assert.equal(pdf.status, 200);
    assert.match(pdf.headers.get('content-type'), /application\/pdf/);
    assert.equal(Buffer.from(await pdf.arrayBuffer()).subarray(0, 5).toString(), '%PDF-');
    await call('room-enqueue', roomID, workerID, 'owner-only', await put('owner-instruction.txt', 'Ask the owner'));
    const ownerClaim = await call('claim', workerID);
    const ownerQuestionID = randomUUID();
    await call('ask', ownerClaim.execution.id, ownerQuestionID, 'person:owner',
      await put('owner-question.txt', 'Private owner question'), await put('owner-checkpoint.txt', 'Waiting'));
    const hiddenPDF = await fetch(`${portal.origin}${roomPath}/questions/${ownerQuestionID}.pdf`,
      { headers: { cookie: guestCookie } });
    assert.equal(hiddenPDF.status, 404);
    const refreshedGuest = await fetch(`${portal.origin}${roomPath}`, { headers: { cookie: guestCookie } });
    assert.doesNotMatch(await refreshedGuest.text(), /Private owner question/);
    assert.doesNotMatch(guestHTML, /Add a link/);
    const guestCSRF = guestHTML.match(/name="_csrf" value="([A-Za-z0-9_-]+)"/)?.[1];
    assert.ok(guestCSRF);

    const crossRoom = await call('room-create', randomUUID(), 'sonda', 'Other room', await put('purpose.txt', 'Separate'));
    const forbidden = await fetch(`${portal.origin}/rooms/${crossRoom.id}`, { headers: { cookie: guestCookie } });
    assert.equal(forbidden.status, 404);
    const forged = await fetch(`${portal.origin}${roomPath}/answers/${questionID}`, {
      method: 'POST', redirect: 'manual', headers: { cookie: guestCookie, origin: 'https://evil.example',
        'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ _csrf: guestCSRF, answer: 'Forged' }),
    });
    assert.equal(forged.status, 403);

    const answer = await fetch(`${portal.origin}${roomPath}/answers/${questionID}`, {
      method: 'POST', redirect: 'manual', headers: { cookie: guestCookie, origin: portal.origin,
        'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ _csrf: guestCSRF, answer: 'Use the existing rule' }),
    });
    assert.equal(answer.status, 303);
    assert.equal((await call('room-question', roomID, questionID)).answer, 'Use the existing rule');
    assert.deepEqual((await call('room-open-questions', roomID)).items.map(item => item.id), [ownerQuestionID]);
  } finally {
    await new Promise(resolve => portal.server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
});
