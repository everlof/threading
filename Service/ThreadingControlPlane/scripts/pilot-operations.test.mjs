import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { createInvitation, writeInvitation } from "./pilot-invitation.mjs";
import { usageQuery, summarizeUsage } from "./turn-usage.mjs";

test("pilot bearer remains in a private file and only its digest goes to D1", async () => {
  const parent = await mkdtemp(join(tmpdir(), "threading-pilot-test-"));
  try {
    const directory = join(parent, "grant");
    await writeInvitation(directory, 24);
    const token = (await readFile(join(directory, "invitation.txt"), "utf8")).trim();
    const sql = await readFile(join(directory, "insert.sql"), "utf8");
    assert.match(token, /^th_pilot_[A-Za-z0-9_-]{43}$/);
    assert.ok(!sql.includes(token));
    assert.ok(sql.includes(createHash("sha256").update(token).digest("hex")));
    assert.equal((await stat(directory)).mode & 0o777, 0o700);
    assert.equal((await stat(join(directory, "invitation.txt"))).mode & 0o777, 0o600);
    await assert.rejects(writeInvitation(directory, 24));
    assert.equal(createInvitation(100, 24).expiresAt, 86500);
    assert.throws(() => createInvitation(100, 169));
  } finally { await rm(parent, { recursive: true, force: true }); }
});

test("usage budgets use the full key total, never the truncated top installations", () => {
  const payload = { data: { viewer: { accounts: [{
    total: [{ sum: { egressBytes: 12e9, ingressBytes: 3e9 } }],
    installations: [{ dimensions: { customIdentifier: "digest" }, sum: { egressBytes: 1e9, ingressBytes: 2e8 } }],
  }] } } };
  const report = summarizeUsage(payload, 0.05, 10);
  assert.equal(report.egressGB, 12);
  assert.ok(Math.abs(report.estimatedUSD - 0.6) < 0.0001);
  assert.equal(report.budgetExceeded, true);
  assert.throws(() => summarizeUsage({ ...payload, errors: [{ message: "denied" }] }, 0.05, 10));
  assert.throws(() => summarizeUsage(payload, NaN, 10));
  const options = { accountID: "a".repeat(32), keyID: "b".repeat(32), date: "2026-10-11" };
  assert.match(usageQuery(options), /total: callsTurnUsageAdaptiveGroups/);
  assert.throws(() => usageQuery({ ...options, date: "2026-02-30" }));
  assert.throws(() => usageQuery({ ...options, keyID: '"bad' }));
});
