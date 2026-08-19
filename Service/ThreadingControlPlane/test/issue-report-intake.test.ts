import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { ISSUE_REPORT_BOUNDS } from "../src/issue-report-intake";
import worker from "../src/index";

const testEnv = env as unknown as Env;
const pickupToken = "test-only-report-pickup-token-at-least-32-bytes";

describe("private issue-report intake", () => {
  it("stores one normalized report in private R2 and exposes no public read route", async () => {
    const report = makeReport();
    const response = await submit(report);

    expect(response.status).toBe(201);
    await expect(response.json()).resolves.toEqual({
      reportID: report.id,
      reference: `RPT-${report.id.replaceAll("-", "").slice(0, 12).toUpperCase()}`,
      wasAlreadyReceived: false,
    });

    const stored = await testEnv.ISSUE_REPORTS.get(`reports/v1/${report.id}.json`);
    expect(stored).not.toBeNull();
    const envelope = await stored?.json<Record<string, unknown>>();
    expect(envelope).toMatchObject({
      receivedAt: expect.any(String),
      report: {
        id: report.id,
        description: report.description,
        diagnostics: { source: "iOSClient" },
      },
    });
    expect(stored?.customMetadata).toMatchObject({
      reportID: report.id,
      schemaVersion: "1",
      source: "iOSClient",
      trigger: "diagnostics",
      kind: "diagnostics",
    });

    const publicRead = await worker.fetch(new Request(
      `https://service.test/v1/reports/${report.id}`,
      { headers: requestHeaders(report.id) },
    ), testEnv);
    expect(publicRead.status).toBe(404);
  });

  it("accepts a reviewed connection-recovery report from iOS", async () => {
    const report = makeReport();
    report.trigger = "connectionRecovery";

    expect((await submit(report)).status).toBe(201);
  });

  it("makes an exact retry idempotent and refuses reuse with different evidence", async () => {
    const report = makeReport();
    const before = await todayCount();
    expect((await submit(report)).status).toBe(201);
    const afterFirst = await todayCount();
    expect(afterFirst).toBe(before + 1);

    const retry = await submit(report);
    expect(retry.status).toBe(200);
    await expect(retry.json()).resolves.toMatchObject({
      reportID: report.id,
      wasAlreadyReceived: true,
    });
    expect(await todayCount()).toBe(afterFirst);

    const conflict = await submit({ ...report, description: "Different evidence" });
    expect(conflict.status).toBe(409);
    await expect(conflict.json()).resolves.toMatchObject({
      error: { code: "idempotencyConflict" },
    });
    expect(await todayCount()).toBe(afterFirst);
  });

  it("rejects unknown fields and content-bearing diagnostic values", async () => {
    const report = makeReport();
    const unknown = await submit({ ...report, accidentalSecret: "do not retain" });
    expect(unknown.status).toBe(400);
    await expect(unknown.json()).resolves.toMatchObject({ error: { code: "invalidRequest" } });

    const diagnosticText = makeReport();
    diagnosticText.diagnostics.records[0]!.fields.reason = "a path /Users/person/project";
    const rejectedText = await submit(diagnosticText);
    expect(rejectedText.status).toBe(400);
    await expect(rejectedText.json()).resolves.toMatchObject({
      error: { code: "invalidReport" },
    });
  });

  it("accepts joined client records only inside a Mac host report", async () => {
    const joined = makeReport();
    joined.trigger = "manual";
    joined.diagnostics.source = "macOSHost";
    joined.diagnostics.records[0]!.source = "iOSClient";
    joined.diagnostics.records.push({
      timestamp: joined.createdAt,
      source: "browserClient",
      level: "info",
      event: "socketConnected",
      fields: { transport: "webrtc" },
    });
    expect((await submit(joined)).status).toBe(201);

    const browserReport = makeReport();
    browserReport.diagnostics.source = "browserClient";
    browserReport.diagnostics.records[0]!.source = "browserClient";
    const rejected = await submit(browserReport);
    expect(rejected.status).toBe(400);
    await expect(rejected.json()).resolves.toMatchObject({
      error: { code: "invalidReport" },
    });
  });

  it("enforces the byte ceiling while streaming when Content-Length is absent", async () => {
    const report = makeReport();
    const request = new Request("https://service.test/v1/reports", {
      method: "POST",
      headers: requestHeaders(report.id),
      body: "x".repeat(ISSUE_REPORT_BOUNDS.requestBytes + 1),
    });
    expect(request.headers.get("Content-Length")).toBeNull();

    const response = await worker.fetch(request, testEnv);

    expect(response.status).toBe(413);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "requestTooLarge" },
    });
  });

  it("requires matching idempotency and paired, bounded JPEG fields", async () => {
    const report = makeReport();
    const mismatched = await worker.fetch(new Request("https://service.test/v1/reports", {
      method: "POST",
      headers: requestHeaders(crypto.randomUUID()),
      body: JSON.stringify(report),
    }), testEnv);
    expect(mismatched.status).toBe(400);

    const unpaired = makeReport();
    unpaired.screenshotPreviewBase64 = btoa("not a jpeg");
    const rejectedUnpaired = await submit(unpaired);
    expect(rejectedUnpaired.status).toBe(400);

    const notJPEG = makeReport();
    notJPEG.screenshotPreviewBase64 = btoa("not a jpeg");
    notJPEG.screenshotMediaType = "image/jpeg";
    const rejectedImage = await submit(notJPEG);
    expect(rejectedImage.status).toBe(400);
  });

  it("requires the developer secret to list or retrieve private reports", async () => {
    const report = makeReport();
    expect((await submit(report)).status).toBe(201);

    const unauthenticated = await worker.fetch(new Request(
      "https://service.test/v1/developer/reports",
    ), testEnv);
    expect(unauthenticated.status).toBe(401);

    const wrongCredential = await worker.fetch(new Request(
      "https://service.test/v1/developer/reports",
      { headers: { Authorization: "Bearer definitely-not-the-pickup-token" } },
    ), testEnv);
    expect(wrongCredential.status).toBe(403);

    const listed = await worker.fetch(new Request(
      "https://service.test/v1/developer/reports?limit=100",
      { headers: pickupHeaders() },
    ), testEnv);
    expect(listed.status).toBe(200);
    const listing = await listed.json<{
      reports: Array<Record<string, unknown>>;
      cursor: string | null;
    }>();
    expect(listing.reports).toContainEqual(expect.objectContaining({
      reportID: report.id,
      source: "iOSClient",
      trigger: "diagnostics",
      kind: "diagnostics",
      size: expect.any(Number),
    }));
    expect(JSON.stringify(listing)).not.toContain(report.description);
    expect(JSON.stringify(listing)).not.toContain("screenshotPreviewBase64");

    const retrieved = await worker.fetch(new Request(
      `https://service.test/v1/developer/reports/${report.id}`,
      { headers: pickupHeaders() },
    ), testEnv);
    expect(retrieved.status).toBe(200);
    await expect(retrieved.json()).resolves.toMatchObject({
      report: { id: report.id, description: report.description },
    });
    expect(retrieved.headers.get("Cache-Control")).toBe("no-store");
  });
});

interface TestReport {
  schemaVersion: number;
  id: string;
  createdAt: string;
  trigger: string;
  description: string;
  diagnostics: {
    schemaVersion: number;
    generatedAt: string;
    source: string;
    appVersion: string;
    appBuild: string;
    operatingSystem: string;
    protocolVersion: number;
    minimumProtocolVersion: number;
    additionalDetails: Record<string, string>;
    records: Array<{
      timestamp: string;
      source: string;
      level: string;
      event: string;
      fields: Record<string, string>;
    }>;
  };
  screenshotPreviewBase64?: string;
  screenshotMediaType?: string;
  accidentalSecret?: string;
}

function makeReport(): TestReport {
  const now = new Date().toISOString();
  return {
    schemaVersion: 1,
    id: crypto.randomUUID().toLowerCase(),
    createdAt: now,
    trigger: "diagnostics",
    description: "The composer stopped responding.",
    diagnostics: {
      schemaVersion: 1,
      generatedAt: now,
      source: "iOSClient",
      appVersion: "1.0",
      appBuild: "1",
      operatingSystem: "iOS 19.0",
      protocolVersion: 1,
      minimumProtocolVersion: 1,
      additionalDetails: { connectionState: "connected" },
      records: [{
        timestamp: now,
        source: "iOSClient",
        level: "info",
        event: "socketConnected",
        fields: { transport: "webrtc", trace: "trace-123" },
      }],
    },
  };
}

async function submit(report: TestReport): Promise<Response> {
  return worker.fetch(new Request("https://service.test/v1/reports", {
    method: "POST",
    headers: requestHeaders(report.id),
    body: JSON.stringify(report),
  }), testEnv);
}

function requestHeaders(reportID: string): HeadersInit {
  return {
    "CF-Connecting-IP": `192.0.2.${Math.floor(Math.random() * 200) + 1}`,
    "Content-Type": "application/json",
    "Idempotency-Key": reportID,
  };
}

function pickupHeaders(): HeadersInit {
  return {
    Authorization: `Bearer ${pickupToken}`,
    "CF-Connecting-IP": `198.51.100.${Math.floor(Math.random() * 200) + 1}`,
  };
}

async function todayCount(): Promise<number> {
  const day = new Date().toISOString().slice(0, 10);
  const row = await testEnv.DB.prepare(
    "SELECT accepted_count FROM issue_report_daily_quota WHERE day = ?",
  ).bind(day).first<{ accepted_count: number }>();
  return row?.accepted_count ?? 0;
}
