import type { Env } from "./environment";
import { sha256Hex } from "./crypto";

export const TURN_BUDGET = {
  perInstallationHour: 240,
  perInstallationDay: 2_000,
  globalDay: 20_000,
  credentialLifetimeSeconds: 24 * 60 * 60,
} as const;

/** Three fixed-size indexed writes per negotiation, never per packet. Only an authenticated
 * installation/host principal may supply accountID. Reconnects share the same budget. */
export async function reserveTURN(env: Env, accountID: string, now = Math.floor(Date.now() / 1000)): Promise<string | undefined> {
  const scope = await sha256Hex(`turn-usage:${accountID}`);
  const day = Math.floor(now / 86_400) * 86_400;
  const hour = Math.floor(now / 3_600) * 3_600;
  const budgets = [
    { scope: "global", period: "day", start: day, maximum: TURN_BUDGET.globalDay },
    { scope, period: "day", start: day, maximum: TURN_BUDGET.perInstallationDay },
    { scope, period: "hour", start: hour, maximum: TURN_BUDGET.perInstallationHour },
  ];
  try {
    await env.DB.batch(budgets.map(budget => env.DB.prepare(
      "INSERT INTO turn_issuance_budget (scope, period, starts_at, count, maximum) VALUES (?, ?, ?, 1, ?) "
        + "ON CONFLICT(scope, period, starts_at) DO UPDATE SET count = count + 1",
    ).bind(budget.scope, budget.period, budget.start, budget.maximum)));
    return scope;
  } catch (error) {
    if (String(error).includes("threading_turn_budget")) {
      console.warn("turn_budget_exhausted");
      return undefined;
    }
    // A failed reservation never permits unmetered issuance. The caller retains STUN fallback.
    console.warn("turn_budget_unavailable");
    return undefined;
  }
}
