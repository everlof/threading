import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";
import type { Env } from "./environment";
import { HttpError } from "./environment";
import { issueSession } from "./auth";
import { randomToken, sha256Hex } from "./crypto";
import { assertExactKeys, json, readJSON } from "./http";
import { validateIdentifier } from "./protocol";

const transactionLifetimeSeconds = 5 * 60;
const startKeys = ["hostID", "codeChallenge"];
const redeemKeys = ["transactionID", "pollToken", "codeVerifier", "hostID"];
const sha256Pattern = /^[0-9a-f]{64}$/u;
const verifierPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const accessKeySets = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

interface TransactionRow {
  authorized_account_id: string | null;
}

export async function startDevelopmentSignIn(request: Request, env: Env): Promise<Response> {
  requireDevelopmentMode(env);
  const body = await readJSON(request, 2 * 1024);
  assertExactKeys(body, startKeys);
  const hostID = identifier(body.hostID, "hostID");
  if (typeof body.codeChallenge !== "string" || !sha256Pattern.test(body.codeChallenge)) {
    invalid("codeChallenge is invalid");
  }
  const transactionID = randomToken("th_dev_auth_");
  const pollToken = randomToken("th_dev_poll_");
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + transactionLifetimeSeconds;
  await env.DB.prepare(
    "INSERT INTO development_auth_transactions "
      + "(transaction_digest, poll_token_digest, code_challenge, host_id, expires_at, created_at) "
      + "VALUES (?, ?, ?, ?, ?, ?)",
  ).bind(
    await sha256Hex(transactionID),
    await sha256Hex(pollToken),
    body.codeChallenge,
    hostID,
    expiresAt,
    now,
  ).run();
  const authorizationURL = new URL("/v1/auth/development/authorize", request.url);
  authorizationURL.searchParams.set("transaction", transactionID);
  return json({
    transactionID,
    pollToken,
    authorizationURL: authorizationURL.toString(),
    expiresAt: expiresAt * 1000,
  }, 201);
}

export async function authorizeDevelopmentSignIn(
  request: Request,
  env: Env,
): Promise<Response> {
  requireDevelopmentMode(env);
  const url = new URL(request.url);
  if ([...url.searchParams.keys()].some((key) => key !== "transaction")) {
    invalid("Authorization request is invalid");
  }
  const transactionID = url.searchParams.get("transaction");
  if (!transactionID || !transactionID.startsWith("th_dev_auth_")
    || transactionID.length > 256) {
    invalid("Authorization request is invalid");
  }
  const identity = await verifiedAccessIdentity(request, env);
  const accountID = `acct_dev_${(await sha256Hex(
    `${configuredIssuer(env)}\0${identity.sub}`,
  )).slice(0, 40)}`;
  const identityDigest = await sha256Hex(`${identity.sub}\0${identity.email}`);
  const now = Math.floor(Date.now() / 1000);
  const results = await env.DB.batch([
    env.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
        + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, auth_invalidated_at = NULL",
    ).bind(accountID, now, now),
    env.DB.prepare(
      "UPDATE development_auth_transactions SET authorized_account_id = ?, "
        + "authorized_identity_digest = ?, authorized_at = ? "
        + "WHERE transaction_digest = ? AND expires_at > ? AND consumed_at IS NULL "
        + "AND (authorized_account_id IS NULL OR authorized_account_id = ?)",
    ).bind(
      accountID,
      identityDigest,
      now,
      await sha256Hex(transactionID),
      now,
      accountID,
    ),
  ]);
  if (results[1]?.meta.changes !== 1) {
    throw new HttpError(410, "developmentAuthExpired", "Development sign-in expired");
  }
  return new Response(successPage, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
    },
  });
}

export async function redeemDevelopmentSignIn(request: Request, env: Env): Promise<Response> {
  requireDevelopmentMode(env);
  const body = await readJSON(request, 4 * 1024);
  assertExactKeys(body, redeemKeys);
  const transactionID = boundedToken(body.transactionID, "transactionID", "th_dev_auth_");
  const pollToken = boundedToken(body.pollToken, "pollToken", "th_dev_poll_");
  const hostID = identifier(body.hostID, "hostID");
  if (typeof body.codeVerifier !== "string" || !verifierPattern.test(body.codeVerifier)) {
    invalid("codeVerifier is invalid");
  }
  const now = Math.floor(Date.now() / 1000);
  const transactionDigest = await sha256Hex(transactionID);
  const row = await env.DB.prepare(
    "SELECT authorized_account_id FROM development_auth_transactions "
      + "WHERE transaction_digest = ? AND poll_token_digest = ? AND code_challenge = ? "
      + "AND host_id = ? AND expires_at > ? AND authorized_at IS NOT NULL "
      + "AND authorized_account_id IS NOT NULL AND consumed_at IS NULL",
  ).bind(
    transactionDigest,
    await sha256Hex(pollToken),
    await sha256Hex(body.codeVerifier),
    hostID,
    now,
  ).first<TransactionRow>();
  if (!row?.authorized_account_id) {
    throw new HttpError(409, "developmentAuthPending", "Development sign-in is pending");
  }
  const consumed = await env.DB.prepare(
    "UPDATE development_auth_transactions SET consumed_at = ? "
      + "WHERE transaction_digest = ? AND consumed_at IS NULL AND expires_at > ?",
  ).bind(now, transactionDigest, now).run();
  if (consumed.meta.changes !== 1) {
    throw new HttpError(409, "developmentAuthConsumed", "Development sign-in was already used");
  }
  return issueSession(row.authorized_account_id, env, now);
}

export function validateDevelopmentAuthConfiguration(env: Env): void {
  if (env.DEVELOPMENT_AUTH_MODE !== "1") return;
  configuredIssuer(env);
  configuredAudience(env);
  configuredEmails(env);
}

async function verifiedAccessIdentity(
  request: Request,
  env: Env,
): Promise<{ sub: string; email: string }> {
  const assertion = request.headers.get("Cf-Access-Jwt-Assertion");
  if (!assertion || assertion.length > 16 * 1024) {
    throw new HttpError(401, "developmentAccessRequired", "Cloudflare Access is required");
  }
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(assertion, accessKeySet(configuredIssuer(env)), {
      issuer: configuredIssuer(env),
      audience: configuredAudience(env),
      algorithms: ["RS256"],
    }));
  } catch {
    throw new HttpError(401, "developmentAccessInvalid", "Cloudflare Access assertion is invalid");
  }
  if (typeof payload.sub !== "string" || payload.sub.length === 0 || payload.sub.length > 512
    || typeof payload.email !== "string") {
    throw new HttpError(401, "developmentAccessInvalid", "Cloudflare Access identity is invalid");
  }
  const email = payload.email.trim().toLowerCase();
  if (!configuredEmails(env).has(email)) {
    throw new HttpError(403, "developmentAccessDenied", "Identity is not allowed");
  }
  return { sub: payload.sub, email };
}

function accessKeySet(issuer: string): ReturnType<typeof createRemoteJWKSet> {
  const existing = accessKeySets.get(issuer);
  if (existing) return existing;
  const created = createRemoteJWKSet(new URL(`${issuer}/cdn-cgi/access/certs`));
  accessKeySets.set(issuer, created);
  return created;
}

function configuredIssuer(env: Env): string {
  const raw = env.DEVELOPMENT_ACCESS_ISSUER;
  if (typeof raw !== "string" || raw.length > 512) configurationError();
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    configurationError();
  }
  if (url.protocol !== "https:" || url.username || url.password || url.port
    || url.pathname !== "/" || url.search || url.hash
    || !url.hostname.endsWith(".cloudflareaccess.com")) {
    configurationError();
  }
  return url.origin;
}

function configuredAudience(env: Env): string {
  const value = env.DEVELOPMENT_ACCESS_AUDIENCE;
  if (typeof value !== "string" || value.length < 16 || value.length > 512
    || !/^[A-Za-z0-9_-]+$/u.test(value)) configurationError();
  return value;
}

function configuredEmails(env: Env): Set<string> {
  if (typeof env.DEVELOPMENT_ACCESS_EMAILS !== "string") configurationError();
  const values = env.DEVELOPMENT_ACCESS_EMAILS.split(",")
    .map((value) => value.trim().toLowerCase())
    .filter(Boolean);
  if (values.length === 0 || values.length > 8 || new Set(values).size !== values.length
    || values.some((value) => value.length > 320 || !/^[^\s@]+@[^\s@]+$/u.test(value))) {
    configurationError();
  }
  return new Set(values);
}

function requireDevelopmentMode(env: Env): void {
  if (env.DEVELOPMENT_AUTH_MODE !== "1" || env.LOCAL_DEVELOPMENT_MODE === "1") {
    throw new HttpError(404, "notFound", "Endpoint was not found");
  }
  validateDevelopmentAuthConfiguration(env);
}

function identifier(value: unknown, name: string): string {
  if (typeof value !== "string" || !validateIdentifier(value)) invalid(`${name} is invalid`);
  return value;
}

function boundedToken(value: unknown, name: string, prefix: string): string {
  if (typeof value !== "string" || !value.startsWith(prefix) || value.length > 256
    || !/^[A-Za-z0-9_-]+$/u.test(value)) invalid(`${name} is invalid`);
  return value;
}

function invalid(message: string): never {
  throw new HttpError(400, "invalidRequest", message);
}

function configurationError(): never {
  throw new HttpError(503, "serviceConfiguration", "Development authentication is not configured");
}

const successPage = `<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Threading development sign-in</title>
<style>
  :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
  body { min-height: 100vh; margin: 0; display: grid; place-items: center; }
  main { max-width: 32rem; padding: 2rem; text-align: center; }
</style>
<main><h1>Threading is authorized</h1><p>You can close this window and return to the app.</p></main>
</html>`;
