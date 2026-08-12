import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { signAccessToken } from "../src/crypto";
import { authorizeRendezvousCredential } from "../src/enrollment";
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

    const revoked = await worker.fetch(new Request(
      `https://service.test/v1/hosts/${hostID}/devices/${deviceID}`,
      { method: "DELETE", headers: { Authorization: `Bearer ${hostCredential}` } },
    ), testEnv);
    expect(revoked.status).toBe(204);
    await expect(authorizeRendezvousCredential(deviceCredential, "device", testEnv))
      .rejects.toMatchObject({ status: 401, code: "unauthorized" });
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

function requiredString(value: unknown): string {
  if (typeof value !== "string") throw new Error("Expected string response field");
  return value;
}
