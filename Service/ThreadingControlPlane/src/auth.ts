import type { AccessPrincipal, Env } from "./environment";
import { HttpError } from "./environment";
import {
  accountIDForAppleSubject,
  decryptRefreshReplacement,
  encryptRefreshReplacement,
  randomToken,
  sha256Hex,
  signAccessToken,
  verifyAccessToken,
  verifyAppleIdentityToken,
  verifyAppleNotification,
  verifyAppleSessionIdentityToken,
} from "./crypto";
import {
  decryptAppleToken,
  encryptAppleToken,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
  validateAppleRefreshToken,
} from "./apple-tokens";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";

const refreshLifetimeSeconds = 30 * 24 * 60 * 60;
const refreshRetryLifetimeSeconds = 2 * 60;
const maximumActiveRefreshSessions = 64;
const maximumAppleTokensPerAccount = 8;
// Active hosts have a lower product limit, but revoked host rows are retained so that an old
// identifier can never silently move to another account. Keep the retained set bounded too.
const maximumStoredHostsPerAccount = 64;
const maximumConcurrentCleanupRequests = 4;
const appleValidationIntervalSeconds = 24 * 60 * 60;
const maximumAppleValidationsPerSchedule = 250;

export async function handleAppleSignIn(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["identityToken", "authorizationCode", "nonce"]);
  const identityToken = requiredString(body.identityToken, "identityToken", 16 * 1024);
  const authorizationCode = requiredString(body.authorizationCode, "authorizationCode", 4096);
  const nonce = requiredString(body.nonce, "nonce", 512);
  const payload = await verifyAppleIdentityToken(identityToken, nonce, env);
  const clientID = appleClientID(payload.aud, env);
  const accountID = await accountIDForAppleSubject(payload.sub as string);
  const assertionDigest = await sha256Hex(identityToken);
  const now = Math.floor(Date.now() / 1000);
  const expiry = typeof payload.exp === "number" ? Math.floor(payload.exp) : now;

  try {
    await env.DB.batch([
      env.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
          + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at",
      ).bind(accountID, now, now),
      env.DB.prepare(
        "INSERT INTO apple_assertions (digest, account_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
      ).bind(assertionDigest, accountID, expiry, now),
    ]);
  } catch (error) {
    const replay = await env.DB.prepare(
      "SELECT 1 AS found FROM apple_assertions WHERE digest = ?",
    ).bind(assertionDigest).first<{ found: number }>();
    if (replay) {
      throw new HttpError(409, "identityTokenReplayed", "Apple identity token was already used");
    }
    throw error;
  }

  try {
    const appleTokens = await exchangeAppleAuthorizationCode(authorizationCode, clientID, env);
    const exchangedPayload = await verifyAppleIdentityToken(appleTokens.identityToken, nonce, env);
    if (exchangedPayload.sub !== payload.sub || appleClientID(exchangedPayload.aud, env) !== clientID) {
      throw new HttpError(401, "appleAuthorization", "Apple authorization identity did not match");
    }
    const encrypted = await encryptAppleToken(appleTokens.refreshToken, env);
    await env.DB.prepare(
      "INSERT INTO apple_tokens "
        + "(account_id, client_id, encrypted_refresh_token, created_at, updated_at, "
        + "last_validation_attempt_at, last_validated_at) VALUES (?, ?, ?, ?, ?, ?, ?) "
        + "ON CONFLICT(account_id, client_id) DO UPDATE SET "
        + "encrypted_refresh_token = excluded.encrypted_refresh_token, "
        + "updated_at = excluded.updated_at, last_validation_attempt_at = excluded.last_validation_attempt_at, "
        + "last_validated_at = excluded.last_validated_at, invalidated_at = NULL",
    ).bind(accountID, clientID, encrypted, now, now, now, now).run();
    // Clear this after token storage too: scheduled validation may have invalidated an older
    // grant while the interactive authorization-code exchange was in flight.
    await env.DB.prepare(
      "UPDATE accounts SET auth_invalidated_at = NULL, updated_at = ? WHERE id = ?",
    ).bind(now, accountID).run();
  } catch (error) {
    await env.DB.prepare("DELETE FROM apple_assertions WHERE digest = ?").bind(assertionDigest).run();
    throw error;
  }
  return issueSession(accountID, env, now);
}

/** Loopback-only account bootstrap for the cloud-free Wrangler development profile. */
export async function handleLocalDevelopmentSignIn(
  request: Request,
  env: Env,
): Promise<Response> {
  if (env.LOCAL_DEVELOPMENT_MODE !== "1" || !isLoopbackRequest(request)) {
    throw new HttpError(404, "notFound", "Endpoint was not found");
  }
  assertExactKeys(await readJSON(request, 1024), []);
  const accountID = "local-development-account";
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare(
    "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
      + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, auth_invalidated_at = NULL",
  ).bind(accountID, now, now).run();
  return issueSession(accountID, env, now);
}

export async function handleRefresh(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["refreshToken"]);
  const refreshToken = requiredString(body.refreshToken, "refreshToken", 4096);
  const digest = await sha256Hex(refreshToken);
  const now = Math.floor(Date.now() / 1000);
  const active = await env.DB.prepare(
    "SELECT s.account_id FROM refresh_sessions s JOIN accounts a ON a.id = s.account_id "
      + "WHERE s.digest = ? AND s.consumed_at IS NULL AND s.revoked_at IS NULL "
      + "AND s.expires_at > ? AND a.auth_invalidated_at IS NULL",
  ).bind(digest, now).first<{ account_id: string }>();
  if (!active) return retryRefreshSession(digest, env, now);
  await cleanupExpiredRefreshSessions(active.account_id, env, now);

  const replacementToken = randomToken("th_refresh_");
  const replacementDigest = await sha256Hex(replacementToken);
  const encryptedReplacement = await encryptRefreshReplacement(replacementToken, env);
  const replacementExpiresAt = now + refreshLifetimeSeconds;
  const retryExpiresAt = now + refreshRetryLifetimeSeconds;
  const accessToken = await signAccessToken(active.account_id, env);
  let rotated: D1Result[];
  try {
    rotated = await env.DB.batch([
      env.DB.prepare(
        "UPDATE refresh_sessions SET consumed_at = ?, replacement_digest = ?, "
          + "replacement_encrypted_token = ?, replacement_expires_at = ? "
          + "WHERE digest = ? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
      ).bind(
        now,
        replacementDigest,
        encryptedReplacement,
        retryExpiresAt,
        digest,
        now,
      ),
      env.DB.prepare(
        "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) "
          + "SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM refresh_sessions "
          + "WHERE digest = ? AND consumed_at = ? AND replacement_digest = ? "
          + "AND replacement_encrypted_token = ? AND replacement_expires_at = ? "
          + "AND revoked_at IS NULL)",
      ).bind(
        replacementDigest,
        active.account_id,
        replacementExpiresAt,
        now,
        digest,
        now,
        replacementDigest,
        encryptedReplacement,
        retryExpiresAt,
      ),
    ]);
  } catch (error) {
    throwRefreshSessionLimit(error);
  }
  if (rotated[0]?.meta.changes !== 1 || rotated[1]?.meta.changes !== 1) {
    return retryRefreshSession(digest, env, now);
  }
  return sessionResponse(
    active.account_id,
    accessToken,
    replacementToken,
    replacementExpiresAt,
    now,
  );
}

/// Invalidates exactly the refresh session presented by this installation. The response is
/// intentionally idempotent so a client can safely retry after losing the first response.
export async function handleSignOut(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["refreshToken"]);
  const refreshToken = requiredString(body.refreshToken, "refreshToken", 4096);
  const digest = await sha256Hex(refreshToken);
  await env.DB.prepare(
    "UPDATE refresh_sessions SET revoked_at = ? WHERE revoked_at IS NULL AND "
      + "(digest = ? OR digest = (SELECT replacement_digest FROM refresh_sessions WHERE digest = ?))",
  ).bind(Math.floor(Date.now() / 1000), digest, digest).run();
  return new Response(null, { status: 204 });
}

export async function authenticateAccess(request: Request, env: Env): Promise<AccessPrincipal> {
  const accountID = await verifiedAccessAccountID(request, env);
  const account = await env.DB.prepare(
    "SELECT 1 AS found FROM accounts WHERE id = ? AND auth_invalidated_at IS NULL",
  )
    .bind(accountID).first<{ found: number }>();
  if (!account) throw new HttpError(401, "unauthorized", "Account no longer exists");
  return { accountID };
}

async function verifiedAccessAccountID(request: Request, env: Env): Promise<string> {
  try {
    const accountID = await verifyAccessToken(bearerToken(request), env);
    return accountID;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "unauthorized", "Access token is invalid or expired");
  }
}

export async function handleDeleteAccount(request: Request, env: Env): Promise<Response> {
  // Keep deletion retryable after a lost 204 response. A still-valid signed access token proves
  // which account was targeted even after the account row and all refresh sessions are gone.
  const accountID = await verifiedAccessAccountID(request, env);
  const account = await env.DB.prepare("SELECT 1 AS found FROM accounts WHERE id = ?")
    .bind(accountID).first<{ found: number }>();
  if (!account) return new Response(null, { status: 204 });
  const tokens = await env.DB.prepare(
    "SELECT client_id, encrypted_refresh_token FROM apple_tokens WHERE account_id = ? LIMIT ?",
  ).bind(accountID, maximumAppleTokensPerAccount).all<{
    client_id: string;
    encrypted_refresh_token: string;
  }>();
  await forEachBounded(tokens.results, maximumConcurrentCleanupRequests, async (token) => {
    try {
      appleClientID(token.client_id, env);
      await revokeAppleRefreshToken(
        await decryptAppleToken(token.encrypted_refresh_token, env),
        token.client_id,
        env,
      );
    } catch (error) {
      // Apple's deletion guidance requires local account removal even if revocation cannot be
      // completed. Do not retain the encrypted user token as an unbounded retry outbox.
      console.warn("apple_revocation_during_deletion_failed", {
        reason: error instanceof Error ? error.name : "unknown",
      });
    }
  });

  await removeAccount(accountID, env);
  return new Response(null, { status: 204 });
}

export async function handleAppleNotification(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request, 32 * 1024);
  assertExactKeys(body, ["payload"]);
  const token = requiredString(body.payload, "payload", 24 * 1024);
  const notification = await verifyAppleNotification(token, env);
  const now = Math.floor(Date.now() / 1000);
  if (typeof notification.iat !== "number" || notification.iat > now + 5 * 60
    || notification.iat < now - 7 * 24 * 60 * 60 || typeof notification.jti !== "string") {
    throw new HttpError(401, "unauthorized", "Apple notification is invalid or stale");
  }
  const events = notification.events;
  if (!events || typeof events !== "object" || Array.isArray(events)) {
    throw new HttpError(400, "invalidRequest", "Apple notification events are invalid");
  }
  const event = events as Record<string, unknown>;
  if (typeof event.type !== "string" || typeof event.sub !== "string") {
    throw new HttpError(400, "invalidRequest", "Apple notification event is invalid");
  }
  const jtiDigest = await sha256Hex(notification.jti);
  const replay = await env.DB.prepare(
    "SELECT 1 AS found FROM apple_notifications WHERE jti_digest = ?",
  ).bind(jtiDigest).first<{ found: number }>();
  if (replay) return new Response(null, { status: 204 });

  // Account removal is idempotent. Process first, then record the replay marker, so a transient
  // D1 or Durable Object failure remains retryable even if a cleanup query would also fail.
  await processAppleAccountEvent(event.type, event.sub, env);
  try {
    await env.DB.prepare(
      "INSERT INTO apple_notifications (jti_digest, expires_at, created_at) VALUES (?, ?, ?)",
    ).bind(jtiDigest, now + 7 * 24 * 60 * 60, now).run();
  } catch {
    // A concurrent delivery may have completed the same idempotent event first.
    return new Response(null, { status: 204 });
  }
  return new Response(null, { status: 204 });
}

export async function processAppleAccountEvent(
  type: string,
  subject: string,
  env: Env,
): Promise<void> {
  if (type !== "consent-revoked" && type !== "account-deleted") return;
  if (subject.length === 0 || new TextEncoder().encode(subject).byteLength > 1024) {
    throw new HttpError(400, "invalidRequest", "Apple notification subject is invalid");
  }
  await removeAccount(await accountIDForAppleSubject(subject), env);
}

export async function validateDueAppleSessions(env: Env, now: number): Promise<void> {
  const rows = await env.DB.prepare(
    "SELECT account_id, client_id, encrypted_refresh_token FROM apple_tokens "
      + "WHERE invalidated_at IS NULL AND (last_validation_attempt_at IS NULL "
      + "OR last_validation_attempt_at <= ?) ORDER BY COALESCE(last_validation_attempt_at, 0) "
      + "LIMIT ?",
  ).bind(now - appleValidationIntervalSeconds, maximumAppleValidationsPerSchedule).all<{
    account_id: string;
    client_id: string;
    encrypted_refresh_token: string;
  }>();
  await forEachBounded(rows.results, maximumConcurrentCleanupRequests, async (row) => {
    const claimed = await env.DB.prepare(
      "UPDATE apple_tokens SET last_validation_attempt_at = ? "
        + "WHERE account_id = ? AND client_id = ? AND encrypted_refresh_token = ? "
        + "AND invalidated_at IS NULL AND (last_validation_attempt_at IS NULL "
        + "OR last_validation_attempt_at <= ?)",
    ).bind(
      now,
      row.account_id,
      row.client_id,
      row.encrypted_refresh_token,
      now - appleValidationIntervalSeconds,
    ).run();
    if (claimed.meta.changes !== 1) return;

    try {
      appleClientID(row.client_id, env);
      const validation = await validateAppleRefreshToken(
        await decryptAppleToken(row.encrypted_refresh_token, env),
        row.client_id,
        env,
      );
      if (validation.kind === "invalidGrant") {
        await invalidateAppleCredential(row, env, now);
        return;
      }
      const identity = await verifyAppleSessionIdentityToken(
        validation.identityToken,
        row.client_id,
        env,
      );
      if (await accountIDForAppleSubject(identity.sub as string) !== row.account_id) {
        throw new HttpError(502, "appleResponse", "Apple session identity did not match");
      }
      await env.DB.prepare(
        "UPDATE apple_tokens SET last_validated_at = ? "
          + "WHERE account_id = ? AND client_id = ? AND encrypted_refresh_token = ? "
          + "AND invalidated_at IS NULL",
      ).bind(
        now,
        row.account_id,
        row.client_id,
        row.encrypted_refresh_token,
      ).run();
    } catch (error) {
      console.warn("apple_session_validation_failed", {
        reason: error instanceof Error ? error.name : "unknown",
      });
    }
  });
}

async function invalidateAppleCredential(
  row: { account_id: string; client_id: string; encrypted_refresh_token: string },
  env: Env,
  now: number,
): Promise<void> {
  const results = await env.DB.batch([
    env.DB.prepare(
      "UPDATE apple_tokens SET invalidated_at = ?, updated_at = ? "
        + "WHERE account_id = ? AND client_id = ? AND encrypted_refresh_token = ? "
        + "AND invalidated_at IS NULL",
    ).bind(now, now, row.account_id, row.client_id, row.encrypted_refresh_token),
    env.DB.prepare(
      "UPDATE accounts SET auth_invalidated_at = ?, updated_at = ? WHERE id = ? "
        + "AND NOT EXISTS (SELECT 1 FROM apple_tokens WHERE account_id = ? AND invalidated_at IS NULL)",
    ).bind(now, now, row.account_id, row.account_id),
    env.DB.prepare(
      "UPDATE refresh_sessions SET revoked_at = ? WHERE account_id = ? AND revoked_at IS NULL "
        + "AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND auth_invalidated_at IS NOT NULL)",
    ).bind(now, row.account_id, row.account_id),
    env.DB.prepare(
      "UPDATE rendezvous_credentials SET revoked_at = ? "
        + "WHERE account_id = ? AND revoked_at IS NULL AND EXISTS "
        + "(SELECT 1 FROM accounts WHERE id = ? AND auth_invalidated_at IS NOT NULL)",
    ).bind(now, row.account_id, row.account_id),
  ]);
  if (results[0]?.meta.changes !== 1) return;
  const account = await env.DB.prepare(
    "SELECT auth_invalidated_at FROM accounts WHERE id = ?",
  ).bind(row.account_id).first<{ auth_invalidated_at: number | null }>();
  if (account?.auth_invalidated_at !== null && account?.auth_invalidated_at !== undefined) {
    await disconnectAccountHosts(row.account_id, env);
  }
}

async function removeAccount(accountID: string, env: Env): Promise<void> {
  const hosts = await accountHosts(accountID, env);
  await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(accountID).run();
  await disconnectHostsBestEffort(hosts, env);
}

async function disconnectAccountHosts(accountID: string, env: Env): Promise<void> {
  await disconnectHostsBestEffort(await accountHosts(accountID, env), env);
}

async function accountHosts(accountID: string, env: Env): Promise<Array<{ id: string }>> {
  const hosts = await env.DB.prepare(
    "SELECT id FROM hosts WHERE account_id = ? LIMIT ?",
  ).bind(accountID, maximumStoredHostsPerAccount).all<{ id: string }>();
  return hosts.results;
}

async function disconnectHostsBestEffort(hosts: Array<{ id: string }>, env: Env): Promise<void> {
  await forEachBounded(hosts, maximumConcurrentCleanupRequests, async (host) => {
    try {
      await env.HOST_RENDEZVOUS.getByName(host.id).fetch("https://internal/disconnect-host", {
        method: "POST",
        headers: { "X-Threading-Internal-Action": "disconnect-host" },
      });
    } catch (error) {
      console.warn("account_host_disconnect_failed", {
        reason: error instanceof Error ? error.name : "unknown",
      });
    }
  });
}

async function issueSession(accountID: string, env: Env, now: number): Promise<Response> {
  await cleanupExpiredRefreshSessions(accountID, env, now);
  const refreshToken = randomToken("th_refresh_");
  const accessToken = await signAccessToken(accountID, env);
  let inserted: D1Result;
  try {
    inserted = await env.DB.prepare(
      "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) "
        + "SELECT ?, ?, ?, ? WHERE (SELECT COUNT(*) FROM refresh_sessions "
        + "WHERE account_id = ? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?) < ?",
    ).bind(
      await sha256Hex(refreshToken),
      accountID,
      now + refreshLifetimeSeconds,
      now,
      accountID,
      now,
      maximumActiveRefreshSessions,
    ).run();
  } catch (error) {
    throwRefreshSessionLimit(error);
  }
  if (inserted.meta.changes !== 1) {
    throw new HttpError(429, "sessionLimit", "Account has too many active sessions");
  }
  return sessionResponse(
    accountID,
    accessToken,
    refreshToken,
    now + refreshLifetimeSeconds,
    now,
  );
}

async function retryRefreshSession(digest: string, env: Env, now: number): Promise<Response> {
  const row = await env.DB.prepare(
    "SELECT old.account_id, old.replacement_digest, old.replacement_encrypted_token, "
      + "replacement.expires_at FROM refresh_sessions old "
      + "JOIN refresh_sessions replacement ON replacement.digest = old.replacement_digest "
      + "JOIN accounts account ON account.id = old.account_id "
      + "WHERE old.digest = ? AND old.consumed_at IS NOT NULL AND old.revoked_at IS NULL "
      + "AND old.replacement_expires_at > ? AND replacement.consumed_at IS NULL "
      + "AND replacement.revoked_at IS NULL AND replacement.expires_at > ? "
      + "AND account.auth_invalidated_at IS NULL",
  ).bind(digest, now, now).first<{
    account_id: string;
    replacement_digest: string;
    replacement_encrypted_token: string;
    expires_at: number;
  }>();
  if (!row) throw new HttpError(401, "unauthorized", "Refresh token is invalid or expired");
  const replacementToken = await decryptRefreshReplacement(row.replacement_encrypted_token, env);
  if (await sha256Hex(replacementToken) !== row.replacement_digest) {
    throw new HttpError(503, "serviceState", "Stored refresh replacement did not match");
  }
  return sessionResponse(
    row.account_id,
    await signAccessToken(row.account_id, env),
    replacementToken,
    row.expires_at,
    now,
  );
}

async function cleanupExpiredRefreshSessions(
  accountID: string,
  env: Env,
  now: number,
): Promise<void> {
  await env.DB.prepare(
    "DELETE FROM refresh_sessions WHERE digest IN (SELECT digest FROM refresh_sessions "
      + "WHERE account_id = ? AND (expires_at <= ? OR revoked_at IS NOT NULL OR "
      + "(consumed_at IS NOT NULL AND (replacement_expires_at IS NULL "
      + "OR replacement_expires_at <= ?))) LIMIT 128)",
  ).bind(accountID, now, now).run();
}

function throwRefreshSessionLimit(error: unknown): never {
  const message = String(error);
  if (message.includes("threading_refresh_active_limit")
    || message.includes("threading_refresh_stored_limit")) {
    throw new HttpError(429, "sessionLimit", "Account has too many sessions");
  }
  throw error;
}

function sessionResponse(
  accountID: string,
  accessToken: string,
  refreshToken: string,
  refreshTokenExpiresAt: number,
  now: number,
): Response {
  return json({
    accessToken,
    accessTokenExpiresAt: (now + 15 * 60) * 1000,
    refreshToken,
    refreshTokenExpiresAt: refreshTokenExpiresAt * 1000,
    accountID,
  });
}

async function forEachBounded<Value>(
  values: Value[],
  width: number,
  operation: (value: Value) => Promise<void>,
): Promise<void> {
  for (let offset = 0; offset < values.length; offset += width) {
    await Promise.all(values.slice(offset, offset + width).map(operation));
  }
}

function appleClientID(audience: unknown, env: Env): string {
  const configured = new Set(
    env.APPLE_CLIENT_IDS.split(",").map((value) => value.trim()).filter(Boolean),
  );
  if (configured.size === 0 || configured.size > maximumAppleTokensPerAccount) {
    throw new HttpError(503, "serviceConfiguration", "Apple audiences are not configured safely");
  }
  const candidates = typeof audience === "string"
    ? [audience]
    : Array.isArray(audience) ? audience.filter((value): value is string => typeof value === "string") : [];
  const match = candidates.find((value) => configured.has(value));
  if (!match) throw new HttpError(401, "unauthorized", "Apple audience is invalid");
  return match;
}

function requiredString(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.length === 0
    || new TextEncoder().encode(value).byteLength > maximumBytes) {
    throw new HttpError(400, "invalidRequest", `${name} is invalid`);
  }
  return value;
}

function isLoopbackRequest(request: Request): boolean {
  const host = new URL(request.url).hostname.toLowerCase();
  return host === "localhost" || host === "127.0.0.1" || host === "[::1]" || host === "::1";
}
