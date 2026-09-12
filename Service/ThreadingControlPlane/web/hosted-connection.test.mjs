import test from 'node:test';
import assert from 'node:assert/strict';
import { parseInvitation, base64url, connectHosted } from './hosted-connection.mjs';
const origin='https://remote.threading.codes';
const route={v:1,s:origin,h:'host',d:'invite-chat',c:'service-only',b:'mac-only',e:Date.now()/1000+3600};
const link=p=>base64url('threading://pair#'+base64url(JSON.stringify(p)));
test('public invitation preserves separate secrets and rejects expired or foreign authorities',()=>{
  assert.deepEqual(parseInvitation(link(route),origin),route);
  for(const p of [{...route,s:'https://evil.test'},{...route,e:1},{...route,c:'x\r\ny'},{...route,v:2},{...route,h:'x/y'}]) {
    assert.throws(()=>parseInvitation(link(p),origin));
  }
  assert.throws(()=>parseInvitation('x'.repeat(8193),origin));
});
test('service failures close the signaling connection without sending Mac authority',async()=>{
  let socket;
  class Socket {
    readyState=0;bufferedAmount=0;sent=[];
    constructor(url,protocols) {socket=this;this.protocols=protocols;queueMicrotask(()=>{this.readyState=1;this.onopen();});}
    send(data) {this.sent.push(JSON.parse(data));queueMicrotask(()=>this.onmessage({data:JSON.stringify({version:1,kind:'failure',errorCode:'hostOffline',errorMessage:'offline'})}));}
    close() {this.readyState=3;}
  }
  await assert.rejects(connectHosted(route,{signalURL:'wss://fixture.test',WebSocketClass:Socket,PeerClass:class{}}),/Mac is offline/);
  assert.equal(socket.readyState,3);
  assert.deepEqual(socket.sent,[{version:1,kind:'deviceConnect',hostID:'host',deviceID:'invite-chat'}]);
  assert.equal(socket.protocols.join(',').includes(base64url('mac-only')),false);
});
test('navigating away cancels an outstanding signaling handshake',async()=>{
  let socket;
  class Socket {readyState=0;constructor(){socket=this;} close(){this.readyState=3;} }
  const controller=new AbortController();
  const pending=connectHosted(route,{signalURL:'wss://fixture.test',WebSocketClass:Socket,PeerClass:class{},signal:controller.signal});
  controller.abort();await assert.rejects(pending,{name:'AbortError'});assert.equal(socket.readyState,3);
});

test('expired links can identify a saved membership, but cannot start fresh acceptance',()=>{
  const expired={...route,e:1};
  assert.throws(()=>parseInvitation(link(expired),origin));
  assert.deepEqual(parseInvitation(link(expired),origin,{allowExpired:true}),expired);
  assert.throws(()=>parseInvitation(link({...expired,s:'https://evil.test'}),origin,{allowExpired:true}));
});
