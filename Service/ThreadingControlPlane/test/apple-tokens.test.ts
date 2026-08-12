import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import {
  decryptAppleToken,
  encryptAppleToken,
  validateAppleRefreshToken,
} from "../src/apple-tokens";
import {
  authenticateAccess,
  handleDeleteAccount,
  processAppleAccountEvent,
  validateDueAppleSessions,
} from "../src/auth";
import { accountIDForAppleSubject, signAccessToken } from "../src/crypto";

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

describe("Apple token storage", () => {
  it("round trips an encrypted refresh token without retaining plaintext", async () => {
    const plaintext = "apple_refresh_secret-value";
    const encrypted = await encryptAppleToken(plaintext, testEnv);

    expect(encrypted).not.toContain(plaintext);
    await expect(decryptAppleToken(encrypted, testEnv)).resolves.toBe(plaintext);
  });

  it("rejects modified ciphertext", async () => {
    const encrypted = await encryptAppleToken("apple_refresh_secret-value", testEnv);
    const replacement = encrypted.endsWith("A") ? "B" : "A";

    await expect(decryptAppleToken(encrypted.slice(0, -1) + replacement, testEnv))
      .rejects.toMatchObject({ status: 503, code: "serviceConfiguration" });
  });

  it("classifies Apple's refresh-token responses without exposing the stored token", async () => {
    const configuredEnv = appleConfiguredEnv();
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(Response.json({
      access_token: "short-lived-access-token",
      expires_in: 3600,
      id_token: "signed.identity.token",
      token_type: "Bearer",
    }));
    await expect(validateAppleRefreshToken(
      "apple-refresh-token",
      "codes.threading",
      configuredEnv,
    )).resolves.toEqual({ kind: "valid", identityToken: "signed.identity.token" });
    const request = fetchSpy.mock.calls[0]?.[1];
    expect(String(request?.body)).toContain("grant_type=refresh_token");
    expect(String(request?.body)).toContain("refresh_token=apple-refresh-token");

    fetchSpy.mockResolvedValueOnce(Response.json(
      { error: "invalid_grant" },
      { status: 400 },
    ));
    await expect(validateAppleRefreshToken(
      "revoked-refresh-token",
      "codes.threading",
      configuredEnv,
    )).resolves.toEqual({ kind: "invalidGrant" });
  });

  it("disables local sessions when the account's last Apple grant becomes invalid", async () => {
    const configuredEnv = appleConfiguredEnv();
    const now = Math.floor(Date.now() / 1000);
    const accountID = `acct-${crypto.randomUUID()}`;
    const hostID = `host-${crypto.randomUUID()}`;
    const encrypted = await encryptAppleToken("revoked-refresh-token", configuredEnv);
    await configuredEnv.DB.batch([
      configuredEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(accountID, now, now),
      configuredEnv.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(hostID, accountID, "Invalidated Mac", now, now),
      configuredEnv.DB.prepare(
        "INSERT INTO apple_tokens "
          + "(account_id, client_id, encrypted_refresh_token, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(accountID, "codes.threading", encrypted, now, now),
      configuredEnv.DB.prepare(
        "INSERT INTO rendezvous_credentials "
          + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
          + "VALUES (?, 'host', ?, ?, NULL, ?, ?)",
      ).bind(`digest-${crypto.randomUUID()}`, accountID, hostID, now + 3600, now),
    ]);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json(
      { error: "invalid_grant" },
      { status: 400 },
    ));

    await validateDueAppleSessions(configuredEnv, now);

    const account = await configuredEnv.DB.prepare(
      "SELECT auth_invalidated_at FROM accounts WHERE id = ?",
    ).bind(accountID).first<{ auth_invalidated_at: number | null }>();
    expect(account?.auth_invalidated_at).toBe(now);
    const activeCredentials = await configuredEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM rendezvous_credentials "
        + "WHERE account_id = ? AND revoked_at IS NULL",
    ).bind(accountID).first<{ count: number }>();
    expect(activeCredentials?.count).toBe(0);
    const access = await signAccessToken(accountID, configuredEnv);
    await expect(authenticateAccess(new Request("https://service.test/v1/hosts", {
      headers: { Authorization: `Bearer ${access}` },
    }), configuredEnv)).rejects.toMatchObject({ status: 401, code: "unauthorized" });
  });

  it("deletes local account data even when Apple's revocation endpoint is unavailable", async () => {
    const configuredEnv = appleConfiguredEnv();
    const now = Math.floor(Date.now() / 1000);
    const accountID = `acct-${crypto.randomUUID()}`;
    const encrypted = await encryptAppleToken("apple-refresh-token", configuredEnv);
    await configuredEnv.DB.batch([
      configuredEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(accountID, now, now),
      configuredEnv.DB.prepare(
        "INSERT INTO apple_tokens "
          + "(account_id, client_id, encrypted_refresh_token, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(accountID, "codes.threading", encrypted, now, now),
    ]);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("unavailable", { status: 503 }));
    const access = await signAccessToken(accountID, configuredEnv);

    const response = await handleDeleteAccount(new Request("https://service.test/v1/account", {
      method: "DELETE",
      headers: { Authorization: `Bearer ${access}` },
    }), configuredEnv);

    expect(response.status).toBe(204);
    expect(await configuredEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(accountID).first()).toBeNull();
  });

  it("cascades consent revocation through every local authority row and is retry-safe", async () => {
    const subject = `apple-subject-${crypto.randomUUID()}`;
    const accountID = await accountIDForAppleSubject(subject);
    const hostID = `host-${crypto.randomUUID()}`;
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.batch([
      testEnv.DB.prepare(
        "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
      ).bind(accountID, now, now),
      testEnv.DB.prepare(
        "INSERT INTO hosts (id, account_id, display_name, created_at, updated_at) "
          + "VALUES (?, ?, ?, ?, ?)",
      ).bind(hostID, accountID, "Revoked Mac", now, now),
      testEnv.DB.prepare(
        "INSERT INTO refresh_sessions (digest, account_id, expires_at, created_at) "
          + "VALUES (?, ?, ?, ?)",
      ).bind(`refresh-${crypto.randomUUID()}`, accountID, now + 3600, now),
      testEnv.DB.prepare(
        "INSERT INTO rendezvous_credentials "
          + "(digest, kind, account_id, host_id, device_id, expires_at, created_at) "
          + "VALUES (?, 'host', ?, ?, NULL, ?, ?)",
      ).bind(`credential-${crypto.randomUUID()}`, accountID, hostID, now + 3600, now),
    ]);

    await processAppleAccountEvent("consent-revoked", subject, testEnv);
    await processAppleAccountEvent("consent-revoked", subject, testEnv);

    expect(await testEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(accountID).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT id FROM hosts WHERE account_id = ?")
      .bind(accountID).first()).toBeNull();
    expect(await testEnv.DB.prepare("SELECT digest FROM refresh_sessions WHERE account_id = ?")
      .bind(accountID).first()).toBeNull();
    expect(await testEnv.DB.prepare(
      "SELECT digest FROM rendezvous_credentials WHERE account_id = ?",
    ).bind(accountID).first()).toBeNull();
  });

  it("ignores unrelated Apple events but bounds revocation subjects", async () => {
    const subject = `apple-subject-${crypto.randomUUID()}`;
    const accountID = await accountIDForAppleSubject(subject);
    const now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)",
    ).bind(accountID, now, now).run();

    await processAppleAccountEvent("email-disabled", subject, testEnv);

    expect(await testEnv.DB.prepare("SELECT id FROM accounts WHERE id = ?")
      .bind(accountID).first()).toEqual({ id: accountID });
    await expect(processAppleAccountEvent(
      "account-deleted",
      "s".repeat(1025),
      testEnv,
    )).rejects.toMatchObject({ status: 400, code: "invalidRequest" });
  });
});

function appleConfiguredEnv(): Env {
  return Object.assign(Object.create(testEnv) as Env, {
    APPLE_TEAM_ID: "TESTTEAM01",
    APPLE_KEY_ID: "TESTKEY001",
    APPLE_PRIVATE_KEY: testApplePrivateKey,
  });
}
