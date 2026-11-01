# Mirror

Mirror puts the page you are working on at the Mac on the paired owner iPhone, full screen,
rendered by the phone's own WebKit. Read [`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md#mirror) for the
user-visible contract and [`../feature-drafts/mirror.md`](../feature-drafts/mirror.md) for the
phases still to build. This note owns the seams that must stay true.

Phase 1 shipped on 2026-10-31: web pages from a shared browser tab (localhost through the existing
browser tunnel, public URLs direct), the invite notification, the Live Activity, the controls and
their guide. It has not yet been measured on a physical iPhone (draft §9, Phase 0).

## Who owns what

| Piece | Where | Owns |
|---|---|---|
| Wire | `Packages/ThreadingRemoteKit/.../RemoteMirror.swift` | Frames, signals, lifetimes, the title bound |
| Mac | `Core/Remote/PhoneMirrorCoordinator.swift` | Every mirror session, phone choice, invites, the chip state |
| Mac source seam | `Core/Remote/PhoneMirrorSource.swift`, `BrowserViewController` | Navigation changes of the followed tab |
| Mac UI | `BrowserViewController` (chip, menu, overflow), `AppCommands.ID.togglePhoneMirror` | Starting, stopping, the chip |
| Phone | `MobileMirrorController.swift`, `MobileMirrorPolicy.swift` | Arrival decision, signals, the quiet offer, local invites |
| Phone stage | `MobileMirrorStage.swift`, `MobileMirrorStageOverlay.swift` | The stage window, the web swap, the controls and the guide |
| Live Activity | `ThreadingGlanceKit/MirrorActivityAttributes.swift`, `Targets/ThreadingGlance/MirrorLiveActivity.swift`, `MobileMirrorEndIntent.swift` | Return and End while the app is away |
| Broker | `Service/ThreadingControlPlane/src/apns.ts` | `mirrorInvite`, notification protocol 5 |

## Rules

**Starting asks nothing.** The click on the Mac is the consent; the phone is the owner's own
paired device. There is no prompt on either side and no arming step. What protects a phone is on
the phone: `MobileMirrorArrivalPolicy` never takes the screen of a phone in use, and the per-Mac
switch (`MobileMirrorPreferences`, on by default) refuses everything.

**"In use" is the present.** `MobileInteractionState.isInUse` is a finger on the screen, one that
left it under `recentTouchWindow` (5 s) ago, or the keyboard up — except a keyboard the system
restored within `restoredKeyboardWindow` of activation. A touch a minute ago does not count: the
click on the Mac is the newer evidence. The app's window is a `MobileInteractionWindow` so every
touch in Threading is seen.

**Arrival order matters.** Switched off → refuse. Already showing this mirror, or the person
tapped its notification or Live Activity → stage. App not active → local invite. In use → quiet
offer (`inUse`). The stage the person left (`rejoin`) → stage. Older than `freshStartWindow`
(30 s, measured on the Mac so no shared clock) → quiet offer (`waiting`). Otherwise → stage. The
quiet offer never promotes itself.

**Frame keys avoid the events envelope.** The phone's events loop decodes `session`, `revision`,
`streamID`, `sequence` and `terminal` with fixed shapes before it switches on `type`; a clash
drops the socket on every shipped phone. Mirror frames use `mirrorID` and `mirrorRevision`, and
`RemoteMirrorTests` pins it. Phone → Mac signals are ordinary `RemoteClientMessage`s with `id`
and `state`, so the host's one permissive decoder reads them.

**The phone declares itself.** `mirrorHello` after the first events frame says the phone speaks
Mirror, whether this Mac may mirror to it, and which mirror its stage still holds; a mirror the
Mac no longer runs is ended there. An older phone never says hello, so the Mac never counts it
as live. Its durable answer while suspended is its notification registration: the phone
registers `mirrorInvite` for a Mac only while that Mac's Mirror switch is on.

**Encoding stays off the main actor.** The coordinator decides on the main actor and encodes on
`PhoneMirrorCoordinator.frameQueue`, one serial worker, so frames keep their order; the phone
encodes its signals on one serial queue the same way. `scripts/check_main_actor_latency.sh` holds
the ceiling.

**The server only forwards.** `RemoteAccessServer` reaches Mirror through
`RemoteAccessServerServices.phoneMirror` (`RemotePhoneMirrorSignalling`), never a singleton, and
only for an owner device with `canManageHost` on its own events socket.

**One mirror per phone, four at most.** Starting a mirror on a phone that has one ends the old one
as `replaced`. A live mirror checks every `sourceCheckInterval` (2 s) that its tab still exists
and is shared; a private tab never mirrors. Navigation and title changes are coalesced over
150 ms into one revision.

**Web pages render on the phone.** A public URL loads directly into a non-persistent store per
mirror. A loopback origin goes through the tab's ordinary browser-tunnel grant
(`POST …/browser-tunnel`) and `MobileBrowserProxy`; the grant is renewed by asking again within
`tunnelRenewalMargin` of expiry or when the origin changes. Relay routes cannot carry it.

**A revision never blanks the page.** The next page loads into a web view behind the visible one,
waits for `document.fonts.ready` and two animation frames (bounded at 1.5 s), restores the scroll
anchor when the address is the same document, then fades the old view out over 150 ms.

**The invite is retractable.** `mirrorInvite` is the one `.expiringOffer` kind: delivered at once,
withdrawn on join, end or after 120 s. Its body names the page only with the device's preview
consent; the URL never travels through APNs or the broker. It is `time-sensitive` in the APNs
payload, which the phone honours through `com.apple.developer.usernotifications.time-sensitive`
(the *Time Sensitive Notifications* capability of `codes.threading.mobile`, enabled 2026-10-31;
without it iOS quietly delivers the invite as `active`). A broker below notification protocol 5 is never
sent one (`RemoteNotificationBrokerCompatibility.mirrorInviteVersion`), and the chip says *Open
Threading on iPhone* instead.

**Every exit returns to the screen beneath.** The stage is its own `UIWindow` above the app's; the
app's window, its sheets and any draft are untouched, and the keyboard is dismissed beneath the
stage rather than left up. The idle timer is off only while the stage is awake.

## Tests

- `RemoteMirrorTests` (wire shape, reserved keys, tolerant tokens).
- `PhoneMirrorCoordinatorTests` (start, invite consent, hold, leave, stop, away and rejoin, stale
  hello, expiry, invite withdrawal, coalescing, closed tab, phone choice, move).
- `BrowserMirrorChipTests`, `RemoteHostedServiceEnvironmentTests` (protocol-5 gate).
- `MobileMirrorPolicyTests` (arrival, in use, restored keyboard, preferences, guide, return link).
- Broker: `test/apns.test.ts` (time-sensitive, 120 s, retraction).
- Demo fixtures `mirror-guide`, `mirror-controls`, `mirror-live`, `mirror-offer` render the stage
  and the offer in a simulator without a Mac.
