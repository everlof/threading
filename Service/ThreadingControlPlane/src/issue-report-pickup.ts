import type { Env } from "./environment";
import { HttpError } from "./environment";
import { sha256Hex } from "./crypto";
import { bearerToken, json } from "./http";

const reportIDPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const maximumListSize = 100;

/** Developer-only report pickup. The credential is a Worker secret, never an app resource. */
export async function handleIssueReportPickup(
  request: Request,
  env: Env,
  reportID?: string,
): Promise<Response> {
  await authorizeDeveloper(request, env);
  if (reportID) return exactReport(reportID, env);
  return listReports(new URL(request.url), env);
}

async function authorizeDeveloper(request: Request, env: Env): Promise<void> {
  const presented = bearerToken(request);
  const expected = env.REPORT_PICKUP_TOKEN;
  if (typeof expected !== "string" || new TextEncoder().encode(expected).byteLength < 32
    || new TextEncoder().encode(expected).byteLength > 4096
    || /[\u0000-\u0020\u007f]/u.test(expected)) {
    throw new HttpError(503, "serviceConfiguration", "Developer pickup is unavailable");
  }
  const [presentedDigest, expectedDigest] = await Promise.all([
    sha256Hex(presented),
    sha256Hex(expected),
  ]);
  let difference = 0;
  for (let index = 0; index < expectedDigest.length; index += 1) {
    difference |= expectedDigest.charCodeAt(index) ^ presentedDigest.charCodeAt(index);
  }
  if (difference !== 0) {
    throw new HttpError(403, "forbidden", "Developer pickup credential is invalid");
  }
}

async function listReports(url: URL, env: Env): Promise<Response> {
  const limitText = url.searchParams.get("limit");
  const limit = limitText === null ? 50 : Number(limitText);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > maximumListSize) {
    throw new HttpError(400, "invalidRequest", "limit must be an integer from 1 through 100");
  }
  const cursor = url.searchParams.get("cursor") ?? undefined;
  if (cursor && (new TextEncoder().encode(cursor).byteLength > 1024
    || /[\u0000-\u001f\u007f]/u.test(cursor))) {
    throw new HttpError(400, "invalidRequest", "cursor is invalid");
  }
  for (const key of url.searchParams.keys()) {
    if (key !== "limit" && key !== "cursor") {
      throw new HttpError(400, "invalidRequest", "Query contains an unknown field");
    }
  }

  const listed = await env.ISSUE_REPORTS.list({
    prefix: "reports/v1/",
    limit,
    ...(cursor ? { cursor } : {}),
    include: ["customMetadata"],
  });
  return json({
    reports: listed.objects.map((object) => ({
      reportID: object.customMetadata?.reportID ?? null,
      receivedAt: object.customMetadata?.receivedAt ?? object.uploaded.toISOString(),
      schemaVersion: object.customMetadata?.schemaVersion ?? null,
      source: object.customMetadata?.source ?? null,
      trigger: object.customMetadata?.trigger ?? null,
      kind: object.customMetadata?.kind ?? null,
      size: object.size,
    })),
    cursor: listed.truncated ? listed.cursor : null,
  });
}

async function exactReport(reportID: string, env: Env): Promise<Response> {
  if (!reportIDPattern.test(reportID)) {
    throw new HttpError(404, "notFound", "Report was not found");
  }
  const object = await env.ISSUE_REPORTS.get(`reports/v1/${reportID}.json`);
  if (!object) throw new HttpError(404, "notFound", "Report was not found");
  return new Response(object.body, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
