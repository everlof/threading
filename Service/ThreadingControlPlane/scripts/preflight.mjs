import { readFile, readdir } from "node:fs/promises";

const serviceRoot = new URL("../", import.meta.url);
const configuration = JSON.parse(await readFile(new URL("wrangler.jsonc", serviceRoot), "utf8"));
const failures = [];

const databases = Array.isArray(configuration.d1_databases) ? configuration.d1_databases : [];
const database = databases.find((candidate) => candidate?.binding === "DB");
if (!database || !isCloudflareIdentifier(database.database_id)) {
  failures.push("DB must use the production D1 database ID, not the checked-in placeholder");
}

const route = Array.isArray(configuration.routes)
  ? configuration.routes.find((candidate) => candidate?.pattern === "remote.threading.codes")
  : undefined;
if (configuration.workers_dev !== false || route?.custom_domain !== true) {
  failures.push("production deploys must disable workers.dev and bind remote.threading.codes");
}

const expectedRateLimits = new Map([
  ["AUTH_RATE_LIMITER", 30],
  ["API_RATE_LIMITER", 120],
  ["SOURCE_RATE_LIMITER", 600],
]);
const rateLimits = Array.isArray(configuration.ratelimits) ? configuration.ratelimits : [];
const namespaceIDs = new Set();
for (const [name, limit] of expectedRateLimits) {
  const binding = rateLimits.find((candidate) => candidate?.name === name);
  if (!binding || binding.simple?.limit !== limit || binding.simple?.period !== 60
    || !/^[1-9][0-9]*$/u.test(binding.namespace_id ?? "")) {
    failures.push(`${name} must retain its reviewed ${limit}/minute binding`);
  } else if (namespaceIDs.has(binding.namespace_id)) {
    failures.push(`rate-limit namespace ${binding.namespace_id} is reused`);
  } else {
    namespaceIDs.add(binding.namespace_id);
  }
}

const crons = new Set(configuration.triggers?.crons ?? []);
for (const expected of ["7,22,37,52 * * * *", "17 3 * * *"]) {
  if (!crons.has(expected)) failures.push(`missing reviewed cron trigger: ${expected}`);
}

const expectedSecrets = [
  "SESSION_SIGNING_SECRET",
  "APPLE_TEAM_ID",
  "APPLE_KEY_ID",
  "APPLE_PRIVATE_KEY",
  "APPLE_TOKEN_ENCRYPTION_SECRET",
  "TURN_KEY_ID",
  "TURN_KEY_API_TOKEN",
];
if (JSON.stringify(configuration.secrets?.required) !== JSON.stringify(expectedSecrets)) {
  failures.push("the required production Worker secret bindings differ from the reviewed list");
}

const migrations = (await readdir(new URL("migrations/", serviceRoot)))
  .filter((name) => name.endsWith(".sql"))
  .sort();
const expectedMigrations = [
  "0001_initial.sql",
  "0002_apple_tokens.sql",
  "0003_apple_notifications.sql",
  "0004_device_limit.sql",
  "0005_apple_session_validation.sql",
  "0006_refresh_rotation.sql",
];
if (JSON.stringify(migrations) !== JSON.stringify(expectedMigrations)) {
  failures.push("the production migration set differs from the reviewed ordered list");
}

if (failures.length > 0) {
  for (const failure of failures) process.stderr.write(`preflight: ${failure}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write("Production configuration preflight passed.\n");
}

function isCloudflareIdentifier(value) {
  return typeof value === "string" && (/^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value));
}
