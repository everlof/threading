import type { Env, RendezvousPrincipal } from "./environment";
import { HttpError } from "./environment";
import {
  handleAppleNotification,
  handleAppleSignIn,
  handleDeleteAccount,
  handleLocalDevelopmentSignIn,
  handleRefresh,
  handleSignOut,
  validateDueAppleSessions,
} from "./auth";
import { validateAppleConfiguration } from "./apple-tokens";
import { handleAPNSPush, validateAPNSConfiguration } from "./apns";
import {
  authorizeDevelopmentSignIn,
  redeemDevelopmentSignIn,
  startDevelopmentSignIn,
  validateDevelopmentAuthConfiguration,
} from "./development-auth";
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
import {
  handleIssueReportNotificationBatch,
  validateReportAlertConfiguration,
} from "./issue-report-notifications";
import { handleIssueReportPickup } from "./issue-report-pickup";
import { BOUNDS, validateIdentifier } from "./protocol";
import {
  registerPushRecipient,
  validatePushTokenEncryptionConfiguration,
} from "./push-registrations";

export { HostRendezvous } from "./host-rendezvous";

const cleanupPageSize = 1_000;

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
      if (request.method === "POST" && url.pathname === "/v1/auth/apple"
        && !isOperatedDevelopment(env)) {
        return await handleAppleSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/local-development") {
        return await handleLocalDevelopmentSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/development/start") {
        return await startDevelopmentSignIn(request, env);
      }
      if (request.method === "GET" && url.pathname === "/v1/auth/development/authorize") {
        return await authorizeDevelopmentSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/development/redeem") {
        return await redeemDevelopmentSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/apple/events"
        && !isOperatedDevelopment(env)) {
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
      if (request.method === "POST" && url.pathname === "/v1/reports"
        && !isOperatedDevelopment(env)) {
        return await handleIssueReport(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/push") {
        return await handleAPNSPush(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/push/registrations") {
        return await registerPushRecipient(request, env);
      }
      if (request.method === "GET" && url.pathname === "/v1/developer/reports"
        && !isOperatedDevelopment(env)) {
        return await handleIssueReportPickup(request, env);
      }
      const pickupMatch = /^\/v1\/developer\/reports\/([^/]+)$/u.exec(url.pathname);
      if (request.method === "GET" && pickupMatch?.[1] && !isOperatedDevelopment(env)) {
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
    const cleanupStatements: D1PreparedStatement[] = [];
    if (event.cron === "17 3 * * *") {
      const reportQuotaCutoffDay = new Date((now - 7 * 24 * 60 * 60) * 1000)
        .toISOString()
        .slice(0, 10);
      cleanupStatements.push(
        env.DB.prepare(
          "DELETE FROM apple_assertions WHERE digest IN "
            + `(SELECT digest FROM apple_assertions WHERE expires_at < ? LIMIT ${cleanupPageSize})`,
        ).bind(now),
        env.DB.prepare(
          "DELETE FROM apple_notifications WHERE jti_digest IN "
            + `(SELECT jti_digest FROM apple_notifications WHERE expires_at < ? `
            + `LIMIT ${cleanupPageSize})`,
        ).bind(now),
        env.DB.prepare(
          "DELETE FROM rendezvous_credentials WHERE digest IN "
            + "(SELECT digest FROM rendezvous_credentials WHERE expires_at < ? "
            + "OR (revoked_at IS NOT NULL AND revoked_at < ?) "
            + `LIMIT ${cleanupPageSize})`,
        ).bind(now, now - 7 * 24 * 60 * 60),
        env.DB.prepare(
          "DELETE FROM development_auth_transactions WHERE transaction_digest IN "
            + "(SELECT transaction_digest FROM development_auth_transactions "
            + `WHERE expires_at < ? LIMIT ${cleanupPageSize})`,
        ).bind(now),
        env.DB.prepare(
          "DELETE FROM push_registrations WHERE digest IN "
            + "(SELECT digest FROM push_registrations WHERE revoked_at IS NOT NULL "
            + `AND revoked_at < ? LIMIT ${cleanupPageSize})`,
        ).bind(now - 7 * 24 * 60 * 60),
      );
      await env.DB.prepare("DELETE FROM issue_report_daily_quota WHERE day < ?")
        .bind(reportQuotaCutoffDay)
        .run();
    } else if (!isOperatedDevelopment(env)) {
      await validateDueAppleSessions(env, now);
    }
    cleanupStatements.push(env.DB.prepare(
      "DELETE FROM refresh_sessions WHERE digest IN (SELECT digest FROM refresh_sessions "
        + "WHERE expires_at <= ? OR revoked_at IS NOT NULL OR (consumed_at IS NOT NULL "
        + "AND (replacement_expires_at IS NULL OR replacement_expires_at <= ?)) "
        + `LIMIT ${cleanupPageSize})`,
    ).bind(now, now));
    await drainCleanupPages(env, cleanupStatements);
  },

  async queue(batch: MessageBatch<unknown>, env: Env): Promise<void> {
    await handleIssueReportNotificationBatch(batch, env);
  },
} satisfies ExportedHandler<Env>;

async function drainCleanupPages(env: Env, statements: D1PreparedStatement[]): Promise<void> {
  let pending = statements;
  while (pending.length > 0) {
    const results = await env.DB.batch(pending);
    if (results.length !== pending.length) {
      throw new Error("D1 cleanup batch returned an incomplete result set");
    }
    pending = pending.filter((_, index) => results[index]?.meta.changes === cleanupPageSize);
  }
}

async function readinessResponse(env: Env): Promise<Response> {
  try {
    if (env.LOCAL_DEVELOPMENT_MODE === "1") {
      requiredConfigurationSecret(env.SESSION_SIGNING_SECRET, 32, 4096);
      requiredConfigurationSecret(env.APPLE_TOKEN_ENCRYPTION_SECRET, 32, 4096);
      requiredConfigurationSecret(env.REPORT_PICKUP_TOKEN, 32, 4096);
      validateReportAlertConfiguration(env);
      requiredConfigurationSecret(env.ISSUE_REPORTS_BUCKET_NAME, 1, 128);
      await probeStorage(env);
      return json({ status: "ready", rendezvousProtocol: BOUNDS.protocolVersion });
    }
    if (isOperatedDevelopment(env)) {
      const signingSecret = requiredConfigurationSecret(env.SESSION_SIGNING_SECRET, 32, 4096);
      const pushSecret = requiredConfigurationSecret(
        env.PUSH_TOKEN_ENCRYPTION_SECRET,
        32,
        4096,
      );
      if (signingSecret === pushSecret) {
        throw new HttpError(503, "serviceConfiguration", "Service secrets are not independent");
      }
      requiredConfigurationSecret(env.TURN_KEY_ID, 1, 1024);
      requiredConfigurationSecret(env.TURN_KEY_API_TOKEN, 1, 4096);
      await validateAPNSConfiguration(env);
      validatePushTokenEncryptionConfiguration(env);
      validateDevelopmentAuthConfiguration(env);
      await probeStorage(env, false);
      return json({ status: "ready", rendezvousProtocol: BOUNDS.protocolVersion });
    }
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
    const pushEncryptionSecret = requiredConfigurationSecret(
      env.PUSH_TOKEN_ENCRYPTION_SECRET,
      32,
      4096,
    );
    if (pushEncryptionSecret === signingSecret || pushEncryptionSecret === encryptionSecret) {
      throw new HttpError(503, "serviceConfiguration", "Service secrets are not independent");
    }
    requiredConfigurationSecret(env.TURN_KEY_ID, 1, 1024);
    requiredConfigurationSecret(env.TURN_KEY_API_TOKEN, 1, 4096);
    requiredConfigurationSecret(env.REPORT_PICKUP_TOKEN, 32, 4096);
    requiredConfigurationSecret(env.ISSUE_REPORTS_BUCKET_NAME, 1, 128);
    validateReportAlertConfiguration(env);
    await Promise.all([
      validateAppleConfiguration(clientIDs, env),
      validateAPNSConfiguration(env),
    ]);
    validatePushTokenEncryptionConfiguration(env);
    validateDevelopmentAuthConfiguration(env);
    await probeStorage(env, true);
    return json({ status: "ready", rendezvousProtocol: BOUNDS.protocolVersion });
  } catch (error) {
    console.warn("readiness_failed", {
      reason: error instanceof HttpError ? error.code : "dependency",
    });
    return json({ status: "unavailable" }, 503);
  }
}

async function probeStorage(env: Env, includeIssueReports = true): Promise<void> {
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
    env.DB.prepare("SELECT consumed_at FROM development_auth_transactions LIMIT 1"),
    env.DB.prepare("SELECT revoked_at FROM push_registrations LIMIT 1"),
  ]);
  if (includeIssueReports) {
    await env.ISSUE_REPORTS.head("health/readiness-probe");
  }
}

function isOperatedDevelopment(env: Env): boolean {
  return env.DEVELOPMENT_AUTH_MODE === "1" && env.LOCAL_DEVELOPMENT_MODE !== "1";
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
  const limiter = pathname.startsWith("/v1/auth/")
    ? env.AUTH_RATE_LIMITER
    : env.API_RATE_LIMITER;
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
  if (pathname === "/v1/push" || pathname === "/v1/push/registrations") return "push";
  if (pathname === "/v1/account") return "account";
  return "unknown";
}
