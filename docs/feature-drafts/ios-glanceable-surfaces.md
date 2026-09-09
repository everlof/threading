# Glanceable iOS surfaces

> Draft, reviewed 2026-09-08. The first usage implementation now has an embedded widget target,
> App Group cache, owner-only capacity endpoint and phone publisher. The
> [implementation notes](../architecture/ios-glanceable-surfaces.md) describe what exists and its limits.
> ActivityKit delivery and comparative visual spikes remain proposed work. The recorded August
> simulator findings at the end are historical evidence, not current device verification.

## Product scope

Build usage widgets for the Home Screen and Lock Screen, followed by a Live Activity for one
agent's current turn. Widgets answer how much capacity an account has used and when its window
resets. The Live Activity answers whether work is ongoing, needs input or has finished, with a
short completion preview when enabled.

One WidgetKit extension hosts both presentations. The first widget reads a snapshot written by
the phone. The Live Activity receives ActivityKit push updates from the Mac, directly or through
the hosted broker. These are different update mechanisms even though they share an extension.

Sessions widgets, permission buttons, push-to-start for work begun on the Mac, controls and other
platforms remain follow-ups. Permission review opens the authenticated chat. The earlier question
about inline Allow remains open; implementing either Allow or Deny is not a prerequisite here.

The first usage slice covers capacity and reset times. Cost history and banked-reset actions
remain in the Usage screen. They need different data and should not turn a glance into a dashboard.

## Existing hooks and missing work

| Area | Verified source | Required addition |
| --- | --- | --- |
| Usage truth | `AccountUsage.observedAt` records API fetch time or the provider cache's observation time | Preserve that provenance across the compact remote projection |
| Compact usage | `RemoteAccountBridge.usageWindows` supplies `RemoteAccountChoiceDTO.usageWindows`, with fraction, reset, duration and model scope | Carry observation time and a typed reading state; do not parse `usageSummary` or publish raw `usageError` |
| Usage delivery | `RemoteSessionMirrorRegistry` builds account choices; `AccountUsageService` publishes `AccountUsageDidChange` | A bounded capacity response and settled-reading update path independent of opening the Usage screen |
| Phone publication | `RemoteAppModel` owns authenticated host/catalogue state | An app-owned publisher and ordered app-group writer |
| Agent lifecycle | `SessionRuntimeDidChange` owns pending-outcome transitions | A separate Live Activity coordinator sharing lifecycle truth, with its own delivery policy |
| Completion text | `CompletedTurnSnapshotStore` and `TurnCompletionPreviewFormatter` produce a bounded final-response preview | Explicit Live Activity preview consent and generation validation |
| Push | Direct and hosted notification senders already exist | Activity-token registration, rotation and separate ActivityKit envelopes in both senders |
| Navigation | `ThreadingMobileSceneDelegate` receives cold and warm URL opens in `RemoteNotifications.swift` | Typed widget/session routes admitted before saved navigation restoration |

The legacy account catalogue still omits `AccountUsage.observedAt`; the new capacity feed carries
it independently. Phone receipt time, a theme change and an unchanged conditional response cannot
renew a provider observation. The first implementation requires the `usage-capacity` feature and
shows an update requirement on older Macs. A future catalogue fallback must explicitly label an
unknown observation age rather than treating phone receipt time as provider freshness.

Account choices are not a continuous usage subscription. Building them can initiate an asynchronous
provider refresh and return the prior reading. A subsequent session-state delta does not prove that
new account windows were delivered. The implementation must test a reading that settles after the
initial response while the Usage screen remains closed.

The recommended new acquisition seam is a bounded, owner-only capacity projection from the usage
cache, with a negotiated remote feature. It returns stable account/window identities and observation
metadata without model catalogues, account images or historical charts. `AccountUsageDidChange`
updates that projection and invalidates subscribed foreground clients; coalesced clients fetch its
latest bounded revision. Reuse the authenticated transport and provider refresh/backoff owner.
A widget refresh must not create a new provider poller. Older hosts use the compact catalogue
fallback and retain its freshness limitations.

Keep capacity revision separate from session/read-receipt revision. An invalidation followed by a
response must settle to at least the newest capacity revision seen; an older response cannot mark
the projection current. See [status integrity](../architecture/status-integrity.md) and
[accounts](../architecture/accounts.md).

## Target and module structure

Add `Targets/ThreadingGlance/` as a filesystem-synchronized root for the extension. Keep its
Info.plist alongside the source folder, as `Targets/ThreadingGlance-Info.plist`, to avoid the
project's synchronized-folder resource trap. Embed the extension in `ThreadingMobile`.

Use two narrow shared modules, with names finalized during implementation:

- A Foundation-only contract in `ThreadingRemoteKit` for capacity data and agent activity content.
  Both the Mac sender and the iOS decoder must compile the same wire definitions.
- `ThreadingGlanceKit` for the snapshot store, pure freshness/selection rules, iOS ActivityAttributes
  adapter and shared mobile presentation tokens. Keep UIKit/SwiftUI code in a separate target from
  the portable store/rules target so pure tests can run on macOS. ActivityKit remains iOS-only.

Extract only the required palette, spacing, typography and environment code from
`RemoteTheme.swift` and `MobileThemeEnvironment.swift`. Do not move their connection indicators or
app-specific controls. Share the theme vocabulary without making the phone's design depend on
WidgetKit. The extension cannot depend on `RemoteAppModel`, the connection pool or app credentials.

The August spike recorded that `APPLICATION_EXTENSION_API_ONLY = YES` on an extension did not
police its local SwiftPM dependency. Add an extension-safety check over the shared dependency path,
and verify the compiler invocation again with the implementation toolchain. A source scan alone
is not proof that every linked dependency is extension safe.

Signing requires `codes.threading.mobile.glance`, the app group `group.codes.threading.mobile`,
and matching app-group entitlements/profiles on the app and extension. `NSSupportsLiveActivities`
belongs in the containing app's Info.plist. Keep the current iOS 17 deployment baseline and guard
newer APIs. The extension's first version needs the app-group capability; optional WidgetKit push
later adds its own Push Notifications capability. Existing APNs credentials must be valid for the
chosen environment and topic; never substitute the widget bundle ID for the app's ActivityKit topic.

Extend the theme, localization and SwiftLint checks to the extension and shared presentation roots.
An extension is a separate bundle and needs its own localized strings. Ordinary `scripts/ci.sh`
already builds and tests iOS; its `--mac-release` variant deliberately skips those lanes. Ensure the
mobile build embeds the new extension, add its tests to the appropriate plans, and check the signed
archive as well as the simulator build. Do not put UIKit tests in the shell's macOS `swift test` loop.

## Usage configuration and storage

A widget's identity is explicit: host, runtime, account and window. Account handles can repeat
across providers, so account name or handle alone is not a key. Renames must not retarget a widget.

For the first version, select one widget host in the phone's settings, independently of the host
currently being browsed. Each widget uses AppIntent configuration to select accounts/windows from
that host's published catalogue. A medium widget may select two accounts. Browsing another Mac
must not silently change any existing widget. Multiple widget hosts can follow after this works.

The snapshot must contain the choices offered by configuration, not just the four rows one widget
renders. Proposed bounds, to verify with the stress fixture:

| Unit | Bound and behavior |
| --- | --- |
| Snapshot | One host, up to 128 account descriptors and 256 usage windows, at most 128 KiB encoded |
| Visible content | At most four windows per widget; accessory families show fewer |
| Text | Bounded opaque identities and display labels; fixed semantic error cases |
| Theme | Only the validated roles required by the shared palette; no images or arbitrary theme assets |
| Overflow | Deterministic bounded catalogue with omitted counts; configuration offers only included records |
| Selected but missing record | Explicit unavailable state; never substitute another account |

The larger archive replaces the earlier 16 KiB/four-row proposal because multiple configured
widgets need independent data. Byte and cardinality limits both apply. Cap before decoding or
constructing views, and do not scan an unbounded input merely to return a bounded prefix. Prefer
stable keyed lookup and project changed accounts. A change of widget host is a bounded replacement.

The archive carries a schema version, publisher epoch/generation, host identity, per-reading
observation/receipt times and storage time. Usage state distinguishes known, missing, reset passed,
provider failure and unknown observation age. Fractions and dates must be finite and valid; invalid
input never becomes zero. Display labels may be shortened safely, but identity must be refused
rather than truncated into a different key.

Only the phone writes `glance-snapshot.v1.json`. Main-actor callbacks hand off bounded immutable
values to one serial writer. It compares semantic content, validates and encodes, atomically
replaces the file, and then requests affected timeline reloads. Compare before advancing storage
time/generation so repeated callbacks do not force identical writes. A later authentic observation
with the same percentage still matters because its observation time changed.

Host replacement, unpairing and authorization loss advance the publication fence before queuing
invalidation. An older worker result cannot restore removed data. Check the fence at commit and
serialize publication/invalidation; cancellation alone does not prove a write was prevented.
Ordinary network loss retains labelled cached readings. Known loss of authorization invalidates
them. The system may retain rendered snapshots until it refreshes; do not promise immediate erasure
of pixels already displayed by iOS.

Set `.completeUntilFirstUserAuthentication` on the file and replacement files explicitly. This
keeps the encrypted file readable after the first unlock, including later locked periods; before
first unlock, render unavailable. App-group access is not an unencrypted disk format.
[Apple's file-protection contract](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication)

Distinguish missing, locked, unsupported schema, corrupt and I/O failure. Preserve an unsupported
newer archive; preserve a bounded quarantine copy of corrupt data before any explicit rebuild.
If preservation fails, block replacement. The widget never repairs the store. The app may recover
this derived cache from a fresh authorized projection after preservation; it must not overwrite
user configuration or mistake corruption for an empty selection. Include failed-write/retry and
downgrade tests, following [persistence rules](../architecture/reliability-and-type-safety.md).

Do not copy whole remote DTOs into the archive. Allow only opaque identity, chosen display labels,
usage values, freshness and necessary theme roles. Exclude email, images, raw errors, credentials,
paths, commands and transcript content. A field allowlist classifies every addition. User-authored
names can themselves be sensitive, so support hidden identity/redaction without claiming sanitizing
a label makes its contents public.

## Widget freshness

Widgets show cached observations. A phone that has not fetched usage for a day cannot show today's
consumption. The first version requires no hosted service and supports direct, Tailscale and hosted
connections with the same last-observed-data contract.

Proposed display rules, evaluated per window:

| Condition | Presentation |
| --- | --- |
| Recent known observation, under 15 minutes | Value with a compact last-updated indication where it fits |
| Observation 15 minutes to 6 hours old | Value with explicit observation time |
| Observation 6 to 24 hours old | Clearly labelled cached value; keep accessible contrast |
| Over 24 hours, or no valid reading | Open Threading for a reading |
| Reset time has passed | Awaiting a new window reading; no old percentage or invented zero |
| Missing observation timestamp or invalid clock ordering | Last received/unknown freshness, never presented as current |

The smallest accessories cannot fit every label. When freshness cannot be communicated alongside
a number, replace the number with a stale/unavailable indicator and expose the detail in the
accessibility label. Do not use colour or dimming as the only freshness signal.

Use dynamic date text for a reset countdown; do not generate a timeline entry per minute. Generate
entries at reset and freshness transitions for the selected windows, plus a refresh request. A
four-window view needs at most 16 future boundary entries plus its initial entry for the rules
above. Evaluate truth at rendering time as well: system reload requests are not deadlines.
[Apple's widget refresh guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)

### Fresher data while the app is closed

On iOS 26+, `WidgetPushHandler` supports WidgetKit push reloads. Its notification requests a new
timeline; it does not supply usage values or guarantee that the containing app runs. A snapshot-only
provider would reread the same old file. WidgetKit push is budgeted and opportunistic.
[WidgetKit push](https://developer.apple.com/documentation/widgetkit/updating-widgets-with-widgetkit-push-notifications),
[API availability](https://developer.apple.com/documentation/widgetkit/widgetpushhandler)

The phone already has the `remote-notification` background mode for notification retraction.
That does not guarantee timely execution and does not make app-only Keychain credentials readable
while locked. An NSE or silent push is therefore not a complete freshness design either.

If fresh closed-app usage becomes a requirement, spike a narrowly authorized hosted snapshot feed:
the Mac publishes capped usage observations to the broker, a widget reload fetches only that
projection using a separate revocable read capability, and WidgetKit push signals changes on
supported OS versions. The widget must not receive the Mac bearer, open a relay or poll a sleeping
Mac. This changes the initial network-free widget contract and needs its own consent, retention,
credential-protection and device tests. It is not merely a new reload call. See
[the hosted-service draft](hosted-remote-service.md).

## Live Activity lifecycle

The initial action is Follow this turn, available while the phone is foregrounded. The user can
follow an already-running turn or opt into following a turn sent from the phone. Hold one active
Live Activity per device initially. Replacing it ends the old activity and removes its subscription;
user dismissal does not cause an automatic restart.

Register against an authenticated host/session/current pending outcome and return the canonical
initial state. If completion races the activity request or token registration, reconcile to that
terminal state immediately. Keep a turn instance stable across background continuation. A prompt
becoming ready is not completion while its pending outcome remains open.
[Notification outcome ownership](../architecture/notification-delivery.md)

Use the semantic state family: working, continuing in background, awaiting user, permission needed,
rate limited, completed, failed and stopped. Disconnected/stale describes knowledge, not a new agent
outcome. A missing process or lost connection cannot prove successful completion.

Define one shared content schema for the Mac encoder and iOS ActivityAttributes adapter. Static
attributes carry opaque route and activity-instance identity. Mutable content carries bounded
display names, semantic status, turn start time, observation time, freshness deadline and optional
completion preview. Session renaming therefore updates content without replacing the activity.
Keep elapsed-time rendering local; no push is required to tick a clock.

A subscription binds participant/device, host instance, session, turn instance, activity instance,
APNs environment, token revision and consent revision. Tokens are credentials for sending updates:
keep them in the protected registration owner, never the widget snapshot or diagnostics. Persist
only the minimal registration facts needed for reconciliation; do not persist response previews.
A process-local turn generation alone is insufficient after a Mac restart. Revalidate against the
current host instance and end unverifiable activities with an interrupted/unknown state.

After registration, the Mac is the progress writer; the phone still owns requesting and explicitly
ending the activity. Do not run independent phone and push progress writers against the same
activity without a tested ordering contract. Ending/replacing an activity also revokes its writer.

Observe token rotation, activity state and user dismissal. On phone relaunch reconcile
`Activity.activities` with authorized registrations. On Mac restart reconcile retained registrations
before sending again. Permission/sharing changes invalidate subscriptions immediately at the sender;
removal on an unreachable phone remains best-effort. An end push includes the final content state.

### Delivery, ordering and freshness

Use a separate coordinator from ordinary notification delivery. Reuse authorization, payload
validation and APNs transport, but do not inherit the notification activity-suppression window:
using the Mac must not stop updates to an explicitly followed turn.

The direct sender and hosted broker both need `apns-push-type: liveactivity`, the containing app's
`codes.threading.mobile.push-type.liveactivity` topic, and the correct token/environment. The broker
must bind the registered activity to its authorized host and recipient, validate the content and
refuse a caller-selected arbitrary topic or token. Capability negotiation lets an old broker refuse
cleanly without breaking ordinary notifications.

Serialize sends per activity. Coalesce replaceable progress states, never an end into a later
update. Recheck activity instance, token and consent revision before sending or retrying. Bound
retry state and remove invalid tokens. APNs acceptance is not proof that the phone displayed it.
The APNs `timestamp` is actual Unix time in seconds; test multiple transitions in one second,
out-of-order responses and clock changes. Admit at most one new envelope per actual second per
activity, retaining the latest state until the next admissible second; an end takes precedence.
Retries retain their original timestamp and are canceled when superseded. A backward clock jump
pauses new sends rather than inventing future timestamps; the displayed activity can become stale.
Use explicit epoch-second numeric fields for wire dates and ActivityKit's default Codable
representation. Byte-test the whole envelope and keep static plus dynamic content below Apple's
combined 4 KB limit.
[Apple's ActivityKit push contract](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)

Sending only state changes leaves a long, unchanged working state indistinguishable from a sleeping
Mac. Proposed starting policy for measurement: one priority-5 heartbeat per minute while the
followed outcome is open, with a three-minute freshness lease; semantic changes send sooner.
Heartbeats observe the bounded canonical runtime state and renew its observation time. They prove
what the host last reported, not that tokens are being generated. Waiting states renew too.

The widget extension uses `context.isStale` and the content deadline to replace a working animation
with Last reported working and an update time when the lease expires. A delayed heartbeat can
recover freshness. Tune cadence on hardware; low priority does not promise delivery within the
lease. Use higher priority sparingly for attention and terminal transitions, and avoid duplicating
existing notification alerts.

Apple permits up to eight active hours and up to four more hours of Lock Screen retention. Tracking
expiry must never say the agent finished. At the limit, show that tracking ended if a final update
can be delivered; the OS may instead end it with the last state. A stale deadline does not end an
activity by itself, and a suspended app cannot promise to run an end timer. After real completion,
propose five minutes of final-state retention, then dismissal.
[ActivityKit lifecycle limits](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)

Without an ActivityKit-capable push sender, local foreground updates can be demonstrated but do not
fulfil the pocket-status product. A configured direct APNs provider works without hosted services;
hosted users need the broker's new envelope path. Push-to-start and broadcast channels are outside
the first slice.

## Work summary and preview consent

A completion preview and an ongoing work summary are different inputs. The existing formatter
returns at most 320 UTF-8 bytes from a captured final assistant response; it is an excerpt, not a
model-generated summary of the whole turn. Reuse that source for the first completed state.

While working, use semantic status and session title. A useful sentence such as Running the test
suite needs an explicit bounded progress report with provenance and expiry. That hook does not
exist merely because completion capture exists. It can be added later without scraping terminals
or making a model call on each update. Unavailable progress stays unavailable.

Propose a device-owned Live Activity preview setting, off by default, separate from notification
preview consent. Enabling ordinary notification previews is not consent for longer-lived activity
text. Keep `completionPreview` separate from any future permission summary field. No unused
permission decision machinery is needed in the first wire contract; additive fields can follow.

Before transmission, revalidate current read authorization, activity/turn identity and preview
consent. Strip presentation/unsafe formatting and cap bytes using the existing formatter. This
formatter does not guarantee semantic removal of every secret; consent authorizes the bounded
response excerpt. Generic semantic text is the fallback. The standard ActivityKit payload contains
renderable text, so this path must not be described as end-to-end encrypted through APNs.

Disabling previews on the phone ends/removes the affected activity locally before syncing consent,
then allows a new generic activity if the user follows again. This prevents an already in-flight
preview update from restoring text to the same activity. Remote revocation sends a best-effort end
and stops future content; it cannot guarantee immediate erasure on an offline phone. Test the race
on hardware. Preview text stays out of the usage archive, logs, retries persisted to disk and
accepted-delivery ledgers. ActivityKit itself retains the displayed state for its lifecycle.

## Design spikes and customization

Use the production view models and SwiftUI views for both fixtures and the installed extension.
Run the first design comparison as soon as the usage hooks work; there is no reason to wait for
Live Activity push before reviewing usage designs.

| Surface | First comparison |
| --- | --- |
| Small Home Screen | Two compact rings versus two aligned bars for one account |
| Medium Home Screen | Two accounts side by side versus one account with more window detail |
| Circular Lock Screen | One labelled consumed fraction, with explicit stale/unknown replacement |
| Rectangular Lock Screen | Account, short/long usage and next reset versus one larger relevant window |
| Inline Lock Screen | A short account/window reading versus reset time when constrained |
| Live Activity / expanded Island | Status-led layout versus a more prominent completion preview |
| Compact / minimal Island | Agent mark and recognizable state, with elapsed time only where it fits |

Use consumed fraction consistently. Preserve model scope, unknown readings and reset expiry.
No synthetic agent progress percentage. Include long localized names, multiple providers sharing
an account handle, hidden identity, long previews, working/background/input/limit states,
completion/failure, stale data and missing authorization.

Share mobile design tokens in full-colour presentation. Use a named widget theme boundary that
respects system `containerBackground`, content margins and full-colour/accented/vibrant rendering.
Do not force the app's dark colour scheme onto monochrome accessories or assume its tint survives
system rendering. Use labels/shapes as well as colour. Review light/dark, clear/tinted iOS 26
appearance, Reduce Motion, contrast, accessibility sizes and VoiceOver.

Apply [the theme boundary](../THEME_BOUNDARY.md),
[design system](../architecture/design-system.md) and
[iOS theme ownership](../IOS_THEMED_DIALOGS.md) before implementing views.
These are deliberately host-only surfaces under the
[customization-surface gate](../extensions/CUSTOMIZATION_SURFACE_AUDIT.md#gate-for-every-new-surface).
Device configuration and shared theme tokens affect presentation. Threading keeps usage meaning,
authorization, freshness, consent, lifecycle and deep-link routing. An Apple widget extension is
not a public Threading customization extension.

## Implementation and verification

1. Add the shared capacity contract, observation metadata and app-owned publisher. Verify a
   refresh that settles after initial acquisition, without opening the Usage screen. Test old-host
   fallback, unknown values, revision gaps, reset expiry and account removal.
2. Add storage, configuration, target, signing and typed routes. Routes contain bounded opaque
   identifiers, never a bearer or host URL. Resolve them through the existing trusted host store.
   Test cold/warm opens, pending continuity restoration, missing account/session and unpairing.
3. Install the usage extension and compare the designs. Add it to the widget gallery, Home Screen,
   Lock Screen and StandBy. Capture real system containers, not only an app-hosted preview.
4. Add one-turn ActivityKit following, direct and hosted delivery, then its installed design
   fixtures. Prove token rotation, end-before-registration, same-second updates, retry reordering,
   user dismissal, restart and preview withdrawal with deterministic model/transport tests.
5. On a passcode-protected phone, verify suspended-app updates, lost connectivity, Mac sleep,
   completion and consent races without a debugger. Record actual delivery/freshness behavior.

Scaling fixture: normally 1 to 6 accounts; stress the 128-account/256-window archive limits and
2,000 unrelated sessions. Prove session count does not enter usage projection or heartbeat work.
Measure bounded background projection/encoding/I/O separately from main-actor handoff and widget
rendering. Repeated unchanged input must not write; a renewed observation must. Retain one pending
publication per publisher and one in-flight send plus latest state per activity, with fixed retry
and subscription caps. Proposed host limits are 256 registered activities, four concurrent APNs
sends, and three retries per current envelope. Refuse admission at capacity and clean up expired
registrations; a new event cannot reset a failing transport's backoff indefinitely.

Portable snapshot/selection/envelope tests run in their Mac-compatible package or Mac test target.
File protection, configuration, ActivityKit adaptation and navigation tests run in
`ThreadingMobileTests` through `scripts/test-mobile.sh`. Installed system appearance and physical
push delivery have their own evidence; the Mac fast test plan cannot verify them.

A component gallery may use the existing iOS evidence runner for iteration, but that runner alone
does not prove SpringBoard, Lock Screen or Dynamic Island behavior. Record inspected evidence on
compact and large phones and a device, with the OS/build and configuration. No runtime builds,
tests or rendered-product evidence were produced by this documentation pass.

When the first slice ships, move durable decisions into a new architecture document and add it to
CLAUDE.md. Update USER_GUIDE.md, REMOTE_ACCESS.md for the actual content/consent contract, and the
hosted-service draft for any implemented broker/feed behavior. Keep later ideas in this draft.

## Recorded platform spikes

The prior draft records these measurements from 2026-08-23: Xcode 26.5, an iPhone 17 Pro Max
simulator on iOS 26.5, using a throwaway app, widget extension and local package. They were not
repeated in this pass. The previously named `.build/glance-spike` harness was not found in this
checkout during this review; recreate it before relying on the measurements.

- Extension safety: `UIApplication.shared` in the extension source failed compilation, but the
  same API in its local package compiled, including when called by the extension. Verify the
  dependency boundary with the actual shipping toolchain.
- Interactive intents: with the app terminated, expanded unlocked Dynamic Island buttons launched
  the app process and reached `perform()` in 172 to 175 ms without foregrounding. On the simulated
  Lock Screen, taps foregrounded the app and did not run `perform()`. Both Allow and Deny were
  tried. The simulator had no passcode; this does not establish secure-device behavior.
- A first activity produced a system consent prompt. Frequent pushes were disabled without the
  corresponding Info.plist setting. These were observations of that setup, not universal timing
  or presentation guarantees.

If permission controls are resumed, first verify passcode/unlock behavior and an authenticated
reconnect through LAN, Tailscale and hosted routes. Neither the simulator timing nor the existence
of a button proves an authorized decision can complete. NSE-driven ActivityKit updates and
background-widget refresh remain separate experiments; neither is required by the initial design.
