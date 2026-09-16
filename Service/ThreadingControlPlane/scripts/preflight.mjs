import { readFile, readdir } from "node:fs/promises";

const serviceRoot = new URL("../", import.meta.url);
const repositoryRoot = new URL("../../", serviceRoot);
const configurationPath = process.env.THREADING_WRANGLER_CONFIG ?? "wrangler.jsonc";
const configuration = JSON.parse(await readFile(new URL(configurationPath, serviceRoot), "utf8"));
const failures = [];
const [xcodeProject, macInfoPlist, debugEntitlements, releaseEntitlements] = await Promise.all([
  readFile(new URL("Threading.xcodeproj/project.pbxproj", repositoryRoot), "utf8"),
  readFile(new URL("Sources/Threading/Resources/Info.plist", repositoryRoot), "utf8"),
  readFile(
    new URL("Sources/Threading/Resources/Threading-Debug.entitlements", repositoryRoot),
    "utf8",
  ),
  readFile(new URL("Sources/Threading/Resources/Threading.entitlements", repositoryRoot), "utf8"),
]);

const exampleVariables = parseDotVariables(
  await readFile(new URL(".dev.vars.example", serviceRoot), "utf8"),
);
const exampleSigningSecret = exampleVariables.get("SESSION_SIGNING_SECRET") ?? "";
const exampleEncryptionSecret = exampleVariables.get("APPLE_TOKEN_ENCRYPTION_SECRET") ?? "";
const examplePushEncryptionSecret = exampleVariables.get("PUSH_TOKEN_ENCRYPTION_SECRET") ?? "";
const examplePickupSecret = exampleVariables.get("REPORT_PICKUP_TOKEN") ?? "";
const exampleAlertSecret = exampleVariables.get("REPORT_ALERT_WEBHOOK_TOKEN") ?? "";
if (new TextEncoder().encode(exampleSigningSecret).byteLength < 32
  || new TextEncoder().encode(exampleEncryptionSecret).byteLength < 32
  || new TextEncoder().encode(examplePushEncryptionSecret).byteLength < 32
  || new TextEncoder().encode(examplePickupSecret).byteLength < 32
  || new TextEncoder().encode(exampleAlertSecret).byteLength < 32
  || exampleSigningSecret === exampleEncryptionSecret
  || exampleSigningSecret === examplePushEncryptionSecret
  || exampleEncryptionSecret === examplePushEncryptionSecret) {
  failures.push("local example secrets must satisfy the independent 32-byte runtime contract");
}

const databases = Array.isArray(configuration.d1_databases) ? configuration.d1_databases : [];
const database = databases.find((candidate) => candidate?.binding === "DB");
if (!database || !isCloudflareIdentifier(database.database_id)) {
  failures.push("DB must use the production D1 database ID, not the checked-in placeholder");
}
const reportBuckets = Array.isArray(configuration.r2_buckets) ? configuration.r2_buckets : [];
const reportBucket = reportBuckets.find((candidate) => candidate?.binding === "ISSUE_REPORTS");
if (reportBucket?.bucket_name !== "threading-private-issue-reports") {
  failures.push("ISSUE_REPORTS must bind the reviewed private production bucket");
}
if (configuration.vars?.ISSUE_REPORTS_BUCKET_NAME !== reportBucket?.bucket_name) {
  failures.push("ISSUE_REPORTS_BUCKET_NAME must match the private production bucket binding");
}
const queueConsumers = configuration.queues?.consumers ?? [];
const reportConsumer = queueConsumers.find(
  (candidate) => candidate?.queue === "threading-issue-report-events",
);
if (!reportConsumer || reportConsumer.dead_letter_queue !== "threading-issue-report-events-dlq"
  || reportConsumer.max_batch_size !== 10 || reportConsumer.max_retries !== 5) {
  failures.push("the issue-report Queue consumer must retain its reviewed bounded DLQ contract");
}

const route = Array.isArray(configuration.routes)
  ? configuration.routes.find((candidate) => candidate?.pattern === "remote.threading.codes")
  : undefined;
if (configuration.workers_dev !== false || route?.custom_domain !== true) {
  failures.push("production deploys must disable workers.dev and bind remote.threading.codes");
}

if (configuration.vars?.APPLE_CLIENT_IDS !== "codes.threading,codes.threading.mobile") {
  failures.push("Apple client IDs must match the shipping macOS and iOS bundle identifiers");
}
if (configuration.vars?.APNS_TOPIC !== "codes.threading.mobile") {
  failures.push("APNs topic must match the shipping iOS bundle identifier");
}
if (countMatches(
  xcodeProject,
  /^\s*PRODUCT_BUNDLE_IDENTIFIER = codes\.threading;\s*$/gmu,
) !== 2 || countMatches(
  xcodeProject,
  /^\s*PRODUCT_BUNDLE_IDENTIFIER = codes\.threading\.mobile;\s*$/gmu,
) !== 2) {
  failures.push("shipping bundle identifiers differ from the reviewed Apple audiences");
}
const serviceURLPattern = /<key>ThreadingControlPlaneURL<\/key>\s*<string>https:\/\/remote\.threading\.codes<\/string>/u;
if (!serviceURLPattern.test(macInfoPlist)) {
  failures.push("shipping macOS target must use the production control-plane URL");
}
if (countMatches(
  xcodeProject,
  /^\s*INFOPLIST_KEY_ThreadingControlPlaneURL\s*=/gmu,
) !== 0) {
  failures.push("iOS must obtain its control-plane URL from each validated pairing link");
}
// Neither macOS configuration may carry a restricted entitlement, and for two different
// reasons. Debug is ad-hoc signed, so one makes the app unlaunchable. Release is distributed by
// Developer ID, which cannot authorise `com.apple.developer.applesignin` at all: the capability
// never reaches a Developer ID provisioning profile, so `exportArchive` refuses outright, and
// signing it by hand ships an entitlement the system rejects at runtime. It was removed on
// 2026-08-23 for exactly that reason — see docs/architecture/releasing.md, "Sign in with Apple
// cannot be shipped by Developer ID". Hosted sign-in on a *distributed* Mac build needs the
// Services ID web flow instead; the native request still works in a development build, which
// is what host enrollment is tested against.
//
// This assertion used to demand the opposite. Do not restore it without reading that record.
const restrictedEntitlement = /<key>com\.apple\.developer\./u;
if (restrictedEntitlement.test(debugEntitlements)) {
  failures.push("macOS Debug builds must remain launchable with ad-hoc signing");
}
if (restrictedEntitlement.test(releaseEntitlements)) {
  failures.push("macOS Release builds must carry no restricted entitlement; Developer ID cannot authorise one");
}

const expectedRateLimits = new Map([
  ["AUTH_RATE_LIMITER", 30],
  ["API_RATE_LIMITER", 120],
  ["SOURCE_RATE_LIMITER", 600],
  ["REPORT_RATE_LIMITER", 6],
  ["REPORT_GLOBAL_RATE_LIMITER", 60],
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
  "APNS_TEAM_ID",
  "APNS_KEY_ID",
  "APNS_PRIVATE_KEY",
  "PUSH_TOKEN_ENCRYPTION_SECRET",
  "TURN_KEY_ID",
  "TURN_KEY_API_TOKEN",
  "REPORT_PICKUP_TOKEN",
  "REPORT_ALERT_WEBHOOK_URL",
  "REPORT_ALERT_WEBHOOK_TOKEN",
];
if (JSON.stringify(configuration.secrets?.required) !== JSON.stringify(expectedSecrets)) {
  failures.push("the required production Worker secret bindings differ from the reviewed list");
}
const expectedExampleVariables = ["APPLE_CLIENT_IDS", "APNS_TOPIC", ...expectedSecrets].sort();
if (JSON.stringify([...exampleVariables.keys()].sort()) !== JSON.stringify(expectedExampleVariables)
  || exampleVariables.get("APPLE_CLIENT_IDS") !== configuration.vars?.APPLE_CLIENT_IDS
  || exampleVariables.get("APNS_TOPIC") !== configuration.vars?.APNS_TOPIC) {
  failures.push(".dev.vars.example must mirror the reviewed variable and secret bindings");
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
  "0007_issue_report_quota.sql",
  "0008_development_auth_and_push_registrations.sql",
  "0009_service_failure_alerts.sql",
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

function parseDotVariables(contents) {
  const values = new Map();
  for (const line of contents.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) continue;
    const separator = trimmed.indexOf("=");
    if (separator <= 0) continue;
    values.set(trimmed.slice(0, separator), trimmed.slice(separator + 1));
  }
  return values;
}

function countMatches(contents, pattern) {
  return [...contents.matchAll(pattern)].length;
}
