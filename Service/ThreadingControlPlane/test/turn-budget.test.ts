import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import type { Env } from "../src/environment";
import { reserveTURN, TURN_BUDGET } from "../src/turn-budget";
import { sha256Hex } from "../src/crypto";

const testEnv = env as unknown as Env;
beforeEach(async () => {
  await testEnv.DB.prepare("DELETE FROM turn_issuance_budget").run();
});

describe("durable TURN issuance budgets", () => {
  it("atomically gives the last hourly slot to one concurrent request", async () => {
    const account = "account-fixture";
    const scope = await sha256Hex(`turn-usage:${account}`);
    const now = 1_800_000_000;
    await testEnv.DB.prepare(
      "INSERT INTO turn_issuance_budget VALUES (?, 'hour', ?, ?, ?)",
    ).bind(scope, Math.floor(now / 3600) * 3600, TURN_BUDGET.perInstallationHour - 1,
      TURN_BUDGET.perInstallationHour).run();
    const results = await Promise.all(Array.from({ length: 8 }, () => reserveTURN(testEnv, account, now)));
    expect(results.filter(Boolean)).toEqual([scope]);
    const global = await testEnv.DB.prepare("SELECT count FROM turn_issuance_budget WHERE scope = 'global'")
      .first<{ count: number }>();
    expect(global?.count).toBe(1);
    expect(await reserveTURN(testEnv, "another-installation", now)).toBeDefined();
    expect(await reserveTURN(testEnv, account, now + 3600)).toBe(scope);
  });

  it("shares the global budget across installations and resets it on the next UTC day", async () => {
    const now = 1_800_000_000;
    await testEnv.DB.prepare("INSERT INTO turn_issuance_budget VALUES ('global', 'day', ?, ?, ?)")
      .bind(Math.floor(now / 86400) * 86400, TURN_BUDGET.globalDay, TURN_BUDGET.globalDay).run();
    expect(await reserveTURN(testEnv, "first", now)).toBeUndefined();
    expect(await reserveTURN(testEnv, "second", now)).toBeUndefined();
    const local = await testEnv.DB.prepare("SELECT COUNT(*) AS count FROM turn_issuance_budget WHERE scope != 'global'")
      .first<{ count: number }>();
    expect(local?.count).toBe(0);
    expect(await reserveTURN(testEnv, "first", now + 86400)).toBeDefined();
  });
});
