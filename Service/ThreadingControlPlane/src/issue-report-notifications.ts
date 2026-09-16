import { ISSUE_REPORT_BOUNDS } from "./issue-report-intake";
import type { Env } from "./environment";

const reportKeyPattern = /^reports\/v1\/([0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.json$/u;
const safeTokenPattern = /^[A-Za-z0-9._:-]+$/u;
const acceptedKinds = new Set(["report", "crash", "diagnostics"]);
const acceptedTriggers = new Set([
  "shake", "diagnostics", "connectionRecovery", "manual", "postCrash",
]);
const acceptedSources = new Set(["iOSClient", "macOSHost"]);

interface R2EventNotification {
  action?: unknown;
  bucket?: unknown;
  object?: {
    key?: unknown;
    size?: unknown;
  };
}

interface TriageNotification {
  event: "threading.issue-report.received";
  reportID: string;
  reference: string;
  kind: string;
  trigger: string;
  source: string;
  receivedAt: string;
  size: number;
}

export async function handleIssueReportNotificationBatch(
  batch: MessageBatch<unknown>,
  env: Env,
): Promise<void> {
  await Promise.all(batch.messages.map((message) => handleMessage(message, env)));
}

export function configuredReportAlertWebhook(env: Env): URL | null {
  const raw = env.REPORT_ALERT_WEBHOOK_URL;
  if (raw === undefined && env.LOCAL_DEVELOPMENT_MODE === "1") return null;
  if (typeof raw !== "string" || new TextEncoder().encode(raw).byteLength > 2048) {
    throw new Error("report alert webhook is not configured");
  }
  const url = new URL(raw);
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password
    || url.search || url.hash) {
    throw new Error("report alert webhook is invalid");
  }
  return url;
}

export function validateReportAlertConfiguration(env: Env): void {
  const url = configuredReportAlertWebhook(env);
  if (url === null) return;
  const token = env.REPORT_ALERT_WEBHOOK_TOKEN;
  if (typeof token !== "string" || new TextEncoder().encode(token).byteLength < 32
    || new TextEncoder().encode(token).byteLength > 4096
    || /[\u0000-\u0020\u007f]/u.test(token)) {
    throw new Error("report alert webhook credential is invalid");
  }
}

async function handleMessage(message: Message<unknown>, env: Env): Promise<void> {
  const event = asEvent(message.body);
  if (!event) {
    console.warn("issue_report_notification_invalid", { reason: "event" });
    message.ack();
    return;
  }
  if (event.bucket !== env.ISSUE_REPORTS_BUCKET_NAME) {
    console.warn("issue_report_notification_invalid", { reason: "bucket" });
    message.ack();
    return;
  }
  const match = reportKeyPattern.exec(event.object.key);
  if (!match?.[1]) {
    console.warn("issue_report_notification_invalid", { reason: "key" });
    message.ack();
    return;
  }

  try {
    const object = await env.ISSUE_REPORTS.head(event.object.key);
    if (!object) throw new Error("committed report object is unavailable");
    const metadata = object.customMetadata ?? {};
    const reportID = metadata.reportID;
    const kind = metadata.kind;
    const trigger = metadata.trigger;
    const source = metadata.source;
    const receivedAt = metadata.receivedAt;
    if (reportID !== match[1] || !acceptedKinds.has(kind ?? "")
      || !acceptedTriggers.has(trigger ?? "") || !acceptedSources.has(source ?? "")
      || typeof receivedAt !== "string" || !Number.isFinite(Date.parse(receivedAt))
      || !safeToken(reportID) || !safeToken(receivedAt)) {
      throw new Error("committed report metadata is invalid");
    }
    const notification: TriageNotification = {
      event: "threading.issue-report.received",
      reportID,
      reference: reportReference(reportID),
      kind: kind!,
      trigger: trigger!,
      source: source!,
      receivedAt,
      size: object.size,
    };
    await deliver(notification, env);
    console.info("issue_report_notification_delivered", {
      reportID,
      kind,
      source,
    });
    message.ack();
  } catch (error) {
    console.warn("issue_report_notification_failed", {
      reportID: match[1],
      reason: error instanceof Error ? error.name : "unknown",
    });
    message.retry({ delaySeconds: 60 });
  }
}

function asEvent(value: unknown): {
  action: "PutObject";
  bucket: string;
  object: { key: string; size: number };
} | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const event = value as R2EventNotification;
  if (event.action !== "PutObject" || typeof event.bucket !== "string"
    || !event.object || typeof event.object.key !== "string"
    || typeof event.object.size !== "number" || !Number.isSafeInteger(event.object.size)
    || event.object.size < 1 || event.object.size > ISSUE_REPORT_BOUNDS.requestBytes + 4 * 1024) return null;
  return {
    action: "PutObject",
    bucket: event.bucket,
    object: { key: event.object.key, size: event.object.size },
  };
}

async function deliver(notification: TriageNotification, env: Env): Promise<void> {
  validateReportAlertConfiguration(env);
  const url = configuredReportAlertWebhook(env);
  if (url === null) return;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.REPORT_ALERT_WEBHOOK_TOKEN!}`,
      "Content-Type": "application/json",
      "Idempotency-Key": notification.reportID,
    },
    body: JSON.stringify(notification),
    signal: AbortSignal.timeout(5000),
  });
  await response.body?.cancel();
  if (!response.ok) throw new Error(`triage webhook returned ${response.status}`);
}

function reportReference(reportID: string): string {
  return `RPT-${reportID.replaceAll("-", "").slice(0, 12).toUpperCase()}`;
}

function safeToken(value: string): boolean {
  return value.length > 0 && value.length <= 160 && safeTokenPattern.test(value);
}
