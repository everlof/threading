import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import worker from "../src/index";

const testEnv = env as unknown as Env;
let testApplePrivateKey = "";

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const exported = await crypto.subtle.exportKey("pkcs8", pair.privateKey) as ArrayBuffer;
  const bytes = new Uint8Array(exported);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).match(/.{1,64}/gu)?.join("\n") ?? "";
  testApplePrivateKey = `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----`;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("service release surfaces", () => {
  it("keeps liveness cheap and hardened without claiming dependency readiness", async () => {
    const response = await worker.fetch(new Request("https://service.test/health"), testEnv);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ok", rendezvousProtocol: 1 });
    expect(response.headers.get("Cache-Control")).toBe("no-store");
    expect(response.headers.get("Content-Security-Policy")).toBe("default-src 'none'");
    expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
  });

  it("reports only a generic unavailable state when production bindings are incomplete", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    const response = await worker.fetch(new Request("https://service.test/ready"), testEnv);

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ status: "unavailable" });
    expect(warning).toHaveBeenCalledWith("readiness_failed", {
      reason: "serviceConfiguration",
    });
  });

  it("proves local cryptographic configuration and D1 before reporting ready", async () => {
    const configured = Object.assign(Object.create(testEnv) as Env, {
      APPLE_TEAM_ID: "TESTTEAM01",
      APPLE_KEY_ID: "TESTKEY001",
      APPLE_PRIVATE_KEY: testApplePrivateKey,
      APPLE_TOKEN_ENCRYPTION_SECRET: "independent-test-encryption-secret-at-least-32-bytes",
      TURN_KEY_ID: "test-turn-key",
      TURN_KEY_API_TOKEN: "test-turn-token",
    });

    const response = await worker.fetch(new Request("https://service.test/ready"), configured);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ready", rendezvousProtocol: 1 });
  });

  it("refuses to report ready when signing and stored-token secrets are reused", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const reused = Object.assign(Object.create(testEnv) as Env, {
      APPLE_TOKEN_ENCRYPTION_SECRET: testEnv.SESSION_SIGNING_SECRET,
    });

    const response = await worker.fetch(new Request("https://service.test/ready"), reused);

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ status: "unavailable" });
  });

  it("refuses readiness when the required D1 schema probe fails", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const configured = Object.assign(Object.create(testEnv) as Env, {
      APPLE_TEAM_ID: "TESTTEAM01",
      APPLE_KEY_ID: "TESTKEY001",
      APPLE_PRIVATE_KEY: testApplePrivateKey,
      APPLE_TOKEN_ENCRYPTION_SECRET: "independent-schema-test-secret-at-least-32-bytes",
      TURN_KEY_ID: "test-turn-key",
      TURN_KEY_API_TOKEN: "test-turn-token",
    });
    const missingSchema = new Proxy(configured, {
      get(target, property, receiver) {
        if (property === "DB") {
          return {
            batch: async () => { throw new Error("missing migration"); },
          } as unknown as D1Database;
        }
        return Reflect.get(target, property, receiver);
      },
    });

    const response = await worker.fetch(new Request("https://service.test/ready"), missingSchema);

    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ status: "unavailable" });
  });

  it("executes the daily bounded expiry cleanup through the scheduled entry point", async () => {
    const now = Math.floor(Date.now() / 1000);
    const suffix = crypto.randomUUID();
    const accountID = `acct-${suffix}`;
    const hostID = `host-${suffix}`;
    const assertion = `assertion-${suffix}`;
    const notification = `notification-${suffix}`;
    const rendezvous = `rendezvous-${suffix}`;
    const refresh = `refresh-${suffix}`;
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(accountID, now, now),
      testEnv.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(hostID, accountID, "Cleanup Mac", now, now),
      testEnv.DB.prepare(
        "INSERT INTO apple_assertions (digest, account_id, expires_at, created_at) "
          + "VALUES (?, ?, ?, ?)",
      ).bind(assertion, accountID, now - 1, now - 10),
      testEnv.DB.prepare(
        "INSERT INTO apple_notifications (jti_digest, expires_at, created_at) VALUES (?, ?, ?)",
      ).bind(notification, now - 1, now - 10),
      testEnv.DB.prepare(
        "INSERT INTO rendezvous_credentials "
          + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
          + "VALUES (?, 'host', ?, ?, NULL, ?, ?)",
      ).bind(rendezvous, accountID, hostID, now - 1, now - 10),
      testEnv.DB.prepare(
        "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) "
          + "VALUES (?, ?, ?, ?)",
      ).bind(refresh, accountID, now - 1, now - 10),
    ]);

    await worker.scheduled({ cron: "17 3 * * *" } as ScheduledController, testEnv);

    await expect(rowExists("apple_assertions", "digest", assertion)).resolves.toBe(false);
    await expect(rowExists("apple_notifications", "jti_digest", notification)).resolves.toBe(false);
    await expect(rowExists("rendezvous_credentials", "digest", rendezvous)).resolves.toBe(false);
    await expect(rowExists("refresh_sessions", "digest", refresh)).resolves.toBe(false);
  });
});

async function rowExists(table: string, column: string, value: string): Promise<boolean> {
  const row = await testEnv.DB.prepare(`SELECT 1 AS found FROM ${table} WHERE ${column} = ?`)
    .bind(value).first<{ found: number }>();
  return row?.found === 1;
}
