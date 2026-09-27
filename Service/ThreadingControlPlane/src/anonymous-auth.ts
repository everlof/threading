import type { Env } from "./environment";
import { HttpError } from "./environment";
import { sha256Hex } from "./crypto";
import { issueSession } from "./auth";
import { assertExactKeys, readJSON } from "./http";

// This is a bounded pilot until the operated service has measured TURN use and a durable
// per-installation quota. The matching D1 trigger checks capacity atomically on every insert.
const hostIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const secretPattern = /^th_install_[A-Za-z0-9_-]{43}$/u;

export async function signInAnonymousHost(request: Request, env: Env): Promise<Response> {
  const body = await readJSON(request, 1024);
  assertExactKeys(body, ["hostID", "installationSecret"]);
  if (typeof body.hostID !== "string" || !hostIDPattern.test(body.hostID)
    || typeof body.installationSecret !== "string"
    || !secretPattern.test(body.installationSecret)) {
    throw new HttpError(400, "invalidRequest", "Installation identity is invalid");
  }
  const accountID = `anon_${body.hostID}`;
  const digest = await sha256Hex(body.installationSecret);
  const existing = await env.DB.prepare(
    "SELECT secret_digest FROM anonymous_host_identities WHERE account_id = ? AND host_id = ?",
  ).bind(accountID, body.hostID).first<{ secret_digest: string }>();
  if (existing) {
    if (existing.secret_digest !== digest) {
      throw new HttpError(401, "unauthorized", "Installation credential is invalid");
    }
    return issueSession(accountID, env, Math.floor(Date.now() / 1000));
  }

  const claimedHost = await env.DB.prepare("SELECT account_id FROM hosts WHERE id = ?")
    .bind(body.hostID).first<{ account_id: string }>();
  if (claimedHost && claimedHost.account_id !== accountID) {
    throw new HttpError(409, "hostAlreadyRegistered", "Host belongs to another identity");
  }

  const now = Math.floor(Date.now() / 1000);
  // The account row and identity row are one transaction. The D1 trigger fails the batch closed
  // if another request claimed the last pilot slot in the meantime.
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO accounts (id, created_at, updated_at) VALUES (?, ?, ?)")
        .bind(accountID, now, now),
      env.DB.prepare(
        "INSERT INTO anonymous_host_identities (account_id, host_id, secret_digest, created_at) "
          + "VALUES (?, ?, ?, ?)",
      ).bind(accountID, body.hostID, digest, now),
    ]);
  } catch (error) {
    if (String(error).includes("threading_anon_capacity")) {
      throw new HttpError(429, "installationLimit", "Hosted access pilot is full");
    }
    // A racing request with the same secret may already have completed registration. Verify
    // ownership before issuing a session; never accept a conflicting installation secret.
    const raced = await env.DB.prepare(
      "SELECT secret_digest FROM anonymous_host_identities WHERE account_id = ? AND host_id = ?",
    ).bind(accountID, body.hostID).first<{ secret_digest: string }>();
    if (raced?.secret_digest === digest) return issueSession(accountID, env, now);
    if (raced) throw new HttpError(401, "unauthorized", "Installation credential is invalid");
    throw error;
  }
  return issueSession(accountID, env, now);
}
