import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import worker from "../src/index";

const testEnv = env as unknown as Env;

function installationSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `th_install_${btoa(String.fromCharCode(...bytes))
    .replace(/\+/gu, "-").replace(/\//gu, "_").replace(/=/gu, "")}`;
}

async function post(path: string, body: object, bearer?: string): Promise<Response> {
  return worker.fetch(new Request(`https://service.test${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}),
    },
    body: JSON.stringify(body),
  }), testEnv);
}

describe("accountless Mac enrollment", () => {
  it("restores the same owner session and rejects another installation secret", async () => {
    const hostID = crypto.randomUUID();
    const secret = installationSecret();
    const first = await post("/v1/auth/anonymous-host", {
      hostID,
      installationSecret: secret,
    });
    expect(first.status).toBe(200);
    const session = await first.json() as { accountID: string; accessToken: string };
    expect(session.accountID).toBe(`anon_${hostID}`);

    const enrolled = await post("/v1/hosts", { hostID, displayName: "My Mac" }, session.accessToken);
    expect(enrolled.status).toBe(201);
    const host = await enrolled.json() as { credential: string };
    const foreignHost = await post("/v1/hosts", {
      hostID: crypto.randomUUID(), displayName: "Another Mac",
    }, session.accessToken);
    expect(foreignHost.status).toBe(403);
    const device = await post(`/v1/hosts/${hostID}/devices`, {
      deviceID: crypto.randomUUID(),
    }, host.credential);
    expect(device.status).toBe(201);
    for (let index = 1; index < 8; index += 1) {
      expect((await post(`/v1/hosts/${hostID}/devices`, {
        deviceID: crypto.randomUUID(),
      }, host.credential)).status).toBe(201);
    }
    const ninthDevice = await post(`/v1/hosts/${hostID}/devices`, {
      deviceID: crypto.randomUUID(),
    }, host.credential);
    expect(ninthDevice.status).toBe(429);

    const restored = await post("/v1/auth/anonymous-host", {
      hostID,
      installationSecret: secret,
    });
    expect(restored.status).toBe(200);
    await expect(restored.json()).resolves.toMatchObject({ accountID: session.accountID });

    const wrong = await post("/v1/auth/anonymous-host", {
      hostID,
      installationSecret: installationSecret(),
    });
    expect(wrong.status).toBe(401);
    await expect(wrong.json()).resolves.toMatchObject({
      error: { code: "unauthorized" },
    });
  });

  it("rejects malformed secrets before allocating a hosted identity", async () => {
    const invalid = await post("/v1/auth/anonymous-host", {
      hostID: crypto.randomUUID(),
      installationSecret: "th_install_short",
    });
    expect(invalid.status).toBe(400);
    await expect(invalid.json()).resolves.toMatchObject({
      error: { code: "invalidRequest" },
    });
  });

  it("enforces the pilot capacity in D1 while preserving existing owners", async () => {
    const existingHostID = crypto.randomUUID();
    const existingSecret = installationSecret();
    expect((await post("/v1/auth/anonymous-host", {
      hostID: existingHostID,
      installationSecret: existingSecret,
    })).status).toBe(200);

    const now = Math.floor(Date.now() / 1000);
    const registered = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM anonymous_host_identities",
    ).first<{ count: number }>();
    for (let index = registered?.count ?? 0; index < 100; index += 1) {
      const hostID = crypto.randomUUID();
      const accountID = `anon_${hostID}`;
      await testEnv.DB.batch([
        testEnv.DB.prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)")
          .bind(accountID, now, now),
        testEnv.DB.prepare(
          "INSERT INTO anonymous_host_identities "
            + "(account_id, host_id, secret_digest, created_at) VALUES (?, ?, ?, ?)",
        ).bind(accountID, hostID, `digest-${hostID}`, now),
      ]);
    }

    const full = await post("/v1/auth/anonymous-host", {
      hostID: crypto.randomUUID(),
      installationSecret: installationSecret(),
    });
    expect(full.status).toBe(429);
    await expect(full.json()).resolves.toMatchObject({
      error: { code: "installationLimit" },
    });
    expect((await post("/v1/auth/anonymous-host", {
      hostID: existingHostID,
      installationSecret: existingSecret,
    })).status).toBe(200);
  });
});
