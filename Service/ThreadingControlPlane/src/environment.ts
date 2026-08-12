export interface Env {
  DB: D1Database;
  ISSUE_REPORTS: R2Bucket;
  HOST_RENDEZVOUS: DurableObjectNamespace;
  AUTH_RATE_LIMITER: RateLimit;
  API_RATE_LIMITER: RateLimit;
  SOURCE_RATE_LIMITER: RateLimit;
  REPORT_RATE_LIMITER: RateLimit;
  REPORT_GLOBAL_RATE_LIMITER: RateLimit;
  REPORT_PICKUP_TOKEN?: string;
  SESSION_SIGNING_SECRET: string;
  APPLE_CLIENT_IDS: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  APPLE_TOKEN_ENCRYPTION_SECRET?: string;
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
  | {
    kind: "session";
    accountID: string;
    hostID: string;
    sessionID: string;
    sessionExpiresAt: number;
  };

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}
