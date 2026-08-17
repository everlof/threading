# Usage dashboard

The Usage settings page joins two local, provider-neutral stories: transcript accounting answers
what was consumed and what it cost; observed limit history answers how quickly an account's real
provider windows are moving. They share a retained presentation boundary but live in separate
Overview and Limit History tabs, with independent date controls and provenance. An estimated
transcript cost must never become a provider limit, and an observed limit percentage must never
be presented as tokens.

## Independent implementation boundary

The supplied product screenshot was used as a visual hierarchy reference: a clear total and ranked
top-tool split beside a soft time series, followed by quieter supporting metrics and breakdown.
The MIT-licensed Claudex repository at `~/repo/claudex` was inspected to understand the useful
product semantics of retained observations, reset boundaries, weekly projection and expiring
banked resets. No source, prose, asset, expression, or file from either reference was copied,
translated, or adapted into Threading.

Every model, parser, storage format and AppKit view here was designed for Threading's existing
provider contracts, settings lifecycle and theme boundary. There is consequently no imported
third-party file in this change that needs an MIT notice or source header. If a future change does
copy MIT-licensed implementation text, its copyright and permission notice travels with that
copy; this note is not permission to blur that boundary later.

## Two feeds, two tabs

`UsagePreferencesViewController` owns one retained `UsageDashboardView` and coordinates the feeds.
The Overview tab presents transcript accounting; Limit History owns the account-window chooser,
projection summary and observed-history chart:

- `TranscriptUsageService` scans on its utility queue, persists a rebuildable 90-day report, and
  posts `TranscriptUsageDidChange` when the completed report can replace the previous one.
- `UsageHistoryStore` keeps a small main-actor working set while `UsageLimitHistoryJournal` loads
  and appends the 180-day journal through its actor. Opening the page never parses the journal on
  the main actor.
- `AccountUsageService` remains the authority for live provider windows. The page asks discovery
  for accounts with that capability instead of switching on provider names. Claude and Codex have
  routable authoritative sources today; Grok and OpenCode stay visible in coverage rather than
  acquiring invented limit data.

The dashboard receives immutable report and limit-series values. It does not read transcripts,
launch CLIs, call provider endpoints or perform journal I/O.

`UsageDashboardProjector` is the Foundation-only seam between those feeds and presentation. It
prepares all three Overview ranges and both metric rankings on a utility task, including the
top-three-plus-Other daily composition and zero-filled days. It also groups the limit journal and
prepares independent 7/30/90-day histories before AppKit sees them. Range and metric changes are
therefore bounded local model changes rather than a main-actor fold over report cells or journal
records. The same semantic values are the input intended for the owner-only remote bridge; neither
platform renderer receives raw transcript cells or the raw journal.

## The page established the shared Settings canvas

Usage is a total beside its own time series over a table of named columns. It was originally laid
out inside the 620 points used as a prose measure, which is where nearly every visual defect on it
came from at once: the chart got whatever the hero left (288 points for 90 days, three points a
day), five bordered tiles each truncated their own explanation inside a fifth of it, and the value
axis printed `US$100,0…`.

Making only Usage wider fixed those defects but made the Settings canvas jump horizontally when a
reader changed destinations. `SettingsUIDefaults.pageWidth` is now the one shell width for every
built-in and extension-provided Settings page. Its content measure,
`Design.Size.settingsContentWidth`, is **derived rather than picked**: the Usage plot rectangle
keeps the readable measure, its axis gutters are added beside it, and the hero's fixed column is
added again with a pane's air between. The richest legitimate page therefore states the common
canvas once, while form controls retain their compact intrinsic or fixed widths inside it.
`Design.UsageDashboard.minimumContentWidth` remains the floor a squeezed pane leaves, and both
widths are rendered.

Three presentation rules follow from that, and each replaced something that had been quietly
lying:

- **One money vocabulary, in one locale.** `UsageValueFormat` (in `ThreadingRemoteKit`, because the
  phone spells the same prepared values) has an exact form for figures a reader checks against an
  invoice — the hero total, every breakdown cost — and a compact form for a slot whose width is
  fixed by something other than its text: the chart's value axis, a stat in the band. It formats in
  a fixed `en_US` on purpose. A local estimate at published US list prices is a US-dollar figure
  whichever country reads it, and formatting it in the reader's locale does not convert it — it
  only changes the separators and buys an ambiguous `US$` in return.
- **The five supporting measures are one band, not five plates.** `UsageStatBandView` is a single
  quiet container, five equal columns and a hairline between them — a rule that stops short of the
  band's edges, because run out to them it divides the band from itself and collides with an
  authored chrome's own border. System draws no plate at all
  there, while an authored chrome states its own surface exactly as the hero beside it does. The
  empty state is unchanged and load-bearing: titles and a dash, and nothing else (see
  [Before there are numbers](#before-there-are-numbers)).
- **The breakdown is a table with headings.** A ranked list of two-line rows with one right-hand
  figure could not be read down any of its numbers, and that figure silently changed meaning with
  the metric control. The columns are the row's own subject (Model, Project, Account or Provider),
  Cost, Share, Tokens and Requests; only **Share** follows the selected metric. Numerics are set
  against the trailing edge in tabular figures. At the narrow floor the request count stands down
  rather than the table growing a sideways scroller inside a page that already scrolls; the row's
  accessibility value still states all four. The table is `.plain` on purpose: the automatic style
  resolves to `.inset` inside a scroll view and lays the header and rows out shifted
  `systemInsetStylePadding` in from each edge — *after* the columns were fit to the clip exactly,
  which pushed the request column's tail past the table's edge while every width still summed
  right. The fit probe the render tests assert therefore measures the last heading's drawn
  trailing edge as well as the widths' sum, so that shape of lie stays caught.

### Attribution, and what a row may claim

`UsageDashboardBreakdownRowProjection.runtimeID` decides whether a row wears an agent's mark. It is
presentation only, never a second cost axis, and it follows one rule: a row names a runtime only
when **every** record behind it came through that one. `UsageReportSelection` resolves it while it
is already folding cells, so nothing re-reads the ledger — and `nil` is absorbing, because "several
runtimes" and "not known" are the same answer to the only question being asked. A model two agents
both ran, and a checkout worked in from two runtimes, therefore wear no mark rather than the mark of
whichever record was folded in first. A provider row always knows, including a billing route:
OpenRouter's spend came through OpenCode, so it honestly wears OpenCode's.

The mark itself is the app's existing `AgentKind.icon` seam — a brand mark where one exists, the
kind's SF Symbol otherwise — in a fixed-width slot, so every name in the column starts on one line
whether or not its row has one.

### Height, and whose gesture it is

The breakdown grows to fit its rows up to `Design.UsageDashboard.breakdownVisibleRows` and scrolls
past that, instead of holding a fixed 300 points whether it had three rows or three hundred. It is
still an `NSTableView` for the reason it always was — the projection allows 500 rows, and only the
visible ones may become views — which is exactly why it cannot simply grow: the section states its
own bound, and the virtualization keeps it cheap.

A nested viewport that scrolls inside a page that also scrolls has to say which gesture is whose.
`ThemedScrollView.verticalScrollHandoff` is that policy, and the breakdown asks for
`.atContentEnds`: the table keeps a vertical flick while it still has somewhere to go, and hands
the rest — momentum included — to the settings page once it does not. Elasticity is off there
because a rubber band *is* movement, so an elastic viewport never reports that it ran out.

## Cross-platform delivery boundary

macOS and iOS share `UsageDashboardProjector` values, not a view hierarchy. AppKit keeps the
desktop chart renderer, pointer inspection and theme-specific motion. The iPhone uses a native
SwiftUI sheet and Swift Charts over the already bounded values, with the same Overview and Limit
History subjects. Both renderers present banked-reset inventory as three distinct states:
positive, authoritative zero, and unavailable (`nil`). Historical `.bankedCredit` evidence and
the next current-credit expiry remain separately typed markers.

The Mac advertises the additive `usage-dashboard` feature only to paired owner devices with
whole-host read access. `/api/me` carries only that small identifier; it does not acquire Usage
data. The phone fetches data only while the Usage sheet is visible:

- `GET /api/usage` returns the three prepared Overview ranges, coverage and one page of limit
  summaries. Pages default to 48 summaries and are capped at 64; each breakdown kind is capped at
  64 rows, and the encoded response is capped at 384 KiB.
- `GET /api/usage/limit?series=<id>&days=<7|30|90>` prepares only the selected account/window and
  returns at most 280 observations and 118 reset-evidence markers. The encoded detail response is
  capped at 192 KiB.

Both routes authorize before loading report or journal data. A view-only or interactive one-chat
guest receives 403 and never sees the feature identifier; a revoked bearer follows the existing
401 path. The bridge omits raw transcript cells, filesystem paths, provider credentials, credit
identity and the raw history journal.

`RemoteUsageDashboardView` uses a lazy vertical stack and adaptive metric grids. Overview range
and metric changes are local because all three bounded ranges arrive together. Limit range changes
fetch only the selected series. A build-state poll backs off from two to twelve seconds, preserves
the last successful snapshot with its observation time, and stops when the sheet disappears.
Structured load/detail work and explicit pagination work are all cancelled on dismissal. The
deterministic `THREADING_MOBILE_DEMO=usage` family covers Overview plus positive, zero and
unavailable banked-reset inventory.

## Transcript ledger

`UsageLedgerRecord` is the response-level interchange between provider adapters and aggregation.
Five token categories remain separate: uncached input, cached input, cache creation, output and
reasoning. Reasoning is a subset of output and is never added a second time. The record also keeps
session, account, model, checkout directory, runtime and billing route.

Runtime and biller are different axes. An OpenCode session routed through OpenRouter is stored as
runtime `opencode`, biller `openrouter`; that distinction survives cache, aggregation, the ranked
top-tool split, chart and coverage. A direct Claude, Codex, Grok or OpenCode route uses the concise
runtime name.

Adapters make provider wire differences explicit:

| Source | Contract |
|---|---|
| Claude Code | One ledger record per assistant response in supported JSONL transcripts. Cache read and creation remain distinct. Message/request identity deduplicates resumes, compactions, forks and copied subagent responses after all files have joined. |
| Codex | Stateful rollout parsing carries session metadata, working directory and active model into each `token_count`. Codex input includes cached input on the wire, so the adapter subtracts it once. An immediately repeated `last_token_usage` is suppressed without collapsing two later responses that happen to have equal counts. |
| OpenCode | Supported CLI exports provide assistant token counts, model, provider route and reported cost. Export revision is the session's durable activity timestamp, so a warm scan does not launch OpenCode for a dormant session. |
| OpenRouter | It is a billing route reported by an OpenCode export, not a fake fifth runtime. It gets its own coverage row and chart series so routed spend remains visible. |
| Grok | The measured ACP surface exposes current context occupancy, while its supported transcript export is Markdown. That is partial coverage, not a token estimate derived from characters. An authoritative future export can land behind `GrokUsageAdapter` without changing the ledger or dashboard. |

Coverage is data, not an empty-state decoration. The report always carries Claude, Codex, Grok,
OpenCode and OpenRouter rows with `complete`, `partial`, `unavailable` or `failed` state, source and
record counts, and a reason where useful. A plausible-looking total can therefore never imply
whole-machine coverage when one runtime is unreadable.

### Pricing honesty

Pricing follows this order:

1. A finite, non-negative cost reported by the provider or billing route wins.
2. Otherwise, `UsagePricingCatalog` may price an exact official model identifier or its dated
   form with the versioned list-price row.
3. An unmatched or ambiguous identifier remains visibly unpriced; its tokens are still counted.

The catalog is deliberately small and explicit rather than a copied community rate dump. The page
shows its version, splits provider-reported and catalog-priced spend, and reports unpriced tokens
and estimated cache savings. For OpenAI's listed 1.05M-context models, more than 272K total input
tokens applies the documented 2× input and 1.5× output tier to the whole request. A local estimate
is never described as an invoice.

### Incremental scan and aggregation

`UsageScanCache` stores one private envelope per source, keyed by stable FNV-1a of parser id and
source path. File size plus a freshly read modification timestamp invalidates transcript entries;
OpenCode entries use export id plus session revision. The cached value retains every response
identity, so global deduplication happens after cache hits and misses are joined and a warm result
is exactly the cold result. Stale cache entries are removed only inside the private cache directory.
Each envelope is bounded to 64 MiB on both read and write. An externally enlarged entry is a cache
miss and is replaced only after the source is parsed; metadata preflight is not used as allocation
authority.

`UsageLedgerBuilder` deduplicates once, prices once, resolves checkout roots once per directory and
aggregates at the bounded cell grain:

`day × runtime/biller × account × exact model × checkout`

The persisted report keeps at most 90 daily cells per combination plus nine days of quarter-hour
buckets used by the existing spend forecast. Selecting 7, 30 or 90 days folds those cells into
daily provider series and model, account, checkout or provider breakdowns without rescanning disk.

## Durable limit history

Every valid window from `AccountUsage` becomes a `UsageSample` carrying its provider provenance,
account/window identity, observed fraction, scheduled reset, normalized duration, reset-credit
count and nearest credit expiry. Samples are sparse: a record is appended when usage changes by at
least 0.5 percentage points, a reset or credit fact changes, or fifteen minutes pass. This keeps
long history useful without turning a 30-second refresh cadence into millions of identical points.

The durable format is owner-only daily JSONL in Application Support:

- directory permissions `0700`, file permissions `0600`;
- 180-day retention, pruned by UTC day;
- a maximum of 250,000 loaded records and 8 MiB per daily file;
- regular files only, with symbolic links rejected;
- normalized percentages and metadata only—never credentials or transcript text;
- legacy `usage-history.json` samples are enriched and migrated once without duplicate records.

The 8 MiB daily ceiling is enforced by the opened stream, and append rotation uses subtraction
rather than an overflowable `current + incoming` sum. A file changed after metadata inspection
therefore cannot turn the history loader into an unbounded allocation.

The journal is append-only because a damaged line can be skipped without losing its neighbours and
because appending an observation does not rewrite six months of history. The Advanced reset path
can delete the journal through `UsageHistoryStore.deleteHistory()`.

### Reset evidence and projection

A recorded reset requires two surrounding observations: the scheduled reset moved forward, usage
fell sharply, and the post-clear fraction is plausibly low. A clear near the old scheduled time is
`scheduled`. An early Codex clear is `bankedCredit` only when the credit count also decreased;
rolling weekly capacity alone cannot manufacture a reset. Other early provider-proven clears are
recorded as `provider`. Each event states the observation interval because the exact reset instant
is not knowable between polls.

Weekly projection is intentionally narrow. It applies only to measured six-to-eight-day windows,
after at least thirty minutes have elapsed, and extrapolates average consumption from the
provider-reported cycle start. The estimated segment is kept separate from observations and drawn
dashed. The page shows projected 100% when it falls before reset, otherwise projected utilization
at reset; scheduled reset, observed reset, banked-reset expiry and projected exhaustion are
different marker kinds.

The limit chart offers 7, 30 and 90 days while storage retains 180. It keeps discontinuities as
separate segments so a reset is not drawn as consumption in reverse. Downsampling preserves
endpoints, extrema and complete, evenly spaced reset pairs under a hard budget—even a corrupt
history that clears on every reading cannot move unbounded geometry work to the main thread. A
single dashboard chart retains at most 120 reset, expiry and projection markers; reset evidence in
the summary still considers every event in the selected range.

## Reusable chart and motion

`ThemedTimeSeriesChartView` is the independent-series design-system boundary, not a Usage-specific
plot. Its data-only model accepts semantic series styles, optional area fills, explicit or
automatic ranges, value formats, discontinuity segments and reset/expiry/projection markers.
Independent series may overlap and each keeps zero as its own fill baseline. Observed series
default to a bounded monotone cubic curve whose control points remain within adjacent vertical
extents, so a spike cannot create a fabricated overshoot. Callers can request a linear curve for
estimated or contractually straight segments; the limit projection does so explicitly. Area fills
follow the same path.

Two axis behaviours exist because a squeezed pane found their absence: time-axis labels drop to
fewer, evenly re-spaced ones — never closer than `Design.Chart.minimumXLabelSpacing`, floored at
the domain's two ends — rather than letting neighbours collide, and the legend draws whole or not
at all. It already refused to clip half a word beside a colour; keeping one key of four lies the
same way about how many series there are, and hover, keyboard inspection and the accessibility
summary still name every series when the room is not there.

`ThemedStackedBandChartView` is the separate additive composition. Its series must have aligned
timestamps and segment boundaries. Each rendered band starts at the cumulative edge beneath it,
and the last upper edge is therefore the true total—not several independent shapes sharing a
baseline. All bands use the extrema indices chosen from that total, retain the same point budget,
and morph both their lower and upper edges. Invalid unaligned input degrades to independent
rendering rather than displaying a plausible but false sum.

Every ink resolves through `Design`: System uses an open, restrained ground with softer grid and
fill opacity, while Cyberpunk, Neo Brutalism and the other chromes keep their authored surfaces,
borders, typography and semantic palette. Chart presentation is also a material decision. Classic
Player requests `spectrum`: observed fills become segmented analyzer columns on a black sunken
well, additive bands remain distinct, and amber peak caps preserve the Winamp EQ reading. Markers
stay above the columns and unobserved projections remain dashed lines. Imported Classic Player
skins inherit the renderer without a named-theme check.

The component retains at most 240 points per series. Layout finds domains in one pass, avoids a
sort for already ordered data, samples local extrema, bounds hostile segment counts, and caches the
resolved domains and markers so a 60 Hz redraw never scans the raw model. Pointer and keyboard
inspection walk only retained geometry, not a provider-sized array.

Changing range, metric or limit series morphs from the geometry currently on screen. An
interruption therefore continues from its presentation state instead of snapping to the last
target. Switching tabs crossfades the incoming retained surface. A cubic ease is driven by
`CADisplayLink` on macOS 14+, with a 60 Hz common-mode timer on macOS 13. Reduce Motion makes both
paths land synchronously, and a detached chart stops its driver. Hover tooltips, Left/Right Arrow
inspection, a group role, summary value and value-change announcements provide the pointerless and
accessibility paths.

## Before there are numbers

The page has two states that are not the same thing, and for a long time both were one grey
sentence drawn across the middle of the chart: a scan in flight, and a scan that found nothing.
Neither told a reader anything they could act on, and the sentence was repeated verbatim under
five dashed metric cards and beside the hero total, so a dashboard whose entire content was one
line of text printed it six times over a value axis labelled 0/0.2/0.5/0.8/1 for a domain nobody
had measured anything in.

`ThemedChartPlaceholderView` now owns both states (see
[`design-system.md`](design-system.md)), and the dashboard states them once. Empty says what would
fill the page; the cards keep their titles and a dash and say nothing else. The scan states its
own progress:

- `UsageScanProgress` carries the source being read, how many sources are done, and the total.
  `fraction` is `nil` until the total is known, so the counting phase shows a breathing ghost
  rather than a bar pinned at zero.
- `TranscriptUsageService.build` **enumerates every account's transcripts before parsing any of
  them**, so the denominator exists from the first file instead of growing under the bar. Listing
  a directory is the cheap half of that work.
- `UsageScanProgressReporter` bounds the stream. A warm scan answers nearly every file from
  `UsageScanCache` and gets through thousands a second, so a report leaves the scan queue only
  when `UsageScanDefaults.progressInterval` has elapsed or the source being read changes — the
  second condition is what stops "Claude Code" sitting on screen through the whole Codex half. A
  failed OpenCode export still advances the count, because a bar that only counts successes stops
  short of its own end whenever one breaks.
- Progress arrives as `TranscriptUsageScanProgressDidChange`, deliberately separate from
  `TranscriptUsageDidChange`, and reaches the dashboard through `updateScanProgress` rather than
  `update`: the tick changes one line of text and one bar, and rebuilding the hero, five cards,
  the breakdown table and the coverage list ten times a second would be a whole-page rebuild for
  each of them.

A rescan behind a report that is already on screen is a different situation and gets a different
answer: a short strip beside the tabs, never a status over the chart. The page keeps its last
complete snapshot visible by design, so covering it would hide the very thing being refreshed —
and until this existed, pressing **Rebuild** produced no visible change at all until the new
report swapped in. The strip carries the same fraction and disappears when the scan ends.

## Scaling gate and measurements

The repeating breakdown is an `NSTableView`; only visible rows construct AppKit cells. Report
aggregation happens off the main actor. Journal reads are coalesced, then the full 180-day snapshot
is grouped, sorted and capped once on a utility task before its prepared series reach the main
actor. The Overview chart ranks daily provider/billing routes, gives the top three their own
additive bands, and folds every remaining route into an explicit `Other` band. Missing route/day
pairs are zero-filled before charting, so timestamps align and the upper edge equals the complete
daily total. The hero remains a compact top-three split while its total, the chart, breakdown and
coverage all retain every route. Dashboard charts receive daily or pre-downsampled data and then
apply their own hard geometry bound as a second line of defence.

Projection output has named budgets before it crosses to a renderer: 500 rows plus one aggregate
omission row per breakdown, 256 account/window series, 280 observed limit points and 118 reset
events per range. The last two slots in the chart's 120-marker budget remain available for credit
expiry and projected exhaustion. A series retains the full reset count and restored-pace total for
its summary even when its visible reset markers are sampled. `nil` reset-credit inventory remains
distinct from authoritative zero throughout this value boundary.

`UsageDashboardPerformanceTests` is part of the fast plan at meaningful default sizes. The opt-in
`scripts/profile_usage_dashboard.sh` builds the test bundle, then invokes `xctest` directly so the
stress environment reaches the test host (ordinary `xcodebuild test` sanitizes it). The 2026-08-09
Debug run on the local Apple-silicon Mac measured:

| Stress contract | XCTest wall time | Gate |
|---|---:|---:|
| 1,000,000 response records, five runtime/billing routes, 2,000 sessions, 20 accounts, 40 models | 5.453 s | < 45 s |
| 250,000 adversarial limit samples with a clear every other reading, including journal preparation | 0.709 s | < 20 s and ≤ 280 analysis points |
| 2,000 cold then warm source-cache files | 1.336 s | warm < cold and < 15 s |
| 100,000 aggregate cells, 250,000 history samples and 50,000 reset events through the real dashboard | 1.348 s | < 30 s, < 100 visible cell subviews, chart budgets intact |
| 1,000 interrupted transitions, five 2,000-point series per switch | 13.544 s | < 60 s and ≤ 1,200 retained points |
| 120 rendered independent-chart animation frames while retaining five 50,000-point source series | 5.985 s | < 20 s and ≤ 1,200 retained points |
| 120 rendered Classic Player stacked-spectrum frames while retaining five aligned 50,000-point source series | 2.187 s | < 25 s and ≤ 1,200 retained points |

The 2026-08-11 matched projection run used the same 100,000 aggregate cells, 250,000 limit samples
and 50,000 reset events across 300 account/window series, then also built and encoded the bounded
remote page. Its three Debug passes were 3.923 s cold, 2.693 s and 2.658 s.
`UsageDashboardProjectionTests` keeps a < 12 s per-pass alarm and asserts every output budget
above; `scripts/profile_usage_dashboard.sh` runs it after the existing renderer suite under the
same opt-in stress environment.

The thresholds are regression alarms, not target frame times. The actual page switches between at
most 90 daily points per provider or 280 prepared history points; the larger transition fixture is
there to expose accidental raw-array work in animation and interaction paths.

## Verification ownership

- `UsageLedgerTests`, `UsageProviderAdapterTests` and `UsageScanCacheTests`: normalization,
  pricing provenance, direct/routed names, deduplication and cold/warm equality.
- `UsageLimitHistoryTests` and `UsageLimitHistoryJournalTests`: reset proof, projection,
  adversarial bounds, permissions, retention, corruption tolerance and legacy joining.
- `ThemedTimeSeriesChartTests`: independent and stacked geometry, extrema/segment preservation,
  hostile boundary budgets, two-edge stacked interpolation, interrupted presentation geometry,
  Reduce Motion and accessibility.
- `UsageDashboardRenderTests`: separate Overview and Limit History renders under System dark,
  Cyberpunk dark, Neo Brutalism light and Classic Player, with all five coverage rows, top-three
  plus Other chart bounds, selected-tab checks and virtualized breakdown assertions.
- `UsageDashboardPerformanceTests`: default regression sizes and the opt-in stress contracts above.
- `UsageDashboardProjectionTests`: range equality, capped breakdown conservation, nil-versus-zero
  banked-reset inventory, remote encoded-size/page ceilings and three matched 100k/250k/50k
  projection passes.
- `RemoteProtocolTests` and `RemoteServerIntegrationTests`: additive DTO compatibility, owner-only
  feature and route authorization, URL construction and response ceilings.
- `RemoteUsageDashboardTests`: deterministic mobile range/chart budgets plus positive, zero and
  unavailable banked-reset states.
