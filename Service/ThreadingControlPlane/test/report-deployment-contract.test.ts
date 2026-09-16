import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import type { Env } from "../src/environment";
import worker from "../src/index";

const bindings = env as unknown as Env & { TEST_REPORT_FIXTURES: string };
const fixtures = JSON.parse(bindings.TEST_REPORT_FIXTURES) as Array<{ id: string }>;

// The production deploy wrapper always runs this with fixtures encoded by the Swift package.
it.skipIf(fixtures.length === 0)("candidate accepts the actual shipping Swift contract before deployment", async () => {
  expect(fixtures).toHaveLength(3);
  for (const report of fixtures) {
    const response = await worker.fetch(new Request("https://service.test/v1/reports/validate", {
      method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": report.id },
      body: JSON.stringify(report),
    }), bindings);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ status: "validated", reportID: report.id,
      droppedUnknownFieldCount: 0, droppedUnknownRecordCount: 0 });
    expect(await bindings.ISSUE_REPORTS.head(`reports/v1/${report.id}.json`)).toBeNull();
  }
});
