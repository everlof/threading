import assert from "node:assert/strict";
import test from "node:test";
import { verifyReports } from "./verify_report_deployment.mjs";

const reports = [1, 2, 3].map(id => ({ id: String(id) }));
function accepted(id, extra = {}) {
  return Response.json({ status: "validated", reportID: id, contractFingerprint: "a".repeat(64),
    droppedUnknownFieldCount: 0, droppedUnknownRecordCount: 0, ...extra });
}
test("requires all shipping fixtures to pass the no-storage production route", async () => {
  let count = 0;
  await verifyReports(reports, async (url, init) => {
    assert.equal(url, "https://remote.threading.codes/v1/reports/validate");
    assert.equal(init.headers["Idempotency-Key"], JSON.parse(init.body).id);
    count++; return accepted(JSON.parse(init.body).id);
  });
  assert.equal(count, 3);
});
test("fails closed on old deployments, lost evidence, mismatched receipts and oversized responses", async () => {
  for (const response of [
    () => Response.json({}, { status: 404 }),
    () => Response.json({}, { status: 400 }),
    () => accepted("1", { droppedUnknownFieldCount: 1 }),
    () => accepted("1", { droppedUnknownRecordCount: 1 }),
    () => accepted("other"),
    () => new Response("x".repeat(4097)),
  ]) await assert.rejects(verifyReports(reports, async () => response()));
});
