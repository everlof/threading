import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));

export async function verifyReports(reports, fetchImplementation = fetch,
  endpoint = "https://remote.threading.codes/v1/reports/validate") {
  if (!Array.isArray(reports) || reports.length !== 3) throw new Error("Missing shipping report fixtures");
  for (const report of reports) {
    const response = await fetchImplementation(endpoint, {
      method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": report.id,
        "User-Agent": "Threading-Release-Contract/1" },
      body: JSON.stringify(report), signal: AbortSignal.timeout(30_000),
    });
    const reader = response.body?.getReader();
    let size = 0;
    const chunks = [];
    if (!reader) throw new Error("Report validation response is empty");
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 4096) { await reader.cancel(); throw new Error("Report validation response is oversized"); }
      chunks.push(value);
    }
    let result;
    try { result = JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { /* refused below */ }
    if (response.status !== 200 || result?.status !== "validated" || result.reportID !== report.id
      || result.droppedUnknownFieldCount !== 0 || result.droppedUnknownRecordCount !== 0
      || !/^[a-f0-9]{64}$/u.test(result.contractFingerprint ?? "")) {
      throw new Error(`Deployed report contract is incompatible (HTTP ${response.status}); deploy the matching service before releasing the app.`);
    }
  }
}

export async function withShippingReportFixtures(consume) {
  const directory = await mkdtemp(join(tmpdir(), "threading-report-contract-"));
  try {
    const fixture = join(directory, "reports.json");
    execFileSync("swift", ["test", "--package-path", join(root, "Packages/ThreadingRemoteKit"),
      "--filter", "ReportDeploymentContractTests/testShippingReportContract"], {
      cwd: root, env: { ...process.env, THREADING_REPORT_CONTRACT_FIXTURE_PATH: fixture },
      stdio: ["ignore", "pipe", "pipe"], maxBuffer: 16 * 1024 * 1024,
    });
    return await consume(JSON.parse(await readFile(fixture, "utf8")), fixture);
  } finally { await rm(directory, { recursive: true, force: true }); }
}

export async function verifyShippingReportDeployment() {
  await withShippingReportFixtures(reports => verifyReports(reports));
  console.log("Deployed intake accepts the shipping Swift report contract with no dropped evidence.");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await verifyShippingReportDeployment();
}
