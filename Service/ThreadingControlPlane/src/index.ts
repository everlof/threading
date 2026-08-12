import type { Env, RendezvousPrincipal } from "./environment";
import { HttpError } from "./environment";
import { handleAppleSignIn, handleRefresh } from "./auth";
import { verifyRendezvousSessionToken } from "./crypto";
import {
  authorizeRendezvousCredential,
  enrollHost,
  issueDeviceCredential,
  revokeDeviceCredential,
  rotateHostCredentialForAccount,
} from "./enrollment";
import { bearerToken, json } from "./http";
import { BOUNDS, validateIdentifier } from "./protocol";

export { HostRendezvous } from "./host-rendezvous";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return json({ status: "ok", rendezvousProtocol: BOUNDS.protocolVersion });
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/apple") {
        return await handleAppleSignIn(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/auth/refresh") {
        return await handleRefresh(request, env);
      }
      if (request.method === "POST" && url.pathname === "/v1/hosts") {
        return await enrollHost(request, env);
      }

      const rotateMatch = /^\/v1\/hosts\/([^/]+)\/credentials\/rotate$/u.exec(url.pathname);
      if (request.method === "POST" && rotateMatch?.[1]) {
        return await rotateHostCredentialForAccount(request, env, decodePath(rotateMatch[1]));
      }
      const devicesMatch = /^\/v1\/hosts\/([^/]+)\/devices$/u.exec(url.pathname);
      if (request.method === "POST" && devicesMatch?.[1]) {
        return await issueDeviceCredential(request, env, decodePath(devicesMatch[1]));
      }
      const revokeMatch = /^\/v1\/hosts\/([^/]+)\/devices\/([^/]+)$/u.exec(url.pathname);
      if (request.method === "DELETE" && revokeMatch?.[1] && revokeMatch[2]) {
        return await revokeDeviceCredential(
          request,
          env,
          decodePath(revokeMatch[1]),
          decodePath(revokeMatch[2]),
        );
      }

      if (request.method === "GET" && url.pathname.startsWith("/v1/rendezvous/")) {
        return await routeRendezvous(request, url.pathname, env);
      }
      throw new HttpError(404, "notFound", "Endpoint was not found");
    } catch (error) {
      if (error instanceof HttpError) {
        return json({ error: { code: error.code, message: error.message } }, error.status);
      }
      console.error("request_failed", {
        reason: error instanceof Error ? error.name : "unknown",
      });
      return json({ error: { code: "internal", message: "Internal service error" } }, 500);
    }
  },

  async scheduled(_event: ScheduledController, env: Env): Promise<void> {
    const now = Math.floor(Date.now() / 1000);
    await env.DB.batch([
      env.DB.prepare(
        "DELETE FROM apple_assertions WHERE digest IN "
          + "(SELECT digest FROM apple_assertions WHERE expires_at < ? LIMIT 1000)",
      ).bind(now),
      env.DB.prepare(
        "DELETE FROM refresh_sessions WHERE digest IN "
          + "(SELECT digest FROM refresh_sessions WHERE expires_at < ? OR revoked_at IS NOT NULL LIMIT 1000)",
      ).bind(now),
      env.DB.prepare(
        "DELETE FROM rendezvous_credentials WHERE digest IN "
          + "(SELECT digest FROM rendezvous_credentials WHERE expires_at < ? "
          + "OR (revoked_at IS NOT NULL AND revoked_at < ?) LIMIT 1000)",
      ).bind(now, now - 7 * 24 * 60 * 60),
    ]);
  },
} satisfies ExportedHandler<Env>;

async function routeRendezvous(
  request: Request,
  pathname: string,
  env: Env,
): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError(426, "upgradeRequired", "WebSocket upgrade is required");
  }
  if (request.headers.get("X-Threading-Rendezvous-Version")
    !== String(BOUNDS.protocolVersion)) {
    throw new HttpError(426, "protocolVersion", "Rendezvous protocol version is unsupported");
  }
  const token = bearerToken(request);
  let principal: RendezvousPrincipal;
  try {
    switch (pathname) {
      case "/v1/rendezvous/host":
        principal = await authorizeRendezvousCredential(token, "host", env);
        break;
      case "/v1/rendezvous/device":
        principal = await authorizeRendezvousCredential(token, "device", env);
        break;
      case "/v1/rendezvous/session": {
        const verified = await verifyRendezvousSessionToken(token, env);
        principal = { kind: "session", ...verified };
        break;
      }
      default:
        throw new HttpError(404, "notFound", "Rendezvous endpoint was not found");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(401, "unauthorized", "Rendezvous credential is invalid or expired");
  }
  if (!validateIdentifier(principal.hostID)) {
    throw new HttpError(401, "unauthorized", "Rendezvous host is invalid");
  }
  const headers = new Headers({
    Upgrade: "websocket",
    "X-Threading-Principal-Kind": principal.kind,
    "X-Threading-Account-ID": principal.accountID,
    "X-Threading-Host-ID": principal.hostID,
  });
  if (principal.kind === "host" || principal.kind === "device") {
    headers.set(
      "X-Threading-Credential-Expires-At",
      String(principal.credentialExpiresAt),
    );
  }
  if (principal.kind === "device") {
    headers.set("X-Threading-Device-ID", principal.deviceID);
  } else if (principal.kind === "session") {
    headers.set("X-Threading-Session-ID", principal.sessionID);
  }
  const stub = env.HOST_RENDEZVOUS.getByName(principal.hostID);
  return stub.fetch(new Request(request.url, { method: "GET", headers }));
}

function decodePath(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    throw new HttpError(400, "invalidPath", "Path contains invalid encoding");
  }
}
