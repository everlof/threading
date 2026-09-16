import { verifyShippingReportDeployment } from "../../../scripts/verify_report_deployment.mjs";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const maximumResponseBytes = 4 * 1024;
const expectedProtocolVersion = 1;
const expectedNotificationProtocolVersion = 2;

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
  const origin = `https://${route.pattern}`;
  const readinessURL = `${origin}/ready`;
  let finalFailure = "no response";
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await request(fetchImplementation, readinessURL);
      const body = await boundedResponseText(response);
      const value = parseReadiness(body);
      if (response.status === 200
        && response.headers.get("Cache-Control") === "no-store"
        && response.headers.get("Content-Type")?.startsWith("application/json") === true
        && response.headers.get("Content-Security-Policy") === "default-src 'none'"
        && response.headers.get("X-Content-Type-Options") === "nosniff"
        && value.status === "ready"
        && value.rendezvousProtocol === expectedProtocolVersion
        && value.notificationProtocol === expectedNotificationProtocolVersion) {
        await verifyPushBoundaries(origin, fetchImplementation);
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
    || Object.keys(value).some((key) => ![
      "status", "rendezvousProtocol", "notificationProtocol",
    ].includes(key))) {
    throw new Error("readiness response was invalid");
  }
  return value;
}

async function verifyPushBoundaries(origin, fetchImplementation) {
  for (const path of ["/v1/push", "/v1/push/retractions"]) {
    const response = await request(fetchImplementation, `${origin}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    await boundedResponseText(response);
    if (response.status !== 401) {
      throw new Error(`${path} did not require a host credential (HTTP ${response.status})`);
    }
  }
}

function request(fetchImplementation, input, init = {}) {
  return fetchImplementation(input, {
    headers: { Accept: "application/json" },
    redirect: "error",
    signal: AbortSignal.timeout(5_000),
    ...init,
  });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  verifyProduction().then(() => verifyShippingReportDeployment()).catch((error) => {
    process.stderr.write(`verify-production: ${error.message}\n`);
    process.exitCode = 1;
  });
}
