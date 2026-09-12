import { parseInvitation, connectHosted } from './hosted-connection.mjs';
import { tunnelFetch, socketClass, bytes } from './peer-tunnel.mjs';
// One membership namespace per invitation, never the shared public origin. The browser's device
// id is physical; the service transport id is guest-<shareID>. Neither grants owner access.
const status = document.getElementById('status');
function storageFacade(storage, prefix) {
  const memory = new Map();
  return {
    getItem:key => { try { return storage.getItem(prefix + key) ?? memory.get(key) ?? null; } catch { return memory.get(key) ?? null; } },
    setItem:(key,value) => { try { storage.setItem(prefix + key,value); } catch { memory.set(key,value); } },
    removeItem:key => { memory.delete(key); try { storage.removeItem(prefix + key); } catch {} },
  };
}
// Keep at most 32 durable guest namespaces per public origin. Further invitations still work
// for the current tab; browser storage quotas must not turn into an unbounded membership list.
function guestStorage(key, prefix) {
  const session = storageFacade(window.sessionStorage, prefix);
  try {
    const indexKey = 'threading.hosted.memberships.v1';
    const raw = window.localStorage.getItem(indexKey) || '[]';
    if (raw.length > 4096) return {local:session,session};
    const keys = JSON.parse(raw);
    if (!Array.isArray(keys) || keys.length > 32 || !keys.every(k => /^[a-f0-9]{64}$/.test(k))) return {local:session,session};
    if (!keys.includes(key)) {
      if (keys.length >= 32) return {local:session,session};
      window.localStorage.setItem(indexKey,JSON.stringify([...keys,key]));
    }
    return {local:storageFacade(window.localStorage,prefix),session};
  } catch { return {local:session,session}; }
}
async function start() {
  if (typeof RTCPeerConnection !== 'function') throw Error('This browser does not support direct connections. Open the invitation in a current Safari, Chrome or Firefox.');
  let invitation, key;
  if (location.hash) {
    invitation = parseInvitation(location.hash.slice(1), location.origin, {allowExpired:true});
    key = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes(invitation.h + ':' + invitation.b)))].map(b => b.toString(16).padStart(2,'0')).join('');
  } else key = new URL(location.href).searchParams.get('share');
  if (!/^[a-f0-9]{64}$/.test(key || '')) throw Error('Open the invitation link the sender shared with you.');
  const prefix = 'threading.hosted.' + key + '.';
  let local, session;
  try { ({local,session} = guestStorage(key,prefix)); }
  catch { local = storageFacade(null,prefix); session = local; }
  let saved;
  try { const raw = local.getItem('route'); if (raw && raw.length <= 16384) saved = JSON.parse(raw); } catch {}
  if (saved && (saved.v !== 1 || saved.s !== location.origin || !saved.route || !saved.token || !saved.deviceID)) saved = null;
  if (!saved && invitation && invitation.e * 1000 <= Date.now()) throw Error('This invitation has expired. Ask for a new link.');
  if (!saved && !invitation) throw Error('This browser no longer has that invitation. Open the original link or ask for a new one.');
  let deviceID = saved?.deviceID || crypto.randomUUID();
  let route = saved?.route || invitation, acceptedToken = saved?.token;
  const invitationTransport = !route.d.startsWith('guest-');
  let pending, active, renewal, stopped = false;
  const cancellation = new AbortController();
  window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });
  window.addEventListener('pagehide', () => {
    stopped = true; cancellation.abort(); clearTimeout(renewal); active?.close();
  },{once:true});
  function persist() {
    if (!acceptedToken) return;
    try { local.setItem('route',JSON.stringify({v:1,s:location.origin,route,token:acceptedToken,deviceID})); } catch {}
  }
  async function getTunnel() {
    if (stopped) throw Error('Connection closed.');
    if (active && !active.closed) return active;
    if (pending) return pending;
    pending = connectHosted(route,{signal:cancellation.signal}).then(tunnel => {
      if (stopped) { tunnel.close(); throw Error('Connection closed.'); }
      active = tunnel; return tunnel;
    }).finally(() => { pending = null; });
    return pending;
  }
  const auth = token => ({Authorization:'Bearer '+token,'X-Threading-Device':deviceID,'X-Threading-Protocol':'1','X-Threading-Protocol-Min':'1','X-Threading-Client':'Threading-Web'});
  async function provision(token, shareID) {
    const response = await tunnelFetch(await getTunnel(),'/api/hosted-device-credential',{method:'POST',headers:auth(token)});
    if (!response.ok) throw Error('The Mac could not save this browser connection. Retry while the invitation is still open.');
    const credential = await response.json();
    if (credential.hostID !== route.h || credential.deviceID !== 'guest-' + shareID ||
        typeof credential.credential !== 'string' || !/^[\x21-\x7e]{1,4096}$/.test(credential.credential) ||
        !Number.isFinite(credential.expiresAt)) throw Error('The Mac returned an invalid connection.');
    // RemoteRouter's JSONEncoder uses Foundation's 2001 epoch for Date (the invitation uses Unix).
    const expires = credential.expiresAt + 978307200;
    if (expires * 1000 <= Date.now()) throw Error('The connection credential has expired.');
    route = { ...route, d:credential.deviceID, c:credential.credential, e:expires };
    acceptedToken = token; persist();
    clearTimeout(renewal);
    renewal = setTimeout(() => { provision(token,shareID).catch(() => {}); }, Math.min(2147483647, Math.max(60000, expires * 1000 - Date.now() - 3600000)));
  }
  if (!acceptedToken) {
    acceptedToken = invitation.b;
    persist();
  }
  await getTunnel();
  history.replaceState(null,'',location.pathname + '?share=' + key);
  try { local.setItem('threading.device',deviceID); } catch {}
  window.ThreadingTransport = {
    initialToken:acceptedToken || invitation.b, localStorage:local, sessionStorage:session,
    WebSocket:socketClass(getTunnel),
    fetch:async (path, options) => {
      const response = await tunnelFetch(await getTunnel(),path,options);
      if (path === '/api/invitations/accept' && response.ok) {
        const body = await response.clone().json(), share = body.me?.share;
        if (!body.accessToken || !share?.label || share.scope === 'all') throw Error('This page requires a guest chat invitation.');
        acceptedToken = body.accessToken; persist();
        await provision(body.accessToken, share.label);
        // Move off the one-use invitation transport before the Mac retires it. Existing chat
        // sockets have not started yet, so this switch cannot interrupt a submission.
        if (invitationTransport) { active?.close(); active = null; await getTunnel(); }
      }
      return response;
    },
  };
  const script = document.createElement('script'); script.src = '/join/assets/app.js';
  document.body.appendChild(script);
}
start().catch(error => {
  status.textContent = error.message || 'Could not connect. Try opening the invitation again.';
  const retry = document.createElement('button'); retry.type='button'; retry.className='connection-retry'; retry.textContent='Try again';
  retry.onclick = () => location.reload(); status.append(document.createElement('br'),retry);
});
