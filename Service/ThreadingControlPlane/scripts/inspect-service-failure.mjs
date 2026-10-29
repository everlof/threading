import { createHash } from "node:crypto";
import { pathToFileURL } from "node:url";

const referencePattern = /^sf-[0-9]{13}-(reports|auth|push|hosts|account|rendezvous)-(400|409|413|415|429|500|502|503|504)$/u;
const maximumResponseBytes = 32 * 1024;

export async function inspectServiceFailure(reference, {
  token = process.env.REPORT_PICKUP_TOKEN,
  origin = "https://remote.threading.codes",
  hostID,
  fetchImplementation = fetch,
} = {}) {
  if (!referencePattern.test(reference ?? "")) throw new Error("Supply the sf-… diagnostic reference from the alert");
  if (typeof token !== "string" || token.length < 32 || token.length > 4096 || /\s/u.test(token)) {
    throw new Error("REPORT_PICKUP_TOKEN must contain the protected developer pickup credential");
  }
  const base = new URL(origin);
  if (base.protocol !== "https:" || base.username || base.password || base.search || base.hash || base.pathname !== "/") {
    throw new Error("The pickup origin must be an HTTPS origin without credentials, path or query");
  }
  const response = await fetchImplementation(new URL(`/v1/developer/service-failures/${reference}`, base), {
    headers: { Authorization: `Bearer ${token}` }, redirect: "error", signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(response.status === 404 ? "No retained diagnostic: predates deployment, expired, or unknown reference"
      : `Developer pickup returned HTTP ${response.status}`);
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Developer pickup returned no diagnostic");
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumResponseBytes) {
      await reader.cancel();
      throw new Error("Developer pickup exceeded the diagnostic response limit");
    }
    chunks.push(Buffer.from(value));
  }
  const evidence = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (evidence.reference !== reference || !Array.isArray(evidence.samples) || evidence.samples.length > 8) {
    throw new Error("Developer pickup returned an invalid diagnostic");
  }
  if (hostID !== undefined) {
    // The supplied host ID is compared locally. It is never sent to the service or printed.
    const hostRef = `host-${createHash("sha256").update(`threading-service-failure:host:${hostID}`).digest("hex").slice(0, 24)}`;
    return { ...evidence, samples: evidence.samples.map(sample => ({ ...sample,
      matchesHost: sample.hostRef ? sample.hostRef === hostRef : null,
    })) };
  }
  return evidence;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [reference, option, hostID, ...extra] = process.argv.slice(2);
  try {
    if ((option !== undefined && (option !== "--host-id" || !hostID)) || extra.length) {
      throw new Error("Usage: node scripts/inspect-service-failure.mjs sf-… [--host-id <local-host-id>]");
    }
    process.stdout.write(`${JSON.stringify(await inspectServiceFailure(reference, { hostID }), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "Diagnostic pickup failed"}\n`);
    process.exitCode = 1;
  }
}
