// Loopback-only browser/native interop fixture; no production credentials or real chats.
// Start this after build:invitations, then run the opt-in Swift test and open the printed URL.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { WebSocketServer } from 'ws';
const port=Number(process.env.THREADING_BROWSER_PROOF_PORT || 18891), origin='http://127.0.0.1:'+port;
const assets=new URL('../.wrangler/invitation-assets/',import.meta.url);
const invitationToken='browser-proof-invite-'+randomUUID();
let guestAcceptances=0,host, result='waiting', acceptedDevice, guestToken='browser-proof-member', acceptanceCount=0, sockets=0;
const sessions=new Map();
const send=(ws,value)=>ws.send(JSON.stringify({version:1,...value}));
const server=http.createServer(async(req,res)=>{
  const path=new URL(req.url,origin).pathname;
  if(path==='/proof-result') {res.end(result);return;}
  if(path==='/proof-state') {res.setHeader('Content-Type','application/json');res.end(JSON.stringify({result,acceptanceCount,sockets,host:!!host}));return;}
  try {
    const name=path==='/join/chat'?'index.html':path.startsWith('/join/assets/')?path.slice(13):'';
    if(!['index.html','app.js','app.css','xterm.js','xterm.css','boot.js'].includes(name)) {res.writeHead(404);res.end();return;}
    res.setHeader('Content-Type',name.endsWith('.js')?'text/javascript':name.endsWith('.css')?'text/css':'text/html');
    let content=await readFile(new URL(name,assets));
    // The real client must accept, reload, and authenticate its chat socket to complete the proof.
    res.end(content);
  } catch {res.writeHead(500);res.end();}
});
const signals=new WebSocketServer({noServer:true,handleProtocols:protocols=>protocols.has('threading.rendezvous.v1')?'threading.rendezvous.v1':false,maxPayload:384*1024});
server.on('upgrade',(req,socket,head)=>signals.handleUpgrade(req,socket,head,ws=>{
  const path=new URL(req.url,origin).pathname;
  ws.on('message',data=>{
    const m=JSON.parse(data.toString());
    if(path==='/v1/rendezvous/host' && m.kind==='hostHello') {host=ws;send(ws,{kind:'hostReady',hostID:m.hostID});return;}
    if(path==='/join/rendezvous' && m.kind==='deviceConnect') {
      if(!host) {send(ws,{kind:'failure',errorCode:'hostOffline',errorMessage:'Fixture host not started'});return;}
      const sessionID=randomUUID(),state={device:ws,deviceID:m.deviceID,expiresAt:Date.now()+290000};sessions.set(sessionID,state);ws.sessionID=sessionID;
      send(host,{kind:'incomingSession',hostID:m.hostID,deviceID:m.deviceID,sessionID,sessionToken:'fixture-session',expiresAt:state.expiresAt});return;
    }
    if(path==='/v1/rendezvous/session' && m.kind==='sessionJoin') {
      const s=sessions.get(m.sessionID);s.peer=ws;ws.sessionID=m.sessionID;
      const ready={kind:'ready',sessionID:m.sessionID,expiresAt:s.expiresAt,iceServers:[{urls:['stun:127.0.0.1:9']}]};
      send(ws,ready);send(s.device,ready);return;
    }
    const s=sessions.get(ws.sessionID);if(!s)return;
    const other=s.device===ws?s.peer:s.device;
    if(m.kind==='close') {ws.close();return;}
    if(other?.readyState===1) other.send(data.toString());
  });
}));
const me={share:{label:'proof-chat',scope:'session',capability:'interact',canApprovePermissions:false,expiresAt:null,memberID:'proof-member',displayName:'Browser guest'},sessions:[{id:'proof-chat',title:'Browser connection test',isAvailable:true,projectName:'Interop fixture',agentKind:'codex',surface:'conversation',state:'idle',agent:'codex',project:'Interop fixture'}],host:{id:'browser-proof-host',name:'Test Mac'},features:[],serverProtocol:{version:1,minimumSupported:1},revision:1};
const mac=http.createServer(async(req,res)=>{
  const data=[];for await(const chunk of req)data.push(chunk);
  const reply=(status,value)=>{const payload=Buffer.from(JSON.stringify(value));res.writeHead(status,{'Content-Type':'application/json','Content-Length':payload.length,'Connection':'close'});res.end(payload);};
  const token=req.headers.authorization,device=req.headers['x-threading-device'];
  if(req.url==='/api/invitations/accept') {
    if(!acceptedDevice) {acceptedDevice=device;acceptanceCount++;}
    if(device!==acceptedDevice || !['Bearer '+invitationToken,'Bearer '+guestToken].includes(token)) {reply(401,{});return;}
    guestAcceptances++;reply(200,{accessToken:guestToken,me});return;
  }
  if(device!==acceptedDevice || token!=='Bearer '+guestToken) {reply(401,{});return;}
  if(req.url==='/api/hosted-device-credential') {reply(201,{hostID:'browser-proof-host',deviceID:'guest-proof-chat',credential:'browser-proof-service-member',expiresAt:Date.now()/1000+86400-978307200});return;}
  if(req.url==='/api/me') {reply(200,me);return;}
  reply(404,{});
});
const chat=new WebSocketServer({noServer:true,maxPayload:2*1024*1024});
mac.on('upgrade',(req,socket,head)=>chat.handleUpgrade(req,socket,head,ws=>{
  sockets++; let authorized=false;
  ws.on('message',data=>{
    const m=JSON.parse(data.toString());
    if(m.type==='auth') {
      if(m.token!==guestToken || m.device!==acceptedDevice) {ws.close(1008);return;}
      authorized=true;
      if(req.url==='/ws/session/proof-chat' && guestAcceptances>=2 && acceptanceCount===1) { setTimeout(()=>{result='passed';console.log('PASS: native tunnel, one-time guest acceptance, reload and authenticated chat socket.');},1500); }
      if(req.url==='/ws/events')return;
      ws.send(JSON.stringify({type:'hello',capability:'interact',sessionID:'proof-chat',surface:'conversation',features:[]}));
      ws.send(JSON.stringify({type:'conversation',sessionID:'proof-chat',rows:[{id:'hello',kind:'assistant',text:'The browser is connected through the native Mac tunnel. Guest access survived a page reload.'}],canSend:true}));
    } else if(authorized && (m.type==='prompt' || m.type==='submit')) {
      result='passed'; console.log('PASS: authenticated browser prompt crossed the native WebRTC tunnel.');
      ws.send(JSON.stringify({type:'conversation',sessionID:'proof-chat',rows:[{id:'reply',kind:'assistant',text:'Received: '+m.text}],canSend:true}));
    }
  });
}));
server.listen(port,'127.0.0.1');mac.listen(port+1,'127.0.0.1');
const encode=v=>Buffer.from(v).toString('base64url');
const payload={v:1,s:origin,h:'browser-proof-host',d:'invite-proof',c:'browser-proof-service-invite',b:invitationToken,e:Date.now()/1000+3600};
console.log(origin+'/join/chat#'+encode('threading://pair#'+encode(JSON.stringify(payload))));
console.log('Native test: THREADING_BROWSER_PROOF_URL='+origin+' swift test --package-path Packages/ThreadingPeerTransport --filter PeerBrowserInteropTests');
