import { env } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import { signAccessToken } from "../src/crypto";
import worker from "../src/index";

const testEnv = env as unknown as Env;
const accountID = "acct_apns-test";
let apnsPrivateKey = "";

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
  apnsPrivateKey = `-----BEGIN PRIVATE KEY-----\n${encoded}\n-----END PRIVATE KEY-----`;
});

beforeEach(async () => {
  const now = Math.floor(Date.now() / 1_000);
  await testEnv.DB.prepare(
    "INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?) "
      + "ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at",
  ).bind(accountID, now, now).run();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("hosted APNs broker", () => {
  it("authenticates the host and forwards one bounded alert without retaining a device token", async () => {
    const hostID = `host-${crypto.randomUUID()}`;
    const credential = await enrollHost(hostID);
    const apnsID = crypto.randomUUID();
    const upstream = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, {
      status: 200,
      headers: { "apns-id": apnsID },
    }));
    const eventID = crypto.randomUUID().toLowerCase();
    const response = await sendPush(credential, pushBody(hostID, eventID));

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      accepted: true,
      statusCode: 200,
      reason: "Accepted",
      apnsID,
    });
    expect(upstream).toHaveBeenCalledOnce();
    const [url, options] = upstream.mock.calls[0] ?? [];
    expect(String(url)).toBe(`https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
    const headers = new Headers(options?.headers);
    expect(headers.get("Authorization")).toMatch(/^bearer [^.]+\.[^.]+\.[^.]+$/u);
    expect(headers.get("apns-topic")).toBe("codes.threading.mobile");
    expect(headers.get("apns-push-type")).toBe("alert");
    expect(headers.get("apns-collapse-id")).toMatch(/^[0-9a-f]{64}$/u);
    const payload = JSON.parse(new TextDecoder().decode(options?.body as Uint8Array));
    expect(payload).toMatchObject({
      aps: {
        alert: { title: "Build finished", body: "Open Threading to review it." },
        sound: "default",
        "thread-id": expect.any(String),
      },
      event: { id: eventID, hostID },
    });
  });

  it("refuses cross-host delivery before contacting APNs", async () => {
    const credential = await enrollHost(`host-${crypto.randomUUID()}`);
    const upstream = vi.spyOn(globalThis, "fetch");

    const response = await sendPush(
      credential,
      pushBody(`host-${crypto.randomUUID()}`, crypto.randomUUID().toLowerCase()),
    );

    expect(response.status).toBe(403);
    expect(upstream).not.toHaveBeenCalled();
  });

  it("routes production registrations to the production APNs endpoint", async () => {
    const hostID = `host-${crypto.randomUUID()}`;
    const credential = await enrollHost(hostID);
    const upstream = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(null, {
      status: 200,
    }));

    const response = await sendPush(
      credential,
      pushBody(hostID, crypto.randomUUID().toLowerCase(), "production"),
    );

    expect(response.status).toBe(200);
    const [url] = upstream.mock.calls[0] ?? [];
    expect(String(url)).toBe(`https://api.push.apple.com/3/device/${"ab".repeat(32)}`);
  });
});

async function enrollHost(hostID: string): Promise<string> {
  const accessToken = await signAccessToken(accountID, testEnv);
  const response = await worker.fetch(new Request("https://service.test/v1/hosts", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ hostID, displayName: "APNs Test Mac" }),
  }), testEnv);
  const value = await response.json<{ credential: string }>();
  return value.credential;
}

async function sendPush(credential: string, body: Record<string, unknown>): Promise<Response> {
  const configured = new Proxy(testEnv, {
    get(target, property, receiver) {
      const values: Record<PropertyKey, unknown> = {
        APNS_TEAM_ID: "TESTTEAM01",
        APNS_KEY_ID: "TESTKEY001",
        APNS_PRIVATE_KEY: apnsPrivateKey,
      };
      return Object.prototype.hasOwnProperty.call(values, property)
        ? values[property]
        : Reflect.get(target, property, receiver);
    },
  });
  return worker.fetch(new Request("https://service.test/v1/push", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credential}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  }), configured as Env);
}

function pushBody(
  hostID: string,
  eventID: string,
  environment = "sandbox",
): Record<string, unknown> {
  return {
    deviceToken: "ab".repeat(32),
    environment,
    playsSound: true,
    event: {
      type: "notification",
      id: eventID,
      kind: "agentMessage",
      hostID,
      sessionID: crypto.randomUUID().toLowerCase(),
      title: "Build finished",
      body: "Open Threading to review it.",
      destination: { kind: "session" },
      createdAt: Date.now() / 1_000,
    },
  };
}
