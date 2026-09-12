import { describe, expect, it } from "vitest";
import worker, { browserSignalingRequest } from "../src/invitation-worker";

describe("public invitations", () => {
  it("serves the exact iPhone association without authentication or a redirect", async () => {
    const response = await worker.fetch(new Request(
      "https://dev.remote.threading.codes/.well-known/apple-app-site-association"));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json");
    expect(await response.json()).toEqual({ applinks: { details: [{
      appIDs: ["SMQ3E8Y57T.codes.threading.mobile"],
      components: [{ "/": "/join", comment: "Threading chat invitations" }],
    }] } });
  });

  it("serves a fragment-only app handoff with no network capability or referrer", async () => {
    const response = await worker.fetch(new Request("https://dev.remote.threading.codes/join"));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("content-security-policy")).toContain("default-src 'none'");
    const html = await response.text();
    expect(html).toContain("Open in Threading");
    expect(html).toContain("Continue in browser");
    expect(html).toContain("location.hash");
    expect(html).not.toContain("fetch(");
    expect(html).not.toContain("http-equiv=\"refresh\"");
  });
  it("does not proxy or accept any API operation", async () => {
    for (const path of ["/api/me", "/v1/push", "/ready", "/join/extra"]) {
      expect((await worker.fetch(new Request("https://remote.threading.codes" + path))).status).toBe(404);
    }
    expect((await worker.fetch(new Request("https://remote.threading.codes/join", { method: "POST" }))).status).toBe(404);
  });

});

describe("browser signaling boundary", () => {
  const origin = "https://dev.remote.threading.codes";
  const request = (changes: Record<string,string> = {}, path = "/join/rendezvous") => new Request(origin + path, {headers:{
    Origin:origin, Upgrade:"websocket", "Sec-WebSocket-Protocol":"threading.rendezvous.v1, threading.auth." + btoa("service-credential"), ...changes,
  }});
  it("forwards only the service credential to the fixed device endpoint", () => {
    const forwarded = browserSignalingRequest(request());
    expect(forwarded?.url).toBe(origin + "/v1/rendezvous/device");
    expect(forwarded?.headers.get("Authorization")).toBe("Bearer service-credential");
    expect(forwarded?.headers.get("X-Threading-Rendezvous-Version")).toBe("1");
    expect(forwarded?.headers.get("Sec-WebSocket-Protocol")).toBeNull();
    expect(forwarded?.url).not.toContain("credential");
  });
  it("rejects cross-origin, URL credentials, header injection and excessive protocols", () => {
    expect(browserSignalingRequest(request({Origin:"https://evil.test"}))).toBeNull();
    expect(browserSignalingRequest(request({},"/join/rendezvous?token=secret"))).toBeNull();
    expect(browserSignalingRequest(request({"Sec-WebSocket-Protocol":"threading.rendezvous.v1, threading.auth." + btoa("x\r\ny")}))).toBeNull();
    expect(browserSignalingRequest(request({"Sec-WebSocket-Protocol":"threading.rendezvous.v1, threading.auth.eA, extra"}))).toBeNull();
    expect(browserSignalingRequest(request({Upgrade:"no"}))).toBeNull();
  });
  it("serves only allowlisted shipping assets with no-referrer and a connection-restricted CSP", async () => {
    const requested:string[]=[];
    const env = {ASSETS:{fetch:async (r:Request) => {requested.push(r.url);return new Response("asset");}}};
    const response = await worker.fetch(new Request(origin+"/join/chat?share=opaque"),env);
    expect(response.status).toBe(200);expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("content-security-policy")).toContain("connect-src 'self'");
    expect(requested).toEqual([origin+"/index.html"]);
    expect((await worker.fetch(new Request(origin+"/join/assets/secrets.json"),env)).status).toBe(404);
    expect((await worker.fetch(new Request(origin+"/api/me"),env)).status).toBe(404);
  });
});
