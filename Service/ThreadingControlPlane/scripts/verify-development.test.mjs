import assert from "node:assert/strict";
import test from "node:test";
import { verifyDevelopment } from "./verify-development.mjs";

test("verifies isolated routes, credential enforcement, and the Access redirect", async () => {
  const requests = [];
  let success = "";
  await verifyDevelopment({
    attempts: 1,
    fetchImplementation: async (input, init) => {
      const url = new URL(input);
      requests.push({ path: url.pathname, redirect: init.redirect });
      switch (url.pathname) {
        case "/ready":
          return json({ status: "ready", rendezvousProtocol: 1, notificationProtocol: 2 }, 200);
        case "/v1/auth/apple":
        case "/v1/reports":
          return json({ error: { code: "notFound", message: "Endpoint was not found" } }, 404);
        case "/v1/push":
        case "/v1/push/retractions":
          return json({ error: { code: "unauthorized", message: "Credential required" } }, 401);
        case "/v1/auth/development/start":
          return json({
            transactionID: "th_dev_auth_transaction",
            pollToken: "th_dev_poll_secret",
            authorizationURL: "https://dev.remote.threading.codes/v1/auth/development/authorize?transaction=th_dev_auth_transaction",
            expiresAt: Date.now() + 300_000,
          }, 201);
        case "/v1/auth/development/authorize":
          return new Response("", {
            status: 302,
            headers: { Location: "https://threading.cloudflareaccess.com/cdn-cgi/access/login" },
          });
        default:
          throw new Error(`unexpected request ${url.pathname}`);
      }
    },
    reportSuccess: (message) => { success = message; },
  });

  assert.match(success, /Development auth and push boundaries verified/u);
  assert.deepEqual(requests.map((request) => request.path), [
    "/ready",
    "/v1/auth/apple",
    "/v1/reports",
    "/v1/push",
    "/v1/push/retractions",
    "/v1/auth/development/start",
    "/v1/auth/development/authorize",
  ]);
  assert.equal(requests.at(-1).redirect, "manual");
});

test("rejects an authorization callback that bypasses Access", async () => {
  await assert.rejects(
    verifyDevelopment({
      attempts: 1,
      fetchImplementation: async (input) => {
        const url = new URL(input);
        switch (url.pathname) {
          case "/ready":
            return json({ status: "ready", rendezvousProtocol: 1, notificationProtocol: 2 }, 200);
          case "/v1/auth/apple":
          case "/v1/reports":
            return json({}, 404);
          case "/v1/push":
          case "/v1/push/retractions":
            return json({}, 401);
          case "/v1/auth/development/start":
            return json({
              transactionID: "th_dev_auth_transaction",
              pollToken: "th_dev_poll_secret",
              authorizationURL: "https://dev.remote.threading.codes/v1/auth/development/authorize?transaction=th_dev_auth_transaction",
              expiresAt: Date.now() + 300_000,
            }, 201);
          case "/v1/auth/development/authorize":
            return new Response("not protected", { status: 200 });
          default:
            throw new Error(`unexpected request ${url.pathname}`);
        }
      },
      reportSuccess: () => {},
    }),
    /browser authorization path is not protected/u,
  );
});

test("rejects a deployment without the notification protocol or retraction route", async () => {
  await assert.rejects(
    verifyDevelopment({
      attempts: 1,
      fetchImplementation: async (input) => {
        const url = new URL(input);
        if (url.pathname === "/ready") {
          return json({ status: "ready", rendezvousProtocol: 1 }, 200);
        }
        throw new Error(`unexpected request ${url.pathname}`);
      },
      reportSuccess: () => {},
    }),
    /development verification failed after 1 attempts/u,
  );

  await assert.rejects(
    verifyDevelopment({
      attempts: 1,
      fetchImplementation: async (input) => {
        const url = new URL(input);
        switch (url.pathname) {
          case "/ready":
            return json({ status: "ready", rendezvousProtocol: 1, notificationProtocol: 2 }, 200);
          case "/v1/auth/apple":
          case "/v1/reports":
            return json({}, 404);
          case "/v1/push":
            return json({}, 401);
          case "/v1/push/retractions":
            return json({}, 404);
          default:
            throw new Error(`unexpected request ${url.pathname}`);
        }
      },
      reportSuccess: () => {},
    }),
    /development verification failed after 1 attempts/u,
  );
});

function json(value, status) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
