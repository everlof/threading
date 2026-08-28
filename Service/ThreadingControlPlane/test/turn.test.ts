import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/environment";
import { BOUNDS } from "../src/protocol";
import { generateIceServers } from "../src/turn";

const fallbackSTUN = {
  urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"],
};

afterEach(() => {
  vi.restoreAllMocks();
});

describe("TURN credential provisioning", () => {
  it("uses host-only ICE without contacting a cloud service in local development", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");

    await expect(generateIceServers({
      LOCAL_DEVELOPMENT_MODE: "1",
      LOCAL_ICE_MODE: "host-only",
      TURN_KEY_ID: "must-not-be-used",
      TURN_KEY_API_TOKEN: "must-not-be-used",
    } as Env)).resolves.toEqual([]);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("keeps direct STUN available when TURN is not configured", async () => {
    await expect(generateIceServers({} as Env)).resolves.toEqual([fallbackSTUN]);
  });

  it("requests bounded credentials and returns only reviewed Cloudflare routes", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      iceServers: [
        { urls: fallbackSTUN.urls },
        {
          urls: [
            "turn:turn.cloudflare.com:3478?transport=udp",
            "turn:turn.cloudflare.com:53?transport=udp",
            "turn:turn.cloudflare.com:3478?transport=tcp",
            "turn:turn.cloudflare.com:80?transport=tcp",
            "turns:turn.cloudflare.com:5349?transport=tcp",
            "turns:turn.cloudflare.com:443?transport=tcp",
            "turn:unreviewed.example:3478?transport=udp",
          ],
          username: "ephemeral-user",
          credential: "ephemeral-secret",
        },
      ],
    }, { status: 201 }));

    const result = await generateIceServers({
      TURN_KEY_ID: "turn-key-id",
      TURN_KEY_API_TOKEN: "turn-api-token",
    } as Env);

    expect(result).toEqual([
      fallbackSTUN,
      {
        urls: [
          "turn:turn.cloudflare.com:3478?transport=udp",
          "turn:turn.cloudflare.com:53?transport=udp",
          "turn:turn.cloudflare.com:80?transport=tcp",
          "turns:turn.cloudflare.com:443?transport=tcp",
        ],
        username: "ephemeral-user",
        credential: "ephemeral-secret",
      },
    ]);
    expect(fetchSpy).toHaveBeenCalledOnce();
    const [url, options] = fetchSpy.mock.calls[0] ?? [];
    expect(url).toBe(
      "https://rtc.live.cloudflare.com/v1/turn/keys/turn-key-id"
        + "/credentials/generate-ice-servers",
    );
    expect(options?.method).toBe("POST");
    expect(new Headers(options?.headers).get("Authorization")).toBe("Bearer turn-api-token");
    expect(JSON.parse(String(options?.body))).toEqual({ ttl: 24 * 60 * 60 });
  });

  it("falls back without returning malformed credentials or logging secrets", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      iceServers: [{
        urls: ["turn:unreviewed.example:3478?transport=udp"],
        username: "must-not-return",
        credential: "must-not-return-secret",
      }],
    }, { status: 201 }));
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});

    const result = await generateIceServers({
      TURN_KEY_ID: "turn-key-id",
      TURN_KEY_API_TOKEN: "turn-api-token",
    } as Env);

    expect(result).toEqual([fallbackSTUN]);
    expect(warning).toHaveBeenCalledWith("turn_credential_failed", {
      reason: "invalidResponse",
    });
    expect(JSON.stringify(result)).not.toContain("must-not-return");
    expect(JSON.stringify(warning.mock.calls)).not.toContain("must-not-return");
  });

  it.each([
    ["username", "u".repeat(BOUNDS.maximumIceCredentialBytes + 1), "short-secret-value"],
    ["credential", "short-user-value", "🔑".repeat(BOUNDS.maximumIceCredentialBytes / 4 + 1)],
  ])("falls back when the upstream %s exceeds the signaling byte bound", async (
    _field,
    username,
    credential,
  ) => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(Response.json({
      iceServers: [{
        urls: ["turn:turn.cloudflare.com:3478?transport=udp"],
        username,
        credential,
      }],
    }, { status: 201 }));
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});

    const result = await generateIceServers({
      TURN_KEY_ID: "turn-key-id",
      TURN_KEY_API_TOKEN: "turn-api-token",
    } as Env);

    expect(result).toEqual([fallbackSTUN]);
    expect(warning).toHaveBeenCalledWith("turn_credential_failed", {
      reason: "invalidResponse",
    });
    expect(JSON.stringify(warning.mock.calls)).not.toContain(username);
    expect(JSON.stringify(warning.mock.calls)).not.toContain(credential);
  });

  it("falls back to STUN when Cloudflare rejects credential generation", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("unavailable", { status: 503 }));
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});

    await expect(generateIceServers({
      TURN_KEY_ID: "turn-key-id",
      TURN_KEY_API_TOKEN: "turn-api-token",
    } as Env)).resolves.toEqual([fallbackSTUN]);
    expect(warning).toHaveBeenCalledWith("turn_credential_failed", { status: 503 });
  });
});
