import type { Env, RendezvousPrincipal } from "./environment";
import { HttpError } from "./environment";
import {
  handleAppleNotification,
  handleAppleSignIn,
  handleDeleteAccount,
  handleRefresh,
  handleSignOut,
  validateDueAppleSessions,
} from "./auth";
import { validateAppleConfiguration } from "./apple-tokens";
import { sha256Hex, verifyRendezvousSessionToken } from "./crypto";
import {
  authorizeRendezvousCredential,
  enrollHost,
  issueDeviceCredential,
  revokeDeviceCredential,
  revokeHost,
  rotateHostCredentialForAccount,
} from "./enrollment";
import { bearerToken, json } from "./http";
import { handleIssueReport } from "./issue-report-intake";
import { handleIssueReportPickup } from "./issue-report-pickup";
import { BOUNDS, validateIdentifier } from "./protocol";

export { HostRendezvous } from "./host-rendezvous";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return json({ status: "ok", rendezvousProtocol: BOUNDS.protocolVersion });
      }
      await enforceRateLimit(request, url.pathname, env);
      if (request.method === "GET" && url.pathname === "/ready") {
        return await readinessResponse(env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/apple") {
        return await handleAppleSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/apple/events") {
        return await handleAppleNotification(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/refresh") {
        return await handleRefresh(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/signout") {
        return await handleSignOut(request, env);
      }
      if (request.method === "DELETE" && url.pathname === "/v1/account") {
        return await handleDeleteAccount(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/hosts") {
        return await enrollHost(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/reports") {
        return await handleIssueReport(request, env);
      }
      if (request.method === "GET" && url.pathname === "/v1/developer/reports") {
        return await handleIssueReportPickup(request, env);
      }
      const pickupMatch = /^\/v1\/developer\/reports\/([^/]+)$/u.exec(url.pathname);
      if (request.method === "GET" && pickupMatch?.[1]) {
        return await handleIssueReportPickup(request, env, decodePath(pickupMatch[1]));
      }

      const rotateMatch = /^\/v1\/hosts\/([^/]+)\/credentials\/rotate$/u.exec(url.pathname);
      if (request.method === "POST" && rotateMatch?.[1]) {
        return await rotateHostCredentialForAccount(request, env, decodePath(rotateMatch[1]));
      }
      const hostMatch = /^\/v1\/hosts\/([^/]+)$/u.exec(url.pathname);
      if (request.method === "DELETE" && hostMatch?.[1]) {
        return await revokeHost(request, env, decodePath(hostMatch[1]));
      }
      const devicesMatch = /^\/v1\/hosts\/([^/]+)\/devices$/u.exec(url.pathname);
      if (request.method === "POST" && devicesMatch?.[1]) {
        return await issueDeviceCredential(request, env, decodePath(devicesMatch[1]));
      }
      const revokeMatch = /^\/v1\/hosts\/([^/]+)\/devices\/([^/]+)$/u.exec(url.pathname);
      if (request.method === "DELETE" && revokeMatch?.[1] && revokeMatch[2]) {
        return await revokeDeviceCredential(
          request,
          env,
          decodePath(revokeMatch[1]),
          decodePath(revokeMatch[2]),
        );
      }

      if (request.method === "GET" && url.pathname.startsWith("/v1/rendezvous/")) {
        return await routeRendezvous(request, url.pathname, env);
      }
      throw new HttpError(404, "notFound", "Endpoint was not found");
    } catch (error) {
      if (error instanceof HttpError) {
        return json({ error: { code: error.code, message: error.message } }, error.status);
      }
      console.error("request_failed", {
        reason: error instanceof Error ? error.name : "unknown",
      });
      return json({ error: { code: "internal", message: "Internal service error" } }, 500);
    }
  },

  async scheduled(event: ScheduledController, env: Env): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    if (event.cron === "17 3 * * *") {
      const reportQuotaCutoffDay = new Date((now - 7 * 24 * 60 * 60) * 1000)
        .toISOString()
        .slice(0, 10);
      await env.DB.batch([
        env.DB.prepare(
          "DELETE FROM apple_assertions WHERE digest IN "
            + "(SELECT digest FROM apple_assertions WHERE expires_at < ? LIMIT 1000)",
        ).bind(now),
        env.DB.prepare(
          "DELETE FROM apple_notifications WHERE jti_digest IN "
            + "(SELECT jti_digest FROM apple_notifications WHERE expires_at < ? LIMIT 1000)",
        ).bind(now),
        env.DB.prepare(
          "DELETE FROM rendezvous_credentials WHERE digest IN "
            + "(SELECT digest FROM rendezvous_credentials WHERE expires_at < ? "
            + "OR (revoked_at IS NOT NULL AND revoked_at < ?) LIMIT 1000)",
        ).bind(now, now - 7 * 24 * 60 * 60),
        env.DB.prepare("DELETE FROM issue_report_daily_quota WHERE day < ?")
          .bind(reportQuotaCutoffDay),
      ]);
    } else {
      await validateDueAppleSessions(env, now);
    }
    await env.DB.prepare(
      "DELETE FROM refresh_sessions WHERE digest IN (SELECT digest FROM refresh_sessions "
        + "WHERE expires_at <= ? OR revoked_at IS NOT NULL OR (consumed_at IS NOT NULL "
        + "AND (replacement_expires_at IS NULL OR replacement_expires_at <= ?)) LIMIT 1000)",
    ).bind(now, now).run();
  },
} satisfies ExportedHandler<Env>;

async function readinessResponse(env: Env): Promise<Response> {
  try {
    const clientIDs = env.APPLE_CLIENT_IDS.split(",")
      .map((value) => value.trim())
      .filter(Boolean);
    if (clientIDs.length !== 2
      || new Set(clientIDs).size !== clientIDs.length
      || !clientIDs.includes("codes.threading")
      || !clientIDs.includes("codes.threading.mobile")) {
      throw new HttpError(503, "serviceConfiguration", "Apple audiences are not configured");
    }
    const signingSecret = requiredConfigurationSecret(env.SESSION_SIGNING_SECRET, 32, 4096);
    const encryptionSecret = requiredConfigurationSecret(
      env.APPLE_TOKEN_ENCRYPTION_SECRET,
      32,
      4096,
    );
    if (signingSecret === encryptionSecret) {
      throw new HttpError(503, "serviceConfiguration", "Service secrets are not independent");
    }
    requiredConfigurationSecret(env.TURN_KEY_ID, 1, 1024);
    requiredConfigurationSecret(env.TURN_KEY_API_TOKEN, 1, 4096);
    requiredConfigurationSecret(env.REPORT_PICKUP_TOKEN, 32, 4096);
    await validateAppleConfiguration(clientIDs, env);
    await env.DB.batch([
      env.DB.prepare("SELECT auth_invalidated_at FROM accounts LIMIT 1"),
      env.DB.prepare(
        "SELECT last_validation_attempt_at, last_validated_at, invalidated_at "
          + "FROM apple_tokens LIMIT 1",
      ),
      env.DB.prepare(
        "SELECT replacement_digest, replacement_encrypted_token, replacement_expires_at "
          + "FROM refresh_sessions LIMIT 1",
      ),
      env.DB.prepare("SELECT device_id, revoked_at FROM rendezvous_credentials LIMIT 1"),
      env.DB.prepare("SELECT jti_digest FROM apple_notifications LIMIT 1"),
      env.DB.prepare("SELECT accepted_count FROM issue_report_daily_quota LIMIT 1"),
    ]);
    await env.ISSUE_REPORTS.head("health/readiness-probe");
    return json({ status: "ready", rendezvousProtocol: BOUNDS.protocolVersion });
  } catch (error) {
    console.warn("readiness_failed", {
      reason: error instanceof HttpError ? error.code : "dependency",
    });
    return json({ status: "unavailable" }, 503);
  }
}

function requiredConfigurationSecret(
  value: string | undefined,
  minimumBytes: number,
  maximumBytes: number,
): string {
  if (typeof value !== "string") {
    throw new HttpError(503, "serviceConfiguration", "Required service configuration is absent");
  }
  const bytes = new TextEncoder().encode(value);
  if (bytes.byteLength < minimumBytes || bytes.byteLength > maximumBytes) {
    throw new HttpError(503, "serviceConfiguration", "Required service configuration is invalid");
  }
  if (/[\u0000-\u0020\u007f]/u.test(value)) {
    throw new HttpError(503, "serviceConfiguration", "Required service configuration is invalid");
  }
  return value;
}

async function routeRendezvous(
  request: Request,
  pathname: string,
  env: Env,
): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError(426, "upgradeRequired", "WebSocket upgrade is required");
  }
  if (request.headers.get("X-Threading-Rendezvous-Version")
    !== String(BOUNDS.protocolVersion)) {
    throw new HttpError(426, "protocolVersion", "Rendezvous protocol version is unsupported");
  }
  const token = bearerToken(request);
  let principal: RendezvousPrincipal;
  try {
    switch (pathname) {
      case "/v1/rendezvous/host":
        principal = await authorizeRendezvousCredential(token, "host", env);
        break;
      case "/v1/rendezvous/device":
        principal = await authorizeRendezvousCredential(token, "device", env);
        break;
      case "/v1/rendezvous/session": {
        const verified = await verifyRendezvousSessionToken(token, env);
        principal = { kind: "session", ...verified };
        break;
      }
      default:
        throw new HttpError(404, "notFound", "Rendezvous endpoint was not found");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "unauthorized", "Rendezvous credential is invalid or expired");
  }
  if (!validateIdentifier(principal.hostID)) {
    throw new HttpError(401, "unauthorized", "Rendezvous host is invalid");
  }
  const headers = new Headers({
    Upgrade: "websocket",
    "X-Threading-Principal-Kind": principal.kind,
    "X-Threading-Account-ID": principal.accountID,
    "X-Threading-Host-ID": principal.hostID,
  });
  if (principal.kind === "host" || principal.kind === "device") {
    headers.set(
      "X-Threading-Credential-Expires-At",
      String(principal.credentialExpiresAt),
    );
  }
  if (principal.kind === "device") {
    headers.set("X-Threading-Device-ID", principal.deviceID);
  } else if (principal.kind === "session") {
    headers.set("X-Threading-Session-ID", principal.sessionID);
    headers.set("X-Threading-Session-Expires-At", String(principal.sessionExpiresAt));
  }
  const stub = env.HOST_RENDEZVOUS.getByName(principal.hostID);
  return stub.fetch(new Request(request.url, { method: "GET", headers }));
}

function decodePath(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new HttpError(400, "invalidPath", "Path contains invalid encoding");
  }
}

async function enforceRateLimit(request: Request, pathname: string, env: Env): Promise<void> {
  const authorization = request.headers.get("Authorization");
  const source = request.headers.get("CF-Connecting-IP") ?? "unattributed";
  const sourceDigest = await sha256Hex(source);
  const sourceOutcome = await env.SOURCE_RATE_LIMITER.limit({
    key: `${sourceDigest}:${rateLimitGroup(pathname)}`,
  });
  if (!sourceOutcome.success) {
    throw new HttpError(429, "rateLimited", "Too many requests; try again shortly");
  }
  let actor = `source:${sourceDigest}`;
  if (authorization?.startsWith("Bearer ")) {
    const token = authorization.slice(7);
    if (token.length > 0 && new TextEncoder().encode(token).byteLength <= 4096
      && !/[\u0000-\u0020\u007f]/u.test(token)) {
      actor = `credential:${await sha256Hex(token)}`;
    }
  }
  const limiter = pathname === "/v1/auth/apple" ? env.AUTH_RATE_LIMITER : env.API_RATE_LIMITER;
  const outcome = await limiter.limit({ key: `${actor}:${rateLimitGroup(pathname)}` });
  if (!outcome.success) {
    throw new HttpError(429, "rateLimited", "Too many requests; try again shortly");
  }
}

function rateLimitGroup(pathname: string): string {
  if (pathname.startsWith("/v1/rendezvous/")) return "rendezvous";
  if (pathname.startsWith("/v1/hosts")) return "hosts";
  if (pathname.startsWith("/v1/auth/")) return "auth";
  if (pathname.startsWith("/v1/developer/reports")) return "developerReports";
  if (pathname === "/v1/reports") return "reports";
  if (pathname === "/v1/account") return "account";
  return "unknown";
}
