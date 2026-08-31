import { spawn } from "node:child_process";
import { resolve4 } from "node:dns/promises";
import { chmod, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const serviceRoot = new URL("../", import.meta.url);
const templateURL = new URL("wrangler.development.jsonc", serviceRoot);
const generatedURL = new URL(".wrangler.development.generated.jsonc", serviceRoot);
const callbackURL = new URL(
  "https://dev.remote.threading.codes/v1/auth/development/authorize",
);

const identity = JSON.parse(await capture("npx", ["wrangler", "whoami", "--json"]));
if (identity.loggedIn !== true || identity.authType !== "OAuth Token"
  || !Array.isArray(identity.accounts) || identity.accounts.length !== 1
  || typeof identity.email !== "string") {
  throw new Error("Wrangler must be OAuth-authenticated to exactly one Cloudflare account");
}
const allowedEmail = identity.email.trim().toLowerCase();
if (!/^[^\s@]+@[^\s@]+$/u.test(allowedEmail) || allowedEmail.length > 320) {
  throw new Error("Wrangler did not return a valid exact development email identity");
}

const edgeAddresses = await resolve4(callbackURL.hostname);
if (edgeAddresses.length < 1) {
  throw new Error("Development custom domain has no Cloudflare IPv4 address");
}
const headers = await capture("curl", [
  "--silent",
  "--show-error",
  "--head",
  "--max-time", "20",
  "--resolve", `${callbackURL.hostname}:443:${edgeAddresses[0]}`,
  callbackURL.href,
]);
const status = headers.match(/^HTTP\/\S+\s+(\d+)/mu)?.[1];
const locationValue = headers.match(/^location:\s*(\S+)/miu)?.[1];
if (status !== "302" || locationValue === undefined) {
  throw new Error("Development callback is not protected by a Cloudflare Access redirect");
}

const location = new URL(locationValue);
if (location.protocol !== "https:" || location.port !== ""
  || !location.hostname.endsWith(".cloudflareaccess.com")
  || location.pathname !== "/cdn-cgi/access/login/dev.remote.threading.codes") {
  throw new Error("Development callback redirected to an unexpected Access origin");
}
const audience = location.searchParams.get("kid") ?? "";
if (!/^[A-Za-z0-9_-]{16,512}$/u.test(audience)) {
  throw new Error("Cloudflare Access redirect has no valid application audience");
}
const metadata = decodeJWTPayload(location.searchParams.get("meta") ?? "");
const metadataAudiences = Array.isArray(metadata.aud) ? metadata.aud : [metadata.aud];
if (metadata.hostname !== callbackURL.hostname || !metadataAudiences.includes(audience)
  || metadata.redirect_url !== callbackURL.pathname) {
  throw new Error("Cloudflare Access redirect metadata does not bind the expected application");
}

const configuration = JSON.parse(await readFile(templateURL, "utf8"));
const database = configuration.d1_databases?.find((candidate) => candidate.binding === "DB");
if (!database || !isCloudflareIdentifier(database.database_id)) {
  throw new Error("Development Wrangler template has no provisioned DB binding");
}
configuration.vars.DEVELOPMENT_ACCESS_ISSUER = `${location.origin}/`;
configuration.vars.DEVELOPMENT_ACCESS_AUDIENCE = audience;
configuration.vars.DEVELOPMENT_ACCESS_EMAILS = allowedEmail;
await writeFile(generatedURL, `${JSON.stringify(configuration, null, 2)}\n`, { mode: 0o600 });
await chmod(generatedURL, 0o600);

process.stdout.write("Rendered the private development Worker configuration from live Access.\n");

function decodeJWTPayload(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("Cloudflare Access metadata is not a JWT");
  try {
    const value = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new Error("Cloudflare Access metadata payload is malformed");
  }
}

function isCloudflareIdentifier(value) {
  return typeof value === "string" && (/^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value));
}

async function capture(executable, args) {
  let stdout = "";
  let stderr = "";
  const child = spawn(executable, args, {
    cwd: fileURLToPath(serviceRoot),
    env: process.env,
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });
  if (code !== 0) throw new Error(`${executable} failed: ${stderr.trim()}`);
  return stdout;
}
