import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const maximumResponseBytes = 4 * 1024;
const expectedProtocolVersion = 1;

export async function verifyProduction({
  attempts = 10,
  retryDelayMilliseconds = 2_000,
  fetchImplementation = fetch,
  reportSuccess = (message) => process.stdout.write(message),
} = {}) {
  const serviceRoot = new URL("../", import.meta.url);
  const configuration = JSON.parse(
    await readFile(new URL("wrangler.jsonc", serviceRoot), "utf8"),
  );
  const route = Array.isArray(configuration.routes)
    ? configuration.routes.find((candidate) => candidate?.custom_domain === true)
    : undefined;
  if (configuration.workers_dev !== false || route?.pattern !== "remote.threading.codes") {
    throw new Error("production verification requires the reviewed custom service domain");
  }
  const readinessURL = `https://${route.pattern}/ready`;
  let finalFailure = "no response";
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetchImplementation(readinessURL, {
        headers: { Accept: "application/json" },
        redirect: "error",
        signal: AbortSignal.timeout(5_000),
      });
      const body = await boundedResponseText(response);
      const value = parseReadiness(body);
      if (response.status === 200
        && response.headers.get("Cache-Control") === "no-store"
        && response.headers.get("Content-Type")?.startsWith("application/json") === true
        && response.headers.get("Content-Security-Policy") === "default-src 'none'"
        && response.headers.get("X-Content-Type-Options") === "nosniff"
        && value.status === "ready"
        && value.rendezvousProtocol === expectedProtocolVersion) {
        reportSuccess(`Production readiness verified at ${readinessURL}.\n`);
        return;
      }
      finalFailure = `HTTP ${response.status}`;
    } catch (error) {
      finalFailure = error instanceof Error ? error.name : "request failure";
    }
    if (attempt < attempts) await delay(retryDelayMilliseconds);
  }
  throw new Error(`production readiness failed after ${attempts} attempts (${finalFailure})`);
}

async function boundedResponseText(response) {
  const declared = Number(response.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > maximumResponseBytes) {
    throw new Error("readiness response was too large");
  }
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.byteLength;
    if (received > maximumResponseBytes) {
      await reader.cancel();
      throw new Error("readiness response was too large");
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(joined);
}

function parseReadiness(body) {
  const value = JSON.parse(body);
  if (typeof value !== "object" || value === null || Array.isArray(value)
    || Object.keys(value).some((key) => key !== "status" && key !== "rendezvousProtocol")) {
    throw new Error("readiness response was invalid");
  }
  return value;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  verifyProduction().catch((error) => {
    process.stderr.write(`verify-production: ${error.message}\n`);
    process.exitCode = 1;
  });
}
