import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const serviceRoot = new URL("../", import.meta.url);
const templateURL = new URL("wrangler.development.jsonc", serviceRoot);
const generatedURL = new URL(".wrangler.development.generated.jsonc", serviceRoot);
const generatedPath = fileURLToPath(generatedURL);
const infraCLI = process.env.THREADING_INFRA_CLI ?? "terraform";

try {
  const [databaseID, issuer, audience, allowedEmailsJSON] = await Promise.all([
    output("d1_database_id"),
    output("development_access_issuer"),
    output("development_access_audience"),
    output("allowed_emails", true),
  ]);
  if (!isCloudflareIdentifier(databaseID)) {
    throw new Error("Terraform/OpenTofu did not return a valid development D1 database ID");
  }
  if (!isAccessIssuer(issuer)) {
    throw new Error("Terraform/OpenTofu did not return a valid Access issuer");
  }
  if (!/^[A-Za-z0-9_-]{16,512}$/u.test(audience)) {
    throw new Error("Terraform/OpenTofu did not return a valid Access audience");
  }
  const allowedEmails = JSON.parse(allowedEmailsJSON);
  if (!Array.isArray(allowedEmails) || allowedEmails.length < 1 || allowedEmails.length > 8
    || allowedEmails.some((email) => typeof email !== "string")) {
    throw new Error("Terraform/OpenTofu did not return a valid development identity list");
  }

  const configuration = JSON.parse(await readFile(templateURL, "utf8"));
  const database = configuration.d1_databases?.find((candidate) => candidate.binding === "DB");
  if (!database) throw new Error("Development Wrangler template has no DB binding");
  database.database_id = databaseID;
  configuration.vars.DEVELOPMENT_ACCESS_ISSUER = issuer;
  configuration.vars.DEVELOPMENT_ACCESS_AUDIENCE = audience;
  configuration.vars.DEVELOPMENT_ACCESS_EMAILS = allowedEmails.join(",");
  await writeFile(generatedURL, `${JSON.stringify(configuration, null, 2)}\n`, { mode: 0o600 });

  const environment = {
    ...process.env,
    THREADING_WRANGLER_CONFIG: generatedPath,
  };
  await run(process.execPath, ["scripts/preflight-development.mjs"], environment);
  await run("npm", ["run", "check"], environment);
  await run("npm", ["test"], environment);
  await run("npx", [
    "wrangler", "d1", "migrations", "apply", "threading-control-plane-development",
    "--remote", "--config", generatedPath,
  ], environment);

  const secretsFile = process.env.THREADING_DEPLOY_SECRETS_FILE;
  if (secretsFile !== undefined) {
    if (!existsSync(secretsFile)) {
      throw new Error(`THREADING_DEPLOY_SECRETS_FILE does not exist: ${secretsFile}`);
    }
    process.stderr.write("deploy-development: bootstrapping the Worker with development secrets\n");
  }
  await run("npx", [
    "wrangler", "deploy", "--config", generatedPath,
    ...(secretsFile === undefined ? [] : ["--secrets-file", secretsFile]),
  ], environment);
  await run(process.execPath, ["scripts/verify-development.mjs"], environment);
} finally {
  await rm(generatedURL, { force: true });
}

function output(name, json = false) {
  return capture(infraCLI, [
    "-chdir=infra/development",
    "output",
    json ? "-json" : "-raw",
    name,
  ]).then((value) => value.trim());
}

function isCloudflareIdentifier(value) {
  return /^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
}

function isAccessIssuer(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === ""
      && url.port === "" && url.pathname === "/" && url.search === "" && url.hash === ""
      && url.hostname.endsWith(".cloudflareaccess.com");
  } catch {
    return false;
  }
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
