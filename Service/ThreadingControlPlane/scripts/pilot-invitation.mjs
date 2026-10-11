import { randomBytes, createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

export function createInvitation(now = Math.floor(Date.now() / 1000), lifetimeHours = 72) {
  if (!Number.isInteger(lifetimeHours) || lifetimeHours < 1 || lifetimeHours > 168) {
    throw new Error("Invitation lifetime must be 1–168 whole hours");
  }
  const invitation = `th_pilot_${randomBytes(32).toString("base64url")}`;
  const digest = createHash("sha256").update(invitation).digest("hex");
  const expiresAt = now + lifetimeHours * 3600;
  const sql = "INSERT INTO pilot_invitations (digest, created_at, expires_at) VALUES "
    + `('${digest}', ${now}, ${expiresAt});\n`;
  return { invitation, digest, expiresAt, sql };
}

// Offline on purpose: inspect/apply the digest-only SQL to the intended D1 environment.
// Never send a pilot bearer through command arguments, stdout, logs or a repository file.
export async function writeInvitation(directory, lifetimeHours) {
  const grant = createInvitation(undefined, lifetimeHours);
  await mkdir(directory, { mode: 0o700 }); // Refuse an existing destination.
  await writeFile(join(directory, "invitation.txt"), `${grant.invitation}\n`, { mode: 0o600, flag: "wx" });
  await writeFile(join(directory, "insert.sql"), grant.sql, { mode: 0o600, flag: "wx" });
  return { expiresAt: new Date(grant.expiresAt * 1000).toISOString() };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const { values } = parseArgs({ options: { output: { type: "string" }, hours: { type: "string", default: "72" } } });
    if (!values.output) throw new Error("Use --output /private/tmp/threading-pilot-<name> [--hours 72]");
    const result = await writeInvitation(resolve(values.output), Number(values.hours));
    console.log(`Private invitation files created; expires ${result.expiresAt}. Apply insert.sql before sharing invitation.txt.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
