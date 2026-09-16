import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import { recordServiceFailure, flushServiceFailureAlerts } from "../src/service-failure-alerts";
import receiver from "../../ThreadingReportAlerts/src/index";

const testEnv = env as unknown as Env;
const now = Date.parse("2026-09-16T10:08:00.000Z");
const request = new Request("https://service.test/v1/reports?private=secret", {
  method: "POST", body: "private report text", headers: { Authorization: "Bearer secret" },
});

beforeEach(async () => { await testEnv.DB.prepare("DELETE FROM service_failure_alerts").run(); });
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("HTTP failure alerts", () => {
  it("aggregates failures durably without retaining request content", async () => {
    await Promise.all([1, 2, 3].map(() => recordServiceFailure(request, testEnv, 400, "invalidReport", now)));
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
    }]);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toEqual([]);
  });

  it("retains failed deliveries and preserves counts in the currently open window", async () => {
    await recordServiceFailure(request, testEnv, 500, "internal", now);
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 502 })));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT * FROM service_failure_alerts").all()).results).toHaveLength(1);
    vi.stubGlobal("fetch", vi.fn(async () => {
      await recordServiceFailure(request, testEnv, 500, "internal", now + 15 * 60000);
      return new Response(null, { status: 204 });
    }));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT count FROM service_failure_alerts").all()).results).toEqual([{ count: 1 }]);
  });

  it("does not erase a late increment to the closed window being delivered", async () => {
    await recordServiceFailure(request, testEnv, 400, "invalidReport", now);
    vi.stubGlobal("fetch", vi.fn(async () => {
      await recordServiceFailure(request, testEnv, 400, "invalidReport", now);
      return new Response(null, { status: 204 });
    }));
    await flushServiceFailureAlerts(testEnv, now + 15 * 60000);
    expect((await testEnv.DB.prepare("SELECT count FROM service_failure_alerts").all()).results).toEqual([{ count: 2 }]);
  });

  it("ignores expected auth errors, unrelated paths, and deployment probes", async () => {
    await recordServiceFailure(request, testEnv, 401, "unauthorized", now);
    await recordServiceFailure(new Request("https://service.test/private/path"), testEnv, 400, "invalid", now);
    await recordServiceFailure(new Request("https://service.test/v1/reports/validate"), testEnv, 400, "invalid", now);
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
});
