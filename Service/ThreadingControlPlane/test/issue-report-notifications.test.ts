import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import worker from "../src/index";

const testEnv = env as unknown as Env;

afterEach(() => {
  vi.restoreAllMocks();
});

describe("issue-report triage notifications", () => {
  it("delivers only trusted metadata after the private object is committed", async () => {
    const reportID = crypto.randomUUID().toLowerCase();
    const key = `reports/v1/${reportID}.json`;
    const description = "customer-controlled prose must not leave R2";
    const receivedAt = new Date().toISOString();
    const object = await testEnv.ISSUE_REPORTS.put(key, JSON.stringify({ description }), {
      customMetadata: {
        reportID,
        receivedAt,
        schemaVersion: "1",
        source: "macOSHost",
        trigger: "postCrash",
        kind: "crash",
      },
    });
    expect(object).not.toBeNull();
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(null, { status: 204 }),
    );
    const ack = vi.fn();
    const retry = vi.fn();

    await worker.queue(messageBatch(key, object!.size, ack, retry), testEnv);

    expect(ack).toHaveBeenCalledOnce();
    expect(retry).not.toHaveBeenCalled();
    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, options] = fetchSpy.mock.calls[0] ?? [];
    expect(String(url)).toBe("https://triage.test/threading/reports");
    expect(new Headers(options?.headers).get("Authorization"))
      .toBe("Bearer test-only-report-alert-token-at-least-32-bytes");
    const payload = JSON.parse(String(options?.body));
    expect(payload).toEqual({
      event: "threading.issue-report.received",
      reportID,
      reference: `RPT-${reportID.replaceAll("-", "").slice(0, 12).toUpperCase()}`,
      kind: "crash",
      trigger: "postCrash",
      source: "macOSHost",
      receivedAt,
      size: object!.size,
    });
    expect(JSON.stringify(payload)).not.toContain(description);
  });

  it("retries a metadata-only alert when the owned triage endpoint is unavailable", async () => {
    const reportID = crypto.randomUUID().toLowerCase();
    const key = `reports/v1/${reportID}.json`;
    const receivedAt = new Date().toISOString();
    const object = await testEnv.ISSUE_REPORTS.put(key, "{}", {
      customMetadata: {
        reportID,
        receivedAt,
        schemaVersion: "1",
        source: "iOSClient",
        trigger: "manual",
        kind: "report",
      },
    });
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("unavailable", { status: 503 }));
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const ack = vi.fn();
    const retry = vi.fn();

    await worker.queue(messageBatch(key, object!.size, ack, retry), testEnv);

    expect(ack).not.toHaveBeenCalled();
    expect(retry).toHaveBeenCalledWith({ delaySeconds: 60 });
  });
});

function messageBatch(
  key: string,
  size: number,
  ack: () => void,
  retry: (options?: { delaySeconds?: number }) => void,
): MessageBatch<unknown> {
  return {
    queue: "threading-issue-report-events",
    messages: [{
      id: crypto.randomUUID(),
      timestamp: new Date(),
      attempts: 1,
      body: {
        account: "test-account",
        action: "PutObject",
        bucket: "threading-private-issue-reports",
        object: { key, size, eTag: "test-etag" },
        eventTime: new Date().toISOString(),
      },
      ack,
      retry,
    }],
    ackAll: vi.fn(),
    retryAll: vi.fn(),
  } as unknown as MessageBatch<unknown>;
}
