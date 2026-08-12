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
      return Response.json(
        { status: "ready", rendezvousProtocol: 1 },
        {
          headers: {
            "Cache-Control": "no-store",
            "Content-Security-Policy": "default-src 'none'",
            "X-Content-Type-Options": "nosniff",
          },
        },
      );
    },
  });
  assert.equal(requestedURL, "https://remote.threading.codes/ready");
});

test("rejects a liveness response that does not prove dependency readiness", async () => {
  await assert.rejects(
    verifyProduction({
      attempts: 1,
      fetchImplementation: async () => Response.json(
        { status: "ok", rendezvousProtocol: 1 },
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
