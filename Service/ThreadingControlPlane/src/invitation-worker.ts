import { invitationAssociation, invitationPage } from "./invitation-page";

// The core API also calls this. The separate Worker serves browser assets and a narrow signaling
// handshake. No remote HTTP request, chat WebSocket or transcript is proxied by this Worker.
export function publicInvitationResponse(request: Request): Response | null {
  if (request.method !== "GET") return null;
  const path = new URL(request.url).pathname;
  if (path === "/.well-known/apple-app-site-association") return invitationAssociation();
  if (path === "/join") return invitationPage();
  return null;
}
const publicOrigins = new Set(["https://remote.threading.codes", "https://dev.remote.threading.codes"]);
const assets = new Set(["app.js", "app.css", "xterm.js", "xterm.css", "boot.js"]);
interface InvitationEnv { ASSETS?: { fetch(request: Request): Promise<Response> } }

export function browserSignalingRequest(request: Request): Request | null {
  const url = new URL(request.url);
  // Browser WebSocket cannot supply Authorization. Receive the service credential in a named
  // subprotocol, never a URL, then use the unchanged authenticated device endpoint. No caller
  // can select an upstream host/path or send a Mac capability to this endpoint.
  if (request.method !== "GET" || url.pathname !== "/join/rendezvous" || url.search
    || !publicOrigins.has(url.origin) || request.headers.get("Origin") !== url.origin
    || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return null;
  const offered = request.headers.get("Sec-WebSocket-Protocol")?.split(",").map(v => v.trim());
  if (offered?.length !== 2 || offered[0] !== "threading.rendezvous.v1"
    || !offered[1]?.startsWith("threading.auth.")) return null;
  const encoded = offered[1].slice("threading.auth.".length);
  if (!/^[A-Za-z0-9_-]{1,5462}$/.test(encoded)) return null;
  let credential: string;
  try { credential = atob(encoded.replaceAll("-", "+").replaceAll("_", "/")); } catch { return null; }
  if (!/^[\x21-\x7e]{1,4096}$/.test(credential)) return null;
  return new Request(url.origin + "/v1/rendezvous/device", { headers: {
    Upgrade: "websocket", Authorization: "Bearer " + credential,
    "X-Threading-Rendezvous-Version": "1",
  } });
}
export default {
  async fetch(request: Request, env: InvitationEnv = {}): Promise<Response> {
    const direct = publicInvitationResponse(request); if (direct) return direct;
    const url = new URL(request.url);
    if (url.pathname === "/join/rendezvous") {
      const upstream = browserSignalingRequest(request);
      if (!upstream) return new Response("Invalid signaling request", {status:400});
      const response = await fetch(upstream);
      if (response.status !== 101 || !response.webSocket) {
        return new Response("Connection refused", {status:response.status === 401 ? 401 : 503,
          headers:{"Cache-Control":"no-store"}});
      }
      return new Response(null, {status:101, webSocket:response.webSocket, headers:{
        "Sec-WebSocket-Protocol":"threading.rendezvous.v1",
      }});
    }
    if (request.method === "GET" && env.ASSETS) {
      const name = url.pathname === "/join/chat" ? "index.html"
        : url.pathname.startsWith("/join/assets/") ? url.pathname.slice("/join/assets/".length) : "";
      if (name === "index.html" || assets.has(name)) {
        const response = await env.ASSETS.fetch(new Request(url.origin + "/" + name));
        const headers = new Headers(response.headers);
        headers.set("Cache-Control", "no-store"); headers.set("Referrer-Policy", "no-referrer");
        headers.set("X-Content-Type-Options", "nosniff");
        headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()");
        headers.set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss://remote.threading.codes wss://dev.remote.threading.codes; img-src data:; font-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
        return new Response(response.body, {status:response.status,headers});
      }
    }
    return new Response("Not found", {status:404});
  },
};
