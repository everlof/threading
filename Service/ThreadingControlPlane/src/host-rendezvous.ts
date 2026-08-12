import type { Env } from "./environment";
import { signRendezvousSessionToken } from "./crypto";
import {
  BOUNDS,
  ProtocolError,
  encodeEnvelope,
  parseEnvelope,
  type Envelope,
  validateIdentifier,
} from "./protocol";
import { generateIceServers } from "./turn";

type Attachment =
  | {
    role: "host-pending";
    accountID: string;
    hostID: string;
    credentialExpiresAt: number;
    connectedAt: number;
  }
  | {
    role: "host";
    accountID: string;
    hostID: string;
    credentialExpiresAt: number;
  }
  | {
    role: "device-pending";
    accountID: string;
    hostID: string;
    deviceID: string;
    credentialExpiresAt: number;
    connectedAt: number;
  }
  | {
    role: "device-waiting";
    accountID: string;
    hostID: string;
    deviceID: string;
    sessionID: string;
    expiresAt: number;
  }
  | {
    role: "device-paired";
    accountID: string;
    hostID: string;
    deviceID: string;
    sessionID: string;
    expiresAt: number;
    candidateCount: number;
    descriptionSeen: boolean;
    candidatesComplete: boolean;
  }
  | {
    role: "peer-pending";
    accountID: string;
    hostID: string;
    sessionID: string;
    expiresAt: number;
    connectedAt: number;
  }
  | {
    role: "peer-paired";
    accountID: string;
    hostID: string;
    sessionID: string;
    expiresAt: number;
    candidateCount: number;
    descriptionSeen: boolean;
    candidatesComplete: boolean;
  };

export class HostRendezvous {
  private static readonly maximumAttachedSockets = 1 + BOUNDS.maximumSessionsPerHost * 2 + 4;
  private static readonly maximumHandshakeDelayMilliseconds = 30_000;

  constructor(
    private readonly ctx: DurableObjectState,
    private readonly env: Env,
  ) {
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("threading-ping", "threading-pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const internalAction = request.headers.get("X-Threading-Internal-Action");
    if (request.method === "POST" && internalAction === "disconnect-host") {
      for (const socket of this.ctx.getWebSockets()) {
        const state = this.attachment(socket);
        if (state.role === "host" || state.role === "host-pending") {
          socket.close(4001, "Host credential rotated or revoked");
        } else {
          this.failSocket(socket, "hostOffline", "The Mac disconnected");
        }
      }
      return new Response(null, { status: 204 });
    }
    if (request.method === "POST" && internalAction === "disconnect-device") {
      const deviceID = request.headers.get("X-Threading-Device-ID");
      if (!validateIdentifier(deviceID)) return new Response("Invalid device", { status: 400 });
      for (const socket of this.ctx.getWebSockets()) {
        const state = this.attachment(socket);
        if ("deviceID" in state && state.deviceID === deviceID) {
          this.closeCounterpartIfWaiting(
            socket,
            "credentialRevoked",
            "The device credential was revoked",
          );
          this.failSocket(socket, "credentialRevoked", "The device credential was revoked");
        }
      }
      return new Response(null, { status: 204 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required", { status: 426 });
    }
    this.sweepExpiredSockets();
    const attachment = attachmentFromInternalHeaders(request.headers);
    if (!attachment) return new Response("Unauthorized", { status: 401 });
    const existing = this.ctx.getWebSockets().filter((socket) => socket.readyState === WebSocket.OPEN);
    if (existing.length >= HostRendezvous.maximumAttachedSockets) {
      return new Response("Too many signaling sockets", { status: 429 });
    }
    if (attachment.role === "host-pending") {
      for (const pending of this.sockets("host-pending")) {
        pending.close(4001, "Host connection replaced");
      }
    } else if (attachment.role === "device-pending") {
      const duplicate = existing.some((socket) => {
        const state = this.attachment(socket);
        return "deviceID" in state && state.deviceID === attachment.deviceID;
      });
      if (duplicate) return new Response("Device already negotiating", { status: 409 });
    } else if (attachment.role === "peer-pending") {
      const duplicate = existing.some((socket) => {
        const state = this.attachment(socket);
        return "sessionID" in state && state.sessionID === attachment.sessionID
          && state.role !== "device-waiting";
      });
      if (duplicate) return new Response("Session peer already connected", { status: 409 });
    }
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(attachment);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      const attachment = this.attachment(socket);
      const envelope = parseEnvelope(message);
      switch (attachment.role) {
        case "host-pending":
          this.registerHost(socket, attachment, envelope);
          break;
        case "device-pending":
          await this.beginDeviceSession(socket, attachment, envelope);
          break;
        case "peer-pending":
          await this.joinHostPeer(socket, attachment, envelope);
          break;
        case "device-paired":
          this.forwardSignal(socket, attachment, envelope, "device");
          break;
        case "peer-paired":
          this.forwardSignal(socket, attachment, envelope, "peer");
          break;
        case "host":
        case "device-waiting":
          throw new ProtocolError("unexpected-message");
      }
    } catch (error) {
      this.failSocket(socket, "invalidEnvelope", "The signaling message was invalid");
      console.warn("rendezvous_protocol_rejected", {
        reason: error instanceof Error ? error.message : "unknown",
      });
    }
  }

  webSocketClose(socket: WebSocket): void {
    this.closeCounterpartIfWaiting(socket, "connectionClosed", "Signaling peer disconnected");
  }

  webSocketError(socket: WebSocket): void {
    this.closeCounterpartIfWaiting(socket, "connectionClosed", "Signaling peer disconnected");
    try { socket.close(1011, "WebSocket error"); } catch { /* already closed */ }
  }

  private registerHost(socket: WebSocket, attachment: Attachment & { role: "host-pending" }, envelope: Envelope): void {
    if (this.pendingHandshakeExpired(attachment.connectedAt)) {
      this.failSocket(socket, "handshakeTimeout", "The host handshake timed out");
      return;
    }
    if (attachment.credentialExpiresAt <= Date.now()) {
      this.failSocket(socket, "credentialExpired", "The host credential expired");
      return;
    }
    if (envelope.kind !== "hostHello" || envelope.hostID !== attachment.hostID) {
      throw new ProtocolError("host-hello");
    }
    for (const existing of this.sockets("host")) {
      if (existing !== socket) existing.close(4001, "Host connection replaced");
    }
    const ready: Attachment = {
      role: "host",
      accountID: attachment.accountID,
      hostID: attachment.hostID,
      credentialExpiresAt: attachment.credentialExpiresAt,
    };
    socket.serializeAttachment(ready);
    socket.send(encodeEnvelope({
      version: BOUNDS.protocolVersion,
      kind: "hostReady",
      hostID: attachment.hostID,
    }));
  }

  private async beginDeviceSession(
    socket: WebSocket,
    attachment: Attachment & { role: "device-pending" },
    envelope: Envelope,
  ): Promise<void> {
    if (this.pendingHandshakeExpired(attachment.connectedAt)) {
      this.failSocket(socket, "handshakeTimeout", "The device handshake timed out");
      return;
    }
    if (attachment.credentialExpiresAt <= Date.now()) {
      this.failSocket(socket, "credentialExpired", "The device credential expired");
      return;
    }
    if (envelope.kind !== "deviceConnect" || envelope.hostID !== attachment.hostID
      || envelope.deviceID !== attachment.deviceID) {
      throw new ProtocolError("device-connect");
    }
    const host = this.sockets("host")[0];
    if (!host) {
      this.failSocket(socket, "hostOffline", "The Mac is not connected");
      return;
    }
    const hostState = this.attachment(host);
    if (hostState.role !== "host" || hostState.credentialExpiresAt <= Date.now()) {
      host.close(4003, "Host credential expired");
      this.failSocket(socket, "hostOffline", "The Mac is not connected");
      return;
    }
    const sessionCount = this.ctx.getWebSockets().filter((candidate) => {
      const role = this.attachment(candidate).role;
      return role === "device-waiting" || role === "device-paired";
    }).length;
    if (sessionCount >= BOUNDS.maximumSessionsPerHost) {
      this.failSocket(socket, "hostBusy", "The Mac has too many pending connections");
      return;
    }
    const sessionID = crypto.randomUUID();
    const expiresAtSeconds = Math.floor(Date.now() / 1000) + BOUNDS.maximumSessionLifetimeSeconds;
    const expiresAt = expiresAtSeconds * 1000;
    socket.serializeAttachment({
      role: "device-waiting",
      accountID: attachment.accountID,
      hostID: attachment.hostID,
      deviceID: attachment.deviceID,
      sessionID,
      expiresAt,
    } satisfies Attachment);
    const sessionToken = await signRendezvousSessionToken(
      attachment.accountID,
      attachment.hostID,
      sessionID,
      expiresAtSeconds,
      this.env,
    );
    host.send(encodeEnvelope({
      version: BOUNDS.protocolVersion,
      kind: "incomingSession",
      hostID: attachment.hostID,
      deviceID: attachment.deviceID,
      sessionID,
      sessionToken,
      expiresAt,
    }));
  }

  private async joinHostPeer(
    socket: WebSocket,
    attachment: Attachment & { role: "peer-pending" },
    envelope: Envelope,
  ): Promise<void> {
    if (this.pendingHandshakeExpired(attachment.connectedAt)) {
      this.failSocket(socket, "handshakeTimeout", "The session handshake timed out");
      return;
    }
    if (attachment.expiresAt <= Date.now()) {
      this.failSocket(socket, "sessionExpired", "The signaling session expired");
      return;
    }
    if (envelope.kind !== "sessionJoin" || envelope.sessionID !== attachment.sessionID) {
      throw new ProtocolError("session-join");
    }
    const device = this.ctx.getWebSockets().find((candidate) => {
      const state = this.attachment(candidate);
      return state.role === "device-waiting" && state.sessionID === attachment.sessionID
        && state.accountID === attachment.accountID && state.hostID === attachment.hostID;
    });
    if (!device) {
      this.failSocket(socket, "sessionExpired", "The signaling session expired");
      return;
    }
    const deviceState = this.attachment(device);
    if (deviceState.role !== "device-waiting" || deviceState.expiresAt <= Date.now()) {
      this.failSocket(socket, "sessionExpired", "The signaling session expired");
      device.close(4008, "Session expired");
      return;
    }
    const base = {
      accountID: attachment.accountID,
      hostID: attachment.hostID,
      sessionID: attachment.sessionID,
      expiresAt: deviceState.expiresAt,
      candidateCount: 0,
      descriptionSeen: false,
      candidatesComplete: false,
    };
    device.serializeAttachment({
      ...base,
      role: "device-paired",
      deviceID: deviceState.deviceID,
    } satisfies Attachment);
    socket.serializeAttachment({ ...base, role: "peer-paired" } satisfies Attachment);
    const ready = encodeEnvelope({
      version: BOUNDS.protocolVersion,
      kind: "ready",
      sessionID: attachment.sessionID,
      expiresAt: deviceState.expiresAt,
      iceServers: await generateIceServers(this.env),
    });
    device.send(ready);
    socket.send(ready);
  }

  private forwardSignal(
    socket: WebSocket,
    attachment: Extract<Attachment, { role: "device-paired" | "peer-paired" }>,
    envelope: Envelope,
    side: "device" | "peer",
  ): void {
    if (attachment.expiresAt <= Date.now() || envelope.sessionID !== attachment.sessionID) {
      this.failSocket(socket, "sessionExpired", "The signaling session expired");
      return;
    }
    const allowedDescription = side === "device" ? "offer" : "answer";
    const next = { ...attachment };
    switch (envelope.kind) {
      case "offer":
      case "answer":
        if (envelope.kind !== allowedDescription || next.descriptionSeen) {
          throw new ProtocolError("description-order");
        }
        next.descriptionSeen = true;
        break;
      case "candidate":
        if (!next.descriptionSeen || next.candidatesComplete
          || next.candidateCount >= BOUNDS.maximumCandidatesPerPeer) {
          throw new ProtocolError("candidate-order");
        }
        next.candidateCount += 1;
        break;
      case "candidatesComplete":
        if (!next.descriptionSeen || next.candidatesComplete) {
          throw new ProtocolError("candidate-completion-order");
        }
        next.candidatesComplete = true;
        break;
      case "close":
        break;
      default:
        throw new ProtocolError("signal-kind");
    }
    socket.serializeAttachment(next);
    const counterpartRole = side === "device" ? "peer-paired" : "device-paired";
    const counterpart = this.ctx.getWebSockets().find((candidate) => {
      const state = this.attachment(candidate);
      return state.role === counterpartRole && state.sessionID === attachment.sessionID;
    });
    if (!counterpart) {
      this.failSocket(socket, "connectionClosed", "The signaling peer disconnected");
      return;
    }
    counterpart.send(encodeEnvelope(envelope));
    if (envelope.kind === "close") {
      socket.close(1000, "Signaling complete");
      counterpart.close(1000, "Signaling complete");
    }
  }

  private closeCounterpartIfWaiting(socket: WebSocket, code: string, message: string): void {
    let state: Attachment;
    try { state = this.attachment(socket); } catch { return; }
    if (state.role === "host") {
      for (const waiting of this.sockets("device-waiting")) {
        this.failSocket(waiting, "hostOffline", "The Mac disconnected");
      }
      return;
    }
    if (state.role !== "device-waiting" && state.role !== "device-paired"
      && state.role !== "peer-paired") return;
    const counterpart = this.ctx.getWebSockets().find((candidate) => {
      if (candidate === socket) return false;
      const candidateState = this.attachment(candidate);
      return "sessionID" in candidateState && candidateState.sessionID === state.sessionID;
    });
    if (counterpart) this.failSocket(counterpart, code, message);
  }

  private failSocket(socket: WebSocket, code: string, message: string): void {
    try {
      const state = this.attachment(socket);
      const sessionID = "sessionID" in state ? state.sessionID : undefined;
      socket.send(encodeEnvelope({
        version: BOUNDS.protocolVersion,
        kind: "failure",
        ...(sessionID ? { sessionID } : {}),
        errorCode: code,
        errorMessage: message,
      }));
    } catch { /* socket may already be closed */ }
    try { socket.close(1008, message.slice(0, 120)); } catch { /* already closed */ }
  }

  private sweepExpiredSockets(): void {
    const now = Date.now();
    for (const socket of this.ctx.getWebSockets()) {
      const state = this.attachment(socket);
      if ((state.role === "host-pending" || state.role === "device-pending"
          || state.role === "peer-pending") && this.pendingHandshakeExpired(state.connectedAt)) {
        this.closeCounterpartIfWaiting(socket, "handshakeTimeout", "A handshake timed out");
        this.failSocket(socket, "handshakeTimeout", "The signaling handshake timed out");
      } else if ((state.role === "host" || state.role === "host-pending"
          || state.role === "device-pending") && state.credentialExpiresAt <= now) {
        this.closeCounterpartIfWaiting(socket, "credentialExpired", "A credential expired");
        this.failSocket(socket, "credentialExpired", "The rendezvous credential expired");
      } else if ((state.role === "device-waiting" || state.role === "device-paired"
          || state.role === "peer-pending" || state.role === "peer-paired")
        && state.expiresAt <= now) {
        this.closeCounterpartIfWaiting(socket, "sessionExpired", "The signaling session expired");
        this.failSocket(socket, "sessionExpired", "The signaling session expired");
      }
    }
  }

  private pendingHandshakeExpired(connectedAt: number): boolean {
    return connectedAt <= Date.now() - HostRendezvous.maximumHandshakeDelayMilliseconds;
  }

  private sockets(role: Attachment["role"]): WebSocket[] {
    return this.ctx.getWebSockets().filter((socket) => {
      try { return this.attachment(socket).role === role; } catch { return false; }
    });
  }

  private attachment(socket: WebSocket): Attachment {
    const value: unknown = socket.deserializeAttachment();
    if (!value || typeof value !== "object" || !("role" in value)) {
      throw new ProtocolError("missing-attachment");
    }
    return value as Attachment;
  }
}

function attachmentFromInternalHeaders(headers: Headers): Attachment | null {
  const role = headers.get("X-Threading-Principal-Kind");
  const accountID = headers.get("X-Threading-Account-ID");
  const hostID = headers.get("X-Threading-Host-ID");
  if (!accountID || !hostID) return null;
  const rawCredentialExpiry = headers.get("X-Threading-Credential-Expires-At");
  const credentialExpiresAt = Number(rawCredentialExpiry);
  const connectedAt = Date.now();
  if (role === "host") {
    return Number.isSafeInteger(credentialExpiresAt)
      ? { role: "host-pending", accountID, hostID, credentialExpiresAt, connectedAt }
      : null;
  }
  if (role === "device") {
    const deviceID = headers.get("X-Threading-Device-ID");
    return deviceID && Number.isSafeInteger(credentialExpiresAt)
      ? { role: "device-pending", accountID, hostID, deviceID, credentialExpiresAt, connectedAt }
      : null;
  }
  if (role === "session") {
    const sessionID = headers.get("X-Threading-Session-ID");
    const expiresAt = Number(headers.get("X-Threading-Session-Expires-At"));
    return sessionID && Number.isSafeInteger(expiresAt)
      ? { role: "peer-pending", accountID, hostID, sessionID, expiresAt, connectedAt }
      : null;
  }
  return null;
}
