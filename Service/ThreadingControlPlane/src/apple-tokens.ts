import { SignJWT, importPKCS8 } from "jose";
import type { Env } from "./environment";
import { HttpError } from "./environment";

const encoder = new TextEncoder();
const maximumAppleResponseBytes = 64 * 1024;
const maximumAppleTokenBytes = 8 * 1024;

interface AppleTokenResponse {
  access_token?: unknown;
  expires_in?: unknown;
  id_token?: unknown;
  refresh_token?: unknown;
  token_type?: unknown;
  error?: unknown;
}

export interface AppleTokens {
  identityToken: string;
  refreshToken: string;
}

export type AppleRefreshValidation =
  | { kind: "valid"; identityToken: string }
  | { kind: "invalidGrant" };

const appleKeyCache = new WeakMap<object, Promise<CryptoKey>>();
const appleClientSecretCache = new WeakMap<object, Map<string, { value: string; expiresAt: number }>>();

export async function exchangeAppleAuthorizationCode(
  authorizationCode: string,
  clientID: string,
  env: Env,
): Promise<AppleTokens> {
  boundedSecret(authorizationCode, "authorizationCode", 4096);
  const body = new URLSearchParams({
    client_id: clientID,
    client_secret: await appleClientSecret(clientID, env),
    code: authorizationCode,
    grant_type: "authorization_code",
  });
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(5_000),
  });
  const value = await boundedJSON<AppleTokenResponse>(response);
  if (!response.ok) throw new HttpError(401, "appleAuthorization", "Apple authorization failed");
  const identityToken = boundedSecret(value.id_token, "id_token", 16 * 1024);
  const refreshToken = boundedSecret(value.refresh_token, "refresh_token", maximumAppleTokenBytes);
  return { identityToken, refreshToken };
}

export async function revokeAppleRefreshToken(
  refreshToken: string,
  clientID: string,
  env: Env,
): Promise<void> {
  boundedSecret(refreshToken, "refreshToken", maximumAppleTokenBytes);
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientID,
      client_secret: await appleClientSecret(clientID, env),
      token: refreshToken,
      token_type_hint: "refresh_token",
    }),
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) {
    // Drain only a bounded body so an upstream failure cannot retain arbitrary bytes.
    await boundedText(response);
    throw new HttpError(502, "appleRevocation", "Apple token revocation failed");
  }
}

export async function validateAppleRefreshToken(
  refreshToken: string,
  clientID: string,
  env: Env,
): Promise<AppleRefreshValidation> {
  boundedSecret(refreshToken, "refreshToken", maximumAppleTokenBytes);
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientID,
      client_secret: await appleClientSecret(clientID, env),
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    }),
    signal: AbortSignal.timeout(5_000),
  });
  const value = await boundedJSON<AppleTokenResponse>(response);
  if (!response.ok) {
    if (response.status === 400 && value.error === "invalid_grant") {
      return { kind: "invalidGrant" };
    }
    throw new HttpError(502, "appleValidation", "Apple session validation failed");
  }
  boundedSecret(value.access_token, "access_token", maximumAppleTokenBytes);
  const identityToken = boundedSecret(value.id_token, "id_token", 16 * 1024);
  if (value.token_type !== "Bearer" || !Number.isInteger(value.expires_in)
    || (value.expires_in as number) <= 0) {
    throw new HttpError(502, "appleResponse", "Apple returned an invalid token response");
  }
  return { kind: "valid", identityToken };
}

export async function encryptAppleToken(token: string, env: Env): Promise<string> {
  boundedSecret(token, "refreshToken", maximumAppleTokenBytes);
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await encryptionKey(env),
    encoder.encode(token),
  );
  return `${base64URL(iv)}.${base64URL(new Uint8Array(encrypted))}`;
}

export async function decryptAppleToken(value: string, env: Env): Promise<string> {
  if (value.length === 0 || value.length > maximumAppleTokenBytes * 2) {
    throw new HttpError(503, "serviceConfiguration", "Stored Apple token is invalid");
  }
  const parts = value.split(".");
  if (parts.length !== 2) throw new HttpError(503, "serviceConfiguration", "Stored Apple token is invalid");
  try {
    const iv = fromBase64URL(parts[0] ?? "");
    const ciphertext = fromBase64URL(parts[1] ?? "");
    if (iv.byteLength !== 12 || ciphertext.byteLength > maximumAppleTokenBytes + 32) {
      throw new Error("invalid encrypted token");
    }
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv },
      await encryptionKey(env),
      ciphertext,
    );
    return boundedSecret(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(plaintext),
      "refreshToken",
      maximumAppleTokenBytes,
    );
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(503, "serviceConfiguration", "Stored Apple token could not be decrypted");
  }
}

async function appleClientSecret(clientID: string, env: Env): Promise<string> {
  const teamID = configured(env.APPLE_TEAM_ID, "Apple team ID");
  const keyID = configured(env.APPLE_KEY_ID, "Apple key ID");
  const now = Math.floor(Date.now() / 1000);
  let secrets = appleClientSecretCache.get(env);
  if (!secrets) {
    secrets = new Map();
    appleClientSecretCache.set(env, secrets);
  }
  const cached = secrets.get(clientID);
  if (cached && cached.expiresAt > now + 30) return cached.value;
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyID })
    .setIssuer(teamID)
    .setAudience("https://appleid.apple.com")
    .setSubject(clientID)
    .setIssuedAt(now)
    .setExpirationTime(now + 5 * 60)
    .sign(await applePrivateKey(env));
  secrets.set(clientID, { value, expiresAt: now + 5 * 60 });
  return value;
}

async function applePrivateKey(env: Env): Promise<CryptoKey> {
  const cached = appleKeyCache.get(env);
  if (cached) return cached;
  const privateKey = configured(env.APPLE_PRIVATE_KEY, "Apple private key").replaceAll("\\n", "\n");
  const imported = importPKCS8(privateKey, "ES256").catch(() => {
    appleKeyCache.delete(env);
    throw new HttpError(503, "serviceConfiguration", "Apple private key is invalid");
  });
  appleKeyCache.set(env, imported);
  return imported;
}

async function encryptionKey(env: Env): Promise<CryptoKey> {
  const secret = configured(env.APPLE_TOKEN_ENCRYPTION_SECRET, "Apple token encryption secret");
  if (encoder.encode(secret).byteLength < 32) {
    throw new HttpError(503, "serviceConfiguration", "Apple token encryption secret is too short");
  }
  const material = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`threading-apple-token-v1:${secret}`),
  );
  return crypto.subtle.importKey("raw", material, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function configured(value: string | undefined, label: string): string {
  if (!value || value.trim().length === 0) {
    throw new HttpError(503, "serviceConfiguration", `${label} is not configured`);
  }
  return value.trim();
}

function boundedSecret(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.length === 0
    || encoder.encode(value).byteLength > maximumBytes || /[\u0000-\u0020\u007f]/u.test(value)) {
    throw new HttpError(400, "invalidRequest", `${name} is invalid`);
  }
  return value;
}

async function boundedJSON<Value>(response: Response): Promise<Value> {
  const text = await boundedText(response);
  try {
    return JSON.parse(text) as Value;
  } catch {
    throw new HttpError(502, "appleResponse", "Apple returned an invalid response");
  }
}

async function boundedText(response: Response): Promise<string> {
  const declared = Number(response.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > maximumAppleResponseBytes) {
    throw new HttpError(502, "appleResponse", "Apple response was too large");
  }
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let count = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (count > maximumAppleResponseBytes - value.byteLength) {
      await reader.cancel();
      throw new HttpError(502, "appleResponse", "Apple response was too large");
    }
    count += value.byteLength;
    chunks.push(value);
  }
  const joined = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(joined);
  } catch {
    throw new HttpError(502, "appleResponse", "Apple returned invalid text");
  }
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function fromBase64URL(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new Error("invalid base64url");
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - value.length % 4) % 4);
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}
