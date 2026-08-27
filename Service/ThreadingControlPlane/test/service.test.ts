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
  it("keeps local sign-in absent from the production profile", async () => {
    const response = await worker.fetch(new Request(
      "http://127.0.0.1/v1/auth/local-development",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" },
    ), testEnv);

    expect(response.status).toBe(404);
  });

  it("bootstraps a bounded session only for the explicit loopback local profile", async () => {
    const local = overrideEnv({
      LOCAL_DEVELOPMENT_MODE: "1",
      LOCAL_ICE_MODE: "host-only",
      REPORT_ALERT_WEBHOOK_URL: undefined,
      REPORT_ALERT_WEBHOOK_TOKEN: undefined,
      ISSUE_REPORTS_BUCKET_NAME: "threading-private-issue-reports-local",
    });
    const response = await worker.fetch(new Request(
      "http://127.0.0.1/v1/auth/local-development",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" },
    ), local);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      accountID: "local-development-account",
      accessToken: expect.any(String),
      refreshToken: expect.any(String),
    });

    const nonLoopback = await worker.fetch(new Request(
      "https://service.test/v1/auth/local-development",
      { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" },
    ), local);
    expect(nonLoopback.status).toBe(404);
  });

  it("reports local storage ready without Apple, TURN, APNs, or an alert webhook", async () => {
    const local = overrideEnv({
      LOCAL_DEVELOPMENT_MODE: "1",
      LOCAL_ICE_MODE: "host-only",
      APPLE_TEAM_ID: undefined,
      APPLE_KEY_ID: undefined,
      APPLE_PRIVATE_KEY: undefined,
      TURN_KEY_ID: undefined,
      TURN_KEY_API_TOKEN: undefined,
      REPORT_ALERT_WEBHOOK_URL: undefined,
      REPORT_ALERT_WEBHOOK_TOKEN: undefined,
      ISSUE_REPORTS_BUCKET_NAME: "threading-private-issue-reports-local",
    });

    const response = await worker.fetch(new Request("http://127.0.0.1/ready"), local);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ status: "ready", rendezvousProtocol: 1 });
  });

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
      APNS_TEAM_ID: "TESTTEAM01",
      APNS_KEY_ID: "TESTKEY001",
      APNS_PRIVATE_KEY: testApplePrivateKey,
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
      APNS_TEAM_ID: "TESTTEAM01",
      APNS_KEY_ID: "TESTKEY001",
      APNS_PRIVATE_KEY: testApplePrivateKey,
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
    const oldReportQuotaDay = "2000-01-01";
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
      testEnv.DB.prepare(
        "INSERT INTO issue_report_daily_quota (day, accepted_count) VALUES (?, ?)",
      ).bind(oldReportQuotaDay, 7),
    ]);

    await worker.scheduled({ cron: "17 3 * * *" } as ScheduledController, testEnv);

    await expect(rowExists("apple_assertions", "digest", assertion)).resolves.toBe(false);
    await expect(rowExists("apple_notifications", "jti_digest", notification)).resolves.toBe(false);
    await expect(rowExists("rendezvous_credentials", "digest", rendezvous)).resolves.toBe(false);
    await expect(rowExists("refresh_sessions", "digest", refresh)).resolves.toBe(false);
    await expect(rowExists(
      "issue_report_daily_quota",
      "day",
      oldReportQuotaDay,
    )).resolves.toBe(false);
  });

  it("drains expiry backlogs larger than one D1 cleanup page", async () => {
    const now = Math.floor(Date.now() / 1000);
    const suffix = crypto.randomUUID();
    const accountID = `backlog-account-${suffix}`;
    const hostID = `backlog-host-${suffix}`;
    const prefix = `backlog-${suffix}`;
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(accountID, now, now),
      testEnv.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(hostID, accountID, "Backlog Mac", now, now),
    ]);
    const numbers = "WITH RECURSIVE numbers(value) AS "
      + "(VALUES(1) UNION ALL SELECT value + 1 FROM numbers WHERE value < 1001) ";
    await testEnv.DB.prepare(
      "WITH RECURSIVE numbers(value) AS "
        + "(VALUES(1) UNION ALL SELECT value + 1 FROM numbers WHERE value < 5) "
        + "INSERT INTO accounts (id, created_at, updated_at) "
        + "SELECT ? || '-refresh-account-' || value, ?, ? FROM numbers",
    ).bind(prefix, now, now).run();
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        numbers
          + "INSERT INTO apple_assertions (digest, account_id, expires_at, created_at) "
          + "SELECT ? || '-assertion-' || value, ?, ?, ? FROM numbers",
      ).bind(prefix, accountID, now - 1, now - 10),
      testEnv.DB.prepare(
        numbers
          + "INSERT INTO apple_notifications (jti_digest, expires_at, created_at) "
          + "SELECT ? || '-notification-' || value, ?, ? FROM numbers",
      ).bind(prefix, now - 1, now - 10),
      testEnv.DB.prepare(
        numbers
          + "INSERT INTO rendezvous_credentials "
          + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
          + "SELECT ? || '-rendezvous-' || value, 'host', ?, ?, NULL, ?, ? FROM numbers",
      ).bind(prefix, accountID, hostID, now - 1, now - 10),
      testEnv.DB.prepare(
        numbers
          + "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at, revoked_at) "
          + "SELECT ? || '-refresh-' || value, "
          + "? || '-refresh-account-' || (((value - 1) % 5) + 1), ?, ?, ? FROM numbers",
      ).bind(prefix, prefix, now - 1, now - 10, now - 1),
    ]);

    await worker.scheduled({ cron: "17 3 * * *" } as ScheduledController, testEnv);

    await expect(rowCountWithPrefix("apple_assertions", "digest", prefix)).resolves.toBe(0);
    await expect(rowCountWithPrefix("apple_notifications", "jti_digest", prefix)).resolves.toBe(0);
    await expect(rowCountWithPrefix("rendezvous_credentials", "digest", prefix)).resolves.toBe(0);
    await expect(rowCountWithPrefix("refresh_sessions", "digest", prefix)).resolves.toBe(0);
  });
});

async function rowExists(table: string, column: string, value: string): Promise<boolean> {
  const row = await testEnv.DB.prepare(`SELECT 1 AS found FROM ${table} WHERE ${column} = ?`)
    .bind(value).first<{ found: number }>();
  return row?.found === 1;
}

async function rowCountWithPrefix(table: string, column: string, prefix: string): Promise<number> {
  const row = await testEnv.DB.prepare(
    `SELECT COUNT(*) AS count FROM ${table} WHERE ${column} LIKE ?`,
  ).bind(`${prefix}%`).first<{ count: number }>();
  return row?.count ?? 0;
}

type EnvOverrides = { [Key in keyof Env]?: Env[Key] | undefined };

function overrideEnv(bindings: EnvOverrides): Env {
  return new Proxy(testEnv, {
    get(target, property, receiver) {
      if (Object.prototype.hasOwnProperty.call(bindings, property)) {
        return Reflect.get(bindings, property);
      }
      return Reflect.get(target, property, receiver);
    },
  });
}
