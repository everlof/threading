import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import { diagnosticContractFingerprint } from "../src/issue-report-contract.generated";
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
      diagnosticNormalization: {
        contractFingerprint: diagnosticContractFingerprint,
        droppedUnknownFieldCount: 0,
        droppedUnknownRecordCount: 0,
      },
      report: {
        id: report.id,
        description: report.description,
        diagnostics: {
          source: "iOSClient",
          additionalDetails: {
            connectionStateHistory: "connecting-3:online-1",
            attachmentPreviewHistory: "pdf.start-3:pdf.fail-1",
          },
        },
      },
    });
    expect(stored?.customMetadata).toMatchObject({
      reportID: report.id,
      schemaVersion: "1",
      source: "iOSClient",
      trigger: "diagnostics",
      kind: "diagnostics",
      diagnosticContract: diagnosticContractFingerprint,
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
    report.diagnostics.records.push({
      timestamp: report.createdAt,
      source: "iOSClient",
      level: "info",
      event: "hostDiscoveryMatched",
      fields: {
        peer: "peer-a1b2c3d4e5f6",
        transport: "lan",
        phase: "resolve",
        result: "matched",
        origin: "origin-a1b2c3d4e5f6",
      },
    });

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

  it("releases the losing reservation when concurrent exact retries race", async () => {
    const report = makeReport();
    const before = await todayCount();
    let pendingInitialHeads = 2;
    let releaseInitialHeads: (() => void) | undefined;
    const initialHeadsComplete = new Promise<void>((resolve) => {
      releaseInitialHeads = resolve;
    });
    const bucket = {
      async head(key: string): Promise<R2Object | null> {
        if (pendingInitialHeads > 0) {
          pendingInitialHeads -= 1;
          if (pendingInitialHeads === 0) releaseInitialHeads?.();
          await initialHeadsComplete;
          return null;
        }
        return testEnv.ISSUE_REPORTS.head(key);
      },
      put(key: string, value: ArrayBuffer | ArrayBufferView | string, options?: R2PutOptions) {
        return testEnv.ISSUE_REPORTS.put(key, value, options);
      },
    } as R2Bucket;
    const concurrentEnv = withReportBucket(bucket);

    const responses = await Promise.all([
      submit(report, concurrentEnv),
      submit(report, concurrentEnv),
    ]);

    expect(responses.map((response) => response.status).sort()).toEqual([200, 201]);
    expect(await todayCount()).toBe(before + 1);
  });

  it("releases a reservation when report storage fails", async () => {
    const report = makeReport();
    const before = await todayCount();
    const storageFailure = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const bucket = {
      head(key: string): Promise<R2Object | null> {
        return testEnv.ISSUE_REPORTS.head(key);
      },
      async put(): Promise<R2Object> {
        throw new Error("simulated R2 failure");
      },
    } as unknown as R2Bucket;

    const response = await submit(report, withReportBucket(bucket));

    expect(response.status).toBe(500);
    expect(await todayCount()).toBe(before);
    storageFailure.mockRestore();
  });

  it("rejects unknown structural fields and content-bearing known diagnostic values", async () => {
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

    const rawOrigin = makeReport();
    rawOrigin.diagnostics.records[0]!.fields.origin = "192.168.1.42:8760";
    expect((await submit(rawOrigin)).status).toBe(400);

    const prefixedRawOrigin = makeReport();
    prefixedRawOrigin.diagnostics.records[0]!.fields.origin = "origin-192.168.1.42:8760";
    expect((await submit(prefixedRawOrigin)).status).toBe(400);

    const proseDuration = makeReport();
    proseDuration.diagnostics.records[0]!.fields.durationMS = "fifteen-seconds";
    expect((await submit(proseDuration)).status).toBe(400);

    const hostEventFromIOS = makeReport();
    hostEventFromIOS.diagnostics.records[0]!.event = "hostListenerStarted";
    expect((await submit(hostEventFromIOS)).status).toBe(400);

    const malformedFutureEvent = makeReport();
    malformedFutureEvent.diagnostics.records.push({
      timestamp: malformedFutureEvent.createdAt,
      source: "iOSClient",
      level: "warning",
      event: "futureRouteEvent",
      fields: "not-an-object" as unknown as Record<string, string>,
    });
    expect((await submit(malformedFutureEvent)).status).toBe(400);
  });

  it("drops and counts unknown diagnostic vocabulary without retaining its content", async () => {
    const report = makeReport();
    report.diagnostics.additionalDetails.futureConnectionDetail = "private future detail";
    report.diagnostics.records[0]!.fields.futureRouteField = "private future field";
    report.diagnostics.records.push({
      timestamp: report.createdAt,
      source: "iOSClient",
      level: "warning",
      event: "futureRouteEvent",
      fields: { futurePayload: "private future payload" },
    });

    expect((await submit(report)).status).toBe(201);
    const stored = await testEnv.ISSUE_REPORTS.get(`reports/v1/${report.id}.json`);
    const envelope = await stored?.json<{
      diagnosticNormalization: {
        contractFingerprint: string;
        droppedUnknownFieldCount: number;
        droppedUnknownRecordCount: number;
      };
      report: TestReport;
    }>();
    expect(envelope?.diagnosticNormalization).toEqual({
      contractFingerprint: diagnosticContractFingerprint,
      droppedUnknownFieldCount: 2,
      droppedUnknownRecordCount: 1,
    });
    expect(envelope?.report.diagnostics.additionalDetails).not.toHaveProperty(
      "futureConnectionDetail",
    );
    expect(envelope?.report.diagnostics.records[0]?.fields).not.toHaveProperty(
      "futureRouteField",
    );
    expect(envelope?.report.diagnostics.records).toHaveLength(1);
    expect(JSON.stringify(envelope)).not.toContain("private future");
  });

  it("includes normalization loss in idempotency", async () => {
    const report = makeReport();
    report.diagnostics.records[0]!.fields.futureRouteField = "dropped";
    expect((await submit(report)).status).toBe(201);

    const changedLoss = structuredClone(report);
    changedLoss.diagnostics.records[0]!.fields.anotherFutureField = "also-dropped";
    const conflict = await submit(changedLoss);
    expect(conflict.status).toBe(409);
    await expect(conflict.json()).resolves.toMatchObject({
      error: { code: "idempotencyConflict" },
    });
  });

  it("rejects nonnumeric values for every duration field in the shared contract", async () => {
    for (const field of [
      "durationMS",
      "timeoutMS",
      "delayMS",
      "dnsMS",
      "tcpMS",
      "tlsMS",
      "serverWaitMS",
      "responseMS",
    ]) {
      const report = makeReport();
      report.diagnostics.records[0]!.fields[field] = "not-a-number";
      expect((await submit(report)).status, field).toBe(400);
    }
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

  it("stores up to four reviewed image previews and rejects malformed collections", async () => {
    const jpegBase64 = bytesToBase64([0xff, 0xd8, 0xff, 0xd9]);
    const report = makeReport();
    report.imagePreviews = Array.from({ length: 4 }, () => ({ jpegBase64 }));

    expect((await submit(report)).status).toBe(201);
    const stored = await testEnv.ISSUE_REPORTS.get(`reports/v1/${report.id}.json`);
    const envelope = await stored?.json<{ report: TestReport }>();
    expect(envelope?.report.imagePreviews).toEqual(report.imagePreviews);

    const empty = makeReport();
    empty.imagePreviews = [];
    expect((await submit(empty)).status).toBe(400);

    const tooMany = makeReport();
    tooMany.imagePreviews = Array.from({ length: 5 }, () => ({ jpegBase64 }));
    expect((await submit(tooMany)).status).toBe(400);

    const malformed = makeReport();
    malformed.imagePreviews = [{ jpegBase64: btoa("not a jpeg") }];
    expect((await submit(malformed)).status).toBe(400);

    const combined = makeReport();
    combined.screenshotPreviewBase64 = jpegBase64;
    combined.screenshotMediaType = "image/jpeg";
    combined.imagePreviews = Array.from({ length: 4 }, () => ({ jpegBase64 }));
    expect((await submit(combined)).status).toBe(400);
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
  imagePreviews?: Array<{ jpegBase64: string }>;
  accidentalSecret?: string;
}

function bytesToBase64(bytes: number[]): string {
  return btoa(String.fromCharCode(...bytes));
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
      additionalDetails: {
        connectionState: "connected",
        connectionStateHistory: "connecting-3:online-1",
        attachmentPreviewHistory: "pdf.start-3:pdf.fail-1",
      },
      records: [{
        timestamp: now,
        source: "iOSClient",
        level: "info",
        event: "hostRouteEnded",
        fields: {
          transport: "hosted",
          trace: "trace-123",
          phase: "hosted.awaitingHost",
          result: "failed",
          durationMS: "15017",
          timeoutMS: "15000",
          delayMS: "0",
          networkStage: "response",
          dnsMS: "12",
          tcpMS: "23",
          tlsMS: "34",
          serverWaitMS: "45",
          responseMS: "56",
          networkProtocol: "h2",
          networkPath: "wifi",
          connectionReused: "true",
          attempt: "1",
          total: "2",
          origin: "origin-abcdef123456",
          detail: "identity.accepted",
        },
      }],
    },
  };
}

async function submit(report: TestReport, targetEnv: Env = testEnv): Promise<Response> {
  return worker.fetch(new Request("https://service.test/v1/reports", {
    method: "POST",
    headers: requestHeaders(report.id),
    body: JSON.stringify(report),
  }), targetEnv);
}

function withReportBucket(bucket: R2Bucket): Env {
  return new Proxy(testEnv, {
    get(target, property, receiver) {
      if (property === "ISSUE_REPORTS") return bucket;
      return Reflect.get(target, property, receiver);
    },
  });
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
