import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { HttpError, type Env } from "../src/environment";
import worker from "../src/index";
import { setFailurePrincipal } from "../src/service-failure-context";
import { recordServiceFailure, flushServiceFailureAlerts } from "../src/service-failure-alerts";
import receiver from "../../ThreadingReportAlerts/src/index";

const testEnv = env as unknown as Env;
const now = Date.parse("2026-09-16T10:08:00.000Z");
const request = new Request("https://service.test/v1/reports?private=secret", {
  method: "POST", body: "private report text", headers: { Authorization: "Bearer secret" },
});

beforeEach(async () => {
  await testEnv.DB.batch([
    testEnv.DB.prepare("DELETE FROM service_failure_alerts"),
    testEnv.DB.prepare("DELETE FROM service_failure_diagnostics"),
  ]);
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers(); });

describe("HTTP failure alerts", () => {
  it("keeps bounded evidence after paging, attributes only authenticated principals, and expires pickup", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const first = new Request("https://service.test/v1/push/registrations?credential=private", {
      method: "POST", body: "private token and notification text",
      headers: { Authorization: "Bearer private", "X-Threading-Request-ID": "caller-chosen" },
    });
    const second = new Request("https://service.test/v1/push");
    setFailurePrincipal(first, { kind: "device", accountID: "first-account", hostID: "first-host",
      deviceID: "first-device", credentialExpiresAt: now + 100000 });
    setFailurePrincipal(second, { kind: "host", accountID: "second-account", hostID: "second-host",
      credentialExpiresAt: now + 100000 });
    const failure = new HttpError(400, "invalidRequest", "private error", { reason: "invalidValue", field: "deviceToken" });
    const requestID = await recordServiceFailure(first, testEnv, failure, now);
    await recordServiceFailure(second, testEnv, failure, now + 1);
    // The atomic cap is exercised under concurrent admission; all failures still count.
    await Promise.all(Array.from({ length: 62 }, () => recordServiceFailure(first, testEnv, failure, now + 2)));
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 204 })));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toEqual([]);

    vi.setSystemTime(now + 15 * 60000);
    const reference = `sf-${now - 60000}-push-400`;
    const url = `https://service.test/v1/developer/service-failures/${reference}`;
    expect((await worker.fetch(new Request(url), testEnv)).status).toBe(401);
    expect((await worker.fetch(new Request(url, { headers: { Authorization: "Bearer app-credential" } }), testEnv)).status).toBe(403);
    const headers = { Authorization: `Bearer ${testEnv.REPORT_PICKUP_TOKEN}` };
    const response = await worker.fetch(new Request(url, { headers }), testEnv);
    expect(response.status).toBe(200);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    const body = await response.json() as { count: number; omittedCount: number; samples: Record<string, string>[] };
    expect(body.count).toBe(64);
    expect(body.omittedCount).toBe(56);
    expect(body.samples).toHaveLength(8);
    expect(body.samples[0]).toMatchObject({ requestID, operation: "push.register", code: "invalidRequest",
      reason: "invalidValue", field: "deviceToken", accountRef: expect.stringMatching(/^account-[0-9a-f]{24}$/u),
      hostRef: expect.stringMatching(/^host-[0-9a-f]{24}$/u), deviceRef: expect.stringMatching(/^device-[0-9a-f]{24}$/u) });
    expect(body.samples[1]?.hostRef).not.toBe(body.samples[0]?.hostRef);
    expect(body.samples[1]?.accountRef).not.toBe(body.samples[0]?.accountRef);
    expect(body.samples[2]?.hostRef).toBe(body.samples[0]?.hostRef);
    for (const forbidden of ["private", "first-host", "first-account", "first-device", "caller-chosen", "Authorization"]) {
      expect(JSON.stringify(body)).not.toContain(forbidden);
    }
    vi.setSystemTime(now + 8 * 24 * 60 * 60000);
    expect((await worker.fetch(new Request(url, { headers }), testEnv)).status).toBe(404);
    await flushServiceFailureAlerts(testEnv, Date.now());
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_diagnostics").all()).results).toEqual([]);
  });

  it("does not retain unknown error text or invent an identity before authentication", async () => {
    await recordServiceFailure(request, testEnv, new HttpError(500, "private-provider-code", "private exception"), now);
    const row = await testEnv.DB.prepare("SELECT samples FROM service_failure_diagnostics").first<{ samples: string }>();
    const sample = JSON.parse(row!.samples)[0];
    expect(sample).toMatchObject({ code: "other", reason: "unclassified" });
    expect(sample.hostRef).toBeUndefined();
    expect(row!.samples).not.toContain("private");
  });

  it("does not replace the original error when diagnostics storage fails", async () => {
    const brokenEnv = { ...testEnv, DB: { batch: async () => { throw new Error("private storage failure"); },
      prepare: testEnv.DB.prepare.bind(testEnv.DB) } } as unknown as Env;
    const requestID = await recordServiceFailure(request, brokenEnv, new HttpError(500, "internal", "private"), now);
    expect(requestID).toMatch(/^[0-9a-f-]{36}$/u);
  });

  it("aggregates failures durably without retaining request content", async () => {
    await Promise.all([1, 2, 3].map(() => recordServiceFailure(request, testEnv, new HttpError(400, "invalidReport", "private error text"), now)));
    const result = await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all();
    expect(result.results).toEqual([{ window_start: now - 60000, route: "reports", status: 400, count: 3 }]);
    const calls: Record<string, unknown>[] = [];
    vi.stubGlobal("fetch", vi.fn(async (_url, init) => {
      calls.push(JSON.parse(init.body)); return new Response(null, { status: 204 });
    }));
    await flushServiceFailureAlerts(testEnv, now + 60000);
    expect(calls).toHaveLength(0); // The window is still open.
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect(calls).toEqual([{
      event: "threading.service-failure.summary", alertID: `${now - 60000}-reports-400-3`,
      route: "reports", status: 400, count: 3, windowStart: "2026-09-16T10:07:00.000Z",
      diagnosticReference: `sf-${now - 60000}-reports-400`,
      example: { operation: "reports", code: "invalidReport", reason: "unclassified", field: "request" },
    }]);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toEqual([]);
  });

  it("retains failed deliveries and preserves counts in the currently open window", async () => {
    await recordServiceFailure(request, testEnv, new HttpError(500, "internal", "private error text"), now);
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 502 })));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toHaveLength(1);
    vi.stubGlobal("fetch", vi.fn(async () => {
      await recordServiceFailure(request, testEnv, new HttpError(500, "internal", "private error text"), now + 15 * 60000);
      return new Response(null, { status: 204 });
    }));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT count FROM service_failure_alerts").all()).results).toEqual([{ count: 1 }]);
  });

  it("delivers pre-migration outbox rows without inventing retained evidence", async () => {
    await testEnv.DB.prepare("INSERT INTO service_failure_alerts VALUES (?, 'push', 400, 1)").bind(now - 60000).run();
    const forward = vi.fn(async () => new Response(null, { status: 204 }));
    vi.stubGlobal("fetch", forward);
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    const call = forward.mock.calls[0] as unknown as [string, { body: string }];
    const body = JSON.parse(call[1].body);
    expect(body.diagnosticReference).toBeUndefined();
    expect(body.example).toBeUndefined();
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_diagnostics").all()).results).toEqual([]);
  });

  it("does not erase a late increment to the closed window being delivered", async () => {
    await recordServiceFailure(request, testEnv, new HttpError(400, "invalidReport", "private error text"), now);
    vi.stubGlobal("fetch", vi.fn(async () => {
      await recordServiceFailure(request, testEnv, new HttpError(400, "invalidReport", "private error text"), now);
      return new Response(null, { status: 204 });
    }));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT count FROM service_failure_alerts").all()).results).toEqual([{ count: 2 }]);
  });

  it("ignores expected auth errors, unrelated paths, and deployment probes", async () => {
    await recordServiceFailure(request, testEnv, new HttpError(401, "unauthorized", "private error text"), now);
    await recordServiceFailure(new Request("https://service.test/private/path"), testEnv, new HttpError(400, "invalid", "private error text"), now);
    await recordServiceFailure(new Request("https://service.test/v1/reports/validate"), testEnv, new HttpError(400, "invalid", "private error text"), now);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toEqual([]);
  });

  it("receiver validates, forwards and deduplicates failure summaries", async () => {
    const token = "test-only-alert-token-with-at-least-32-bytes";
    const receiverEnv = { REPORT_ALERT_WEBHOOK_TOKEN: token, PUSHOVER_APP_TOKEN: "a".repeat(30), PUSHOVER_USER_KEY: "b".repeat(30) };
    const forward = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", forward);
    const payload = { event: "threading.service-failure.summary", alertID: `${now - 60000}-reports-400-2`,
      route: "reports", status: 400, count: 2, windowStart: "2026-09-16T10:07:00.000Z" };
    const make = (body = payload, bearer = token) => new Request("https://alerts.test/v1/report-alert", {
      method: "POST", headers: { Authorization: `Bearer ${bearer}` }, body: JSON.stringify(body),
    });
    expect((await receiver.fetch(make(payload, "wrong"), receiverEnv)).status).toBe(401);
    expect((await receiver.fetch(make({ ...payload, route: "private/path" }), receiverEnv)).status).toBe(400);
    expect((await receiver.fetch(make(), receiverEnv)).status).toBe(204);
    expect((await receiver.fetch(make(), receiverEnv)).status).toBe(204);
    expect(forward).toHaveBeenCalledTimes(1);
    const form = forward.mock.calls[0] as unknown as [string, { body: URLSearchParams }];
    expect(form[1].body.get("message")).toContain("2 failed reports requests");
  });

  it("receiver includes an actionable reference and rejects extra diagnostic data", async () => {
    const token = "test-only-alert-token-with-at-least-32-bytes";
    const receiverEnv = { REPORT_ALERT_WEBHOOK_TOKEN: token, PUSHOVER_APP_TOKEN: "a".repeat(30), PUSHOVER_USER_KEY: "b".repeat(30) };
    const forward = vi.fn(async () => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", forward);
    const payload = { event: "threading.service-failure.summary", alertID: `${now - 60000}-push-400-1`,
      route: "push", status: 400, count: 1, windowStart: "2026-09-16T10:07:00.000Z",
      diagnosticReference: `sf-${now - 60000}-push-400`,
      example: { operation: "push.register", code: "invalidRequest", reason: "invalidValue", field: "deviceToken" } };
    const make = (value: unknown) => new Request("https://alerts.test/v1/report-alert", {
      method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(value),
    });
    expect((await receiver.fetch(make({ ...payload, diagnosticReference: "different-bucket" }), receiverEnv)).status).toBe(400);
    expect((await receiver.fetch(make({ ...payload, example: { ...payload.example, body: "private" } }), receiverEnv)).status).toBe(400);
    expect((await receiver.fetch(make({ ...payload, example: { ...payload.example, field: "private\ntext" } }), receiverEnv)).status).toBe(400);
    expect((await receiver.fetch(make({ ...payload, example: { ...payload.example, operation: "reports" } }), receiverEnv)).status).toBe(400);
    expect((await receiver.fetch(make(payload), receiverEnv)).status).toBe(204);
    const form = forward.mock.calls[0] as unknown as [string, { body: URLSearchParams }];
    expect(form[1].body.get("message")).toContain("push.register: invalidRequest / invalidValue (deviceToken)");
    expect(form[1].body.get("message")).toContain(payload.diagnosticReference);
  });
});
