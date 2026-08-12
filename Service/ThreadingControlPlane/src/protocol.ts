export const BOUNDS = {
  protocolVersion: 1,
  maximumEnvelopeBytes: 384 * 1024,
  maximumIdentifierBytes: 256,
  maximumCredentialBytes: 4 * 1024,
  maximumErrorBytes: 1024,
  maximumSessionLifetimeSeconds: 5 * 60,
  maximumIceServers: 8,
  maximumURLsPerIceServer: 4,
  maximumSessionDescriptionBytes: 256 * 1024,
  maximumCandidateBytes: 16 * 1024,
  maximumCandidateMidBytes: 256,
  maximumCandidatesPerPeer: 64,
  maximumSessionsPerHost: 8,
} as const;

export const kinds = [
  "hostHello",
  "hostReady",
  "deviceConnect",
  "incomingSession",
  "sessionJoin",
  "ready",
  "offer",
  "answer",
  "candidate",
  "candidatesComplete",
  "close",
  "failure",
] as const;

export type RendezvousKind = (typeof kinds)[number];

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export interface SessionDescription {
  kind: "offer" | "answer";
  sdp: string;
}

export interface IceCandidate {
  sdp: string;
  sdpMLineIndex: number;
  sdpMid?: string;
}

export interface Envelope {
  version: number;
  kind: RendezvousKind;
  hostID?: string;
  deviceID?: string;
  sessionID?: string;
  sessionToken?: string;
  expiresAt?: number;
  iceServers?: IceServer[];
  description?: SessionDescription;
  candidate?: IceCandidate;
  errorCode?: string;
  errorMessage?: string;
}

const encoder = new TextEncoder();
const knownKeys = new Set([
  "version",
  "kind",
  "hostID",
  "deviceID",
  "sessionID",
  "sessionToken",
  "expiresAt",
  "iceServers",
  "description",
  "candidate",
  "errorCode",
  "errorMessage",
]);

export class ProtocolError extends Error {}

export function parseEnvelope(message: string | ArrayBuffer): Envelope {
  const bytes = typeof message === "string" ? encoder.encode(message) : new Uint8Array(message);
  if (bytes.byteLength === 0 || bytes.byteLength > BOUNDS.maximumEnvelopeBytes) {
    throw new ProtocolError("envelope-size");
  }
  let raw: unknown;
  try {
    raw = JSON.parse(
      new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes),
    );
  } catch {
    throw new ProtocolError("invalid-json");
  }
  if (!isRecord(raw) || Object.keys(raw).some((key) => !knownKeys.has(key))) {
    throw new ProtocolError("unknown-field");
  }
  const envelope = raw as unknown as Envelope;
  validateEnvelope(envelope);
  return envelope;
}

export function encodeEnvelope(envelope: Envelope): string {
  validateEnvelope(envelope);
  const encoded = JSON.stringify(envelope);
  if (encoder.encode(encoded).byteLength > BOUNDS.maximumEnvelopeBytes) {
    throw new ProtocolError("envelope-size");
  }
  return encoded;
}

export function validateIdentifier(value: unknown): value is string {
  return typeof value === "string"
    && encoder.encode(value).byteLength > 0
    && encoder.encode(value).byteLength <= BOUNDS.maximumIdentifierBytes
    && /^[A-Za-z0-9._:-]+$/.test(value);
}

function validateEnvelope(value: Envelope): void {
  if (value.version !== BOUNDS.protocolVersion || !kinds.includes(value.kind)) {
    throw new ProtocolError("version-or-kind");
  }
  for (const id of [value.hostID, value.deviceID, value.sessionID]) {
    if (id !== undefined && !validateIdentifier(id)) throw new ProtocolError("identifier");
  }
  if (value.sessionToken !== undefined && !validateSecret(value.sessionToken)) {
    throw new ProtocolError("session-token");
  }
  for (const text of [value.errorCode, value.errorMessage]) {
    if (text !== undefined && (!nonEmptyString(text) || byteCount(text) > BOUNDS.maximumErrorBytes)) {
      throw new ProtocolError("error-field");
    }
  }
  if (value.expiresAt !== undefined && (!Number.isSafeInteger(value.expiresAt)
    || value.expiresAt <= Date.now() - 5000
    || value.expiresAt > Date.now() + (BOUNDS.maximumSessionLifetimeSeconds + 5) * 1000)) {
    throw new ProtocolError("expiry");
  }
  if (value.iceServers !== undefined) validateIceServers(value.iceServers);
  if (value.description !== undefined) validateDescription(value.description);
  if (value.candidate !== undefined) validateCandidate(value.candidate);

  const noPayload = value.sessionToken === undefined && value.expiresAt === undefined
    && value.iceServers === undefined && value.description === undefined
    && value.candidate === undefined && value.errorCode === undefined
    && value.errorMessage === undefined;
  const noSignalIdentity = value.hostID === undefined && value.deviceID === undefined
    && value.sessionToken === undefined && value.expiresAt === undefined
    && value.iceServers === undefined && value.errorCode === undefined
    && value.errorMessage === undefined;

  let valid = false;
  switch (value.kind) {
    case "hostHello":
    case "hostReady":
      valid = value.hostID !== undefined && value.deviceID === undefined
        && value.sessionID === undefined && noPayload;
      break;
    case "deviceConnect":
      valid = value.hostID !== undefined && value.deviceID !== undefined
        && value.sessionID === undefined && noPayload;
      break;
    case "incomingSession":
      valid = value.hostID !== undefined && value.deviceID !== undefined
        && value.sessionID !== undefined && value.sessionToken !== undefined
        && value.expiresAt !== undefined && value.iceServers === undefined
        && value.description === undefined && value.candidate === undefined
        && value.errorCode === undefined && value.errorMessage === undefined;
      break;
    case "sessionJoin":
      valid = value.hostID === undefined && value.deviceID === undefined
        && value.sessionID !== undefined && noPayload;
      break;
    case "ready":
      valid = value.hostID === undefined && value.deviceID === undefined
        && value.sessionID !== undefined && value.sessionToken === undefined
        && value.expiresAt !== undefined && value.iceServers !== undefined
        && value.description === undefined && value.candidate === undefined
        && value.errorCode === undefined && value.errorMessage === undefined;
      break;
    case "offer":
      valid = noSignalIdentity && value.sessionID !== undefined
        && value.description?.kind === "offer" && value.candidate === undefined;
      break;
    case "answer":
      valid = noSignalIdentity && value.sessionID !== undefined
        && value.description?.kind === "answer" && value.candidate === undefined;
      break;
    case "candidate":
      valid = noSignalIdentity && value.sessionID !== undefined
        && value.candidate !== undefined && value.description === undefined;
      break;
    case "candidatesComplete":
    case "close":
      valid = value.hostID === undefined && value.deviceID === undefined
        && value.sessionID !== undefined && noPayload;
      break;
    case "failure":
      valid = value.hostID === undefined && value.deviceID === undefined
        && value.sessionToken === undefined && value.expiresAt === undefined
        && value.errorCode !== undefined && value.errorMessage !== undefined
        && value.iceServers === undefined && value.description === undefined
        && value.candidate === undefined;
      break;
  }
  if (!valid) throw new ProtocolError("field-combination");
}

function validateIceServers(value: unknown): asserts value is IceServer[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > BOUNDS.maximumIceServers) {
    throw new ProtocolError("ice-servers");
  }
  for (const server of value) {
    if (!isRecord(server) || !Array.isArray(server.urls)
      || server.urls.length === 0 || server.urls.length > BOUNDS.maximumURLsPerIceServer
      || Object.keys(server).some((key) => !["urls", "username", "credential"].includes(key))) {
      throw new ProtocolError("ice-server");
    }
    for (const url of server.urls) {
      if (!nonEmptyString(url) || byteCount(url) > 2048
        || !/^(stun|stuns|turn|turns):/i.test(url)) throw new ProtocolError("ice-url");
    }
    for (const secret of [server.username, server.credential]) {
      if (secret !== undefined && (typeof secret !== "string" || byteCount(secret) > 1024)) {
        throw new ProtocolError("ice-credential");
      }
    }
  }
}

function validateDescription(value: unknown): asserts value is SessionDescription {
  if (!isRecord(value) || Object.keys(value).some((key) => !["kind", "sdp"].includes(key))
    || (value.kind !== "offer" && value.kind !== "answer") || !nonEmptyString(value.sdp)
    || byteCount(value.sdp) > BOUNDS.maximumSessionDescriptionBytes) {
    throw new ProtocolError("description");
  }
}

function validateCandidate(value: unknown): asserts value is IceCandidate {
  if (!isRecord(value) || Object.keys(value).some((key) => !["sdp", "sdpMLineIndex", "sdpMid"].includes(key))
    || !nonEmptyString(value.sdp) || byteCount(value.sdp) > BOUNDS.maximumCandidateBytes
    || !Number.isInteger(value.sdpMLineIndex) || (value.sdpMLineIndex as number) < 0
    || (value.sdpMLineIndex as number) > 2_147_483_647
    || (value.sdpMid !== undefined && (typeof value.sdpMid !== "string"
      || byteCount(value.sdpMid) > BOUNDS.maximumCandidateMidBytes))) {
    throw new ProtocolError("candidate");
  }
}

function validateSecret(value: string): boolean {
  const bytes = encoder.encode(value);
  return bytes.length > 0 && bytes.length <= BOUNDS.maximumCredentialBytes
    && !Array.from(bytes).some((byte) => byte < 0x21 || byte === 0x7f);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && byteCount(value) > 0;
}

function byteCount(value: string): number {
  return encoder.encode(value).byteLength;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
