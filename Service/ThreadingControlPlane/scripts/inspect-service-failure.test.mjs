import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { inspectServiceFailure } from "./inspect-service-failure.mjs";

const reference = "sf-1793214420000-push-400";
const token = "test-only-developer-pickup-credential";

test("pickup uses the protected route and compares host identity only on the operator's machine", async () => {
  const hostID = "local-host";
  const hostRef = `host-${createHash("sha256").update(`threading-service-failure:host:${hostID}`).digest("hex").slice(0, 24)}`;
  const evidence = await inspectServiceFailure(reference, { token, hostID,
    fetchImplementation: async (url, options) => {
      assert.equal(url.href, `https://remote.threading.codes/v1/developer/service-failures/${reference}`);
      assert.equal(options.headers.Authorization, `Bearer ${token}`);
      assert.equal(options.redirect, "error");
      assert.ok(!JSON.stringify(options).includes(hostID));
      return Response.json({ reference, samples: [{ hostRef }, { hostRef: "host-someone-else" }, {}] });
    },
  });
  assert.deepEqual(evidence.samples.map(sample => sample.matchesHost), [true, false, null]);
  assert.ok(!JSON.stringify(evidence).includes(hostID));
});

test("refuses redirects, oversized evidence, wrong references and missing credentials", async () => {
  await assert.rejects(inspectServiceFailure(reference, { token: "" }), /PICKUP_TOKEN/u);
  await assert.rejects(inspectServiceFailure(reference, { token, origin: "http://service.test" }), /HTTPS/u);
  await assert.rejects(inspectServiceFailure(reference, { token, fetchImplementation: async () => new Response(null, { status: 403 }) }), /HTTP 403/u);
  await assert.rejects(inspectServiceFailure(reference, { token, fetchImplementation: async () => new Response(null, { status: 404 }) }), /No retained diagnostic/u);
  await assert.rejects(inspectServiceFailure(reference, { token, fetchImplementation: async () => new Response("x".repeat(32769)) }), /response limit/u);
  await assert.rejects(inspectServiceFailure(reference, { token, fetchImplementation: async () => Response.json({ reference: "wrong", samples: [] }) }), /invalid diagnostic/u);
});
