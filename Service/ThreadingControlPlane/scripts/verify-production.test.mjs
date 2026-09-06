import assert from "node:assert/strict";
import test from "node:test";
import { verifyProduction } from "./verify-production.mjs";

test("accepts only the reviewed ready response and hardening headers", async () => {
  let requestedURL = "";
  await verifyProduction({
    attempts: 1,
    reportSuccess: () => undefined,
    fetchImplementation: async (url) => {
      requestedURL = url;
      if (new URL(url).pathname !== "/ready") return Response.json({}, { status: 401 });
      return readyResponse();
    },
  });
  assert.equal(requestedURL, "https://remote.threading.codes/v1/push/retractions");
});

test("rejects a liveness response that does not prove dependency readiness", async () => {
  await assert.rejects(
    verifyProduction({
      attempts: 1,
      fetchImplementation: async () => Response.json(
        { status: "ok", rendezvousProtocol: 1, notificationProtocol: 1 },
        {
          headers: {
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'",
            "X-Content-Type-Options": "nosniff",
          },
        },
      ),
    }),
    /production readiness failed after 1 attempts/u,
  );
});

test("rejects a stale notification protocol and a missing retraction route", async () => {
  await assert.rejects(
    verifyProduction({
      attempts: 1,
      fetchImplementation: async () => Response.json(
        { status: "ready", rendezvousProtocol: 1 },
        { headers: hardeningHeaders() },
      ),
    }),
    /production readiness failed after 1 attempts/u,
  );

  await assert.rejects(
    verifyProduction({
      attempts: 1,
      fetchImplementation: async (url) => {
        const path = new URL(url).pathname;
        if (path === "/ready") return readyResponse();
        return Response.json({}, { status: path === "/v1/push" ? 401 : 404 });
      },
    }),
    /production readiness failed after 1 attempts/u,
  );
});

test("bounds an untrusted readiness response before parsing", async () => {
  await assert.rejects(
    verifyProduction({
      attempts: 1,
      fetchImplementation: async () => new Response("x".repeat(4 * 1024 + 1), {
        headers: {
          "Cache-Control": "no-store",
          "Content-Security-Policy": "default-src 'none'",
          "X-Content-Type-Options": "nosniff",
        },
      }),
    }),
    /production readiness failed after 1 attempts/u,
  );
});

function hardeningHeaders() {
  return {
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'none'",
    "X-Content-Type-Options": "nosniff",
  };
}

function readyResponse() {
  return Response.json(
    { status: "ready", rendezvousProtocol: 1, notificationProtocol: 1 },
    { headers: hardeningHeaders() },
  );
}
