import type { AccessPrincipal, Env } from "./environment";
import { HttpError } from "./environment";
import {
  accountIDForAppleSubject,
  randomToken,
  sha256Hex,
  signAccessToken,
  verifyAccessToken,
  verifyAppleIdentityToken,
} from "./crypto";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";

const refreshLifetimeSeconds = 30 * 24 * 60 * 60;

export async function handleAppleSignIn(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request);
  assertExactKeys(body, ["identityToken", "nonce"]);
  const identityToken = requiredString(body.identityToken, "identityToken", 16 * 1024);
  const nonce = requiredString(body.nonce, "nonce", 512);
  const payload = await verifyAppleIdentityToken(identityToken, nonce, env);
  const accountID = await accountIDForAppleSubject(payload.sub as string);
  const assertionDigest = await sha256Hex(identityToken);
  const now = Math.floor(Date.now() / 1000);
  const expiry = typeof payload.exp === "number" ? Math.floor(payload.exp) : now;

  await env.DB.prepare(
    "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
      + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at",
  ).bind(accountID, now, now).run();
  try {
    await env.DB.prepare(
      "INSERT INTO apple_assertions (digest, account_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
    ).bind(assertionDigest, accountID, expiry, now).run();
  } catch {
    throw new HttpError(409, "identityTokenReplayed", "Apple identity token was already used");
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

export async function authenticateAccess(request: Request, env: Env): Promise<AccessPrincipal> {
  try {
    return { accountID: await verifyAccessToken(bearerToken(request), env) };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "unauthorized", "Access token is invalid or expired");
  }
}

async function issueSession(accountID: string, env: Env, now: number): Promise<Response> {
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

function requiredString(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.length === 0
    || new TextEncoder().encode(value).byteLength > maximumBytes) {
    throw new HttpError(400, "invalidRequest", `${name} is invalid`);
  }
  return value;
}
