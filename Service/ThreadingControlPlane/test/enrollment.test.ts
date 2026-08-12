import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { accountIDForAppleSubject, sha256Hex, signAccessToken } from "../src/crypto";
import { processAppleAccountEvent } from "../src/auth";
import { authorizeRendezvousCredential } from "../src/enrollment";
import { parseEnvelope, type Envelope } from "../src/protocol";
import worker from "../src/index";

const testEnv = env as unknown as Env;
const accountID = "acct_test-account";

describe("host and device enrollment", () => {
  beforeEach(async () => {
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
        + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at",
    ).bind(accountID, now, now).run();
  });

  it("issues separately scoped host/device credentials and revokes the device", async () => {
    const access = await signAccessToken(accountID, testEnv);
    const hostID = `host-${crypto.randomUUID()}`;
    const deviceID = `device-${crypto.randomUUID()}`;
    const enrolled = await fetchJSON("/v1/hosts", access, {
      hostID,
      displayName: "Test Mac",
    });
    expect(enrolled.response.status).toBe(201);
    const hostCredential = requiredString(enrolled.body.credential);
    expect(hostCredential).toMatch(/^th_host_/u);

    const device = await fetchJSON(`/v1/hosts/${hostID}/devices`, hostCredential, { deviceID });
    expect(device.response.status).toBe(201);
    const deviceCredential = requiredString(device.body.credential);
    expect(deviceCredential).toMatch(/^th_device_/u);
    await expect(authorizeRendezvousCredential(hostCredential, "host", testEnv))
      .resolves.toMatchObject({ kind: "host", accountID, hostID });
    await expect(authorizeRendezvousCredential(deviceCredential, "device", testEnv))
      .resolves.toMatchObject({ kind: "device", accountID, hostID, deviceID });

    const upgrade = await worker.fetch(new Request("https://service.test/v1/rendezvous/device", {
      headers: {
        Authorization: `Bearer ${deviceCredential}`,
        Upgrade: "websocket",
        "X-Threading-Rendezvous-Version": "1",
      },
    }), testEnv);
    if (!upgrade.webSocket) throw new Error("Expected device WebSocket");
    upgrade.webSocket.accept();
    const disconnected = nextEnvelope(upgrade.webSocket);

    const revoked = await worker.fetch(new Request(
      `https://service.test/v1/hosts/${hostID}/devices/${deviceID}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${hostCredential}` } },
    ), testEnv);
    expect(revoked.status).toBe(204);
    await expect(disconnected).resolves.toMatchObject({
      kind: "failure",
      errorCode: "credentialRevoked",
    });
    await expect(authorizeRendezvousCredential(deviceCredential, "device", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
  });

  it("bounds temporary device credential lifetimes", async () => {
    const access = await signAccessToken(accountID, testEnv);
    const hostID = `host-${crypto.randomUUID()}`;
    const enrolled = await fetchJSON("/v1/hosts", access, {
      hostID,
      displayName: "Pairing Mac",
    });
    const hostCredential = requiredString(enrolled.body.credential);
    const before = Date.now();
    const temporary = await fetchJSON(`/v1/hosts/${hostID}/devices`, hostCredential, {
      deviceID: `pairing-${crypto.randomUUID()}`,
      lifetimeSeconds: 300,
    });
    expect(temporary.response.status).toBe(201);
    expect(temporary.body.expiresAt).toEqual(expect.any(Number));
    expect(temporary.body.expiresAt as number).toBeGreaterThanOrEqual(before + 299_000);
    expect(temporary.body.expiresAt as number).toBeLessThanOrEqual(Date.now() + 301_000);

    for (const invalidLifetime of [59, 30 * 24 * 60 * 60 + 1, 300.5, "300"]) {
      const rejected = await fetchJSON(`/v1/hosts/${hostID}/devices`, hostCredential, {
        deviceID: `pairing-${crypto.randomUUID()}`,
        lifetimeSeconds: invalidLifetime,
      });
      expect(rejected.response.status).toBe(400);
      expect(rejected.body).toMatchObject({ error: { code: "invalidRequest" } });
    }
  });

  it("keeps host and device quotas intact under concurrent last-slot requests", async () => {
    const quotaAccountID = `acct-${crypto.randomUUID()}`;
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
    ).bind(quotaAccountID, now, now).run();
    await testEnv.DB.batch(Array.from({ length: 15 }, (_, index) => testEnv.DB.prepare(
      "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
        + "VALUES (?, ?, ?, ?, ?)",
    ).bind(`host-${crypto.randomUUID()}`, quotaAccountID, `Mac ${index}`, now, now)));

    const access = await signAccessToken(quotaAccountID, testEnv);
    const hostAttempts = await Promise.all(Array.from({ length: 2 }, () => fetchJSON(
      "/v1/hosts",
      access,
      { hostID: `host-${crypto.randomUUID()}`, displayName: "Last Mac" },
    )));
    expect(hostAttempts.map((attempt) => attempt.response.status).sort()).toEqual([201, 429]);
    const hostCount = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM hosts WHERE account_id = ? AND revoked_at IS NULL",
    ).bind(quotaAccountID).first<{ count: number }>();
    expect(hostCount?.count).toBe(16);

    const revokedHostID = `host-${crypto.randomUUID()}`;
    await testEnv.DB.prepare(
      "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at, revoked_at) "
        + "VALUES (?, ?, ?, ?, ?, ?)",
    ).bind(revokedHostID, quotaAccountID, "Retired Mac", now, now, now).run();
    const revived = await fetchJSON("/v1/hosts", access, {
      hostID: revokedHostID,
      displayName: "Revived Mac",
    });
    expect(revived.response.status).toBe(429);
    const stillActive = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM hosts WHERE account_id = ? AND revoked_at IS NULL",
    ).bind(quotaAccountID).first<{ count: number }>();
    expect(stillActive?.count).toBe(16);

    const successfulHost = hostAttempts.find((attempt) => attempt.response.status === 201);
    const hostID = requiredString(successfulHost?.body.hostID);
    const hostCredential = requiredString(successfulHost?.body.credential);
    const seededDeviceIDs = Array.from({ length: 63 }, () => `device-${crypto.randomUUID()}`);
    await testEnv.DB.batch(seededDeviceIDs.map((deviceID) => testEnv.DB.prepare(
      "INSERT INTO rendezvous_credentials "
        + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
        + "VALUES (?, 'device', ?, ?, ?, ?, ?)",
    ).bind(
      `digest-${crypto.randomUUID()}`,
      quotaAccountID,
      hostID,
      deviceID,
      now + 3600,
      now,
    )));

    const finalDeviceIDs = Array.from({ length: 2 }, () => `device-${crypto.randomUUID()}`);
    const deviceAttempts = await Promise.all(finalDeviceIDs.map((deviceID) => fetchJSON(
      `/v1/hosts/${hostID}/devices`,
      hostCredential,
      { deviceID },
    )));
    expect(deviceAttempts.map((attempt) => attempt.response.status).sort()).toEqual([201, 429]);
    const deviceCount = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM rendezvous_credentials "
        + "WHERE host_id = ? AND kind = 'device' AND revoked_at IS NULL AND expires_at > ?",
    ).bind(hostID, now).first<{ count: number }>();
    expect(deviceCount?.count).toBe(64);

    const successfulDevice = deviceAttempts.find((attempt) => attempt.response.status === 201);
    const deviceID = requiredString(successfulDevice?.body.deviceID);
    const oldCredential = requiredString(successfulDevice?.body.credential);
    const rotated = await fetchJSON(
      `/v1/hosts/${hostID}/devices`,
      hostCredential,
      { deviceID },
    );
    expect(rotated.response.status).toBe(201);
    await expect(authorizeRendezvousCredential(oldCredential, "device", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
    await expect(authorizeRendezvousCredential(
      requiredString(rotated.body.credential),
      "device",
      testEnv,
    )).resolves.toMatchObject({ hostID, deviceID });
  });

  it("rejects unknown enrollment fields before storing a host", async () => {
    const access = await signAccessToken(accountID, testEnv);
    const result = await fetchJSON("/v1/hosts", access, {
      hostID: `host-${crypto.randomUUID()}`,
      displayName: "Test Mac",
      accidentalSecret: "must-not-be-accepted",
    });
    expect(result.response.status).toBe(400);
    expect(result.body).toMatchObject({ error: { code: "invalidRequest" } });
  });

  it("revokes a host and all of its device credentials", async () => {
    const access = await signAccessToken(accountID, testEnv);
    const hostID = `host-${crypto.randomUUID()}`;
    const deviceID = `device-${crypto.randomUUID()}`;
    const enrolled = await fetchJSON("/v1/hosts", access, { hostID, displayName: "Test Mac" });
    const hostCredential = requiredString(enrolled.body.credential);
    const device = await fetchJSON(`/v1/hosts/${hostID}/devices`, hostCredential, { deviceID });
    const deviceCredential = requiredString(device.body.credential);

    const revoked = await worker.fetch(new Request(`https://service.test/v1/hosts/${hostID}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${access}` },
    }), testEnv);
    expect(revoked.status).toBe(204);
    const retriedWithAccess = await worker.fetch(new Request(
      `https://service.test/v1/hosts/${hostID}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${access}` } },
    ), testEnv);
    expect(retriedWithAccess.status).toBe(204);
    const retriedWithOldHostCredential = await worker.fetch(new Request(
      `https://service.test/v1/hosts/${hostID}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${hostCredential}` } },
    ), testEnv);
    expect(retriedWithOldHostCredential.status).toBe(204);
    await expect(authorizeRendezvousCredential(hostCredential, "host", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
    await expect(authorizeRendezvousCredential(deviceCredential, "device", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
  });

  it("signs out one refresh session idempotently", async () => {
    const refreshToken = `th_refresh_${crypto.randomUUID()}`;
    const digest = await sha256Hex(refreshToken);
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) VALUES (?, ?, ?, ?)",
    ).bind(digest, accountID, now + 3600, now).run();

    for (const _attempt of [1, 2]) {
      const response = await worker.fetch(new Request("https://service.test/v1/auth/signout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken }),
      }), testEnv);
      expect(response.status).toBe(204);
    }
    const row = await testEnv.DB.prepare(
      "SELECT revoked_at FROM refresh_sessions WHERE digest = ?",
    ).bind(digest).first<{ revoked_at: number | null }>();
    expect(row?.revoked_at).not.toBeNull();
  });

  it("returns one encrypted replacement when concurrent refresh responses are retried", async () => {
    const refreshAccountID = `acct-${crypto.randomUUID()}`;
    const oldRefreshToken = `th_refresh_${crypto.randomUUID()}`;
    const oldDigest = await sha256Hex(oldRefreshToken);
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(refreshAccountID, now, now),
      testEnv.DB.prepare(
        "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) "
          + "VALUES (?, ?, ?, ?)",
      ).bind(oldDigest, refreshAccountID, now + 3600, now),
    ]);

    const attempts = await Promise.all([
      refreshRequest(oldRefreshToken),
      refreshRequest(oldRefreshToken),
    ]);
    expect(attempts.map((attempt) => attempt.response.status)).toEqual([200, 200]);
    const replacements = attempts.map((attempt) => requiredString(attempt.body.refreshToken));
    expect(new Set(replacements).size).toBe(1);
    const replacement = replacements[0] as string;
    const rows = await testEnv.DB.prepare(
      "SELECT consumed_at, replacement_encrypted_token FROM refresh_sessions "
        + "WHERE account_id = ? ORDER BY created_at, digest",
    ).bind(refreshAccountID).all<{
      consumed_at: number | null;
      replacement_encrypted_token: string | null;
    }>();
    expect(rows.results).toHaveLength(2);
    expect(rows.results.filter((row) => row.consumed_at === null)).toHaveLength(1);
    expect(rows.results.find((row) => row.replacement_encrypted_token)?.replacement_encrypted_token)
      .not.toContain(replacement);

    const signedOut = await worker.fetch(new Request("https://service.test/v1/auth/signout", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: oldRefreshToken }),
    }), testEnv);
    expect(signedOut.status).toBe(204);
    expect((await refreshRequest(oldRefreshToken)).response.status).toBe(401);
    expect((await refreshRequest(replacement)).response.status).toBe(401);
  });

  it("rate limits repeated Apple sign-in attempts before authentication work", async () => {
    const source = `198.51.100.${Math.floor(Math.random() * 200) + 1}`;
    let response: Response | undefined;
    for (let attempt = 0; attempt < 31; attempt += 1) {
      response = await worker.fetch(new Request("https://service.test/v1/auth/apple", {
        method: "POST",
        headers: {
          "CF-Connecting-IP": source,
          "Content-Type": "application/json",
        },
        body: "{}",
      }), testEnv);
      if (attempt < 30) expect(response.status).toBe(400);
    }
    if (!response) throw new Error("Expected a rate-limit response");
    expect(response.status).toBe(429);
    await expect(response.json()).resolves.toMatchObject({ error: { code: "rateLimited" } });
  });

  it("deletes a legacy account and every hosted credential", async () => {
    const access = await signAccessToken(accountID, testEnv);
    const hostID = `host-${crypto.randomUUID()}`;
    const deviceID = `device-${crypto.randomUUID()}`;
    const enrolled = await fetchJSON("/v1/hosts", access, { hostID, displayName: "Delete Mac" });
    const hostCredential = requiredString(enrolled.body.credential);
    const device = await fetchJSON(`/v1/hosts/${hostID}/devices`, hostCredential, { deviceID });
    const deviceCredential = requiredString(device.body.credential);

    const deleted = await worker.fetch(new Request("https://service.test/v1/account", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${access}` },
    }), testEnv);
    expect(deleted.status).toBe(204);
    expect(await testEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(accountID).first()).toBeNull();
    const retriedDelete = await worker.fetch(new Request("https://service.test/v1/account", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${access}` },
    }), testEnv);
    expect(retriedDelete.status).toBe(204);
    await expect(authorizeRendezvousCredential(hostCredential, "host", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
    await expect(authorizeRendezvousCredential(deviceCredential, "device", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });

    const staleAccess = await fetchJSON("/v1/hosts", access, {
      hostID: `host-${crypto.randomUUID()}`,
      displayName: "Must fail",
    });
    expect(staleAccess.response.status).toBe(401);
  });

  it("does not let a corrupt over-limit host set block account deletion", async () => {
    const retainedAccountID = `acct-${crypto.randomUUID()}`;
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
    ).bind(retainedAccountID, now, now).run();
    for (let index = 0; index < 65; index += 1) {
      await testEnv.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at, revoked_at) "
          + "VALUES (?, ?, ?, ?, ?, ?)",
      ).bind(
        `host-${crypto.randomUUID()}`,
        retainedAccountID,
        `Retired Mac ${index}`,
        now,
        now,
        now,
      ).run();
    }

    const access = await signAccessToken(retainedAccountID, testEnv);
    const response = await worker.fetch(new Request("https://service.test/v1/account", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${access}` },
    }), testEnv);

    expect(response.status).toBe(204);
    expect(await testEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(retainedAccountID).first()).toBeNull();
  });

  it("removes account data when Apple reports revoked consent", async () => {
    const subject = `apple-subject-${crypto.randomUUID()}`;
    const notifiedAccountID = await accountIDForAppleSubject(subject);
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
    ).bind(notifiedAccountID, now, now).run();
    const access = await signAccessToken(notifiedAccountID, testEnv);
    const hostID = `host-${crypto.randomUUID()}`;
    const enrolled = await fetchJSON("/v1/hosts", access, { hostID, displayName: "Revoked Mac" });
    const hostCredential = requiredString(enrolled.body.credential);

    await processAppleAccountEvent("consent-revoked", subject, testEnv);

    expect(await testEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(notifiedAccountID).first()).toBeNull();
    await expect(authorizeRendezvousCredential(hostCredential, "host", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
  });
});

async function fetchJSON(
  path: string,
  credential: string,
  body: Record<string, unknown>,
): Promise<{ response: Response; body: Record<string, unknown> }> {
  const response = await worker.fetch(new Request(`https://service.test${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credential}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  }), testEnv);
  return { response, body: await response.json<Record<string, unknown>>() };
}

async function refreshRequest(
  refreshToken: string,
): Promise<{ response: Response; body: Record<string, unknown> }> {
  const response = await worker.fetch(new Request("https://service.test/v1/auth/refresh", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ refreshToken }),
  }), testEnv);
  return { response, body: await response.json<Record<string, unknown>>() };
}

function requiredString(value: unknown): string {
  if (typeof value !== "string") throw new Error("Expected string response field");
  return value;
}

function nextEnvelope(socket: WebSocket): Promise<Envelope> {
  return new Promise((resolve, reject) => {
    socket.addEventListener("message", (event) => {
      try {
        if (typeof event.data === "string" || event.data instanceof ArrayBuffer) {
          resolve(parseEnvelope(event.data));
        } else {
          reject(new Error("Unexpected WebSocket payload"));
        }
      } catch (error) {
        reject(error);
      }
    }, { once: true });
  });
}
