# Glanceable iOS surfaces: widgets, the Lock Screen and the Dynamic Island

> Status: draft. Nothing is implemented and no target exists. Every claim about the tree was
> verified on 2026-08-23; every claim about the platform is sourced below and marked where it is
> community evidence rather than Apple's own words. Re-check both before starting.

## Decision

Add **one** iOS widget extension to the project. It hosts the Home Screen widgets, the Lock Screen
accessory widgets and, later, the Live Activity and Dynamic Island presentation. It reads a small
versioned snapshot file written by the phone app into a shared app group, and it never opens a
network connection of its own.

Ship the Usage widget first. It needs no new push type, no new APNs work, no hosted service, and
no change to the notification content policy. It works identically for a paired-direct user, a
Tailscale user and a hosted user, because it reads what the app already fetched.

The Live Activity is a second slice with a real new dependency: a Live Activity push token
registered with the Mac and a second APNs envelope. It is still not gated on the hosted service.

The inline permission control in the Dynamic Island is a third slice, and it is the one place where
this draft deliberately does not decide. `REMOTE_ACCESS.md` currently rules out lock-screen
Allow/Deny actions; whether an inline **Allow** should exist here is a product call the owner has
chosen to leave open. So the design carries both answers from the start: the intent is a
decision-carrying intent rather than a Deny-only one, the content-state schema has a defined and
unpopulated place for the summary an Allow would need, and the difference between the two
configurations is a setting and a case, not a different shape. **Deny plus Open to review is the
shipping default.** Nothing here should have to be reworked when the choice is made either way.

## What is true today, verified 2026-08-23

- No `ActivityKit`, `WidgetKit`, app group or extension target appears anywhere in the tree. A
  repository-wide grep for `ActivityKit`, `WidgetKit`, `com.apple.security.application-groups`
  and `APPLICATION_EXTENSION_API_ONLY` returns nothing outside build output.
- `Threading.xcodeproj` holds ten native targets: two applications (`Threading`,
  `ThreadingMobile`), four command line tools (`ThreadingMCPBridge`, `ThreadingExtensionHelper`,
  `ThreadingExtensionHelperNetwork`, `ThreadingWasmExtensionRunner`) and four test bundles.
- `ThreadingMobile` is `codes.threading.mobile`, team `SMQ3E8Y57T`,
  `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, `TARGETED_DEVICE_FAMILY = "1,2"`,
  `SWIFT_STRICT_CONCURRENCY = complete`. Its entitlements file carries exactly one key,
  `aps-environment`.
- There is no `UIBackgroundModes` array. `GENERATE_INFOPLIST_FILE` plus `INFOPLIST_KEY_` settings
  carry only strings and booleans, and `Sources/ThreadingMobile-Info.plist` exists solely for the
  two array keys it needs (`NSBonjourServices`, `CFBundleURLTypes`). So the phone app has no
  background modes at all today, and a silent push cannot wake it.
- Push is Mac to Apple direct. `RemoteNotificationService.swift` signs an ES256 provider JWT and
  posts to `api.push.apple.com` with `apns-push-type: alert`, topic `codes.threading.mobile`,
  priority 10, a per kind collapse id and a per kind expiry. The whole sanitized
  `RemoteNotificationEventDTO` rides beside `aps` under an `event` key, and the payload is
  re-truncated if the encoding exceeds 4 KB. A hosted broker path exists
  (`RemoteHostedService.sendHostedPush`) that hands the same event and device token to the Worker.
- Usage already crosses to the phone as a bounded owner-only projection:
  `RemoteUsageBridge` prepares it, `RemoteUsageDashboardDTO` carries it (overview capped at
  384 KiB, limit detail at 192 KiB), `RemoteUsageDashboardView` renders it, and
  `RemoteAuthorization.canReadHostUsage` gates it. `RemoteUsageLimitSeriesSummaryDTO` is already
  almost exactly a widget row: runtime name, account name, window label, `currentFraction`,
  `resetsAt`, `bankedResetCount`, `nextBankedResetExpiresAt`.
- A second, even smaller usage projection already exists on the session catalogue.
  `RemoteAccountChoiceDTO` carries `usageSummary` (for example `5h 43% · 7d 73%`) and
  `usageFraction` (peak consumed fraction, 0 to 1). It is documented as presentation safe.
- The paired Mac's bearer credentials live in Keychain under service
  `codes.threading.mobile.remote-hosts`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
  **no** `keychain-access-groups` entitlement.
- `RemoteThemeDTO` lives in `ThreadingRemoteKit` and carries fully resolved colours, radii,
  border width, glow, text scale and typeface. The SwiftUI wrapper `RemoteThemePalette` and the
  `MobileDesign` tokens live in `Sources/ThreadingMobile/RemoteTheme.swift`; `mobileTheme(_:)`
  lives in `MobileThemeEnvironment.swift`. Neither file touches `UIApplication`, `UIScreen.main`
  or `openURL`, so both are already extension safe.
- A remote permission decision is a **WebSocket frame on a session-routed connection**, not a REST
  call. `RemoteAccessServer` checks `authorization.canApprovePermissions`, re-checks
  `authorizer.isCurrent(authorization)` on the main queue, checks `RemoteSessionAccess.isVisible`,
  and then calls `resolveRemotePermission`, which fails with `permissionNotPending` if the request
  has already been answered.
- Native permission requests are presented and queued **one at a time**
  (`permissionQueue` / `activePermissionCard`), so at most one is pending per session.

### Two content rules that this feature has to answer to

`RemoteNotificationService.swift:183`, inside `permissionRequested`:

> Tool arguments, paths and diffs belong behind authentication, not on a lock screen.

and above `activityChanged`:

> The hook/BEL layer owns detecting that state; notifications never scrape terminal text.

`docs/REMOTE_ACCESS.md` states the consequence directly:

> Permission notifications intentionally contain no command, path, tool arguments or diff on the
> lock screen, and do not offer lock-screen Allow/Deny actions; the authenticated chat remains the
> place to review the evidence.

The last clause is the one the requested Dynamic Island approve button contradicts. See
[The approve control](#the-approve-control).

## Reconciling with the hosted remote service draft

[`hosted-remote-service.md`](hosted-remote-service.md) already names widgets and Live Activities.
It specifies a **widget snapshot store**: "an opt-in, size-capped semantic projection with a
generation number and observation time. A widget reads this store rather than activating the
public relay." It lists widgets and Live Activities under "Later product slices", and its push
broker section says "ActivityKit and future WidgetKit tokens remain later slices."

What this draft assumes, explicitly:

- **The projection shape from that draft is right and is adopted here**, including the generation
  number, the observation time and the "stale data remains visibly stale when the Mac is sleeping"
  rule. This draft moves that store from the hosted service onto the phone, in an app group
  container, and treats the hosted copy as a later mirror rather than as the origin.
- **The hosted service is not required for any slice here.** That is the most useful answer this
  draft can give. A paired-direct or Tailscale user gets the Usage widget in full, and gets the
  Live Activity in full, because the phone already holds the data and the Mac already holds an
  APNs provider key in the self-hosted configuration. What a hosted service adds is push delivery
  for users who never configure `THREADING_APNS_*`, which is a distribution problem the push
  broker slice already owns, not a widget problem.
- **This draft does not re-specify the hosted control plane**, its cost model or its deployment
  gate. Where the hosted service later takes over push, the Live Activity envelope described here
  becomes one more envelope kind the Worker can sign, and nothing on the device changes.
- The hosted draft's warning is inherited verbatim: "Do not health-check every host or let widgets
  poll the Mac." This design has the widget do no network work at all, which is the strongest form
  of that rule.

## The content line, restated for a surface that is not a notification

An app group container file is readable by any process carrying the group entitlement, is
unencrypted, and by default carries `NSFileProtectionCompleteUntilFirstUserAuthentication`, which
means it is readable after the first unlock following a boot, including while the device is locked
([DEV Community](https://dev.to/konstantin_shkurko/app-groups-are-not-secure-by-default-heres-how-to-fix-that-1ii8)).
A widget rendered on a locked screen therefore has the same audience as a notification body: the
person holding the phone, whoever is standing next to them, and anyone who picks it up.

The decision, and it matches the instinct in the brief:

**May be written to the app group and drawn on a locked screen**

- account display names and agent runtime names, which already cross the wire in
  `RemoteAccountChoiceDTO` and are already drawn in the Usage sheet;
- consumed fraction, window label, reset time, banked reset count;
- measured cost and token totals for the bounded ranges the Usage projection already prepares;
- a session's `displayTitle`, which a permission push and an `awaitingUser` push already put on
  the lock screen today;
- a session's coarse `RemoteSessionActivity` (`working`, `awaitingUser`, `needsAttention`,
  `limitReached`), the project name, the agent kind, and a turn start time;
- a tool **name**, which `permissionRequested` already puts on the lock screen today;
- the resolved `RemoteThemeDTO`, which is colour values and radii and says nothing about work.

**Must never be written to the app group**

- tool arguments, filesystem paths, diffs, command lines, transcript text, prompt text, agent
  output of any kind, attachment contents, browser pixels, provider credentials, bearer tokens or
  any capability;
- anything derived by scraping terminal output, for the reason `activityChanged` already gives;
- the paired Mac's bearer, which stays in Keychain in the app's own access group. See
  [Why the widget never talks to the Mac](#why-the-widget-never-talks-to-the-mac).

The line is not new. It is the existing push line applied to a second surface with the same
audience, which is why no new policy is proposed. The one place a widget could quietly cross it is
an "activity" or "recent work" widget that wants a sentence about what the agent is doing. That
sentence would have to come from transcript text. It is a non-goal.

### One field is reserved and left empty

There is exactly one deliberate hole in the list above, and it belongs to the deferred choice about
an inline Allow. `pendingSummary` is defined in the Live Activity's content-state schema
([The recommendation](#the-recommendation)) and is **absent in every shipping configuration**.

It exists because the asymmetry in [The approve control](#the-approve-control) is real: a person can
refuse a tool knowing only its name, and cannot sensibly permit one. If an inline Allow is ever
enabled, it needs a one-line statement of what the tool would do, and a schema with nowhere to put
that would force either a protocol change or an improvised field at exactly the moment the content
question is being decided. Reserving it now keeps the later decision cheap without taking it.

Three things about it, so it cannot drift:

- **What would populate it.** The Mac, from the same structured `PermissionPolicy` classification
  that already produces the permission card, and only that. It is a *summary* of the classified
  request, not the request. It never comes from scraped terminal text, never carries a path, an
  argument, a command line or a diff fragment, and it is not the card's evidence moved outward.
- **The size cost.** 120 bytes, counted inside the 4 KB combined static plus dynamic ceiling Apple
  states. The rest of the content-state is small enough that this changes no budget. The field is
  hard-capped at write time and truncated by the Mac, never by the phone.
- **What the content line becomes if it is populated.** It becomes strictly wider than the line
  today: a locked screen would carry a sentence about a pending decision, where it currently
  carries only the tool's name. That is the substance of the deferred choice, and the reason the
  field ships absent rather than empty-but-filled-on-a-flag. Enabling it is a decision about the
  content line, taken once, in the open, and recorded where the line is recorded.

The widget snapshot has no equivalent field and gains none. This is a Live Activity concern only.

## Structure

### Targets: one, not two

**One widget extension.** Apple's own guidance is that the Live Activity UI belongs in the widget
extension: "The code that describes the user interface of your Live Activity is part of your app's
widget extension. If you already offer widgets in your app, add code for the Live Activity to your
existing widget extension and reuse code between your widgets and Live Activities"
([Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)).
The same extension hosts Home Screen widgets, the iOS 16 Lock Screen accessory families, StandBy
(a `.systemSmall` widget appears there without extra work) and, behind an availability gate, an
iOS 18 `ControlWidget`. So one target covers all three surfaces in the product goal.

**No Notification Service Extension**, for the first two slices. An NSE is only invoked for an
alert push whose `aps` carries `mutable-content: 1`
([UNNotificationServiceExtension](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)),
so it cannot participate in the ActivityKit path at all, and the two things it might buy on the
widget path are both weak:

- *Writing a fresher snapshot at notification time.* The push payload already carries the
  sanitized `RemoteNotificationEventDTO`, so an NSE could project it into the snapshot with no new
  exposure. But it can only tell the widget to redraw by calling `WidgetCenter`, and multiple
  Apple Developer Forums threads report that reloading a timeline from an NSE or from a background
  push does not reliably take effect when the app is not in the foreground
  ([thread 669736](https://developer.apple.com/forums/thread/669736),
  [thread 652946](https://developer.apple.com/forums/thread/652946),
  [thread 771345](https://developer.apple.com/forums/thread/771345)). This is community evidence,
  not an Apple statement, and it is contested. The design below is built so that the answer does
  not matter.
- *Driving ActivityKit.* Does not hold. See
  [The NSE alternative](#the-nse-alternative-and-why-it-does-not-hold).

A second target therefore earns its place only if a later slice needs notification content
mutation for its own sake, for example attaching an agent mark image to a banner. Name that
requirement before adding the target.

### Where the source lives

This is the part with a real trap in it, and the trap is `Sources/`.

`Sources` is a single `PBXFileSystemSynchronizedRootGroup` (`63D8F495…`) attached to the **Mac**
target. `Sources/ThreadingMobile` is a second synchronized root group attached to `ThreadingMobile`.
Because the mobile folder is *nested inside* the Mac's group, every one of its roughly sixty files
must appear in the Mac target's `membershipExceptions` list (`project.pbxproj` around line 242) or
the Mac target tries to compile UIKit. That is a permanent per-file tax with a confusing failure
mode, and it is exactly why `Sources/ThreadingMobile-Info.plist` sits *outside* the folder. The
comment in that file records the second half of the trap:

> It sits beside the target's folder rather than inside it because a synchronized root group
> copies its own files into the bundle, and Xcode 26 cannot read a project whose exception set is
> attached to a target's own synchronized root group.

**So put extension sources outside `Sources/`.** `Targets/` already exists for exactly this: it
holds `MCPBridge`, `ExtensionHelper` and `WasmRunner`. The recommendation:

```
Targets/ThreadingGlance/            # a synchronized root group attached to the extension target
Targets/ThreadingGlance-Info.plist  # the NSExtension dict and NSSupportsLiveActivities, sibling
Targets/ThreadingGlance/ThreadingGlance.entitlements
```

Attaching a synchronized root group (rather than the plain `PBXFileReference` list the three tools
use) means a new widget source file compiles with zero `project.pbxproj` entries, matching the
direction the repository already went for `Tests/`. The Info.plist stays a sibling for the reason
quoted above.

The cost of leaving `Sources/` is that three lints are rooted there and would not see the new code:

| Lint | Current root | What must change |
|---|---|---|
| SwiftLint (`scripts/ci.sh`) | `"${repository_directory}/Sources"` | add `Targets/ThreadingGlance` |
| `check_mobile_theme_boundaries.py` | `MOBILE_SOURCE_ROOT = "Sources/ThreadingMobile"` | add the widget root; the palette rules matter more here, not less |
| `localization_boundary_lint.py` | `Sources/Threading`, `Sources/ThreadingMobile` plus their catalogues | add the widget root and its own `Localizable.xcstrings`, since an extension is a separate bundle with its own strings |

Three one-time root additions beat a permanent per-file exception list. Note that the two tools
under `Targets/` already escape all three lints today, so this change also closes an existing gap
rather than opening a new one.

**Shared code goes in a package, not in a second target membership.** A synchronized root group
belongs to one target; adding the widget to `Sources/ThreadingMobile`'s group would make the
widget compile the whole phone app. So:

`Packages/ThreadingGlanceKit` (new, `platforms: [.iOS(.v17)]`, depends on `ThreadingRemoteKit`)

- `GlanceSnapshot`: the versioned, capped record described below.
- `GlanceSnapshotStore`: the app group reader and writer.
- `RemoteThemePalette`, the `remoteTheme` environment key and `MobileDesign`, **moved** out of
  `Sources/ThreadingMobile/RemoteTheme.swift`.

That move is the honest cost of this structure and should be priced before starting.
`RemoteTheme.swift` is 688 lines and is a grab bag: it holds `MobileDesign`, a UIKit connection
indicator view, `RemoteThemePalette`, the environment key, a button style, a toggle style and
`UIColor` helpers. Only the tokens, the palette, the environment key and the colour helpers move;
the views and styles stay on the phone. Both files were checked and neither touches
`UIApplication`, `UIScreen.main` or `openURL`, so the moved code is extension safe as written.
`ThreadingRemoteKit` is Foundation only and imports no `UIApplication` either.

One build setting was a known unknown and is now measured: an extension target is built with
`APPLICATION_EXTENSION_API_ONLY = YES`, and **that does not reach a local SwiftPM package**. The
package builds and links fine, so the structure is viable, but the compiler stops policing the
extension boundary at the module edge. `ThreadingGlanceKit` therefore needs its own lint rule
forbidding extension-unsafe API, landing with the package rather than after it, and the package
should stay narrow enough that the rule has little to read. See
[spike 1](#uncertainties-and-the-spikes-that-settle-them) for the three builds that pinned it.

### The app group

| | |
|---|---|
| Identifier | `group.codes.threading.mobile` |
| Written by | the phone app only, on the main actor, through `GlanceSnapshotStore` |
| Read by | the widget extension only |
| Format | one JSON file, `glance-snapshot.v1.json`, written atomically to a temporary name and renamed |
| File protection | set explicitly to `.completeUntilFirstUserAuthentication`, never left to default and never `.complete` |
| Size cap | 16 KiB encoded, refused rather than truncated |
| Entitlement | `com.apple.security.application-groups` added to both `ThreadingMobile.entitlements` and the extension's |

The protection class is a stated decision, not a default. `.complete` would make the file
unreadable exactly when a Lock Screen widget wants to draw it;
`.completeUntilFirstUserAuthentication` is what makes a Lock Screen widget possible at all, and it
is also precisely why the content line above is the notification line and not something looser.

Write the store the way `MobileSessionContinuityStore` is written, because that pattern is already
proven here: a versioned archive, explicit byte and cardinality caps, a `writesAllowed` flag that
latches false on an unreadable record, and a quarantine copy kept rather than an overwrite. A
corrupt snapshot must produce a widget that says it has nothing, never a widget that draws a
previous generation as current.

**No `UserDefaults(suiteName:)` for the snapshot.** A shared defaults suite is the same
readability and the same disk, with less control over size, atomicity and protection class, and
`UserDefaults.didChangeNotification` does not cross into an extension anyway
([forums thread 722386](https://developer.apple.com/forums/thread/722386)). A file with an
explicit format is the smaller contract.

### Signing and provisioning

Owned by [`releasing.md`](../architecture/releasing.md); this section states only what changes.

- The extension gets its own bundle identifier, `codes.threading.mobile.glance`. Apple requires an
  extension identifier to be prefixed by its containing app's.
- Both identifiers need App IDs carrying the App Groups capability, and the group
  `group.codes.threading.mobile` must be registered and enabled on both.
- Live Activities need no separate capability, but the ActivityKit push topic
  `codes.threading.mobile.push-type.liveactivity` is served by the **same** APNs key. No second
  `.p8`, no second `THREADING_APNS_*` variable.
- Automatic signing already covers the mobile target. `releasing.md` records the rule that
  matters: automatic signing "cannot create or download the matching profile from a command-line
  archive unless `-allowProvisioningUpdates` is present". Adding an extension adds a second
  profile to that set, so any unattended iOS archive lane must install both.
- `APS_ENVIRONMENT` is set per configuration on the app. The extension does not need it. The
  extension's entitlements file holds the app group and nothing else.
- The iOS app is not part of `scripts/ci.sh` today, which builds and tests the Mac plan and the
  packages. Adding an iOS target does not change that, but the new package `ThreadingGlanceKit`
  should join the `for package in …` loop so its tests run in CI.

### How the theme crosses into the widget

This is the same failure the phone half of the boundary already documents. `docs/IOS_THEMED_DIALOGS.md`:

> A sheet is its own hosting scene and inherits neither `remoteTheme` nor the presentation values
> read from it.

A widget extension is that failure taken further: a separate process, a separate launch, no
`RemoteAppModel`, no connection, and no environment to inherit from. The mechanism that already
solves it for sheets solves it here, and it must be the same mechanism rather than a second one.

1. `RemoteThemeDTO` is already a `Codable` value carrying **resolved** colours. `RemoteThemePalette`
   is a pure function of it. So the snapshot carries the `RemoteThemeDTO` verbatim, and the widget
   constructs `RemoteThemePalette(snapshot.theme)` exactly as the phone constructs it from
   `model.me?.theme`.
2. The widget's root view applies `mobileTheme(_:)`, the same modifier that states all five values
   together (palette, colour scheme, accent tint, toggle style, label colour). The mobile theme
   checker's rule that a bare `environment(\.remoteTheme,)` outside `MobileThemeEnvironment.swift`
   is an error must be extended to the widget root, not exempted from it. This is the rule with the
   worst failure mode of the three and the one most likely to be forgotten in a new process.
3. `MobileDesign.Spacing` and `MobileDesign.Size` come with the palette. A widget must not
   introduce its own scale.
4. A snapshot with no theme, or a snapshot the widget cannot read, falls back to
   `RemoteThemePalette(nil)`, which is the built-in dark palette the phone already ships. The
   fallback must be visibly the fallback, not an approximation of the user's theme.

Two things the widget cannot have, and should not pretend to: the widget's own background is drawn
by `containerBackground`, which the system may tint or remove entirely depending on placement, and
a theme glow will not survive a Lock Screen accessory family's monochrome rendering. Treat both as
platform chrome inside a named boundary, the way `THEME_BOUNDARY.md` already treats system chrome,
rather than fighting them.

## The data path

### Why the widget never talks to the Mac

Three verified reasons, any one of which is sufficient.

1. **The credential is unreachable.** The paired Mac's bearer is in Keychain with
   `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and no `keychain-access-groups` entitlement. The
   extension has a different bundle identifier and therefore a different default access group, so
   it cannot read the item at all; and even with a shared group, `WhenUnlockedThisDeviceOnly`
   means the item is unreadable while the device is locked, which is the exact moment a Lock
   Screen widget draws. Adding a shared keychain group to make a widget able to authenticate would
   be moving an interactive-session credential into a process that runs unattended. Do not.
2. **The Mac may be asleep or off the network.** A widget that has to reach a sleeping laptop
   fails most of the time, and its only honest rendering of that failure is the stale state it
   would have drawn anyway.
3. **It is the hosted draft's own rule.** "Do not health-check every host or let widgets poll the
   Mac."

So the widget's entire input is the snapshot file. This also means the widget needs no network
entitlement, no Local Network grant question, and no TLS pin evaluation, which removes an entire
class of security surface from a process that runs unattended on a locked device.

### Who writes the snapshot, and when

The phone app writes it, and only the phone app. Every write is a projection of data the app has
already fetched and already authorized:

| Trigger | What is refreshed |
|---|---|
| App becomes active | everything the app currently holds |
| The session catalogue delta arrives on the live socket | session states, attention counts |
| The Usage sheet completes a fetch | usage rows |
| The theme update frame arrives | the `RemoteThemeDTO` |
| App resigns active | one final write, so the last thing the widget shows matches the last thing the user saw |

After a write, the app calls `WidgetCenter.shared.reloadTimelines(ofKind:)`. Apple documents that a
reload requested while "the widget's containing app is in the foreground" does not consume the
refresh budget
([Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)),
which is the common case here.

A **fourth**, optional trigger is push. Two options were considered and both are demoted to
opportunistic:

- A `content-available` silent push would require adding the `remote-notification` background
  mode, which the app does not have today, and silent pushes are delivered at the system's
  discretion.
- An NSE writing the snapshot at notification time works in principle but its ability to make the
  widget redraw is contested by the forum evidence cited above.

Neither is in the freshness contract. If a spike shows the NSE path is reliable, it becomes a
strict improvement with no design change, because the snapshot format does not care who wrote it.

### Freshness, stated as a number

The snapshot carries `generation` (monotonic), `observedAt` (when the Mac observed the values) and
`writtenAt` (when the phone wrote the file). The widget never claims to be fresher than
`observedAt`.

| Age of `observedAt` | What the widget draws |
|---|---|
| under 15 minutes | the values, with no timestamp |
| 15 minutes to 6 hours | the values, with "as of 14:32" in the theme's secondary label |
| over 6 hours | the values dimmed to the tertiary label, with "last seen 06:10" |
| over 24 hours, or no snapshot | an explicit empty state naming the app, never a zero and never a stale number presented as current |

**The contract: a Usage widget is at most as fresh as the last time the app was open, and it says
so past 15 minutes.** For a phone that opens Threading once a day, the reading is a day old and
labelled a day old. That is an honest and useful surface for weekly limit windows, and it is a bad
one for a per-minute progress reading, which is what the Live Activity is for.

The one number the widget computes itself, and can therefore keep exact with zero refreshes, is
the **countdown to `resetsAt`**. It is arithmetic on a timestamp in the snapshot, so a timeline can
carry entries at the minute boundaries that matter and be correct at each one without any new data.
This is why the Usage widget survives the platform's reload budget rather than fighting it: the
value that changes fastest is the one that needs no reload.

### Scaling gate

Applying the gate from `CLAUDE.md`. The externally sized inputs are the account and window series
(the Usage projection already bounds these at 256 account/window series) and the session catalogue
(unbounded in principle; the phone's dashboard already virtualizes it).

| Question | Answer |
|---|---|
| Expected and stress cardinality | expected 1 to 6 limit series and 1 to 30 sessions; stress 256 series and 2,000 sessions, matching the caps the Usage projection and the session catalogue already state |
| What is O(1) | everything the widget does. The widget reads one file, decodes a fixed-shape record and renders a fixed number of rows |
| The cap, before construction | **the snapshot holds at most 4 limit rows and at most 3 session rows**, chosen on the Mac's ordering rules by the app at write time, plus integer counts of what was omitted. A widget is 155 by 155 points at its smallest; more rows than that is not a smaller number, it is illegible |
| Bound the scan, not just the output | the app selects those rows from data it already holds in memory for the dashboard it is already drawing. No new query, no new fetch, no filesystem or process work |
| Encoded ceiling | 16 KiB, refused rather than truncated, checked before the write |
| Timeline entries | a fixed small number, currently the next four countdown boundaries plus one staleness transition. Never one entry per data row, and never a timeline whose length depends on the data |
| High-frequency callbacks | the session catalogue delta is O(changed) on the phone already. The snapshot write is coalesced: at most one write per second, and a write is skipped entirely when the projected record is byte-identical to the one on disk |
| Live Activity content state | 4 KB combined static plus dynamic, which is Apple's cap, and one Live Activity per session with a hard ceiling of one concurrent activity in the first slice. The reserved `pendingSummary` costs 120 bytes of that ceiling if it is ever populated, and is measured against the cap in tests whether or not it ships |
| Stress fixture | a deterministic `THREADING_MOBILE_DEMO=glance-*` family, matching the existing demo mode convention, driving the real store and the real widget views at both expected and stress cardinalities |

The write path is the one place a regression could hide, because it runs on the main actor inside a
frequent socket callback. Measure it: encode plus atomic write at the 16 KiB ceiling, and the
skip-if-identical path, which is the one that actually runs most of the time.

## Live Activities

### The delivery model, from Apple's documentation

The brief's claim is **confirmed**. Apple's
[Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications)
specifies:

- `apns-push-type: liveactivity`, and `apns-topic: <bundleID>.push-type.liveactivity`.
- an `aps` payload carrying `timestamp`, `event` (`start`, `update` or `end`), `content-state`,
  `attributes` and `attributes-type` (start only), `stale-date`, `dismissal-date`,
  `relevance-score`, `alert`, and on iOS 18 `input-push-token` and `input-push-channel`.
- "When the system receives the ActivityKit push notification on a device, it starts a new Live
  Activity, wakes up your app, and grants it background runtime to allow you to download assets
  that the Live Activity needs."
- an update budget: priority 5 does not count against it, priority 10 does, and
  `NSSupportsLiveActivitiesFrequentUpdates` in `Info.plist` raises it, with
  `ActivityAuthorizationInfo.frequentPushesEnabled` reporting whether the user has turned frequent
  updates off.

The page describes **no** notification service extension, and an NSE is only invoked for an alert
push carrying `mutable-content: 1`. So `aps.content-state` reaches ActivityKit as plaintext through
APNs, readable by Apple in transit exactly as an alert body is. **Whatever goes in `content-state`
is subject to the same line as a notification body**, which is the whole reason the content section
above exists.

Also fixed by the platform, from
[Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities):
an activity runs at most 8 hours and stays on the Lock Screen at most 12 hours total; static plus
dynamic data cannot exceed 4 KB combined; the user can turn Live Activities off per app and the app
must check `ActivityAuthorizationInfo().areActivitiesEnabled`; and `NSSupportsLiveActivities` must
be `YES` in the app's `Info.plist`.

The 8 hour ceiling is worth stating as a product fact rather than a footnote: an agent session that
runs overnight will lose its Live Activity, and the surface must end gracefully with a final state
rather than vanishing mid-turn.

### The NSE alternative, and why it does not hold

The brief proposes: an alert push with `mutable-content`, an NSE that fetches real state over the
authenticated channel and calls `Activity.update` itself, so Apple sees a wake-up rather than the
content. It is a good idea and the evidence says it does not work.

- `Activity.activities` is reported empty in extension processes. The Apple Developer Forums thread
  [Can Live Activities be updated via `activity.update` in extensions?](https://developer.apple.com/forums/thread/735382)
  is exactly this question; the resolution was that the developer's intent had to be added to the
  **app** bundle so the update ran in the app's process instead. Secondary sources describe the
  same behaviour as an extension sandbox constraint.
- Apple's own documentation never describes an extension calling `Activity.update`, and describes
  ActivityKit push as the mechanism for remote updates.
- This is **community evidence plus documentary silence**, not an Apple statement. It is strong
  enough to plan against and not strong enough to close the question. See
  [Spikes](#uncertainties-and-the-spikes-that-settle-them).

There is a second, independent reason the NSE route buys less than it appears to. Apple lists
`alert` as **required** when starting a Live Activity by push. A start push therefore carries a
user-visible title and body through APNs no matter what, so routing the *content* around Apple
while routing the *alert* through it protects the smaller half.

And the freshness cost is exactly what the brief anticipates: an NSE runs only when an alert is
actually delivered, so it yields at most one activity update per user-visible notification. That
suits a state transition (a turn started, a permission is waiting, the turn finished) and is
useless as a progress ticker. Since those transitions are precisely what the Live Activity should
show, the freshness cost is not the reason to reject it. The reason is that it does not work.

### The recommendation

Use ordinary ActivityKit push, and hold the `content-state` to the notification content line.

```
content-state = {
  state:          "working" | "awaitingUser" | "needsAttention" | "limitReached",
  startedAt:      <unix seconds, so the Dynamic Island can run its own timer>,
  pendingID:      <the permission request id the decision frame expects, or absent>,
  pendingTool:    <tool name, or absent>,
  pendingSummary: <reserved, always absent in every shipping configuration; see below>,
  agentKind:      "claude" | "codex" | "grok" | "opencode"
}
attributes      = { sessionTitle, projectName, hostID, sessionID }
```

`sessionTitle` already crosses APNs today in both the permission push and the `awaitingUser` push,
so this adds no category of exposure. `pendingTool` is the same field
`permissionRequested` already sends. `pendingID` is an opaque request id, not content; it is what
lets the decision-carrying intent name the exact request rather than "whatever is pending", which
is what makes an already-answered request fail cleanly with `permissionNotPending` instead of
resolving something else. Nothing else is added, and the fact that the Dynamic Island can render
elapsed time from `startedAt` alone means no ticking update is needed for the one value that
changes continuously.

`pendingSummary` is the reserved hole described in
[One field is reserved and left empty](#one-field-is-reserved-and-left-empty): defined here so the
schema can express it, 120 bytes when it exists, and encoded by nothing in any configuration that
ships. A decoder must treat its absence as normal rather than as a degraded payload.

Delivery follows the existing push path with a second envelope:

- the phone registers the activity's push token, and on iOS 17.2 and later its
  `pushToStartToken`, over the **existing** `RemoteNotificationRegistrationDTO` channel, which
  already carries a device token and an authorization;
- the Mac posts to the same `api.push.apple.com` with the same `.p8`, changing only the topic
  suffix, `apns-push-type` and the envelope shape in `RemoteAPNSPushSender`;
- updates ride priority 5 by default, so they do not consume the budget, and priority 10 is
  reserved for the transition into `awaitingUser` or `needsAttention`, which is the one the user
  is actually waiting for;
- `stale-date` is set to the point past which the phone should stop believing the state, which
  makes a Mac that went to sleep mid-turn draw as stale rather than as still working. This is the
  same rule as the widget's staleness contract, expressed in the platform's own field.

`RemoteProtocol` handling follows rule 1 in `releasing.md`: a new optional token field on the
registration DTO and a new optional notification kind are additive and bump nothing.

Note the iOS 17.0 deployment target. `pushToStartToken` is iOS 17.2 and later and needs an
availability gate, and the token has been reported unreliable to obtain on iOS 17 specifically
([Christian Selig, server-side Live Activities](https://christianselig.com/2024/09/server-side-live-activities/)).
Without it, an activity can only be started by the app in the foreground, because
`Activity.request` throws `ActivityAuthorizationError.visibility` from the background. So the
honest first version is: **the user starts the Live Activity by sending a turn from the phone**,
and push keeps it updated afterwards. Push-to-start, which would let a turn started on the Mac
raise an activity on a phone in a pocket, is the follow-up.

### The approve control

This is the piece that touches an existing decision, and the decision is deliberately left open.
What follows is therefore a structure, not an answer: it has to be equally correct whichever way
the inline Allow question lands, and nothing below may quietly settle it.

**What the platform allows, verified.** From
[Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities):

> By default, the system runs the app intent in the same process as the widget extension.

> However, if the app intent's `openAppWhenRun` property is `true`, or if the intent conforms to
> `AudioPlaybackIntent`, `ForegroundContinuableIntent`, `LiveActivityIntent`, or
> `PushToTalkTransmissionIntent`, the system performs the app intent in the app's process.

> If you adopt the `LiveActivityIntent` or `AudioPlaybackIntent` protocol, the system runs the app
> intent in the app's process. Make sure to add your custom app intent to your app target.

So: **the intent adopts `LiveActivityIntent` and is a member of the app target, and it therefore
runs in the phone app's process.** That is the only arrangement that can work here, because the
widget extension cannot read the Keychain credential and has no connection machinery.

**It is one decision-carrying intent, not a Deny button.** The type is
`ResolvePermissionIntent(hostID:sessionID:requestID:decision:)`, where `decision` is the same
`allow` or `deny` the server already accepts on the existing frame. Both cases exist in the type
from the first line of code; which case a given build *offers* is a setting read at render time,
not a property of the intent. This is the part that has to be right on day one, because the
alternatives all foreclose something:

- a `DenyPermissionIntent` with no decision parameter would make adding Allow a new intent type,
  and an intent type is a shipped identity that Shortcuts, Siri and the system's own
  intent index remember;
- putting the decision in the *view* rather than the intent would put an authority-bearing choice
  in the widget extension's process, which is the one place it must not be;
- a Deny-only intent that later grows an `allow` case is a widened intent, and widening one that
  has already shipped is the change most likely to want a different process arrangement.

Adding inline Allow must therefore be: populate `pendingSummary`, flip a setting, render a second
button. Not a reshaped intent, not a second intent type, not a different process.

**Which scope check it lands on.** The intent must not open a new authority path. It sends the
existing permission decision frame on a session-routed authenticated connection, which means it
lands on `RemoteAccessServer`'s existing checks unchanged:

1. `authorization.canApprovePermissions`, which is false for a guest, false for a view-only
   capability and false for a project terminal scope;
2. `authorizer.isCurrent(authorization)` re-checked on the main queue, so a revoked share fails
   even if the phone still holds the bearer;
3. `RemoteSessionAccess.isVisible` for the session;
4. `resolveRemotePermission`, which refuses with `permissionNotPending` if the card was already
   answered on the Mac or elsewhere.

The failure the brief asks to design out (a button approving a tool for a session the holder is not
scoped to) is designed out by *not adding a route*. The intent is a second caller of the frame the
phone's permission card already sends. The test that pins this is a negative one: a guest-scoped
authorization sending the frame from the intent path receives `forbidden`, and the Live Activity is
never started for a session the device's authorization does not cover in the first place.

**The execution budget.** The intent runs in the app process while the app is suspended, in a short
system-granted window. A cold pairing handshake will not fit: TLS pin evaluation, hosted ICE
negotiation and a fresh capability exchange are all far too slow. So the contract has to be
"resume, do not pair". The button is offered only when the app holds a warm route to that host, and
when it does not, the control degrades to **Open to review**, which deep-links into the chat exactly
as a notification tap does today. A control that silently does nothing when the Mac is unreachable
is worse than no control. It must report the failure into the activity.

**The open question, and the reasoning around it.** `REMOTE_ACCESS.md` says permission
notifications "do not offer lock-screen Allow/Deny actions; the authenticated chat remains the place
to review the evidence." An inline Allow is that rule reversed. Whether to reverse it is a product
call, and it is one David has deliberately deferred. This draft does not take it.

What the draft does record is the reasoning that will be in front of whoever takes it. Read the
existing rule's stated reason rather than the rule: the reason is that *the evidence* belongs behind
authentication. It is not that approving is too dangerous to do quickly. That distinction produces
an asymmetry worth taking seriously:

- **Deny is safe without evidence.** The worst outcome is an unnecessary refusal, which the person
  undoes by opening the chat and asking again. The tool name alone is enough information to refuse.
- **Allow is not obviously safe without evidence.** A button that grants a tool whose arguments the
  person cannot see invites a decision the surface has deliberately withheld the basis for, which
  is why an inline Allow and `pendingSummary` are one question rather than two: enabling the button
  without the summary is the version nobody should want, and enabling it with the summary is a
  change to the content line.

That asymmetry is why the two configurations are not symmetric in cost, and why one of them is the
default. It is not why the other is refused.

**Two supported configurations.**

| | Default | Full |
|---|---|---|
| Setting | off | on, explicitly chosen |
| Buttons | Deny, Open to review | Allow, Deny, Open to review |
| `pendingSummary` | absent | populated, 120 bytes |
| Content line | unchanged from today's permission push | widened, and recorded as such |
| Intent | `ResolvePermissionIntent`, `deny` case offered | same type, both cases offered |

**Deny plus Open to review is the shipping default**, because it is the configuration that needs no
content decision to be made first and is useful on its own: the action you actually want when you
glance at a phone and see an agent about to do something you did not intend. It is a default, not a
verdict. The Full configuration is a supported build of the same design, reachable by a setting and
a populated field, and the structure must stay able to reach it for as long as the question is open.

**What the platform has already decided, measured 2026-08-23.** Neither row of that table applies
on the Lock Screen, because iOS does not run an interactive Live Activity intent there: it takes
the tap through unlock and into the app. Measured on the simulator with the app terminated, both
buttons, reproducibly; the same tap in the unlocked expanded Dynamic Island cold-launched the app
and ran `perform()` about 175 ms later without foregrounding. See
[spike 5](#uncertainties-and-the-spikes-that-settle-them).

That narrows the open question without taking it. On the Lock Screen there is one behaviour, and it
is Open to review, whichever configuration ships. The choice David has deferred is therefore only
about the **unlocked expanded presentation**, which is a materially smaller question than the one
this section started with: the person has already got past the lock screen before any button of
ours can act. It is still a change to the content line, and still his to take.

The device half of that measurement is owed before slice D ships, because the simulator had no
passcode.

`REMOTE_ACCESS.md` is not edited by this draft and should not be edited to encode either outcome.
When slice D ships, the edit it earns is to state **the reason behind the existing rule** (evidence
belongs behind authentication) and to record that the inline case is a deliberate open choice with
a default, so a later reader can see both what the rule protects and that the question was left
open on purpose rather than overlooked.

## Slices

### Slice A: the Usage widget

Shippable alone. Delivers: Home Screen small and medium widgets and Lock Screen circular,
rectangular and inline accessories showing consumed fraction, window label, reset countdown, and
measured spend for the selected range.

Contains all the structural work: the extension target, the app group, `ThreadingGlanceKit`, the
`RemoteThemePalette` move, the snapshot store, the staleness contract, the three lint roots and the
signing changes.

**What it is worth without the rest.** At a glance, on a locked phone, how much of a weekly window
is gone and when it comes back, without unlocking and without launching. That is the reading people
actually check repeatedly during a heavy week, it changes on the scale of hours rather than seconds
so a snapshot-driven surface is genuinely correct for it, and the countdown stays exact with no
refreshes at all. It needs no new push type, no protocol change, no Mac-side APNs work and no
hosted service.

**Why not lead with the Live Activity.** It needs a new push type, a new token registration, a new
Mac envelope, a Live Activity authorization state to handle, an 8 hour ceiling to design around,
and it lands immediately on the permission-actions policy question. Every one of those is easier to
judge on top of a working extension than at the same time as inventing one.

### Slice B: the sessions widget

Cheap once A exists, and worth listing separately because it is where the content line gets tested.
A medium widget listing at most three sessions by title, project, agent mark and coarse state, plus
counts of what was omitted. No sentence about what any agent is doing. Same snapshot, same store,
one more view.

### Slice C: the Live Activity

Phone-started, push-updated, no interactive control. Registration field, Mac envelope, activity
lifecycle, Dynamic Island compact and expanded presentations, Lock Screen presentation, the stale
and ended states.

### Slice D: the inline control

Shippable in either configuration, and it does not wait for the product call. It ships in the
default configuration as soon as spikes 5 and 6 are answered; enabling the Full configuration later
is a setting and a populated field, not a second slice of engineering.

What the slice builds, in both configurations: `ResolvePermissionIntent` with both decision cases,
the setting that decides which are offered, the warm-route check, the truthful failure state in the
activity when the Mac cannot be reached, and the negative authorization tests.

What differs between them:

| | Default | Full |
|---|---|---|
| Buttons rendered | Deny, Open to review | Allow, Deny, Open to review |
| Where they act | unlocked expanded presentation only; the Lock Screen is Open to review by the platform's choice, not ours | same |
| Mac-side change | none beyond slice C | `pendingSummary` populated from the existing `PermissionPolicy` classification, capped at 120 bytes |
| Content line | unchanged | widened, and the widening is the decision |
| Documentation | `REMOTE_ACCESS.md` records the reason and the open choice | the same edit, plus the choice now made and dated |

If the product call is never taken, the default configuration is a finished feature and not a
placeholder. That is the point of splitting it this way.

### Slice E: opportunistic freshness

Only if the spikes support it: an NSE writing the snapshot at notification time, or a background
refresh task. Strict improvement, no format change.

### Later, cheap, not scheduled

An iOS 18 `ControlWidget` behind an availability gate, opening a chat or starting one. StandBy
comes free with the small widget. A widget configuration intent choosing which account or session
a widget shows, which is ordinary `AppIntentConfiguration` work over data already in the snapshot.

## What is gated on the hosted service, and what is not

**Not gated.** Every slice above. The Usage widget, the sessions widget, the Live Activity and the
inline control all work for a paired-direct user and a Tailscale user, because the phone holds the
data and the Mac already holds an APNs provider key when `THREADING_APNS_*` is configured. The
degraded contract without any push at all, which is what a user with no provider key has today
(the settings page says **Live only**), is: **the widgets work in full**, since they never depended
on push, and **the Live Activity works while the app can update it**, meaning it is started and
kept current whenever the app is in the foreground or briefly backgrounded, and goes stale and then
ends when it cannot be. That is a real and honest degradation rather than a broken feature.

**Gated.** Push delivery for a user who never configures a provider key, which is the hosted push
broker slice and already exists as a Worker call for alert pushes; it needs one more envelope kind
for `liveactivity`. And the hosted **widget snapshot store**, which in this design is not the origin
but a mirror: it would let a second device, or a phone whose app has not been opened in days, read
a fresher projection than its own last write. That is a genuine improvement and it is strictly
additive to the format described here, since the record already carries a generation number and an
observation time.

Nothing in this draft should be built in a way that makes the hosted store the only way it works.

## Uncertainties, and the spikes that settle them

**Spikes 5 and 6 block slice D in every configuration** and have to be answered before it ships,
including before the default configuration ships.

Spikes 1 and 5 were run on 2026-08-23 against a throwaway app plus widget extension plus local
package, Xcode 26.5, iPhone 17 Pro Max simulator on iOS 26.5. The harness is kept at
`.build/glance-spike` (gitignored) because the device half of spike 5 still needs it. Findings are
marked below.

1. **Answered, and the answer changes the plan. `APPLICATION_EXTENSION_API_ONLY` does not reach a
   local SwiftPM package.**

   The good half: the structure works. A local package linked by both the app and the widget
   extension builds and links with no special handling, and the package may hold the
   `ActivityAttributes`, the shared store and the App Intent. So `ThreadingGlanceKit` is viable and
   the "carry the types as source in both targets" fallback is not needed.

   The bad half: the package is compiled **once**, and `-application-extension` appears only in the
   extension's own compile and link tasks, never in the package's. Three builds pinned it:

   | Where `UIApplication.shared` is written | Result |
   |---|---|
   | the widget extension's own source | `error: 'shared' is unavailable in application extensions for iOS` |
   | inside the package | builds clean |
   | inside the package, and *called* from the widget's own source | builds clean, no warning |

   So the compiler enforces the extension boundary exactly up to the module edge and not one step
   past it. A shared package can call extension-unavailable API, link into the appex, and fail at
   runtime instead, with nothing said at build time.

   **This is a new requirement, not just a spike result.** `ThreadingGlanceKit` needs a checker
   rule forbidding extension-unsafe API in its sources, because Xcode will not provide one. It
   belongs beside the other repository boundary lints and should land with the package rather than
   after it. The audit surface is small and stays small, which is the argument for keeping the
   package narrow: tokens, palette, the snapshot record and its store, and nothing that wants a
   `UIApplication`.
2. **Can a Notification Service Extension actually drive ActivityKit?** Evidence says no, and the
   evidence is a forum thread plus documentary silence. Spike: a 20 line NSE that logs
   `Activity<T>.activities.count` and attempts one `update`, on a physical device, with the app
   suspended. NSEs do not work under simulated pushes, so this must be a real device and a real
   push. Half a day, and it closes the question permanently either way.
3. **Does `WidgetCenter.reloadTimelines` from an NSE or a background push reliably redraw a
   widget?** Contested across several forum threads. Spike: instrument a timeline provider to log
   its invocations, drive it from an NSE with the app suspended, over several hours and without a
   debugger attached, since several reports say the debugger changes the answer. One day. Gates
   slice E only.
4. **Is the app woken with background runtime for `event: "update"`, or only for `"start"`?** Apple
   states it for the start case. If updates also wake the app, a lower-content update payload
   becomes possible. Spike: a logging build on a device, comparing a start push and an update push.
   Half a day.
5. **Blocks slice D. Answered on the simulator, owed on a device. The system already interposes
   unlock on the Lock Screen, and the intent runs in the app's process.**

   Measured with the app **terminated** each time, so every run is a cold start, and with the
   intent defined in the package rather than in the app target:

   | Presentation | Result |
   |---|---|
   | Expanded Dynamic Island, device unlocked | app cold-launches, `perform()` runs 172 to 175 ms later in the app's process, no foregrounding |
   | Lock Screen Live Activity, device locked | app launches and comes to the foreground, `perform()` **does not run** |

   Both rows reproduced for the Deny button and the Allow button independently, so the variable is
   the lock state and not which control was pressed. Two consequences:

   - **A one-tap decision from the Lock Screen is not on the table, whatever the product call.**
     iOS routes the tap through unlock and into the app instead of running the intent. The platform
     already enforces roughly what the existing `REMOTE_ACCESS.md` rule wants. This does not take
     David's decision; it narrows what the decision is about, from "Allow anywhere a Live Activity
     appears" to "Allow in the unlocked expanded presentation". Deny plus Open to review is
     unaffected, and on the Lock Screen the default configuration is *already* Open to review
     because the system makes it so.
   - **Target membership through a package satisfies Apple's requirement.** Apple says to add the
     intent to the app target; defining it in a package linked by both put its metadata in both
     bundles' `Metadata.appintents`, and `perform()` ran in the app's process with the app's pid.
     So the intent does not have to be duplicated into `Sources/ThreadingMobile`.

   **Still owed, on a physical device:** the simulator had no passcode, so "unlock" was a swipe. A
   passcode-protected device may demand the passcode and then run the intent, or demand it and then
   open the app, and those are different products. Also unverified on device: whether
   `openAppWhenRun = true` or `ForegroundContinuableIntent` changes the Lock Screen answer. Half a
   day with the kept harness. Record the answer in the architecture file with its date, because
   this is platform behaviour that can move under us.

   Two smaller things the same run turned up, both worth carrying into the product:

   - The **first** Live Activity an app requests raises a system consent sheet, and it can appear
     on the Lock Screen ("Allow Live Activities from …?"). So the first time a turn starts, the
     user is asked, on a surface we do not control. Slice C should not raise its first activity at
     a moment where that prompt would be confusing.
   - `ActivityAuthorizationInfo().frequentPushesEnabled` read `false` without
     `NSSupportsLiveActivitiesFrequentUpdates`, as documented. Nothing surprising, but it confirms
     the Mac can read that state off the phone before choosing a push priority.
6. **Blocks slice D. How long does a warm reconnect actually take from a suspended app?** This
   decides whether an inline control of any kind is usable. Spike 5 removed half of this question:
   process startup is not the problem, because a cold app launch reached `perform()` in about
   175 ms. What remains is entirely the network work inside `perform()`. Spike: instrument
   `RemoteSessionConnection` and measure resume to session-routed frame on LAN, on a tailnet and
   over the hosted path, from a suspended app. One day, and it needs the real app rather than the
   harness. If the LAN case is not comfortably inside the intent's window, no button is viable in
   either configuration and the control is Open to review only, which is a deep link and needs no
   connection at all.
7. **Does the mobile theme checker's palette rule survive a second module?** Mechanical, but it is
   the rule most likely to be quietly dropped in a new process. Settle it by extending the checker
   before writing the first widget view, not after.

## Tests

Following the repository's own division: nothing here needs a window on screen, so all of it
belongs in the fast plan.

- `GlanceSnapshotStore`: round trip, the 16 KiB refusal, the atomic write, the quarantine path on
  a corrupt record, the latched `writesAllowed` after an unreadable read, and the explicit file
  protection class on the written file.
- Projection: the caps (4 limit rows, 3 session rows) and the omitted counts, at both expected and
  stress cardinality, driven by the same fixtures `UsageDashboardProjectionTests` already uses.
- Content: an assertion that the encoded snapshot contains no field carrying tool arguments, a
  path, a diff or transcript text. This is the test that keeps the content line from eroding, and
  it should read as a deny list over the record's own fields so a newly added field fails until
  someone classifies it.
- Theme: the widget root resolves a palette from a snapshot `RemoteThemeDTO` and from `nil`, and
  renders both, using the offscreen render pattern the repository already uses. Remember that an
  offscreen render needs an explicit appearance and a painted backdrop.
- Live Activity: the content state encodes under 4 KB at every state, **including with
  `pendingSummary` populated at its 120 byte cap**, so the reserved field is proven to fit before
  anyone needs it. The envelope carries the right topic suffix and push type. All pure value tests
  on the Mac side.
- The reserved field: an assertion that `pendingSummary` is absent from every encoded content state
  the shipping configuration produces, and a decode test proving a payload without it is normal
  rather than degraded. These are the two tests that keep a reserved hole from becoming a populated
  one by accident.
- Authorization: the negative test that a guest-scoped authorization sending the permission
  decision frame from the intent path receives `forbidden`, and that an already-answered request
  receives `permissionNotPending`. Run it for **both** decision cases, so the `allow` path is
  covered by the same negative tests as `deny` from the day the intent exists rather than from the
  day the button appears.
- Staleness: the four bands render their four distinct states, and no band renders a stale number
  without its timestamp.

Visual review follows the existing convention: a `THREADING_MOBILE_DEMO=glance-*` family and
`scripts/ui-evidence-ios.sh`, reviewed on a compact iPhone, a large iPhone, an accessibility
Dynamic Type size and a deliberately different remote theme.

## Non-goals

- Any widget or activity content derived from transcript or terminal text.
- A widget that opens a network connection, holds a credential, or reaches the Mac.
- A shared Keychain access group between the app and the extension.
- Shipping the inline Allow enabled, or populating `pendingSummary`, before the deferred product
  call is taken. The capability is designed in and the default is off; see
  [The approve control](#the-approve-control). Foreclosing that capability is equally a non-goal.
- watchOS, macOS widgets, or a Mac menu bar surface. Different products, different drafts.
- Making the hosted snapshot store a dependency of anything here.

## When this ships

A new subsystem earns a `docs/architecture/` file plus one row in the CLAUDE.md table. The durable
decisions that belong there are: the app group and its format, the content line as it applies to a
surface that is not a notification, the freshness contract, the theme crossing into a second
process, the reserved `pendingSummary` and why it is reserved rather than populated, and spike 5's
answer with its date.

`REMOTE_ACCESS.md` gets an edit when slice D ships, and the edit **states the reason behind the
existing rule and records that the inline case is a deliberate open choice with a default**. It
does not encode either outcome as settled. If the choice is later taken, that is a second, dated
edit to the same sentence.

`USER_GUIDE.md` gets the widgets and the Live Activity.
[`hosted-remote-service.md`](hosted-remote-service.md) gets a pointer saying its widget snapshot
store became a mirror rather than an origin.
