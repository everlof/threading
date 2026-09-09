# iOS usage widgets

The first implementation is usage-only. `ThreadingGlance` is an embedded iOS 17+ WidgetKit
extension; `ThreadingGlanceKit` owns its Foundation snapshot, cache, freshness and URL contract.
Live Activity registration, delivery and presentation remain in the
[feature draft](../feature-drafts/ios-glanceable-surfaces.md).

The Mac's `/api/usage/capacity` endpoint requires a whole-host owner, including a view-only
owner. Guest shares cannot discover the feature or read the endpoint. The service projects the
existing `AccountUsageService` cache and retains provider `observedAt`; it never reads transcripts
or constructs the historical Usage dashboard. `AccountUsageDidChange` advances an independent
epoch/revision and emits `usageCapacityChanged` to authorized event subscribers. Authorization is
checked again after an asynchronous response has been prepared.

Discovery runs on one utility task. It scans at most 4,096 home entries and admits the first
128 account candidates before actor-owned preference work; disabled candidates are filtered out.
The projection admits 256 windows and reports omitted counts. Credential-derived email labels are primed on a
utility worker before the actor-owned name resolver runs. Preferences and structural setup changes
invalidate discovery; a later capacity request also refreshes a discovery older than five minutes.
Provider refreshes retain the existing four-request concurrency and pacing. Changed readings
compare only the bounded projection, not an arbitrarily large provider window list.

On the phone, **Settings → Widgets → Use this Mac for widgets** pins one pairing identity.
The publisher belongs to the application delegate, rather than the Usage screen or unit-test
model initializer. It uses the authenticated active route only when that route belongs to the
pinned Mac. Switching Macs or suspending cancels acquisition and retains the dated snapshot;
removing the pairing, opting out or receiving an authorization refusal clears it. An ordinary
network failure keeps the previous observation. Older Macs show an update requirement.

Acquisition has one request and one pending invalidation, a 500 ms coalescing delay, a ten-second
request timeout and at most three attempts. The network stream is capped at 128 KiB before
decoding. Refreshing the same snapshot does not renew its observation time or ask WidgetKit to
reload. No background polling or WidgetKit push feed is installed in this slice.

`UsageGlanceStore` serializes file and codec work away from the main actor. Its only production
directory is `group.codes.threading.mobile`. Reads stop at 128 KiB plus one byte. Atomic writes use
`completeFileProtectionUntilFirstUserAuthentication`: encrypted on disk and readable while locked
after the first unlock. An app-issued sequence fences a stale fetch against a newer clear. Newer
archive versions are preserved and block writes. Readers never repair. An explicit cache reset
moves corrupt bytes to one non-overwriting recovery slot before rebuilding; preservation failures
block replacement. Credentials, addresses, images and transcripts never enter this store.

Each widget chooses one account using the pinned pairing identity plus provider/account identity.
A deleted configured account stays unavailable. Small and medium widgets show two windows;
circular and inline Lock Screen widgets show the first window. Rectangular widgets
also show the reset or observation age. Remaining capacity is always `1 - used`, never a guessed
reset value. At 15 minutes a reading gains its age, at six hours it is cached, and at 24 hours it
becomes unavailable. A passed reset or an implausible future observation removes the percentage.
The timeline schedules these boundaries; relative date text belongs to the system clock.

The durable surface is deliberately host-only. `GlanceDesign` is the system-widget theme
containment: semantic adaptive foregrounds and WidgetKit background/margin ownership survive
tinted Home Screens, vibrant Lock Screens and StandBy. This first implementation does not export
the Mac's fixed palette. Account choice is customizable; identity, authorization, freshness,
reset meaning and deep-link validation stay host-owned. There is no public Threading extension
component and no new extension data authority.

Widget taps are typed `threading://usage` routes. The UIKit scene admits cold-launch URLs before
constructing the root. A route selects only an existing pairing, prevents restoring an unrelated
chat and opens the Usage screen with the provider-qualified account identity. No URL accepts or
creates a pairing.

Validation lives in the GlanceKit and RemoteKit package suites, Mac capacity projection and
server integration tests, and mobile bundle/route tests. The extension is compiled and embedded
in the ordinary mobile build, including its English and Swedish catalogues. Physical-device
App Group provisioning and protection, OS timeline delivery, and installed Home/Lock Screen
visual evidence are separate acceptance checks; compilation is not their substitute.

The 2026-09-08 pass built both apps and passed 206 RemoteKit tests, seven GlanceKit tests,
15 focused Mac tests and 15 focused iOS tests. The iOS checks resolve the installed app's App
Group and inspect the embedded extension and Swedish resources. The bounded Mac projection
fixture (129 candidates, 300 source windows each) completed in 4 ms in the final Debug run;
that is test elapsed time, not a release or end-to-end widget refresh measurement. Localization,
mobile theme and main-actor latency checks passed. The extension installed on iOS 26.5, but the
Simulator input helper failed to connect and Computer Use permissions were unavailable, so no
Home/Lock Screen layout acceptance or physical-device protection/provisioning is claimed.
