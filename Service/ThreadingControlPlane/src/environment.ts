export interface Env {
  DB: D1Database;
  HOST_RENDEZVOUS: DurableObjectNamespace;
  SESSION_SIGNING_SECRET: string;
  APPLE_CLIENT_IDS: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

export interface AccessPrincipal {
  accountID: string;
}

export type RendezvousPrincipal =
  | {
    kind: "host";
    accountID: string;
    hostID: string;
    credentialExpiresAt: number;
  }
  | {
    kind: "device";
    accountID: string;
    hostID: string;
    deviceID: string;
    credentialExpiresAt: number;
  }
  | { kind: "session"; accountID: string; hostID: string; sessionID: string };

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}
