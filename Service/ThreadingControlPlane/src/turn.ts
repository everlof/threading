import type { Env } from "./environment";
import { BOUNDS, type IceServer } from "./protocol";

const fallbackSTUN: IceServer = {
  urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"],
};

const encoder = new TextEncoder();
const reviewedTURNURLs = [
  "turn:turn.cloudflare.com:3478?transport=udp",
  "turn:turn.cloudflare.com:53?transport=udp",
  "turn:turn.cloudflare.com:80?transport=tcp",
  "turns:turn.cloudflare.com:443?transport=tcp",
];

/// TURN is an availability fallback: a credential-provisioning outage must not suppress the
/// direct STUN path. The returned native configuration remains within the Swift-side 8 × 4 cap.
export async function generateIceServers(env: Env): Promise<IceServer[]> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1" && env.LOCAL_ICE_MODE === "host-only") return [];
  if (!env.TURN_KEY_ID || !env.TURN_KEY_API_TOKEN) return [fallbackSTUN];
  try {
    const response = await fetch(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}`
        + "/credentials/generate-ice-servers",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.TURN_KEY_API_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ ttl: 24 * 60 * 60 }),
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!response.ok) {
      console.warn("turn_credential_failed", { status: response.status });
      return [fallbackSTUN];
    }
    const turn = provisionedTURNServer(await response.json());
    if (!turn) {
      console.warn("turn_credential_failed", { reason: "invalidResponse" });
      return [fallbackSTUN];
    }
    return [fallbackSTUN, turn];
  } catch (error) {
    console.warn("turn_credential_failed", {
      reason: error instanceof Error ? error.name : "unknown",
    });
    return [fallbackSTUN];
  }
}

function provisionedTURNServer(value: unknown): IceServer | undefined {
  if (!isRecord(value) || !Array.isArray(value.iceServers)) return undefined;
  for (const server of value.iceServers) {
    if (!isRecord(server)) continue;
    const urls = server.urls;
    if (!Array.isArray(urls) || !boundedCredential(server.username)
      || !boundedCredential(server.credential)) continue;
    const preferred = reviewedTURNURLs.filter((url) => urls.includes(url));
    if (preferred.length > 0) {
      return { urls: preferred, username: server.username, credential: server.credential };
    }
  }
  return undefined;
}

function boundedCredential(value: unknown): value is string {
  return typeof value === "string" && value.length > 0
    && encoder.encode(value).byteLength <= BOUNDS.maximumIceCredentialBytes;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
