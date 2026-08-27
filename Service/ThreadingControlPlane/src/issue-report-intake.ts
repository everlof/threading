import type { Env } from "./environment";
import { HttpError } from "./environment";
import { sha256Hex } from "./crypto";
import { assertExactKeys, json, readJSON } from "./http";
import {
  additionalDetailFieldsByReportSource,
  diagnosticContractFingerprint,
  diagnosticEvents,
  diagnosticEventsByRecordSource,
  diagnosticFieldValidation,
  type DiagnosticFieldValidation,
} from "./issue-report-contract.generated";

export const ISSUE_REPORT_BOUNDS = {
  requestBytes: 64 * 1024,
  descriptionBytes: 10 * 1024,
  diagnosticsBytes: 24 * 1024,
  diagnosticRecords: 250,
  screenshotBytes: 12 * 1024,
  maximumAgeMilliseconds: 31 * 24 * 60 * 60 * 1000,
  maximumFutureSkewMilliseconds: 5 * 60 * 1000,
  maximumReportsPerUTCday: 2_000,
} as const;

const encoder = new TextEncoder();
const reportKeys = [
  "schemaVersion",
  "id",
  "createdAt",
  "trigger",
  "description",
  "diagnostics",
  "screenshotPreviewBase64",
  "screenshotMediaType",
];
const diagnosticsKeys = [
  "schemaVersion",
  "generatedAt",
  "source",
  "appVersion",
  "appBuild",
  "operatingSystem",
  "protocolVersion",
  "minimumProtocolVersion",
  "additionalDetails",
  "records",
];
const recordKeys = ["timestamp", "source", "level", "event", "fields"];
const triggers = new Set([
  "shake", "diagnostics", "connectionRecovery", "manual", "postCrash",
]);
const reportSources = new Set(["iOSClient", "macOSHost"]);
const recordSources = new Set(["iOSClient", "macOSHost", "browserClient"]);
const levels = new Set(["info", "warning", "error"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const iso8601Pattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/u;
const machineTokenPattern = /^[A-Za-z0-9._:-]+$/u;
const unsignedIntegerPattern = /^\d+$/u;
const peerPseudonymPattern = /^(?:peer|device)-[0-9a-f]{12}$/u;
const sessionPseudonymPattern = /^session-[0-9a-f]{12}$/u;
const originDigestPattern = /^origin-[0-9a-f]{12}$/u;
const base64Pattern = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;

interface NormalizedIssueReport {
  schemaVersion: 1;
  id: string;
  createdAt: string;
  trigger: string;
  description: string;
  diagnostics: NormalizedDiagnostics;
  screenshotPreviewBase64?: string;
  screenshotMediaType?: "image/jpeg";
}

interface NormalizedDiagnostics {
  schemaVersion: 1;
  generatedAt: string;
  source: string;
  appVersion: string;
  appBuild: string;
  operatingSystem: string;
  protocolVersion: number;
  minimumProtocolVersion: number;
  additionalDetails?: Record<string, string>;
  records: Array<{
    timestamp: string;
    source: string;
    level: string;
    event: string;
    fields: Record<string, string>;
  }>;
}

interface DiagnosticNormalization {
  contractFingerprint: string;
  droppedUnknownFieldCount: number;
  droppedUnknownRecordCount: number;
}

export type IssueReportKind = "report" | "crash" | "diagnostics";

export async function handleIssueReport(request: Request, env: Env): Promise<Response> {
  const contentType = request.headers.get("Content-Type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new HttpError(415, "unsupportedMediaType", "Content-Type must be application/json");
  }
  const contentEncoding = request.headers.get("Content-Encoding")?.trim().toLowerCase();
  if (contentEncoding && contentEncoding !== "identity") {
    throw new HttpError(415, "unsupportedEncoding", "Compressed report bodies are not accepted");
  }
  await enforceReportRateLimit(request, env);

  const raw = await readJSON(request, ISSUE_REPORT_BOUNDS.requestBytes);
  const normalization: DiagnosticNormalization = {
    contractFingerprint: diagnosticContractFingerprint,
    droppedUnknownFieldCount: 0,
    droppedUnknownRecordCount: 0,
  };
  const report = normalizeReport(raw, normalization);
  const idempotencyKey = request.headers.get("Idempotency-Key");
  if (idempotencyKey !== report.id) {
    throw new HttpError(400, "invalidIdempotencyKey", "Idempotency-Key must match the report id");
  }

  // Idempotency covers the normalized evidence and what version skew cost. The current contract
  // fingerprint remains stored as provenance, but is deliberately excluded here: deploying an
  // unrelated additive contract revision must not turn an otherwise exact retry into a conflict.
  const canonical = JSON.stringify({
    report,
    diagnosticNormalization: {
      droppedUnknownFieldCount: normalization.droppedUnknownFieldCount,
      droppedUnknownRecordCount: normalization.droppedUnknownRecordCount,
    },
  });
  const digest = await sha256Hex(canonical);
  const key = `reports/v1/${report.id}.json`;
  const existing = await env.ISSUE_REPORTS.head(key);
  if (existing) return existingReceipt(existing, report.id, digest);
  await reserveDailyCapacity(env);

  const receivedAt = new Date().toISOString();
  const stored = encoder.encode(JSON.stringify({
    receivedAt,
    diagnosticNormalization: normalization,
    report,
  }));
  const checksum = await crypto.subtle.digest("SHA-256", stored);
  const object = await env.ISSUE_REPORTS.put(key, stored, {
    onlyIf: { etagDoesNotMatch: "*" },
    httpMetadata: { contentType: "application/json" },
    customMetadata: {
      reportID: report.id,
      reportDigest: digest,
      receivedAt,
      schemaVersion: String(report.schemaVersion),
      source: report.diagnostics.source,
      trigger: report.trigger,
      kind: issueReportKind(report.trigger),
      diagnosticContract: normalization.contractFingerprint,
    },
    sha256: checksum,
  });
  if (!object) {
    const winner = await env.ISSUE_REPORTS.head(key);
    if (!winner) throw new Error("R2 conditional write failed without an existing object");
    return existingReceipt(winner, report.id, digest);
  }

  console.info("issue_report_received", {
    reportID: report.id,
    source: report.diagnostics.source,
    alreadyReceived: false,
    droppedUnknownFieldCount: normalization.droppedUnknownFieldCount,
    droppedUnknownRecordCount: normalization.droppedUnknownRecordCount,
  });
  return receipt(report.id, false, 201);
}

export function issueReportKind(trigger: string): IssueReportKind {
  if (trigger === "postCrash") return "crash";
  if (trigger === "diagnostics") return "diagnostics";
  return "report";
}

async function reserveDailyCapacity(env: Env): Promise<void> {
  const day = new Date().toISOString().slice(0, 10);
  const reservation = await env.DB.prepare(
    "INSERT INTO issue_report_daily_quota (day, accepted_count) VALUES (?, 1) "
      + "ON CONFLICT(day) DO UPDATE SET accepted_count = accepted_count + 1 "
      + "WHERE accepted_count < ? RETURNING accepted_count",
  ).bind(day, ISSUE_REPORT_BOUNDS.maximumReportsPerUTCday).first<{ accepted_count: number }>();
  if (!reservation) {
    throw new HttpError(429, "reportCapacity", "The report service is temporarily at capacity");
  }
}

async function enforceReportRateLimit(request: Request, env: Env): Promise<void> {
  const source = request.headers.get("CF-Connecting-IP") ?? "unattributed";
  const sourceDigest = await sha256Hex(source);
  const [sourceOutcome, globalOutcome] = await Promise.all([
    env.REPORT_RATE_LIMITER.limit({ key: `source:${sourceDigest}` }),
    env.REPORT_GLOBAL_RATE_LIMITER.limit({ key: "all-reports" }),
  ]);
  if (!sourceOutcome.success || !globalOutcome.success) {
    throw new HttpError(429, "rateLimited", "Too many reports; try again later");
  }
}

function normalizeReport(
  value: Record<string, unknown>,
  normalization: DiagnosticNormalization,
): NormalizedIssueReport {
  assertExactKeys(value, reportKeys);
  if (value.schemaVersion !== 1) invalid("Report schema version is unsupported");
  const id = requiredString(value.id, "id", 36);
  if (!uuidPattern.test(id)) invalid("Report id is invalid");
  const createdAt = boundedTimestamp(value.createdAt, "createdAt");
  const trigger = requiredString(value.trigger, "trigger", 32);
  if (!triggers.has(trigger)) invalid("Report trigger is invalid");
  const description = requiredString(
    value.description,
    "description",
    ISSUE_REPORT_BOUNDS.descriptionBytes,
  );
  if (description.trim().length === 0) invalid("Report description is empty");
  const diagnostics = normalizeDiagnostics(
    requiredObject(value.diagnostics, "diagnostics"),
    normalization,
  );

  const screenshot = optionalString(value.screenshotPreviewBase64, "screenshotPreviewBase64");
  const mediaType = optionalString(value.screenshotMediaType, "screenshotMediaType");
  if ((screenshot === undefined) !== (mediaType === undefined)) {
    invalid("Screenshot fields must be supplied together");
  }
  if (mediaType !== undefined && mediaType !== "image/jpeg") {
    invalid("Screenshot media type is invalid");
  }
  if (screenshot !== undefined) validateJPEG(screenshot);

  return {
    schemaVersion: 1,
    id,
    createdAt,
    trigger,
    description,
    diagnostics,
    ...(screenshot === undefined ? {} : {
      screenshotPreviewBase64: screenshot,
      screenshotMediaType: "image/jpeg" as const,
    }),
  };
}

function normalizeDiagnostics(
  value: Record<string, unknown>,
  normalization: DiagnosticNormalization,
): NormalizedDiagnostics {
  assertExactKeys(value, diagnosticsKeys);
  if (value.schemaVersion !== 1) invalid("Diagnostic schema version is unsupported");
  const generatedAt = boundedTimestamp(value.generatedAt, "diagnostics.generatedAt");
  const source = requiredString(value.source, "diagnostics.source", 32);
  if (!reportSources.has(source)) invalid("Diagnostic source is invalid");
  const appVersion = safeText(value.appVersion, "diagnostics.appVersion", 160);
  const appBuild = safeText(value.appBuild, "diagnostics.appBuild", 160);
  const operatingSystem = safeText(value.operatingSystem, "diagnostics.operatingSystem", 160);
  const protocolVersion = boundedInteger(value.protocolVersion, "diagnostics.protocolVersion");
  const minimumProtocolVersion = boundedInteger(
    value.minimumProtocolVersion,
    "diagnostics.minimumProtocolVersion",
  );
  const allowedAdditionalDetails = additionalDetailFieldsByReportSource.get(source);
  if (!allowedAdditionalDetails) invalid("Diagnostic source has no additional-detail contract");
  const additionalDetails = normalizeAdditionalDetails(
    value.additionalDetails,
    "diagnostics.additionalDetails",
    allowedAdditionalDetails,
    normalization,
  );
  if (!Array.isArray(value.records)
    || value.records.length > ISSUE_REPORT_BOUNDS.diagnosticRecords) {
    invalid("Diagnostic records are invalid");
  }
  const records: NormalizedDiagnostics["records"] = [];
  value.records.forEach((candidate, index) => {
    const record = requiredObject(candidate, `diagnostics.records[${index}]`);
    assertExactKeys(record, recordKeys);
    const timestamp = boundedTimestamp(record.timestamp, `diagnostics.records[${index}].timestamp`);
    const recordSource = requiredString(record.source, "diagnostic record source", 32);
    if (!recordSources.has(recordSource)
      || (source === "iOSClient" && recordSource !== "iOSClient")) {
      invalid("Diagnostic record source does not match report source");
    }
    const level = requiredString(record.level, "diagnostic record level", 16);
    if (!levels.has(level)) invalid("Diagnostic record level is invalid");
    const event = requiredString(record.event, "diagnostic record event", 64);
    const rawFields = requiredObject(record.fields, "diagnostic record fields");
    if (!diagnosticEvents.has(event)) {
      normalization.droppedUnknownRecordCount += 1;
      return;
    }
    if (diagnosticEventsByRecordSource.get(recordSource)?.has(event) !== true) {
      invalid("Diagnostic record event does not match its source");
    }
    const fields = normalizeDiagnosticFields(
      rawFields,
      "diagnostic record fields",
      normalization,
    );
    records.push({ timestamp, source: recordSource, level, event, fields });
  });

  const normalized: NormalizedDiagnostics = {
    schemaVersion: 1,
    generatedAt,
    source,
    appVersion,
    appBuild,
    operatingSystem,
    protocolVersion,
    minimumProtocolVersion,
    ...(additionalDetails === undefined ? {} : { additionalDetails }),
    records,
  };
  if (encoder.encode(JSON.stringify(normalized)).byteLength > ISSUE_REPORT_BOUNDS.diagnosticsBytes) {
    throw new HttpError(413, "diagnosticsTooLarge", "Diagnostics are too large");
  }
  return normalized;
}

function normalizeAdditionalDetails(
  value: unknown,
  name: string,
  allowedKeys: ReadonlySet<string>,
  normalization: DiagnosticNormalization,
): Record<string, string> | undefined {
  if (value === undefined || value === null) return undefined;
  const source = requiredObject(value, name);
  const result: Record<string, string> = {};
  for (const key of Object.keys(source).sort()) {
    if (!allowedKeys.has(key)) {
      normalization.droppedUnknownFieldCount += 1;
      continue;
    }
    const fieldValue = safeText(source[key], `${name}.${key}`, 160);
    result[key] = fieldValue;
  }
  return result;
}

function normalizeDiagnosticFields(
  source: Record<string, unknown>,
  name: string,
  normalization: DiagnosticNormalization,
): Record<string, string> {
  const result: Record<string, string> = {};
  for (const key of Object.keys(source).sort()) {
    const validation = diagnosticFieldValidation.get(key);
    if (validation === undefined) {
      normalization.droppedUnknownFieldCount += 1;
      continue;
    }
    const fieldValue = safeText(source[key], `${name}.${key}`, 160);
    validateDiagnosticFieldValue(fieldValue, key, name, validation);
    result[key] = fieldValue;
  }
  return result;
}

function validateDiagnosticFieldValue(
  value: string,
  key: string,
  dictionaryName: string,
  validation: DiagnosticFieldValidation,
): void {
  const name = `${dictionaryName}.${key}`;
  if (!machineTokenPattern.test(value)) invalid(`${name} is not a machine token`);
  switch (validation) {
    case "unsignedInteger":
      if (!unsignedIntegerPattern.test(value)) invalid(`${name} is not an unsigned integer`);
      break;
    case "peerPseudonym":
      if (!peerPseudonymPattern.test(value)) invalid(`${name} is not pseudonymized`);
      break;
    case "sessionPseudonym":
      if (!sessionPseudonymPattern.test(value)) invalid(`${name} is not pseudonymized`);
      break;
    case "originDigest":
      if (!originDigestPattern.test(value)) invalid(`${name} is not hashed`);
      break;
    case "token":
      break;
  }
}

function validateJPEG(encoded: string): void {
  if (encoded.length === 0 || !base64Pattern.test(encoded)) invalid("Screenshot is not valid base64");
  let binary: string;
  try {
    binary = atob(encoded);
  } catch {
    invalid("Screenshot is not valid base64");
  }
  if (binary.length > ISSUE_REPORT_BOUNDS.screenshotBytes) {
    throw new HttpError(413, "screenshotTooLarge", "Screenshot preview is too large");
  }
  if (binary.length < 3
    || binary.charCodeAt(0) !== 0xff
    || binary.charCodeAt(1) !== 0xd8
    || binary.charCodeAt(2) !== 0xff) {
    invalid("Screenshot preview is not a JPEG");
  }
}

function boundedTimestamp(value: unknown, name: string): string {
  const timestamp = requiredString(value, name, 64);
  if (!iso8601Pattern.test(timestamp)) invalid(`${name} is not an ISO-8601 timestamp`);
  const milliseconds = Date.parse(timestamp);
  const now = Date.now();
  if (!Number.isFinite(milliseconds)
    || milliseconds < now - ISSUE_REPORT_BOUNDS.maximumAgeMilliseconds
    || milliseconds > now + ISSUE_REPORT_BOUNDS.maximumFutureSkewMilliseconds) {
    invalid(`${name} is outside the accepted time window`);
  }
  return timestamp;
}

function boundedInteger(value: unknown, name: string): number {
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > 65_535) {
    invalid(`${name} is invalid`);
  }
  return value as number;
}

function safeText(value: unknown, name: string, maximumBytes: number): string {
  const result = requiredString(value, name, maximumBytes);
  if (result.length === 0 || /[\u0000-\u001f\u007f]/u.test(result)) {
    invalid(`${name} contains invalid text`);
  }
  return result;
}

function requiredString(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || encoder.encode(value).byteLength > maximumBytes) {
    invalid(`${name} is invalid`);
  }
  return value;
}

function optionalString(value: unknown, name: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requiredString(value, name, ISSUE_REPORT_BOUNDS.requestBytes);
}

function requiredObject(value: unknown, name: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    invalid(`${name} must be an object`);
  }
  return value as Record<string, unknown>;
}

function existingReceipt(existing: R2Object, reportID: string, digest: string): Response {
  if (existing.customMetadata?.reportDigest !== digest) {
    throw new HttpError(409, "idempotencyConflict", "Report id was already used");
  }
  console.info("issue_report_received", {
    reportID,
    source: existing.customMetadata?.source ?? "unknown",
    alreadyReceived: true,
  });
  return receipt(reportID, true, 200);
}

function receipt(reportID: string, wasAlreadyReceived: boolean, status: number): Response {
  return json({
    reportID,
    reference: `RPT-${reportID.replaceAll("-", "").slice(0, 12).toUpperCase()}`,
    wasAlreadyReceived,
  }, status);
}

function invalid(message: string): never {
  throw new HttpError(400, "invalidReport", message);
}
