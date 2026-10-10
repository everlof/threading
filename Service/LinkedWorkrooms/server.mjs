import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';

const exec = promisify(execFile);
const maxBodyBytes = 36_000;
const tokenLifetimeMs = 24 * 60 * 60 * 1000;
const maxPDFBytes = 2_000_000;
const pdfRenderer = fileURLToPath(new URL('./render_pdf.py', import.meta.url));
const css = `
  :root{font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;color:#182431;background:#edf2f5}
  *{box-sizing:border-box}body{margin:0}a{color:#165d78}main{max-width:960px;margin:0 auto;padding:32px 20px 80px}
  header{display:flex;justify-content:space-between;align-items:baseline;gap:16px;margin-bottom:32px}
  h1{font-size:1.8rem;letter-spacing:-.035em;margin:0}h2{font-size:1.2rem;margin:0 0 14px}
  h3{font-size:1rem;margin:0 0 8px}p{line-height:1.55}small,.quiet{color:#526474}
  .eyebrow{font-size:.75rem;text-transform:uppercase;letter-spacing:.11em;color:#536878;font-weight:700}
  .card{background:white;border:1px solid #ced9df;border-radius:14px;padding:22px;margin:0 0 18px;box-shadow:0 3px 14px #2037440a}
  .row{display:flex;justify-content:space-between;align-items:start;gap:20px}.stack>*+*{margin-top:12px}
  label{display:block;font-weight:650;margin:12px 0 6px}input,textarea,select{font:inherit;width:100%;border:1px solid #a6bac4;border-radius:8px;padding:10px;background:white;color:inherit}
  textarea{min-height:100px;resize:vertical}input:focus,textarea:focus,select:focus{outline:3px solid #99d6e9;outline-offset:1px}
  button,.button{font:inherit;font-weight:700;color:white;background:#155e74;border:0;border-radius:8px;padding:10px 16px;cursor:pointer;display:inline-block;text-decoration:none}
  button:hover,.button:hover{background:#0d495e;color:white}.secondary{background:#dce8ec;color:#19475a}.secondary:hover{background:#cadce2;color:#19475a}
  .question{border-top:1px solid #d7e1e5;padding-top:18px;margin-top:18px}.question:first-child{border-top:0;padding-top:0;margin-top:0}
  .pill{font-size:.78rem;font-weight:700;display:inline-block;background:#e2f3ed;color:#15624a;padding:4px 9px;border-radius:999px}
  .pill.open{background:#fff0cf;color:#765012}ul{padding-left:21px}li{margin:9px 0;line-height:1.45}
  .error{border-color:#b54a43;background:#fff4f1}.answer{white-space:pre-wrap;border-left:3px solid #53a087;padding-left:12px}
  .pre{white-space:pre-wrap;overflow-wrap:anywhere}.token{font-family:ui-monospace,monospace;font-size:.82rem}
  .brief{background:#f4f8fa;border:1px solid #d2e0e6;border-radius:10px;padding:16px 18px;margin:16px 0}
  .brief h4{font-size:.88rem;margin:18px 0 5px}.brief h4:first-child{margin-top:0}.brief p{margin:0}
  @media(max-width:600px){main{padding:20px 14px 60px}.row,header{display:block}.card{padding:17px}}
`;

function escapeHTML(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#39;');
}

function page(title, body, identity) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>${escapeHTML(title)} · Linked Workrooms</title><style>${css}</style></head><body><main>
    <header><div><div class="eyebrow">Threading trial</div><h1>Linked Workrooms</h1></div><small>${escapeHTML(identity)}</small></header>
    ${body}</main></body></html>`;
}

function csrfField(viewer) {
  return `<input type="hidden" name="_csrf" value="${escapeHTML(viewer.csrf)}">`;
}

function presentationHTML(presentation) {
  if (!presentation) return '';
  const choices = presentation.choices?.length ? `<h4>Possible paths</h4><ol>${presentation.choices.map(choice =>
    `<li class="pre">${escapeHTML(choice)}</li>`).join('')}</ol>` : '';
  const sources = presentation.sources?.length ? `<h4>Source notes to verify</h4><ul>${presentation.sources.map(source =>
    `<li class="pre">${escapeHTML(source)}</li>`).join('')}</ul>` : '';
  return `<section class="brief"><h4>Background</h4><p class="pre">${escapeHTML(presentation.context)}</p>${choices}${sources}</section>`;
}

function send(res, status, body, extra = {}) {
  res.writeHead(status, {
    'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
    'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff',
    ...extra,
  });
  res.end(body);
}

function redirect(res, location, cookie) {
  send(res, 303, '', { location, ...(cookie ? { 'set-cookie': cookie } : {}) });
}

function field(body, name, maximum, required = true) {
  const value = String(body.get(name) ?? '').trim();
  if ((required && !value) || Buffer.byteLength(value) > maximum || value.includes('\0')) {
    throw new PortalError(400, `Check ${name} and try again.`);
  }
  return value;
}

async function formBody(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/x-www-form-urlencoded') {
    throw new PortalError(415, 'This form format is not supported.');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBodyBytes) throw new PortalError(413, 'This form is too large.');
    chunks.push(chunk);
  }
  return new URLSearchParams(Buffer.concat(chunks).toString('utf8'));
}

class PortalError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export async function createWorkroomPortal({ database, controller, scope, port = 0 }) {
  if (!database || !controller || !scope) throw new Error('database, controller and scope are required');
  const access = new Map();
  const ownerToken = randomBytes(32).toString('base64url');
  access.set(ownerToken, { role: 'owner', principal: 'person:owner', csrf: randomBytes(32).toString('base64url') });
  let pdfInFlight = 0;

  async function call(command, ...args) {
    try {
      const result = await exec(controller, ['--database', database, command, ...args],
                                { timeout: 10_000, maxBuffer: 1_100_000 });
      return JSON.parse(result.stdout);
    } catch (error) {
      if (error.stderr?.includes('not_found')) throw new PortalError(404, 'This item was not found.');
      if (error.stderr?.includes('forbidden')) throw new PortalError(403, 'This action is not allowed.');
      if (error.stderr?.includes('conflict')) throw new PortalError(409, 'This item changed. Reload and try again.');
      if (error.stderr?.includes('invalid_input')) throw new PortalError(400, 'Check the form and try again.');
      throw error;
    }
  }

  async function withTextFile(text, action) {
    const directory = await mkdtemp(join(tmpdir(), 'threading-workroom-'));
    const path = join(directory, 'input.txt');
    try {
      await writeFile(path, text, { mode: 0o600 });
      return await action(path);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  async function questionPDF(room, question) {
    if (pdfInFlight >= 2) throw new PortalError(429, 'PDF export is busy. Try again.');
    pdfInFlight += 1;
    let directory;
    try {
      directory = await mkdtemp(join(tmpdir(), 'threading-workroom-pdf-'));
      const input = join(directory, 'record.json');
      const output = join(directory, 'question.pdf');
      await writeFile(input, JSON.stringify({ room, question }), { mode: 0o600 });
      await exec('python3', [pdfRenderer, input, output], { timeout: 10_000, maxBuffer: 16_384 });
      const bytes = await readFile(output);
      if (bytes.length > maxPDFBytes) throw new PortalError(413, 'This PDF is too large.');
      return bytes;
    } finally {
      pdfInFlight -= 1;
      if (directory) await rm(directory, { recursive: true, force: true });
    }
  }

  function principal(req) {
    const cookie = req.headers.cookie?.split(';').map(part => part.trim())
      .find(part => part.startsWith('workroom_access='));
    const token = cookie?.slice('workroom_access='.length);
    const value = token ? access.get(token) : undefined;
    if (value?.expiresAt && value.expiresAt < Date.now()) { access.delete(token); return null; }
    return value ?? null;
  }

  function roomAccess(viewer, roomID) {
    if (viewer.role === 'owner' || viewer.roomID === roomID) return;
    throw new PortalError(404, 'This room was not found.');
  }

  async function roomInScope(roomID) {
    const room = await call('room', roomID);
    if (room.scope !== scope) throw new PortalError(404, 'This room was not found.');
    return room;
  }

  const server = createServer(async (req, res) => {
    try {
      const base = `http://127.0.0.1:${server.address().port}`;
      const url = new URL(req.url, base);
      if (req.headers.host !== `127.0.0.1:${server.address().port}` &&
          req.headers.host !== `localhost:${server.address().port}`) {
        throw new PortalError(400, 'Unexpected host.');
      }
      if (req.method === 'GET' && url.pathname.startsWith('/join/')) {
        const token = url.pathname.slice('/join/'.length);
        const viewer = access.get(token);
        if (!viewer || (viewer.expiresAt && viewer.expiresAt < Date.now())) {
          throw new PortalError(403, 'This invitation expired.');
        }
        const cookie = `workroom_access=${token}; HttpOnly; SameSite=Strict; Path=/`;
        redirect(res, viewer.role === 'owner' ? '/' : `/rooms/${viewer.roomID}`, cookie);
        return;
      }
      const viewer = principal(req);
      if (!viewer) {
        send(res, 401, page('Sign in', '<section class="card"><h2>Open an invitation</h2><p>Use the private workroom link you were given.</p></section>', 'Local trial'));
        return;
      }
      let form;
      if (req.method === 'POST') {
        form = await formBody(req);
        if (form.get('_csrf') !== viewer.csrf) throw new PortalError(403, 'This form expired. Reload and try again.');
        const origin = req.headers.origin;
        // The embedded browser may send an opaque Origin; the per-invitation form token is still required.
        if (origin && origin !== 'null' && origin !== base && origin !== `http://localhost:${server.address().port}`) {
          throw new PortalError(403, 'This form came from another site.');
        }
      }
      if (req.method === 'GET' && url.pathname === '/') {
        if (viewer.role !== 'owner') { redirect(res, `/rooms/${viewer.roomID}`); return; }
        const after = Number(url.searchParams.get('after') ?? '0');
        if (!Number.isSafeInteger(after) || after < 0) throw new PortalError(400, 'Invalid page.');
        const rooms = await call('rooms', scope, String(after));
        const cards = rooms.items.map(room => `<section class="card"><h2><a href="/rooms/${escapeHTML(room.id)}">${escapeHTML(room.title)}</a></h2>
          <p>${escapeHTML(room.purpose || 'No brief yet.')}</p><small class="token">${escapeHTML(room.id)}</small></section>`).join('');
        const body = `<section class="card"><h2>New room</h2><p>A room can start without any ticket or document.</p>
          <form method="post" action="/rooms">${csrfField(viewer)}<label for="title">Title</label><input id="title" name="title" maxlength="256" required>
          <label for="purpose">Purpose</label><textarea id="purpose" name="purpose" maxlength="4096"></textarea>
          <p><button>Create room</button></p></form></section><h2>Rooms</h2>${cards || '<p>No rooms yet.</p>'}
          ${rooms.items.length === 50 ? `<p><a href="/?after=${rooms.next}">More rooms →</a></p>` : ''}`;
        send(res, 200, page('Rooms', body, 'Owner'));
        return;
      }
      const pdfMatch = /^\/rooms\/([0-9a-f-]{36})\/questions\/([0-9a-f-]{36})\.pdf$/.exec(url.pathname);
      if (req.method === 'GET' && pdfMatch) {
        const [, roomID, questionID] = pdfMatch;
        roomAccess(viewer, roomID);
        const room = await roomInScope(roomID);
        const question = await call('room-question', roomID, questionID);
        if (viewer.role !== 'owner' && !question.recipients.includes(viewer.principal)) {
          throw new PortalError(404, 'This question was not found.');
        }
        const bytes = await questionPDF(room, question);
        res.writeHead(200, { 'content-type': 'application/pdf', 'content-length': bytes.length,
          'content-disposition': `inline; filename="workroom-question-${questionID}.pdf"`,
          'cache-control': 'no-store', 'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff' });
        res.end(bytes);
        return;
      }
      if (req.method === 'POST' && url.pathname === '/rooms') {
        if (viewer.role !== 'owner') throw new PortalError(403, 'This action is not allowed.');
        const title = field(form, 'title', 256);
        const purpose = field(form, 'purpose', 4_096, false);
        const id = randomUUID();
        await withTextFile(purpose, path => call('room-create', id, scope, title, path));
        redirect(res, `/rooms/${id.toLowerCase()}`);
        return;
      }
      const match = /^\/rooms\/([0-9a-f-]{36})(?:\/(links|invite|answers)\/?)?(?:([0-9a-f-]{36}))?$/.exec(url.pathname);
      if (!match) throw new PortalError(404, 'This page was not found.');
      const [, roomID, action, questionID] = match;
      roomAccess(viewer, roomID);
      const room = await roomInScope(roomID);
      if (req.method === 'POST' && action === 'links' && !questionID) {
        if (viewer.role !== 'owner') throw new PortalError(403, 'This action is not allowed.');
        const kind = field(form, 'kind', 32);
        const provider = field(form, 'provider', 128);
        const target = field(form, 'target', 2_048);
        const label = field(form, 'label', 256);
        const relationship = field(form, 'relationship', 32);
        const displayURL = field(form, 'url', 2_048, false) || '-';
        await call('room-link', roomID, randomUUID(), kind, provider, target, label, relationship, displayURL);
        redirect(res, `/rooms/${roomID}`);
        return;
      }
      if (req.method === 'POST' && action === 'invite' && !questionID) {
        if (viewer.role !== 'owner') throw new PortalError(403, 'This action is not allowed.');
        const name = field(form, 'name', 64);
        if (!/^[a-zA-Z0-9._-]+$/.test(name)) throw new PortalError(400, 'Use letters, numbers, dots, dashes or underscores for the recipient ID.');
        const token = randomBytes(32).toString('base64url');
        access.set(token, { role: 'guest', roomID, principal: `person:${name}`,
                            csrf: randomBytes(32).toString('base64url'), expiresAt: Date.now() + tokenLifetimeMs });
        const link = `${base}/join/${token}`;
        send(res, 200, page('Invitation', `<p><a href="/rooms/${roomID}">← ${escapeHTML(room.title)}</a></p><section class="card">
          <h2>Invitation for ${escapeHTML(name)}</h2><p>Copy this private link. It lasts 24 hours while this trial server runs.</p>
          <input class="token" readonly value="${escapeHTML(link)}"><p class="quiet">Anyone holding this link can answer as ${escapeHTML(name)} in this room.</p></section>`, 'Owner'));
        return;
      }
      if (req.method === 'POST' && action === 'answers' && questionID) {
        const question = await call('room-question', roomID, questionID);
        if (question.answer != null || !question.recipients.includes(viewer.principal)) {
          throw new PortalError(403, 'This question is not addressed to you.');
        }
        const answer = field(form, 'answer', 32_768);
        await withTextFile(answer, path => call('answer', questionID, viewer.principal, '-', path));
        redirect(res, `/rooms/${roomID}`);
        return;
      }
      if (req.method !== 'GET' || action) throw new PortalError(404, 'This page was not found.');
      const after = Number(url.searchParams.get('after') ?? '0');
      const linksAfter = Number(url.searchParams.get('links_after') ?? '0');
      const worksAfter = Number(url.searchParams.get('works_after') ?? '0');
      if (![after, linksAfter, worksAfter].every(value => Number.isSafeInteger(value) && value >= 0)) {
        throw new PortalError(400, 'Invalid page.');
      }
      const questions = viewer.role === 'owner'
        ? await call('room-questions', roomID, String(after))
        : await call('room-questions-for', roomID, viewer.principal, String(after));
      const visibleQuestions = questions.items;
      const linksPage = viewer.role === 'owner' ? await call('room-links', roomID, String(linksAfter)) : null;
      const worksPage = viewer.role === 'owner' ? await call('room-works', roomID, String(worksAfter)) : null;
      const links = linksPage?.items ?? [];
      const works = worksPage?.items ?? [];
      const questionHTML = visibleQuestions.map(q => `<article class="question"><div class="row"><h3>${escapeHTML(q.text)}</h3>
        <span class="pill ${q.answer == null ? 'open' : ''}">${q.answer == null ? 'Open' : 'Answered'}</span></div>
        ${viewer.role === 'owner' ? `<small>To ${escapeHTML(q.recipients.join(', '))}</small>` : ''}
        ${presentationHTML(q.presentation)}
        <p><a href="/rooms/${roomID}/questions/${escapeHTML(q.id)}.pdf">PDF copy</a></p>
        ${q.answer != null ? `<p class="answer">${escapeHTML(q.answer)}</p><small>Answered by ${escapeHTML(q.answeredBy)}</small>` :
          q.recipients.includes(viewer.principal) ? `<form method="post" action="/rooms/${roomID}/answers/${escapeHTML(q.id)}">${csrfField(viewer)}
            <label for="answer-${escapeHTML(q.id)}">Your answer</label><textarea id="answer-${escapeHTML(q.id)}" name="answer" maxlength="32768" required></textarea>
            <p><button>Submit answer</button></p></form>` : '<p class="quiet">Waiting for an answer.</p>'}</article>`).join('');
      const ownerControls = viewer.role === 'owner' ? `<section class="card"><h2>Links</h2>
        ${links.length ? `<ul>${links.map(link => `<li><strong>${escapeHTML(link.label)}</strong> <span class="quiet">${escapeHTML(link.kind)} · ${escapeHTML(link.relationship)}</span>
          ${link.url ? `<a href="${escapeHTML(link.url)}" target="_blank" rel="noopener noreferrer">Open</a>` : ''}</li>`).join('')}</ul>` : '<p>No links yet.</p>'}
        ${links.length === 50 ? `<p><a href="/rooms/${roomID}?after=${after}&links_after=${linksPage.next}&works_after=${worksAfter}">More links →</a></p>` : ''}
        <form method="post" action="/rooms/${roomID}/links">${csrfField(viewer)}<h3>Add a link</h3>
          <label>Kind<select name="kind"><option value="issue">Issue</option><option value="document">Document</option><option value="pullRequest">Pull request</option><option value="supportCase">Support case</option><option value="repository">Repository</option><option value="url">URL</option><option value="other">Other</option></select></label>
          <label>Provider<input name="provider" placeholder="jira, github, web…" maxlength="128" required></label>
          <label>Provider ID or URL<input name="target" maxlength="2048" required></label>
          <label>Label<input name="label" maxlength="256" required></label>
          <label>Relationship<select name="relationship"><option value="context">Context</option><option value="source">Source</option><option value="affected">Affected</option><option value="output">Output</option></select></label>
          <label>Display URL (optional)<input name="url" type="url" maxlength="2048" placeholder="https://…"></label><p><button>Add link</button></p></form></section>
        <section class="card"><h2>Work in this room</h2>
          ${works.length ? `<ul>${works.map(work => `<li><strong>${escapeHTML(work.key)}</strong> <span class="quiet">${escapeHTML(work.state)}</span><br><small>${escapeHTML(work.instruction.slice(0, 240))}${work.instruction.length > 240 ? '…' : ''}</small></li>`).join('')}</ul>` : '<p>No agent work has been linked yet.</p>'}
          ${works.length === 50 ? `<p><a href="/rooms/${roomID}?after=${after}&links_after=${linksAfter}&works_after=${worksPage.next}">More work →</a></p>` : ''}</section>
        <section class="card"><h2>Invite someone</h2><p>Use the person ID that the agent addresses, such as <code>expert</code> for <code>person:expert</code>.</p>
          <form method="post" action="/rooms/${roomID}/invite">${csrfField(viewer)}<label>Person ID<input name="name" maxlength="64" required pattern="[a-zA-Z0-9._-]+"></label><p><button>Make invitation</button></p></form></section>` : '';
      const body = `${viewer.role === 'owner' ? '<p><a href="/">← All rooms</a></p>' : ''}
        <section class="card"><div class="eyebrow">Room</div><h2>${escapeHTML(room.title)}</h2><p class="pre">${escapeHTML(room.purpose || 'No brief yet.')}</p>
        ${viewer.role === 'owner' ? `<small class="token">${escapeHTML(room.id)}</small>` : ''}</section>
        <section class="card"><h2>Questions</h2>${questionHTML || '<p>No questions on this page.</p>'}
        ${questions.items.length === 50 ? `<p><a href="/rooms/${roomID}?after=${questions.next}&links_after=${linksAfter}&works_after=${worksAfter}">More questions →</a></p>` : ''}</section>${ownerControls}`;
      send(res, 200, page(room.title, body, viewer.role === 'owner' ? 'Owner' : viewer.principal));
    } catch (error) {
      const status = error instanceof PortalError ? error.status : 500;
      if (status === 500) console.error(error);
      send(res, status, page('Problem', `<section class="card error"><h2>Could not open this page</h2><p>${escapeHTML(status === 500 ? 'The local service failed. Check its terminal output.' : error.message)}</p></section>`, 'Linked Workrooms'));
    }
  });
  await new Promise((ok, fail) => { server.once('error', fail); server.listen(port, '127.0.0.1', ok); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  return { server, origin, ownerURL: `${origin}/join/${ownerToken}` };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const options = Object.fromEntries(process.argv.slice(2).map((value, index, all) =>
    index % 2 === 0 ? [value, all[index + 1]] : null).filter(Boolean));
  const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
  const controller = options['--controller'] ?? join(root, 'Targets/Controller/.build/debug/threading-controller');
  const database = options['--database'];
  const scope = options['--scope'] ?? 'local';
  if (!database) {
    console.error('Usage: node server.mjs --database ABSOLUTE_PATH [--controller ABSOLUTE_PATH] [--scope NAME]');
    process.exit(2);
  }
  const portal = await createWorkroomPortal({ database, controller, scope });
  console.log(`Open this owner link: ${portal.ownerURL}`);
  console.log('The trial portal listens on loopback only. Keep this process running.');
}
