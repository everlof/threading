import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, mkdir, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { fileURLToPath } from "node:url";

const serviceRoot = new URL("../", import.meta.url);
const localVariablesURL = new URL(".dev.vars.local", serviceRoot);
const statePath = ".wrangler/state/local";
await ensureLocalSecrets();
await mkdir(new URL(statePath, serviceRoot), { recursive: true });

await run("npx", [
  "wrangler", "d1", "migrations", "apply", "threading-control-plane-local",
  "--local", "--config", "wrangler.local.jsonc", "--persist-to", statePath,
]);

process.stdout.write(
  "\nLocal control plane: http://127.0.0.1:8787\n"
    + "Mac app environment:\n"
    + "  THREADING_CONTROL_PLANE_URL=http://127.0.0.1:8787\n"
    + "  THREADING_CONTROL_PLANE_LOCAL_AUTH=1\n"
    + "Use the iOS Simulator for loopback pairing; a physical phone requires an HTTPS staging endpoint.\n\n",
);
await run("npx", [
  "wrangler", "dev", "--config", "wrangler.local.jsonc",
  "--env-file", ".dev.vars.local", "--persist-to", statePath, "--ip", "127.0.0.1",
]);

async function ensureLocalSecrets() {
  try {
    await access(localVariablesURL, constants.F_OK);
    return;
  } catch {
    const values = [
      "# Generated for the loopback-only Worker. Never commit this file.",
      `SESSION_SIGNING_SECRET=${secret()}`,
      `APPLE_TOKEN_ENCRYPTION_SECRET=${secret()}`,
      `REPORT_PICKUP_TOKEN=${secret()}`,
      "",
    ];
    await writeFile(localVariablesURL, values.join("\n"), { mode: 0o600, flag: "wx" });
  }
}

function secret() {
  return randomBytes(48).toString("base64url");
}

async function run(executable, args) {
  const child = spawn(executable, args, {
    cwd: fileURLToPath(serviceRoot),
    stdio: "inherit",
    env: process.env,
  });
  const code = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", resolve);
  });
  if (code !== 0) throw new Error(`${executable} ${args.join(" ")} failed with exit ${code}`);
}
