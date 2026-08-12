import type { Env } from "./environment";
import type { IceServer } from "./protocol";

const fallbackSTUN: IceServer = {
  urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"],
};

interface CloudflareTURNResponse {
  iceServers?: Array<{
    urls?: string[];
    username?: string;
    credential?: string;
  }>;
}

/// TURN is an availability fallback: a credential-provisioning outage must not suppress the
/// direct STUN path. The returned native configuration remains within the Swift-side 8 × 4 cap.
export async function generateIceServers(env: Env): Promise<IceServer[]> {
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
    const body = await response.json<CloudflareTURNResponse>();
    const turn = body.iceServers?.find((server) => server.username && server.credential);
    if (!turn?.urls || !turn.username || !turn.credential) return [fallbackSTUN];
    const preferred = [
      "turn:turn.cloudflare.com:3478?transport=udp",
      "turn:turn.cloudflare.com:53?transport=udp",
      "turn:turn.cloudflare.com:80?transport=tcp",
      "turns:turn.cloudflare.com:443?transport=tcp",
    ].filter((url) => turn.urls?.includes(url));
    if (preferred.length === 0) return [fallbackSTUN];
    return [
      fallbackSTUN,
      { urls: preferred, username: turn.username, credential: turn.credential },
    ];
  } catch (error) {
    console.warn("turn_credential_failed", {
      reason: error instanceof Error ? error.name : "unknown",
    });
    return [fallbackSTUN];
  }
}
