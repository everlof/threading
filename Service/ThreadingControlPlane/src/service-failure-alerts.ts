import type { Env } from "./environment";
import { configuredReportAlertWebhook, validateReportAlertConfiguration } from "./issue-report-notifications";

const windowMS = 15 * 60 * 1000;
const cronOffsetMS = 7 * 60 * 1000;
const routes = new Set(["reports", "auth", "push", "hosts", "account", "rendezvous"]);
const statuses = new Set([400, 409, 413, 415, 429, 500, 502, 503, 504]);

function bucket(now: number): number {
  return Math.floor((now - cronOffsetMS) / windowMS) * windowMS + cronOffsetMS;
}

export async function recordServiceFailure(
  request: Request, env: Env, status: number, code: string, now = Date.now(),
): Promise<void> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1" || env.DEVELOPMENT_AUTH_MODE) return;
  const path = new URL(request.url).pathname;
  const route = path.split("/")[2] ?? "";
  // Release probes have their own fail-closed caller; never page for deliberate probes.
  if (path === "/v1/reports/validate" || !path.startsWith("/v1/")
    || !routes.has(route) || !statuses.has(status)) return;
  // Only server-owned status/code and a fixed route family. Never include the URL/body/message.
  console.warn("service_http_failure", { route, status, code });
  try {
    await env.DB.prepare(
      "INSERT INTO service_failure_alerts (window_start, route, status, count) VALUES (?, ?, ?, 1) "
      + "ON CONFLICT(window_start, route, status) DO UPDATE SET count = MIN(count + 1, 1000000000)",
    ).bind(bucket(now), route, status).run();
  } catch {
    // Monitoring must never replace the response the app needs to interpret.
    console.error("service_failure_recording_failed", { route, status });
  }
}

export async function flushServiceFailureAlerts(env: Env, now = Date.now()): Promise<void> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1" || env.DEVELOPMENT_AUTH_MODE) return;
  try {
    await env.DB.prepare("DELETE FROM service_failure_alerts WHERE window_start < ?")
      .bind(now - 7 * 24 * 60 * 60 * 1000).run();
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
      const response = await fetch(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${env.REPORT_ALERT_WEBHOOK_TOKEN!}`, "Content-Type": "application/json" },
        body: JSON.stringify({ event: "threading.service-failure.summary", alertID,
          route: row.route, status: row.status, count: row.count,
          windowStart: new Date(row.window_start).toISOString() }),
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
