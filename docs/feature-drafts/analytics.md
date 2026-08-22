# Analytics and crash reporting: what leaves the machine, and only by consent

**Status: draft.** Researched 2026-08-22. Nothing is committed. The local counter store (steps
1–2) is implementable now and needs no consent surface, because nothing leaves the machine. The
upload path shares the hosted remote service's deployed control plane and its deployment gate
([hosted-remote-service.md](hosted-remote-service.md) §Release sequence step 3). The single
decision that gates the whole feature is a brand decision, not a technical one: Threading's
stated position is **"nothing leaves without your action"**
([OPEN_SOURCE.md](../OPEN_SOURCE.md) §7), and this draft is designed so that shipping it keeps
that sentence true — upload is the user's action, taken once, revocable, and inspectable.

## The problem

Two kinds of question have no answer today:

1. **Counterfactual engineering questions.** The iOS app keeps a small pool of warm session
   connections for a bounded time. Would connecting, on every app activation, to every chat
   showing a badge have saved real loads, and at what cost in wasted connections? Today the
   only honest answer is a guess. The instrumentation seams exist
   (`RemoteSessionConnection`'s warm-transport states, the activation path), but nothing counts
   them, and nothing could report the counts even to us.
2. **Usage and failure reality.** Which features are used at all ("nobody uses X, remove it"),
   which structural errors actually occur in the field, and whether shipped builds crash or hang
   — beyond the handful of people who file an issue. `MetricKitDiagnostics` already collects
   Apple's crash/hang payloads *locally*; the launch ledger already knows a launch did not come
   back; none of it reaches the developer unless a user manually assembles a support report.

The constraint is that Threading's audience is precisely the population with the strongest
documented allergy to telemetry: terminal users. The category baseline is zero (Ghostty, iTerm2,
Obsidian — all market the absence). Our own research record already contains the cautionary tale:
t3code shipped default-on PostHog with a persistent pseudonymous ID and an undocumented opt-out,
and the resulting trust wound is lesson #1 of
[T3CODE_FINDINGS.md](../archive/research/T3CODE_FINDINGS.md) ("Never default-on telemetry") and
half the argument of [OPEN_SOURCE.md](../OPEN_SOURCE.md). This draft exists because the answer to
"can we have analytics anyway?" turns out to be yes — there is a design this audience has
repeatedly accepted — but only that design, and it is not the one analytics vendors sell.

## Research: what the category accepts

Full sources at the end. The compressed findings that bind this design:

- **The default is the whole fight.** Every telemetry revolt on record (Audacity 2021, Go's
  transparent-telemetry proposal 2023, Homebrew 2016, Fedora 2023, Warp at launch) was about
  collection being on by default. Payload cleanliness did not save any of them: Fedora's proposal
  was self-hosted, content-free and privacy-preserving and was rejected anyway; Go's design was
  *praised by its opponents* while the opt-out default alone forced a reversal. Browsability and
  "no sensitive content" are necessary but not sufficient.
- **The accepted reference design is Go 1.23's.** Counters aggregated on-device, `local` mode on
  by default (collected, inspectable, never uploaded), upload strictly opt-in, every uploadable
  string pre-approved in a published schema, uploaded copies kept locally, aggregate data public.
  Russ Cox's own math: ~16,000 weekly reports give 1% accuracy at 99% confidence, so even a 1–10%
  opt-in rate produces statistically useful counts.
- **Third-party endpoints are radioactive independent of payload.** Google Analytics/Yandex were
  the accelerant at Audacity; "it's from Google" poisoned even Go's design; Homebrew only earned
  goodwill back by moving to self-hosted InfluxDB and destroying the Google-era data. First-party
  ingest is close to a prerequisite in this category.
- **t3 is two opposite stories, and the relevant one is the bad one.** T3 Chat (hosted web app)
  runs identified server-side PostHog deep enough to build per-user "Wrapped" from, with no
  analytics opt-out, and gets no backlash — because the user's data already lives on their
  servers. t3code (the local desktop tool, the product comparable to Threading) applied the same
  instinct and took the trust wound. A local-first tool does not get the hosted product's social
  license. One detail from T3 Chat worth engineering *against*: their analytics events survive
  the user deleting the underlying content.
- **Transparency artifacts that were concretely praised, worth copying:** Go's `telemetry view`
  and published dataset; Zed's "open telemetry log" command; VS Code's `--telemetry` event
  inventory; Homebrew's public aggregates and per-field docs; Sparkle's twenty-year-old dialog
  that shows the literal fields before asking. And one anti-pattern: VS Code's ~1,600
  possible events reads as surveillance even where each event is benign — schema growth needs a
  brake.
- **Legal reality points the same way as sentiment.** A stable per-install ID — even
  double-hashed — is pseudonymous personal data under EDPB guidance (Guidelines 01/2025;
  singling-out), and reading an identifier off the device for analytics sits inside ePrivacy
  Art. 5(3), where opt-out consent does not exist. Consent-free telemetry is defensible only with
  **no stable identifier at all** (the CNIL audience-measurement exemption shape; Aptabase and
  Plausible's daily-rotating-salt designs). Opt-in makes the entire question moot, which is the
  cheapest legal position available. Purely on-device collection is outside ePrivacy's scope
  until something is transmitted.
- **First-party analytics needs no App Tracking Transparency prompt** (ATT governs cross-company
  tracking only). The App Store privacy label for this design is *Data Not Linked to You:
  Usage Data* (+ *Crash Data* for the crash channel), which is also the label the audience reads.

## Product contract

Seven rules. They are the durable part of this draft; every implementation choice below follows
from one of them.

1. **Local always, upload by consent.** The counter store runs in every build, because it is
   also a user-facing feature (a local "what did Threading do this week" view) and a support
   asset. Nothing is transmitted until the person has said yes on an explicit surface. The ask
   happens once, on its own onboarding page and in Settings, default **off** — never a prompt
   fired unbidden (the onboarding rule in [onboarding.md](../architecture/onboarding.md) already
   states this position for notifications). A managed-preference key lets fleet administrators
   force it off. Turning it off stops assembly and delivery immediately; a separate control
   erases the local store.
2. **Structural allowlist, no free strings.** Counters, bounded histograms, enum values, app and
   OS versions. Never paths, titles, prompts, commands, hostnames, addresses, account or session
   identifiers. This is the same discipline `ThreadingRemoteKit`'s diagnostic contract already
   enforces ("events describe state transitions; they do not contain user content" —
   [REMOTE_DIAGNOSTICS.md](../REMOTE_DIAGNOSTICS.md)); analytics reuses the writer discipline
   rather than growing a second, looser one.
3. **No stable identifier, ever.** A report carries a random UUID minted for that report and
   never reused; no install ID, no hashed device ID, no cross-report linkage. We deliberately
   give up per-user retention curves and funnels; every question in scope (§The two question
   shapes) is answerable without them. This is what keeps the privacy label at *Not Linked to
   You* and the GDPR analysis anonymous rather than pseudonymous.
4. **Aggregate on device; upload summaries.** One report per week: counter totals and fixed
   histogram buckets for that week, app/build, OS version, platform, schema version. Never a
   time-ordered event stream, never per-event timestamps. The week is the only time resolution
   that leaves the machine.
5. **Every uploadable name is published and enforced.** The schema is one Swift registry file;
   a build-phase check script keeps `docs/analytics/SCHEMA.md` in exact sync with it, the same
   way the theme and architecture boundary scripts gate the build today. A counter that is not
   in the registry cannot be incremented; a field that is not in the schema cannot be encoded.
   Adding a counter requires a documented reason in the schema entry — the brake against the
   1,600-event failure mode.
6. **Browsable before, during and after.** The pending report is viewable verbatim; sent reports
   are kept locally with receipts (the `MacIssueReportOutbox` record/package pattern —
   [github.md](../architecture/github.md)); live counters are visible in the same surface. A user
   can always answer "what exactly has this app sent?" from the app itself.
7. **First-party endpoint; crash reports are a separate consent.** Ingest rides our existing
   Cloudflare control plane, not a vendor SDK. Crash/hang reporting is a different channel with
   richer payloads and therefore its own moment of consent — ask-at-the-moment with the payload
   shown, per the Sparkle/Apple pattern — and is never bundled into the analytics yes.

Rejected alternatives, recorded per this directory's rules:

| Option | Why not |
| --- | --- |
| PostHog (cloud or SDK) | Third-party endpoint; identity-shaped SDK (persistent distinct id even in "anonymous" mode); the exact stack behind the t3code wound. Server-side PostHog works for hosted products, which Threading is not. |
| Firebase / Crashlytics | Google endpoint; ads-adjacent SDK with documented App Review friction; category poison. |
| TelemetryDeck | The respectable Apple-indie vendor, but its model is a *stable* double-hashed device ID (that is what powers its retention metrics) plus a vendor endpoint — both conflict with rules 3 and 7. |
| Aptabase (self-hosted) | Closest in spirit (daily-rotating salt, no stored client ID), but event-stream shaped, needs an operated Postgres/ClickHouse deployment, and still doesn't match report-shaped weekly uploads. Running it is more ops than the Worker route below. |
| Sentry for crashes | Third-party endpoint and an in-process crash handler SDK; MetricKit already produces the payloads without installing signal handlers in a PTY-juggling process. |

## The counter store (client)

A small module, `Core/Analytics/`, on both platforms (shared via the same source or
`ThreadingRemoteKit`-adjacent placement so iOS reuses it):

- **`AnalyticsSchema.swift`** — the registry. Each entry: a typed counter or histogram name, the
  fixed bucket boundaries for histograms, a one-line reason, and the schema version it was added
  in. This file *is* the allowlist; `scripts/check_analytics_schema.sh` fails the build when
  `docs/analytics/SCHEMA.md` and the registry diverge, joining the Enforce Repository Boundaries
  phase.
- **`AnalyticsCounters`** — in-memory accumulation, O(1) increment, no I/O and no allocation
  proportional to anything on hot paths (the increments proposed below sit on activation and
  connection seams, which the Scaling Gate treats as high-frequency). Flushed on a timer and on
  background/termination to a week-stamped JSON file under
  `~/Library/Application Support/Threading/Analytics/` (its own bounded directory, pruned to a
  handful of weeks — never inside `threading.db`, so persistence quarantine and analytics cannot
  interact). Losing a partial flush in a crash is acceptable; counters are not a ledger.
- **Test hosting:** no collection under `XCTestCase` (the `AppDelegate` startup skip already
  establishes the pattern), and the store redirects to a scratch directory in hosted tests the
  way `PreferenceStore` does, so a test can never pollute the developer's real counters.
- **Structural error counting:** `EventLog`'s stable error codes (`remote.http.401`-shaped) can
  be counted by code enum. This answers "which errors happen in the field" without a reporting
  channel; the string never leaves the code's own namespace.

## The two question shapes, worked

**The activation-prewarm counterfactual** (the motivating example). The policy under evaluation —
"on every activation, pre-connect every badged chat" — is evaluated *locally* at every
activation, so raw events never need to leave any device. On the existing seams:

- On `didBecomeActive`: increment `activation.count`; add the number of badge-showing sessions to
  histogram `activation.badgedSessions` (buckets 0, 1, 2, 3–5, 6+).
- At the warm-transport seam (`RemoteSessionConnection.resumeFromPool` and the connect path):
  increment `pool.hit` or `pool.miss`; on a miss, add the paid connect latency to
  `pool.missConnectLatencyMS` (fixed buckets); when a parked connection dies or expires unused,
  increment `pool.expiredUnused`.
- When a session is opened within the pool TTL after an activation: increment
  `open.withinTTL.badged` or `open.withinTTL.unbadged`; if it was badged *and* a pool miss,
  increment `counterfactual.prewarmBadged.savedMiss`. Also accumulate
  `counterfactual.prewarmBadged.wouldPrewarm` (sum of badged counts at activation).

The answers fall out of arithmetic on the weekly totals: wasted connections per week =
`wouldPrewarm − open.withinTTL.badged`; loads the policy would have saved = `savedMiss`; the
latency each save is worth = the `pool.missConnectLatencyMS` distribution. Because the
counterfactual is versioned in code, changing the policy under test is a schema revision, not a
data-science project — and this shape answers the question *better* than an event stream, which
would need cross-event joins to reconstruct the same numbers. This slice is worth landing first
and alone: with zero consent UI it already answers the question from our own devices and
TestFlight, because nothing uploads.

**"Nobody uses feature X"** is plain usage counters on command/surface entry points, with one
honest caveat carried into the schema doc: opt-in data is a biased sample, so absence in
telemetry is evidence, not proof. Use it for ranking and magnitudes; confirm removals with an
in-app deprecation notice. (Go's sampling math above says even a small opted-in population ranks
features reliably.)

## The weekly report, the ask, and the browsable surface

- **Assembly.** When a week's window closes, fold that week's counter file into a report:
  `{schemaVersion, reportID (random, single-use), platform, appVersion, build, osVersion, week,
  counters, histograms}`. Nothing else. No locale, no country, no timezone — each was considered
  and none currently pays for its fingerprinting surface.
- **Outbox.** The record/package split already proven by `MacIssueReportOutbox`: the report is
  written locally always; a delivery queue entry exists only when consent is on *and* an endpoint
  is configured (`ThreadingAnalyticsIntakeURL`, same no-compiled-fallback rule as the issue
  intake). Sent reports keep their receipt beside them. A developer build with no endpoint shows
  "saved", exactly like issue reports.
- **The ask.** One onboarding page (after notifications, same explicit-action rule), and the
  Privacy settings page. The page shows a real, current example report — Sparkle's
  show-the-fields dialog, updated — with a link to the schema doc. Default off. The same page
  hosts the off switch, the erase-local-store action, and the browsable list of pending and sent
  reports. iOS mirrors this inside the existing Diagnostics sheet.
- **Scriptable and manageable off:** a `defaults` key honored before anything else, readable by
  MDM managed preferences, so an organization can flatten it fleet-wide.

## Backend

The control plane already deployed for remote access (Cloudflare Worker + D1 + R2 + Queues + WAF,
Terraform-managed — [hosted-remote-service.md](hosted-remote-service.md) §Service shape) gains
one bounded slice. No new vendor, no new operational surface beyond a route, a queue consumer and
a cron.

- **Ingest route** — `POST /v1/analytics-report` on the existing Worker, its own rate-limit
  namespace and WAF rules. Unauthenticated by design (an account would defeat rule 3), defended
  by shape instead: size cap (64 KB), schema-version allowlist, strict field validation against
  the same published schema, counters bounded to plausible magnitudes, anything failing dropped
  with a count. The handler **never reads or logs the client IP** — no `CF-Connecting-IP` access,
  no Logpush of request metadata; Cloudflare's transient processing of the IP is a
  processor-level fact the privacy policy discloses. Accepted reports go to a Queue, the consumer
  appends them as NDJSON to R2, partitioned by week and schema version.
- **Aggregation and reading.** A scheduled Worker folds each closed week into aggregate rows in
  D1 (totals and merged histograms per platform/version). Day one, the developer reads with
  DuckDB straight over the R2 objects — no hosted dashboard to operate, no Grafana; D1 aggregates
  exist so simple questions don't re-scan raw reports. If volume ever makes this slow, that is
  the moment to consider ClickHouse, not before.
- **Retention.** Raw reports: an R2 lifecycle rule deletes at 13 months (the CNIL exemption's
  outer bound, adopted as ours even though consent makes it non-mandatory). Aggregates persist.
- **Publishing aggregates** (later, optional but recommended): the cron emits a public JSON of
  the same aggregates, Homebrew-style. It converts telemetry from a liability into proof, and it
  is nearly free once the aggregate rows exist.
- **Abuse honesty:** without device attestation anyone can POST fiction. App Attest exists on
  iOS only; macOS has no equivalent, and requiring one would add an identity we don't want.
  Accepted: the data is counters, poisoning it is low-value, rate limits bound the damage, and
  aggregation notes report counts per version so an anomaly is visible. Recorded as an open
  question rather than solved.

## Crash and hang reporting, the accepted way

Everything needed already exists locally: `MetricKitDiagnostics` receives Apple's crash/hang
payloads in shipped builds; the launch ledger's `PreviousLaunchOutcome` knows a launch was
`unclean` and pins the `.ips` to the crashed pid
([crash-recovery.md](../architecture/crash-recovery.md)); Phase 3 of
[REMOTE_DIAGNOSTICS.md](../REMOTE_DIAGNOSTICS.md) already promises "consent-gated crash/error
reporting for release builds". This section is that promise made concrete, following the pattern
this audience has accepted for twenty years (Apple's own crash dialog, Sparkle, Firefox's crash
reporter) and the one it distrusts (silent in-process Crashlytics-style auto-upload):

1. **Ask at the moment, with the payload shown.** On the next launch after an `unclean` outcome
   — and outside the crash-loop triage flow, which keeps its existing ordering and gets no new
   dialog — a non-modal surface offers: **View report**, **Send**, **Always send**, **Don't
   send**. "Always send" is a durable choice made *in* a dialog that asked first, which is why
   Firefox's equivalent is accepted; it is revocable on the Privacy page. The analytics consent
   neither implies nor is implied by this one.
2. **The payload is assembled by allowlist, not redaction.** MetricKit's crash/hang diagnostic
   (call stacks as image UUID + name + offsets — never full image paths, which embed the
   username), plus the app's own structural context: previous-launch outcome, crash-loop state,
   app/build/OS versions, and the same week-granularity timestamp. No `.ips` is ever attached
   raw; the `.ips` remains the *local* record behind "Reveal Crash Report". Symbolication happens
   on the developer side against archived dSYMs (we sign and distribute our own builds), so no
   symbol server and no third party.
3. **Per-report code, deletable.** Each crash report carries a short report code shown to the
   user; the intake stores it 90 days and deletes by code on request — the same
   deletable-by-report-code contract REMOTE_DIAGNOSTICS Phase 3 states for support uploads. This
   is honest about the one way a crash report differs from analytics: it is a document about one
   incident, so it gets an identity and therefore a deletion right.
4. **Same outbox, own route.** Crash reports use the outbox record/package split and a separate
   `POST /v1/crash-report` route with its own caps. Hang diagnostics (MetricKit hang payloads,
   `MainThreadStallMonitor` summaries as bounded counters) ride the same consent.
5. **iOS baseline:** App Store distribution already gives Apple's opt-in crash reporting via
   App Store Connect; our channel complements it (faster, joined to our structural context) and
   the two are never merged.

## Apple and legal position

- **Privacy label:** Data Not Linked to You — Usage Data (analytics) and Diagnostics/Crash Data
  (crash channel). No Identifiers entry: nothing stable is collected. No ATT prompt: first-party
  only, no cross-company linkage, no data sharing.
- **GDPR/ePrivacy:** local counters are on-device processing (outside Art. 5(3) until upload);
  upload happens only under explicit consent, so the lawful basis is consent regardless of
  whether a regulator would call the anonymous report personal data at all. The privacy policy
  states, Aptabase-style, that analytics reports cannot be attributed to a person and therefore
  cannot be individually deleted — and that crash reports can be, by code.
- **The brand sentence survives.** "Nothing leaves without your action" remains literally true:
  the action is the consent, taken on a page that showed the bytes. The landing-page phrasing
  should be updated in the same release the first upload path ships, not after — discovering
  telemetry is what burned Audacity and t3code; being told first is what Homebrew survived on.

## What exists, and what is new

| Exists | Reused as |
| --- | --- |
| `ThreadingRemoteKit` schema discipline (allowlisted structural fields, bounded values, no content) | The authoring rules for the analytics schema |
| `MacIssueReportOutbox` record/package split, receipts, no-compiled-endpoint rule | The analytics and crash outboxes |
| `MetricKitDiagnostics`, launch ledger `PreviousLaunchOutcome`, `.ips` pid pinning | The crash channel's entire local half |
| Cloudflare Worker + D1 + R2 + Queues + Terraform, WAF and rate-limit namespaces | The ingest backend |
| Onboarding page pattern, notifications-ask rule; Privacy settings page | The consent surfaces |
| iOS Diagnostics sheet | The iOS browsable surface |
| Boundary check scripts in the Enforce Repository Boundaries phase | `check_analytics_schema.sh` |

New: `Core/Analytics/` (registry, counters, report assembly, sanitizer), the two Worker routes +
queue consumer + cron, `docs/analytics/SCHEMA.md`, the consent/browse UI, the crash prompt.

## Risks and boundaries

- **Capability existing draws fire even opt-in** (iTerm2's AI feature). Mitigation: the schema
  doc, the browsable surface and the consent page ship in the *same* release as the first upload
  path; announce it ourselves before anyone finds it in a diff; never a silent point release.
- **Opt-in bias.** Stated in the schema doc and in every removal discussion: telemetry ranks,
  it does not veto. Feature-removal decisions require a second signal.
- **Schema creep** is the failure mode transparency cannot fix (VS Code). The brake is
  structural: registry + doc + build gate + a reason per counter, and a norm that a counter that
  answered its question gets removed.
- **Scaling Gate compliance:** every proposed increment sits on an activation, connection or
  command seam; each must remain O(1) with no I/O; flush stays off the main actor and bounded.
  A stress fixture drives the pool seam at high frequency before the instrumentation ships.
- **Never in the product database.** Counter files live in their own pruned directory; analytics
  can neither trigger nor suffer persistence quarantine.

## Tests

- The consent gate is a network property, not a UI property: a test proves no delivery queue
  entry and no socket is created while consent is off, endpoint or not.
- Sanitizer tests in the "credentials cannot enter a report" family: paths, usernames, hostnames
  and free strings structurally cannot be encoded into a report or crash package.
- Schema sync: the check script fails on a registry/doc divergence and on an undocumented
  counter; a unit test proves an unregistered name cannot compile/encode.
- Report assembly is deterministic from a counter file fixture; histograms merge correctly;
  the report UUID is unique per assembly.
- Hosted-test isolation: counters written under XCTest land in the scratch directory
  (`HostedStoreTestCase` pattern) and never in the developer's store.
- Crash prompt: shown only after `unclean`, never during crash-loop triage, never twice for one
  incident; "Always send" honored and revocable.
- E2E (opt-in, `scripts/test.sh e2e`-style): one report and one synthetic crash package against
  a local mock intake, validated field-for-field against `SCHEMA.md`.

## Sequencing

1. **Counter store + registry + check script + the pool counterfactual counters.** Local only,
   no consent UI, immediately useful on our own devices and TestFlight. This slice alone answers
   the motivating question.
2. **Browsable surfaces** (Mac Privacy page section, iOS Diagnostics section) showing live
   counters — shipping the window before the pipe.
3. **Report assembly + outbox + consent UI**, endpoint unset (everything reports "saved").
4. **Backend slice** (routes, queue, R2, cron, retention, DuckDB workflow) behind the hosted
   service's deployment gate; then configure the endpoint and update the public privacy wording,
   same release.
5. **Crash channel** (prompt, allowlist packager, always-send preference, deletable-by-code
   intake).
6. **Optional: public aggregates.**

## Open questions

- Ingest abuse: live with rate limits + anomaly visibility, or add iOS App Attest for the iOS
  reports only (accepting asymmetry)?
- Cadence: weekly is Go's shape; is a 14-day window better for a low-volume app's anonymity set?
- Publish aggregates from day one, or after the first quarter of data?
- Does the local counter view earn a place in the Usage dashboard rather than the Privacy page?

## Research sources

Repo: [OPEN_SOURCE.md](../OPEN_SOURCE.md) · [T3CODE_FINDINGS.md](../archive/research/T3CODE_FINDINGS.md)
(t3code #1397) · [REMOTE_DIAGNOSTICS.md](../REMOTE_DIAGNOSTICS.md) ·
[hosted-remote-service.md](hosted-remote-service.md) ·
[crash-recovery.md](../architecture/crash-recovery.md) · [performance.md](../architecture/performance.md) §MetricKit ·
[github.md](../architecture/github.md) §`MacIssueReportOutbox`.

Reference designs: Go transparent telemetry — https://go.dev/doc/telemetry ·
https://go.dev/blog/gotelemetry · https://research.swtch.com/telemetry-opt-in ·
https://github.com/golang/go/discussions/58409 ; Homebrew — https://docs.brew.sh/Analytics ;
VS Code — https://code.visualstudio.com/docs/configure/telemetry ·
https://www.roboleary.net/tools/2022/04/20/vscode-telemetry ; Zed — https://zed.dev/docs/telemetry ;
Sparkle — https://sparkle-project.github.io/documentation/system-profiling/ .

Cautionary cases: Audacity — https://www.theregister.com/software/2021/05/14/audacitys-new-management-hits-rewind-on-telemetry-plans-following-community-outrage/731361 ·
https://tenacityaudio.org/ ; Fedora — https://lwn.net/Articles/937528/ ; Warp —
https://news.ycombinator.com/item?id=30921231 · https://www.warp.dev/blog/telemetry-now-optional-in-warp ;
iTerm2 AI backlash — https://gitlab.com/gnachman/iterm2/-/issues/11470 ; Ghostty/Obsidian zero-telemetry
posture — https://ghostty.org/docs/about · https://obsidian.md/privacy .

t3: launch changelog ("Added serverside analytics w/ Posthog") —
https://x.com/theo/status/1878718988261458060 ; the Wrapped/ClickHouse video —
https://www.youtube.com/watch?v=vcfISXg--R0 ; PostHog advocacy (sponsored) —
https://x.com/theo/status/1770944371116192194 · https://t3.gg/sponsors/posthog ;
t3.chat privacy policy — https://t3.chat/privacy-policy ; t3code telemetry issue —
https://github.com/pingdotgg/t3code/issues/1397 .

Vendors: TelemetryDeck — https://telemetrydeck.com/docs/guides/privacy-faq/ ·
https://telemetrydeck.com/docs/articles/anonymization-how-it-works/ ; Aptabase —
https://aptabase.com/legal/privacy · https://github.com/aptabase/aptabase-swift ; PostHog —
https://posthog.com/docs/data/anonymous-vs-identified-events ; Plausible —
https://plausible.io/data-policy ; Firebase concerns —
https://steamclock.com/blog/2021/02/apple-tracking-analytics-sdks ·
https://developer.apple.com/forums/thread/688582 .

Legal/Apple: EDPB ePrivacy Art. 5(3) guidelines —
https://www.edpb.europa.eu/system/files/2024-10/edpb_guidelines_202302_technical_scope_art_53_eprivacydirective_v2_en_0.pdf ;
EDPB pseudonymisation 01/2025 —
https://www.edpb.europa.eu/system/files/2025-01/edpb_guidelines_202501_pseudonymisation_en.pdf ;
CNIL audience-measurement exemption — https://www.cnil.fr/en/sheet-ndeg16-use-analytics-your-websites-and-applications ;
Apple tracking definition / privacy details — https://developer.apple.com/app-store/user-privacy-and-data-use/ ·
https://developer.apple.com/app-store/app-privacy-details/ ;
opt-out consent analysis — https://www.activemind.legal/guides/telemetry-data/ .
