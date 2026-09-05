# Activity-aware notification delivery

Read this with [`../REMOTE_ACCESS.md`](../REMOTE_ACCESS.md), which owns the user-visible pairing,
notification and privacy contract. This note owns the implementation seams that must remain true
when routine turn-completion delivery changes.

## One coordinator owns the decision

`RemoteTurnNotificationDeliveryCoordinator` is the sole delivery policy for routine
`turnCompleted` events. Its clock, scheduler, activity source, target source and live, push,
retraction and diagnostic sinks are injectable so deadline and cancellation races are tested
without wall-clock sleeps. Urgent permission requests, agent questions, person-to-person requests
and explicitly requested agent or extension notifications keep their established immediate path.

The coordinator keys pending work by session and participant and gives every completed turn a
stable generation from `CompletedTurnSnapshotStore`. Generations are allocated across the whole
process rather than restarted per session, so removing and reopening a session cannot create an
ABA match with old pending or accepted work. The store admits at most 256 sessions; pressure
evicts the oldest generation, which makes its eventual delivery fail closed. A newer turn or an accepted interaction
invalidates older pending work. A timer also carries its own token: after waking, it must still
match the pending entry and then revalidate generation, authorization, current targets and
activity before any push sink is called. Foreground live delivery does not imply APNs delivery;
the two decisions are deliberately separate.

A target has a stable identity (share, device and participant) and mutable delivery facts
(enabled kinds, preview consent and retraction capability). The coordinator never uses equality
of the mutable facts as recipient identity. It snapshots current targets once at the deadline,
and the sender re-reads the authoritative subscription immediately before beginning network I/O.
An APNs result is revalidated again before it enters the accepted-delivery ledger.

Activity is participant-scoped. Authenticated foreground-device counts cover that participant
across this Mac's sessions. Only the owner also inherits deliberate Mac interaction, bounded by
the configured Off/1/2/5/10-minute window. The AppKit callback mutates scalar state and schedules
one coalesced main-actor job; it never walks sessions or writes diagnostics synchronously.
Pending and accepted-delivery collections are bounded to 256 entries each.

## Completion text has one narrow entrance

`CompletedTurnSnapshot` is provider-neutral and process-local. Terminal-backed providers capture
the lifecycle report's final assistant message; Native chat captures the completed assistant
turn. The store retains at most one bounded 64-KiB prefix per live session and delivery performs
no transcript read, terminal scrape or model call. `TurnCompletionPreviewFormatter` returns at
most 320 UTF-8 bytes from useful plain text after presentation and unsafe-formatting removal.

Consent belongs to the receiving device and defaults off. A target without both read
authorization and registered consent gets the localized generic body. Notification text is not
part of the delivery diagnostic type, accepted-push ledger or retraction request, making those
boundaries structurally unable to log or persist a preview.

## Retraction is precise and best-effort

Only provider-accepted APNs attempts enter the bounded in-memory ledger. Its 24-hour lifetime uses
the process monotonic clock, so a wall-clock correction cannot resurrect or prematurely age an
entry. Invalidating one creates
a typed `RemoteNotificationRetractionDTO` containing opaque host, session, event and kind
identifiers. It travels over an authenticated live connection and, for capable devices, the
dedicated hosted background-push endpoint. iOS removes a delivered or pending Threading request
only after all identifiers and `turnCompleted` match.

Background APNs is advisory: iOS can delay or discard it, particularly after force-quit. Local
clearing on application activation and session open is the reliable fallback. Retraction support
and preview consent are optional capability-registration fields, so absence retains the old
generic-alert behavior.

The alert and background retraction use the same APNs collapse identifier. If Apple has accepted
but not delivered the alert, the retraction replaces it in the provider queue; if it has already
arrived, iOS removes the exact request. iOS also records a bounded 24-hour tombstone before it
queries `UNUserNotificationCenter`, preventing a late live event from recreating an alert after
the removal query won the race. Turning off turn completions or preview consent clears existing
routine completion requests locally before the compatibility registration round-trip.

The phone validates decoded notification discriminators, identifier/text bounds, destination
shape and localization cardinality before presentation or navigation. Codable conformance alone
is not treated as validation. The hosted broker independently enforces the same external-boundary
shape and binds both delivery operations to the authenticated host and opaque recipient record.

## Completion follows the outcome, not the spinner

`SessionRuntimeDidChange` carries a typed transition with foreground-turn and background-
continuation facts kept separate. A provider `Stop` can therefore end the foreground turn and
make the prompt ready without completing the pending outcome. `RemoteNotificationService` opens
one generation on `beganPendingOutcome` and sends “finished its turn” only on
`completedPendingOutcome`; the intermediate `readyWithBackgroundWork` state sends nothing. The
continuation's later automatic result turn stays in the same generation, so it produces exactly
one completion. `SessionActivityDidChange` remains the read/attention presentation channel and
cannot authorize completion delivery.

## One notification tap is one navigation transaction

iOS can describe the same response in two lifecycle places: the user-notification-center
delegate and a new scene's `connectionOptions.notificationResponse`. Both enter
`RemoteAppModel.openSessionFromNotification`, keyed by host and event id; a bounded in-memory
ledger admits the tap once, and a duplicate scene callback can only strengthen the pending
transaction to connecting-scene semantics.

That distinction preserves both navigation contracts. A notification delivered to an existing
scene is one forward push, retaining the current screen as Back's destination. A notification
that creates a scene is the scene's initial route and replaces saved continuity. The pending
intent is recorded synchronously before the root view starts its catalogue refresh, and route
restoration refuses to run while that intent is pending. After the authenticated catalogue
confirms the target, the model commits exactly one route and publishes the destination request;
if the target no longer exists, ordinary continuity restoration is allowed again.

## Ownership and diagnostics

The activity window, automatic suppression, consent enforcement, preview bounds, authorization,
generation and deep-link validation are host-owned. The customization-surface gate classifies
these settings as deliberately host-only: extensions keep the brokered notification capability
but cannot replace or bypass delivery policy. Presentation may be customizable only after the
host has selected a valid recipient and payload.

Every transition uses the generated diagnostic vocabulary: created, deferred, replaced,
canceled, invalidated, deadline fired, revalidated, sent, refused, retracted and locally cleared.
Records use pseudonymous identifiers, generation, bounded queue and delay values, transport,
attempt/provider result, activity source, suppression reason, and preview-present/byte-count
metadata. Prompts, responses, tokens, device tokens and notification bodies are forbidden.
