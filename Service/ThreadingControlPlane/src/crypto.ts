import { SignJWT, createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";
import type { Env } from "./environment";
import { HttpError } from "./environment";

const encoder = new TextEncoder();
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

export function randomToken(prefix: string): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `${prefix}${base64URL(bytes)}`;
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function accountIDForAppleSubject(subject: string): Promise<string> {
  return `acct_${(await sha256Hex(`apple:${subject}`)).slice(0, 40)}`;
}

export async function signAccessToken(accountID: string, env: Env): Promise<string> {
  return new SignJWT({ typ: "access" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(accountID)
    .setIssuer("threading-control-plane")
    .setAudience("threading-apple-clients")
    .setIssuedAt()
    .setExpirationTime("15m")
    .setJti(crypto.randomUUID())
    .sign(signingKey(env));
}

export async function verifyAccessToken(token: string, env: Env): Promise<string> {
  const { payload } = await jwtVerify(token, signingKey(env), {
    issuer: "threading-control-plane",
    audience: "threading-apple-clients",
    algorithms: ["HS256"],
  });
  if (payload.typ !== "access" || typeof payload.sub !== "string") {
    throw new HttpError(401, "unauthorized", "Invalid access token");
  }
  return payload.sub;
}

export async function signRendezvousSessionToken(
  accountID: string,
  hostID: string,
  sessionID: string,
  expiresAtSeconds: number,
  env: Env,
): Promise<string> {
  return new SignJWT({ typ: "rendezvous-session", hostID, sessionID })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(accountID)
    .setIssuer("threading-control-plane")
    .setAudience("threading-rendezvous")
    .setIssuedAt()
    .setExpirationTime(expiresAtSeconds)
    .setJti(crypto.randomUUID())
    .sign(signingKey(env));
}

export async function verifyRendezvousSessionToken(
  token: string,
  env: Env,
): Promise<{ accountID: string; hostID: string; sessionID: string }> {
  const { payload } = await jwtVerify(token, signingKey(env), {
    issuer: "threading-control-plane",
    audience: "threading-rendezvous",
    algorithms: ["HS256"],
  });
  if (payload.typ !== "rendezvous-session" || typeof payload.sub !== "string"
    || typeof payload.hostID !== "string" || typeof payload.sessionID !== "string") {
    throw new HttpError(401, "unauthorized", "Invalid rendezvous session token");
  }
  return { accountID: payload.sub, hostID: payload.hostID, sessionID: payload.sessionID };
}

export async function verifyAppleIdentityToken(
  identityToken: string,
  rawNonce: string,
  env: Env,
): Promise<JWTPayload> {
  const audiences = env.APPLE_CLIENT_IDS.split(",").map((value) => value.trim()).filter(Boolean);
  if (audiences.length === 0) throw new HttpError(503, "serviceConfiguration", "Apple audience is not configured");
  const { payload } = await jwtVerify(identityToken, appleKeys, {
    issuer: "https://appleid.apple.com",
    audience: audiences,
    algorithms: ["RS256"],
  });
  if (typeof payload.sub !== "string" || typeof payload.nonce !== "string") {
    throw new HttpError(401, "unauthorized", "Apple identity token is missing required claims");
  }
  const expectedNonce = await sha256Hex(rawNonce);
  if (payload.nonce.toLowerCase() !== expectedNonce) {
    throw new HttpError(401, "unauthorized", "Apple identity nonce does not match");
  }
  return payload;
}

function signingKey(env: Env): Uint8Array {
  const bytes = encoder.encode(env.SESSION_SIGNING_SECRET);
  if (bytes.byteLength < 32) {
    throw new HttpError(503, "serviceConfiguration", "Signing secret is not configured");
  }
  return bytes;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}
