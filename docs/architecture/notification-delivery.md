# Activity-aware notification delivery

Read this with [`../REMOTE_ACCESS.md`](../REMOTE_ACCESS.md), which owns the user-visible pairing,
notification and privacy contract. This note owns the implementation seams that must remain true
when routine turn-completion delivery changes.

**A public Mac build is Live only.** Push to a suspended iPhone goes through the hosted broker,
which only a development build offers (`BuildChannel.offersHostedDirect`). A release, beta or
nightly build's hosted controller has no endpoint, so `canSendHostedPush` is false and the push and
retraction sinks report unavailable; `RemoteAPNSPushSender.fromEnvironment` is compiled only into
Debug and internal builds. Every policy below still runs, and delivery reaches the phone over the
authenticated live connection alone.

## Explicit lifetimes share one activity source and transport

`RemoteNotificationKind.lifecycle` exhaustively classifies each kind as a completed turn, an
unresolved response request or an independent event. Adding a kind requires an explicit decision;
the immediate fan-out refuses state events. Completion and response lifetimes share transport
identity and provider-result types, subscription authorization and APNs/retraction senders.

`RemoteTurnNotificationDeliveryCoordinator` is the sole delivery policy for routine
`turnCompleted` events. Its clock, scheduler, activity source, target source and live, push,
retraction and diagnostic sinks are injectable so deadline and cancellation races are tested
without wall-clock sleeps. `RemoteResponseNotificationCoordinator` applies the same participant
activity source to permission requests and agent questions. Person-to-person requests and
explicitly requested agent or extension notifications keep their immediate path.

Response requests have a different lifetime from completions: unrelated Mac input extends their
deferral instead of canceling an unanswered question. Mac deactivation or the last foreground
phone detaching re-evaluates outstanding requests; the Mac deadline reads the latest shared
activity timestamp. The hot input path remains O(1). At most 256 request/device pairs (normally
1–4), including timers and in-flight delivery state, are retained. A stress fixture submits
1,000 pairs and proves the bound and cancellation of stale timers.

Only `SessionRuntimeDidChange` creates or resolves terminal questions from semantic blocker
transitions. Read-receipt and badge presentation events cannot authorize delivery.
The tracker's `awaitsUser` flag also represents a completed unread result: it is an operational
blocker only while a turn remains open. Explicit ask-tool calls retain their own lifetime even
when a turn-start report was missed. A completion or later idle-prompt notice must never create
an `agentQuestion`, and finishing off screen must resolve the previous question despite leaving
an unread badge. Shipping-service tests exercise those transitions through `AgentRuntime`.
The semantic transition out of `awaitingUser` resolves a terminal question. Native permission
cards resolve their exact permission notification before promoting the next card; process exit
clears both. App-owned browser questions use a separate internal browser scope of the same
permission-request kind, delivered only to paired owners. Resolving a native card cannot retract
an unanswered browser grant, and vice versa. Scope is internal delivery identity, not a new wire
kind or a new notification preference. Editing bytes and viewing a session do not claim to answer a request. Resolution
retracts live events and accepted pushes by exact event identity, and late APNs acceptance checks
that identity again. Authorization and activity are rechecked immediately before network I/O.

Response delivery states are pending, sending, accepted and refused. Transport errors, HTTP 429
and server failures retry after 1, 5 and 30 seconds, retaining one event identity and one timer.
Presence events cannot shorten that backoff; answering cancels it. Other HTTP refusals wait for a
registration or provider change, which can reopen a refused attempt with a fresh retry budget.
An accepted request remains unanswered until its semantic resolution, even if the user returns
while APNs is accepting it. Mac activity is sampled before dispatch; it cannot undo network I/O
that already began. State is process-local: restarting the Mac loses unresolved delivery tracking,
and the phone's session-open cleanup remains the fallback for pre-restart response alerts.

The coordinator keys pending work by session and participant and gives every completed turn a
stable generation from `CompletedTurnSnapshotStore`. Generations are allocated across the whole
process rather than restarted per session, so removing and reopening a session cannot create an
ABA match with old pending or accepted work. The store admits at most 256 sessions; pressure
evicts the oldest generation, which makes its eventual delivery fail closed. A newer turn or an accepted interaction
invalidates older pending work. A timer also carries its own token: after waking, it must still
match the pending entry and then revalidate generation, authorization, current targets and
activity before any push sink is called. Foreground live delivery does not imply APNs delivery;
the two decisions are deliberately separate.

Activating Threading is presence, not an answer for every chat this Mac holds.
`macBecameActive(at:viewing:)` resumes the owner's activity window and acknowledges only the
session on screen, which is the rule `AttentionAlertCenter` already applies to its own banners.
Routing activation through the deliberate-input path instead meant a one-second glance retracted
every accepted completion push on the phone, for chats the user never opened, while the Mac's
banners for those same chats stayed up. A push still in flight at that moment is a separate
question with an unchanged answer: the post-send activity check retracts it whichever session it
belonged to.

A target has a stable identity (share, device and participant) and mutable delivery facts
(enabled kinds, preview consent and retraction capability). The coordinator never uses equality
of the mutable facts as recipient identity. It snapshots current targets once at the deadline,
and the sender re-reads the authoritative subscription immediately before beginning network I/O.
An APNs result is revalidated again before it enters the accepted-delivery ledger.

A phone refreshes its hosted APNs recipient before registering notification preferences with the
Mac. If that refresh fails **temporarily** — a transport fault, a timeout, 408/425/429, a 5xx, or
a malformed response (`HostedPushRefreshFailurePolicy`) — the preference registration asks the Mac
to retain a previous hosted binding, and the Mac does so only for the same authorized device, APNs
token, environment and active hosted service. This lets opt-outs and sound changes take effect
without replacing a working push target with a Live-only target during an outage. A refusal from
the service, or a refresh the phone could not attempt (missing or expiring device credential,
invalid endpoint), sends no preservation request: nothing then refreshes the binding, and claiming
push delivery on it would be a receipt the phone cannot stand behind. A changed token or service,
an explicit Live-only registration, a revoked pairing, or a request that both preserves and
carries a new registration cannot reuse the old binding. Older clients omit the preservation
request and retain their original registration behavior.

`notify_user` and the Test Notification tab share `RequestedNotificationCommandService`. A send
from the tab is a new request: it allocates a fresh event identity and rechecks current recipient
permissions, Remote Access, and live or push targets. An opaque `target_ref` is resolved again on
every send, so an expired reference fails rather than silently falling back to the chat; the tab
shows such a link as expired and cannot choose it. The latest attempt per chat is kept in memory
only, and an agent's request never opens or reveals the tab — see
[mcp-and-display.md](mcp-and-display.md#requested-notification-preview).

Activity is participant-scoped. Authenticated foreground-device counts cover that participant
across this Mac's sessions. Only the owner also inherits Mac presence, bounded by the configured
Off/1/2/5/10-minute window. Presence is whether the Mac is in use, not whether Threading is in
front: `CGEventSource.secondsSinceLastEventType` answers for the whole login session without an
Accessibility or Input Monitoring grant, and the activity source reads it whenever it decides or
schedules a deadline. Measured on 11 September 2026: a prompt submitted in Threading at 13:53:01,
a switch to another app, the turn finishing at 13:53:17 with Threading in the background, and the
completion pushed at once, then retracted seven seconds later by the next keystroke in Threading.
Leaving the app therefore no longer flushes deferred work; the screen locking, the display
sleeping or the login session moving does, because a locked screen keeps its last keystroke
recent for a whole window. A flush while the Mac is still in use would reach the sender's own
activity check, which cancels rather than defers, so the coordinator flushes only when the Mac is
not in use. Deliberate input in Threading keeps its stronger meaning — the owner has seen what is
on screen — while input elsewhere only defers. Without the probe, in the test host, the app-local
monitor remains the fallback and leaving the app is the only evidence of leaving the Mac. The
AppKit callback mutates scalar state and schedules
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
only after all identifiers and the retractable kind (`turnCompleted`, `agentQuestion` or
`permissionRequest`) match.

Background APNs is advisory: iOS can delay or discard it, particularly after force-quit. Local
clearing on session open is the fallback for completion, question and permission alerts.
Global app activation and completion-preference changes clear only completion alerts: opening an
unrelated screen is not evidence that an outstanding question was answered. Retraction support
and preview consent are optional capability-registration fields, so absence retains the old
generic-alert behavior.

Each alert and its background retraction use the same APNs collapse identifier, derived from
host, session, kind and **event** identity. Different events in one session must never collide:
a late retraction of A must not replace a newer alert B in Apple's queue. Both local and hosted
senders use the same length-prefixed identity hash, covered by transport regression tests. If Apple has accepted
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

Running shells remain pending across every intervening reply, including automatic session-watch
messages. Seeing the same shell at a second `Stop` does not prove that its result is irrelevant.
The shared background-work ledger recognizes both hook `shell` and stream `local_bash` types;
only a later turn boundary without that shell can complete its outcome. The shipping-service
regression drives parsed hook reports through `AgentRuntime`, the Mac alert observer and the phone
push sender, proving silence through repeated yields and one alert after the result.

Host session watches participate in that same outcome. A watch waiting for a sibling's existing
result adds an independent typed dependency to the caller's runtime, while a watch observing a
future restart does not. The dependency survives repeated replies, idle-prompt reminders, held
notice delivery and accepted queueing, then hands off to the next foreground turn. Completion
and read-receipt consumers see the composed runtime rather than the provider's empty background
array. The shipping-service regression drives watch registration, runtime composition, Mac alert
policy and the phone sender through three interim replies and one final response.

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

Mac automatic alerts use `AttentionAlertRuntimeObserver` on the same typed runtime channel.
The observer captures the transition instead of sampling participant-specific sidebar activity
later, and revalidates it before posting. Restoring an unread receipt is presentation, not a new
alert: on 8 September 2026, 15 of 20 restart alerts had `cause=running` because the old observer
read restored badges as fresh completions. The regression drives the real runtime/read-receipt
projection, submits 1,000 presentation invalidations (normal startup: dozens of sessions), and
then proves one real completion still posts. Handling is O(1) per runtime edge with no session
scan or per-session transition cache; presentation invalidations schedule no notification work.

The activity window, automatic suppression, consent enforcement, preview bounds, authorization,
generation and deep-link validation are host-owned. The customization-surface gate classifies
these settings as deliberately host-only: extensions keep the brokered notification capability
but cannot replace or bypass delivery policy. Presentation may be customizable only after the
host has selected a valid recipient and payload.

Every transition uses the generated diagnostic vocabulary: created, deferred, replaced,
canceled, invalidated, deadline fired, revalidated, sent, refused, retracted and locally cleared.
Records use pseudonymous identifiers, generation, bounded queue and delay values, transport,
attempt/provider result, the exact HTTP status and bounded broker code, activity source,
suppression reason, and preview-present/byte-count metadata. Only a request that received no HTTP
response is recorded as `status=transport`; service rejections must not be flattened into it.
Prompts, responses, tokens, device tokens and notification bodies are forbidden.

`status=transport` is reserved for a request that received no HTTP response, so a refusal decided
on this Mac — no provider configured, a device that never registered, a registration retired with
its service, consent withdrawn or a question answered while the send was queued — carries
`status=local` and its own `failureCode` instead. `RemoteNotificationPushResult.attempted` is what
separates the two, and it also keeps the response coordinator's bounded backoff for genuine
network faults: a local refusal waits for the registration or provider change it depends on
rather than spending three retries. Flattening these into `transport` left 835 completion
refusals in the week to 8 September 2026 that could not afterwards be told from a network fault.
The durable journal line carries the same reason, status, code, transport and activity source as
the diagnostic record; before that it carried only the phase, generation, queue depth and preview
metadata, which is a count of failures rather than an account of them.

The hosted service publishes a notification protocol version beside the rendezvous protocol in
`/health` and `/ready`. Both guarded deploy verifiers require that version and prove that the push
and retraction routes exist behind host authentication. A green dependency probe from an older
Worker is therefore not sufficient to release a client with a newer notification contract.

**The number has to move with the schema, and the client has to read it.** Neither was true when
`turnGeneration` was added to the event on 4 September 2026. The broker validates a notification
against an exact key list and answers HTTP 400 `invalidRequest` for one field it has not heard
of, so every completion push to a Worker deployed before that day was refused while questions and
permission requests, which carry no such field, went on arriving: the phone looked healthy and
completions had simply stopped. The version stayed at 1 across the change, so it could not have
expressed the difference, and the Mac read neither `/health` nor `/ready`, so it could not have
asked. The version is now 2, `PeerControlPlaneClient.notificationProtocolVersion()` reads it, and
`RemoteNotificationBrokerCompatibility` reduces an outgoing event to the shape the bound broker
admits. The generation is a sender-side delivery fact that no receiver reads, so omitting it
costs a recipient nothing; the alternative cost the entire notification. An unreachable or silent
`/health` answers 0, which sends the older shape, and the answer is cached per service for ten
minutes so a push costs one request rather than two. **Adding a field to the wire event means
bumping this version in the same change**, teaching the compatibility rule which version
introduced it, and deploying every service before a client that can send it.
