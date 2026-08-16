import { spawn } from "node:child_process";
import { readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const serviceRoot = new URL("../", import.meta.url);
const templateURL = new URL("wrangler.jsonc", serviceRoot);
const generatedURL = new URL(".wrangler.production.generated.jsonc", serviceRoot);
const generatedPath = fileURLToPath(generatedURL);
const infraCLI = process.env.THREADING_INFRA_CLI ?? "terraform";

try {
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
    THREADING_WRANGLER_CONFIG: generatedPath,
  };
  await run(process.execPath, ["scripts/preflight.mjs"], environment);
  await run("npm", ["run", "check"], environment);
  await run("npm", ["test"], environment);
  await run("npm", ["run", "test:load"], environment);
  await run("npx", [
    "wrangler", "d1", "migrations", "apply", "threading-control-plane",
    "--remote", "--config", generatedPath,
  ], environment);
  await run("npx", ["wrangler", "deploy", "--config", generatedPath], environment);
  await run(process.execPath, ["scripts/verify-production.mjs"], environment);
} finally {
  await rm(generatedURL, { force: true });
}

function isCloudflareIdentifier(value) {
  return /^[0-9a-f]{32}$/u.test(value)
    || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
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
