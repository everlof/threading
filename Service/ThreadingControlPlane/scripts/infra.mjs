import { spawn } from "node:child_process";

const command = process.argv[2];
if (command !== "plan" && command !== "apply") {
  process.stderr.write("Usage: node scripts/infra.mjs <plan|apply>\n");
  process.exit(2);
}

const executable = process.env.THREADING_INFRA_CLI ?? "terraform";
const args =
  command === "plan"
    ? ["-chdir=infra", "plan", "-input=false", "-out=.threading.tfplan"]
    : ["-chdir=infra", "apply", "-input=false", ".threading.tfplan"];
const child = spawn(executable, args, { stdio: "inherit", env: process.env });
child.on("error", (error) => {
  process.stderr.write(`Unable to start ${executable}: ${error.message}\n`);
  process.exitCode = 1;
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exitCode = code ?? 1;
});
