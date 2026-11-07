import type { RendezvousPrincipal } from "./environment";

// Server-selected vocabulary only. Submitted field names and values never enter diagnostics.
export type FailureReason = "invalidValue" | "unknownField" | "invalidJSON" | "emptyBody"
  | "bodyNotObject" | "bodyTooLarge" | "invalidContentLength" | "outsideTimeWindow"
  | "invalidShape";

export type FailureField = "request" | "playsSound" | "soundName" | "badge" | "registrationID"
  | "deviceToken" | "environment" | "event" | "event.type" | "event.id" | "event.kind"
  | "event.hostID" | "event.sessionID" | "event.title" | "event.body" | "event.createdAt"
  | "event.turnGeneration" | "retraction" | "retraction.type" | "retraction.hostID"
  | "retraction.sessionID" | "retraction.eventID" | "retraction.kind" | "destination"
  | "destination.kind" | "destination.attachmentID" | "destination.browserTabID"
  | "destination.extensionIdentifier" | "destination.extensionPanelID"
  | "titleLocalization" | "titleLocalization.key" | "titleLocalization.arguments"
  | "bodyLocalization" | "bodyLocalization.key" | "bodyLocalization.arguments";

export interface FailureDiagnostic {
  reason: FailureReason;
  field: FailureField;
}

// Request lifetime only; never keyed by a caller-supplied ID or a credential. Set only after
// authentication, before parsing a push body, so a forged hostID cannot misattribute a failure.
const principals = new WeakMap<Request, RendezvousPrincipal>();

export function setFailurePrincipal(request: Request, principal: RendezvousPrincipal): void {
  principals.set(request, principal);
}

export function failurePrincipal(request: Request): RendezvousPrincipal | undefined {
  return principals.get(request);
}
