import { readFile, readdir } from "node:fs/promises";

const serviceRoot = new URL("../", import.meta.url);
const configurationPath = process.env.THREADING_WRANGLER_CONFIG
  ?? "wrangler.development.jsonc";
const configuration = JSON.parse(await readFile(new URL(configurationPath, serviceRoot), "utf8"));
const failures = [];

if (configuration.name !== "threading-control-plane-development") {
  failures.push("development Worker must have its isolated script name");
}
const databases = Array.isArray(configuration.d1_databases) ? configuration.d1_databases : [];
const database = databases.find((candidate) => candidate?.binding === "DB");
if (databases.length !== 1 || database?.database_name !== "threading-control-plane-development"
  || !isCloudflareIdentifier(database?.database_id)) {
  failures.push("development DB must use its own rendered D1 database ID");
}
if ((configuration.r2_buckets?.length ?? 0) !== 0
  || (configuration.queues?.consumers?.length ?? 0) !== 0) {
  failures.push("development push testing must not bind production reports or Queue resources");
}

const routes = Array.isArray(configuration.routes) ? configuration.routes : [];
if (configuration.workers_dev !== false || routes.length !== 1
  || routes[0]?.pattern !== "dev.remote.threading.codes"
  || routes[0]?.custom_domain !== true) {
  failures.push("development must expose only the dedicated custom domain");
}

const variables = configuration.vars ?? {};
if (variables.APNS_TOPIC !== "codes.threading.mobile") {
  failures.push("development APNs topic must match the iOS application");
}
if (variables.DEVELOPMENT_AUTH_MODE !== "1" || "LOCAL_DEVELOPMENT_MODE" in variables
  || "APPLE_CLIENT_IDS" in variables || "ISSUE_REPORTS_BUCKET_NAME" in variables) {
  failures.push("development must use browser auth without local, Apple, or report modes");
}
if (!isAccessIssuer(variables.DEVELOPMENT_ACCESS_ISSUER)) {
  failures.push("development Access issuer must be an exact cloudflareaccess.com HTTPS origin");
}
if (typeof variables.DEVELOPMENT_ACCESS_AUDIENCE !== "string"
  || !/^[A-Za-z0-9_-]{16,512}$/u.test(variables.DEVELOPMENT_ACCESS_AUDIENCE)) {
  failures.push("development Access audience must be rendered from the Access application");
}
const emails = typeof variables.DEVELOPMENT_ACCESS_EMAILS === "string"
  ? variables.DEVELOPMENT_ACCESS_EMAILS.split(",")
  : [];
if (emails.length < 1 || emails.length > 8 || new Set(emails).size !== emails.length
  || emails.some((email) => email !== email.trim().toLowerCase()
    || !/^[^\s@]+@[^\s@]+$/u.test(email) || email.length > 320)) {
  failures.push("development Access identities must be 1-8 exact lowercase email addresses");
}

const expectedRateLimits = new Map([
  ["AUTH_RATE_LIMITER", 30],
  ["API_RATE_LIMITER", 120],
  ["SOURCE_RATE_LIMITER", 600],
  ["REPORT_RATE_LIMITER", 6],
  ["REPORT_GLOBAL_RATE_LIMITER", 60],
]);
const productionNamespaces = new Set([
  "934721001", "934721002", "934721003", "934721004", "934721005",
]);
const rateLimits = Array.isArray(configuration.ratelimits) ? configuration.ratelimits : [];
const namespaceIDs = new Set();
for (const [name, limit] of expectedRateLimits) {
  const binding = rateLimits.find((candidate) => candidate?.name === name);
  if (!binding || binding.simple?.limit !== limit || binding.simple?.period !== 60
    || !/^[1-9][0-9]*$/u.test(binding.namespace_id ?? "")) {
    failures.push(`${name} must retain its reviewed ${limit}/minute binding`);
  } else if (namespaceIDs.has(binding.namespace_id)
    || productionNamespaces.has(binding.namespace_id)) {
    failures.push(`development rate-limit namespace ${binding.namespace_id} is reused`);
  } else {
    namespaceIDs.add(binding.namespace_id);
  }
}

const expectedSecrets = [
  "SESSION_SIGNING_SECRET",
  "APNS_TEAM_ID",
  "APNS_KEY_ID",
  "APNS_PRIVATE_KEY",
  "PUSH_TOKEN_ENCRYPTION_SECRET",
  "TURN_KEY_ID",
  "TURN_KEY_API_TOKEN",
];
if (JSON.stringify(configuration.secrets?.required) !== JSON.stringify(expectedSecrets)) {
  failures.push("development secret bindings must contain only auth, APNs, push, and TURN inputs");
}
if (JSON.stringify(configuration.triggers?.crons) !== JSON.stringify(["17 3 * * *"])) {
  failures.push("development must run cleanup without Apple's production validation trigger");
}

const migrations = (await readdir(new URL("migrations/", serviceRoot)))
  .filter((name) => name.endsWith(".sql"))
  .sort();
if (migrations.at(-1) !== "0008_development_auth_and_push_registrations.sql") {
  failures.push("development auth and push-registration migration must be the latest migration");
}

if (failures.length > 0) {
  for (const failure of failures) process.stderr.write(`preflight-development: ${failure}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write("Development configuration preflight passed.\n");
}

function isCloudflareIdentifier(value) {
  return typeof value === "string" && (/^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value));
}

function isAccessIssuer(value) {
  if (typeof value !== "string" || value.length > 512) return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === ""
      && url.port === "" && url.pathname === "/" && url.search === "" && url.hash === ""
      && url.hostname.endsWith(".cloudflareaccess.com");
  } catch {
    return false;
  }
}
