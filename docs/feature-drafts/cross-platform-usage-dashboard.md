# Cross-platform Usage dashboard

> Status: implemented 2026-08-11 — retained as the delivery plan and architectural decision
> record for the shared projection, owner-only remote surface, native iOS renderer and the
> banked-reset contract on both platforms.

## Decision

Bring Usage to iOS as a native phone surface backed by a bounded, owner-only snapshot prepared by
the Mac. Share the usage meaning and projection, not the AppKit view tree or the raw transcript and
history stores.

The first release should include both Usage subjects:

- **Overview** — measured cost, tokens, daily provider composition, totals and coverage;
- **Limit History** — current consumption, projections, reset evidence and banked resets.

Banked resets are part of the initial cross-platform contract, not an iOS follow-up. On both macOS
and iOS, the selected account/window must show:

- the current number of available banked resets when the provider reports it;
- the earliest known expiry among those available resets;
- proven historical banked-reset uses as distinct chart markers;
- an explicit unavailable state when the provider supplies no reset-credit data.

Do not sum banked resets across accounts. A reset belongs to a provider account, and a machine-wide
number would hide which account can actually use it.

## Why this shape

The macOS implementation already owns the expensive and provider-sensitive work:

- `TranscriptUsageService` incrementally scans and deduplicates local usage sources;
- `UsageHistoryStore` and `UsageLimitHistoryJournal` retain sparse observed limit history;
- `AccountUsageService` fetches authoritative provider windows;
- `CodexUsageFetcher` reads the available reset-credit count and, independently, the detailed
  credit endpoint used to find the next expiry;
- `UsageLimitHistoryAnalysis` classifies an early clear as a banked reset only when the surrounding
  observations and a decreased credit count prove it.

The iOS companion cannot and should not repeat that work. It has no local transcript authority,
provider credentials or durable limit journal. It already has an authenticated connection to the
Mac, a shared Foundation-only DTO package, and a resolved semantic app theme.

The existing macOS `UsageDashboardView` is AppKit-specific and assumes a desktop content width.
Sharing it would couple the phone to AppKit geometry while still failing to share any of the data
acquisition. A native iOS renderer over one semantic snapshot is the smaller and more durable
boundary.

## Product contract

### Availability and entry

- Usage is available only for a paired owner device whose scope covers the whole Mac. A guest link
  to one session must never receive whole-machine cost, account names or limit history.
- The Mac advertises Usage through an optional remote feature identifier. A new iOS build hides
  the entry when paired to an older Mac rather than presenting a route that returns 404.
- On iPhone, **Usage** appears in the session dashboard's trailing options menu and opens as a
  large sheet with its own navigation title and close action. This matches the supplied mobile
  hierarchy reference and avoids treating a non-session screen as a session ID in the current
  navigation path.
- On iPad, the same surface may use the platform's wider sheet presentation. Its content reflows;
  it does not adopt the macOS minimum width.

### Overview

The default tab is Overview at 30 days. It provides:

1. a 7 / 30 / 90 day control;
2. a Cost / Tokens control;
3. a hero card containing the selected total, measurement quality, request count and stacked daily
   chart;
4. a ranked provider/billing-route list with value and share;
5. supporting totals for processed, cached and uncached input, output, reasoning and estimated
   cache savings;
6. data coverage, including partial, unavailable and failed sources;
7. the pricing-catalog version and a concise statement that local estimates are not invoices.

The supplied mobile screenshot is a hierarchy reference: total and chart first, providers next,
then quieter totals. No screenshot asset, third-party layout code or product-specific prose is
copied into Threading.

Coverage remains visible on the phone. A smaller screen is not permission to make a partial total
look complete.

### Limit History

Limit History provides:

1. an account/window chooser;
2. an independent 7 / 30 / 90 day control;
3. current utilization and scheduled reset;
4. projected exhaustion or utilization at reset, clearly marked as an estimate;
5. recorded reset count and restored pace;
6. **Banked resets** — current available count plus next expiry;
7. a chart separating observed history, projected continuation, scheduled/proven resets, banked
   reset uses and expiry markers.

The count is inventory; a banked-reset marker is historical evidence. They must not be conflated:

- `resetCredits == 3` means three resets are currently available for that account;
- a `.bankedCredit` event means a prior reset was observed being consumed;
- an expiry marker means the earliest currently available credit is expected to expire;
- none of those facts says a banked reset will be applied automatically.

### Banked-reset states

Both renderers use the same state meanings:

| Provider value | Presentation |
| --- | --- |
| Positive count | “N banked resets” and the nearest expiry when known |
| Authoritative zero | “0 banked resets” / “None available” |
| Count present, expiry absent | Count plus “No expiry reported” |
| Count absent | “Unavailable” rather than zero |

Use plural-aware localized copy. Color may distinguish reset, expiry and projection markers, but
shape, label and accessibility text must carry the same distinction without color.

## Shared semantic projection

Move dashboard derivation out of the AppKit view into Foundation-only value projection before
adding the wire endpoint.

Proposed responsibility split:

```text
TranscriptUsageReport ─┐
                       ├─ UsageDashboardProjection ─┬─ macOS AppKit renderer
Limit history snapshot ┤                            └─ Remote usage DTO bridge
Live AccountUsage ─────┘                                      │
                                                             ▼
                                                   native iOS renderer
```

`UsageDashboardProjection` should own semantic decisions that must not drift between platforms:

- 7 / 30 / 90 day range selection;
- totals and cost-quality provenance;
- provider ranking and Top 3 + Other chart composition;
- zero-filling missing provider/day pairs;
- bounded breakdown values;
- limit-series grouping, reset evidence, projection and downsampling;
- current banked-reset count and nearest expiry.

It must not own AppKit/SwiftUI colors, fonts, geometry, localized sentences or number formatting.
Each client formats numeric/date values in its own locale and renders through its platform design
system.

Move `UsageLimitDashboardSeries` out of `UI/Design/UsageDashboardView.swift`, and move
`UsagePreferencesViewController.limitSeries(from:)` out of the view controller. The macOS screen
then consumes the same immutable projection that the remote bridge encodes.

## Remote contract

### Feature discovery and release order

Add an optional feature list to `RemoteMeDTO`, with a stable `usage-dashboard` identifier. This is
an additive wire change and does not bump `RemoteProtocol.current`.

Ship in this order:

1. Mac server, feature advertisement and endpoint;
2. iOS client and renderer;
3. any later cleanup only after both released builds coexist safely.

An older iOS app ignores the new field and route. A new iOS app paired with an older Mac sees no
feature and hides Usage.

### Endpoints

Do not add the Usage payload to `/api/me`; the iOS dashboard polls that response every three
seconds. Usage is fetched only while its sheet is visible.

Use dedicated owner-only reads:

- `GET /api/usage` — overview projections for 7, 30 and 90 days, coverage, build state and a
  bounded/paginated limit-series index;
- `GET /api/usage/limit?series=<id>&days=<7|30|90>` — one prepared limit series with at most the
  existing 280 observed points and 120 markers.

The endpoint may trigger the existing non-forced refresh, but returns the most recent immutable
snapshot immediately. Its response carries `isBuilding` and `builtAt`. If no completed report
exists, return an explicit building/empty result rather than blocking a network connection on a
transcript scan. While visible, iOS may re-fetch with a bounded backoff until `isBuilding` becomes
false; it stops on dismissal.

### DTO shape

Add public, Codable, Sendable usage DTOs to `ThreadingRemoteKit`. Carry semantic numeric data:

- timestamps, range and build state;
- token-category totals and cost provenance;
- daily route values for both cost and processed tokens;
- route totals and shares;
- coverage status and source counts;
- limit/account/window stable IDs and display labels;
- utilization samples and segment IDs;
- separately typed projection, reset, banked-reset and expiry markers;
- `bankedResetCount: Int?` and `nextBankedResetExpiresAt: Double?`.

Do not send:

- raw transcript records or text;
- raw `TranscriptUsageReport.Cell` arrays;
- checkout filesystem paths;
- provider credentials, credit IDs or credit titles;
- the raw 180-day journal;
- preformatted currency, percentages or relative dates.

`nil` banked-reset count remains different from zero across Codable round trips.

### Authorization

Introduce or use an explicit owner-whole-host read authority. Do not authorize the route merely
because a bearer may view or interact with one session. Integration tests must prove:

- paired owner: 200;
- view-only guest: 403;
- interactive guest: 403;
- expired/revoked bearer: the existing authorization failure;
- feature advertisement absent from guest `/api/me` payloads.

## iOS presentation

Implement a native SwiftUI `RemoteUsageDashboardView` using `RemoteThemePalette` and
`MobileDesign`.

- Use `ScrollView` + `LazyVStack`; provider and limit indexes are value data and build only visible
  rows.
- Use Swift Charts for the bounded daily stack and limit series. The phone does not reproduce the
  macOS custom chart renderer or Classic Player spectrum geometry.
- Resolve series colors from the semantic remote palette: accent, warning, syntax/status roles and
  an explicit Other treatment. Legends and row labels identify every series independently of
  color.
- Combine the Overview hero and chart into one phone card. Place provider rows below, then a
  two-column adaptive metric grid and coverage disclosure.
- Keep Banked resets in the first visible Limit History summary group, not below the chart or in a
  hidden disclosure.
- Follow Dynamic Type, VoiceOver, Reduce Motion and Increase Contrast. A chart exposes a summary
  and the surrounding rows expose the exact values; chart inspection is supplementary.
- Add pull-to-refresh. Preserve the last successful snapshot while a refresh is in progress and
  mark it with its observation time rather than replacing it with placeholders.

Add a deterministic `THREADING_MOBILE_DEMO=usage` fixture with Overview and Limit History data,
including positive, zero and unavailable banked-reset states.

## macOS alignment

The current macOS Limit History already renders a Banked reset metric card, proven banked-reset
markers and the next expiry. Preserve those behaviors while moving the semantic preparation out of
the UI layer, and tighten the cross-platform contract:

- title the inventory metric **Banked resets** and apply plural-aware detail;
- render authoritative zero distinctly from unavailable;
- keep the next expiry visible in the card and on the chart;
- keep `.bankedCredit` markers distinct from scheduled/provider reset markers;
- ensure account/window changes update inventory and markers together from one projection;
- retain the existing bounded marker and sample budgets.

The AppKit renderer remains responsible for macOS-specific chart motion, pointer/keyboard
inspection, themed materials and the Classic Player spectrum style.

## Scaling gate

Expected ordinary data:

- three fixed Overview ranges;
- up to 90 daily timestamps;
- Top 3 + Other chart series;
- a handful of provider routes and coverage rows;
- tens of account/window choices;
- no more than 280 points and 120 markers for the selected limit series.

Stress data follows the existing dashboard contracts: 100,000 aggregate cells, 250,000 history
samples, 50,000 reset events and externally sized account/window indexes.

Required bounds:

- transcript and journal reads remain off the main actor;
- projection is O(source values) off-main, then main-thread work is O(visible/bounded result);
- the wire never contains raw externally sized stores;
- account/window indexes paginate before encoding and before constructing rows;
- changing metric is O(retained chart points) with no network request;
- changing Overview range is local because all three prepared ranges arrive together;
- changing limit range fetches/prepares only the selected bounded series;
- dismissal cancels in-flight client work and build-state polling.

Set explicit encoded-response ceilings and reject/replace an oversized projection rather than
allowing a corrupt store to become a relay-sized allocation.

## Implementation slices

### Slice 1 — Shared projection and macOS banked-reset contract (complete)

- Extract Foundation-only Overview and Limit History projections.
- Move `UsageLimitDashboardSeries` and history preparation out of UI files.
- Update the macOS dashboard to consume the projection.
- Make zero/unavailable banked-reset states and pluralized labels explicit.
- Preserve rendered output and existing performance budgets.

### Slice 2 — Additive remote surface (complete)

- Add usage DTOs and tolerant Codable tests to `ThreadingRemoteKit`.
- Advertise `usage-dashboard` to owner devices.
- Add owner-only routes, background projection and response-size limits.
- Add server authorization, compatibility and stress tests.

### Slice 3 — iOS Overview (complete)

- Add the Usage sheet and client fetch state.
- Implement the mobile hierarchy: controls, hero/chart, providers, totals and coverage.
- Add loading, stale, empty, offline and partial-coverage states.
- Add the deterministic demo fixture and screenshots.

### Slice 4 — iOS Limit History and banked resets (complete)

- Add the account/window index and selected-series fetch.
- Add current/projected/reset/banked-reset summary cards.
- Render observed, projected, reset and expiry semantics.
- Verify positive, zero, unavailable and expiring reset inventories.

### Slice 5 — Verification and documentation (complete)

- Run macOS fast tests and the Usage stress profiler.
- Run `ThreadingMobileTests` and simulator accessibility/layout checks.
- Render macOS themes plus iPhone light/dark/custom-theme fixtures.
- Update `docs/architecture/usage-dashboard.md` with the shipped cross-platform boundary.
- Update `USER_GUIDE.md` and the iOS localization catalog.

## Test ownership

- `UsageLedgerTests` / projection tests: range totals, Top 3 + Other equality, cost provenance and
  coverage.
- `UsageLimitHistoryTests`: banked-reset proof still requires a decreased credit count, a sharp
  clear and moved reset; zero/unknown inventory semantics.
- `ThreadingRemoteKit` protocol tests: round trips, optional fields, old payload compatibility and
  nil-versus-zero reset counts.
- `RemoteServerIntegrationTests`: owner/guest authorization, feature advertisement, bounded
  response and building/stale behavior.
- `UsageDashboardRenderTests`: macOS banked-reset inventory and markers across themes.
- iOS demo/UI fixtures: compact and large Dynamic Type, light/dark/custom themes, positive/zero/
  unavailable banked resets, partial coverage, loading and offline states.
- performance tests: projection off-main, encoded size ceiling, paginated index, chart budgets and
  cancellation on dismissal.

## Acceptance criteria

- A paired owner can open Usage on iOS without configuring provider credentials on the phone.
- Overview totals for 7, 30 and 90 days match macOS from the same projection and observation time.
- Both platforms show the same selected account's banked-reset count and nearest expiry.
- A provider-reported zero never becomes unavailable, and missing data never becomes zero.
- A chart labels a reset as banked only when the existing evidence rule proves a credit was used.
- Guest shares cannot discover or read host Usage.
- `/api/me` remains small and keeps its existing three-second polling cost.
- No raw transcript, filesystem path, credit identity or unbounded history crosses the wire.
- iOS range/metric interaction remains responsive at the stated bounds and accessible without
  relying on chart color.

## Non-goals

- Scanning transcripts or calling provider usage APIs from iOS.
- Applying a banked reset automatically.
- Combining reset credits across accounts or providers.
- Treating estimated transcript cost as a provider limit.
- Pixel-identical AppKit and SwiftUI charts.
- Offline mutation or a second durable usage authority on the phone. A later encrypted last-good
  snapshot cache may improve offline viewing, but the Mac remains authoritative.
