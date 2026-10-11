import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

// https://developers.cloudflare.com/realtime/turn/analytics/
export function usageQuery({ accountID, keyID, date }) {
  if (!/^[a-f0-9]{32}$/i.test(accountID ?? "") || !/^[a-f0-9]{32}$/i.test(keyID ?? "")) {
    throw new Error("Set CLOUDFLARE_ACCOUNT_ID and TURN_KEY_ID to the intended account/key IDs");
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date ?? "") || new Date(date).toISOString().slice(0, 10) !== date) {
    throw new Error("Use --date YYYY-MM-DD (one UTC day)");
  }
  // All literals above are validated. The ungrouped total cannot silently truncate at the
  // identifier limit. Identifiers are the installation digests attached at issuance, not names.
  const filter = `keyId: "${keyID}", date_geq: "${date}", date_leq: "${date}"`;
  return `{ viewer { accounts(filter: { accountTag: "${accountID}" }) {
    total: callsTurnUsageAdaptiveGroups(filter: { ${filter} }, limit: 1, orderBy: []) {
      sum { egressBytes ingressBytes }
    }
    installations: callsTurnUsageAdaptiveGroups(filter: { ${filter} }, limit: 100, orderBy: [sum_egressBytes_DESC]) {
      dimensions { customIdentifier }
      sum { egressBytes ingressBytes }
    }
  } } }`;
}

export function summarizeUsage(payload, pricePerGB, budgetGB) {
  if (!Number.isFinite(pricePerGB) || pricePerGB < 0 || !Number.isFinite(budgetGB) || budgetGB <= 0) {
    throw new Error("Supply the contracted --price-per-gb and a positive --budget-gb");
  }
  const accounts = payload?.data?.viewer?.accounts;
  if (payload?.errors?.length || !Array.isArray(accounts) || accounts.length !== 1) {
    throw new Error("TURN analytics unavailable; check the Account Analytics token permission");
  }
  const { total, installations } = accounts[0];
  if (!Array.isArray(total) || total.length > 1 || !Array.isArray(installations)) throw new Error("Invalid analytics response");
  const bytes = row => {
    const { egressBytes, ingressBytes } = row?.sum ?? {};
    if (![egressBytes, ingressBytes].every(value => Number.isFinite(value) && value >= 0)) throw new Error("Invalid analytics counters");
    return { egressBytes, ingressBytes };
  };
  const totals = total.length ? bytes(total[0]) : { egressBytes: 0, ingressBytes: 0 };
  const egressGB = totals.egressBytes / 1e9;
  return {
    ...totals, egressGB, estimatedUSD: egressGB * pricePerGB,
    budgetGB, budgetExceeded: egressGB >= budgetGB,
    // Top 100 only; cost and budget always use the independent full total above.
    installations: installations.map(row => ({ identifier: row.dimensions?.customIdentifier ?? "", ...bytes(row) })),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const { values } = parseArgs({ options: {
      date: { type: "string" }, "price-per-gb": { type: "string" }, "budget-gb": { type: "string" },
    } });
    const query = usageQuery({ accountID: process.env.CLOUDFLARE_ACCOUNT_ID, keyID: process.env.TURN_KEY_ID, date: values.date });
    const token = process.env.CLOUDFLARE_ANALYTICS_API_TOKEN;
    if (!token) throw new Error("Set CLOUDFLARE_ANALYTICS_API_TOKEN with Account Analytics read permission");
    const response = await fetch("https://api.cloudflare.com/client/v4/graphql", {
      method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query }), signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`TURN analytics HTTP ${response.status}`);
    const result = summarizeUsage(await response.json(), Number(values["price-per-gb"]), Number(values["budget-gb"]));
    console.log(JSON.stringify({ date: values.date, ...result }, null, 2));
    if (result.budgetExceeded) process.exitCode = 2;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
