import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { withShippingReportFixtures } from "../../../scripts/verify_report_deployment.mjs";

await withShippingReportFixtures(async (reports, fixture) => {
  if (!Array.isArray(reports) || reports.length !== 3) throw new Error("Missing shipping Swift fixtures");
  execFileSync("npx", ["vitest", "run", "test/report-deployment-contract.test.ts"], {
    cwd: fileURLToPath(new URL("../", import.meta.url)), stdio: "inherit",
    env: { ...process.env, THREADING_REPORT_CANDIDATE_FIXTURES: fixture },
  });
});
