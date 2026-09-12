import { parseEnvelope, encodeEnvelope } from '../src/protocol.ts';
import { Tunnel, deadline, bytes } from './peer-tunnel.mjs';
export function base64url(value) {
  return btoa(String.fromCharCode(...bytes(value))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
}
export function decode64(value) {
  if (typeof value !== 'string' || !value || value.length > 8192 || !/^[A-Za-z0-9_-]+$/.test(value)) throw Error('Invalid invitation.');
  return new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')), c => c.charCodeAt(0)));
}
export function parseInvitation(fragment, origin, { allowExpired = false } = {}) {
  const link = new URL(decode64(fragment));
  if (link.protocol !== 'threading:' || link.hostname.toLowerCase() !== 'pair' || link.pathname || link.search || link.username || link.password || link.port) throw Error('This invitation needs a private network.');
  const p = JSON.parse(decode64(link.hash.slice(1)));
  const service = new URL(p.s);
  if (service.origin !== origin || service.pathname !== '/' || service.search || service.hash || service.username || service.password) throw Error('Open this invitation on its original Threading service.');
  if (p.v !== 1 || ![p.h,p.d].every(v => typeof v === 'string' && /^[A-Za-z0-9._:-]{1,256}$/.test(v)) ||
      ![p.c,p.b].every(v => typeof v === 'string' && /^[\x21-\x7e]{1,4096}$/.test(v)) ||
      !Number.isFinite(p.e) || (!allowExpired && p.e * 1000 <= Date.now()) || p.e * 1000 > Date.now() + 370 * 86400000) throw Error('This invitation has expired or is invalid. Ask for a new link.');
  return p;
}
export async function connectHosted(route, { signalURL, WebSocketClass = WebSocket, PeerClass = RTCPeerConnection, signal } = {}) {
  if (signal?.aborted) throw new DOMException('Aborted','AbortError');
  const url = signalURL || location.origin.replace(/^http/, 'ws') + '/join/rendezvous';
  const socket = new WebSocketClass(url, ['threading.rendezvous.v1', 'threading.auth.' + base64url(route.c)]);
  socket.binaryType = 'arraybuffer';
  let peer, tunnel, sessionID, answer = false, localDone = false, remoteDone = false, offered = false;
  let localCount = 0, remoteCount = 0, pendingCandidates = [], signalChain = Promise.resolve(), queuedSignals = 0;
  let resolve, reject, connected = false, stopped = false;
  const ready = new Promise((a,b) => { resolve=a; reject=b; });
  const send = value => {
    if (socket.readyState !== 1 || socket.bufferedAmount > 512 * 1024) throw Error('Signaling unavailable.');
    socket.send(encodeEnvelope({ version: 1, ...value }));
  };
  const fail = (error = new Error('Could not connect. Check that the Mac is online and try again.')) => {
    if (stopped) return; stopped = true; reject(error); socket.close(); tunnel?.close(); peer?.close();
  };
  const abort = () => fail(new DOMException('Aborted','AbortError'));
  signal?.addEventListener('abort',abort,{once:true});
  const finishSignals = () => {
    if (localDone && remoteDone && socket.readyState === 1) {
      send({kind:'close',sessionID}); socket.close();
    }
  };
  const candidate = event => {
    try {
      if (!event.candidate) { localDone = true; if (offered) send({kind:'candidatesComplete',sessionID}); finishSignals(); return; }
      if (++localCount > 64) throw Error('Too many network candidates.');
      const value = {kind:'candidate',sessionID,candidate:{sdp:event.candidate.candidate,sdpMLineIndex:event.candidate.sdpMLineIndex,sdpMid:event.candidate.sdpMid}};
      if (value.candidate.sdpMid === null) delete value.candidate.sdpMid;
      if (offered) send(value); else pendingCandidates.push(value);
    } catch { fail(); }
  };
  socket.onopen = () => { try { send({kind:'deviceConnect',hostID:route.h,deviceID:route.d}); } catch { fail(); } };
  socket.onerror = () => fail();
  socket.onclose = () => { if (!remoteDone || !localDone) fail(); };
  socket.onmessage = event => {
    if (++queuedSignals > 70) { fail(); return; }
    signalChain = signalChain.then(async () => {
      if (stopped) return;
      const message = parseEnvelope(event.data);
      if (message.kind === 'failure') {
        const messages = { hostOffline:'The Mac is offline. Ask the sender to open Threading.', unauthorized:'This invitation is no longer valid. Ask for a new link.', hostBusy:'The Mac has too many connections. Try again shortly.' };
        throw Error(messages[message.errorCode] || 'The connection service could not reach the Mac. Try again.');
      }
      if (!sessionID) {
        if (message.kind !== 'ready') throw Error('Invalid signaling response.');
        sessionID = message.sessionID;
        peer = new PeerClass({iceServers:message.iceServers, bundlePolicy:'max-bundle'});
        peer.onicecandidate = candidate;
        peer.onconnectionstatechange = () => { if (['failed','closed'].includes(peer.connectionState)) fail(); };
        const channel = peer.createDataChannel('threading.remote.v1', {ordered:true});
        channel.onopen = () => {
          if (stopped) return;
          tunnel = new Tunnel(channel); tunnel.onclose = () => { peer.close(); socket.close(); };
          connected = true; resolve(tunnel);
        };
        channel.onerror = () => fail();
        const offer = await peer.createOffer(); await peer.setLocalDescription(offer);
        send({kind:'offer',sessionID,description:{kind:'offer',sdp:offer.sdp}}); offered = true;
        for (const value of pendingCandidates) send(value); pendingCandidates = [];
        if (localDone) send({kind:'candidatesComplete',sessionID});
        return;
      }
      if (message.sessionID !== sessionID) throw Error('Unexpected signaling session.');
      if (message.kind === 'answer' && !answer) {
        await peer.setRemoteDescription({type:'answer',sdp:message.description.sdp}); answer = true;
      } else if (message.kind === 'candidate' && answer && !remoteDone) {
        if (++remoteCount > 64) throw Error('Too many network candidates.');
        const c = message.candidate;
        await peer.addIceCandidate({candidate:c.sdp,sdpMLineIndex:c.sdpMLineIndex,sdpMid:c.sdpMid});
      } else if (message.kind === 'candidatesComplete' && answer && !remoteDone) {
        remoteDone = true; finishSignals();
      } else if (!(message.kind === 'close' && remoteDone)) throw Error('Unexpected signaling message.');
    }).catch(fail).finally(() => { queuedSignals--; });
  };
  // Negotiation/candidate gathering is bounded even if the data channel opens earlier.
  const timer = setTimeout(() => { if (!connected || !localDone || !remoteDone) fail(); }, 30000);
  try { const result = await deadline(ready); signalChain.finally(() => {}); return result; }
  catch (error) { fail(error); throw error; }
  finally { signal?.removeEventListener('abort',abort); if (stopped || (localDone && remoteDone)) clearTimeout(timer); else setTimeout(() => clearTimeout(timer), 31000); }
}
