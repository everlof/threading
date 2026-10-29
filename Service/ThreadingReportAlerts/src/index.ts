/// The owned triage receiver for `REPORT_ALERT_WEBHOOK_URL`.
///
/// The control plane will not post to a third party directly, and could not usefully do so: it
/// sends its own JSON shape under an `Authorization: Bearer`, and rejects any URL carrying a
/// query string or fragment, which is how most webhook services carry their credential. So this
/// sits in between, owns the credential check and the deduplication the runbook requires, and
/// translates one bounded metadata event into whatever channel the operator actually reads.
///
/// It deliberately holds nothing. No report content ever reaches it — the event carries an ID, a
/// reference, three enum-ish tokens, a timestamp and a byte count — and it stores none of that
/// beyond a dedup marker.
///
/// **The channel is Pushover, and ntfy was tried first.** ntfy.sh meters anonymous publishing per
/// source IP, and a Worker egresses from addresses shared with everyone else on Cloudflare, so
/// that pool sits permanently over the limit: every forward returned 429. A free ntfy account did
/// not help either, because account-based metering is a paid tier there. Pushover meters per
/// application token, which does not depend on where the request came from. Do not "simplify"
/// this back to ntfy without re-testing from a *deployed Worker* rather than a laptop; a laptop
/// has its own IP budget and will happily succeed while production does not.

interface Env {
  /// The same value installed on the control plane. Both sides must agree or delivery fails
  /// closed, which is the point: an unauthenticated caller must not be able to page the operator.
  REPORT_ALERT_WEBHOOK_TOKEN: string;
  /// Identifies this application to Pushover. Metering is per application token.
  PUSHOVER_APP_TOKEN: string;
  /// Identifies the account that receives the notification.
  PUSHOVER_USER_KEY: string;
}

/// The event the control plane sends. Mirrored here by hand rather than shared, because these are
/// two independently deployed services and a shared type would imply a coupling that does not
/// exist on the wire.
interface TriageNotification {
  event: string;
  reportID: string;
  reference: string;
  kind: string;
  trigger: string;
  source: string;
  receivedAt: string;
  size: number;
}

interface FailureNotification {
  event: "threading.service-failure.summary";
  alertID: string;
  route: string;
  status: number;
  count: number;
  windowStart: string;
  diagnosticReference?: string;
  example?: { operation: string; code: string; reason: string; field: string };
}

type Notification = TriageNotification | FailureNotification;

const ROUTE = "/v1/report-alert";
const MAXIMUM_BODY_BYTES = 4096;
const PUSHOVER_ENDPOINT = "https://api.pushover.net/1/messages.json";
const FORWARD_TIMEOUT_MS = 5000;
/// Long enough to cover the intake Queue's five retries at a 60 second delay, with room to spare,
/// and short enough that a genuinely new report months later is never mistaken for a duplicate.
const DEDUP_TTL_SECONDS = 3600;
/// A token shorter than this cannot be the reviewed 32-byte secret, so treat it as misconfigured
/// rather than comparing against it.
const MINIMUM_TOKEN_BYTES = 32;
/// Pushover user keys and application tokens are both exactly 30 alphanumeric characters.
const PUSHOVER_CREDENTIAL = /^[A-Za-z0-9]{30}$/u;
/// Pushover priorities. 1 is "high" and bypasses the recipient's quiet hours, which is right for
/// a crash and wrong for everything else. 2 demands acknowledgement and is too much for this.
const PRIORITY_HIGH = 1;
const PRIORITY_NORMAL = 0;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "POST") return status(405);
    if (new URL(request.url).pathname !== ROUTE) return status(404);
    if (!isConfigured(env)) {
      console.warn("alert_misconfigured");
      return status(503);
    }
    if (!authorized(request, env)) {
      // Deliberately identical to a route miss from the caller's point of view.
      console.warn("alert_unauthorized");
      return status(401);
    }

    const notification = await readNotification(request);
    if (!notification) {
      console.warn("alert_invalid_event");
      return status(400);
    }

    // Dedup is checked before forwarding and *recorded after*, so a failed forward is retried
    // rather than swallowed. The intake retries the same report ID up to five times; without
    // this, a single report would page five times.
    const marker = new Request(
      `https://alert.invalid/report/${encodeURIComponent("alertID" in notification ? notification.alertID : notification.reportID)}`,
    );
    if (await caches.default.match(marker)) {
      console.log("alert_duplicate_suppressed");
      return status(204);
    }

    const delivered = await forward(notification, env);
    if (!delivered) {
      // Non-2xx makes the control plane throw, which returns the message to its Queue for
      // another attempt. Failing loudly is correct here: a dropped alert is invisible.
      console.warn("alert_forward_failed");
      return status(502);
    }

    await caches.default.put(
      marker,
      new Response(null, { headers: { "Cache-Control": `max-age=${DEDUP_TTL_SECONDS}` } }),
    );
    return status(204);
  },
};

function isConfigured(env: Env): boolean {
  const token = env.REPORT_ALERT_WEBHOOK_TOKEN;
  return typeof token === "string"
    && new TextEncoder().encode(token).byteLength >= MINIMUM_TOKEN_BYTES
    && typeof env.PUSHOVER_APP_TOKEN === "string"
    && PUSHOVER_CREDENTIAL.test(env.PUSHOVER_APP_TOKEN)
    && typeof env.PUSHOVER_USER_KEY === "string"
    && PUSHOVER_CREDENTIAL.test(env.PUSHOVER_USER_KEY);
}

/// Constant-time, so a caller cannot learn the token one byte at a time from response timing.
function authorized(request: Request, env: Env): boolean {
  const header = request.headers.get("authorization") ?? "";
  const prefix = "Bearer ";
  if (!header.startsWith(prefix)) return false;
  const presented = new TextEncoder().encode(header.slice(prefix.length));
  const expected = new TextEncoder().encode(env.REPORT_ALERT_WEBHOOK_TOKEN);
  // timingSafeEqual throws on a length mismatch, which is itself an observable difference; the
  // length of a secret is not worth protecting and a mismatch is already a definite failure.
  if (presented.byteLength !== expected.byteLength) return false;
  return crypto.subtle.timingSafeEqual(presented, expected);
}

async function readNotification(request: Request): Promise<Notification | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAXIMUM_BODY_BYTES) return null;
  // Content-Length can lie or be absent, so the real ceiling is on what was actually read.
  const reader = request.body?.getReader();
  if (!reader) return null;
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAXIMUM_BODY_BYTES) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  const joined = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
  const raw = new TextDecoder().decode(joined);
  if (new TextEncoder().encode(raw).byteLength > MAXIMUM_BODY_BYTES) return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const value = parsed as Record<string, unknown>;
  if (value.event === "threading.service-failure.summary") {
    if (Object.keys(value).some(key => !["event", "alertID", "route", "status", "count", "windowStart", "diagnosticReference", "example"].includes(key))) return null;
    if (typeof value.route !== "string" || !["reports", "auth", "push", "hosts", "account", "rendezvous"].includes(value.route)) return null;
    if (typeof value.status !== "number" || ![400, 409, 413, 415, 429, 500, 502, 503, 504].includes(value.status)) return null;
    if (!Number.isSafeInteger(value.count) || (value.count as number) < 1 || (value.count as number) > 1000000000) return null;
    if (typeof value.windowStart !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.000Z$/u.test(value.windowStart)) return null;
    const time = Date.parse(value.windowStart);
    if (!Number.isFinite(time) || value.alertID !== `${time}-${value.route}-${value.status}-${value.count}`) return null;
    if (value.diagnosticReference !== undefined || value.example !== undefined) {
      if (value.diagnosticReference !== `sf-${time}-${value.route}-${value.status}`) return null;
      const example = value.example;
      if (!example || typeof example !== "object" || Array.isArray(example)) return null;
      const fields = example as Record<string, unknown>;
      if (Object.keys(fields).length !== 4
        || Object.keys(fields).some(key => !["operation", "code", "reason", "field"].includes(key))) return null;
      for (const key of ["operation", "code", "reason", "field"]) {
        if (typeof fields[key] !== "string" || !/^[A-Za-z][A-Za-z0-9.]{0,63}$/u.test(fields[key])) return null;
      }
      const operations = value.route === "push" ? ["push", "push.send", "push.register", "push.retract"] : [value.route];
      if (!operations.includes(fields.operation as string)) return null;
    }
    return value as unknown as FailureNotification;
  }
  if (value.event !== "threading.issue-report.received") return null;

  for (const key of ["reportID", "reference", "kind", "trigger", "source", "receivedAt"]) {
    const field = value[key];
    // Every one of these is a machine token or an ID. Anything with a control character or
    // beyond a sane length is not one, and must not reach a notification body.
    if (typeof field !== "string" || field.length === 0 || field.length > 160) return null;
    if (/[\u0000-\u001f\u007f]/u.test(field)) return null;
  }
  if (typeof value.size !== "number" || !Number.isFinite(value.size) || value.size < 0) return null;

  return value as unknown as TriageNotification;
}

async function forward(notification: Notification, env: Env): Promise<boolean> {
  const failure = "alertID" in notification;
  const crash = !failure && notification.kind === "crash";
  const form = new URLSearchParams({
    token: env.PUSHOVER_APP_TOKEN,
    user: env.PUSHOVER_USER_KEY,
    title: failure ? `Threading HTTP ${notification.status}` : `Threading ${notification.kind}`,
    message: failure ? failureMessage(notification) : [
      notification.reference,
      notification.source,
      notification.trigger,
      `${notification.size} B`,
    ].join(" \u00b7 "),
    priority: String(crash ? PRIORITY_HIGH : PRIORITY_NORMAL),
  });

  try {
    const response = await fetch(PUSHOVER_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form,
      signal: AbortSignal.timeout(FORWARD_TIMEOUT_MS),
    });
    // Say *why*, always. Pushover answers a 4xx with a JSON body naming the bad field, which is
    // the difference between "the credentials are wrong" and "the message was malformed". This is
    // the one path whose failure nobody would otherwise notice, so it is worth one bounded read.
    if (!response.ok) {
      const detail = (await response.text()).slice(0, 200);
      console.warn("alert_pushover_rejected", { status: response.status, detail });
      return false;
    }
    await response.body?.cancel();
    return true;
  } catch (error) {
    console.warn("alert_pushover_unreachable", {
      reason: error instanceof Error ? error.name : "unknown",
      detail: error instanceof Error ? error.message.slice(0, 200) : undefined,
    });
    return false;
  }
}

function failureMessage(notification: FailureNotification): string {
  const lines = [`${notification.count} failed ${notification.route} requests since ${notification.windowStart}`];
  if (notification.example && notification.diagnosticReference) {
    const example = notification.example;
    lines.push(`Example: ${example.operation}: ${example.code} / ${example.reason} (${example.field})`);
    lines.push(`Diagnostic: ${notification.diagnosticReference}`);
  }
  return lines.join("\n");
}

function status(code: number): Response {
  return new Response(null, { status: code });
}
