import type { Env } from "./environment";
import { HttpError } from "./environment";
import { randomToken, sha256Hex } from "./crypto";
import { authorizeRendezvousCredential } from "./enrollment";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";

const registrationRequestKeys = ["deviceToken", "environment"];
const environments = new Set(["sandbox", "production"]);
const deviceTokenPattern = /^[0-9a-f]+$/u;
const registrationIDPattern = /^th_push_[A-Za-z0-9_-]{32,128}$/u;
const encoder = new TextEncoder();
const tokenKeyCache = new WeakMap<object, Promise<CryptoKey>>();

export interface PushRegistration {
  registrationID: string;
  hostID: string;
  deviceID: string;
  environment: "sandbox" | "production";
}

interface StoredPushRegistration {
  account_id: string;
  host_id: string;
  device_id: string;
  encrypted_device_token: string;
  device_token_digest: string;
  environment: "sandbox" | "production";
}

export async function registerPushRecipient(request: Request, env: Env): Promise<Response> {
  const principal = await authorizeRendezvousCredential(
    bearerToken(request),
    "device",
    env,
  );
  if (principal.kind !== "device") {
    throw new HttpError(403, "forbidden", "Device credential required");
  }
  const body = await readJSON(request, 4 * 1024);
  assertExactKeys(body, registrationRequestKeys);
  const deviceToken = normalizedDeviceToken(body.deviceToken);
  const environment = normalizedEnvironment(body.environment);
  const registrationID = randomToken("th_push_");
  const now = Math.floor(Date.now() / 1000);
  const encrypted = await encryptDeviceToken(
    deviceToken,
    principal.hostID,
    principal.deviceID,
    environment,
    env,
  );
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE push_registrations SET revoked_at = ?, updated_at = ? "
        + "WHERE host_id = ? AND device_id = ? AND revoked_at IS NULL",
    ).bind(now, now, principal.hostID, principal.deviceID),
    env.DB.prepare(
      "INSERT INTO push_registrations "
        + "(digest, account_id, host_id, device_id, encrypted_device_token, "
        + "device_token_digest, environment, created_at, updated_at) "
        + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind(
      await sha256Hex(registrationID),
      principal.accountID,
      principal.hostID,
      principal.deviceID,
      encrypted,
      await sha256Hex(deviceToken),
      environment,
      now,
      now,
    ),
  ]);
  return json({
    registrationID,
    hostID: principal.hostID,
    deviceID: principal.deviceID,
    environment,
  }, 201);
}

export async function registeredPushRecipient(
  registrationID: unknown,
  hostID: string,
  accountID: string,
  env: Env,
): Promise<{
  deviceToken: string;
  deviceTokenDigest: string;
  deviceID: string;
  environment: "sandbox" | "production";
}> {
  if (typeof registrationID !== "string" || !registrationIDPattern.test(registrationID)) {
    throw new HttpError(400, "invalidRequest", "Push registration is invalid");
  }
  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare(
    "SELECT p.account_id, p.host_id, p.device_id, p.encrypted_device_token, "
      + "p.device_token_digest, p.environment FROM push_registrations p "
      + "WHERE p.digest = ? AND p.host_id = ? AND p.account_id = ? AND p.revoked_at IS NULL "
      + "AND EXISTS (SELECT 1 FROM rendezvous_credentials c WHERE c.account_id = p.account_id "
      + "AND c.host_id = p.host_id AND c.device_id = p.device_id AND c.kind = 'device' "
      + "AND c.revoked_at IS NULL AND c.expires_at > ?)",
  ).bind(await sha256Hex(registrationID), hostID, accountID, now)
    .first<StoredPushRegistration>();
  if (!row) {
    throw new HttpError(404, "pushRegistrationNotFound", "Push registration was not found");
  }
  const deviceToken = await decryptDeviceToken(
    row.encrypted_device_token,
    row.host_id,
    row.device_id,
    row.environment,
    env,
  );
  if (await sha256Hex(deviceToken) !== row.device_token_digest) {
    throw new HttpError(503, "serviceState", "Stored push registration did not match");
  }
  return {
    deviceToken,
    deviceTokenDigest: row.device_token_digest,
    deviceID: row.device_id,
    environment: row.environment,
  };
}

export async function revokePushRegistration(
  registrationID: string,
  env: Env,
): Promise<void> {
  await env.DB.prepare(
    "UPDATE push_registrations SET revoked_at = ?, updated_at = ? "
      + "WHERE digest = ? AND revoked_at IS NULL",
  ).bind(
    Math.floor(Date.now() / 1000),
    Math.floor(Date.now() / 1000),
    await sha256Hex(registrationID),
  ).run();
}

export function validatePushTokenEncryptionConfiguration(env: Env): void {
  configuredEncryptionSecret(env);
}

function normalizedDeviceToken(value: unknown): string {
  if (typeof value !== "string") invalid("deviceToken is invalid");
  const normalized = value.toLowerCase();
  if (normalized.length < 32 || normalized.length > 512
    || normalized.length % 2 !== 0
    || !deviceTokenPattern.test(normalized)) {
    invalid("deviceToken is invalid");
  }
  return normalized;
}

function normalizedEnvironment(value: unknown): "sandbox" | "production" {
  if (typeof value !== "string" || !environments.has(value)) {
    invalid("environment is invalid");
  }
  return value as "sandbox" | "production";
}

async function encryptDeviceToken(
  deviceToken: string,
  hostID: string,
  deviceID: string,
  environment: string,
  env: Env,
): Promise<string> {
  const iv = new Uint8Array(12);
  crypto.getRandomValues(iv);
  const ciphertext = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv,
      additionalData: tokenAssociatedData(hostID, deviceID, environment),
    },
    await tokenEncryptionKey(env),
    encoder.encode(deviceToken),
  );
  return `${base64URL(iv)}.${base64URL(new Uint8Array(ciphertext))}`;
}

async function decryptDeviceToken(
  value: string,
  hostID: string,
  deviceID: string,
  environment: string,
  env: Env,
): Promise<string> {
  const parts = value.split(".");
  if (parts.length !== 2) storedTokenError();
  try {
    const iv = fromBase64URL(parts[0] ?? "");
    const ciphertext = fromBase64URL(parts[1] ?? "");
    if (iv.byteLength !== 12 || ciphertext.byteLength > 544) throw new Error("invalid token");
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv,
        additionalData: tokenAssociatedData(hostID, deviceID, environment),
      },
      await tokenEncryptionKey(env),
      ciphertext,
    );
    return normalizedDeviceToken(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(plaintext),
    );
  } catch (error) {
    if (error instanceof HttpError) throw error;
    storedTokenError();
  }
}

function tokenAssociatedData(hostID: string, deviceID: string, environment: string): Uint8Array {
  return encoder.encode(`threading-push-registration-v1\0${hostID}\0${deviceID}\0${environment}`);
}

async function tokenEncryptionKey(env: Env): Promise<CryptoKey> {
  const cached = tokenKeyCache.get(env);
  if (cached) return cached;
  const imported = crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`threading-push-token-v1:${configuredEncryptionSecret(env)}`),
  ).then((material) => crypto.subtle.importKey(
    "raw",
    material,
    "AES-GCM",
    false,
    ["encrypt", "decrypt"],
  )).catch((error) => {
    tokenKeyCache.delete(env);
    throw error;
  });
  tokenKeyCache.set(env, imported);
  return imported;
}

function configuredEncryptionSecret(env: Env): string {
  const value = env.PUSH_TOKEN_ENCRYPTION_SECRET;
  if (typeof value !== "string" || encoder.encode(value).byteLength < 32
    || encoder.encode(value).byteLength > 4096 || /[\u0000-\u0020\u007f]/u.test(value)) {
    throw new HttpError(503, "serviceConfiguration", "Push token encryption is not configured");
  }
  return value;
}

function invalid(message: string): never {
  throw new HttpError(400, "invalidRequest", message);
}

function storedTokenError(): never {
  throw new HttpError(503, "serviceState", "Stored push registration could not be decrypted");
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
