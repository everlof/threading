import type { Env, RendezvousPrincipal } from "./environment";
import { HttpError } from "./environment";
import { authenticateAccess } from "./auth";
import { randomToken, sha256Hex } from "./crypto";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";
import { validateIdentifier } from "./protocol";

const hostCredentialLifetimeSeconds = 90 * 24 * 60 * 60;
const deviceCredentialLifetimeSeconds = 30 * 24 * 60 * 60;
const minimumDeviceCredentialLifetimeSeconds = 60;
const maximumDevicesPerHost = 64;
const maximumHostsPerAccount = 16;
const maximumStoredHostsPerAccount = 64;

interface CredentialRow {
  kind: "host" | "device";
  account_id: string;
  host_id: string;
  device_id: string | null;
  expires_at: number;
}

export async function enrollHost(request: Request, env: Env): Promise<Response> {
  const principal = await authenticateAccess(request, env);
  const body = await readJSON(request);
  assertExactKeys(body, ["hostID", "displayName"]);
  const hostID = identifier(body.hostID, "hostID");
  const displayName = boundedDisplayName(body.displayName);
  const now = Math.floor(Date.now() / 1000);
  const existing = await env.DB.prepare(
    "SELECT account_id, revoked_at FROM hosts WHERE id = ?",
  ).bind(hostID).first<{ account_id: string; revoked_at: number | null }>();
  if (existing && existing.account_id !== principal.accountID) {
    throw new HttpError(409, "hostAlreadyRegistered", "Host is registered to another account");
  }
  if (existing) {
    if (!await updateOwnedHost(hostID, principal.accountID, displayName, now, env)) {
      throw new HttpError(429, "hostLimit", "Account has too many active hosts");
    }
  } else {
    let didEnroll = false;
    try {
      const result = await env.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
          + "SELECT ?, ?, ?, ?, ? WHERE "
          + "(SELECT COUNT(*) FROM hosts WHERE account_id = ? AND revoked_at IS NULL) < ? "
          + "AND (SELECT COUNT(*) FROM hosts WHERE account_id = ?) < ?",
      ).bind(
        hostID,
        principal.accountID,
        displayName,
        now,
        now,
        principal.accountID,
        maximumHostsPerAccount,
        principal.accountID,
        maximumStoredHostsPerAccount,
      ).run();
      didEnroll = result.meta.changes === 1;
    } catch (error) {
      // Another request may have enrolled this exact identifier after the initial lookup.
      const raced = await env.DB.prepare("SELECT account_id FROM hosts WHERE id = ?")
        .bind(hostID).first<{ account_id: string }>();
      if (raced?.account_id === principal.accountID) {
        didEnroll = await updateOwnedHost(
          hostID,
          principal.accountID,
          displayName,
          now,
          env,
        );
      } else if (raced) {
        throw new HttpError(409, "hostAlreadyRegistered", "Host is registered to another account");
      } else {
        throw error;
      }
    }
    if (!didEnroll) {
      throw new HttpError(429, "hostLimit", "Account has too many hosts");
    }
  }
  return rotateHostCredential(hostID, principal.accountID, env, now);
}

export async function rotateHostCredentialForAccount(
  request: Request,
  env: Env,
  hostID: string,
): Promise<Response> {
  if (!validateIdentifier(hostID)) throw new HttpError(400, "invalidHost", "Host ID is invalid");
  const principal = await authenticateAccess(request, env);
  await requireHostOwner(hostID, principal.accountID, env);
  return rotateHostCredential(hostID, principal.accountID, env, Math.floor(Date.now() / 1000));
}

export async function issueDeviceCredential(
  request: Request,
  env: Env,
  hostID: string,
): Promise<Response> {
  if (!validateIdentifier(hostID)) throw new HttpError(400, "invalidHost", "Host ID is invalid");
  const accountID = await authorizeHostMutation(request, env, hostID);
  const body = await readJSON(request);
  assertExactKeys(body, ["deviceID", "lifetimeSeconds"]);
  const deviceID = identifier(body.deviceID, "deviceID");
  const lifetimeSeconds = body.lifetimeSeconds === undefined
    ? deviceCredentialLifetimeSeconds
    : boundedDeviceCredentialLifetime(body.lifetimeSeconds);
  const now = Math.floor(Date.now() / 1000);
  const active = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM rendezvous_credentials "
      + "WHERE host_id = ? AND kind = 'device' AND revoked_at IS NULL AND expires_at > ? "
      + "AND device_id != ?",
  ).bind(hostID, now, deviceID).first<{ count: number }>();
  if ((active?.count ?? 0) >= maximumDevicesPerHost) {
    throw new HttpError(429, "deviceLimit", "Host has too many active devices");
  }
  const token = randomToken("th_device_");
  const expiresAt = now + lifetimeSeconds;
  try {
    await env.DB.batch([
      env.DB.prepare(
        "UPDATE rendezvous_credentials SET revoked_at = ? "
          + "WHERE host_id = ? AND device_id = ? AND kind = 'device' AND revoked_at IS NULL",
      ).bind(now, hostID, deviceID),
      env.DB.prepare(
        "INSERT INTO rendezvous_credentials "
          + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
          + "VALUES (?, 'device', ?, ?, ?, ?, ?)",
      ).bind(await sha256Hex(token), accountID, hostID, deviceID, expiresAt, now),
    ]);
  } catch (error) {
    if (String(error).includes("threading_device_limit")) {
      throw new HttpError(429, "deviceLimit", "Host has too many active devices");
    }
    throw error;
  }
  await disconnectDevice(hostID, deviceID, env);
  return json({ hostID, deviceID, credential: token, expiresAt: expiresAt * 1000 }, 201);
}

export async function revokeDeviceCredential(
  request: Request,
  env: Env,
  hostID: string,
  deviceID: string,
): Promise<Response> {
  if (!validateIdentifier(hostID) || !validateIdentifier(deviceID)) {
    throw new HttpError(400, "invalidRequest", "Host or device ID is invalid");
  }
  await authorizeHostMutation(request, env, hostID);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE rendezvous_credentials SET revoked_at = ? "
        + "WHERE host_id = ? AND device_id = ? AND kind = 'device' AND revoked_at IS NULL",
    ).bind(now, hostID, deviceID),
    env.DB.prepare(
      "UPDATE push_registrations SET revoked_at = ?, updated_at = ? "
        + "WHERE host_id = ? AND device_id = ? AND revoked_at IS NULL",
    ).bind(now, now, hostID, deviceID),
  ]);
  await disconnectDevice(hostID, deviceID, env);
  return new Response(null, { status: 204 });
}

async function disconnectDevice(hostID: string, deviceID: string, env: Env): Promise<void> {
  await env.HOST_RENDEZVOUS.getByName(hostID).fetch("https://internal/disconnect-device", {
    method: "POST",
    headers: {
      "X-Threading-Internal-Action": "disconnect-device",
      "X-Threading-Device-ID": deviceID,
    },
  });
}

export async function revokeHost(
  request: Request,
  env: Env,
  hostID: string,
): Promise<Response> {
  if (!validateIdentifier(hostID)) throw new HttpError(400, "invalidHost", "Host ID is invalid");
  await authorizeHostRevocation(request, env, hostID);
  const now = Math.floor(Date.now() / 1000);
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE hosts SET revoked_at = ?, updated_at = ? WHERE id = ? AND revoked_at IS NULL",
    ).bind(now, now, hostID),
    env.DB.prepare(
      "UPDATE rendezvous_credentials SET revoked_at = ? "
        + "WHERE host_id = ? AND revoked_at IS NULL",
    ).bind(now, hostID),
    env.DB.prepare(
      "UPDATE push_registrations SET revoked_at = ?, updated_at = ? "
        + "WHERE host_id = ? AND revoked_at IS NULL",
    ).bind(now, now, hostID),
  ]);
  await env.HOST_RENDEZVOUS.getByName(hostID).fetch("https://internal/disconnect-host", {
    method: "POST",
    headers: { "X-Threading-Internal-Action": "disconnect-host" },
  });
  return new Response(null, { status: 204 });
}

export async function authorizeRendezvousCredential(
  token: string,
  expectedKind: "host" | "device",
  env: Env,
): Promise<RendezvousPrincipal> {
  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare(
    "SELECT c.kind, c.account_id, c.host_id, c.device_id, c.expires_at "
      + "FROM rendezvous_credentials c JOIN hosts h ON h.id = c.host_id "
      + "WHERE c.digest = ? AND c.kind = ? AND c.revoked_at IS NULL "
      + "AND c.expires_at > ? AND h.revoked_at IS NULL",
  ).bind(await sha256Hex(token), expectedKind, now).first<CredentialRow>();
  if (!row) throw new HttpError(401, "unauthorized", "Rendezvous credential is invalid or expired");
  if (row.kind === "host") {
    return {
      kind: "host",
      accountID: row.account_id,
      hostID: row.host_id,
      credentialExpiresAt: row.expires_at * 1000,
    };
  }
  if (!row.device_id) throw new HttpError(401, "unauthorized", "Device credential is invalid");
  return {
    kind: "device",
    accountID: row.account_id,
    hostID: row.host_id,
    deviceID: row.device_id,
    credentialExpiresAt: row.expires_at * 1000,
  };
}

async function rotateHostCredential(
  hostID: string,
  accountID: string,
  env: Env,
  now: number,
): Promise<Response> {
  const token = randomToken("th_host_");
  const expiresAt = now + (
    env.DEVELOPMENT_AUTH_MODE === "1" ? 24 * 60 * 60 : hostCredentialLifetimeSeconds
  );
  await env.DB.batch([
    env.DB.prepare(
      "UPDATE rendezvous_credentials SET revoked_at = ? "
        + "WHERE host_id = ? AND kind = 'host' AND revoked_at IS NULL",
    ).bind(now, hostID),
    env.DB.prepare(
      "INSERT INTO rendezvous_credentials "
        + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
        + "VALUES (?, 'host', ?, ?, NULL, ?, ?)",
    ).bind(await sha256Hex(token), accountID, hostID, expiresAt, now),
  ]);
  await env.HOST_RENDEZVOUS.getByName(hostID).fetch("https://internal/disconnect-host", {
    method: "POST",
    headers: { "X-Threading-Internal-Action": "disconnect-host" },
  });
  return json({ hostID, credential: token, expiresAt: expiresAt * 1000 }, 201);
}

async function authorizeHostMutation(request: Request, env: Env, hostID: string): Promise<string> {
  const token = bearerToken(request);
  if (token.startsWith("th_host_")) {
    const principal = await authorizeRendezvousCredential(token, "host", env);
    if (principal.kind !== "host" || principal.hostID !== hostID) {
      throw new HttpError(403, "forbidden", "Host credential does not match");
    }
    return principal.accountID;
  }
  const principal = await authenticateAccess(request, env);
  await requireHostOwner(hostID, principal.accountID, env);
  return principal.accountID;
}

async function authorizeHostRevocation(request: Request, env: Env, hostID: string): Promise<void> {
  const token = bearerToken(request);
  if (token.startsWith("th_host_")) {
    try {
      const principal = await authorizeRendezvousCredential(token, "host", env);
      if (principal.kind !== "host" || principal.hostID !== hostID) {
        throw new HttpError(403, "forbidden", "Host credential does not match");
      }
      return;
    } catch (error) {
      const revoked = await env.DB.prepare(
        "SELECT 1 AS found FROM rendezvous_credentials c JOIN hosts h ON h.id = c.host_id "
          + "WHERE c.digest = ? AND c.kind = 'host' AND c.host_id = ? "
          + "AND c.revoked_at IS NOT NULL AND h.revoked_at IS NOT NULL",
      ).bind(await sha256Hex(token), hostID).first<{ found: number }>();
      if (revoked) return;
      throw error;
    }
  }
  const principal = await authenticateAccess(request, env);
  const owned = await env.DB.prepare(
    "SELECT 1 AS found FROM hosts WHERE id = ? AND account_id = ?",
  ).bind(hostID, principal.accountID).first<{ found: number }>();
  if (!owned) throw new HttpError(404, "hostNotFound", "Host was not found");
}

async function requireHostOwner(hostID: string, accountID: string, env: Env): Promise<void> {
  const row = await env.DB.prepare(
    "SELECT 1 AS found FROM hosts WHERE id = ? AND account_id = ? AND revoked_at IS NULL",
  ).bind(hostID, accountID).first<{ found: number }>();
  if (!row) throw new HttpError(404, "hostNotFound", "Host was not found");
}

async function updateOwnedHost(
  hostID: string,
  accountID: string,
  displayName: string,
  now: number,
  env: Env,
): Promise<boolean> {
  const result = await env.DB.prepare(
    "UPDATE hosts SET display_name = ?, updated_at = ?, revoked_at = NULL "
      + "WHERE id = ? AND account_id = ? AND (revoked_at IS NULL OR "
      + "(SELECT COUNT(*) FROM hosts WHERE account_id = ? AND revoked_at IS NULL) < ?)",
  ).bind(displayName, now, hostID, accountID, accountID, maximumHostsPerAccount).run();
  return result.meta.changes === 1;
}

function identifier(value: unknown, field: string): string {
  if (!validateIdentifier(value)) throw new HttpError(400, "invalidRequest", `${field} is invalid`);
  return value;
}

function boundedDeviceCredentialLifetime(value: unknown): number {
  if (!Number.isInteger(value)
    || (value as number) < minimumDeviceCredentialLifetimeSeconds
    || (value as number) > deviceCredentialLifetimeSeconds) {
    throw new HttpError(400, "invalidRequest", "lifetimeSeconds is invalid");
  }
  return value as number;
}

function boundedDisplayName(value: unknown): string {
  if (typeof value !== "string") throw new HttpError(400, "invalidRequest", "displayName is invalid");
  const normalized = value.trim();
  if (normalized.length === 0 || new TextEncoder().encode(normalized).byteLength > 128) {
    throw new HttpError(400, "invalidRequest", "displayName is invalid");
  }
  return normalized;
}
