import { SignJWT, importPKCS8 } from "jose";
import type { Env } from "./environment";
import { HttpError } from "./environment";
import { sha256Hex } from "./crypto";
import { authorizeRendezvousCredential } from "./enrollment";
import { assertExactKeys, bearerToken, json, readJSON } from "./http";
import { validateIdentifier } from "./protocol";
import { registeredPushRecipient, revokePushRegistration } from "./push-registrations";

const requestKeys = ["registrationID", "playsSound", "event"];
const eventKeys = [
  "type", "id", "kind", "hostID", "sessionID", "title", "body",
  "titleLocalization", "bodyLocalization", "destination", "createdAt",
  "turnGeneration",
];
const retractionRequestKeys = ["registrationID", "retraction"];
const retractionKeys = ["type", "hostID", "sessionID", "eventID", "kind"];
const localizationKeys = ["key", "arguments"];
const destinationKeys = [
  "kind", "attachmentID", "browserTabID", "extensionIdentifier", "extensionPanelID",
];
export enum NotificationKind {
  sharedSession = "sharedSession",
  permissionRequest = "permissionRequest",
  agentQuestion = "agentQuestion",
  turnCompleted = "turnCompleted",
  agentMessage = "agentMessage",
  attentionRequest = "attentionRequest",
}
type RetractableNotificationKind = NotificationKind.turnCompleted
  | NotificationKind.agentQuestion | NotificationKind.permissionRequest;

// Exhaustive: a new wire kind must explicitly choose whether it has a retractable lifetime.
function supportsRetraction(kind: NotificationKind): kind is RetractableNotificationKind {
  switch (kind) {
    case NotificationKind.turnCompleted:
    case NotificationKind.agentQuestion:
    case NotificationKind.permissionRequest:
      return true;
    case NotificationKind.sharedSession:
    case NotificationKind.agentMessage:
    case NotificationKind.attentionRequest:
      return false;
  }
  const unclassified: never = kind;
  return unclassified;
}

const kinds = new Set<NotificationKind>(Object.values(NotificationKind));
const destinationKinds = new Set(["session", "attachment", "browserTab", "extensionPanel"]);
const machineTokenPattern = /^[A-Za-z0-9._:-]+$/u;
const apnsKeyCache = new WeakMap<object, Promise<CryptoKey>>();
const apnsJWTCache = new WeakMap<object, { value: string; issuedAt: number }>();

interface NotificationEvent {
  type: "notification";
  id: string;
  kind: NotificationKind;
  hostID: string;
  sessionID: string;
  title: string;
  body: string;
  titleLocalization?: { key: string; arguments: string[] };
  bodyLocalization?: { key: string; arguments: string[] };
  destination: {
    kind: string;
    attachmentID?: string;
    browserTabID?: string;
    extensionIdentifier?: string;
    extensionPanelID?: string;
  };
  createdAt: number;
  turnGeneration?: number;
}

interface NotificationRetraction {
  type: "notificationRetraction";
  hostID: string;
  sessionID: string;
  eventID: string;
  kind: RetractableNotificationKind;
}

export async function handleAPNSPush(request: Request, env: Env): Promise<Response> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1") {
    throw new HttpError(503, "pushUnavailable", "Hosted push is unavailable in local development");
  }
  const principal = await authorizeRendezvousCredential(bearerToken(request), "host", env);
  if (principal.kind !== "host") throw new HttpError(403, "forbidden", "Host credential required");
  const body = await readJSON(request, 8 * 1024);
  assertExactKeys(body, requestKeys);
  if (typeof body.playsSound !== "boolean") invalid("playsSound is invalid");
  const event = normalizedEvent(requiredObject(body.event, "event"));
  if (event.hostID !== principal.hostID) {
    throw new HttpError(403, "forbidden", "Notification host does not match credential");
  }
  const registration = await registeredPushRecipient(
    body.registrationID,
    principal.hostID,
    principal.accountID,
    env,
  );

  const apnsBody = await encodedAPNSBody(event, body.playsSound);
  const host = registration.environment === "sandbox"
    ? "api.sandbox.push.apple.com"
    : "api.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${registration.deviceToken}`, {
    method: "POST",
    headers: {
      Authorization: `bearer ${await apnsAuthorizationToken(env)}`,
      "Content-Type": "application/json",
      "apns-topic": configuredAPNSTopic(env),
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(event.createdAt + (
        event.kind === "permissionRequest" ? 3_600 : 86_400
      ))),
      "apns-collapse-id": await eventCollapseID(event),
    },
    body: apnsBody,
    signal: AbortSignal.timeout(5_000),
  });
  const reason = await apnsResponseReason(response);
  const apnsID = normalizedAPNSID(response.headers.get("apns-id"));
  if (response.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
    await revokePushRegistration(body.registrationID as string, env);
  }
  console.info(response.ok ? "push_provider_accepted" : "push_provider_refused", {
    eventID: event.id,
    kind: event.kind,
    host: `host-${(await sha256Hex(event.hostID)).slice(0, 12)}`,
    session: `session-${(await sha256Hex(event.sessionID)).slice(0, 12)}`,
    device: `device-${registration.deviceTokenDigest.slice(0, 12)}`,
    environment: registration.environment,
    transport: "apns",
    attempt: 1,
    status: response.status,
    previewPresent: event.kind === NotificationKind.turnCompleted && !event.bodyLocalization,
    previewBytes: event.kind === NotificationKind.turnCompleted && !event.bodyLocalization
      ? new TextEncoder().encode(event.body).byteLength : 0,
    ...(apnsID ? { providerTrace: apnsID } : {}),
  });
  return json({
    accepted: response.status === 200,
    statusCode: response.status,
    reason: reason ?? (response.status === 200 ? "Accepted" : "Refused"),
    apnsID,
  });
}

export async function handleAPNSRetraction(request: Request, env: Env): Promise<Response> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1") {
    throw new HttpError(503, "pushUnavailable", "Hosted push is unavailable in local development");
  }
  const principal = await authorizeRendezvousCredential(bearerToken(request), "host", env);
  if (principal.kind !== "host") throw new HttpError(403, "forbidden", "Host credential required");
  const body = await readJSON(request, 4 * 1024);
  assertExactKeys(body, retractionRequestKeys);
  const retraction = normalizedRetraction(requiredObject(body.retraction, "retraction"));
  if (retraction.hostID !== principal.hostID) {
    throw new HttpError(403, "forbidden", "Retraction host does not match credential");
  }
  const registration = await registeredPushRecipient(
    body.registrationID,
    principal.hostID,
    principal.accountID,
    env,
  );
  const encoded = new TextEncoder().encode(JSON.stringify({
    aps: { "content-available": 1 },
    retraction,
  }));
  const host = registration.environment === "sandbox"
    ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const response = await fetch(`https://${host}/3/device/${registration.deviceToken}`, {
    method: "POST",
    headers: {
      Authorization: `bearer ${await apnsAuthorizationToken(env)}`,
      "Content-Type": "application/json",
      "apns-topic": configuredAPNSTopic(env),
      "apns-push-type": "background",
      "apns-priority": "5",
      "apns-expiration": String(Math.floor(Date.now() / 1_000 + 5 * 60)),
      // The background retraction replaces an alert APNs has accepted but not yet delivered.
      // If the alert already reached the phone, the payload instead removes it locally.
      "apns-collapse-id": await retractionCollapseID(retraction),
    },
    body: encoded,
    signal: AbortSignal.timeout(5_000),
  });
  const reason = await apnsResponseReason(response);
  const apnsID = normalizedAPNSID(response.headers.get("apns-id"));
  if (response.status === 410 || reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic") {
    await revokePushRegistration(body.registrationID as string, env);
  }
  console.info(response.ok ? "push_retraction_accepted" : "push_retraction_refused", {
    eventID: retraction.eventID,
    kind: retraction.kind,
    host: `host-${(await sha256Hex(retraction.hostID)).slice(0, 12)}`,
    session: `session-${(await sha256Hex(retraction.sessionID)).slice(0, 12)}`,
    device: `device-${registration.deviceTokenDigest.slice(0, 12)}`,
    environment: registration.environment,
    transport: "apns",
    attempt: 1,
    status: response.status,
    ...(apnsID ? { providerTrace: apnsID } : {}),
  });
  return json({
    accepted: response.status === 200,
    statusCode: response.status,
    reason: reason ?? (response.status === 200 ? "Accepted" : "Refused"),
    apnsID,
  });
}

export async function validateAPNSConfiguration(env: Env): Promise<void> {
  if (env.LOCAL_DEVELOPMENT_MODE === "1") return;
  configuredAPNSTopic(env);
  await apnsAuthorizationToken(env);
}

function normalizedEvent(value: Record<string, unknown>): NotificationEvent {
  assertExactKeys(value, eventKeys);
  if (value.type !== "notification") invalid("event.type is invalid");
  const id = machineToken(value.id, "event.id", 128);
  const kind = boundedEnum(value.kind, kinds);
  const hostID = machineToken(value.hostID, "event.hostID", 128);
  const sessionID = machineToken(value.sessionID, "event.sessionID", 128);
  if (!validateIdentifier(hostID) || !validateIdentifier(sessionID)) {
    invalid("event identifiers are invalid");
  }
  const title = safeText(value.title, "event.title", 160);
  const body = safeText(value.body, "event.body", 1_500);
  const titleLocalization = optionalLocalization(value.titleLocalization, "titleLocalization");
  const bodyLocalization = optionalLocalization(value.bodyLocalization, "bodyLocalization");
  const destination = normalizedDestination(requiredObject(value.destination, "destination"));
  if (typeof value.createdAt !== "number" || !Number.isFinite(value.createdAt)) {
    invalid("event.createdAt is invalid");
  }
  const turnGeneration = value.turnGeneration;
  if (turnGeneration !== undefined && (
    typeof turnGeneration !== "number"
      || !Number.isSafeInteger(turnGeneration)
      || turnGeneration < 0
  )) {
    invalid("event.turnGeneration is invalid");
  }
  const now = Date.now() / 1_000;
  if (value.createdAt < now - 2 * 24 * 60 * 60 || value.createdAt > now + 5 * 60) {
    invalid("event.createdAt is outside the accepted window");
  }
  return {
    type: "notification",
    id,
    kind,
    hostID,
    sessionID,
    title,
    body,
    ...(titleLocalization ? { titleLocalization } : {}),
    ...(bodyLocalization ? { bodyLocalization } : {}),
    destination,
    createdAt: value.createdAt,
    ...(typeof turnGeneration === "number" ? { turnGeneration } : {}),
  };
}

function normalizedRetraction(value: Record<string, unknown>): NotificationRetraction {
  assertExactKeys(value, retractionKeys);
  if (value.type !== "notificationRetraction") invalid("retraction.type is invalid");
  const hostID = machineToken(value.hostID, "retraction.hostID", 128);
  const sessionID = machineToken(value.sessionID, "retraction.sessionID", 128);
  const eventID = machineToken(value.eventID, "retraction.eventID", 128);
  const kind = boundedEnum(value.kind, kinds);
  if (!validateIdentifier(hostID) || !validateIdentifier(sessionID)
    || !supportsRetraction(kind)) invalid("retraction is invalid");
  return { type: "notificationRetraction", hostID, sessionID, eventID, kind };
}

function normalizedDestination(value: Record<string, unknown>): NotificationEvent["destination"] {
  assertExactKeys(value, destinationKeys);
  const kind = boundedEnum(value.kind, destinationKinds);
  const fields = {
    attachmentID: optionalMachineToken(value.attachmentID, "destination.attachmentID"),
    browserTabID: optionalMachineToken(value.browserTabID, "destination.browserTabID"),
    extensionIdentifier: optionalMachineToken(
      value.extensionIdentifier,
      "destination.extensionIdentifier",
    ),
    extensionPanelID: optionalMachineToken(value.extensionPanelID, "destination.extensionPanelID"),
  };
  const present = Object.entries(fields).filter(([, candidate]) => candidate !== undefined)
    .map(([key]) => key);
  const expected = kind === "session" ? []
    : kind === "attachment" ? ["attachmentID"]
    : kind === "browserTab" ? ["browserTabID"]
    : ["extensionIdentifier", "extensionPanelID"];
  if (JSON.stringify(present) !== JSON.stringify(expected)) invalid("destination is invalid");
  return { kind, ...Object.fromEntries(Object.entries(fields).filter(([, item]) => item)) };
}

function optionalLocalization(
  value: unknown,
  name: string,
): { key: string; arguments: string[] } | undefined {
  if (value === undefined || value === null) return undefined;
  const object = requiredObject(value, name);
  assertExactKeys(object, localizationKeys);
  const key = safeText(object.key, `${name}.key`, 160);
  if (!Array.isArray(object.arguments) || object.arguments.length > 8) {
    invalid(`${name}.arguments is invalid`);
  }
  return {
    key,
    arguments: object.arguments.map((item, index) => safeText(
      item,
      `${name}.arguments[${index}]`,
      160,
    )),
  };
}

async function encodedAPNSBody(event: NotificationEvent, playsSound: boolean): Promise<Uint8Array> {
  let delivered = event;
  let encoded = encodeEnvelope(delivered, playsSound);
  if (encoded.byteLength > 4_096) {
    delivered = { ...event, body: truncateUTF8(event.body, 400) };
    encoded = encodeEnvelope(delivered, playsSound);
  }
  if (encoded.byteLength > 4_096) {
    throw new HttpError(413, "pushTooLarge", "Notification does not fit the APNs payload limit");
  }
  return encoded;
}

function encodeEnvelope(event: NotificationEvent, playsSound: boolean): Uint8Array {
  return new TextEncoder().encode(JSON.stringify({
    aps: {
      alert: {
        title: event.title,
        body: event.body,
        ...(event.titleLocalization ? {
          "title-loc-key": event.titleLocalization.key,
          "title-loc-args": event.titleLocalization.arguments,
        } : {}),
        ...(event.bodyLocalization ? {
          "loc-key": event.bodyLocalization.key,
          "loc-args": event.bodyLocalization.arguments,
        } : {}),
      },
      ...(playsSound ? { sound: "default" } : {}),
      "thread-id": event.sessionID,
      category: event.kind === "permissionRequest" ? "THREADING_PERMISSION" : "THREADING_SESSION",
    },
    event,
  }));
}

async function apnsAuthorizationToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1_000);
  const cached = apnsJWTCache.get(env);
  if (cached && now - cached.issuedAt < 50 * 60) return cached.value;
  const teamID = configuredToken(env.APNS_TEAM_ID, "APNs team ID", 128);
  const keyID = configuredToken(env.APNS_KEY_ID, "APNs key ID", 128);
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyID })
    .setIssuer(teamID)
    .setIssuedAt(now)
    .sign(await apnsPrivateKey(env));
  apnsJWTCache.set(env, { value, issuedAt: now });
  return value;
}

async function apnsPrivateKey(env: Env): Promise<CryptoKey> {
  const cached = apnsKeyCache.get(env);
  if (cached) return cached;
  const raw = env.APNS_PRIVATE_KEY;
  if (typeof raw !== "string" || raw.length === 0 || raw.length > 64 * 1024) {
    throw new HttpError(503, "serviceConfiguration", "APNs private key is not configured");
  }
  const imported = importPKCS8(raw.replaceAll("\\n", "\n"), "ES256").catch(() => {
    apnsKeyCache.delete(env);
    throw new HttpError(503, "serviceConfiguration", "APNs private key is invalid");
  });
  apnsKeyCache.set(env, imported);
  return imported;
}

function configuredAPNSTopic(env: Env): string {
  const topic = configuredToken(env.APNS_TOPIC, "APNs topic", 160);
  if (topic !== "codes.threading.mobile") {
    throw new HttpError(503, "serviceConfiguration", "APNs topic is invalid");
  }
  return topic;
}

async function eventCollapseID(event: NotificationEvent): Promise<string> {
  if (supportsRetraction(event.kind)) {
    return retractableCollapseID(event.hostID, event.sessionID, event.kind, event.id);
  }
  const source = event.kind === "agentMessage"
    ? `event:${event.id}`
    : `session:${event.kind}:${event.sessionID}`;
  return (await sha256Hex(source)).slice(0, 64);
}

async function retractionCollapseID(retraction: NotificationRetraction): Promise<string> {
  return retractableCollapseID(
    retraction.hostID, retraction.sessionID, retraction.kind, retraction.eventID,
  );
}

async function retractableCollapseID(
  hostID: string, sessionID: string, kind: NotificationKind, eventID: string,
): Promise<string> {
  const encoder = new TextEncoder();
  const identity = [hostID, sessionID, kind, eventID]
    .map(value => `${encoder.encode(value).byteLength}:${value}`).join("");
  return sha256Hex(identity);
}

async function apnsResponseReason(response: Response): Promise<string | undefined> {
  const reader = response.body?.getReader();
  if (!reader) return undefined;
  const chunks: Uint8Array[] = [];
  let count = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (count > 8 * 1024 - value.byteLength) {
      await reader.cancel();
      return undefined;
    }
    count += value.byteLength;
    chunks.push(value);
  }
  const joined = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    const value = JSON.parse(new TextDecoder().decode(joined)) as { reason?: unknown };
    return typeof value.reason === "string" && value.reason.length <= 128
      && machineTokenPattern.test(value.reason) ? value.reason : undefined;
  } catch {
    return undefined;
  }
}

function normalizedAPNSID(value: string | null): string | null {
  if (!value || value.length > 128 || !machineTokenPattern.test(value)) return null;
  return value;
}

function boundedEnum<Value extends string>(value: unknown, accepted: Set<Value>): Value {
  if (typeof value !== "string" || !accepted.has(value as Value)) invalid("enum value is invalid");
  return value as Value;
}

function machineToken(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.length === 0
    || new TextEncoder().encode(value).byteLength > maximumBytes
    || !machineTokenPattern.test(value)) invalid(`${name} is invalid`);
  return value;
}

function optionalMachineToken(value: unknown, name: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  return machineToken(value, name, 512);
}

function configuredToken(value: string | undefined, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.length === 0
    || new TextEncoder().encode(value).byteLength > maximumBytes
    || !machineTokenPattern.test(value)) {
    throw new HttpError(503, "serviceConfiguration", `${name} is invalid`);
  }
  return value;
}

function safeText(value: unknown, name: string, maximumBytes: number): string {
  if (typeof value !== "string" || value.trim().length === 0
    || new TextEncoder().encode(value).byteLength > maximumBytes
    || /[\u0000-\u001f\u007f]/u.test(value)) invalid(`${name} is invalid`);
  return value;
}

function requiredObject(value: unknown, name: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) invalid(`${name} is invalid`);
  return value as Record<string, unknown>;
}

function truncateUTF8(value: string, maximumBytes: number): string {
  if (new TextEncoder().encode(value).byteLength <= maximumBytes) return value;
  let result = "";
  for (const character of value) {
    if (new TextEncoder().encode(`${result}${character}…`).byteLength > maximumBytes) break;
    result += character;
  }
  return `${result}…`;
}

function invalid(message: string): never {
  throw new HttpError(400, "invalidPush", message);
}
