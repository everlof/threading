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
  REPORT_ALERT_WEBHOOK_URL?: string;
  REPORT_ALERT_WEBHOOK_TOKEN?: string;
  ISSUE_REPORTS_BUCKET_NAME?: string;
  SESSION_SIGNING_SECRET: string;
  APPLE_CLIENT_IDS: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  APPLE_PRIVATE_KEY?: string;
  APPLE_TOKEN_ENCRYPTION_SECRET?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
  PUSH_TOKEN_ENCRYPTION_SECRET?: string;
  DEVELOPMENT_AUTH_MODE?: string;
  DEVELOPMENT_ACCESS_ISSUER?: string;
  DEVELOPMENT_ACCESS_AUDIENCE?: string;
  DEVELOPMENT_ACCESS_EMAILS?: string;
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
  LOCAL_DEVELOPMENT_MODE?: string;
  LOCAL_ICE_MODE?: string;
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
