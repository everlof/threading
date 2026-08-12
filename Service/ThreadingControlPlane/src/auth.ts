import type { AccessPrincipal, Env } from "./environment";
import { HttpError } from "./environment";
import {
  accountIDForAppleSubject,
  randomToken,
  sha256Hex,
  signAccessToken,
  verifyAccessToken,
  verifyAppleIdentityToken,
  verifyAppleNotification,
} from "./crypto";
import {
  decryptAppleToken,
  encryptAppleToken,
  exchangeAppleAuthorizationCode,
  revokeAppleRefreshToken,
} from "./apple-tokens";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";

const refreshLifetimeSeconds = 30 * 24 * 60 * 60;
const maximumActiveRefreshSessions = 64;
const maximumAppleTokensPerAccount = 8;
const maximumHostsPerAccount = 16;

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
  } catch {
    throw new HttpError(409, "identityTokenReplayed", "Apple identity token was already used");
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
        + "(account_id, client_id, encrypted_refresh_token, created_at, updated_at) "
        + "VALUES (?, ?, ?, ?, ?) ON CONFLICT(account_id, client_id) DO UPDATE SET "
        + "encrypted_refresh_token = excluded.encrypted_refresh_token, updated_at = excluded.updated_at",
    ).bind(accountID, clientID, encrypted, now, now).run();
  } catch (error) {
    await env.DB.prepare("DELETE FROM apple_assertions WHERE digest = ?").bind(assertionDigest).run();
    throw error;
  }
  return issueSession(accountID, env, now);
}

export async function handleRefresh(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["refreshToken"]);
  const refreshToken = requiredString(body.refreshToken, "refreshToken", 4096);
  const digest = await sha256Hex(refreshToken);
  const now = Math.floor(Date.now() / 1000);
  const result = await env.DB.prepare(
    "UPDATE refresh_sessions SET consumed_at = ? "
      + "WHERE digest = ? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ? "
      + "RETURNING account_id",
  ).bind(now, digest, now).run<{ account_id: string }>();
  const accountID = result.results[0]?.account_id;
  if (!accountID) throw new HttpError(401, "unauthorized", "Refresh token is invalid or expired");
  return issueSession(accountID, env, now);
}

/// Invalidates exactly the refresh session presented by this installation. The response is
/// intentionally idempotent so a client can safely retry after losing the first response.
export async function handleSignOut(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["refreshToken"]);
  const refreshToken = requiredString(body.refreshToken, "refreshToken", 4096);
  await env.DB.prepare(
    "UPDATE refresh_sessions SET revoked_at = ? WHERE digest = ? AND revoked_at IS NULL",
  ).bind(Math.floor(Date.now() / 1000), await sha256Hex(refreshToken)).run();
  return new Response(null, { status: 204 });
}

export async function authenticateAccess(request: Request, env: Env): Promise<AccessPrincipal> {
  try {
    const accountID = await verifyAccessToken(bearerToken(request), env);
    const account = await env.DB.prepare("SELECT 1 AS found FROM accounts WHERE id = ?")
      .bind(accountID).first<{ found: number }>();
    if (!account) throw new HttpError(401, "unauthorized", "Account no longer exists");
    return { accountID };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "unauthorized", "Access token is invalid or expired");
  }
}

export async function handleDeleteAccount(request: Request, env: Env): Promise<Response> {
  const principal = await authenticateAccess(request, env);
  const tokens = await env.DB.prepare(
    "SELECT client_id, encrypted_refresh_token FROM apple_tokens WHERE account_id = ? LIMIT ?",
  ).bind(principal.accountID, maximumAppleTokensPerAccount + 1).all<{
    client_id: string;
    encrypted_refresh_token: string;
  }>();
  if (tokens.results.length > maximumAppleTokensPerAccount) {
    throw new HttpError(503, "serviceState", "Account has too many Apple tokens");
  }
  for (const token of tokens.results) {
    appleClientID(token.client_id, env);
    await revokeAppleRefreshToken(
      await decryptAppleToken(token.encrypted_refresh_token, env),
      token.client_id,
      env,
    );
  }

  await removeAccount(principal.accountID, env);
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
  try {
    await env.DB.prepare(
      "INSERT INTO apple_notifications (jti_digest, expires_at, created_at) VALUES (?, ?, ?)",
    ).bind(jtiDigest, now + 7 * 24 * 60 * 60, now).run();
  } catch {
    return new Response(null, { status: 204 });
  }
  await processAppleAccountEvent(event.type, event.sub, env);
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

async function removeAccount(accountID: string, env: Env): Promise<void> {
  const hosts = await env.DB.prepare(
    "SELECT id FROM hosts WHERE account_id = ? LIMIT ?",
  ).bind(accountID, maximumHostsPerAccount + 1).all<{ id: string }>();
  if (hosts.results.length > maximumHostsPerAccount) {
    throw new HttpError(503, "serviceState", "Account has too many hosts");
  }
  for (const host of hosts.results) {
    await env.HOST_RENDEZVOUS.getByName(host.id).fetch("https://internal/disconnect-host", {
      method: "POST",
      headers: { "X-Threading-Internal-Action": "disconnect-host" },
    });
  }
  await env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(accountID).run();
}

async function issueSession(accountID: string, env: Env, now: number): Promise<Response> {
  const active = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM refresh_sessions WHERE account_id = ? "
      + "AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
  ).bind(accountID, now).first<{ count: number }>();
  if ((active?.count ?? 0) >= maximumActiveRefreshSessions) {
    throw new HttpError(429, "sessionLimit", "Account has too many active sessions");
  }
  const refreshToken = randomToken("th_refresh_");
  await env.DB.prepare(
    "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
  ).bind(
    await sha256Hex(refreshToken),
    accountID,
    now + refreshLifetimeSeconds,
    now,
  ).run();
  return json({
    accessToken: await signAccessToken(accountID, env),
    accessTokenExpiresAt: (now + 15 * 60) * 1000,
    refreshToken,
    refreshTokenExpiresAt: (now + refreshLifetimeSeconds) * 1000,
    accountID,
  });
}

function appleClientID(audience: unknown, env: Env): string {
  const configured = new Set(
    env.APPLE_CLIENT_IDS.split(",").map((value) => value.trim()).filter(Boolean),
  );
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
