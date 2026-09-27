import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const serviceRoot = new URL("../", import.meta.url);
const templateURL = new URL("wrangler.jsonc", serviceRoot);
const generatedURL = new URL(".wrangler.production.generated.jsonc", serviceRoot);
const generatedPath = fileURLToPath(generatedURL);
const infraCLI = process.env.THREADING_INFRA_CLI ?? "terraform";
const deployTokenKeychainService = "codes.threading.cloudflare.production-deploy";

try {
  const variables = await readFile(new URL("infra/terraform.tfvars", serviceRoot), "utf8");
  const accountMatches = [...variables.matchAll(
    /^\s*cloudflare_account_id\s*=\s*"([0-9a-f]{32})"\s*(?:#.*)?$/gmu,
  )];
  if (accountMatches.length !== 1) {
    throw new Error("Production terraform.tfvars must define exactly one Cloudflare account ID");
  }
  const accountID = accountMatches[0][1];
  const databaseID = (await capture(infraCLI, [
    "-chdir=infra",
    "output",
    "-raw",
    "d1_database_id",
  ])).trim();
  if (!isCloudflareIdentifier(databaseID)) {
    throw new Error("Terraform/OpenTofu did not return a valid production D1 database ID");
  }
  const configuration = JSON.parse(await readFile(templateURL, "utf8"));
  const database = configuration.d1_databases?.find((candidate) => candidate.binding === "DB");
  if (!database) throw new Error("Production Wrangler template has no DB binding");
  database.database_id = databaseID;
  await writeFile(generatedURL, `${JSON.stringify(configuration, null, 2)}\n`, { mode: 0o600 });

  const environment = {
    ...process.env,
    CLOUDFLARE_ACCOUNT_ID: accountID,
    THREADING_WRANGLER_CONFIG: generatedPath,
  };
  await run(process.execPath, ["scripts/preflight.mjs"], environment);
  await run("npm", ["run", "check"], environment);
  await run("npm", ["test"], environment);
  await run("npm", ["run", "test:load"], environment);
  await run(process.execPath, ["scripts/verify-report-candidate.mjs"], environment);
  const wranglerEnvironment = await withDeployToken(environment, accountID);
  await run("npx", [
    "wrangler", "d1", "migrations", "apply", "threading-control-plane",
    "--remote", "--config", generatedPath,
  ], wranglerEnvironment);
  // `wrangler secret put` cannot address a Worker that does not exist yet, so the very first
  // deploy has to carry its secrets with it. THREADING_DEPLOY_SECRETS_FILE names a KEY=value
  // file for exactly that case; every later deploy leaves it unset and the already-installed
  // secrets are untouched. The file is the caller's to create and delete — this script never
  // writes one, so no secret is left behind by a failed run.
  const secretsFile = process.env.THREADING_DEPLOY_SECRETS_FILE;
  if (secretsFile !== undefined) {
    if (!existsSync(secretsFile)) {
      throw new Error(`THREADING_DEPLOY_SECRETS_FILE does not exist: ${secretsFile}`);
    }
    process.stderr.write("deploy: bootstrapping a new Worker with its secrets\n");
  }
  await run("npx", [
    "wrangler", "deploy", "--config", generatedPath,
    ...(secretsFile === undefined ? [] : ["--secrets-file", secretsFile]),
  ], wranglerEnvironment);
  await run(process.execPath, ["scripts/verify-production.mjs"], environment);
} finally {
  await rm(generatedURL, { force: true });
}

function isCloudflareIdentifier(value) {
  return /^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}

async function withDeployToken(environment, accountID) {
  if (environment.CLOUDFLARE_API_TOKEN || process.platform !== "darwin") return environment;
  const child = spawn("/usr/bin/security", [
    "find-generic-password", "-a", accountID,
    "-s", deployTokenKeychainService, "-w",
  ], { stdio: ["ignore", "pipe", "ignore"] });
  let token = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { token += chunk; });
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });
  if (code === 44) return environment; // No account-owned token has been installed yet.
  if (code !== 0) throw new Error("Could not read the production deploy token from Keychain");
  token = token.trim();
  if (!token.startsWith("cfat_") || /\s/u.test(token)) {
    throw new Error("The production deploy token in Keychain is not a new account-owned token");
  }
  process.stderr.write("deploy: using the account-owned production token from Keychain\n");
  return { ...environment, CLOUDFLARE_API_TOKEN: token };
}

async function capture(executable, args) {
  let stdout = "";
  let stderr = "";
  const child = spawn(executable, args, { cwd: fileURLToPath(serviceRoot), env: process.env });
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

async function run(executable, args, env) {
  const child = spawn(executable, args, {
    cwd: fileURLToPath(serviceRoot),
    stdio: "inherit",
    env,
  });
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });
  if (code !== 0) throw new Error(`${executable} ${args.join(" ")} failed with exit ${code}`);
}
