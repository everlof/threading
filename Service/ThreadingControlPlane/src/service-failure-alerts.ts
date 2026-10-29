import type { Env } from "./environment";
import { HttpError } from "./environment";
import { sha256Hex } from "./crypto";
import { json } from "./http";
import { authorizeDeveloper } from "./issue-report-pickup";
import { failurePrincipal, type FailureField, type FailureReason } from "./service-failure-context";
import { configuredReportAlertWebhook, validateReportAlertConfiguration } from "./issue-report-notifications";

const windowMS = 15 * 60 * 1000;
const cronOffsetMS = 7 * 60 * 1000;
const retentionMS = 7 * 24 * 60 * 60 * 1000;
const maximumSamples = 8;
const routes = new Set(["reports", "auth", "push", "hosts", "account", "rendezvous"]);
const statuses = new Set([400, 409, 413, 415, 429, 500, 502, 503, 504]);
// Fail closed if a future error accidentally passes through provider or submitted text.
const codes = new Set([
  "internal", "invalidRequest", "invalidJSON", "invalidPush", "invalidHost", "invalidPath",
  "invalidReport", "invalidIdempotencyKey", "idempotencyConflict", "identityTokenReplayed",
  "hostAlreadyRegistered", "developmentAuthConsumed", "developmentAuthPending",
  "requestTooLarge", "pushTooLarge", "diagnosticsTooLarge", "imagePreviewTooLarge",
  "unsupportedEncoding", "unsupportedMediaType", "rateLimited", "reportCapacity",
  "installationLimit", "sessionLimit", "deviceLimit", "hostLimit", "pushUnavailable",
  "serviceConfiguration", "serviceState", "appleResponse", "appleRevocation", "appleValidation",
]);

interface FailureSample {
  requestID: string;
  occurredAt: string;
  operation: string;
  code: string;
  reason: FailureReason | "unclassified";
  field: FailureField;
  accountRef?: string;
  hostRef?: string;
  deviceRef?: string;
}

interface FailureRecord {
  window_start: number;
  route: string;
  status: number;
  count: number;
  first_seen: number;
  last_seen: number;
  samples: string;
}

function diagnosticReference(window: number, route: string, status: number): string {
  return `sf-${window}-${route}-${status}`;
}

function bucket(now: number): number {
  return Math.floor((now - cronOffsetMS) / windowMS) * windowMS + cronOffsetMS;
}

export async function recordServiceFailure(
  request: Request, env: Env, error: HttpError, now = Date.now(),
): Promise<string | undefined> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1" || env.DEVELOPMENT_AUTH_MODE) return;
  const path = new URL(request.url).pathname;
  const route = path.split("/")[2] ?? "";
  const { status } = error;
  // Release probes have their own fail-closed caller; never page for deliberate probes.
  if (path === "/v1/reports/validate" || !path.startsWith("/v1/")
    || !routes.has(route) || !statuses.has(status)) return;
  const requestID = crypto.randomUUID();
  const window = bucket(now);
  try {
    const sample: FailureSample = {
      requestID,
      occurredAt: new Date(now).toISOString(),
      operation: path === "/v1/push" ? "push.send"
        : path === "/v1/push/registrations" ? "push.register"
        : path === "/v1/push/retractions" ? "push.retract" : route,
      code: codes.has(error.code) ? error.code : "other",
      reason: error.diagnostic?.reason ?? "unclassified",
      field: error.diagnostic?.field ?? "request",
      ...await principalReferences(request),
    };
    const encoded = JSON.stringify(sample);
    console.warn("service_http_failure", {
      route, status, diagnosticReference: diagnosticReference(window, route, status), ...sample,
    });
    // Same transaction, with an atomic bounded append: concurrent failures cannot lose counts
    // or exceed eight examples. Evidence is independent of the pending-alert outbox.
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO service_failure_alerts (window_start, route, status, count) VALUES (?, ?, ?, 1) "
        + "ON CONFLICT(window_start, route, status) DO UPDATE SET count = MIN(count + 1, 1000000000)",
      ).bind(window, route, status),
      env.DB.prepare(
        "INSERT INTO service_failure_diagnostics "
        + "(window_start, route, status, count, first_seen, last_seen, samples) "
        + "VALUES (?, ?, ?, 1, ?, ?, json_array(json(?))) "
        + "ON CONFLICT(window_start, route, status) DO UPDATE SET "
        + "count = MIN(count + 1, 1000000000), "
        + "first_seen = MIN(first_seen, excluded.first_seen), last_seen = MAX(last_seen, excluded.last_seen), "
        + "samples = CASE WHEN json_array_length(samples) < ? "
        + "THEN json_insert(samples, '$[#]', json(?)) ELSE samples END",
      ).bind(window, route, status, now, now, encoded, maximumSamples, encoded),
    ]);
  } catch {
    // Monitoring must never replace the response the app needs to interpret.
    console.error("service_failure_recording_failed", { route, status, requestID });
  }
  return requestID;
}

async function principalReferences(request: Request): Promise<Pick<FailureSample, "accountRef" | "hostRef" | "deviceRef">> {
  const principal = failurePrincipal(request);
  if (!principal) return {};
  const reference = async (kind: string, value: string) =>
    `${kind}-${(await sha256Hex(`threading-service-failure:${kind}:${value}`)).slice(0, 24)}`;
  const [accountRef, hostRef, deviceRef] = await Promise.all([
    reference("account", principal.accountID),
    reference("host", principal.hostID),
    principal.kind === "device" ? reference("device", principal.deviceID) : undefined,
  ]);
  return { accountRef, hostRef, ...(deviceRef ? { deviceRef } : {}) };
}

/** The existing developer pickup credential reads bounded evidence, never an app credential. */
export async function handleServiceFailurePickup(request: Request, env: Env, reference: string): Promise<Response> {
  await authorizeDeveloper(request, env);
  const match = /^sf-([0-9]{13})-(reports|auth|push|hosts|account|rendezvous)-(400|409|413|415|429|500|502|503|504)$/u.exec(reference);
  const window = Number(match?.[1]);
  if (!match || bucket(window) !== window || window < Date.now() - retentionMS) {
    throw new HttpError(404, "notFound", "Service failure diagnostic was not found or has expired");
  }
  const row = await env.DB.prepare(
    "SELECT * FROM service_failure_diagnostics WHERE window_start = ? AND route = ? AND status = ?",
  ).bind(window, match[2], Number(match[3])).first<FailureRecord>();
  if (!row) throw new HttpError(404, "notFound", "Service failure diagnostic was not found or has expired");
  const samples = JSON.parse(row.samples) as FailureSample[];
  return json({
    reference, windowStart: new Date(window).toISOString(),
    route: row.route, status: row.status, count: row.count,
    firstSeen: new Date(row.first_seen).toISOString(), lastSeen: new Date(row.last_seen).toISOString(),
    expiresAt: new Date(window + retentionMS).toISOString(),
    sampleLimit: maximumSamples, omittedCount: row.count - samples.length, samples,
  });
}

export async function flushServiceFailureAlerts(env: Env, now = Date.now()): Promise<void> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1" || env.DEVELOPMENT_AUTH_MODE) return;
  try {
    await env.DB.batch([
      env.DB.prepare("DELETE FROM service_failure_alerts WHERE window_start < ?").bind(now - retentionMS),
      env.DB.prepare("DELETE FROM service_failure_diagnostics WHERE window_start < ?").bind(now - retentionMS),
    ]);
    validateReportAlertConfiguration(env);
    const url = configuredReportAlertWebhook(env);
    if (!url) return;
    // Only closed windows: increments during an alert cannot be lost by its deletion.
    const result = await env.DB.prepare(
      "SELECT window_start, route, status, count FROM service_failure_alerts "
      + "WHERE window_start < ? ORDER BY window_start, route, status LIMIT 64",
    ).bind(bucket(now)).all<{ window_start: number; route: string; status: number; count: number }>();
    for (const row of result.results) {
      const alertID = `${row.window_start}-${row.route}-${row.status}-${row.count}`;
      const evidence = await env.DB.prepare(
        "SELECT samples FROM service_failure_diagnostics WHERE window_start = ? AND route = ? AND status = ?",
      ).bind(row.window_start, row.route, row.status).first<{ samples: string }>();
      const sample = evidence ? (JSON.parse(evidence.samples) as FailureSample[])[0] : undefined;
      const response = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${env.REPORT_ALERT_WEBHOOK_TOKEN!}`, "Content-Type": "application/json" },
        body: JSON.stringify({ event: "threading.service-failure.summary", alertID,
          route: row.route, status: row.status, count: row.count,
          windowStart: new Date(row.window_start).toISOString(),
          ...(sample ? {
            diagnosticReference: diagnosticReference(row.window_start, row.route, row.status),
            example: { operation: sample.operation, code: sample.code, reason: sample.reason, field: sample.field },
          } : {}),
        }),
        signal: AbortSignal.timeout(5000),
      });
      await response.body?.cancel();
      if (!response.ok) throw new Error("alert delivery failed");
      await env.DB.prepare(
        "DELETE FROM service_failure_alerts WHERE window_start = ? AND route = ? AND status = ? AND count = ?",
      ).bind(row.window_start, row.route, row.status, row.count).run();
    }

  } catch {
    // The next cron retries durable rows; a receiver outage cannot lose the alert.
    console.error("service_failure_alert_delivery_failed");
  }
}
