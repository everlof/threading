import { env } from "cloudflare:workers";
import { exportJWK, SignJWT, type JWK } from "jose";
import { beforeAll, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import { sha256Hex } from "../src/crypto";
import worker from "../src/index";

const baseEnv = env as unknown as Env;
const issuer = "https://threading-tests.cloudflareaccess.com";
const audience = "threading-development-access-test";
const allowedEmail = "developer@example.test";
const keyID = "test-access-key";
let privateKey: CryptoKey;
let publicJWK: JWK;

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  privateKey = pair.privateKey;
  publicJWK = { ...await exportJWK(pair.publicKey), kid: keyID, alg: "RS256", use: "sig" };
});

describe("development browser authentication", () => {
  it("requires a signed allowlisted Access identity and redeems a host-bound challenge once", async () => {
    const configured = developmentEnv();
    const hostID = `host-${crypto.randomUUID()}`;
    const verifier = verifierValue();
    const started = await start(hostID, verifier, configured);
    const upstream = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      keys: [publicJWK],
    }));
    const assertion = await accessAssertion(allowedEmail);
    const authorized = await worker.fetch(new Request(started.authorizationURL, {
      headers: { "Cf-Access-Jwt-Assertion": assertion },
    }), configured);

    expect(authorized.status).toBe(200);
    expect(authorized.headers.get("Cache-Control")).toBe("no-store");
    expect(authorized.headers.get("Content-Security-Policy")).toContain("frame-ancestors 'none'");
    expect(upstream).toHaveBeenCalledOnce();

    const redeemed = await redeem(started, hostID, verifier, configured);
    expect(redeemed.response.status).toBe(200);
    expect(redeemed.body).toMatchObject({
      accountID: expect.stringMatching(/^acct_dev_[0-9a-f]{40}$/u),
      accessToken: expect.any(String),
      refreshToken: expect.stringMatching(/^th_refresh_/u),
    });
    expect((redeemed.body.refreshTokenExpiresAt as number) - Date.now())
      .toBeLessThanOrEqual(24 * 60 * 60 * 1000 + 1_000);

    const repeated = await redeem(started, hostID, verifier, configured);
    expect(repeated.response.status).toBe(409);
    expect(repeated.body).toMatchObject({ error: { code: "developmentAuthPending" } });
    vi.restoreAllMocks();
  });

  it("does not trust an asserted email without a cryptographically valid Access JWT", async () => {
    const configured = developmentEnv();
    const hostID = `host-${crypto.randomUUID()}`;
    const verifier = verifierValue();
    const started = await start(hostID, verifier, configured);

    const response = await worker.fetch(new Request(started.authorizationURL, {
      headers: { "Cf-Access-Authenticated-User-Email": allowedEmail },
    }), configured);

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "developmentAccessRequired" },
    });
  });

  it("rejects a valid Access identity that is not on the Worker allowlist", async () => {
    const configured = developmentEnv();
    const hostID = `host-${crypto.randomUUID()}`;
    const verifier = verifierValue();
    const started = await start(hostID, verifier, configured);
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({ keys: [publicJWK] }));

    const response = await worker.fetch(new Request(started.authorizationURL, {
      headers: {
        "Cf-Access-Jwt-Assertion": await accessAssertion("intruder@example.test"),
      },
    }), configured);

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "developmentAccessDenied" },
    });
    vi.restoreAllMocks();
  });

  it("keeps the development routes absent from production and loopback modes", async () => {
    const body = JSON.stringify({
      hostID: `host-${crypto.randomUUID()}`,
      codeChallenge: "a".repeat(64),
    });
    const production = await worker.fetch(new Request(
      "https://service.test/v1/auth/development/start",
      { method: "POST", headers: { "Content-Type": "application/json" }, body },
    ), baseEnv);
    const loopback = await worker.fetch(new Request(
      "http://127.0.0.1/v1/auth/development/start",
      { method: "POST", headers: { "Content-Type": "application/json" }, body },
    ), developmentEnv({ LOCAL_DEVELOPMENT_MODE: "1" }));

    expect(production.status).toBe(404);
    expect(loopback.status).toBe(404);
  });

  it("removes production-only Apple and report routes from the operated development Worker", async () => {
    const configured = developmentEnv();
    for (const path of ["/v1/auth/apple", "/v1/auth/apple/events", "/v1/reports"]) {
      const response = await worker.fetch(new Request(`https://service.test${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      }), configured);
      expect(response.status, path).toBe(404);
    }
    const pickup = await worker.fetch(new Request(
      "https://service.test/v1/developer/reports",
    ), configured);
    expect(pickup.status).toBe(404);
  });
});

function developmentEnv(overrides: Partial<Env> = {}): Env {
  const values: Partial<Env> = {
    DEVELOPMENT_AUTH_MODE: "1",
    DEVELOPMENT_ACCESS_ISSUER: issuer,
    DEVELOPMENT_ACCESS_AUDIENCE: audience,
    DEVELOPMENT_ACCESS_EMAILS: allowedEmail,
    ...overrides,
  };
  return new Proxy(baseEnv, {
    get(target, property, receiver) {
      return Object.prototype.hasOwnProperty.call(values, property)
        ? values[property as keyof Env]
        : Reflect.get(target, property, receiver);
    },
  });
}

async function start(hostID: string, verifier: string, configured: Env): Promise<{
  transactionID: string;
  pollToken: string;
  authorizationURL: string;
}> {
  const response = await worker.fetch(new Request(
    "https://dev.remote.threading.codes/v1/auth/development/start",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ hostID, codeChallenge: await sha256Hex(verifier) }),
    },
  ), configured);
  expect(response.status).toBe(201);
  return response.json();
}

async function redeem(
  transaction: { transactionID: string; pollToken: string },
  hostID: string,
  codeVerifier: string,
  configured: Env,
): Promise<{ response: Response; body: Record<string, unknown> }> {
  const response = await worker.fetch(new Request(
    "https://dev.remote.threading.codes/v1/auth/development/redeem",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        transactionID: transaction.transactionID,
        pollToken: transaction.pollToken,
        hostID,
        codeVerifier,
      }),
    },
  ), configured);
  return { response, body: await response.json<Record<string, unknown>>() };
}

async function accessAssertion(email: string): Promise<string> {
  return new SignJWT({ email })
    .setProtectedHeader({ alg: "RS256", kid: keyID })
    .setIssuer(issuer)
    .setAudience(audience)
    .setSubject(`identity:${email}`)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(privateKey);
}

function verifierValue(): string {
  return `${crypto.randomUUID().replaceAll("-", "")}${crypto.randomUUID().replaceAll("-", "")}`;
}
