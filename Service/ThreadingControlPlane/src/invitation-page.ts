/// The capability lives in the URL fragment and is read only by this page on the recipient's
/// device. No analytics, previews, third-party assets, redirect, or HTTP request receives it.
export function invitationAssociation(): Response {
  return new Response(JSON.stringify({ applinks: { details: [{
    appIDs: ["SMQ3E8Y57T.codes.threading.mobile"],
    components: [{ "/": "/join", comment: "Threading chat invitations" }],
  }] } }), { headers: {
    "Content-Type": "application/json", "Cache-Control": "public, max-age=3600",
    "X-Content-Type-Options": "nosniff",
  } });
}

export function invitationPage(): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  return new Response(`<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>Join a chat · Threading</title>
<style nonce="${nonce}">
:root{color-scheme:light dark;font-family:system-ui,sans-serif;background:light-dark(#f5f5f4,#141414);color:light-dark(#202020,#ededeb)}
body{margin:0;min-height:100svh;display:grid;place-items:center}main{max-width:28rem;padding:3rem 1.5rem}
.brand{font-size:.85rem;letter-spacing:.12em;text-transform:uppercase;color:light-dark(#666,#aaa)}
h1{font-size:2rem;letter-spacing:-.04em;margin:1rem 0}p{line-height:1.6;color:light-dark(#555,#bbb)}
a{display:inline-block;padding:.85rem 1.25rem;border-radius:.6rem;background:light-dark(#202020,#eee);color:light-dark(#fff,#171717);text-decoration:none;font-weight:600;margin:1rem 0}a:focus-visible{outline:3px solid #687dff;outline-offset:4px}
.actions{display:flex;flex-wrap:wrap;gap:.6rem;margin:1.5rem 0}.actions a{margin:0}#open{background:transparent;color:inherit;box-shadow:inset 0 0 0 1px light-dark(#bbb,#555)}@media(max-width:420px){.actions{flex-direction:column}.actions a{text-align:center}}
small{display:block;line-height:1.5;color:light-dark(#666,#aaa)}[hidden]{display:none}
</style><main><div class="brand">Threading</div><h1>You’re invited to a chat</h1>
<p id="message">Join the shared chat in your browser or open it in the Threading app.</p>
<div class="actions"><a id="browser" hidden>Continue in browser</a><a id="open" hidden>Open in Threading</a></div>
<p id="network" hidden></p><small id="help">No installation needed for browser access. The sender’s Mac must be online with Threading open.</small>
</main><script nonce="${nonce}">
const button=document.getElementById('open');
try {
 const encoded=location.hash.slice(1);
 if(!encoded || location.href.length>8192 || !/^[A-Za-z0-9_-]+$/.test(encoded)) throw Error();
 const payload=atob(encoded.replaceAll('-','+').replaceAll('_','/'));
 const link=new URL(payload);
 if(link.protocol!=='threading:' || !['pair','join'].includes(link.hostname.toLowerCase()) || !link.hash || link.username || link.password || link.port || link.pathname || link.search) throw Error();
 button.href=payload; button.hidden=false;
 const browser=document.getElementById('browser');
 if(link.hostname.toLowerCase()==='pair') { browser.href='/join/chat#'+encoded; browser.hidden=false; }
 if(link.hostname.toLowerCase()==='join') {
  const note=document.getElementById('network');note.hidden=false;
  const privateURL=new URL(atob(link.hash.slice(1).replaceAll('-','+').replaceAll('_','/')));
  if(privateURL.protocol==='https:' && !privateURL.username && !privateURL.password) {
   privateURL.hash=privateURL.hash.split('.')[0]; browser.href=privateURL.href; browser.hidden=false;
  }
  note.textContent='This invitation requires access to the sender’s Wi-Fi or private network. Your browser may ask you to trust the Mac’s certificate. Ask the sender to enable Hosted Direct to share across networks.';
 }
} catch {
 document.querySelector('h1').textContent='This invitation is incomplete';
 document.getElementById('message').textContent='Ask the sender to copy a new invitation from Threading.';
 document.getElementById('help').hidden=true;
}
</script></html>`, { headers: {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'`,
  } });
}
