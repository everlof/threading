import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const maximumResponseBytes = 8 * 1024;

export async function verifyDevelopment({
  attempts = 10,
  retryDelayMilliseconds = 2_000,
  fetchImplementation = fetch,
  reportSuccess = (message) => process.stdout.write(message),
} = {}) {
  const serviceRoot = new URL("../", import.meta.url);
  const configurationPath = process.env.THREADING_WRANGLER_CONFIG
    ?? "wrangler.development.jsonc";
  const configuration = JSON.parse(
    await readFile(new URL(configurationPath, serviceRoot), "utf8"),
  );
  const route = Array.isArray(configuration.routes)
    ? configuration.routes.find((candidate) => candidate?.custom_domain === true)
    : undefined;
  if (configuration.workers_dev !== false || route?.pattern !== "dev.remote.threading.codes") {
    throw new Error("development verification requires the dedicated custom service domain");
  }
  const origin = `https://${route.pattern}`;
  let finalFailure = "no response";
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await verifyAttempt(origin, fetchImplementation);
      reportSuccess(`Development auth and push boundaries verified at ${origin}.\n`);
      return;
    } catch (error) {
      finalFailure = error instanceof Error ? error.message : "request failure";
    }
    if (attempt < attempts) await delay(retryDelayMilliseconds);
  }
  throw new Error(`development verification failed after ${attempts} attempts (${finalFailure})`);
}

async function verifyAttempt(origin, fetchImplementation) {
  const ready = await request(fetchImplementation, `${origin}/ready`);
  const readyValue = JSON.parse(ready.body);
  if (ready.status !== 200 || readyValue.status !== "ready"
    || readyValue.rendezvousProtocol !== 1
    || readyValue.notificationProtocol !== 1) {
    throw new Error(`readiness returned HTTP ${ready.status}`);
  }

  for (const path of ["/v1/auth/apple", "/v1/reports"]) {
    const response = await request(fetchImplementation, `${origin}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    if (response.status !== 404) {
      throw new Error(`${path} is exposed in development (HTTP ${response.status})`);
    }
  }

  for (const path of ["/v1/push", "/v1/push/retractions"]) {
    const unauthorizedPush = await request(fetchImplementation, `${origin}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    });
    if (unauthorizedPush.status !== 401) {
      throw new Error(`${path} did not require a host credential (HTTP ${unauthorizedPush.status})`);
    }
  }

  const start = await request(fetchImplementation, `${origin}/v1/auth/development/start`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      hostID: "deployment-boundary-verification",
      codeChallenge: "0".repeat(64),
    }),
  });
  if (start.status !== 201) {
    throw new Error(`development auth start returned HTTP ${start.status}`);
  }
  const transaction = JSON.parse(start.body);
  const authorizationURL = new URL(transaction.authorizationURL);
  if (authorizationURL.origin !== origin
    || authorizationURL.pathname !== "/v1/auth/development/authorize"
    || !authorizationURL.searchParams.get("transaction")) {
    throw new Error("development auth returned an invalid authorization URL");
  }
  const authorization = await request(fetchImplementation, authorizationURL, {
    redirect: "manual",
  });
  const location = authorization.headers.get("Location");
  if (![301, 302, 303, 307, 308].includes(authorization.status) || !location) {
    throw new Error("browser authorization path is not protected by Cloudflare Access");
  }
  const loginURL = new URL(location, authorizationURL);
  if (!loginURL.hostname.endsWith(".cloudflareaccess.com")) {
    throw new Error("browser authorization did not redirect to the configured Access tenant");
  }
}

async function request(fetchImplementation, input, init = {}) {
  const response = await fetchImplementation(input, {
    redirect: "error",
    signal: AbortSignal.timeout(5_000),
    ...init,
  });
  return {
    status: response.status,
    headers: response.headers,
    body: await boundedResponseText(response),
  };
}

async function boundedResponseText(response) {
  const declared = Number(response.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > maximumResponseBytes) {
    throw new Error("development verification response was too large");
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
      throw new Error("development verification response was too large");
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

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  verifyDevelopment().catch((error) => {
    process.stderr.write(`verify-development: ${error.message}\n`);
    process.exitCode = 1;
  });
}
