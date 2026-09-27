import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";

if (process.platform !== "darwin" || !process.stdin.isTTY) {
  throw new Error("Run this command in an interactive macOS Terminal so Keychain can prompt for the token");
}

const variables = await readFile(new URL("../infra/terraform.tfvars", import.meta.url), "utf8");
const accountMatches = [...variables.matchAll(
  /^\s*cloudflare_account_id\s*=\s*"([0-9a-f]{32})"\s*(?:#.*)?$/gmu,
)];
if (accountMatches.length !== 1) {
  throw new Error("Production terraform.tfvars must define exactly one Cloudflare account ID");
}

const child = spawn("/usr/bin/security", [
  "add-generic-password",
  "-a", accountMatches[0][1],
  "-s", "codes.threading.cloudflare.production-deploy",
  "-l", "Threading production Cloudflare deploy token",
  "-U", "-w",
], { stdio: "inherit" });
const code = await new Promise((resolve, reject) => {
  child.on("error", reject);
  child.on("exit", resolve);
});
if (code !== 0) {
  process.exitCode = code || 1;
} else {
  process.stdout.write("Production Cloudflare deploy token stored in Keychain.\n");
}
