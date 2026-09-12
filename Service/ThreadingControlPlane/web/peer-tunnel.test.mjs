import test from 'node:test';
import assert from 'node:assert/strict';
import { Tunnel, frame, bounds, bytes, join, tunnelFetch, socketClass } from './peer-tunnel.mjs';
class Channel {
  readyState = 'open'; bufferedAmount = 0; sent = [];
  send(data) { this.sent.push(data); this.onSend?.(data); }
  receive(op,id,value=0,payload) { this.onmessage({data:frame(op,id,value,payload).buffer}); }
  close() { this.readyState = 'closed'; }
}
const operation = data => data[3];
const id = data => new DataView(data.buffer).getUint32(4);
test('native frame layout, flow control and bounded stream count', async () => {
  const channel = new Channel(), tunnel = new Tunnel(channel);
  channel.onSend = data => { if (operation(data) === 1) queueMicrotask(() => channel.receive(2,id(data))); };
  const stream = await tunnel.open();
  assert.deepEqual([...channel.sent[0]], [0x54,0x52,1,1,0,0,0,1,0,0,0,0]);
  channel.receive(3,1,3,bytes('abc'));
  assert.equal(channel.sent.length,1); // not acknowledged until consumed
  assert.equal(new TextDecoder().decode(await stream.read()),'abc');
  assert.equal(operation(channel.sent.at(-1)),4);
  for (let i=1;i<bounds.streams;i++) await tunnel.open();
  await assert.rejects(tunnel.open()); tunnel.close();
});
test('oversized inbound window, invalid control and invalid version fail closed', async () => {
  for (const invalid of ['window','control','version']) {
    const channel = new Channel(), tunnel = new Tunnel(channel);
    channel.onSend = data => { if (operation(data)===1) queueMicrotask(()=>channel.receive(2,id(data))); };
    await tunnel.open();
    if (invalid === 'window') for (let n=0;n<6;n++) channel.receive(3,1,bounds.chunk,new Uint8Array(bounds.chunk));
    if (invalid === 'control') channel.receive(4,1,1);
    if (invalid === 'version') { const f=frame(2,1); f[2]=2; channel.onmessage({data:f.buffer}); }
    assert.equal(tunnel.closed,true);
  }
});
test('REST crosses the byte tunnel with split headers and body, without global fetch', async () => {
  const channel = new Channel(), tunnel = new Tunnel(channel); let wire='';
  channel.onSend = data => {
    const streamID=id(data);
    if(operation(data)===1) queueMicrotask(()=>channel.receive(2,streamID));
    if(operation(data)===3) {
      wire+=new TextDecoder().decode(data.subarray(12));
      queueMicrotask(()=> {
        const a=bytes('HTTP/1.1 200 OK\r\nContent-Len'), b=bytes('gth: 11\r\nContent-Type: application/json\r\n\r\n{"ok":true}');
        channel.receive(3,streamID,a.length,a);channel.receive(3,streamID,b.length,b);
      });
    }
  };
  const response=await tunnelFetch(tunnel,'/api/me',{headers:{Authorization:'Bearer guest'}});
  assert.deepEqual(await response.json(),{ok:true});
  assert.match(wire,/authorization: Bearer guest/);assert.match(wire,/GET \/api\/me HTTP\/1.1/);
  assert.equal(tunnel.streams.size,0);
  await assert.rejects(tunnelFetch(tunnel,'https://evil.test/api/me'));
  tunnel.close();
});
test('truncated and oversized HTTP responses fail without retaining streams', async () => {
  for (const length of ['999999999','3']) {
    const channel=new Channel(),tunnel=new Tunnel(channel);
    channel.onSend=data=> {
      if(operation(data)===1) queueMicrotask(()=>channel.receive(2,id(data)));
      if(operation(data)===3) queueMicrotask(()=>{
        const body=bytes('HTTP/1.1 200 OK\r\nContent-Length: '+length+'\r\n\r\nx');
        channel.receive(3,id(data),body.length,body);channel.receive(5,id(data));
      });
    };
    await assert.rejects(tunnelFetch(tunnel,'/api/me'));assert.equal(tunnel.streams.size,0);tunnel.close();
  }
});
test('WebSocket upgrades, masks client messages, reassembles fragments and answers ping', async () => {
  const channel=new Channel(),tunnel=new Tunnel(channel);let socketID; const sent=[];
  channel.onSend=data=> {
    if(operation(data)===1) { socketID=id(data);queueMicrotask(()=>channel.receive(2,socketID)); }
    if(operation(data)===3) {
      const payload=data.subarray(12); const text=new TextDecoder().decode(payload);
      if(text.startsWith('GET')) {
        const key=/Sec-WebSocket-Key: (.*)\r\n/.exec(text)[1];
        crypto.subtle.digest('SHA-1',bytes(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')).then(hash=>{
          const response=bytes('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: '+btoa(String.fromCharCode(...new Uint8Array(hash)))+'\r\n\r\n');
          channel.receive(3,socketID,response.length,response);
        });
      } else sent.push(payload);
    }
  };
  const Socket=socketClass(async()=>tunnel),socket=new Socket('wss://public.test/ws/session/chat-1');
  await new Promise((resolve,reject)=>{socket.onopen=resolve;socket.onerror=reject;});
  socket.send('hello');await socket.queue;
  assert.ok(sent[0][1]&128);
  const masked=sent[0],size=masked[1]&127,mask=masked.subarray(2,6);
  assert.equal(new TextDecoder().decode(masked.subarray(6,6+size).map((v,i)=>v^mask[i%4])),'hello');
  const received=new Promise(resolve=>socket.onmessage=resolve);
  const frames=join([new Uint8Array([1,2,104,101]),new Uint8Array([0x89,1,7]),new Uint8Array([0x80,3,108,108,111])]);
  channel.receive(3,socketID,frames.length,frames);
  assert.equal((await received).data,'hello');await socket.queue;assert.equal(sent.at(-1)[0]&15,10);
  socket.close();assert.equal(socket.readyState,3);assert.equal(tunnel.streams.size,0);tunnel.close();
});
test('writer waits for native window credit and connection close settles pending writes',async()=>{
  const channel=new Channel(),tunnel=new Tunnel(channel);
  channel.onSend=data=>{if(operation(data)===1)queueMicrotask(()=>channel.receive(2,id(data)));};
  const stream=await tunnel.open();let finished=false;
  const write=stream.write(new Uint8Array(bounds.window+1)).then(()=>{finished=true;});
  await new Promise(resolve=>setImmediate(resolve));assert.equal(finished,false);
  channel.receive(4,1,bounds.chunk);await write;assert.equal(finished,true);
  const blocked=stream.write(new Uint8Array(bounds.window));
  tunnel.close();await assert.rejects(blocked);
});
