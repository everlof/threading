import { spawn } from "node:child_process";

const command = process.argv[2];
const environment = process.argv[3];
if (command !== "plan" && command !== "apply") {
  process.stderr.write("Usage: node scripts/infra.mjs <plan|apply> [development]\n");
  process.exit(2);
}
if (environment !== undefined && environment !== "development") {
  process.stderr.write("Environment must be omitted for production or be development.\n");
  process.exit(2);
}

const executable = process.env.THREADING_INFRA_CLI ?? "terraform";
const directory = environment === "development" ? "infra/development" : "infra";
const args =
  command === "plan"
    ? [`-chdir=${directory}`, "plan", "-input=false", "-out=.threading.tfplan"]
    : [`-chdir=${directory}`, "apply", "-input=false", ".threading.tfplan"];
const child = spawn(executable, args, { stdio: "inherit", env: process.env });
child.on("error", (error) => {
  process.stderr.write(`Unable to start ${executable}: ${error.message}\n`);
  process.exitCode = 1;
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exitCode = code ?? 1;
});
