# Performance Measurement

Self-profiling, command-line captures, and repeatable regression workloads.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The layers answer different questions

No one profiler should try to answer everything:

| Layer | What it answers | Artifact |
|---|---|---|
| `PerformanceRecorder` | Which Threading operation was in flight, and for how long? | OS signposts plus bounded Chrome Trace JSON |
| `MainThreadStallMonitor` | Did the main queue stop servicing events for at least 250 ms? | Kill-safe incident plus automatic Chrome Trace snapshot |
| `MetricKitDiagnostics` | What hangs, crashes, launch, CPU, memory, disk and responsiveness did shipped builds see? | Apple's metrics and diagnostic JSON |
| `/usr/bin/sample` | Which stacks owned CPU during a reproduced slowdown? | Text stack sample |
| `xcrun xctrace` | How did CPU, allocations, hitches, I/O and concurrency interact? | `.trace` bundles |
| Opt-in stress tests | Does the same bounded workload get faster or slower between changes? | Stable `THREADING_PERF` log lines |

This is why the app records semantic spans even though `xctrace` can already sample it.
Sampling can say that AppKit is constructing constraints; the `git.review.render-files`
signpost says *which user operation asked it to*. Conversely, a span can identify the slow
operation but cannot explain its stack, allocations, or kernel activity; that remains the
sampling tools' job.

## Always-on recorder

`PerformanceRecorder` emits one `OSSignposter` interval and keeps one in-memory event for each
coarse operation. The current entry points are:

- application launch;
- display-pane render and hosted-controller installation;
- native-conversation transcript replay and render;
- subagent index/transcript reads, timeline reduction and selected-transcript render;
- project-sidebar tree build, outline reload, structure application and disclosure persistence;
- Git Review's end-to-end load-and-render;
- Git reader queue wait plus work;
- per-turn Git checkpoint capture and private-ref publication;
- each git child process;
- Git Review's main-thread render and file-row construction;
- the debounced attachment scan of a terminal's rendered buffer.

Do not add spans per diff line, table cell, terminal frame, token, or streamed event. A profiler
that changes the hot path is measuring itself. Prefer a nested span only where it separates two
actionable owners, such as background parsing from main-thread view construction.

Turn checkpoints obey the same boundary as review reads. Alternate-index construction, object
writes, ref verification and tree diffs stay off main. Admission/completion wait for their result,
but unrelated repositories have independent ref queues and checkpoint work does not sit behind a
large review parse. Selecting an older Turn N changes only the immutable diff request; the existing
virtual file table and lazy per-row TextKit/image endpoint rendering remain the scaling boundary.

Names are static schema (`StaticString`). Metadata is aggregate and bounded: counts, modes,
results, and byte sizes. Never record repository paths, commit hashes, diff text, prompts,
session IDs, URLs, or account data. The recorder keeps 4,096 completed events, at most 256 active
spans, and 20 files. It writes only under:

```text
~/Library/Application Support/Threading/Performance/
├── Stalls/
├── Traces/
└── MetricKit/
    ├── metrics/
    └── diagnostics/
```

Chrome Trace files open in Perfetto and other viewers that support the `traceEvents` format.
An active operation is exported with `args.incomplete = true`; that is often the most useful
record in a stall snapshot.

## Stall detection

After the first window is shown, `MainThreadStallMonitor` sends a ping to the main queue every
100 ms. If one is unanswered for 250 ms, it first writes a small incident JSON synchronously on
the watchdog's utility queue, then requests a trace. The incident holds the threshold, main-thread
id and at most 16 active semantic spans; if the user force-quits while the queue is still blocked,
that incomplete record survives. Once the queue answers, the same file gains the full duration
and the recorder adds the `main-thread.stall` interval. Both incident files and traces retain the
newest 20; trace exports have a 30-second cooldown.

The watchdog deliberately does not walk or suspend the main thread. Stack collection belongs to
Apple's supported `sample` and `xctrace` tools; the watchdog's reliable job is to preserve the
semantic context that existed before those tools were attached. A support report includes only a
share-safe incident summary — counts, longest observed duration and compile-time operation names.
The bounded metadata and exact timestamps remain owner-local in the incident/trace files; MetricKit
is still the production source for OS-collected hang stacks.

## The composer typing lag, 2026-09-01

Reported as a feeling — writing in a chat "was very slow, lagging behind". The app had already
recorded it exactly: 20 stall incidents that day, arriving in bursts of 1.4-2.0 s roughly every
five seconds. Three of them are worth quoting because of what they do *not* say.

| Incident | Duration | `activeOperations` |
|---|---|---|
| 11:02:27 | 1850 ms | none |
| 11:02:32 | 1793 ms | none |
| 11:01:06 | 2017 ms | `attachments.scan` (66,795 bytes) |

**An empty `activeOperations` is the informative case, not a gap.** It says the blocking work is
covered by no span, so the owner is somewhere the recorder does not instrument — which is where
the search should start rather than stop.

**And the one span that *was* open was a bystander.** `attachments.scan` is declared
`crossesQueues: true`; its 2175 ms is wall time across a worker hop, and its own
`custody_worker_ms` arg read `0.000`. The worker did nothing. The entire span was its continuation
waiting to get back onto a main actor that was already blocked. A span that inflates *because* of
the stall reads exactly like a span that caused one.

### The owner

A 30-second `sample` of the running app, with the `mach_msg` idle branch discarded, put 8.6% of
the main thread in `_dispatch_main_queue_drain` and named the tree under it:

| Frame | Share of main-queue work |
|---|---|
| `AgentWorkloadMonitor.recordActivity` | 62% |
| ...of which `AgentModels` file reads | 48% |

`AgentSessionViewController.terminalSession(_:didProduceOutputOf:)` calls `recordActivity` once
per `ActivityDefaults.workingByteThreshold` — **every 200 bytes an agent prints**. That called
`refresh(at:)` unconditionally, before its own `guard magnitude > 0`, and `refresh` measures the
aggregate across *every* working session: `AgentModels.option` plus `effectiveEffort`, each
independently re-entering `options(for:account:)` and landing in `claudeState`, which read and
parsed a ~90 KB `.claude.json` **with no cache**. The cost is therefore
(output chunks/s) x (working sessions) x 2 parses — quadratic in working sessions, since every
session's output re-measured every other session.

Measured on this machine for a 96 KB `.claude.json`:

| `stat` (mtime + size) | read | `JSONSerialization` | total |
|---|---|---|---|
| 0.0017 ms | 0.0125 ms | 0.7024 ms | 0.7315 ms |

The parse is 96% of the cost. A drain runs every queued block before returning to the run loop, so
a burst of agent output queued many deliveries, they drained as one batch, and keystrokes waited
behind the whole batch. That is the lag.

### Three repairs, each justified on its own

1. **`ProviderSettingsFileCache`** remembers what a CLI's own file parsed to, keyed by path and
   validated against the file's modification date and size *on every call*. Identity is checked
   rather than timed, because the stat is ~430x cheaper than the parse: there is no staleness
   window to trade for the speed, and an unchanged file is never parsed twice. This is the shape
   `rememberedCodexCatalogs` already used for `models_cache.json` — the Claude readers simply
   never got it. It now covers `.claude.json`, `settings.json` and `config.toml`, so
   `ResolvedPermissionMode`'s three consecutive questions are also one parse rather than three.

2. **`recordActivity` no longer measures the workload**, and its guards come first. Neither
   `workingCount` nor `anyAtTopEffort` can change because a session printed 200 more bytes: the
   first moves on `SessionActivityDidChange` and the second on `ProjectsDidChange`, both now
   observed in `start()`. Measuring per pulse could only ever confirm what an event had already
   delivered.

3. **The `MainThreadStallHUDView`** (DEBUG only). The evidence for all of the above was on disk
   the whole time and nobody was told. The pill is quiet when healthy and names the duration and
   the open spans when not — including "no active span", the reading that actually located this
   bug.

### Two neighbours found by the same trace

Both are off the main actor, so they cost CPU and battery rather than latency, and both were
unbounded in the same way — a coalescer that re-ran the instant it was allowed to.

- **`attachments.scan` ran 736 times in one four-minute trace**, mostly over text that had not
  changed: a TUI rewrites its screen in place, so `noteOutput` fires while the bytes under the read
  window stay identical. `TerminalAttachmentObserver` now fingerprints (text hash, byte count,
  row position, current directory, project root) and skips the detection pass when nothing the
  answer depends on has moved. The row position is in the fingerprint deliberately — text can
  repeat while the buffer advances, and an advance must always be scanned.
- **1061 `git` child processes and 46 s of process time** in that same window.
  `GitChangeMonitor` refused to run two summaries at once but re-read the instant one finished, so
  an agent writing files continuously held `needsAnotherRead` set and the reads ran back to back.
  `GitChangeMonitorDefaults.minimumReadInterval` now floors the cadence at 1 s, measured from when
  the previous read *started*. A burst of writes still ends with a reading taken after the last of
  them.

### Regression boundary

`ProviderSettingsFileCacheTests` counts decodes, so a removed cache fails rather than merely
getting slower, and pins the freshness half: a rewritten file is picked up on the next read, a
same-length rewrite is still noticed, and a file caught mid-truncation reads as absent without
being remembered. `ProviderSettingsReadingTests` pins the semantics the cache had to preserve
exactly — first-assignment-wins in `config.toml`, an empty value refusing rather than falling
through to a later one, a longer key not satisfying a shorter one.
`TerminalAttachmentScanReuseTests` asserts on `isScanInFlight` rather than on recorded
attachments, because the recorder is only reached when something was found and so cannot tell
"scanned and found nothing" from "did not scan".

## The iOS dashboard-return hangs, 2026-09-05

Three reports that felt like one problem had different owners.

- Ten of eleven symbolicated UIKit hangs around 1.3 seconds entered
  `RemoteAppModel.performMobileDiagnosticsCapture` on the main actor, then synchronously waited in
  `RemoteDiagnosticJournal.records()`. The journal enumerated files, read bounded suffixes,
  decoded every retained JSON line, sorted timestamps, and only then took the newest records.
- The kill-level watchdog stacks while returning to the main chat list were in
  `LazyVStack.measureEstimates` and `PlatformViewLayoutEngine.sizeThatFits`. The dashboard nested
  one lazy project-group stack around lazy row stacks. To the outer stack each project was one
  giant virtual row, so navigation-transition estimation measured every bridged
  `MobileMorphingTitle` in a 76-session catalogue.
- A separate SIGABRT was Swift exclusivity enforcement: representable dismantling cleared the
  terminal weak reference, its property observer published keyboard availability, and that
  publication re-entered the same AttributeGraph teardown.

The repairs preserve three independent boundaries:

1. Product callers use `recentRecords(maximumCount:)`, `supportReportAsync`, or
   `writeSupportReportAsync`. The journal's existing serial queue owns directory enumeration,
   file reads, JSON decoding, report encoding, and report writes. The recent reader walks journal
   days and lines newest-first, stops when the requested count is satisfied, and shares one
   8-MiB allowance across the whole query. A diagnostics capture rechecks consent, owner, active
   host, LAN route, and connection identity after the worker hop before it uploads.
2. `MobileDashboardCollectionViewController` is the dashboard's only scroll owner. Its diffable
   snapshot has one stable item per chat or terminal; project/type chrome and themed plates are
   collection sections, and `UIHostingConfiguration` mounts the authored SwiftUI row only for a
   visible cell. Updates with unchanged identities reconfigure visible rows, structural updates
   preserve the first visible item and offset, and pull-to-refresh is the collection's native
   refresh control. There is no nested-stack fallback. The deterministic 1,000-row scaling test
   requires all identities in the snapshot while fewer than 40 cells and row hosts are mounted in
   a 393 x 852 viewport.
   The collection continues painting to the page's bottom edge; Search and New are a true overlay,
   with their height added only to the collection's scroll extent. Reserving them with SwiftUI's
   `safeAreaInset` makes a UIKit representable stop at the inset and exposes an opaque full-width
   strip instead of floating pills.
   An authoritative reconnect also compares its `RemoteMeDTO` before assignment: the equality
   guard is outside the `@Published` observer, because that wrapper sends before `didSet` and an
   observer guard would still invalidate the dashboard for an identical catalogue.
   The layout's section provider must return a section for every index it is asked about, and
   must index the same list the snapshot was built from. Both halves shipped wrong. A structural
   update installs the new layout first, so the layout is resolved while the previous, longer
   snapshot is still applied, and the provider answered `nil` for the indices past the new
   section count; `UICollectionViewCompositionalLayout` treats that as an assertion failure, so
   the phone app aborted whenever a group left the catalogue. The provider also indexed the
   unfiltered section list while the snapshot skipped empty sections, which would hand every
   section after an empty one the wrong descriptor. The presented list is now derived once on
   assignment and used by both, and an out-of-range index gets a placeholder section that the
   following snapshot apply immediately replaces.
   `MobileDashboardCollectionPerformanceProbe.exerciseSectionRemoval` is the regression boundary.
3. `TerminalKeyBridge` has explicit attach/detach operations. Detach clears the weak view without
   publishing in `dismantleUIView`; a generation-checked main-actor task reconciles availability
   after the teardown returns, and cannot overwrite a replacement attachment.

Package tests pin newest-record order, count and the oversized-journal tail. Mobile tests pin the
1,000-row mount bound and both sides of deferred terminal detach. Appearance remains covered by
the real iOS dashboard evidence rather than by the structural performance fixture.

### Dashboard scrolling after the collection migration

The collection fixed return-time whole-project measurement, but its repeated rows still used an
estimated compositional height and `UIHostingConfiguration`. A deterministic 1,000-row fixture
made the remaining interactive cost visible: the scroll driver measured 132.567 ms p50 and
154.586 ms p95 synchronous main-thread work, with a 166.677 ms p95 frame gap. A 10-second sample
put 1,965 main-thread samples in `UICollectionView.layoutSubviews`; 826 entered preferred-layout
fitting, and the descendants repeatedly constructed SwiftUI hosts and measured
`MobileMorphingTitle`.

Dashboard rows already have a fixed two-line contract. Their compositional item height is now an
absolute value derived from the same Dynamic Type title and caption fonts, vertical padding,
divider width, and display scale. Preferred-content-size and display-scale changes replace the
layout while preserving the visible anchor. Bounded chrome such as project headings and recovery
cards remains self-sized because its content really is variable.

Removing preferred-size invalidation cut p95 work to 82.732 ms but left visible-row hosting as the
tail. Chat and terminal rows therefore share a native reusable collection cell. It retains the
required `MobileMorphingTitleLabel`, provider/account marks, state glyphs, age and activity column,
the one horizontal swipe recognizer, context menu, and accessibility actions. The themed plate is
still the sole row background owner; the cell paints only row content, divider, and the currently
revealed action strip. SwiftUI continues to own the bounded surrounding chrome.

Three optimized Debug simulator runs of the same 1,000-row down-and-back traversal measured
5.458–5.911 ms p50 and 7.189–7.600 ms p95 main-thread work. Frame-gap p95 was
16.693–16.708 ms, versus 166.677 ms before, and no run mounted more than 16 cells at once. Run the
reproducible clean metric plus diagnostic sample with:

```bash
scripts/profile_threading.sh ios-dashboard-scroll-stress 8 1000 booted
```

The structural regression test requires all 1,000 identities in the diffable snapshot, fewer than
40 mounted cells, every mounted row to use the native reuse pool, and zero hosted row content.
Rendered evidence covers the normal custom-theme dashboard, a partial archive swipe and close,
vertical scrolling begun inside a row, and Accessibility Large expansion.

## Renaming a login in Settings, measured 2026-09-05

Reported as a feeling — "editing the name of an account is just SO SLOW; there must be something
wrong there". The recorder had nothing to offer: the two stall incidents either side of the report
(357 ms at 13:00, 368 ms at 13:08) both carry an empty `activeOperations`, which is the informative
case — **the Accounts page is covered by no span at all.**

`AccountsPreferencesEditingPerformanceTests` (opt-in, `THREADING_STRESS=1`) is the fixture that
answers it: the shipping `AccountsPreferencesViewController` at the real 396-point Settings width,
six fixture logins, in an unshown titled window so the name field can take the field editor —
which is what makes a keystroke cost what it costs in the app. `accountsProvider` is a closure and
no observer is registered, so **discovery and the sidebar's `ProjectsDidChange` reload are both
outside these numbers**; whatever they add is on top.

Debug, Apple silicon, 6 logins, 18 virtual rows, 12 live cells. Layout and draw are timed apart,
because the fixture redraws the whole 396-point pane into a fresh bitmap where the app draws a
dirty rect — a combined number charges the harness to the page, and the first run of this fixture
did exactly that, reporting 15.5 ms per keystroke:

| Operation | Cost |
|---|---|
| `viewWillAppear` reload | 0.2 ms |
| one keystroke, layout | 0.9 ms median, 2.6 ms max |
| commit (`controlTextDidEndEditing`), layout | 102 ms |
| commit, draw | 23 ms |

**Typing is not the problem; committing is.** 125 ms to record one name, with no filesystem and no
notification observers in the fixture at all, is `commitNameEdit` → `reload()` →
`reloadPresentationRows()` → `tableView.reloadData()`: the complete page model is rebuilt and every
live cell discarded and remade because one row's text changed. That is the
[scaling gate](#implementation-time-scaling-gate)'s own rule — a local status change updates the
affected stable identities, it does not clear and rebuild a whole page — applied to a page that
predates it, and `enabledChanged` and the emoji picker take the same route.

125 ms is the floor rather than the reading. In the app that same `reload()` also runs
`AgentAccountDiscovery` (a home-directory scan plus the shell config reads behind
`ShellAliasReader`) and then posts `ProjectsDidChange`, which reloads the sidebar — which is the
shape of the 357 ms and 368 ms stalls the recorder captured either side of the report.

### The owner was not the table

Two structural repairs looked obvious and neither moved the number much, which is the part worth
recording. Restamping only the affected rows instead of the page took the commit from 102 ms to
67 ms. Replacing `NSTableView.reloadData(forRowIndexes:)` with an in-place `install` on the live
cell — on the theory that a table with automatic row heights re-measures its viewport around a
reloaded row — took it to 72 ms, which is to say nowhere.

The experiment that named it was one line: run the identical commit with nothing focused.

| Commit | Cost |
|---|---|
| with the name field holding the field editor | 84 ms |
| with no first responder | 2.8 ms |

Rebuilding the account row removes the `ThemedTextField` AppKit is editing in, and tearing that
text input session down is the cost — the same HIToolbox/IMK activation behind the archive and
switch stalls elsewhere in this document, arriving here as "renaming is slow" instead. **A view
rebuild that happens to contain the first responder is not a cheap view rebuild.**

So the row the edit came *from* is restamped by value — its field is handed the resolved name,
covering trimming and the cleared-field case — and never rebuilt. Every other affected row is
rebuilt in place as before.

### Measured after, same fixture and build

| Operation | Before | After |
|---|---|---|
| one keystroke, layout | 0.9 ms | 0.7 ms |
| commit | 125 ms | **3.9 ms** |
| commit, layout | — | 0.9 ms |
| commit, draw | 23 ms | 15 ms |

And the app-wide half, which the fixture cannot see: the page no longer posts `ProjectsDidChange`
for a presentation edit. `AccountPreferencesStore` already posts `AccountPreferencesDidChange` on
every write; the two surfaces that were relying on the structural event — the sidebar's account
chip and the composer's identity chip — observe that instead and restamp their visible rows. The
sidebar outline rebuild, the transcript and navigation search reindex, the extension fact
republish, the curfew re-evaluation and the remote mirror reconcile no longer happen because
somebody renamed a login.

The regression boundary is `AccountPresentationPropagationTests`: the two page surfaces that print
the name both follow the edit, the page is not rebuilt, a changed roster still rebuilds it, and the
field the edit came from is still in the hierarchy afterwards. `THREADING_STRESS=1` keeps the
timing fixture, whose `commit unfocused` line is what names the owner if this regresses.

Not yet repaired, and the repair is not simply "reload one row": an account's name also appears in
the limits cards below it, so the affected identities are the account row *and* the limit rows that
name it. The fixture stays as the before-case and the regression boundary.

## The transcript index rewrote itself continuously, 2026-09-01

Found in the same session as the typing lag above and unrelated to it: this one never touches the
main thread. A `sample` of the running app put a whole core in `sqlite3_step` under
`TranscriptSearchIndex.updateMetadata`, 2.05 s of CPU in a 6 s window, with the leaf frames in
`fts5NextMethod` -> `sqlite3BtreeNext` -> `pread`. It is off-main, so it produced no stall
incident and showed up only as the app feeling heavy while an agent worked.

**`transcript_search_fts` is an FTS5 virtual table, and FTS5 indexes nothing but its text.**
`source_id` is declared `UNINDEXED`, but so is every other filter column — FTS5 has no b-tree on
any of them, so a `WHERE source_id = ?` is answered by walking the entire index:

```
sqlite> EXPLAIN QUERY PLAN SELECT * FROM transcript_search_fts WHERE source_id = 'x';
`--SCAN transcript_search_fts VIRTUAL TABLE INDEX 0:
```

Every matched row then has its tokens deleted and reinserted, because that is what updating an
FTS5 row means. `reconcile` called this **once per source, on every refresh, unconditionally** —
the comment above the call ("metadata can change without transcript bytes changing") justified
keeping the rows current but not doing it when nothing had changed. `ProjectsDidChange` restarts a
refresh and an agent renaming a session posts one, so on a real working set it ran more or less
continuously.

Measured against the author's real index — **82,688 rows, 351 sources, 138 MB** — with a warm
cache, an exclusive connection and no other load:

| | per source | full pass (351 sources) |
|---|---|---|
| Before: FTS5 scan + re-tokenize | 123 ms | **43.2 s** |
| After: one primary-key lookup | 0.008 ms | **2.6 ms** |

The repair is to ask a table that *is* indexed. `transcript_search_sources` is an ordinary table
keyed by `source_id`, so it now carries a `metadata_signature` — the six values the indexed rows
actually hold, plus the generation they were written under. `updateMetadata` compares against it
and returns; the scan happens only when a project or session is genuinely renamed, archived or
rebuilt, which is when the rows are actually wrong.

**The schema version had to stop being the parser version to do this.** They were one constant, and
the ledger treats a parser change as "re-ingest this transcript from byte zero" — so adding a
column would have silently re-indexed all 138 MB. `schemaVersion` (now 2) moves independently of
`parserVersion` (still 1), and the version-2 step is one `ALTER TABLE`. Existing databases keep
their indexed text and simply carry a null signature, which reads as "never recorded" and costs one
rewrite per source on the first refresh after upgrading, once.

### Regression boundary

The guard is a performance contract, so `TranscriptSearchIndex` exposes `metadataRewriteCount` and
`TranscriptSearchIndexTests` asserts on it directly — a removed guard fails the suite rather than
quietly getting slow again. Five cases pin both halves: repeated identical refreshes rewrite once
and never again; appending to a transcript does not rewrite standing rows; a renamed session and an
archived session both do, exactly once, and are then findable by what they are now; and a reopened
index inherits the recorded signature instead of rewriting every source once per launch. The
existing seven cases in that file cover the correctness the guard must not cost.


## MetricKit

`MetricKitDiagnostics` subscribes only in a real app launch, never in the hosted XCTest process.
It persists both current callbacks and Apple's `pastPayloads`/`pastDiagnosticPayloads`, capped at
20 of each kind. Delivery is delayed, normally aggregates a prior period, and is not guaranteed,
so absence of a payload is not evidence that a run was healthy. The immediate recorder and
MetricKit are complements.

## iPhone Usage history rendering, 2026-09-14

The selected history carries at most 280 observations and 118 reset markers. Normal weekly
history spans 2–13 reset segments; the adversarial fixture uses 119 segments inside that same
wire budget. Requests occur on account/window/period selection and explicit refresh. Scrolling
must retain its offset, and unrelated loading/capacity publication must not rebuild the chart.

The phone previously constructed an area and line mark per observation plus one mark per reset.
Its default area stacking also let separate provider windows participate in one fill computation.
`MobileUsageLimitChart` now retains one equatable snapshot, prepares independent normalized line
and zero-based fill paths, and draws all marks in one clipped Canvas. Swift Charts still owns
the axes; the existing legend and VoiceOver summary describe the same observations, projection,
peaks and reset evidence. Drawing is bounded by the selected snapshot, with no per-point views,
filesystem work or history discovery on a frame callback.

`MobileUsageChartRenderingTests/testSegmentedHistoryRendering` measures mount, layout and raster
of that production component. Fixture and controller construction are outside the clock. These
are Debug iPhone 17 Pro Simulator / iOS 26.5 measurements on the same Mac, four runs per case,
with the first framework-cold run excluded from the three-sample warm median and maximum:

| 280-point case | Native marks median / max | Canvas median / max |
| --- | ---: | ---: |
| 13 segments, 12 reset rules | 54.4 / 56.4 ms | 12.8 / 14.9 ms |
| 119 segments, 118 reset rules | 41.7 / 41.7 ms | 17.1 / 17.1 ms |

Disabling stacking alone was effectively flat in the ordinary case (52.4 ms median), so that
experiment did not close the performance issue. A preliminary harness called the old chart
method without installing its environment and spent time logging SwiftUI warnings; those timings
were discarded. The table uses properly hosted views for both implementations. Simulator Debug
results establish the removed rendering work, not a physical-iPhone frame-rate claim.

The real sheet fixture also reproduced the period-change jump: dropping the old chart and summary
reduced content height from 1,046 to 449 points and clamped offset 180 to the top inset, -70.
The last same-series snapshot now remains mounted during loading and failure, and request
generations prevent old results/errors/deferred loading cleanup from replacing newer state.
`MobileUsagePeriodTests` drives the actual segmented control in a presented sheet, checks pending
and completed scroll continuity, and covers failed and superseded requests and a return to the
already displayed period. Geometry and raster tests pin reset gaps, independent fill baselines,
and containment of out-of-domain ink. The `ios-usage` evidence entry covers the shipping sheet.

## Implementation-time scaling gate

Profiling should confirm an architecture, not be the first time its scaling boundary is named.
Before building a UI or callback, classify both axes:

| Axis | Bounded case | Scaling case |
|---|---|---|
| Cardinality | a fixed schema with a stated small maximum | files, turns, tools, sessions, accounts, extensions, processes, browser records, provider data |
| Frequency | explicit navigation or an occasional settings action | layout, resize, scroll, pointer movement, streaming, polling, filesystem/provider notifications |

If either axis can grow, write its expected and stress values into the implementation or fixture.
If both can grow, the path must be O(visible), O(changed), or explicitly background work; it may
not synchronously rebuild or relayout total content on the main actor. Unknown means scaling, not
"probably short."

### Risk patterns

- **Retained external collections.** Converting every model to an `NSView`, attributed document,
  decoded image, constraint set, or layer makes first paint, layout, theme changes, and memory
  proportional to total content. Keep value rows and let a table, collection, or outline own the
  viewport.
- **One giant virtual row.** A virtual table does not help if one cell contains every credential,
  extension field, changed file, diff hunk, or recursive node. Virtualization has to reach the
  repeating unit.
- **Cosmetic laziness.** Building all detail rows and then passing only a prefix, hiding them, or
  placing them behind a collapsed disclosure still pays their construction and often retains
  them. Cap, page, or branch before materialization. Release content that is no longer needed.
- **Whole-subtree replacement.** Clearing a page or stack and recreating it for one toggle,
  disclosure, appended event, or status change multiplies view construction and Auto Layout.
  Stable identities should support insert/remove/reconfigure of the changed run.
- **Total-content work in hot callbacks.** Layout, resize, scroll, pointer and stream callbacks
  execute at frame or token frequency. They may read cached geometry and touch visible/changed
  rows; they may not enumerate total rows, discover files, decode images, invoke child processes,
  or rebuild documents.
- **Offscreen animation.** A retained view is not active merely because it is unhidden and its
  window is visible. Display links and frame-rate timers must also stop while the view is clipped
  outside every enclosing scroll viewport; otherwise a long document can redraw every animated
  sample on each frame even though only one viewport can contribute pixels. Expensive decorative
  animation should also pause for live and momentum scrolling, then repaint once and resume.
- **Main-actor discovery.** Directory walks, file reads, parsing, image decoding and process waits
  make opening or interacting with an otherwise virtual surface jagged. Prepare immutable model
  data off-main, then mount a bounded viewport on-main.
- **Per-item bounds mistaken for a global bound.** Keeping 400 lines for each of 1,000 files is
  still 400,000 lines. Bound count × retained payload × simultaneous surfaces, not each term in
  isolation. A transport/security maximum can be much larger than a reasonable eager-render cap.
- **Gesture retargeting.** A nested scrollable or interactive component beneath a stationary
  pointer can receive the momentum tail after content moves. Route the entire phased gesture on
  the axis chosen at its beginning; never return from `scrollWheel` in a way that silently drops
  vertical momentum meant for an ancestor.
- **Debounce as camouflage.** Coalescing is correct for redundant events only after one operation
  is bounded. It does not repair a resize tick that still reflows hidden history or invalidates
  every row.
- **Autoreleased returns inside a long loop.** Foundation hands back autoreleased Objective-C
  objects from ordinary-looking Swift calls: `FileHandle.read(upToCount:)` returns `NSData`, and
  `JSONDecoder` leaves an `_NSJSONReader`. A loop over thousands of files drains no pool until it
  returns, so peak memory becomes the *sum* of every iteration's transient bytes rather than the
  largest one. This turned a 4.4 GB cache directory into 4.4 GB of live `NSData` in one usage scan
  (see [`usage-dashboard.md`](usage-dashboard.md)). Per-item work that allocates through
  Objective-C needs `autoreleasepool` at the per-item boundary.

The heuristic is cardinality × row richness × mutation frequency. If two are non-trivial, use a
value model, viewport ownership, stable identity, and a stress fixture by default. A small
fixed-schema form remains free to use a retained stack and wholesale rebuild; recycled-cell
cleanup and one-controller-for-another lifecycle replacement are also not findings by themselves.

### Transcript JSONL scanning contract

JSONL record size is provider data and is not bounded by the 64 KiB read chunk. Codex embeds tool
results in one escaped JSON record: the measured usage corpus includes a 302,608,718-byte rollout
whose longest record is 22,025,450 bytes. In the Debug app, the old forward reader searched the
entire incomplete record again after every chunk and used generic `Data.Collection.firstIndex` for
every byte. A live sample held `codes.threading.usage-index` there for every one of 2,130 samples;
after fifteen minutes its file descriptor had only reached 296 MiB.

`JSONLReader.scanForward` now carries two linear-time invariants. Bytes retained from the prior
chunk have already been searched, so the next search begins at the first appended byte; and newline
discovery uses `memchr` over `Data`'s contiguous storage rather than a per-byte protocol-witness
walk. Record delivery, exact offsets and finite-pass fragment handling remain unchanged. The
ordinary test suite includes an 8 MiB single-record boundary and requires it to scan in under two
seconds in Debug; the fixture is large enough that restoring the prefix rescan fails before a
machine-speed fluctuation matters.

The usage index remains off-main and revision-gated. A changed rollout still requires a complete
stateful parse because its later usage cells inherit session metadata, model and child-boundary
state from earlier records; “incremental” must not mean totals assembled without that context.
The shared reader makes that necessary parse proportional to bytes read rather than bytes times
the number of chunks in a large record.

Parser-version migration is bounded at the physical database generation, not at rows. The former
single-file design put a 7.7-million-record Codex generation beside its 600,000-record replacement,
then reclaimed the former through source cascades in one transaction. A live Debug scan was still
CPU-bound after 22 minutes while its 13 GB database grew a 7 GB WAL. The current parser-version set
instead writes a fresh, per-source-resumable database and keeps the persisted report visible.
After a successful aggregate it checkpoints, atomically commits a small generation manifest, and
retires the old database and sidecars by file unlink. There is no old-row enumeration, cascade, or
deletion WAL on the parser-change path. `UsageScanCacheTests` pins legacy-file immutability before
commit, sidecar retirement, and restart from an abandoned staging generation.

### Project-stats scaling contract

Project count and repository history both scale, while pointer entry can repeat quickly. The
hover card therefore reads persisted aggregate values only; it never walks files, reads history,
or waits for a process on the main actor. Code composition and Git activity have independent
utility queues, in-flight suppression, and freshness clocks, so a slow repository cannot turn
crossing sidebar rows into a process queue or delay another metric. A working project is skipped.

The bundled scc process has a 30-second/32-MiB output bound. Its Git-ignore preflight returns
directory roots rather than walking ignored subtrees into a file roster; both that output and the
expanded exclusion arguments stop at 128 KiB, with a 15-second process bound. An overflow fails
the reading closed instead of launching scc with a partial ignore answer. Git activity is exactly
two bounded queries: one latest commit and at most 20,001 timestamps covering twelve seven-day
buckets, each with a 15-second/512-KiB bound. The 20,001st timestamp proves truncation; the UI
reports `20,000+` and withholds the biased chart. No view cardinality is proportional to files or
commits: the card retains at most the fixed language legend plus twelve bars.

Completion persistence follows the same scaling rule. The main actor publishes one changed
reading and enqueues that exact identity in O(1); a dedicated utility writer owns its own cache
dictionary and folds a burst into at most one verified whole-file rewrite per two-second window.
It deliberately does not retain a main-actor dictionary snapshot, because that would move JSON
off-main while forcing the next mutation to copy every project through copy-on-write.

The 250-project CLI fixture (`scripts/profile_threading.sh project-stats-stress`) writes the same
109,293-byte activity cache through both paths. Across three fresh processes, the old 250
main-actor rewrites took 1,710.727 ms median; the exact worker enqueued all 250 readings in
0.198 ms median and completed one background rewrite in 86.075 ms median, a 95.0% reduction in
total persistence work and removal of the disk/encode/read-back pause from UI publication.
`project-stats.cache-write` records cache kind, final entry count, folded update count, and result
in built-in traces. The independently built CLI artifact at
`/tmp/threading-profiles/20260812T124238Z-project-stats-stress` passed the one-write gate and
measured 528.508 versus 4.202 ms total, with 0.395 ms spent enqueueing from the caller.

Deeper Project Insights must remain outside hover. Its proposed host broker caps time window,
commit count, file count, top-N rows, and graph edges; fast summary facets may refresh passively,
but hotspot, coupling, and ownership facets load only after explicit panel navigation. A display
panel must virtualize repeated rows, while a semantic scene stays under its existing 500-mark
contract.

### Semantic-scene scaling contract

An ordinary semantic scene has tens of marks; its public stress bound is 500, and resize, pointer
movement and hierarchy focus can repeat after it mounts. Marks remain value geometry painted by
one `SemanticSceneView` canvas, not one AppKit control, layer and tracking area per mark. Native
accessibility children are lightweight virtual elements and are materialized only when AppKit asks
for them. Pointer movement uses a fixed normalized-space index, layout and paint touch the marks
that can contribute pixels, and one hierarchy child traversal plus one source-order scan replaces
an ancestor walk for every mark. Branch navigation mutates the retained canvas and never holds an
outgoing 500-mark view tree beside a replacement during animation.
The iPhone projection builds the same branch by one child traversal and one source-order scan;
it does not repeat a full ancestor walk for every SwiftUI mark on each focus-state render.

Colour derivation is per *kind* of mark, not per mark. A hierarchy fill is mixed in Oklab from
the resolved panel — three surface composites and two colour-space round trips inside an
appearance push — and every mark sharing a colour role, depth, enabled state and emphasis paints
the identical result. That was being derived once per mark per repaint, and because hover marked
the whole view dirty, the pointer crossing from one mark to its neighbour re-derived all five
hundred. Fills are now derived once per repaint per distinct key, hover and press invalidate the
affected marks alone, and `draw(_:)` paints only the marks meeting the dirty rectangle — which is
safe because marks keep their order, so a partial repaint layers parents before children exactly
as a whole one does.
`SemanticSceneScalingTests/testAStressedHierarchyDerivesAFillPerKindOfMarkNotPerMark` pins the
bound as a count rather than a duration, so it means the same thing on every machine; the cache is
per-draw, which is why no theme or appearance change can leave a stale colour behind for the next
frame.

Hit testing asks the mark's own shape, not its bounding box. A circle covers π/4 of its
rectangle, and a hierarchy's circle packing makes sibling boxes overlap wherever the circles are
tangent — so rectangle hit testing handed hover, the pointing-hand cursor and the click to a mark
the pointer was not over. `SemanticSceneHitTests` covers the geometry and the click routing.

### Extension scene validation is bounded by the cap it reports

`ExtensionScene.validationIssues` used to append "exceeds maximum item count" and then walk the
oversized array anyway, through a per-item pass and two hierarchy passes that are quadratic in
the number of marks. Measured against the real validator on this machine, Debug:

| marks | issues produced | wall clock |
|---|---|---|
| 500 (the documented cap) | 124,751 | 0.09 s |
| 2,000 | 1,999,001 | 1.5 s |
| 8,000 (fits inside one 1 MiB protocol line) | 31,996,001 | 25.9 s |

Two things were wrong and both are the same mistake: the cap bounded the *report* rather than the
*scan*, and sibling overlap was reported once per colliding pair rather than once per offending
mark. An oversized scene is now answered by its size and nothing else, and within the cap the
overlap report is linear. The 8,000-mark case returns one issue in under a millisecond.
`ExtensionContractTests/testAnOversizedSceneIsAnsweredByItsSizeAlone` and
`testOverlappingSiblingsAreNamedOncePerMarkRatherThanOncePerPair` keep it that way.

### Mobile remote dashboard scaling contract

Project disclosure is a user-frequency structural update: expect tens of projects; exercise
1,000 independent project preferences and the existing 1,000-row collection stress case.
`MobileProjectDisclosureStore` reads/writes one scalar preference per identity, never an archive
of the whole catalogue. The project loop skips a collapsed plate before constructing its row
models or views. Remaining rows keep their diffable identities and viewport reuse, and the
collection preserves its visible anchor through section removal. Catalogue grouping remains a
value-model structural pass; no hidden nested stack is introduced. The 1,000-preference write,
reload and exact-choice verification test took 0.975 s and 1.121 s total in two iOS Simulator Debug runs on
2026-09-14 (including fixture work, not a per-tap latency claim). `SessionDashboardTests` still
pins fewer than 40 mounted cells for 1,000 rows and safe removal of every plate. Expanded and
interactively collapsed shipping-shell captures live in `ios-session-dashboard`.


The dashboard catalogue scales with sessions and its invalidation source can burst when the Mac
applies several store mutations together. The ordinary expectation is tens of sessions and fewer
than five catalogue changes per minute; the stress case is 1,000 sessions with 100 row-change
events arriving in one second.

The initial snapshot and genuinely structural changes may rebuild the scoped catalogue. Ordinary
row/order changes carry one authorised session summary over the existing event socket, so Mac
projection and network work are O(changed). iOS coalesces a delta burst for 50 ms, merges and sorts
the local value catalogue off-main, then publishes once for identity-based visible-row diffing;
structural invalidations are coalesced for 350 ms. The event socket has one bounded exponential
recovery task (1–60 seconds), is torn down in the background, and is never accompanied by
healthy-state REST polling.

The host also bounds the structural fan-out itself. Paired owners reuse one common catalogue
projection for requests arriving within one second; device-specific share metadata is layered on
afterward. Known row, structure, account and theme mutations invalidate that projection
immediately, and the lifetime starts only after a cold projection finishes so a large build cannot
expire itself. Exact-session and exact-terminal guests use the store's identity indexes instead of
walking every project. This is an ephemeral freshness cache, not another durable source of truth.

The reproducible owner-fan-out fixture is
`scripts/profile_threading.sh remote-catalogue-stress 1000`. On the 32-client connection cap, the
same Debug fixture fell from 32 main-actor projections and 16,876.973 ms to one projection and
705.818 ms (23.9x). The metric covers `meResponse` projection and per-device response assembly; it
does not claim to measure HTTP transport or JSON transfer time.

**The bytes, 2026-09-05.** An audit of a day's phone diagnostics put the worst sustained
slowdown on `/api/me`: 34 refreshes at 2.2–3.4 s with about 2.65 s of it `serverWaitMS`, during a
session-relaunch storm that invalidated the one-second projection cache on every relaunch, and the
slowest single refresh at 4.65 s with 3.42 s of it transferring a 78-row catalogue over cellular.
Two things were on the main queue that did not need to be: `JSONEncoder` over the whole catalogue
inside the same `DispatchQueue.main.async` block as the projection, and again for every one of
the thirteen mutation handlers that answer with the catalogue. Now (`RemoteAccessServer
.respondWithCatalogue`) the main-actor phase is the projection plus one comparison; the encoding
and gzip run on a `userInitiated` worker on an immutable payload, and the encoded body is shelved
in `RemoteMeResponseCache` per authorization and catalogue edition until the next invalidation,
bounded by the connection cap. The catalogue names its edition (`RemoteCatalogueRevisionDTO`), a
client sends it back as `If-None-Match`, and an unchanged catalogue is answered `304` with no body
at all. Same Debug fixture, 1,000 sessions: the 32-client fan-out is still one projection
(411.000 ms); one body is 1,225,121 bytes of JSON, 69,750 bytes as gzip (17.6x), encoded once in
57.696 ms off the main actor, and a shelved lookup for the next device is 0.004 ms. The
`THREADING_PERF remote-catalogue-body` line of `RemoteCatalogueScalingTests` is the regression
boundary. At the audit's 78 rows that is roughly 95 KB down to 6 KB on the wire, and nothing at
all for the refreshes that the phone's `MobileRefreshPolicy` now answers from the edition in hand.
Slimming the rows themselves — the two `RemoteTerminalThemeDTO` palettes carried per session are
most of a row's bytes and the dashboard list never draws them — is the next lever if a measured
cellular refresh still exceeds a second after this; `MobileDashboardCacheSnapshot.Session` already
names the thirteen fields the list needs.

Standalone project terminals add one bounded summary per durable terminal to initial and
structural catalogues. Their dashboard group is lazy and keeps no socket, emulator, polling task
or timer per row. Selecting one opens exactly one terminal socket and one bounded replay. Starting
a dormant shell is the only polling path: the selected detail performs at most 30 half-second
catalogue checks, cancels when the host or screen changes, and stops as soon as that terminal is
available; view-only capabilities never enter it.

The project organization groups terminal and chat value summaries by the same project name before
constructing lazy row groups; a project with only terminals still gets one section. The type
organization materializes the same two groups in one of two persisted directions rather than
copying or eagerly interleaving their rows. Both paths remain O(catalogue) preparation and
O(visible) row construction.

Cold launch has the same bound. iOS asynchronously decodes one versioned, presentation-only
last-good catalogue per pairing on a store actor, projects cached rows there, and publishes the
finished value once; no catalogue-sized decode or projection runs in `RemoteAppModel.init` or a
SwiftUI body. Live snapshots are projected and encoded off-main, coalesced to at most one write
per second under a hot delta stream. The optional archive keeps at most eight pairings, at most
2,000 active and 2,000 archived sessions plus 1,000 terminals per pairing, at most 5,000 rows in
one snapshot, 2 MiB of aggregate strings and 4 MiB encoded. Size pressure evicts least-recent
pairings; an individually invalid snapshot leaves the last-good archive untouched.

The pre-catalogue connection card is invariant at one current-operation row. Its activity
treatment keeps one two-second timer, plays one bounded 650 ms LabelMorph fade, and invalidates
the timer when that row is replaced, unmounted, or subject to Reduce Motion. Route cardinality
never adds a view or another timer.

Before this boundary, one visible dashboard issued `/api/me` every three seconds: 1,200 requests
per hour and about 24,000 over 20 visible hours, even with no changes. The healthy steady state is
now zero repeated REST requests: one activation/foreground snapshot, scoped deltas for row
changes, and a coalesced snapshot only for structural changes or socket recovery.

### Mobile created-session startup transaction, 2026-08-23

Moving directly from a submitted draft into its new conversation exposed a transaction boundary
that the old dismiss-and-return flow had hidden. The create response arrived before the Mac's
asynchronous presentation and provider launch made a terminal available. The detail screen then
called the generic dormant-session resume route a second time and polled the complete `/api/me`
catalogue every 500 ms, up to 30 times, while waiting for one row. On the reported store that meant
re-projecting 435 sessions, including 387 archived sessions, on the main actor for every check.
Observed create-to-attach intervals were 14.3 and 42.5 seconds even though the Mac had launched the
provider after 1.5–4.2 seconds and submitted the prompt after 8.4–9.8 seconds. The delay was host
catalogue churn and duplicate lifecycle work, not a slow provider launch.

Created-session startup is now one host-owned transaction. A capable phone requests a compact
response containing the exact authorised session summary and startup state rather than a complete
`me` snapshot, publishes that row locally, and opens its session socket without issuing resume or
polling the catalogue. The Mac owns the bounded wait between creation and terminal registration:
the socket receives `sessionStarting`, attaches when the exact session mirror appears, and fails
after 60 seconds if launch never produces one. The client deadline is deliberately longer so the
host's concrete failure wins. Older clients retain the original full response and older Macs retain
the phone's compatibility fallback; feature negotiation, rather than version guessing, selects the
new path.

Terminal registration happens at `TerminalSessionDelegate.terminalSessionDidStart`, after the PTY
has published its running process identity. An earlier attempt from the controller's pre-launch
edge is necessarily unavailable; treating that attempt as registration lost the only wake-up for
an already-waiting dormant-session socket, leaving the phone on “Opening chat…” until it navigated
away or the startup deadline expired. The process-start callback is shared by local, hosted and
host-fallback launches, so each creates the mirror once at the same authoritative lifecycle edge.

The same changed-entity rule reaches the Mac UI and store. Creation appends one SQLite session row
and emits `sessionAdded`; coalesced title/turn writes also persist their exact session or project
row. The common manual-order, top-level addition mutates one sidebar leaf, its ancestor/index
entries and one outline row. A project-local rebuild remains the correctness fallback when branch
grouping genuinely changes the surrounding structure. The coordinator does not issue a second
reload after the store notification.

The matched one-project / 5,000-session Debug fixture measured the complete add mutation at
**150.351 ms before and 5.550 ms after**. Sidebar work fell from **139.647 ms to 1.039 ms**;
the new path built no tree or shape and spent 0.010 ms in index work and 1.010 ms applying the
outline insertion. In the same after-process, the deliberately retained whole-graph persistence
and full-reload comparisons cost 244.985 ms and 51.045 ms. The performance record is
`/tmp/threading-profiles/20260823T211000Z-created-session-add/project-sidebar-stress.log`.

### Workspace navigator live-edge scaling contract, 2026-08-29

A process-materialized extension navigator may contain 1,000 items and session activity can change
many times during a turn. A live edge therefore cannot rebuild the semantic document, scan every
row, start concurrent process requests, or do work for a navigator hidden behind Native or
Settings. Host-evaluated pipeline navigators have a separate complete-output virtualization
contract below; they do not use this event-action path.

The selected navigator coalesces changed session IDs for one main-queue turn and admits at most 64
unique IDs per request. It keeps one event action in flight; later edges stay in a set for the next
bounded request. The extension may return at most 64 content-only item patches. Collection and
item membership are indexed by stable ID, grid items retain their row index, and the host reloads
only the named outline or grid rows. Patch validation is atomic: an unknown target changes no row
and fails that process generation back to Native. Full replacements and ordinary action patches
increment a shared content revision; a live answer overtaken by either is retried rather than
applied over newer content.

Pending invalidations are bounded to four batches (256 unique session IDs) in addition to the
single in-flight batch. Crossing that bound, a timeout, or any other event-action failure returns
the selected generation to Native rather than leaving stale content presented. A Settings
override stops process dispatch while retaining a bounded set of changed IDs; reopening the
navigator performs its initial load or deferred document refresh first, then drains that catch-up
set through the same single-flight path. A project refresh observed while Settings is visible is
latched without waking the extension process. The catch-up set is container-owned, so replacing a
process generation while Settings is visible cannot silently discard invalidations.

The regression target is a maximum-size 1,000-item virtual collection with a 64-ID burst. The
contract and renderer tests pin request/response ceilings, duplicate coalescing, targeted row
content replacement, retained collection identity, unknown-target failback, and the absence of
event work without `eventActionID`. No per-edge profiler span is added because that would instrument
the hot path at the event frequency; the bounded request and row-level assertions are the durable
gate.

### Extension-fact freshness scaling contract, 2026-08-30

An extension generation may retain 4,096 facts and the navigator stress rate is 600 publications
per minute. Freshness therefore cannot find the next expiry by scanning every retained fact after
each publication, and it cannot allocate one timer per value.

`ExtensionFactRegistry` keeps only the winning provider cell for each subject/key in a
lazy-invalidated min-heap and arms one process timer at its root. Recomputing a changed subject
pushes only changed deadlines; an old heap entry becomes inert when it no longer matches the
current deadline index. The heap rebuilds only after lazy entries exceed twice the active count
(with a 512-entry floor), making repeated refresh O(changed log retained) with bounded retained
debris. The timer is reset only when the earliest deadline changes. At expiry, the heap yields the
due subjects directly and the ordinary exact/256-cell notification boundary applies.

`ExtensionFactRegistryTests` fills the 4,096-fact generation ceiling, republishes one non-earliest
cell 600 times, and asserts that the heap stays below twice the active count while the timer is
armed only once. A separately injected scheduler test advances the clock and fires that timer,
proving stale removal and notification without an intervening registry read.

### Registered navigator fact-catalogue scaling contract, 2026-08-30

An ordinary installation exposes tens or hundreds of live fact definitions. The deterministic
stress boundary is 5,000 winning definitions across 40 providers, below the aggregate security
ceiling while large enough to catch catalogue work accidentally moving onto each menu open or
snapshot refresh. A registered-fact submenu may render only the host-owned None row plus 128 fact
rows, regardless of the registry's total size.

`ExtensionFactRegistry` rebuilds one canonical winning-definition index only when a generation
changes its definition set or the locale changes. Those lifecycle events may inspect the live
definition set; fact publication, freshness expiry, menu opening and navigator snapshot refresh do
not rebuild it. Each usage caches only its sorted 128-definition prefix. Reading a menu is O(128),
including the selected-key replacement rule, and snapshotting is O(consumed keys) for definition
and provider metadata rather than O(all definitions). The navigator host unions the selected keys
with its declared consumption set, so exact notifications for unrelated catalogue entries do no
work and a selected structural key schedules one bounded refresh.

`ExtensionFactRegistryTests.testStressRegisteredFactCatalogWhenEnabled` registers the 5,000
definitions within the per-provider 128-definition boundary, selects a key outside the cached
prefix, and reports registration, catalogue-read and one-key snapshot timings. The test plan
sanitizes custom environment variables, so build the test bundle and run this gated case through
`xcrun xctest` with `THREADING_NAVIGATOR_FACT_CATALOG_STRESS=1`, following the direct-bundle pattern
documented for the other opt-in macOS fixtures below. Ordinary test runs still pin the 128-row cap,
winner precedence, unavailable-selection sentinel and selected-key inclusion without paying for
the stress fixture.

Measured on 2026-08-30 in the Debug M-series fixture: registering all 5,000 definitions across 40
lifecycle commits took **1,487.816 ms**; the selected-outside-prefix catalogue read took
**0.154 ms**, and the one-key snapshot took **0.152 ms**. The emitted record was
`THREADING_PERF navigator-registered-facts definitions=5000 choices=128
registration_ms=1487.816 catalog_ms=0.154 snapshot_ms=0.152`.

### Host-windowed navigator pipeline scaling contract, 2026-08-30

A host-evaluated navigator commonly sees tens or hundreds of sessions; the deterministic stress
boundary is 5,000. A pipeline whose output opts into `hostVirtualized` retains every lightweight,
ordered row identity so the user can navigate and search the complete result, while AppKit row
templates are realized only for the visible range. Pipeline evaluation may inspect and sort the
whole source snapshot on its worker, but mounting and scrolling may not build a view per result.
The existing required `itemLimit` and `truncateWithNotice` fields remain the compatibility fallback:
an older host ignores the optional hint and still presents a bounded 1,000-row result with notice.

The worker-side evaluator is O(n log n) when sorting all matching subjects. The presentation builds
its stable row and destination indexes once off the main actor in O(n). Main-actor destination
selection is O(1), row view ownership is O(visible), a fact patch is O(changed), and a query burst
retains only the newest pending evaluation. Clearing a query restores the selected tail row and its
scroll position without scanning all rows or replacing the collection view.

`ExtensionRendererTests.testStressPipelineNavigatorWhenEnabled` mounts all 5,000 logical rows,
asserts fewer than 50 live template views at both the head and tail, scrolls to and selects row
4,999, filters that source session to row zero, then clears the query and verifies tail selection
and visibility restoration. It also pins one exact fact patch and one 100-keystroke burst. The test
plan sanitizes custom environment variables, so build the test bundle and run this gated case
through `xcrun xctest` with `THREADING_NAVIGATOR_PIPELINE_STRESS=1`, following the direct-bundle
pattern documented for the other opt-in macOS fixtures below.

Measured on 2026-08-30 in the Debug M-series fixture: mounting the complete 5,000-row ordering took
**123.46 ms**, scrolling to and realizing the tail took **8.64 ms**, and the exact one-row patch
took **2.04 ms**. Both the head and tail held **14 live templates**. Enqueuing the final query in
the 100-keystroke burst took **4.66 ms** and the worker/UI result settled in **66.67 ms**. The
emitted record was `THREADING_PERF workspace-navigator-pipeline sessions=5000 logical_rows=5000
live_templates=14 tail_live_templates=14 mount_ms=123.46 tail_ms=8.64 exact_patch_ms=2.04
query_enqueue_ms=4.66 query_settle_ms=66.67`.

### Mobile terminal viewport-lease scaling contract, 2026-08-20

A phone-owned terminal grid is recomputed on every crossed cell boundary — pinch steps, the
keyboard, any animated layout — and each recomputation used to go straight to the Mac as a
viewport lease. A lease is the most expensive message in the protocol: the Mac soft-resets the
session's emulator, reflows its scrollback (10,000 lines), raises SIGWINCH, and the agent answers
with a whole-screen repaint that is appended to the ring and broadcast to every follower — all of
it on the Mac's main thread, serialized with socket admission.

The bound was wrong by a factor of the gesture, not of the schema. An iPhone issue report
("entering a chat that has smaller texts is very much slower", 2026-08-20) correlated with the
Mac journal: one pinch recorded **nineteen** `Remote viewport applied` entries in ~200 ms
(06:29:07.132–07.750), and while that churn drained, `Remote client connected` for the *next*
entered chat lagged its socket by 1.2–12.8 s (06:27:34 → 06:27:47). Entries at 13 pt, before any
pinch, applied exactly one lease and connected in 60–150 ms — the slowdown tracked the small font
because that is when the gesture crosses the most boundaries and the grid is largest.

The contract now: the local renderer follows every deliberate font crossing immediately (the
pinch stays live), but navigation motion is not a sequence of terminal widths.
`RemoteTerminalLayoutView` keeps one settled content width and is clipped by the travelling
destination for both push and interactive Back; its update is O(1), retains one terminal view,
and commits only the final width after the coordinator completes with that terminal still on
screen (or after the same quiet period when UIKit exposes no coordinator). A completed Back
discards the outgoing width before teardown. Keyboard presentation height is clipped live by the
structural host, but SwiftTerm keeps its last committed row grid through the animation and
receives the final height once at `keyboardDidShow` or `keyboardDidHide`. A cancelled transition
that returns to the committed height produces no resize, and teardown discards pending height.
The wire
sees only the first grid of a lease — entering still sizes the agent at once — and after that the
grid that has held still for
`RemoteMobileConnectionDefaults.viewportSettleDelay` (150 ms; crossings inside a moving gesture
arrive 10–60 ms apart in the journal). Release and disconnect cancel a pending settle so a
dismissed chat never resizes the Mac afterwards. The browser client has debounced its fit at
80 ms all along; the iOS client simply never had the same settling.
`RemoteTerminalViewportLeaseTests` holds the boundary: a storm leases once, with the settled
grid; the first grid is immediate; release cancels. `RemoteTerminalLayoutViewTests` holds the
local half: a navigation-width storm leaves SwiftTerm on one grid, a coordinator-less storm
commits only its last width, and 10,000 keyboard presentation frames retain one terminal, report
no intermediate grid, and report exactly one final grid at the stable keyboard state.

The return-to-live-end control shares that frequency boundary. Every accepted UIKit offset can
re-evaluate it, so the check reads only `contentOffset`, the cached cell size/reachable maximum,
and the emulator's current mouse/alternate-buffer mode: O(1), one retained button, no buffer-row
walk, view rebuild, PTY write or viewport lease. A long scroll or continuous output changes only
that button's small presence state; `RemoteTerminalScrollTests` drives both local-scrollback and
program-owned cases through the real SwiftTerm view. Activating it performs one constant-time
UIKit momentum cancellation before the exact tail jump, so a completed reset cannot be displaced
later by the flick velocity that preceded it.

A disconnect and a deliberate leave do not have the same lease lifetime. An unannounced socket
loss keeps the device-keyed grid for the configurable reconnect grace, avoiding two expensive
reflows when iOS briefly backgrounds. Explicit `viewportRelease` and `sessionPark` messages end
the lease immediately: Back means the renderer is gone, so keeping its grid made the desktop stay
at phone size for the default 120-second grace whenever another watcher or the enabled remote
mirror kept the session alive. The immediate path also removes a held lease for the same device,
because socket teardown and the already-sent release frame can reach the main actor in either
order. `RemoteViewportLeaseGraceTests` pins transient disconnect, deliberate release, parking and
that close/release race separately. The grace also exists only while no local Mac renderer is
looking at that chat: a disconnect while the chat is selected restores immediately, and selecting
it after a hold began cancels the held grids. A phone that is still actively rendering remains in
the intersection; Mac visibility cancels the reconnect hold, not a live viewer.

The Mac's authoritative desktop grid is renderer input during attach, never a phone viewport
lease. It may legitimately exceed the phone protocol's 240-column ceiling. SwiftTerm's
`shouldReportSizeChange` hook must therefore guard the delegate notification inside its explicit
`resize(cols:rows:)` path, while the resize still knows its authority. Checking ownership only
after an asynchronous delegate hop is too late: the phone may have taken local ownership by then
and echo a desktop grid such as 268×83 back to the Mac, which correctly refuses it and never
produces the resize repaint the phone is waiting to reveal. The mobile scroll tests exercise the
delegate itself so a present-but-unused suppression hook cannot satisfy this contract.

The remaining grid-independent entry cost was the replay itself: the phone parsed the Mac's
whole 512 KB ring and then trimmed nearly all of it, because its emulator keeps SwiftTerm's
default 500-line scrollback. The client now states a 128 KB `replayBudget` in its auth frame and
the host answers a larger ring with CAN + the ring's newest bytes within budget + a freshly
synthesized repaint of the visible screen (the ring's own seed sits at the head, which is the
part a budget cuts away), then the mode seed as before. Measured on the same fixture
(393×720 pt, 9 pt font, 141×43 authoritative grid, three runs each): full 512 KB ring parsed in
348–357 ms; CAN + 128 KB tail + a ~20 KB repaint parsed in 103–105 ms — ~3.4×, about 250 ms off
every chat entry, cellular transfer down by the same factor. Absent budget (older phones, the
browser client) replays the full ring unchanged. `RemoteTerminalReplayTests` pins the replay
composition and the policy bounds; the truncation writes `Remote replay bounded` to the journal.

The same report surfaced a second event-frequency defect on the phone:
`TerminalViewRepresentable.updateUIView` reapplied the terminal theme on every published
connection change (presence, typing, canSend, the grid), and `installColors` clears the
attribute caches and marks the whole screen dirty — a cold whole-grid repaint per status tick,
measured at 5.3–8.5 ms per reapply in the simulator probe (26×24 grid at 24 pt up to 70×65 at
9 pt, 393×720 pt fixture), growing with cell count exactly as the font shrinks. `apply` now
installs only a changed theme, and the same test file asserts an unchanged theme invalidates no
rows. For reference the probe's grid-independent costs: a 512 KB ring replay parses in
~320–350 ms and the local-viewport reflow after it is 7–10 ms, at every font size.

### Initial phone viewport ownership, 2026-09-12

The first terminal frame is not a viewport lease. `TerminalViewRepresentable` starts with zero
geometry and interprets buffered replay against the Mac's authoritative grid until
`RemoteTerminalLayoutView` commits its first nonempty content layout. That layout hands local
viewport ownership to an interactive phone; a view-only or recorded-grid renderer retains host
ownership. Construction, theme changes and capability publication cannot invent content bounds.

This matters particularly for parked connections: they retain interactive capability, so the
former `UIScreen.main.bounds` construction frame immediately became a phone lease. Seven observed
warm reopenings all sent 60×71 followed by 60×51 or 60×29, 161–255 ms later. Each changed grid can
restart the Mac's SIGWINCH repaint and replace the ordered hydration transaction. Codex's normal
screen history makes repeated resize repair especially expensive; the wire lab deliberately
exercises that shape with its 2,400-line Codex fixture beside Claude's alternate-screen fixture.

The scaling contract remains one mounted terminal and one bounded replay per opening, independent
of the number of visited chats. Initial geometry admission is O(1); later width/keyboard storms
retain the existing settled-layout boundary. A queued size delegate reads only the current grid
of the renderer that still owns the connection, so an obsolete frame or replaced renderer cannot
acquire a lease after its actor hop. `RemoteTerminalInitialViewportTests` exercises actual
SwiftUI representable construction inside a constrained UIKit host, and covers host-grid replay
and a replaced renderer's queued callback. The wire lab starts a fresh probe on `sessionResume`
as well as on a new socket, so warm reopening receives its own complete entry measurement.

This is host-owned renderer and wire lifecycle; extension presentation never owns viewport leases,
replay authority or the ordered `terminalReady` boundary. The 200 ms host-local quiet guard stays
in place: removing duplicate work must not reintroduce partial-screen reveal.

The loopback wire comparison used the same prebuilt Mac fixture host, reset between variants,
2,400 generated history lines, an iPhone 17 Pro Max / iOS 26.5 simulator, 13 pt text and a final
53×44 grid. Both phone builds were ordinary unoptimized Debug builds; three warm opens per
provider followed one cold open. Every warm baseline sent 53×58 then 53×44; every fixed open sent
only 53×44. Median / maximum observations:

| Warm entry measurement | Before | After |
| --- | --- | --- |
| Codex bytes received | 313,022 / 313,022 | 158,585 / 158,585 |
| Codex terminal feed time | 103.24 / 106.39 ms | 53.97 / 56.84 ms |
| Codex connect to reveal | 985.81 / 1,184.41 ms | 889.23 / 1,290.97 ms |
| Claude bytes received | 10,229 / 10,229 | 6,929 / 6,929 |
| Claude terminal feed time | 4.40 / 4.54 ms | 2.95 / 2.97 ms |
| Claude connect to reveal | 573.03 / 573.59 ms | 375.46 / 377.28 ms |

These are iteration measurements, not physical-device Release launch claims. Concurrent Mac
build activity makes the wall-time comparison noisy (Codex's maximum did not improve); the
deterministic result is the eliminated extra lease and repaint, including 49% fewer Codex bytes.
The measured interval starts at connection/resume, not at the dashboard tap. Artifacts live in
`/tmp/threading-profiles/20260912T043729Z-ios-terminal-wire-lab/` (`before.metrics.log`,
`after.metrics.log`, `comparison.json`, and real-shell screenshots).
All 785 ordinary mobile tests passed, including the three new initial-layout regressions and
the existing 10,000-frame keyboard storm, lease, scroll and pool contracts; one unrelated opt-in
attachment stress test was skipped. Mobile tests still use explicit Xcode membership, unlike
the filesystem-synchronized Mac test targets, so the new test file is registered in that target.
The 20 scoped terminal/standalone evidence captures stabilized with every fixture check passing;
inspected keyboard-open/dismissed renders preserve content and restore the editor frame and safe
area. No baselines were changed. The broader `full 5` Mac sweep could not execute: its app link
failed on `UsageScanCache` / `UsageLedgerIndex` `forceRefresh` symbols in separately modified
usage-cache code. That broader check remains unverified; no Mac implementation changed here.
The ordinary iOS Simulator Release build also passed. Physical-iPhone installation and Release
opening measurements remain unverified.

### Mobile host-recovery single-flight contract, 2026-08-22

Host recovery is one operation per Mac, not one operation per socket. An iPhone report captured
the terminal and dashboard event WebSockets losing the same transport within 6 ms. Both recovery
loops then called `RemoteAppModel.refresh()`. Each call advanced `refreshGeneration`, so the
second invalidated the first: a LAN route that answered after 4.0 seconds and a later Tailscale
route that answered were both discarded as `refresh.generationChanged`. Repeated route races
continued for nearly two minutes and live-session sockets reached their 15-second hello deadline
while the Mac and agent processes remained healthy.

The contract now: `MobileHostRefreshSingleFlight` owns at most one catalogue/route task for the
active host. Dashboard recovery, explicit refreshes and any session that truly needs a route all
await that task. Cancelling one screen's waiter does not cancel shared recovery; only a host or app
lifecycle invalidation cancels it, and an old completion is fenced from clearing its replacement.
A session socket first retries the last authenticated route when the catalogue is already online;
it joins or starts host recovery only when a flight exists or the model lacks an authoritative
catalogue. If only one session socket fails while the catalogue remains healthy, its first retry
uses that authenticated route; a second failure escalates into shared host recovery, so an isolated
socket failure cannot retry a stale route forever. The reconnect closure also captures the expected
host id, so a host switch cannot hand an old session a client for the new Mac.
`MobileHostRefreshSingleFlightTests` holds the escalation boundary, coalescing, waiter cancellation,
explicit invalidation, late stale completion and fresh later refreshes.

### A session socket does not dial a dead route blind, 2026-09-02

An iPhone report captured the other failure the single-flight contract left open. The phone
walked off Wi-Fi with a chat open; the terminal socket and the dashboard event socket died within
a millisecond. The dashboard's recovery always re-resolves, and it was back on the Mac over
cellular via Tailscale 2.5 seconds later. The session socket's first retry reused the last
authenticated route, because a successful hello twenty seconds earlier had reset its ladder to
attempt zero and its check for a dashboard flight ran 72 ms before that flight started: both
sockets sleep the same flat second. It dialled the LAN origin that no longer existed, produced no
journal record for the attempt, and would have spent the 15-second hello deadline there before
escalating. The person backed out of the chat at about 13 seconds, which ran a refresh and was
what "fixed" it.

Three rules replace the "one cheap retry first" one:

- **The cheap retry is for a socket the Mac closed on purpose.** `MobileSessionReconnectRequest`
  carries whether a close frame arrived (`URLSessionWebSocketTask.closeCode`, read before the
  task is cancelled, since cancelling writes a code of its own). A close frame proves bytes
  crossed the route on the way down; a socket that died without one may have died of its route
  and re-resolves on the first retry. The `socketReconnectScheduled` record says which
  (`detail: peerClosed` or `routeSuspect`), so the next report can tell them apart.
- **A scheduled dashboard recovery counts as one in flight.** `isDashboardRecoveryPending(for:)`
  is true from the moment the event socket schedules its backoff until that recovery has run,
  not only while the route race exists. Whichever socket wakes first starts the race and the
  other joins it; the 72 ms window is gone without adding jitter.
- **A route that moves supersedes a socket still dialling the old one.** `routeIdentity` is
  derived from the model's published host state; the detail views watch it and hand the new
  client to `RemoteSessionConnection.adoptRoute(_:)`. A hello still waiting or a backoff still
  counting restarts on the new origin at once, and the abandoned attempt gets the terminal
  `socketEnded` record (`result: superseded`, `reason: routeChanged`) every connect is owed. A
  connected socket is left alone: it is either fine or about to say it is not, and its own
  reconnect asks the model for the current route. The route race can also flip between two
  healthy routes (the Tailscale candidate won over Wi-Fi at 04:35:26 in the same report), so
  adoption may restart a sub-second connect that would have succeeded; that costs one handshake
  and is accepted for a deterministic rule.

The client still has no `NWPathMonitor` on the connection path; a Wi-Fi to cellular switch is
learned from a socket dying of it. `RemoteConnectionFailureTests` holds the first-retry request,
the superseded hello, the superseded backoff and the untouched connected socket;
`MobileHostRefreshSingleFlightTests` holds the policy table.

### Token-free iOS terminal wire lab, 2026-08-20

A static ANSI fixture proves rendering but cannot benchmark the entry path that flickered: it
bypasses the Mac PTY, capture ring, replay budget, WebSocket scheduling, phone-owned viewport
lease, SIGWINCH and the TUI's resize repaint. Running a live provider for every comparison fixes
that fidelity problem by introducing account state, network variance, private transcript data
and paid turns. Neither is an acceptable performance baseline.

`scripts/profile_threading.sh ios-terminal-wire-lab [history-lines] [simulator] [admission-delay-ms]`
now runs the middle path under the shipping boundaries. An isolated hosted XCTest creates two
real terminal sessions, starts the generated Codex- and Claude-shaped helpers on real raw-mode
PTYs, and serves them through `RemoteAccessServer` and `RemoteSessionMirrorRegistry`. A Debug
`-O` iOS build gets a loopback-only ephemeral pairing and uses the ordinary dashboard, session
navigation, `RemoteSessionConnection`, WebSocket and SwiftTerm surface. The pairing, continuity,
discovery and notification state are isolated from the simulator's ordinary app data. The bearer is a
fixed test authority and no provider executable, credential, API or token is consulted.

The two workloads deliberately disagree where provider behavior changes the cost model:

- Codex leaves alternate screen, fills normal terminal scrollback, and on every real PTY width
  change clears and re-emits the generated history. Ordinary one-finger movement measures local
  scrollback.
- Claude enters alternate screen with SGR mouse reporting, fills the host ring with previous
  complete frames, redraws its composer while typing, and answers wheel reports and resize with
  application-owned full-screen repaints. A swipe delivers several reports in one PTY read, so
  its fixture parser removes each report by the distance from `Data.startIndex`, never by treating
  an absolute `Data.Index` as a byte count; a regression drains one batch and then accepts the
  next report.

The opt-in probe is absent from Release builds. While this lab link is active it writes bounded
`THREADING_PERF ios-terminal-*` records for connect→hello→first bytes→SwiftTerm feed→next display
tick→quiet settle, viewport-message count, keystroke repaint cost, Return→stream settle, normal
scroll event gaps, and alternate-screen wheel→response/display. It also counts clear-screen,
clear-history and alternate-screen sequences during entry. The driver copies the metrics and a
final real-shell screenshot into the run directory under `/tmp/threading-profiles` when Return is
pressed in its terminal. Re-enter both chats in one run: successive `attempt` values are the
push/pop comparison rather than separate process launches with different caches.

The optional admission delay is a deterministic reproduction for remote typing that feels
sticky while the socket itself is healthy. A value such as `750` pauses the hosted Debug Mac at
the same main-queue boundary used by direct terminal input and atomic prompt submission. Run the
lab once with `0` and once with `750`; the delayed run reports
`ios-terminal-input-probe round_trip_ms`, `ios-terminal-typing first_response_ms`, and
`ios-terminal-turn submit_to_first_bytes_ms` without consulting a provider or carrying typed
bytes in the measurements. The fixture is accepted only by the token-free hosted test and is
compiled out of Release builds.

The first real Codex run exposed the remaining flicker as scheduling, not parser cost. Its resize
repair arrived in 154 binary frames over 2.0 seconds; SwiftTerm spent only 61 ms feeding them, but
38 display-link ticks ran after some frames and before later ones. The phone was therefore drawing
valid but temporary clear/reflow states. A busy-host run also paused 695 ms between the attach
replay and the SIGWINCH repair, which proved that the former 250 ms probe quiet period — and a
first 500 ms reveal experiment — could both declare the surface stable too early.

Initial terminal entry is one presentation transaction, but network silence is no longer its
commit signal. A host that advertises `terminalHydrationBoundary` receives a request id on each
viewport generation sent before reveal. After applying that grid, the Mac observes the first
local PTY output burst caused by SIGWINCH, closes it after 200 ms of *host-local* quiet, then
queues one authoritative screen seed, the current mode seed, and `terminalReady(requestID:)` on the same
connection. SwiftTerm still mounts and parses every earlier frame behind `Opening chat…`; the
matching ordered boundary reveals it. Wi-Fi packet gaps can delay the whole transaction but can
no longer restart a second phone-side quiet timer or expose the resize repaint. The Mac closes a
TUI that does not repaint after one second and continuous output after three; the phone retains a
four-second escape for a capable host that never sends its boundary. Earlier hosts keep the
conservative one-second client-silence behavior. The request id prevents a delayed boundary for
an old grid from revealing a newer transaction, and a boundary received before SwiftTerm mounts
waits behind the buffered binary frames before it can reveal.

The same optimized 2,400-row real-PTY lab on 2026-08-21 measured three push/pop entries per
provider. Codex revealed in 759 ms cold and 560/606 ms warm (606 ms median), versus the corrected
2.49-second run above: about 1.88 seconds, or 76%, off the median entry. Claude revealed in 397 ms
cold and 336/353 ms warm (353 ms median). Codex still consumed 155–157 binary frames because its
fixture deliberately re-emits all history at the new width; feed work was only 40–64 ms and stayed
behind the boundary. Frame-by-frame inspection of the simulator recording shows only the loader
followed by one complete, stable terminal for both providers. The run artifacts are
`/tmp/threading-profiles/20260821T100838Z-ios-terminal-wire-lab`.

A second instrumented pass found that those feed/settle numbers did not prove the placeholder's
own lifetime. A viewport message used to install its new hydration request id while the message
was *constructed*, before `send` rejected a duplicate grid. If layout crossed another cell count
and settled back on the grid already leased, that unsent id replaced the generation actually on
the wire. The Mac returned the correct ordered boundary, but the phone treated it as stale; since
the host had advertised the boundary, the legacy one-second fallback was deliberately disabled
and the visible loader survived until the four-second emergency timeout. Request-id ownership now
moves only after the duplicate guard, beside the update of `lastSentTerminalViewport`.
`testAnUnsentDuplicateViewportCannotReplaceTheHydrationGeneration` holds that exact return-to-the-
same-grid case.

The same pass removed transport callback amplification below the terminal protocol. SwiftTerm's
`DispatchIO` read is 128 KB, but Darwin commonly delivered it as roughly 1 KB partial callbacks;
each partial became a main-thread emulator feed, capture update and WebSocket frame. Adjacent
fragments that are already waiting when the main-queue drain runs are now joined into bounded
128 KB deliveries. There is no coalescing timer, so an isolated keystroke/output fragment is still
delivered immediately; the existing time slice, generation checks and 4 MB/1 MB backpressure
remain intact. The 8 MiB backpressure test still passes, and a new 512 KiB fixture asserts exact
byte delivery with a bounded callback count.

With both repairs, three entries per provider measured Codex at 742 ms cold and 553/542 ms warm
(547 ms warm median) and Claude at 376 ms cold and 359/375 ms warm (367 ms warm median). Codex
fell from 155–157 output frames to seven; Claude fell from seven to five. Every capable-host run
sent one hydration request id and received one matching `terminalReady`; marker-to-reveal was
0.04–0.07 ms. The warm Codex path was approximately 113 ms to hello, 15 ms from hello to the
viewport, 235 ms for the resize repair to reach the phone, and 184 ms from its last repaint frame
to the final seed. Warm Claude was approximately 116 ms to hello, 19 ms to the viewport, 37 ms to
the repaint and 195 ms to the final seed. The last interval is the Mac's nominal 200 ms local
quiet boundary. Observed repaint/final-seed gaps still reached 208 ms, so reducing that guard
without a provider-owned repaint-complete signal would trade latency for the original partial
reveal. Frame-by-frame inspection at 500 ms intervals again shows only the loader followed by one
complete terminal. The measured artifacts are
`/tmp/threading-profiles/20260821T131423Z-ios-terminal-wire-lab`.

Starting a session socket from the row tap rather than the detail's task is not useful: the real
view is created 9–12 ms after connection start, so it can recover only that small scheduling
slice. Preconnecting dashboard rows would violate the catalogue scaling contract above by adding
sockets, replay buffers and terminal capture per candidate.

The separate bounded-cache experiment now ships as iOS session connection reuse. Pop sends
`sessionPark`; the Mac runs the complete mirror detach path before acknowledging it, so the socket
receives no PTY output or conversation deltas, owns no viewport or hydration transaction, leaves
presence/input control, and retains no SwiftTerm renderer. Only the authenticated WebSocket stays
warm. Push sends `sessionResume`, and the ordinary startup-aware attach path — the same one a
fresh `hello` takes — supplies a new authoritative hello, bounded replay or conversation snapshot,
collaboration state and hydration boundary. It therefore removes the roughly 110 ms
TLS/WebSocket/auth handshake without letting stale output or a stale grid leak into the new view.

Saving the handshake is all it saves. A parked transport cannot start a chat that stopped while it
was held, so push settles readiness first and consults the pool only for a chat that was already
live — which is every warm hit the pool has ever recorded. A chat that has to be woken pays the
handshake, which is immaterial next to launching the process. Reusing the transport regardless
turned a dormant chat into a refusal the user read as "Session closed on Mac"; see
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md).

Its scaling contract is explicit: the default is three parked transports for 60 seconds; the
device setting is bounded to 0–8 transports and 5–300 seconds. Park, lookup and eviction do O(1)
work at that bound, terminal history remains the one host-side per-session ring rather than a
per-parked-client buffer, and parked clients are absent from subscriber fan-out. Telemetry is one
fixed-size aggregate value—hits, misses, expiry/eviction causes, occupancy, totals/maxima and six
age buckets—not an event or session history. Reducing either setting evicts excess state
immediately; backgrounding or a memory warning drains it.

The warm transport also means an outgoing and incoming SwiftTerm representable can briefly name
the same `RemoteSessionConnection`. Terminal delivery and the viewport lease therefore belong to
an explicit renderer identity. Mounting a replacement supersedes the old identity atomically;
dismantling releases callbacks and the lease only if that renderer still owns them. An
unconditional teardown can leave the new screen on a healthy socket with incoming repaint bytes
buffered invisibly—the typing then appears only after another reopen flushes that buffer.

### Scaling audit, 2026-08-08

The Tools page prompted a repository sweep for the patterns above. This is a risk inventory, not a
claim that every item is already user-visible at ordinary scale. Priorities reflect how directly
external data reaches eager AppKit work.

| Priority | Surface | Concrete risk |
|---|---|---|
| Resolved | `ChangedFilesCardView` | The tree is a value projection rendered by reusable table cells against the conversation's outer viewport; collapsed descendants own no views, and one retained card shares a 2,000-line preview budget across files. The before/after measurements are below. |
| Resolved | Extension panels | The complete 500-node value is still validated atomically, but nested vertical stacks are flattened into reusable table rows. A maximum-contract panel retains only a viewport of native controls, and replacement updates reload value rows instead of rebuilding the whole recursive view tree. The before/after measurements are below. |
| Resolved | Extensions preferences | The 256-package inventory is a value-row model in one grouped table. Collapsed packages own only row identities; disclosure inserts one package's detail identities, and inventory/status events recycle only the viewport while preserving the clip origin. The before/after measurements are below. |
| Resolved | Extension settings | Settings allow 128 fields per extension and built-in pages aggregate contributions from multiple extensions. Extension fields are now individual virtual rows in both the shared host and Tools page; the before/after measurements are below. |
| Resolved | Browser baseline library | The 200-record value model is presented by reusable table rows. Only a viewport of cards exists; screenshot reads, SHA-256 and source inspection run off-main with reuse cancellation, while the main actor performs only a row-sized decode and assignment. The before/after measurements are below. |
| Resolved | File pane refresh | Directory enumeration, resource-value reads, natural sorting and snapshot signatures now run off-main for initial load, hot refresh and disclosure. Main-actor reconciliation preserves node identity with a sorted merge; equal signatures skip both reconciliation and AppKit reload. The before/after measurements are below. |
| Resolved | Archived settings | The archive is a cheap value-row model in one grouped table. The recent fold owns ten session identities; expansion inserts the older identities, and project events recycle only the viewport while preserving the clip origin. The before/after measurements are below. |
| Resolved | Tools dynamic sections | Tool rows, extension-contributed settings, persistent website origins and Browser Sign-In inventories are all value rows in the same grouped table. Provider, credential and exemption mutations refresh cheap snapshots and recycle only the viewport. |
| Resolved | Settings search results | An installed extension can contribute up to eight searchable pages, so the 256-package ceiling can produce 2,048 extension results before built-ins. Results now render in the sidebar itself (2026-08-13 redesign: setting-level rows that jump to the row); that stack is retained and rebuilt per keystroke, so a search caps construction at `SettingsSidebar.Defaults.maximumResultRows` and prints what it cut. The stress fixture drives 2,048 pages through the real sidebar. |
| Resolved | Git Review watched refresh | A build can expose ~9,000 generated files / ~80,000 changed lines and refresh repeatedly. The pane now reconciles stable paths in place, anchors by path + within-row offset, and defers model/height mutations until live scrolling ends. A scroller-thumb drag uses geometry-preserving identity rows and materializes full TextKit only for the resting viewport. |
| Resolved | Git Review during live resize | The 8,985-file fixture now drives 48 distinct widths through the real layout callback. Complete-index height invalidation averages 6.08 ms, with 6.66 ms p95 and 10.49 ms max, while preserving correct offscreen wrapping estimates and scrollbar extent. |
| Resolved | Session status card provider, usage and attachment scale | Checkout bursts debounce for 500 ms; provider reads cache the unchanged branch + HEAD for 15 seconds and poll every 30 seconds only while checks are pending. Transcript usage scans and lifetime-cell indexing run off-main; a refresh visits only the selected parent/child identities, remembers 32 recent sessions, and retains six model details. The card itself stays fixed-row. Subagents annotates its existing virtualized rows. Attachment projection bounds before view configuration at three recent rows plus one optional View all route, independent of the session's attachment count. |
| Resolved | Live run plans in terminal, Chat and remote clients | Terminal hooks and transcript catch-up share one serial off-main reducer and call-id dedupe set. JSONL scanning resumes from a persistent byte cursor, reads bounded passes, and resets only when the file changes identity or truncates; ANSI and emulator rows are never scanned. Provider admission retains at most 256 steps, 4,096 UTF-8 bytes per title, 1,024 per identifier, 512 pending incremental mutations and 4,096 observed mutations per turn; violations withdraw the plan instead of retaining a partial or stale projection. The compact Mac surfaces retain one summary. Full Mac checklists use reusable table rows, while remote clients receive one summary plus revision-bound 64-row pages and iOS materializes them through `LazyVStack`. Turn end sends an authoritative clear rather than retaining a historical plan. |
| Resolved | Account settings cold discovery | A fresh-process fixture separates real home-directory/login-marker/shell-alias discovery from page construction. Five accounts take 6.61 ms to discover, 12.31 ms to render and 8.14 ms to lay out; the seven-second cache makes subsequent callers lock-cheap. |
| Resolved | Accounts settings inventory | Provider discovery has no view-layer ceiling. Accounts and their closed limit folds are value rows in one grouped table; a 120-account fixture exceeds 240 rows while materializing less than half the inventory and passing the theme-boundary audit. |
| Resolved | Usage Windows account fleet | The settings page keeps stable account-row identities. A 120-account fixture scrolls into the fleet, then proves an account-usage or poke event evaluates only the named account instead of rebuilding every row. |
| Resolved | Storage settings findings | Project and checkout discovery has no product cap. The page retains one value-row inventory and virtualizes checkout, disclosure and artifact rows; a 120-checkout fixture preserves its deep scroll position across a scan event, while an action retains exact artifact IDs rather than encoding provider-sized coordinates in control tags. |
| Resolved | Keyboard provider commands | Extension commands and project scripts are value rows whose shortcut recorders exist only in visible cells. A 2,000-command expanded fixture produces 2,004 virtual rows, materializes less than half, and preserves its deep clip origin across registry refresh. |
| Resolved | Single-account usage popover | Providers may report one limit window per model. The popover keeps fixed header/footer chrome around a bounded virtual table; a 2,001-window fixture materializes fewer than 40 rows and preserves its deep clip origin when readings refresh. Observation time is injected once per refresh so every visible row and the footer describe the same instant. |
| Resolved | Compact usage chrome and menus | Toolbar/composer readings admit three complete windows and state the omitted count; their tooltip and accessibility projections use the same bound. Account/model menu rows cap metrics and toned segments at three, while the menu-wide comparison plan admits three distinct columns. The 2,000-window and 2,000-column fixtures prove excluded provider values cannot grow attributed state or widen the fixed 440-point menu; the virtual popover remains the complete inventory. |
| Resolved | Usage dashboard | The report scans off-main with per-source metadata caches, aggregates to 90-day cells and globally deduplicates cached plus fresh records. The breakdown uses virtual table rows, the 180-day journal loads through an actor, and both history analysis and the reusable chart enforce adversarial point budgets. The million-record profile and measured gates live in [`usage-dashboard.md`](usage-dashboard.md#scaling-gate-and-measurements). |
| Resolved | Attachment preview cold open | The pane installs only the selected format's surface on first use, and its document boundary independently installs PDFKit or Quick Look only when that renderer is selected. Regression coverage pins the unused renderers as absent. |
| Resolved | Agent charts | `ChartSpec` caps the product at 240 marks and one drawn chart view owns prepared geometry. Maximum-contract decode/update work stays below 0.45 ms per spec and synchronous paint below 5.5 ms per sampled frame. |
| Resolved | Conversation Markdown, Compare text, Subagents summary and prompt images | A main-conversation answer plans pages before styling and materializes at most 48 Markdown blocks / 96 source lines per reachable page, preventing nested block budgets from multiplying; list pages hold 64 rows and table pages hold at most 48 body rows × 8 columns in the direct-layout table. Compare has one 300-line display budget and one TextKit view across the complete hunk set while retaining the complete export model. The child navigator pages before constructing more than 40 rows and moves to a new external selection without snapping back during live updates. The composer retains at most 32 thumbnails, prepares them serially with bounded ImageIO rasterization off-main, and keeps overflow as literal paths. |

Installed-extension discovery has a separate refusal boundary from presentation: enumeration stops
one entry past 1,024 visible names and inventory refuses more than 256 package directories before
loading any manifest. Those safety/cardinality ceilings now feed a viewport-owned preferences
table; they are not used as an excuse to retain 256 AppKit cards.

The same sweep found bounded uses that should not be "fixed" merely because they match a text
search: Advanced, General, Profile and Keyboard's core preferences are fixed-schema. Keyboard's
extension-command and project-script folds coordinate disclosure only; expanded provider content
is virtualized rather than constructed inside the fold. Usage virtualizes repeating breakdown and
provider-window rows and bounds both retained report cells and chart geometry;
File and project trees use virtual outline cells; conversation Markdown uses virtual or bounded
block pages, with independently bounded list/table pages;
and cell hosts removing old subviews during reuse is the intended ownership boundary.

The stress sweep below replaced that risk-only ordering with measurements. Extensions preferences,
extension settings, the changed-files card, browser baseline library, Archived settings and
maximum-contract extension panels are repaired. Archived settings became the smallest proof case
for the cosmetic-laziness rule. Attachment preview cold open was repaired
at both lazy boundaries: the pane installs one format surface, then the document surface installs
PDFKit or Quick Look. Account discovery's fresh-process measurement stays below one 60 Hz frame
for the filesystem phase; its caching and presentation split should remain until a controlled
fixture proves a real slow-filesystem case rather than adding placeholder state speculatively.

### Scaling-audit stress baselines

Three opt-in fixtures now exercise the high-risk surfaces through their production controllers and
renderers. Each scale/theme point runs in a fresh XCTest process, keeping cold footprint and
construction results independent. Fixture manufacture is reported separately and excluded from
the UI times. The 2026-08-08 Debug sweep used the local Apple-silicon Mac:

| Surface and valid scale | Cold UI | Mutation / viewport | Retained result |
|---|---:|---:|---:|
| Changed-files card, 1,000 files, collapsed | 184–189 ms construction + 1,676–1,679 ms layout | Expand all: 244–249 ms | 1 visible of 1,001 row views; 5,016 descendants; 245–246 MB |
| Changed-files previews, 174 files × 400 retained lines | 42–46 ms construction + 103–107 ms layout | Preview derivation: 0.9 ms | 13.6–13.7 MB model + 20.8 MB views |
| Extension panel, 500 semantic nodes | 29 ms render + 232–245 ms layout | Generation replacement: 261–275 ms; draw: 55–58 ms/frame | 707 descendants; 51–67 MB |
| Extensions preferences, 256 installed packages | 457–509 ms construction + **5,317–5,478 ms layout** | One disclosure: **6,017–6,282 ms** | 3,601 descendants; 197–198 MB |
| Archived settings, 250 conversations | 74.0 ms construction + 31.7 ms layout | Expand: 146.4 ms mutation + **1,912.8 ms layout**; unchanged event: 303.0 ms + 1,897.1 ms | 2,776 expanded descendants; 96.6 MB |
| Tools Browser Sign-In, 250 submission exemptions | 31.8 ms construction + **2,247.3 ms layout** | No separate mutation phase | 2,310 descendants; 112.4 MB |
| Settings search, 250 results | 162.1 ms construction + **1,169.2 ms layout** | Query update: 384.4 ms mutation + **1,096.1 ms layout** | 2,761 descendants; 87.0 MB |
| Extension settings, one 128-field extension | 63–77 ms render + 941–945 ms layout | Draw: 30–35 ms/frame | 1,169 descendants; 54–61 MB |
| Extension settings, four 128-field extensions | 211–215 ms render + **56,841–61,485 ms layout** | Draw: 47 ms System / 121 ms Neo Brutalism | 4,640 descendants; 292–307 MB |
| Browser baseline library, 200 records | 170–178 ms render + 507–559 ms layout | One permission toggle: 679–742 ms; draw: 24 ms System / **544 ms Neo Brutalism** | 2,411 descendants; 119 MB System / 217 MB Neo Brutalism |

The extension-settings result is a superlinear Auto Layout cliff, not just 512 moderately expensive
rows: increasing the aggregate from 128 to 512 fields multiplies layout by roughly sixty. The
production boundary permits 128 fields per extension, while a built-in host page may aggregate
several extensions, so the 512-field point is a valid system-wide load rather than an invalid
single-extension manifest. The repeating field must become the virtual row; splitting the same
retained controls into four sections does not bound the page.

#### Extension-settings repair

`ExtensionSettingsListView` now owns one grouped table across built-in and contributed sections.
Fixed-schema built-in sections remain coarse rows; each extension caption and field is a cheap
presentation-row identity. Only a visible field constructs its control and constraints, and that
recycled row owns the control's action target for exactly its lifetime. A contributed section is
never a giant virtual row. `ToolsPreferencesViewController` flattens the same section models into
its existing table, rather than nesting a second scroll view or retaining the section in one cell.
The grouped table also discovers and draws only visible divider boundaries.

The identical fresh-process Debug matrix after the repair measured:

| Valid aggregate | Cold UI | Forced cross-document position | Live result after traversal |
|---|---:|---:|---:|
| 128 fields | 12–13 ms construction + 56–62 ms layout | 4.35–4.36 ms layout; 15–19 ms draw | 11 of 129 rows; 133 descendants; 23 MB |
| 512 fields | 13 ms construction + 55–61 ms layout | 16.8–16.9 ms layout; 18–21 ms draw | 11 of 516 rows; 133 descendants; 70–72 MB |

At 512 fields, cold layout fell from **56.8–61.5 seconds to 55–61 ms** and the hierarchy from
4,640 descendants to 133. The 48-position scroll fixture deliberately jumps far enough to replace
the complete viewport at every sample, so its 512-field layout number is a pessimistic row-mount
stress rather than the cost of a smooth one-row scroll. It remains independent of total retained
views; the higher post-traversal footprint is allocator high-water after visiting all fields, not
a 512-row view hierarchy. A production-host regression also mounts 128 contributed fields through
the real Tools controller, reaches the final field, and verifies its recycled control still owns a
live target.

#### Extensions-preferences repair

`ExtensionsPreferencesViewController` now owns one `ThemedGroupedTableView` and a cheap ordering
model. A collapsed package is one header identity; its manifest detail rows do not exist as AppKit
objects until disclosure inserts them and the viewport asks for them. The table paints the card
behind each header/detail run, so this is the same visual hierarchy without a retained hierarchy.
The fixed page header, import button and scroll view survive updates. Status, identity-resolver and
settings-registry events rebuild value snapshots and recycle only visible cells rather than
replacing the page. A disclosure mutates only its contiguous row run, preserving the clip view and
scroll momentum. Extension-contributed fields targeting the Extensions page remain individual
virtual rows in the same scroll owner.

`ExtensionPackageStoreTests.testStressExtensionsPreferencesWhenEnabled` manufactures exactly the
256-package product ceiling before its clocks start. Package inventory/manifest inspection is
reported separately from the UI, and the fixture measures cold construction, first layout,
disclosure, a jump to the end, an unchanged inventory event at that end, hierarchy size and
footprint under System and Neo Brutalism. Run both themes with
`scripts/profile_threading.sh extensions-preferences-stress`; the workload is also part of `full`.

Fresh Debug processes before and after the repair measured:

| 256-package workload | Before | After |
|---|---:|---:|
| Cold System UI | 509.1 ms construction + 5,478.3 ms layout | **22.7–25.7 ms construction + 48.2–58.5 ms layout** |
| Cold Neo Brutalism UI | 456.8 ms construction + 5,316.9 ms layout | **19.8–30.1 ms construction + 45.3–55.5 ms layout** |
| Expand one package | 6,282.4 ms System / 6,016.9 ms Neo | **9.5–11.5 ms** |
| Jump to final package | 0.4–0.5 ms over the retained stack | **16.1–22.7 ms**, including mounting a new viewport |
| Unchanged inventory event at the end | same whole-page construction path as disclosure | **10.1–10.3 ms model/reload + 16.0–17.8 ms viewport layout**; clip origin unchanged |
| Retained UI | 3,601 descendants; 197–198 MB | **144 descendants, 10 of 257 rows; 9.1–9.5 MB** |

The jump comparison is intentionally not presented as a speedup: the old page had already paid six
seconds and 198 MB to mount everything, so moving its clip was cheap. The repaired page pays a
bounded viewport-mount cost when new content becomes visible. The invariant is total cardinality no
longer owns construction, layout or memory. Do not put package detail views back in
`makePresentationRows()`, call `render()` from disclosure, wrap this table in `SettingsUI.page(_:)`,
or turn contributed settings into one opaque section row.

#### Archived-settings repair

`ArchivedPreferencesViewController` now keeps the complete archive as value tuples and presents
one `PresentationRow` per visible identity through `ThemedGroupedTableView`. Collapsed mode owns the
explanation, ten recent session identities and one disclosure identity. Expanding inserts the
older identities without replacing the fixed header, scroll view or existing cells; only rows that
intersect the viewport construct labels, relative-date formatting, Restore/Delete controls and
constraints. Project and extension-settings events refresh the value model and recycle the
viewport. Extension-contributed fields targeting Archived remain individual rows in the same
scroll owner rather than becoming a nested page.

Search keeps that boundary. The fixed `ThemedSearchField` snapshots only title and project into
small `Sendable` records, and a cancellable detached scan returns matching indices to the main
actor. A query presents every matching identity through the same virtual table instead of
constructing the folded-away rows; clearing it restores the ten-row fold. Thus query work is
linear in archive count and value-only, while AppKit construction, layout and retained hierarchy
remain bounded by the viewport. The expected case is tens to hundreds of conversations; the
existing 1,000-row stress is the implementation-time gate. Do not move row construction, relative
date formatting or contributed settings work into the search task.

`SettingsDisclosureRenderTests.testStressArchivedPreferencesWhenEnabled` manufactures its archive
before the clock starts, then reports controller/view load, model render, first layout, disclosure,
jump to the end, an unchanged project event at that end, hierarchy size and footprint. Its
`search_ms` phase scans the same 1,000 value records for a match at the end before AppKit mounts,
and the test asserts that exact source identity returns. It also asserts the clip origin is
unchanged. Run both themes with
`scripts/profile_threading.sh archived-settings-stress`; the workload is part of `full`.

Fresh Debug processes measured:

| Archived workload | Before | After |
|---|---:|---:|
| Cold collapsed page | 250 rows: 74.0 ms render + 31.7 ms layout | 1,000 rows: **10.0–10.1 ms view load + 0.24 ms model render + 42.7–45.7 ms layout** |
| Expand older conversations | 250 rows: 146.4 ms mutation + **1,912.8 ms layout** | 1,000 rows: **3.6–3.9 ms mutation + 0.22–0.23 ms layout** |
| Jump to final conversation | 0.25 ms after retaining all 250 views | **15.9–18.1 ms**, including mounting the final viewport |
| Unchanged project event at end | 250 rows: 303.0 ms render + **1,897.1 ms layout** | **2.3–2.6 ms reload + 19.0–19.6 ms viewport layout**; clip origin unchanged |
| Retained UI | 250 rows: 2,776 descendants; 96.6 MB | 1,000 rows: **158 descendants, 13 of 1,002 rows; 8.7–8.8 MB** |

The old 1,000-row expansion was terminated after more than two minutes without completing, so the
before table deliberately reports the smaller completed 250-row point rather than inventing a
number. The repaired run uses four times the archive. As with the other virtual repairs, the old
jump itself was cheap only because all row construction and layout had already happened. Do not
put `makeRow` back in the presentation-model pass, rebuild the page from disclosure or project
events, wrap this table in `SettingsUI.page(_:)`, or aggregate contributed settings into one row.

#### Changed-files-card repair

`ChangedFilesCardView` now keeps a pre-order array of presented node indices and renders it through
one embedded `ThemedTableView`. The table does not introduce a nested scroll gesture: its full
logical height remains part of the conversation document, while the conversation's outer clip is
also the cell-materialization viewport. Folding rebuilds only the value projection, updates one
height constraint, and invalidates the retained conversation row. A large flat root-level tree
defers binding its data source until that outer clip has committed layout; otherwise a detached
full-height table would correctly consider every row visible and eagerly construct it.

Diff preview capture now has both the existing 400-line per-file ceiling and a 2,000-line card-wide
ceiling. The remaining aggregate budget is divided fairly among files that have drawable hunks;
short files return unused lines to later files. The dictionary still contains every path, but a
wide generated turn no longer retains `file count × 400` diff lines for the lifetime of the chat.

A paired fresh-process System run immediately before and after the repair measured:

| Valid workload | Before | After | Retained result after |
|---|---:|---:|---:|
| 1,000 files, initially collapsed | 606.4 ms construction + 3,936.5 ms layout | **11.0 ms construction + 30.9 ms layout** | 1 row collapsed / 35 rows expanded; 17 descendants; 7.3 MB views |
| Expand all 1,001 logical rows | 109.2 ms update + 432.5 ms layout | **1.2 ms update + 34.3 ms layout** | viewport-bound rather than total-row-bound |
| 174 files × 400-line diffs | 222.6 ms construction + 200.4 ms layout | **11.5 ms construction + 29.8 ms layout** | 2,000 of 69,600 lines; 7.3 MB views |

Neo Brutalism follows the same ownership bound: the 1,000-file cold path is 12.4 ms construction +
31.0 ms layout, expansion is 1.2 ms + 36.5 ms, and only 35 cells are materialized in a 700-point
viewport. The 174-file preview case is 11.4 ms + 29.8 ms and retains the same 2,000 lines. A
root-only 1,000-file regression separately proves that a tree with no directory available to fold
still binds at most 80 cells after entering the outer viewport.

#### Browser baseline-library repair

`BrowserBaselineLibraryViewController` now retains the 200-record value model but presents it with
reusable fixed-height table rows. A store event reloads only the viewport instead of reconstructing
every card. Each control's callbacks are replaced with the displayed record's stable id during
reuse; a regression scrolls to a recycled row, activates its permission checkbox, and asserts that
the displayed baseline — not the cell's former owner — changed.

Thumbnails keep the durable-image trust boundary. `BrowserBaselineImage.authenticatedData` performs
the same bounded read, SHA-256, source-size and declared-dimension checks as the store's public read,
but needs only a URL and immutable revision value, so rows can call it off-main. Reuse cancels the
row task. The main actor decodes at most a 192-pixel ImageIO thumbnail, caches it by content hash,
and assigns it only if the cell still represents that revision.

The stress fixture was corrected at the same time: all 200 records now contain distinct, valid
320×200 PNGs whose declared dimensions match their bytes. Previously it reused one PNG and declared
4×3 dimensions, so damaged-image refusal meant the benchmark did not actually exercise successful
thumbnail loading. The repaired after-numbers therefore include more real image work than the old
baseline:

| 200-record workload | Before | After |
|---|---:|---:|
| Cold System mount | 187.1 ms render + 478.8 ms layout | **46.3 ms render + 33.4 ms layout**; visible thumbnails ready asynchronously in 26.4 ms |
| Cold Neo Brutalism mount | 170–178 ms render + 507–559 ms layout | **42.6 ms render + 31.9 ms layout**; thumbnails ready in 28.7 ms |
| One permission change | 255.9 ms render + 414.2 ms layout | **2.0–2.3 ms render + 6.4–6.8 ms layout** |
| 48-position stress frame | 24 ms System / 544 ms Neo draw before layout | **16.3 ms System / 12.1 ms Neo** for scroll + layout + draw |
| Retained UI | 2,411 descendants; 119–217 MB | **53 descendants, 3 materialized rows; 14–19 MB** |

#### Extension-panel repair

`ExtensionPanelViewController` validates the entire semantic tree before publication, then flattens
nested vertical stacks into presentation values owned by an automatic-height reusable table. The
flattening carries each stack's spacing and parent axis into the visible row, preserving divider,
spacer and control geometry. Horizontal stacks, overlays, scenes and disclosures remain atomic
two-dimensional rows. Each materialized row owns a fresh action bridge, and a regression scrolls
through reuse before activating the final button to prove the current semantic id is routed.

At the public maximum of 500 semantic nodes, the host now retains 24 of 499 presentation rows and
112 descendants instead of 707. Fresh before/after runs on the same fixture measured:

| 500-node panel workload | Before | After |
|---|---:|---:|
| Cold System layout | 243.7 ms | **40.2 ms** |
| Cold Neo Brutalism layout | 242.0 ms | **38.3 ms** |
| One complete value replacement | 61.3 ms render + 203.3–204.9 ms layout | **1.8–2.0 ms render + 12.3–12.8 ms layout** |
| 48-position stress frame | 56.8–57.5 ms draw | **13.4–14.0 ms** for scroll + layout + draw |
| Retained UI | 707 descendants | **112 descendants; 24 materialized rows** |

The 500-node/1,000-element contract remains a safety bound rather than permission to put an
unbounded repeated collection inside one horizontal, overlay, scene or disclosure row. Long linear
documents should remain vertical semantic stacks so the host can keep ownership viewport-bounded.

### The payloads are read back into the support report

For a long time nothing read that directory. The blobs were write-only sediment: a crash from the
previous launch arrived on the next one, was written, pruned, and never looked at, while the
support report — which already carries `previousLaunchClean` — knew nothing about it.
`MetricKitDiagnosticReader` closes that. `MacSupportReportDetails` gains three fields, assembled
once in `AppDelegate.writeSupportReport`:

| Field | Example |
|---|---|
| `metricKitDiagnostics` | `payloads=4 crash=2 hang=3 cpu=1 diskWrite=0 unreadable=1 skipped=0` |
| `metricKitWindow` | `2026-07-30..2026-08-05` |
| `metricKitLastCrash` | `version=1.4.2 build=311 exception=1 code=0 signal=11 reason=Namespace-SIGNAL-Code-0xb` |

**Counts and a window, never the payloads.** `previousLaunchClean` answers whether *this app* came
back; MetricKit answers whether the *system* recorded a crash or a hang for it, over a longer
window than one launch. What a support conversation needs from a crash payload is whether MetricKit
saw the crash and which build it hit — not a call tree. `callStackTree` and
`virtualMemoryRegionInfo` are therefore not decoded at all, which is the cheapest redaction there
is: the field that was never read. Every string that does survive is reduced by the reader to one
bounded, path-free token, so no consumer can pass an OS-authored sentence through untouched. The
window is whole days in UTC — neither the hour a Mac crashed nor its time zone is anyone's
business, and `MacSupportReportDetailsTests` asserts no field carries a path, an address or a
space.

**Four answers, not two.** `MetricKitDiagnosticReading` is `noDirectory` / `empty` / `read` /
`unreadable(payloadFiles:)`. "MetricKit has never delivered here", "it delivered and recorded
nothing" and "there are payloads on disk this build could not parse" are different facts about the
machine, and a reader that returned an empty result for the third would make a support report say
*no crash was seen* about a Mac that crashed. A damaged file beside readable ones costs that file
and not the answer, counted as `unreadable=`. A directory that exists and cannot be listed is
`unreadable(payloadFiles: 0)` rather than empty.

**Payloads on disk were written by whatever macOS version ran**, so parsing is defensive.
`exceptionType` has appeared as a number and as a string; a strict decode would throw *inside* the
payload and discard a perfectly readable crash over a field nobody needed, so every scalar is read
leniently. Unknown keys are ignored. But a blob carrying none of the recognised keys is refused
rather than accepted as an empty payload — that is what separates a truncated file from a healthy
machine. Timestamps are read from the payload in the three formats MetricKit has used, falling back
to the writer's own `<beginEpoch>-<endEpoch>.json` file name, which no macOS release can reformat.
`MetricKitStorage` names that directory layout once so the two sides cannot drift apart.

**The budget is stated on the reading side too** (`MetricKitReadBudget`: 24 files, 4 MB each,
48-character tokens). The writer already prunes to 20, so in the ordinary case none of it binds —
but a budget enforced only by the other side of a boundary is not a budget, and a corrupted cap or
a directory someone copied files into must not turn a menu command into an unbounded read. Files
past the file budget are reported as `skipped=`, kept apart from `unreadable=` because one is a
budget and the other is damage.

## Command-line workflow

`scripts/profile_threading.sh` never launches the Instruments UI:

```bash
# Deterministic Git Review file-index workloads, including 9k expanded generated files.
scripts/profile_threading.sh git-stress

# Real repository discovery, history, bounded range parsing, and production view mount.
# The checkout is read-only; base, target, and run count are optional.
scripts/profile_threading.sh git-repository-stress /path/to/linux HEAD~100 HEAD 5

# Maximum-contract agent charts: decode/model, cold pane, updates, and rendered frames.
scripts/profile_threading.sh chart-stress

# Tools cold open, disclosure, credentials/exemptions, website origins, and rendered scroll.
scripts/profile_threading.sh tools-settings-stress

# Maximum-contract settings results, a query-only update, and scroll-position preservation.
scripts/profile_threading.sh settings-search-stress

# Changed-files card at 10–1,000 files, with collapsed trees and aggregate capped previews.
scripts/profile_threading.sh changed-files-stress

# Extension panels at 50–500 nodes and aggregate Settings pages at 32–512 fields.
scripts/profile_threading.sh extension-ui-stress

# Browser baseline library at 10–200 rich image-backed records.
scripts/profile_threading.sh baseline-library-stress

# Deterministic native-conversation replay, jump, append, fold, and streaming workloads.
scripts/profile_threading.sh conversation-stress

# Generated 250–1,000-turn conversations, including prose and tool-heavy extremes.
scripts/profile_threading.sh conversation-massive-stress

# One unresolved turn with 25–500 tools, including a 1,000-turn history edge.
scripts/profile_threading.sh conversation-active-turn-stress

# Multi-conversation residency, session switching, background updates, and footprint.
scripts/profile_threading.sh conversation-residency-stress

# Deterministic Subagents pane, or replay one provider child transcript exactly.
scripts/profile_threading.sh subagent-stress [child-transcript-path]

# Deterministic production-outline workload from 500 through 5,000 sessions.
scripts/profile_threading.sh sidebar-stress

# Deterministic production File pane at 100 through 20,000 entries, under System and an authored theme.
scripts/profile_threading.sh file-tree-stress

# Deterministic attachment scan over terminal-sized buffers, under both attachment scopes.
scripts/profile_threading.sh attachment-stress

# Capped cold mount and all-row switching for every attachment preview family.
scripts/profile_threading.sh attachment-format-stress

# Deterministic whole-window drag with chrome, terminal-grid and Claude-repaint phases.
scripts/profile_threading.sh window-resize-stress

# Right-pane open/close beside a repainting Codex TUI, including remote-grid control.
scripts/profile_threading.sh display-pane-stress

# Three first-window launch measurements plus an isolated command-line App Launch trace.
scripts/profile_threading.sh startup

# Lightweight stacks from an already-running app.
scripts/profile_threading.sh sample 15 Threading

# One Instruments template from the command line.
scripts/profile_threading.sh trace "Time Profiler" 15 Threading

# Build, install, launch, and stack-sample the Release app on a booted simulator.
scripts/profile_threading.sh ios-simulator-sample 15

# Host-side projection/encoding plus mobile decode, pagination, reconnect, delta and resync.
scripts/profile_threading.sh remote-conversation-stress 5000

# One shared owner projection across the maximum 32 concurrent clients.
scripts/profile_threading.sh remote-catalogue-stress 1000

# Deterministic iOS cold open, mounted 5,000-row reconnect, then deep scrolling.
scripts/profile_threading.sh ios-conversation-stress 12 5000

# Cross-device sweep: remote transport state, Mac replay, iOS cold open and deep scrolling.
scripts/profile_threading.sh cross-device-conversation-stress 12 5000

# Attach to an installed, running app on a connected device (device UDID or exact name).
scripts/profile_threading.sh ios-device-trace "Time Profiler" 15 DEVICE_UDID

# Run the routine iOS templates against that connected device.
scripts/profile_threading.sh ios-device-full 15 DEVICE_UDID

# Routine sweep: Git, charts, conversation, subagent, sidebar, file-tree, attachment scan/preview
# and window-resize fixtures, sample, Time Profiler, Animation Hitches, and Allocations.
scripts/profile_threading.sh full 15 Threading

# Release/investigation sweep: full plus the three scaling-audit sweeps above, massive,
# unresolved-turn and multi-conversation workloads, CPU Profiler, File Activity, Leaks,
# Swift Concurrency, System Trace, and Power Profiler.
scripts/profile_threading.sh full+ 15 Threading

# Locate recent CLI and built-in artifacts.
scripts/profile_threading.sh latest
```

Each `xctrace` capture attaches to the running process for the requested duration. Exercise the
same pane action during each capture. Output defaults to `/tmp/threading-profiles`; set
`THREADING_PROFILE_OUTPUT` to retain it elsewhere. Command-line Instruments can still require
macOS Developer Tools authorization the first time, but it requires no interactive Instruments
launch or template setup.

`startup` is deliberately separate from `full`: the former launches a measured process and the
latter attaches to an already-running app. The startup sweep is safe while the regular app stays
open. It builds an isolated app copy, changes only that copy's bundle identity, ad-hoc signs it,
and gives each repetition a fresh copy-on-write snapshot of the real Application Support tree.
SQLite's backup API replaces the independently cloned database/WAL/SHM family with one consistent
image, and the real preferences are copied into the throwaway bundle domain. The measured process
therefore sees the real project/session, extension, icon, theme and window-state shape, while every
lock, marker, log and write belongs to temporary state that is removed after the sweep. Every
capture remains owned by the CLI: the exit trap matches only that copy's complete executable path,
queues `TERM` before `CONT` when App Launch leaves the target suspended, and uses a bounded `KILL`
fallback. This ownership is part of the harness contract—a completed or interrupted profile must
leave neither a process nor a Dock tile behind.
`THREADING_STARTUP_PROFILE_RUNS` controls the repetition count (three by default);
`THREADING_STARTUP_PROFILE_CONFIGURATION` selects the build configuration (Debug by default).
`THREADING_STARTUP_PROFILE_SESSIONS` raises the isolated snapshot to that many deterministic,
schema-valid sessions (up to 50,000) before any measured copy is made. It never edits or invents
files in the real support directory: the rows are added only to SQLite's temporary backup, and
every repetition receives the same pristine clone. Use 5,000 for the routine large-restoration
check; omit it to measure the real store exactly as it is.
Set `THREADING_STARTUP_PROFILE_DERIVED_DATA` to a trusted existing DerivedData directory for fast
incremental tuning runs; omitting it keeps each retained artifact self-contained.
The startup build explicitly disables code coverage and builds only the measured host architecture.
It also disables Xcode signing for the build product: the harness changes the copied app's bundle
identity and ad-hoc signs that copy immediately afterwards, so requiring the shipping identity's
development profile would add no integrity and made Release profiling fail on an otherwise valid
developer machine.
The scheme's test plan otherwise leaks `-profile-generate` into a standalone launch build, while a
universal Release binary spends build time on a slice the selected destination cannot execute.
Coverage-instrumented launch totals are not comparable to the uninstrumented baselines below.

The three scaling-audit commands run System and Neo Brutalism by default and accept their printed
`THREADING_*` variables as one-point overrides. Extension-settings virtualization removed the
former roughly two-minute 512-field cliff from `full+`; the 200-record authored-theme baseline
draw pass still takes about 26 seconds, and the changed-files cases deliberately mount up to 1,000
records. They stay out of routine `full` because those specialist edge sweeps remain materially
slower than the ordinary interaction fixtures.

The simulator command makes an isolated Release build, installs and launches it, and uses
`/usr/bin/sample` against the resulting simulator process. It defaults to the booted iOS simulator;
pass a simulator UDID as the last argument when more than one is in use. Simulator-device
`xctrace` recording is deliberately not wrapped here: in Xcode 26.5 it can announce recording but
never reach the time limit or finalize. The stack sample is reliable for locating CPU owners, but
it measures the Mac-backed simulator rather than an iPhone's CPU, GPU, memory pressure, power, or
thermal behavior.

The conversation-specific iOS command uses DEBUG-only fixtures, a mounted reconnect action, and an
automated display-link scroll driver, so it needs no manual interaction. Its Debug app is explicitly
compiled with `-O`:
the probes remain available, but Swift code does not run under the intentionally slow `-Onone`
setting. Cold open intentionally mounts only the newest 160 rows: that is the production remote
snapshot bound, even when the Mac owns a much longer conversation. The deep-scroll pass represents
the same client after pagination has loaded all requested rows. It records fixture/store time,
settled first paint, visible-index and bottom-position correctness, the initial exact jump,
per-frame main-thread work, frame gaps, and stack samples. The metric launch is deliberately clean;
the script then relaunches the identical fixture for `/usr/bin/sample`. A 1 ms stack sampler is
invasive enough to turn a 5 ms scroll-work p95 into more than 20 ms, so a metric emitted while that
sampler is attached is diagnostic evidence, not a regression baseline. `remote-conversation-stress`
separately measures the Mac snapshot-to-wire projection, client decode/apply, every 64-row history
page, repeated reconnect hydration, a live delta, a 250-frame streaming burst, and revision-gap
resync. The command requires both the cold-open and bounded-streaming metrics, so a renamed or
skipped XCTest cannot silently produce a green zero-test run. These deterministic numbers exclude
real network round-trip time; use a device trace and a real paired connection when latency, radio,
thermal, or GPU behavior is the question.

The reconnect pass mounts all requested rows, waits for the first settled viewport, then drives the
same published connection phases and authoritative store replacement as the production UI. It
reports synchronous dispatch, layout, display and end-to-end settled time plus whether the
replacement forced a diffable reset. The CLI rejects a reset of an identical snapshot, invalid
geometry, an estimated-only bottom, duplicate cold settling, or a fixture draft mutation. Socket
round-trip and decode remain intentionally outside this phase because the host-side workload
measures them separately.

The scroll result also reports `jump_top_index`, `final_top_index`, and `geometry_failures`.
Those are correctness gates for the optimized height index: both exact jumps must resolve item 0,
and a full scan must find no non-finite frames, overlaps, spacing errors, or content-height drift.

`cross-device-conversation-stress` combines those two workloads with a 1,000-turn native Mac
conversation replay. A prompt sent from iOS is persisted in the same provider transcript format
as one entered on macOS, so the native replay is the relevant reopen cost after substantial
mobile activity. Override `THREADING_CROSS_DEVICE_MAC_TURNS` or
`THREADING_CROSS_DEVICE_MAC_SHAPE` for a narrower investigation.

### Cross-device conversation baseline

The 2026-08-02 Debug sweep used an iPhone 17 Pro simulator on the local Apple-silicon Mac, with
5,000 remote rows and a 1,000-turn mixed Mac transcript. Simulator timing is useful for relative
regressions, not as an iPhone launch-time promise.

| Phase | Baseline |
|---|---:|
| Remote projection + encode + mobile decode/apply, newest 160 rows | 1.98 ms |
| Reconnect hydration, 20 repetitions | 1.46 ms p50 / 1.65 ms p95 |
| All 76 history pages | 138.86 ms total / 2.40 ms page p95 |
| Live update against 5,000 rows | 7.18 ms |
| 250 metadata-only streaming updates against 5,000 rows | 0.625 ms total |
| Revision-gap resync, newest 160 rows | 1.82 ms |
| iOS remote cold open, newest 160 rows | 507.24 ms first paint |
| iOS fully loaded 5,000-row stress view | 2,081.56–2,341.54 ms first paint |
| iOS exact jump to first row | 76.45–157.32 ms |
| iOS automated deep scroll | 52.66–67.50 ms work p50 / 86.01–130.60 ms p95 |
| iOS deep-scroll frame gap | 100.04–149.93 ms p95; every observed frame over 33.3 ms |
| Mac reopen, 1,000 turns / 6,000 rows | 154.60 ms |
| Mac exact deep jump | 19.25 ms |

The original remote broadcaster rebuilt the provider-neutral row DTO array and compared the whole
snapshot every 50 ms while tokens streamed. A settled 5,000-row history therefore remained in the
hot path even though only `streamingText` had changed. Three warm Debug runs of 250 updates measured
the old whole-row comparison at 1,308.596–1,317.713 ms total (1,309.904 ms median).

The native controller now mirrors the exact append/result changes already emitted by
`ConversationTimeline` into a cached row projection. A controller generation plus monotonically
advancing row revision proves when that array is unchanged; metadata comparison and delta creation
then touch no settled rows. The same three runs measured 0.568–0.664 ms total (0.625 ms median),
about 2,095 times less work. A real row append still uses the general diff and measured about 8 ms
end to end at 5,000 rows; that lower-frequency structural path remains the boundary to optimize if
future traces show it dominating. Focused tests pin exact append and tool-result projection plus the
empty-row invariant for metadata-only deltas.

The immediate problem was the fully loaded iOS timeline, not wire projection or reconnect-state
hydration. The original scroll sample spent 3,498 of 3,984 driver-layout samples inside
`UICollectionView.layoutSubviews`; 1,403 samples were the compositional layout's preferred-size
invalidation resolver. Text self-sizing and repeated UIKit row construction sat beneath it.

The kept implementation uses a conversation-specific `UICollectionViewLayout`. It caches measured
heights by stable diffable identifier, binary-searches the visible range, and stores later-row
origin changes in a Fenwick difference tree. A preferred-height discovery is therefore O(log n)
instead of shifting every later frame; only currently visible followers are invalidated. Width and
Dynamic Type changes clear the measurements, prepends rebuild them by identifier, and discoveries
above the viewport compensate the content offset. Cells have row-kind-specific reuse pools and
reconfigure their hosted UIKit views. Recycled finite text views request TextKit's cheaper
contiguous compatibility path, while newly created views stay on TextKit 2 so cold mounts do not
pay that conversion thousands of times.

Two repeat 5,000-row runs after those changes measured:

| Phase | Optimized | Original |
|---|---:|---:|
| iOS remote cold open, production 160-row window | 385.42–454.46 ms | 507.24 ms |
| iOS fully loaded 5,000-row stress view | 395.55–406.44 ms | 2,081.56–2,341.54 ms |
| Exact jump to first row | 28.10–40.15 ms | 76.45–157.32 ms |
| Automated deep scroll | 14.61–16.04 ms p50 / 21.15–21.45 ms p95 | 52.66–67.50 ms p50 / 86.01–130.60 ms p95 |
| Deep-scroll frame gap | 33.37–33.45 ms p95 | 100.04–149.93 ms p95 |

Both runs reported item 0 after the initial and final exact jumps and zero geometry failures over
all 5,000 frames. Median main-thread scrolling is now inside a 60 Hz frame budget on this
simulator. The remaining tail is visible-cell creation and text self-sizing: p95 work is still
about 21 ms and p95 display-link gaps remain one 30 Hz frame, so future work should target that
tail rather than transport or another total-history layout rewrite.

A later optimized-probe pass found that markdown warming still launched one main-actor task per
assistant response. With 5,000 mounted rows, that completion flood delayed a correct settled paint
to 2,353 ms. Warming is now newest-first in 64-document actor batches. A batch updates cached
documents together and re-anchors only when it actually reconfigured visible content. The first
paint probe also waits for both `viewDidAppear` and the diffable snapshot's final cold-height
positioning passes; `last_visible_index` and `bottom_error` therefore cannot pass on the estimated
viewport one turn early.

The retained 5,000-row run on 2026-08-02 measured:

| Phase | Batched optimized probe |
|---|---:|
| iOS remote cold open, production 160-row window | 364.88 ms |
| iOS fully loaded 5,000-row settled view | 417.20 ms |
| Exact jump to first row | 89.30 ms |
| Automated deep scroll | 13.94 ms p50 / 19.10 ms p95 |
| Deep-scroll frame gap | 33.37 ms p95 |

Both opens included the actual last item and reported only the expected 20-point adjusted bottom
inset; both exact jumps reached item 0 and the layout reported zero geometry failures. Fixture
generation plus store insertion was 0.19 ms for the production window and 2.51 ms for all 5,000
rows. The remaining roughly 365 ms production cold-open cost is therefore fixed screen
presentation, dominated in the stack sample by the outer SwiftUI first transaction, rather than
history projection, storage, Markdown scheduling, or total row count.

That ownership result led to replacing the iOS conversation shell rather than rewriting the
timeline again. `RemoteConversationViewController` now owns the timeline, composer, completion
catalog, presence, input control, attention activity and submission receipts. It observes model
changes directly and coalesces one UIKit render turn; SwiftUI is no longer in the scrolling,
typing, keyboard or submission path. The application lifecycle is also UIKit-owned. Screens not
yet migrated are hosted below the scene coordinator, while the deterministic conversation route
enters the native navigation controller directly. The attention-request sheet remains an
on-demand SwiftUI presentation and therefore does not participate in cold open.

One UIKit attempt was itself a cold-path trap: anchoring the composer to
`keyboardLayoutGuide.topAnchor` synchronously initialized UIKit's text-input tracking coordinator
when the view entered the first window. The sample attributed about 108 ms to that work and cold
open regressed to 496.05 ms. The kept controller listens for keyboard frame notifications and
adjusts a safe-area constraint, so the keyboard framework is paid only when the keyboard is
actually used.

The retained clean 5,000-source-row run after the native-shell change measured:

| Phase | Native iOS shell | Prior SwiftUI shell |
|---|---:|---:|
| Production cold open, newest 160 mounted rows | 244.01–252.84 ms | 364.88 ms |
| Fully loaded 5,000-row settled view | 274.31 ms | 417.20 ms |
| Exact jump to first row | 36.47 ms | 89.30 ms |
| Automated 5,000-row deep scroll | 11.47 ms p50 / 12.80 ms p95 | 13.94 ms p50 / 19.10 ms p95 |
| Deep-scroll frame gap | 33.39 ms p95 | 33.37 ms p95 |

The 160-row scroll control measured 2.89 ms p50 / 5.21 ms p95 with a 16.70 ms frame-gap p95.
Both scales reached the actual last item at the expected 20-point bottom inset, exact jumps landed
on item 0, and geometry failures remained zero. The direct native cold sample no longer contains
the old 117-sample hosting/AttributeGraph owner. Its first Core Animation commit is about 122 ms;
roughly 46 ms is the initial diffable snapshot, visible-cell creation and final bottom-height
positioning. Standard dashboard and settings screens still use a hosting controller and should
migrate only when their own traces justify it.

The phase split showed that the snapshot value was not the 46 ms owner. The timeline applied it
from the child's `viewDidLoad`, before the parent installed the child's constraints, and its
diffable completion immediately called `layoutIfNeeded`. UIKit therefore created the bottom cells
at a one-point width, invalidated every discovered height when the real width arrived, and created
the visible cells again. `viewDidAppear` could also schedule a second copy of the three-pass bottom
settle while the first completion was still pending.

Initial anchoring now waits for the first `viewDidLayoutSubviews` with real bounds. That pass sets
the estimated bottom without nesting another layout, and all layout/appearance callbacks share
one next-turn measured-height settle. The DEBUG fixture reports invalid-width cell construction and
settle-task count; the CLI refuses a run unless they are exactly zero and one. The initial raw
assistant/streaming surface is also a light multiline label. It exists only until the off-main
Markdown batch returns, at which point completed messages still install the normal selectable text
views; transient content no longer initializes TextKit selection machinery merely to be replaced.

Three same-simulator fresh-process production-window runs measured **248.13–257.53 ms before** and
**174.93–188.50 ms after**, a 28–32% cold-open reduction. A clean CLI run measured:

| Phase | 160 mounted rows | 5,000 mounted rows |
|---|---:|---:|
| Timeline view load | 4.72 ms | 11.99 ms |
| Diffable snapshot apply | 0.39 ms | 4.29 ms |
| Snapshot-to-final-bottom settle | 92.10 ms | 96.86 ms |
| Invalid-width cells / settle tasks | 0 / 1 | 0 / 1 |
| Settled first paint | **181.20 ms** | **195.95 ms** |

The retained 5,000-row regression reached item 0 in 37.05 ms, scrolled at 10.26 ms p50 / 13.66 ms
p95, ended at item 0, and reported zero geometry failures. The optimized path therefore removed a
duplicate cold mount rather than trading initial speed for later scrolling or an estimated-only
viewport.

The same cold sample found a separate 16-sample framework load below `restoreDraft()`: assigning
the empty saved draft to an already-empty composer made `UITextView` coordinate a selection change,
initialize dictation, and dynamically load AssistantServices. A first comparison fixed the ordinary
empty-string case, but a reused simulator container could still make a performance fixture inherit a
real draft and silently measure a different workload. Restoration compares normalized visible
values, while deterministic cold/scroll fixtures explicitly use an empty draft. Their metric reports
`draft_assignments`; the CLI rejects any value other than zero. A real production draft is still
installed synchronously.

The next isolated trace found the same 17 ms input-services load below initial selectable transcript
text. Static `UITextView` content is now installed while selection is disabled and selection is
enabled on the finished view; rows remain selectable but construction is not reported to UIKit as an
editable selection change. The post-change cold trace had zero AssistantServices or dictation
samples. Five matched same-simulator cold launches moved median bottom settle from **103.503 to
98.249 ms** and median first paint from **199.097 to 197.190 ms**. Those aggregates are deliberately
reported as modest because framework warmth and process scheduling vary; the firm result is removal
of the owned call tree. Three matched deep-scroll runs stayed neutral at **15.781 versus 15.735 ms
p95** (13.337 versus 13.697 ms median) with zero geometry failures, so selection preservation did
not trade cold work for a scrolling regression.

The mounted reconnect fixture then found a different total-history failure. Even when all 5,000
rows and their content were identical, `RemoteConversationStore.replace` always emitted `reset`.
That cleared the stable height and Markdown caches and animated a new 5,000-item diffable snapshot.
In the baseline sample, 34 of the reconnect action's 39 synchronous samples were under store
replacement and 28 were inside diffable application. The nominally unchanged update consequently
took **39.843 ms** to dispatch and **496.406 ms** to settle.

Snapshot replacement is now identity-aware. Equal ordered row identities produce only exact
changed-row and metadata deltas; a snapshot whose only difference is its revision is a timeline
no-op, while state and send availability still advance. Inserts, removals and reordering retain a
structural reset, but preserve height and Markdown caches by stable id, invalidate changed retained
rows, and discard only cache entries whose row/source disappeared. Five direct launches of the
same before and after binaries measured:

| Mounted 5,000-row reconnect | Before | After |
|---|---:|---:|
| Full snapshot resets | 5 / 5 | **0 / 5** |
| Synchronous dispatch, median | 46.986 ms | **8.036 ms** |
| End-to-end settled, median | 505.460 ms | **11.237 ms** |

That is an 82.9% dispatch reduction and a 97.8% settled-time reduction. Every run retained the
last five visible rows at the expected 20-point adjusted bottom inset and reported zero geometry
failures. The matched full suite kept the controls neutral or better: production-window cold paint
was 228.940 versus 222.052 ms, scrolling work p95 was 15.018 versus 13.869 ms, exact top navigation
still reached item 0, and geometry failures remained zero. The CLI keeps the unchanged-reset check
as a regression gate, while focused store tests cover identical, content-changed, reordered,
inserted and in-flight history-loading replacements. Baseline and after artifacts are
`/tmp/threading-profiles/20260812T115239Z-ios-conversation-stress` and
`/tmp/threading-profiles/20260812T115713Z-ios-conversation-stress`.

The device commands intentionally attach rather than build or install: first install a Release
build, connect and unlock the trusted Developer Mode device, and leave Threading open in the
foreground. `xcrun xctrace list devices` prints usable names and UDIDs. The default process name is
`ThreadingMobile`; pass a different process name or PID after the device argument if necessary.
These captures also require no Instruments window. Generic device traces still need the target
interaction during the timed interval; the simulator conversation stress command supplies its own
deterministic driver.

## Attachment scan stress target

`SessionAttachmentStoreTests.testStressAttachmentScanWhenEnabled` scans a generated
terminal-sized buffer of path-shaped text and records what the scan admits. It exists because the
attachment scope became configurable, and both sides of that setting introduced work whose queue
ownership matters: matching and filesystem resolution belong on a worker, while admission remains
main-actor state and the wide scope may also take custody of newly visible file bytes.

Two changes were worth a number rather than an argument. Containment used to be answered *before*
the filesystem, so a path outside the project was rejected on a string comparison; counting one
costs a `stat`, which puts the filesystem in the path of text an agent merely printed. And the
wide scope copies bytes, on that same thread. `AttachmentReferenceDetector.maximumCandidatesPerScan`
bounds the first, `SessionAttachmentDefaults.maximumPerSession` and `maximumWithheldPerSession` the
second.

Three shapes, each a real afternoon in a terminal: `mixed` (half the paths in the checkout, half
outside, all real), `outside` (every path outside — `find ~ -name '*.png'`, the case the rule
exists for), and `absent` (path-*shaped* prose naming nothing, which is what a build log mostly
is). `THREADING_ATTACHMENT_STRESS_SHAPE`, `_SCOPE` and `_PATHS` narrow the sweep to one point.

Each run reports the cold scan, the warm re-scan of the identical buffer — what a repainting
terminal actually pays, since every path in it has been seen — the gated read every pane, tool and
remote fetch goes through, and the count the pane's band is drawn from.

### Attachment scan baseline

The 2026-08-02 Debug sweep, on the local Apple-silicon Mac. Cold-scan milliseconds; the observer
hands the detector at most `SessionAttachmentDefaults.maximumTerminalScanBytes` (256 KB), so the
194 KB rows are the realistic ceiling and the 979 KB rows are deliberately past it.

| Buffer | Scope | First sweep | Shipped |
|---|---|---:|---:|
| 1,000 absent paths, 116 KB | narrow | 34.05 ms | 23.52 ms |
| 1,000 mixed paths, 141 KB | narrow | 168.08 ms | 43.52 ms |
| 1,000 mixed paths, 141 KB | wide | 171.82 ms | 51.76 ms |
| 1,000 outside paths, 194 KB | narrow | 98.94 ms | 36.44 ms |
| 1,000 outside paths, 194 KB | wide | 264.16 ms | 44.59 ms |
| 5,000 outside paths, 979 KB | narrow | 181.04 ms | 47.39 ms |
| 5,000 outside paths, 979 KB | wide | 343.13 ms | 54.36 ms |

The first sweep put a **343 ms main-thread scan** one setting away, over the stall monitor's own
250 ms threshold — from turning a preference on. Three findings, all the same shape: work done for
rows the caps were about to throw away.

- **A capful is all that can survive, so only a capful is built.** The wide scope copied 512 files
  to keep 32 and delete 480 — bytes copied on the main thread purely to be evicted. The scanned
  door proved 500 in-checkout files against the filesystem to keep the same 32, and `noteWithheld`
  inserted 512 refused paths at the front of a growing array before truncating it to 32, which is
  quadratic in whatever an agent last printed and made *refusing* a buffer twice as expensive as
  admitting one. All three now take `suffix(cap)` first: newest wins in `admit`, and the newest
  are at the end, so the surviving list is identical.
- **The candidate cap is enforced while matching, not after.** `matches(in:)` materialises every
  hit before anything can be discarded, so a terminal holding a thousand paths built a thousand
  `NSTextCheckingResult`s and as many bridged strings to keep the first few hundred.
  `enumerateMatches` with a stop pointer is the same answer for a fraction of the work.
- **Reporting an outside path costs a `stat`.** Containment used to be answered on a string, which
  made refusing free. A count the pane shows has to be a count of files that exist, so
  `maximumCandidatesPerScan` is what keeps that bounded.

The remaining regex pass was still flat at 20–55 ms whatever the buffer held: the `absent` row did
no filesystem work at all and still cost 23 ms. It no longer runs on the queue the window draws
on. The observer captures SwiftTerm's bounded text on the main actor, resolves immutable text and
URLs in a user-initiated worker task, then returns only the bounded resolution for admission.
Native structured assistant messages use the same split rather than synchronously scanning each
finished answer.

The follow-up 2026-08-11 sweep reports main-actor scheduling, worker resolution, main-actor
admission and end-to-end readiness separately. Cold/warm pairs are in milliseconds. The 979 KB
row remains deliberately beyond the production 256 KB terminal-buffer cap.

| Buffer / scope | Old synchronous main | Main schedule | Worker | Main apply | Ready |
|---|---:|---:|---:|---:|---:|
| 1,000 absent, narrow | 25.25 / 21.83 | 0.72 / 0.02 | 23.18 / 20.94 | 0.09 / 0.01 | 24.15 / 23.10 |
| 1,000 mixed, wide | 55.73 / 55.59 | 0.72 / 0.02 | 45.99 / 41.51 | 14.05 / 0.90 | 60.96 / 42.57 |
| 5,000 outside, wide | 82.14 / 114.14 | 0.75 / 0.02 | 47.02 / 43.73 | 25.08 / 0.80 | 73.02 / 47.47 |

The high-frequency repaint path was below one millisecond of main-actor work: warm scheduling was
about 0.02 ms and warm apply was 0.01–0.90 ms. Cold wide-scope admission still spent 14–25 ms on
the main actor because custody meant copying genuinely new outside files there.

Custody now has its own worker phase. It copies each outside file into a unique unpublished slot;
the main actor publishes that slot only after rechecking the scope and caller generation. If a
same-source row wins while the copy is in flight, the staged bytes are atomically folded into the
winner's existing slot so its opaque ID and relative path do not change. Cancellation or a scope
change discards the unpublished slots. Focused tests pin both the scope-change and same-source-race
contracts.

Three fresh-process `outside / wide / 1,000` runs on 2026-08-11 measured:

| Phase | Before | After |
|---|---:|---:|
| Main schedule, cold | 2.90 ms | 0.71–0.73 ms |
| Resolution worker, cold | 40.31 ms | 35.23–36.35 ms |
| Custody worker, cold | included in main apply | 11.81–13.59 ms |
| Main apply, cold | 27.40 ms | 3.35–3.99 ms |
| Ready, cold | 70.84 ms | 51.33–54.89 ms |
| Main apply, warm | 0.81 ms | 0.67–0.82 ms |

Cold main-actor admission fell about 85%, while the byte-copying invariant stayed intact. The
remaining one-time custody cost is explicit worker time rather than event-loop work.
`attachments.scan` remains a recorded wall-time span, and the stress fixture reports both worker
phases so a regression cannot hide inside the aggregate.

That first split exposed two adjacent interactive edges, so the fixture now exercises them too:
the pane's **Show** action against the full withheld cap, and a second full generation that evicts
all 64 standing rows. The former still called the old synchronous custody door; the latter returned
from worker staging only to delete every evicted slot and repeatedly scan a growing array on the
main actor.

The pane now owns one cancellable, generation-bound admission task. Its files use the same
unpublished worker staging as live scans, and changing the global scope again prevents a stale
task from publishing. Full-generation admission derives last-source-wins chronology in one pass,
indexes standing sources once, and publishes the new capped list before a utility worker deletes
the now-unaddressable private slots. Owned-slot checks use the trusted session root plus a
component-level traversal guard instead of canonicalising the same URLs repeatedly. A later scan
of an explicitly handed-over file preserves that row's origin and non-scope-governed authority.

Three fresh-process `outside / 1,000` pairs measured:

| Interaction | Before main work | After main work | Worker / ready after |
|---|---:|---:|---:|
| Pane Show, 32 withheld files | 12.06–12.84 ms synchronous | 0.01–0.03 ms schedule + 1.07–1.17 ms apply | 6.92–7.90 ms / 10.67–12.03 ms |
| Replace a full 64-row list | 16.78–17.95 ms apply | 2.45–2.51 ms apply | 11.27–12.56 ms / 13.88–16.68 ms |

The complete seven-point sweep stayed bounded: warm apply was at most 0.81 ms, outside-only cold
apply at most 2.83 ms, and the mixed cold edge (64 project references plus 12 copied rows) was the
largest remaining main slice at 7.12 ms. The fixture reports scope-widen and rollover phases
separately so neither can regress behind the ordinary cold/warm pair.

One more pass removed two duplicate costs that the phase split made visible. The pane used to call
`attachments(for:)` and then `countOfFilesOutsideProject(for:)`; each call revalidated every row
against the filesystem, so one refresh paid roughly 12–16 ms for two equivalent walks.
`listSnapshot(for:)` now returns the rows and scope count from one authoritative validation. Fresh
processes measured that single snapshot at 4.57–5.40 ms for the mixed fixture and 6.19–9.10 ms for
64 private copies. The per-read validation invariant remains intact: a deleted file still disappears
the next time any consumer asks for the snapshot.

Worker resolution also now carries the already-resolved project root into admission. Files that the
worker has proved to exist inside that root no longer repeat their `stat` and symlink resolution on
the main actor. Three-run mixed cold admission fell from 6.74–7.12 ms to 3.38–4.98 ms; the final
seven-point sweep kept all other main apply phases at or below 2.88 ms and warm apply at or below
0.83 ms. Finally, the delayed transcript observer now enters through the same async scanned-record
door as terminal and structured-message observation. It no longer resolves on a worker only to copy
outside bytes synchronously when it returns to the main actor.

### The buffer read, and the four instruments that missed it

Everything above measures what happens to the text *after* the observer has it. Getting the text
was the expensive half, and no number here described it until 2026-08-20.

`SessionAttachmentDefaults.maximumTerminalScanBytes` bounds the text
`Terminal.getRecentLogicalBufferText` **returns**. It cannot bound what that call **reads**. The
walk goes backwards from the newest row and stops when the budget is spent, but a blank row costs
one separator byte and real agent scrollback is mostly blank and short rows, so 3,473 rows yielded
about 59 KB and the budget was never spent. The walk reached row zero every time, calling
`BufferLine.translateToString` and `getTrimmedLength` on every row of every session's entire
scrollback, on the thread the window draws on, roughly six times a second.

A window left running for 25 hours with 24 live sessions was measured at a 10.3 GB physical
footprint, 14.1 GB peak, holding 23,545,777 live `Swift.StringStorage` objects. `sample` put 91 of
118 main-thread samples inside that walk. The recorder's own ring held 3,867 `attachments.scan`
events out of 4,096 across a 640-second window: 6.0 scans per second, 219 MB of buffer text read,
**one** attachment found.

`sinceAbsoluteRow` bounds the read. A caller passes back the `nextAbsoluteRow` of its previous
result and only rows produced since are translated again. Two rules keep that from being merely
faster:

- **The current screen is always re-read.** A full-screen agent TUI repaints rows in place without
  producing a new row, so the screen is the one region that can change without moving the cursor.
- **The cursor commits only when a scan is applied.** Advancing it at read time was tried first and
  is wrong: a scan superseded by a newer generation is dropped, and its rows would have been
  carried away unread with nothing to ever read them again. `TerminalIncrementalScanTests` pins
  both, because both failures are silent.

Rows above the screen have scrolled out of the cursor's reach and can no longer change, which is
what makes skipping them safe rather than only cheap. `TerminalAttachmentObserver` also stopped
keeping a set of every path anywhere in scrollback and now remembers a bounded
`rememberedScannedPaths` of what it has already offered, which covers more history than the read
window and is the first version of that set with an upper bound.

**Four instruments were pointed at this feature and none of them saw it.** That is the part worth
keeping:

1. **The expensive phase was outside every span.** `attachments.scan` began *after* `text()`
   returned, so the one recorded measurement of this feature described the worker round trip and
   never the synchronous work that blocked the window. The read now has its own `attachments.read`
   span. Instrument the phase you suspect is cheap; a span that starts after it proves nothing.
2. **The stall heuristic could not tell a blocked thread from an `await`.** Requiring a span to
   both begin and end on the main thread was meant to exclude cross-queue work, but an `await` that
   resumes on the main actor satisfies both endpoints while occupying the thread for neither. So
   `attachments.scan` tripped the 100 ms threshold on essentially every pass and the app exported a
   trace every 30-second cooldown, continuously, for something that was never a stall. A signal
   that fires constantly is worse than one that never fires: it reads as background noise, and it
   crowded out the two genuine `main-thread.stall` events in the same window. Spans that cross
   queues now pass `crossesQueues: true` and are excluded.
3. **The stress fixture began after the expensive part.** `testStressAttachmentScanWhenEnabled`
   hands the detector a ready-made `String`, so a whole-scrollback walk was structurally invisible
   to it. `TerminalIncrementalScanTests.testStressTerminalBufferReadWhenEnabled` now sweeps the
   read itself across scrollback depths, and `scripts/profile_threading.sh attachment-stress` runs
   it first.
4. **A bounded ring is a sampling window, and nothing said what filled it.** At 3,867 of 4,096
   events, one span had evicted almost every other subsystem from the trace; read as a timeline
   that is invisible. Every exported trace now carries `dominant_span`, `dominant_span_share`,
   `ring_events`, `ring_distinct_spans` and `top_spans` in `otherData`, and the automatic-export
   log line repeats them, so `log show` shows what is flooding the recorder without opening a file.

The general rule, which is not specific to attachments: **a cap on output is not a cap on work.**
A bound stated in bytes, rows or items returned says nothing about how much was examined to
produce them, and the two diverge exactly when the content is sparse.

## Attachment preview-format stress target

Detection is only the first half of an attachment feature. Once a file is in the pane, its row
thumbnail and selected preview can enter ImageIO/AppKit, PDFKit, WebKit, Quick Look or TextKit.
`SessionAttachmentsLayoutTests.testStressAttachmentFormatPipelineWhenEnabled` creates its files
before the clock, admits the product cap of 64, mounts the production pane, then selects every row
forwards and backwards. The phases keep controller construction, first layout/draw, cold selection
dispatch, warm selection dispatch and footprint separate. The system renderers remain asynchronous;
the switching figures are main-thread interaction cost, not time until Quick Look or WebKit has
finished painting remote-process content.

The default fixtures are 1,600 × 1,000 PNGs, twelve-page PDFs, 300-row HTML files, archive metadata
cards, 800-paragraph RTF documents, and Mermaid source immediately below the 512 KB source-preview
cap. `mixed` rotates through all six families. Set
`THREADING_ATTACHMENT_FORMAT_STRESS_KIND` or `..._FILES` for a focused point. Quick Look activates
its display bundle asynchronously, so each fresh-process workload retains its offscreen test window
until process exit; immediately destroying or closing an activation-pending `QLPreviewView` tests
an unsupported XCTest teardown race rather than the pane.

The pre-fix Debug sweep on 2026-08-09 measured:

| Format | Source bytes, 64 files | Cold pane construction | First all-row pass | Reverse warm pass | Footprint delta |
|---|---:|---:|---:|---:|---:|
| Image | 1.8 MB | 209.7 ms | 47.3 ms | 47.8 ms | 15.4 MB |
| PDF | 0.4 MB | 219.1 ms | 250.9 ms | 126.1 ms | 13.3 MB |
| HTML | 1.0 MB | 206.8 ms | 16.2 ms | 12.5 ms | 13.0 MB |
| Archive | 0.1 MB | 207.3 ms | 19.0 ms | 15.1 ms | 12.3 MB |
| Document | 2.2 MB | 200.8 ms | 19.5 ms | 14.8 ms | 12.3 MB |
| Diagram | 32.0 MB | 230.8 ms | 90.1 ms | 101.3 ms | 12.9 MB |
| Mixed | 5.9 MB | 188.0 ms | 82.3 ms | 49.7 ms | 12.9 MB |

The scaling bounds worked: even the 32 MB aggregate diagram edge was roughly 1.5 ms per selection,
and the PDF decoder was the only 64-file pass over 100 ms. The cold result exposed a different
problem. One-file controls measured the same 209–243 ms construction band as 64 files, independent
of whether the selected file was an image, PDF, HTML document or diagram. Hidden content is not
lazy merely because it is hidden.

That finding is now repaired. The pane installs only the selected image, document, WebKit or
TextKit surface and retains surfaces that have actually been used. The document surface applies
the same boundary again, installing PDFKit for a PDF or Quick Look for other documents without
constructing its unused sibling. Layout tests pin both halves of that contract.

Raster work is bounded separately from surface construction. Selected images are reopened through
one authoritative byte/dimension/pixel-area policy, while the rail forces bounded ImageIO
thumbnails instead of retaining full lazy `NSImage(contentsOf:)` decoders for every row. A raster
that exceeds that contract is an unavailable image, not a document that falls through to Quick
Look. Extension package images use a stricter 4 MiB, 1,024-pixel, single-frame policy at both host
decode and remote delivery; browser-baseline UI reopens pixels through the store's hash and
dimension claim rather than bypassing it with a raw URL.

The immediate post-fix fresh-process sweep measured:

| Format | Cold pane, before → after | First all-row pass, before → after | Warm pass, before → after | Live descendants after |
|---|---:|---:|---:|---:|
| Image | 209.7 → 146.2 ms | 47.3 → 36.9 ms | 47.8 → 36.5 ms | 41 |
| PDF | 219.1 → 154.7 ms | 250.9 → 79.1 ms | 126.1 → 65.9 ms | 48 |
| HTML | 206.8 → 171.1 ms | 16.2 → 12.0 ms | 12.5 → 8.9 ms | 42 |
| Archive | 207.3 → 83.6 ms | 19.0 → 15.5 ms | 15.1 → 10.6 ms | 43 |
| Document | 200.8 → 90.1 ms | 19.5 → 14.3 ms | 14.8 → 12.0 ms | 43 |
| Diagram | 230.8 → 165.0 ms | 90.1 → 95.3 ms | 101.3 → 85.3 ms | 45 |
| Mixed | 188.0 → 75.9 ms | 82.3 → 124.8 ms | 49.7 → 57.0 ms | 56 |

Single-file controls initially landed in the same format-specific bands: 71–72 ms for Quick Look
documents, 143 ms for an image, 147 ms for a PDF, 157 ms for a maximum source preview, and 165 ms
for HTML. The former universal 188–243 ms tax was gone; one selected handler owned cold time. The
mixed first pass intentionally rose because it is the one workload that visits every family and
now pays each one-time installation at first use instead of charging all six to pane open. Once
every family has been touched, its 56 descendants match the old eager pane; single-family panes
retain only 41–48.

That fresh-process number still combined two different things, so the fixture now reports
controller init, view load, shell-minus-preview, preview metadata/clear/prepare/install/present,
and a second same-process pane. It also asserts that refresh presents the restored selection once:
`reloadData` and `selectRowIndexes` both notify the delegate, so the refresh suppresses those
intermediate notifications and owns one final presentation.

The phase split changed the diagnosis. At the 64-file cap, the first XCTest process spends
roughly 76–107 ms loading AppKit/design-system classes before format work. A second pane in that
same process mounts in 12.8–14.7 ms for image, PDF, archive, document, diagram and mixed fixtures;
their selected preview adds at most 2.3 ms. This is the app-warm interaction, and it is already
within one 60 Hz frame. Treating the fresh XCTest class-loader cost as repeatable pane work would
lead to prewarming exactly the renderers the lazy boundary removed.

HTML was the real exception: a warm capped pane took 47.4 ms, including about 3.9 ms to construct
`WKWebView` and 30.7 ms synchronously inside `loadFileURL`. Both now wait until the pane's loading
state can be committed on the next main-loop turn, and the request is tokened so a quick row change
cancels stale work before WebKit is even constructed. Warm pane mount is 12.5 ms; the deferred
system handoff remains separately visible as 3.5 ms installation plus 30.8 ms navigation. The
stress fixture forces that deferred handoff after every selected HTML row, so switching results do
not become artificially cheap. `Attachment Preview Presentation` and `Attachment HTML Navigation`
spans carry the same split into self-profile traces and xctrace.

## Desktop terminal repeated-frame rendering

A live Debug capture with the app otherwise in background work put 38–40% of sampled main-thread
time in the Core Graphics terminal path: snapshot preparation, `SnapshotTextBuilder`, Core Text
line/run construction, glyph fitting, low-contrast detection and `draw`. The display driver was
already visibility/occlusion-aware and PTY parsing was already off-main. The remaining defect was
repeat work: AppKit may promote a narrow invalidation to a full-surface draw, and Core Graphics
rebuilt every exposed row even when the immutable snapshot revision had not changed. Metal already
kept the corresponding row cache.

The Core Graphics renderer now retains at most 256 prepared visible rows keyed by the source
identity and generation, snapshot revision, render-context identity and custom block-glyph mode.
A hit reuses the attributed segments, shaped `CTLine`s and extracted run attributes. Content,
selection/link/command/blink style, ANSI palette, BiDi dependencies and images all advance the row
revision; fonts, default colours, fallback provider and true-colour transform move the context
identity. Wide/fallback glyph slot fitting has a separate 4,096-entry cache keyed by both retained
font identities, glyph, cell geometry, width and placement policy, so a font object cannot be
deallocated and ABA-reused into stale metrics.

Low-contrast observation applies the same immutable-row boundary inside the render owner. It
rescans only changed visible rows, retains at most 256, and still globally deduplicates the row
findings before publishing them. Diagnostics expose built/reused Core Graphics rows, glyph-fit
hits/misses and contrast rows scanned/reused. The regression draws exercise unchanged and
single-row content, selection/style, BiDi dependencies and appearance invalidation; image changes
share the snapshot's existing revision gate rather than adding a second cache authority.

## Whole-window resize stress target

`WindowEdgeTests.testStressWholeWindowResizeWhenEnabled` drives 120 bottom-right window-resize
ticks through the production `MainWindowController`. It measures plain window chrome, a Claude
alternate-screen terminal with its natural frame-derived grid, the same terminal with grid changes
suppressed, and both grid modes with a generated full-screen Claude repaint after every tick. The
natural/frozen delta isolates SwiftTerm resize work from AppKit layout and terminal drawing;
`grid_changes` verifies that the control really differs.

`scripts/profile_threading.sh window-resize-stress` runs the ordinary empty-history case. Set
`THREADING_WINDOW_RESIZE_STRESS_HISTORY_LINES` for a one-point investigation. The routine `full`
sweep uses empty history; `full+` adds 5,000 input lines before entering the alternate screen so
hidden normal-buffer reflow cannot escape the release edge.

The first Debug sweep showed that neither window chrome nor Claude repainting owned the reported
stall:

| Stage | Hidden history input lines | Repaint | Resize p50 | Resize p95 | Ticks over 16.7 ms |
|---|---:|---:|---:|---:|---:|
| Original SwiftTerm resize | 0 | No | 20.3 ms | 241.4 ms | 66 / 120 |
| Logical buffer rows only | 0 | No | 5.6 ms | 8.5 ms | 0 / 120 |
| Logical rows, eager hidden reflow | 5,000 | No | 116.9 ms | 253.0 ms | 119 / 120 |
| Lazy hidden reflow | 5,000 | No | 2.6 ms | 4.2 ms | 0 / 120 |
| Lazy hidden reflow | 5,000 | Yes | 5.7 ms | 7.2 ms | 0 / 120 |

`CircularBufferLineList.maxLength` is capacity, but SwiftTerm's width path iterated it as content.
Subscript reads materialize empty slots, so the first resize of a fresh 24-row terminal allocated
and resized all 10,000 reserved scrollback rows. Buffer resize now visits `lines.count` only.

A real 5,000-line normal buffer was still reflowed on every tick while Claude's alternate buffer
covered it. Terminal resize now updates the visible alternate grid immediately and synchronizes the
normal buffer only when it becomes visible again. The deliberately extreme fixture pays 177.5 ms
once on alternate-screen exit instead of 117–253 ms on every drag tick. A generic debounce was not
added: after removing invisible work, live grid updates and repaints fit within one 60 Hz frame and
keep terminal content tracking the pointer.

## Cold launch to the first ready window

`THREADING_STARTUP_PROFILE=1` follows the production launch path through launch-ledger open, state
loading, appearance restore, menu construction, `MainWindowController`, ordering the first window,
and the next main queue turn. It then settles the pending content layout and display before
terminating cleanly, so visible outline rows cannot first materialize inside AppKit's termination
flush after the metric has already printed. `total_ms` retains the run-loop readiness boundary;
`settle_layout_ms`, `settle_display_ms`, and `total_to_frame_ms` describe the complete settled-frame
boundary. The one bounded `THREADING_PERF app-startup` line reports every phase separately and
includes the project/session counts that define the measured store. Session restoration, extension
processes, polling, and background services still begin after the profile exits. The ordinary
always-on `app.launch` signpost remains unchanged.

The first Debug trace against one project and 99 sessions found two pieces of invisible eager work
inside the 352–356 ms window-construction phase:

- every visible `SessionRowView` derived account and git information for a hover card that had not
  been requested; and
- the zero-height native `WindowTitleBandView` asked AppKit to render the application icon even
  though only takeover chrome displays it.

Session rows now retain only the source session/activity until the pointer actually requests the
card. The title band similarly asks for the application icon only when its resolved style exposes
the icon slot. An App Launch trace proves both former stacks are absent. The matched xctrace runs
and the lower-noise direct repetitions measured:

| Debug launch measurement | Before | After | Change |
|---|---:|---:|---:|
| xctrace process entry → first ready turn | 652.0 ms | 572.1 ms | −79.9 ms (−12.3%) |
| xctrace window construction | 356.4 ms | 290.9 ms | −65.6 ms (−18.4%) |
| Direct process entry → first ready turn | 687.7 ms | 610.2 ms median of three | −77.5 ms (−11.3%) |
| Direct window construction | 352.1 ms | 284.5 ms median of three | −67.6 ms (−19.2%) |

A follow-up sample of the remaining first-outline mount found another invisible state inside an
otherwise visible row: the first idle `SessionStatusIndicator` spent a 5 ms sample constructing a
layer-backed `ThemedSpinner`. The spinner also owns theme and accessibility-display observers, and
99 stored sessions are overwhelmingly idle at launch. The indicator now materializes that subtree
only when a session first enters working or loading; attention and limit marks keep their original
eager, lightweight geometry. Focused indicator, limit-mark and session-row suites execute 101 tests
across the idle/working/loading/selection transitions.

Three follow-up direct launches against the same one-project / 99-session store measured 531.4,
540.6 and 542.0 ms process-entry-to-ready, with 239.9, 241.6 and 245.0 ms of window construction.
The median intermediate direct baseline was therefore **540.6 ms total / 241.6 ms window
construction**.
The installed app was running when the final check was made, so the CLI's state-lock guard correctly
refused the additional matched App Launch trace; those values were an intermediate direct baseline
rather than a new paired xctrace comparison.

The next call tree found 15 ms of a complete `SessionComposerViewController` built behind the
placeholder used while the saved session is restored: `ChipView`, `PromptView`, and footer controls
were all loaded even though startup never showed the composer. `TerminalContainerViewController`
now retains the composer factory and delegate intent but constructs and installs the controller only
when `showComposer` requests that route. Hide, handoff, recovery, terminal, conversation, and
settings paths inspect the stored controller without crossing that lazy boundary. The late install
also preserves the original view order below the git-status overlay. The following App Launch trace
contains **0 ms** in `SessionComposerViewController`, `PromptView`, or `ChipView`; the focused
composer, fit, toolbar, and recovery-startup suites cover the deferred route and its first use.

That trace also caught the first standard-login row synchronously enumerating account directories
and parsing shell aliases solely to learn that the standard account has no badge. Standard rows now
skip discovery; alternate rows still resolve their visible badge synchronously. Three matched direct
runs immediately before and after that fast path measured:

| Debug direct launch, one project / 99 sessions | Before median | After median | Change |
|---|---:|---:|---:|
| Process entry → first ready turn | 563.5 ms | 541.0 ms | −22.5 ms (−4.0%) |
| Window construction | 246.5 ms | 236.0 ms | −10.5 ms (−4.3%) |

The after runs were 485.1, 541.0 and 541.7 ms total, so launch variance remains material. The final
isolated App Launch capture measured **454.0 ms total / 217.8 ms window construction** and proved
the standard scan absent. One visible alternate-account row still carried a 5 ms directory scan;
removing that would require an honest asynchronous badge-resolution design rather than withholding
or guessing visible identity content.

That same trace found a smaller presentation cost in each mounted sidebar row: the action controls
must exist before hover for keyboard and VoiceOver access, but their hidden SF Symbols do not yet
contribute pixels. `ThemedIconButton` now supports a presentation-only lazy boundary. The real
control shell, constraints, action, and accessibility metadata remain eager; only the latest glyph
is resolved at first draw or explicit reveal. Session, project, and terminal-row hover actions use
that boundary. Component and row tests verify that pointerless activation still works before
materialization and that the latest changed symbol appears on reveal.

The matched follow-up App Launch trace contains no `ThemedIconButton.renderSlot` or CoreUI symbol
resolution below `SessionRowView.init`. It measured **457.1 ms total / 213.3 ms window
construction**, versus **454.0 / 217.8 ms** immediately before the change. At the profiler's 5 ms
sampling interval this is a roughly one-sample window improvement and a flat total, which is the
honest result for this small fix. Three direct launches measured 482.2/194.4, 473.5/191.2, and
460.6/184.4 ms total/window (median **473.5 / 191.2 ms**), but that larger swing includes warm-cache
variance and is not attributed to deferred glyphs.

The remaining window phase is mostly the visible AppKit surface: cold `NSWindow` creation,
split/sidebar construction, first outline cells, symbol/image initialization, Auto Layout, and
initial-frame application. The final trace attributed about 60 ms to AppKit showing the window's
native toolbar, about 55 ms to the first `ThemedOutlineView` layout, and about 40 ms to the outline's
visible-cell provider (inclusive and therefore overlapping). The 99 stored sessions do not all
become views; the outline mounts its viewport.

The stack paths split that apparent 55 ms outline owner into two layouts of the same viewport:
roughly 35 ms of row construction ran while attaching the native toolbar, before the saved window
frame was in force, and roughly 20 ms ran when `applyInitialFrame` established the geometry the
window would actually draw. The rows were therefore paying for a transient, invisible size. The
main-window sidebar now keeps its real empty outline installed through content-controller, toolbar,
and frame setup, then mounts the persisted tree once after `applyInitialFrame`. Standalone sidebar
controllers retain eager mounting. The lifecycle boundary is idempotent, and focused sidebar plus
window/chrome suites cover both the deferred empty pass and the one real mount.

The same samples exposed two smaller hidden-state costs inside every ordinary session row. A
standard-account row constructed an absent account-chip image view and four constraints, and an
unpinned row resolved an SF Symbol and reserved an arranged stack slot for an invisible pin.
Neither subtree now exists until the corresponding state is visible. Reused rows keep a previously
materialized subtree warm and hide it when absent; pinned accessibility content appears at the same
boundary as the indicator. This is content laziness inside the viewport row, not an attempt to make
the outline's row virtualization lazy twice.

The structural duplicate is removed, but its matched after-trace still matters. The startup CLI
now clones the real state into a temporary Cocoa home and replaces the live SQLite family with a
consistent backup, so its lock and launch writes cannot touch the installed app even when that app
remains open. `scripts/profile_threading.sh startup` reproduces the repeated phase lines and
preserves `App-Launch.trace` without opening Instruments or interrupting an active session. The
remaining one-pass visible-row mount and native toolbar installation are the next window owners
after that comparison.

The one-pass trace still found two correctness-preserving micro-costs. Idle/dormant session rows
constructed a full `SessionStatusIndicator` even though it had no pixels; rows now keep a fixed
12-point geometry slot and materialize the indicator only on the first visible state. The title
wrapper also configured font, truncation and alignment on an empty `MorphingLabel`; LabelMorph now
invalidates empty intrinsic state without rebuilding an empty layer tree. The follow-up trace lost
the former indicator and empty-rebuild samples and reduced sampled `SessionRowView.init` work from
about 25 ms to one 5 ms sample. Direct median window construction moved only **209.1 → 208.4 ms**,
so these remain scaling/ownership fixes rather than a claimed launch-speed win.

The next trace put **40 ms** under `ProjectDatabase.load`, **35 ms** of it decoding every saved
`PersistedPanel` and `PersistedSessionAttachments` document solely to identify future/corrupt rows.
Reading SQLite `TEXT` payloads directly as bytes first removed two sampled `String → Data` copies,
but did not materially change wall time because JSON decoding remained the owner. Auxiliary payload
validation now moves to first feature access while preserving the refusal boundary: a first write
before any read validates the existing row too, successful validation is cached, and unreadable
bytes are still never replaced. Startup only scans auxiliary row identifiers so malformed unkeyed
rows remain protected from prune.

Matched three-run Debug launches against the same one-project / 99-session snapshot measured:

| Cold launch phase | Eager auxiliary decode | Lazy feature-boundary decode | Change |
|---|---:|---:|---:|
| State load median | 58.0 ms | **23.3 ms** | **−34.7 ms (−59.8%)** |
| Process entry → first ready turn median | 483.6 ms | **470.2 ms** | −13.4 ms (−2.8%) |

The smaller end-to-end gain is expected noise from dyld, native window construction and the first
main-queue turn; one after-run still recorded a 58.3 ms state outlier. The owned phase is the firm
result. In the verification trace, `PersistedPanel.init` and
`PersistedSessionAttachments.init` have **zero startup samples**; `ProjectDatabase.load` appears
only in two short SQLite reads totalling 0.144 ms, including 0.020 ms for the structural auxiliary
scan. Sixty focused database/state-manager tests cover authoritative corruption, future panels,
future attachments arriving before first read, unkeyed-row pruning, migration and raw UTF-8 bytes.

The next launch trace showed that the supposed one-pass sidebar mount still stopped one lifecycle
event too early. The saved *window* frame was final, but the saved sidebar divider was deliberately
restored on the next main-queue turn, after AppKit had laid out the native toolbar. Mounting rows in
`MainWindowController.init` therefore built the viewport at the default divider, ordered that tree
into the window, then changed its width and laid the same labels and constraints out again. The
trace contained `MorphingLabel.layout` below `restoreSidebarWidth`; a width is presentation
geometry, so neither the model nor the outline should have crossed its lazy boundary before it.

The main-window outline now stays empty through toolbar installation, saved window-frame restore,
ordering, toolbar measurement and saved divider restore. The same next-turn geometry block mounts
the persisted tree after the divider settles and before the first display cycle. The startup
readiness block is queued later, so the measurement still includes the complete visible viewport;
this is deleted duplicate work, not a faster marker. Since the mount deliberately crosses the old
`window_construct` phase boundary, compare the combined window-construction, ordering and
first-ready-turn tail:

| Five-run Debug launch, real snapshot | Prior ordering | Divider-first mount | Change |
|---|---:|---:|---:|
| Window construction + ordering + first ready turn, median | 305.8 ms | **227.8 ms** | **−78.0 ms (−25.5%)** |
| Process entry → first ready turn, median | 420.1 ms | **345.7 ms** | **−74.4 ms (−17.7%)** |

The controlled swap used the same one-project / 99-session snapshot. A second five-run fixed sweep
after the live snapshot gained one session reproduced a **228.2 ms** combined UI tail. Its trace
has no `MorphingLabel` or row layout below `restoreSidebarWidth`; the remaining sampled restore is
empty split geometry and the viewport mounts once. A lifecycle regression test holds the deferred
boundary through the saved-divider turn. The focused sizing/tree suites ran 36 tests (one opt-in
stress case skipped), while explicit 1,000- and 5,000-session sweeps kept 23 materialized cells and
resize p95 at 5.69 ms and 6.32 ms respectively.

The next sampled row-construction owner, the fixed two-button `NSStackView` used by each visible
sidebar row, was also tested rather than assumed. Across seven 500-pair microbench repetitions, a
custom fixed-frame container measured 11.427 ms versus 11.819 ms for the stack: only 0.392 ms over
500 rows, or roughly 0.02 ms at the 23-row launch viewport. Launch-wide A/B/A results moved with
unrelated dyld, state and AppKit variance and did not reproduce that first apparent difference.
The custom component and its stress fixture were therefore reverted; the complexity would not buy
a measurable startup improvement.

The following one-project / 100-session trace exposed two more costs in the same first-turn mount.
`MorphingLabel` prepared every title off-window at the 2x fallback scale, then treated attachment to
the same 2x window as a scale change and rebuilt the identical glyph tree. Recording the raster
scale alongside the completed layout snapshot removes that duplicate while a real display-scale
change still rerasterizes normally. A matched five-run sweep reduced median first-turn work from
**84.66 to 80.86 ms (−4.5%)**; the after trace contains no `MorphingLabel.rebuild`,
`updateForBackingScale`, or `viewDidMoveToWindow` stack beneath row attachment.

Each visible product row also constructed two `ComponentCustomizationHost`s, registered two
notification observers, and ran the empty renderer path before extension processes had started.
Product rows now perform only the synchronous registry check while the resolution is empty. One
sidebar-level observer revisits materialized rows when a publication arrives; a row creates only
the affected host once content exists, while gallery and standalone injected rows remain
self-observing. The next matched five-run sweep reduced median first-turn work again from **80.86
to 76.62 ms (−5.2%)**. From the fresh baseline these two owned-phase changes remove **8.04 ms
(−9.5%)**. Process-entry totals stayed flat within dyld/AppKit launch variance, so no aggregate
speedup is claimed. The final Time Profiler table contains visible `SessionRowView` construction
but no `ComponentCustomizationHost`, `renderComposition`, or LabelMorph attachment rebuild.

The first production-configuration audit corrected the profiler itself before interpreting the
next stacks. With coverage disabled and only arm64 built, five direct Release launches against the
same one-project / 100-session snapshot established this baseline:

| Release cold-launch phase | Median |
|---|---:|
| Process entry → delegate | 103.51 ms |
| State load | 18.62 ms |
| Window construction | 143.43 ms |
| Window ordering | 6.70 ms |
| First ready turn | 62.33 ms |
| Delegate → ready | 250.82 ms |
| Process entry → ready | **354.33 ms** |

The trace found one more invisible branch in window construction: every populated sidebar built,
themed and constrained its two-label no-project prompt, then immediately hid it. The prompt now
materializes only when the rebuilt root tree is actually empty. Hiding it, including entering
Settings with projects present, does not cross that boundary; leaving Settings with an empty store
still creates and shows it. The 29-test sidebar tree/lifecycle run reports 28 passes and one opt-in
stress skip, including explicit populated, empty and Settings-round-trip coverage.

The after trace has no `makeEmptyStateView`, empty-state label, `FontRoleApplying`, or appearance-
variant stack below `ProjectSidebarViewController`. Its matched five direct Release launches ranged
from 317.68 to 414.66 ms and had a **368.53 ms** total median; first-turn work moved from 62.33 to
**61.59 ms**, while window construction moved from 143.43 to 146.23 ms. Dyld, state and native
window variance was larger than the roughly one-sample branch removed, so no aggregate launch
speedup is claimed. The firm result is that an unshown state no longer owns launch work; the current
production baseline remains roughly **350–370 ms process entry to ready**, with about **62 ms** in
the first visible-tree turn.

The next Release audit split `MainWindowController` construction into coarse semantic phases on the
existing one-line startup metric. Against a cloned one-project / 104-session store, the root-content
install and native toolbar were the largest removable pieces of split setup. The command-line Time
Profiler trace explained why: `WindowChromeHostViewController.viewDidLoad` built a complete
`WindowTitleBandView` and `WindowCommandBandView` even in native dress, where both were hidden at
zero height. App-icon lookup, workspace appearance queries, chrome font registration, the command
controls, their constraints, and their observers therefore all ran for pixels that did not exist.

Native dress now installs only two lightweight zero-height structural slots. The actual title and
command bands materialize when takeover chrome first becomes active. A window launched directly
under a takeover theme passes that initial state into the host, so its visible chrome is still built
as part of the first root attachment; native launch and a later native → takeover transition retain
the title and control behavior. Regression tests hold all three boundaries: setting a native title
and laying out the host does not materialize the bands, entering takeover does, and covering-surface
geometry remains identical in both dresses.

To separate this owner from dyld and native-window variance, six eager and six lazy Release binaries
were alternated against pristine clones of the same store. Each binary already contained the same
single toolbar-state update, so the comparison isolates chrome materialization:

| Release cold-launch phase, six-run paired median | Eager hidden chrome | Lazy takeover chrome | Change |
|---|---:|---:|---:|
| Root content installation | 25.52 ms | **18.92 ms** | **−6.61 ms (−25.9%)** |
| Complete split setup | 62.04 ms | **52.10 ms** | **−9.94 ms (−16.0%)** |
| Window construction | 135.23 ms | **126.46 ms** | **−8.77 ms (−6.5%)** |
| Process entry → ready | 302.98 ms | **291.12 ms** | **−11.87 ms (−3.9%)** |
| First ready turn | 30.81 ms | 31.98 ms | +1.17 ms (within run variance) |

The independent five-run lazy sweep measured **272.22 ms** total, **114.97 ms** window
construction, and **17.07 ms** root installation; its App Launch trace measured 262.43, 121.56,
and 18.15 ms respectively. Those absolute totals are reported as a state-and-machine snapshot, not
a universal launch promise. The paired phase delta is the attribution result.

Two nearby experiments are recorded to prevent repetition. Attaching the complete content tree only
after building the toolbar and pane header merely shifted layout between phases and saved about
4 ms of window setup, so that ordering was reverted. Removing the first of two identical
`updateToolbarControlStates` calls was flat within roughly 0–2 ms; the single post-header update is
kept because both toolbar and pane controls exist then, but no launch win is attributed to it.

The native-toolbar phase was then split at its actual ownership boundaries. In five direct Release
launches, its 18.87 ms median comprised **0.03 ms** constructing `NSToolbar`, **18.30 ms** inside
`NSWindow.setToolbar`, **1.84 ms** of app-owned delegate item construction nested inside that call,
and **0.46 ms** applying the compact style. The saved Time Profiler trace places the remaining
attachment time in `NSToolbarView` creation and `_windowWillShowToolbar`. The toolbar is the system
primitive that keeps the sidebar control beside the traffic lights, and its three visible symbols
belong to first paint; replacing it or deferring those pixels would trade correctness or move work
behind the marker for, at most, the 1.84 ms app-owned slice. Treat the roughly 16 ms remainder as a
native floor unless a later OS trace changes that attribution. The sub-phase fields remain in the
one startup metric so a future AppKit change is visible without opening Instruments.

The next removable owner was smaller but entirely invisible. `AccountUsageItemView` used to build
its ring, label, constraints, event observation and repeating refresh timer during every
`MainWindowController` initialization, although an empty or composer launch has no metered account
and never displays it. The pane header now omits the item until a session first supplies an account;
late materialization inserts it in the same arranged position. Reads for extension signals and
session-stop refreshes inspect the optional materialized item and do not cross the boundary.

Six balanced AB/BA Release pairs against clones of the same one-project / 105-session store measured
the owned phases as follows:

| Release cold-launch phase | Eager hidden usage item | Lazy usage item | Change |
|---|---:|---:|---:|
| Controller base initialization | 3.29 ms | **2.76 ms** | −0.53 ms |
| Pane-header construction | 5.91 ms | **5.57 ms** | −0.34 ms |

The median paired deltas were −0.54 and −0.33 ms respectively. Window construction and total launch
also moved in the favourable direction, but by much larger amounts than the removed subtree and
with divergent state/native-window timings, so no aggregate speedup is attributed to this change.
The retained claim is structural plus the approximately **0.9 ms** owned-phase reduction: a hidden
timer-owning view no longer exists at launch. Focused navigation and chrome suites ran 56 tests;
the lazy regression asserts both non-materialization on an empty window and the exact arranged
position after first access.

The same header audit did **not** treat the whole action group as hidden. New Session, the status
card choice and the display-pane control are standing first-paint actions; session context and shell
also retain their real control shells for keyboard/accessibility behavior. Only three glyphs have no
launch pixels: the hidden native/terminal surface switch and both halves of the hidden Open In
control. Those buttons now use `ThemedIconButton`'s existing deferred-presentation boundary. Their
geometry, actions and accessibility metadata remain eager, and the latest symbol or application
icon materializes when the control is first revealed.

Six balanced AB/BA Release pairs measured pane-header construction at **5.92 → 4.16 ms**, with a
median paired delta of **−1.79 ms**. Complete split setup and total launch moved in the opposite
direction because content installation, native window construction and first-turn scheduling varied
by much more than this subtree; no aggregate claim is made. The after trace contains no symbol stack
beneath `makePaneHeaderView`; its remaining sampled launch symbol is the separate, eagerly created
`ThemedTabItemView` in controller base initialization. Eight focused navigation tests verify the
three hidden glyphs stay unmaterialized while visible/standing actions remain complete.

The remaining sampled symbol stack was the page tab itself. An empty launch constructed a complete
`ThemedTabItemView`—including its SF Symbol, close button, theme observation and constraints—even
though no session, terminal or project composer existed to name. Settings has a separate mode
header and likewise does not need a document tab. The pane header now starts without that subtree
and inserts it at the leading edge only when `updateSessionTitleItem` first has a real workspace
page. A tab first requested while Settings is active inherits the hidden state rather than flashing
through the mode header.

Six balanced AB/BA Release pairs against the same one-project / 105-session snapshot measured
controller base initialization at **2.814 → 0.433 ms**, a median paired reduction of **2.382 ms
(84.6%)**. Every pair moved in the same direction. Window construction and total launch also moved
favourably, but those deltas include native-window, dyld and scheduling variance and are not
attributed to this subtree. The after trace contains zero `ThemedTabItemView` or `pageTabView`
startup samples; the one remaining sampled `Design.Symbol.image` belongs to the visible project
sidebar header. The focused 29-test navigation/Open In/header run passed, and a production-route
regression now proves that Settings leaves the tab unbuilt while selecting a real project creates,
positions and reveals it. That stronger test also exposed and fixed a pre-existing omission where
selecting an existing project opened its composer without refreshing the page header or window
title.

The measurement above stands as taken; only the subtree's name has changed since. The header's
leading control is no longer a `ThemedTabItemView` — `PageTitleView` names the page instead (see
[`window-chrome.md`](window-chrome.md)) — and it inherits this laziness unchanged: same lazy
`pageTitleView` accessor, same insertion at the leading edge on the first real workspace page,
same hidden-under-Settings inheritance, and `testPageTitleIsLazyUntilARealPageNeedsIt` is the
same regression test renamed. It is a slightly smaller subtree than the one measured, having no
close button.

The next trace exposed work that was visible but unnecessarily expensive rather than hidden. The
first Claude and Codex rows loaded their 32 px brand marks with two synchronous
`NSImage(contentsOf:)` calls from loose bundle files. The retained post-page-tab Time Profiler
capture assigned **9.17 ms** of main-thread weight to those two `AgentBrandIcons.load` stacks,
including ImageIO plug-in and PNG metadata work. Both marks now also live in the compiled asset
catalogue and the runtime path uses `NSImage(named:)`; the loose resources remain because the
component gallery intentionally attaches them as sample files. The Codex rendition is compiled as
a template image, while the Claude rendition retains its colour.

The after Release trace contains zero `AgentBrandIcons`, `SessionRowView.applyAgentIcon`,
`NSImage(contentsOf:)`, or `ERROR_ImageIO_DataBufferIsNotReadable` samples. Its sole ImageIO sample
is AppKit initializing image suffix support while constructing the native titlebar, not a session
row. Six balanced launch pairs were too noisy to claim an aggregate improvement: the owned sidebar
phase had a +0.47 ms median paired delta because two after runs were system-load outliers, while the
other four pairs ranged from −1.26 to +1.07 ms. The retained claim is therefore deliberately
limited to removing the measured synchronous file-decode stack, not an end-to-end launch delta.
The six-test account-mark suite verifies catalogue presence, template semantics, sizing and the
rendered provider strip.

The next invisible startup owner was the launch ledger itself. Every healthy JSONL line first
decoded a version-only probe and then decoded the complete `LaunchLedgerRecord`, so the ordinary
current-format path parsed the same bytes twice on the main thread. The parser now uses one custom
`Decodable` wrapper: it reads `version` and asks the same decoder for the complete record only when
this build owns that format. A later-format line still stops after the discriminator and remains
byte-for-byte untouched; a regression supplies deliberately incompatible `kind` and `launch`
payload shapes to prove an old build never asks for them.

The startup line retains `ledger_open_ms` as a permanent coarse attribution field. Six balanced
AB/BA Release pairs against the same 153-record, 33.8 KiB production snapshot measured ledger open
at **8.102 → 6.442 ms (−1.659 ms, −20.5%)**, with a **−1.712 ms** median paired change. The matched
Time Profiler capture reduced `LaunchLedgerParser.parse` from 5 to 3 ms of sampled weight,
`JSONDecoder.decode` from 6 to 4 ms, and `LaunchLedger.openLaunch` from 7 to 6 ms. Total launch moved
in the favourable direction, but unrelated state, native-window and scheduling phases varied too
widely to attribute that aggregate.

The scaling boundary was measured separately rather than inferred from the ordinary file. A cold
synthetic fixture at the 512-record retention ceiling (91.6 KiB, 20 complete launches with rich
checkpoint detail) measured **8.706 → 7.660 ms (−1.047 ms, −12.0%)**, with a **−0.966 ms** median
paired change across six Release pairs. The retained
`scripts/profile_threading.sh launch-ledger-stress` fixture drives the same 512-record / 20-launch
shape repeatedly through the production parser and emits median, p95 and max latency; routine
`full` runs it.

That trace also corrected the endpoint it was measuring. The `app-startup` line printed before
AppKit's first display cycle: the metric appeared at 23:31:06.645, while visible session rows were
still resolving account identity at 23:31:06.688–06.695, and the Time Profiler placed row
construction below the subsequent `NSApplication.terminate` flush. The profile path now settles
the pending content layout and display before printing and terminating. The original run-loop
readiness fields remain for comparison, while `total_to_frame_ms` is the number to use for
first-frame work.

The newly visible row work included repeated `IconBackplate.tone(of:)` calls for Claude's one
immutable colour mark. A row measured the same pixels during configuration and again when AppKit
assigned its background style. `AgentBrandIcons` now measures that mark once; session rows pass the
known tone through every later plate decision. Extension images still measure their own pixels
because their provider may replace the bytes. An isolated 1,000-iteration microbenchmark using the
real 32 px Claude asset and a 23-row viewport with two style passes measured **7.278 ms median /
7.709 ms p95** for per-row measurement versus **0.177 ms / 0.230 ms** with the shared tone. This is
an owned primitive comparison, not an attributed end-to-end launch delta; the existing
`sidebar-stress` fixture carries the production viewport path.

The first settled-frame Release baseline against the same two-project / 114-session snapshot
measured **445.412 ms** median process entry to settled frame, including **51.550 ms** of explicit
layout and **41.000 ms** of display after the first ready turn. The isolated trace measured
482.763 / 55.467 / 49.204 ms respectively. The profiler build is unsigned and host-architecture
only; the measured copy receives a throwaway bundle identity and ad-hoc signature afterwards, so
Release profiling does not depend on a development certificate or redirect through LaunchServices
to the installed app.

Although row customization hosts were already deferred, each ordinary row still eagerly built the
extension surfaces they would have hosted: two replaceable-content wrappers, an empty after-title
stack, and an empty wake/snooze label. A native row now starts as its direct native subtree. The
identity wrapper, row wrapper and slot materialize only when the registry publishes corresponding
content; the attention label materializes only when that row first has durable attention state.
Rows reused after those boundaries keep the materialized subtree warm, and injected gallery/test
rows retain their self-observing eager route.

Three fresh Release launches reduced median settled layout from **51.550 to 45.822 ms (−11.1%)**;
the after trace measured **49.117 ms**, down from 55.467 ms. Its inclusive sampled table-row work
fell from 55.796 to 46.448 ms, Auto Layout engine work from 52.493 to 45.000 ms, row initialization
from 29.515 to 26.448 ms, and key-loop work from 15.000 to 11.448 ms. This is an owned layout and
scaling result, not an end-to-end launch claim: median delegate-to-settled-frame time was effectively
flat at 328.780 versus 328.383 ms, while process-entry variance moved total-to-frame from 445.412 to
475.409 ms. A direct attempt to batch key-loop recalculation was also rejected: the same mounted
window measured 2.371 ms on AppKit's automatic path versus 2.533 ms when batching and explicitly
recalculating it.

The next trace attributed one complete 5 ms sample in `ProjectRowView.setupViews` to the trailing
collapsed-session count: the count was empty, but constructing its label still initialized the
monospaced-digit font and OpenType feature table and installed three constraints. The label now
materializes with the first nonzero count; a reused row keeps it warm and hides it when the count
returns to zero. Hover controls retain their original overlay/crossfade geometry.

The follow-up live snapshot had gained two sessions (116 instead of 114), so its aggregate launch
numbers are not treated as a controlled pair. Median settled layout nevertheless moved from
45.822 to 44.459 ms and the trace boundary from 49.117 to 47.516 ms. The firm result is in the
owned call tree: `ProjectRowView.setupViews → numericDetail → CTFontCreateWithFontDescriptor →
CreateOTFeatureTable` moved from 5 ms to **zero samples**. Fourteen focused count, reuse, hover,
extension-replacement, selection-theme and render tests cover the boundary.

The ordinary session row still put its native icon/title stack inside a one-child `NSView`
wrapper, even after the extension container around that wrapper had become lazy. The wrapper added
no ownership or replacement semantics; it existed only to pin the stack to four edges. The native
stack is now the row's direct arranged child and becomes the extension container's default content
only if a row-level customization is published. This removes one view and four constraints from
every mounted ordinary session row while preserving the exact reparenting boundary extensions use.

The 5,000-session Debug fixture moved final layout from **47.185 to 46.781 ms** and resize p95 from
**5.895 to 5.631 ms**. Those small direct changes are close enough to run noise that they are not
claimed as exact savings. A follow-up isolated Release trace was directionally consistent: sampled
table layout moved 48.639 → 36.341 ms, row initialization 36.397 → 25.605 ms, key-loop work
19.151 → 5.000 ms, Auto Layout engine work 39.436 → 21.494 ms, and stack-view work
15.000 → 1.720 ms. Direct settled layout was 48.938 ms and the trace measured 44.507 ms, within
the existing launch variance. Fifty-nine focused row, extension, title-morph, rendering and project
count tests cover the simplified hierarchy; the scaling result is the deleted per-cell structure,
not a promised end-to-end launch delta.

The next scaling audit made the Release launch harness capable of raising its isolated SQLite
snapshot to an exact session count. `THREADING_STARTUP_PROFILE_SESSIONS=5000` repeats a real,
schema-valid session payload only inside the temporary backup; every direct run and trace still
receives the same pristine copy, and the user's live store is never opened for writing. That
fixture showed that the complete logical tree was virtualized at the cell layer but still expensive
at the AppKit data-source bridge. `NSOutlineView` repeatedly asked Swift arrays for Objective-C
children while recursively expanding the standing tree. Caching each immutable node's `NSArray`
projection, invalidated whenever its Swift children change, reduced the sampled initial sidebar
mount from about **140 ms to 42.9 ms**. Direct first-turn work fell from a **164.9 ms** median to
**84.5 ms**. Whole-launch dyld and native-window variance moved in the opposite direction during
that comparison, so the owned outline phase—not the aggregate—is the result to preserve.

With outline enumeration bounded, the same trace exposed authoritative session decoding as the
remaining cardinality-dependent startup owner. The database previously invoked a top-level
`JSONDecoder.decode` once per session. It now decodes bounded 256-row JSON arrays while retaining
each row's indexed metadata; a failed batch falls back to individual decoding only to identify the
exact corrupt row before refusing the whole load. The paired Release results were:

| Startup state workload | Per-row decode | Bounded batch decode | Change |
|---|---:|---:|---:|
| Ordinary store (119/120 sessions), median | 17.35 ms | 17.83 ms | flat (+0.48 ms) |
| 5,000 sessions, median | 120.88 ms | **100.06 ms** | **−20.82 ms (−17.2%)** |
| 5,000-session premium over ordinary | 103.52 ms | **82.23 ms** | **−21.29 ms (−20.6%)** |

Time Profiler independently moved `ProjectDatabase.load` from **62.86 to 50.78 ms** and the
inclusive state-load stack from **81.93 to 61.07 ms**. The optimized three-run settled-frame
median was 594.62 ms versus 717.47 ms in the immediately preceding run, but that larger aggregate
also includes measured system-wide launch variance and is not attributed to the decoder. Database
tests cover syntactically invalid payloads, valid JSON with a schema/type failure, exact corrupt-row
identity, and ordering across the 256-row boundary. Retained artifacts are
`/tmp/threading-profiles/20260812T142156Z-startup`,
`/tmp/threading-profiles/20260812T143632Z-startup`, and
`/tmp/threading-profiles/20260812T144409Z-startup`.

## Display-pane transition beside a live TUI

Opening the right pane originally performed two consecutive 200 ms transitions: first the split
item uncollapsed to its chrome floor, then its remembered divider width was restored. Every pixel
width along both motions became a SwiftTerm character-grid resize, emulator reflow, PTY resize and
SIGWINCH. A full-screen Codex or Claude process answers each SIGWINCH by repainting its alternate
screen, so a visually small motion multiplied into layout plus process output at animation-frame
frequency.

The remembered divider position is installed in the same geometry transaction as the uncollapse,
so there is no second restoration motion. More importantly, terminal-backed sessions take the
immediate split route even when the caller requests animation. The policy is resolved once in the
shared split-collapse boundary for both edge panes, so the sidebar and display panel cannot
disagree. That commits the one useful final width without blocking the main thread on a
backing-tree animation or manufacturing intermediate terminal grids. Native conversation surfaces
retain the standard motion. This is a presentation policy at the pane boundary, not a SwiftTerm
resize suppression: terminal frame, emulator, PTY, accessibility, search and scroller state still
follow the one final geometry normally.

The empty display pane had a second independent cold cost: `viewDidLoad` eagerly installed a
`WKWebView`, launching WebKit services for image, chart, native-controller, and empty panes.
`DisplayPaneController` now installs its shared document renderer only when HTML is actually
selected, and tears down a switched-away page without constructing the renderer for non-HTML
content.

`WindowEdgeTests.testStressDisplayPaneTransitionBesideCodexWhenEnabled` drives that production
route beside a real alternate-screen terminal and feeds a Codex-like repaint after every accepted
grid. Its phase probes separate controller preparation, collapse state, split layout, toolbar,
divider geometry, terminal grid decisions, and repaint. A five-cycle fresh-process Debug
comparison measured:

| Workload | Before | After |
|---|---:|---:|
| Cold first open | ~302 ms | 10.7 ms |
| Five open/close cycles | ~399 ms | 46.7 ms |

The final natural-grid fixture accepts at most one grid per completed action; a remotely frozen
grid accepts none. There are no synthetic transition ticks or secretly deferred grids. Run the
fixture through `scripts/profile_threading.sh display-pane-stress`; routine `full` includes it.

## Git Review as the first stress target

`GitReviewViewTests.testStressLargeFileIndexesWhenEnabled` renders collapsed indexes with
10, 100, 500, and 1,000 files. It is gated by `THREADING_GIT_STRESS=1`, because a workload is
not a correctness test and should not tax every fast-suite run.

The first run established that collapsed bodies were not enough. A Debug XCTest run on the
development machine measured:

| Files | Eager stack | 20-row stack | Virtual table | Jump to last row |
|---:|---:|---:|---:|---:|
| 10 | 37 ms | 25 ms | 24 ms | 0.7 ms |
| 100 | 882 ms | 34 ms | 21 ms | 20 ms |
| 500 | 18,704 ms | 29 ms | 20 ms | 18 ms |
| 1,000 | 94,171 ms | 29 ms | 19 ms | 18 ms |

The superlinear cost was AppKit laying out every arranged header before presenting the first
one. A 20-row progressive stack fixed initial presentation, but a deterministic walk through
all 1,000 files still did not finish in a minute: every append retained another header and
made later stack layout more expensive.

File comparisons therefore use `ThemedTableView`. All file models are immediately addressable,
while AppKit creates views only around the viewport. The 1,000-file run instantiates 14 rows
initially and 28 total after jumping to the end. There is no paging control or deep-index
latency cliff, and expanded diff bodies remain lazy as before. Notices, the staged commit
composer, and commit details are virtual table rows on file-comparison surfaces so they keep
the original scroll behavior. Opening the diff at deterministic row 777 of 1,000 takes about 3 ms;
the fixture also asserts that the row still carries its exact new-file editor line.

That two-line deep-jump fixture did not reproduce a reported pause on a real 174-file working
tree, so `git-stress` also carries a 174-file comparison whose selected file reaches the 400-line
display cap. The original per-line `NSStackView` built hundreds of controls and constraints on
first open, then made automatic-height collapse remeasure the retained tree. One selectable
TextKit document per hunk removes that second layout system while keeping wrapping, syntax colour,
full-width change washes and exact line context. Cached contiguous wash runs also keep paint from
re-enumerating TextKit fragments on every scroll frame.

| 174 files, selected file 400 lines (Debug) | Per-line views | TextKit document |
|---|---:|---:|
| First open, construction + layout | 364.0 ms | 43.7 ms |
| Close, invalidation + layout | 5,571.0 ms | 1.2 ms |
| Reopen cached body | 6.1 ms | 1.7 ms |
| 48-frame forced scroll | — | 9.7 ms/frame |

The same retained run keeps the 1,000-file index at 20.4 ms, the deep jump at 19.5 ms, and the
two-line exact disclosure at 3.3 ms. Text-file state now defaults to expanded, but virtualization
is still the construction boundary: offscreen expanded files are model booleans, not TextKit views.

The next reported case was not a large file but a generated **large index**: 8,985 expanded files
with 80,865 added lines. A production trace of the real 8,984-file checkout showed the outer
`git.review.render` taking 43–295 ms every time the watcher fired, while `render-files` itself was
mostly 15–22 ms. `show` was tearing down the table, clearing every height, and rebuilding the
visible TextKit rows even when the file identities had not changed. It also restored a raw y
coordinate, so files inserted above the reader changed which path that coordinate named.

`testStressMassiveExpandedFileIndexWhenEnabled` now carries that shape in `git-stress`. A 2026-08-08
Debug run at 620×760 measured:

| 8,985 files / 80,865 added lines | Result |
|---|---:|
| Cold model-to-table render | 17.1 ms |
| Initial layout | 30.2 ms |
| 48-width live-resize layout, average / p95 / max | 6.08 / 6.66 / 10.49 ms |
| Height-discovery document drift | 0 pt |
| Continuous 24-viewport sweep, forced bitmap p95 | 14.7 ms/frame |
| Full-index 120-step sweep, forced bitmap p95 | 33.4 ms/frame |
| Insert 12 paths before viewport + anchored refresh | 35.1 ms |
| Rows instantiated after both sweeps | 437 / 8,985 |

The full-index sweep deliberately jumps about 75 expanded files per frame and is closer to dragging
the scroller thumb through the whole document than trackpad reading. A fresh 2026-08-11 baseline
put that path at 32.5 ms p95: every transient viewport built complete interactive headers and
TextKit bodies that disappeared on the next pointer event. The scroller now reports a knob action
before AppKit applies it. Only that path creates lightweight rows carrying the file path, counts,
expanded state, themed surface, and the same estimated geometry; ordinary wheel and trackpad
scrolling still build complete rows. Release replaces the visible lightweight rows at the exact
same clip origin.

Three retained-process runs measured 11.6–11.9 ms p95 for the full-index sweep, down from 32.5 ms.
The resting viewport took 13.5–15.7 ms to materialize complete TextKit rows. Representative
continuous scrolling remained 14.4 ms p95. Across both sweeps the table constructed 440 rows for
8,985 files, 380 of them transient thumb-drag rows rather than TextKit documents. The result keeps
thumb tracking below a 60 Hz frame without changing honest scrollbar extent or adding a debounce.
The resize phase drives a 420–820-point triangle wave through `viewDidLayout`, so every frame takes
the width-change branch and invalidates all 8,985 cheap height estimates. Its measured maximum is
still below one 60 Hz frame. Keep the complete invalidation unless a future fixture crosses that
budget: invalidating only visible rows leaves the scrollbar extent and offscreen wrap estimates at
the old width, producing a jump later rather than removing work.
The continuous workload stays inside a 60 Hz frame while also forcing software bitmap capture.
More importantly, neither a watcher refresh nor exact-height discovery is allowed to land during
live momentum: both coalesce until `didEndLiveScroll`, which protects velocity independently of
their eventual resting cost. The refresh span is `git.review.refresh-files` and reports inserted,
removed, compared, changed and reordered path counts.

The lightweight seek rows earned two refinements on 2026-08-12, after a real +20k-line
uncommitted diff showed their degenerate case: the sweep's assumption of ~75 small files per
viewport inverts when a handful of enormous expanded diffs own the document height, and a drag
then shows nothing but bare card surface until mouse-up — reported as "scrolling shows nothing
until I release the scroller". First, a deferred body now holds a `DiffSkeletonView` ghost —
proportional added/removed bars drawn only for the rows intersecting `dirtyRect`, pulsing by a
layer-opacity animation rather than a redraw timer — so the per-pointer-event workload is
unchanged. Second, a thumb held still for `GitReviewDefaults.scrollerSeekSettleDelay` (0.15 s)
materializes the visible rows for real at the exact clip origin *without* ending the drag's
transaction: only `isFileScrollerSeeking` clears, so the next knob jump re-enters the cheap
path, while exact-height discovery and any coalesced watched phase still wait for
`didEndLiveScroll`. People scrub in drag–pause–look strokes; the settle pass answers the pause
with content at the release path's own measured cost (13.5–15.7 ms), paid only once per pause.
A ghost body is also excluded from exact-height recording (`hasEstimatedGhostBody`): the
skeleton stretches to whatever the table gave the row, so measuring it would replace the
model's honest line-weight estimate with the header's fitting height and collapse the
scrollbar's extent.

The 2026-08-14 review-polish pass added a retained sticky file heading, a bounded loaded-file
navigator, split/unified presentation, and bounded context expansion without changing the table's
file-row virtualization boundary. A same-machine Debug comparison against `29a828a9` measured the
174-file forced-scroll workload at 15.814 ms/frame before and 16.952 ms/frame after. On the
8,985-file fixture, resize p95 moved from 8.019 to 8.483 ms, continuous-scroll p95 from 22.769 to
24.442 ms, and full-index seek p95 from 22.561 to 23.510 ms. Cold render plus layout was noisier:
the single baseline sample was 36.554 ms and three retained after samples ranged from 39.887 to
42.189 ms, so it is recorded as Debug diagnostic evidence rather than a shipping launch claim.
The load-bearing scroll and resize comparisons remained within 10% of the matched baseline, and
both opt-in Git Review stress tests passed after the final sticky-header implementation.

That pass also exposed a temporal resize defect which elapsed-time-only measurement could not
describe: the split divider and clip view reached the new width in one display frame, while the
table column, mounted card and TextKit container sometimes consumed the width invalidation in the
next layout traversal. `viewDidLayout` now states the clip width on the virtual table synchronously
and, after invalidating the complete index's cheap height estimates, settles only the mounted
viewport in a non-animated transaction. Offscreen rows remain model estimates and no debounce is
introduced. The resize fixture now gates coherence as well as time: every descendant must advance
by the viewport's exact width delta and leave no second visible layout frame pending. Two retained
8,985-file runs measured 8.212 and 8.415 ms resize p95, with 12.726 and 11.183 ms maxima, versus the
pre-fix 8.483 ms p95 / 11.584 ms maximum. Both recorded `max_width_delta_drift=0.000` and
`pending_layout_frames=0`.

The interaction follow-up later that day replaced the retained header's decorative copy with one
real header-only `GitReviewFileRow` and moved disclosure height invalidation after its constraint
swap. The first canonical sample ran immediately after a long cold build and was not repeatable
(16.151 ms resize p95). Three direct warm repeats from the same built bundle measured resize p95
at **10.920, 10.170 and 8.782 ms**; the last two maxima were **12.885 and 12.581 ms**, and every
sample kept `max_width_delta_drift=0.000` and `pending_layout_frames=0`. The same repeats put the
massive fixture's continuous-scroll p95 at 27.480–42.076 ms and full-index seek p95 at
26.354–46.979 ms; those Debug drawing tails remain noisy, so the retained-header contract stays
one bounded view and the load-bearing resize claim is geometry coherence plus the repeated warm
frame result, not the post-build outlier. The ordinary 174-file/400-line workload measured
18.220 ms per forced-scroll frame.

The 2026-08-15 context-anchor and header-alignment follow-up preserves that boundary. Context
expansion reloads only its materialized row, restores an adjacent changed source line to the same
window coordinate, and defers the replacement during live momentum; it does not construct an
offscreen row to find the anchor. One clean warm standard run measured the 174-file/400-line forced
scroll at **18.376 ms/frame**. Two warm 8,985-file repeats measured resize p95 at **8.869 and
11.077 ms** (max **12.215 and 13.659 ms**), continuous-scroll p95 at **46.458 and 28.977 ms**, and
full-index p95 at **27.614 and 35.636 ms**. Every resize sample retained
`max_width_delta_drift=0.000` and `pending_layout_frames=0`; both opt-in stress workloads passed.
The spread in forced bitmap drawing remains the already-recorded Debug tail, while resize geometry
and the ordinary workload remain coherent with the established warm range.

The 2026-08-17 file-card silhouette and hunk-disclosure follow-up keeps collapse state in the
virtual file-row model and hides only the mounted hunk body. A toggle invalidates that one row;
offscreen expanded files still remain booleans and estimates rather than constructed disclosure
or TextKit views. The complete-index resize estimator also takes a zero-collapse fast path, so its
normal 8,985-file width pass does not derive hunk identities or allocate per-hunk state. A clean
standard run measured the 174-file/400-line forced scroll at **11.234 ms/frame**. Two sequential
warm massive-index runs measured resize p95 at **9.005 and 8.091 ms** (max **11.425 and
12.502 ms**), continuous-scroll p95 at **20.026 and 18.088 ms**, and full-index p95 at **19.525
and 16.012 ms**. Both retained `max_width_delta_drift=0.000` and
`pending_layout_frames=0`; the standard and massive opt-in workloads passed. Rounded-card clipping
therefore does not change the existing virtualization or live-resize coherence boundary.

The 2026-08-17 pointer and disclosure-settling follow-up keeps those same bounds. Source-line hover
is one cached TextKit logical-line rectangle and invalidates only the old and new pointer targets;
there is still no view per source line. A hunk toggle performs two non-animated mounted-viewport
layout passes in the input event — model estimate, then exact TextKit height — so no old-height
table frame reaches display. Offscreen files remain estimates and neither pass constructs them. The
174-file/400-line workload measured **10.654 ms/frame** and its disclosure cycle completed without
a pending layout frame. Two sequential warm 8,985-file runs measured resize p95 at **8.421 and
8.790 ms** (max **11.580 and 12.303 ms**), continuous-scroll p95 at **16.505 and 17.318 ms**, and
full-index p95 at **15.606 and 15.491 ms**. Both recorded `max_width_delta_drift=0.000` and
`pending_layout_frames=0`; the standard and massive opt-in workloads passed.

The generated workload is the regression boundary, but it cannot reproduce the object database,
index and history shape of Linux-scale repositories. `git-repository-stress` accepts an existing
checkout and runs three complementary layers without modifying it:

1. production `GitReviewReader` calls enumerate visible paths, compute the uncommitted summary and
   parsed diff, and load the first 100 history rows;
2. a bounded real revision-range command and `GitDiffParser` report process and parsing time
   separately; and
3. the resulting real models mount in `GitReviewViewController`, lay out, draw, and seek to the
   bottom through the same virtual table as the application.

The default range is `HEAD~100..HEAD`. A larger range that crosses the production 8 MiB diff cap
reports `result=output-too-large` and the time to reach the bounded refusal; the harness does not
raise the cap to manufacture a render result. Use a closer base to profile the visible pane, or a
known large commit/range to test the bound deliberately. Results include first-run, median, p95
and maximum wall latency so filesystem-cache effects stay visible. This case is manual because an
external repository and its cache state are not reproducible enough for routine `full`; setting
`THREADING_GIT_REPOSITORY_STRESS_PATH` includes it in `full+`.

A five-run Debug smoke measurement on 2026-08-12 verified the complete harness before using a
Linux-scale checkout. The supplied repository had 1,646 visible paths; the revision range produced
342 files, 54,396 presented diff lines and 2.60 MiB of patch data:

| Real-repository phase | Median | p95 | Max |
|---|---:|---:|---:|
| Enumerate repository files | 37.5 ms | 37.9 ms | 40.5 ms |
| Uncommitted summary | 155.0 ms | 156.0 ms | 158.6 ms |
| Parsed uncommitted review | 154.5 ms | 155.2 ms | 167.8 ms |
| First 100 history rows | 572.9 ms | 575.7 ms | 728.6 ms |
| Revision-range Git command | 111.1 ms | 112.9 ms | 134.8 ms |
| Revision-range parse | 101.0 ms | 102.2 ms | 102.7 ms |

The one real-model view pass then took 20.5 ms to install, 51.5 ms to lay out, 23.6 ms to draw,
and 31.6 ms to seek and render the bottom viewport while instantiating three of 342 file rows.
This is a harness baseline, not a Linux-scale conclusion. It does, however, identify the
numstat-bearing 100-row history query as the first production phase to inspect when the larger
checkout is run.

### Linux-scale result and repairs

The follow-up used a full clone of `torvalds/linux`: 94,854 visible paths, roughly 1.46 million
commits, an 8.2 GiB checkout and a 6.5 GiB object database. A macOS case-insensitive checkout
cannot represent 13 case-colliding Linux paths independently, so the working tree deliberately
reported those 13 files as modified; the benchmark did not clean or rewrite the external clone.
The real range `HEAD~100..HEAD` produced 970 files, 39,488 presented lines and 1.58 MiB of patch
data. Five-run Debug medians exposed three independent defects:

1. untracked synthesis used full porcelain status merely to obtain untracked names, making Git
   walk the tracked index twice for a working-tree review;
2. the history page mounted all 100 graph rows in an `NSStackView`; and
3. repository enumeration applied `localizedStandardCompare` to every path, while opening one
   mobile repository file repeated that complete catalogue solely as an allowlist check.

The reader now uses `git ls-files --others --exclude-standard -z` for untracked synthesis. It
preserves ignored-file filtering and literal NUL-delimited names, including newlines and non-ASCII
characters. The immediately matched run reduced summary from 589 to 341 ms and parsed
uncommitted review from 593 to 349 ms, both about 42%; later warmed final medians were 300 and
304 ms. The remaining time is Git/process and bounded untracked-file synthesis, not main-thread
view construction.

History retains the whole `GitCommitGraph` as small value geometry but hands rich rows to a fixed-
height `NSTableView`. `Show more` can therefore retain additional model pages without making
construction, layout or drawing proportional to total history. A 1,000-commit regression mounts
only the two visited viewports. The real 100-row page changed as follows:

| History UI phase | Eager stack | Virtual table | Change |
|---|---:|---:|---:|
| Render | 48.8 ms | 11.3 ms | −77% |
| Layout | 155.3 ms | 23.1 ms | −85% |
| Draw first viewport | 180.7 ms | 28.4 ms | −84% |
| Seek + draw bottom | 296.8 ms | 43.8 ms | −85% |
| Rich rows constructed | 101 | 33 across both viewports | O(visible) |

The table must be identified inside its data-source callbacks by its already-installed column
identifier, not by reading the controller's lazy `historyTableView` property. Doing the latter
re-enters initialization while `dataSource` is being assigned and recursively constructs tables.
The 1,000-commit and existing large-file regressions pin that lifecycle boundary.

For the 94,854-path catalogue, direct isolation measured Git at 160–180 ms, UTF-8 decode and value
creation around 98 ms, localized natural sorting at 256–262 ms, and deterministic lexical sorting
at about 13 ms. Repository tools conventionally expose locale-independent Git path order, so the
reader now explicitly merges tracked/untracked output with lexical sorting. The production median
fell from 548 to 305 ms (−44%). Opening a single remote file no longer builds that array: after
containment and regular-file checks it asks Git for one `:(literal)` path, preserving the tracked
or non-ignored allowlist without accepting wildcard or exclude pathspecs. A Linux file open now
takes 29.6 ms median; previously it necessarily paid the roughly 548 ms catalogue first.

The final representative run was:

| Linux workload | Median | p95 | Cold/maximum |
|---|---:|---:|---:|
| Enumerate 94,854 repository paths | 304.6 ms | 309.0 ms | 769.5 ms |
| Validate and read one repository file | 29.6 ms | 29.8 ms | 30.4 ms |
| Uncommitted summary, 13 files | 299.9 ms | 302.9 ms | 307.0 ms |
| Parsed uncommitted review, 13 files | 304.0 ms | 304.8 ms | 306.3 ms |
| First 100 history models | 92.9 ms | 97.9 ms | 569.5 ms |
| Range Git command, 970 files | 439.4 ms | 448.5 ms | 790.0 ms |
| Range parse, 39,488 lines | 80.2 ms | 81.5 ms | 83.6 ms |

Cold history and range reads remain visibly cache-sensitive: their first iterations are roughly
six and two times their warm medians. No reader change in this pass targeted those commands, so
their warmed median movement across runs must not be credited to the UI repair. The next work on
those phases belongs below `git.process` (arguments, object/index cache behavior, or progressive
presentation), while the range parser and both virtual tables are already bounded enough that
moving the same work around the main actor would not address the measured owner.

### Progressive Git-process follow-up

Command isolation against the same Linux checkout showed that the remaining history cost was not
commit traversal. Metadata for 100 commits takes about 10–20 ms in `/usr/bin/git`, while
`--numstat` opens enough trees and blobs to take roughly 50 ms warm and several hundred
milliseconds cold. Git's unique `%h` abbreviation and `%D` decoration expansion also double the
otherwise-minimal metadata command on this object/ref population. The pane therefore now presents
the whole graph, full subjects, authors and dates from a metadata-only page; it derives a temporary
seven-character label from `%H`, shows an ellipsis in the count column, and asynchronously enriches
the same fixed-height rows with exact abbreviations, refs and `+/−` statistics. Enrichment reloads
only matching rows by hash and never rebuilds graph geometry. A failed statistics read leaves the
usable history in place rather than replacing it with an error.

The matched five-run result changed history's presentation-critical read from 92.9 ms median and
569.5 ms first run to 40.2 ms median and 95.8 ms first run. Exact statistics then arrived in a
separate 92.4 ms median read; its 555.0 ms cold outlier no longer blocks first paint. The table
remained bounded at 33 constructed rows and about 48 ms for a bottom seek.

For a full range, changing rename detection, indentation heuristics or Git's Myers/minimal diff
algorithm did not materially move the roughly 340–450 ms Git command. A raw NUL-delimited file
index, however, asks only for stable paths and change kinds: the initial Linux run measured the
970-file `HEAD~100..HEAD` roster at 44.7 ms median versus 436.7 ms for the unified patch plus
80.1 ms to parse it. Large staged and checkpoint comparisons therefore start that compact read
only after the full patch has missed a 100 ms responsiveness budget; ordinary diffs spawn no
second process.

The first version stopped at progressive presentation: it drew non-interactive `loading…` rows,
but still let the complete patch finish and replaced every value model afterward. That moved first
paint without removing the measured work. The production path now freezes both endpoints as tree
hashes (including copying the staged index to a private index before `write-tree`), cancels the
full-patch process group as soon as a roster of at least 100 paths wins, and requests exact hunks
only for up to 16 pending files intersecting the resting viewport. Literal pathspecs include both
sides of a rename. One serial hydration queue prevents process fan-out, bounds notifications
coalesce during wheel motion, and no returned model or height mutates the table until live scrolling
ends. Statistics and image endpoints use the same immutable tree pair, so two viewport batches can
never show two index versions.

The matched three-run Debug sweep on the same Linux checkout (94,854 visible paths, 970 range
files, 39,488 changed lines) measured the new production pieces separately:

| Linux range phase | Median | Cold/maximum | Presentation role |
|---|---:|---:|---|
| Raw path/change roster | 67.7 ms | 304.4 ms | first complete file index |
| First 16 exact file patches | 42.7 ms | 42.7 ms | first rich viewport |
| Exact all-file numstat | 399.1 ms | 782.6 ms | background totals and height weights |
| Complete unified patch command | 504.8 ms | 574.2 ms | old rich-body path |
| Complete unified patch parse | 104.4 ms | 121.1 ms | old all-file model cost |

Warm first exact viewport is therefore about **210 ms** including the 100 ms gate, rather than
about **609 ms** for complete patch plus parse (roughly 65% earlier). The processes still race on
a genuinely cold object cache: whichever result reaches main first wins, so the 304 ms cold raw
read does not delay a full patch that finishes sooner. Exact numstat starts only after the resting
viewport is rich and has stayed still for another 600 ms, uses its own lower-priority queue, and
cannot block viewing, hydration, scrolling or navigation summaries. The original broad
`--find-renames` made a direct matched probe take 2.61 s despite this range containing no renames,
versus 0.56 s with `--no-renames`. Production now uses the no-rename pass, then re-enables
similarity analysis only for rename endpoint paths already proven by the raw roster. The final
three-run app benchmark reduced the exact stats median from 712.5 ms to **399.1 ms** (44%) while a
real edited-rename integration test pins identical per-file counts. Unlike the discarded complete
path, the pass retains no hunk text and does no all-file Swift parse, but its remaining line walk is
still work proportional to total changed content.

Pending rows first use cheap header geometry, then the numstat roster establishes an expanded
offscreen line-weight estimate. Hydrating a row invalidates only that identity. Both transitions
preserve the first visible path and its within-row offset, or the actual maximum offset when the
reader is at bottom, and defer height notifications during momentum. Unknown counts remain
`loading…`; they are never represented as zero and staging is disabled until exact content exists.

The scaling rule this pins is broader than Git Review: when a trustworthy cheap index and an
expensive rich body have different cost curves, present the index after a short latency gate and
enrich retained identities in place. Do not make every small request pay the progressive path, and
do not represent unknown statistics as zero or enable actions against placeholder content.

Review Find keeps that split. Typing against an exact file phase scans its immutable models in a
cancellable detached task. Typing against a progressive roster earns one complete comparison read
through the existing 8 MiB guard, then searches that value off-main; it neither hydrates every
path nor creates any row. Navigation hydrates and materializes one selected identity. The index
includes at most the 400 presentable lines per file, uses the renderer's character cap, and bounds
its retained destinations at 10,000. Source generations discard stale reads and scans after a
checkout or mode change. Opening the bar with no query performs no repository-wide work.

Height discovery is split at that boundary. AppKit automatic row height initially retained roughly
twice the actual height for a 400-line body, creating blank content after the last glyph; and a
height query before the table became the scroll document saw width zero, making the offscreen wrap
estimate enormous. File rows now start from a width-aware model estimate using the pane/root width
that already exists, then cache exact TextKit height only for materialized rows. The 30-file
regression requires document extent to remain within 1% after materializing the last viewport and
again after a pane resize. Terminal scrolling uses `NSClipView.constrainBoundsRect`, so the 54pt
overlay inset is part of the true bottom rather than an unaccounted tail.

The relevant trace split is:

```text
git.review.load-and-render
├── git.read.diff
│   └── git.process
└── git.review.render
    └── git.review.render-files
```

- `git.process` dominant: inspect git arguments and repository workload.
- `git.read.diff` dominant beyond its child: inspect decoding/parsing and synthesized untracked
  files.
- `git.review.render-files` dominant while `instantiated_files` stays near the viewport:
  inspect model preparation or table reload.
- `git.review.render` reports both model rows and instantiated file rows. A large gap is the
  expected proof that virtualization is holding; similar values on a large index are a
  regression.
- `git.review.render` dominant outside row creation: inspect teardown, constraint resolution,
  scroll restoration, and layout.

Keep the workload and before/after artifacts with an optimization. Do not virtualize or cache on
intuition alone: the spans are intentionally arranged so a change can name the cost it removed
and reveal the cost it merely moved elsewhere.

## Provider wire parsing stress target

`ProviderWireParsingPerformanceTests` measures what one streamed provider chunk costs to read.
Every ACP agent message chunk, every Codex delta, every tool call and every tool result reaches
the app as one newline-delimited JSON line and is parsed on the main actor before anything is
drawn. It is the highest-frequency data path in the product and it had no stress target; the
numbers below are the first ones for it.

The fixture exists because a recommendation was resting on numbers nobody could re-run. When
`2536faf9` converted `ACPWireAdapter` to typed `JSONValue` reading, the figures quoted with it —
1.14 µs before and 5.86 µs after for a streamed chunk, 3.55 µs for today's whole line against
2.66 µs for `JSONDecoder` straight from the line — came from a standalone `swiftc` replica of the
code shapes, since deleted. The conclusion drawn from them, *convert at the transport rather than
at the leaf*, is a real architectural choice, so it needed a real measurement.

### The scaling contract

| Axis | Value |
|---|---|
| Cardinality | one JSON line: expected 130 B – 2 KB, stress 48–72 KB, bounded above only by what an agent sends |
| Frequency | one per streamed token for message deltas, several per tool call — frame-rate class |
| Must be | O(line bytes); never O(bytes × fields), and never proportional to conversation length |
| Owner | `JSONRPCLineEnvelope.parse` → `ACPWireAdapter` / `CodexAppServerEvent`, all on the main actor |

Parsing is on the main actor because the delta it produces is drawn immediately; at these sizes
moving it off would buy a hop rather than a saving. That makes the per-line cost a frame-budget
question — a 120 Hz frame is 8.3 ms — and it is why the two large payloads below matter more than
the per-token one.

### The fixture

Nine payloads, generated as **JSON text** and parsed: an ACP `agent_message_chunk`, an ACP
`tool_call` carrying tool-owned `rawInput`, an ACP `plan` of six entries, an ACP
`tool_call_update` whose `rawOutput` is a 48 KB string, an ACP `tool_call_update` whose
`rawOutput` is a 320-member structured object, and the Codex counterparts
(`item/agentMessage/delta`, `item/started`, `turn/plan/updated`, and a completed
`commandExecution` with 48 KB of aggregated output).

Text rather than Swift literals, for the reason `3277a3a0` records: a corpus written as literals
never runs `JSONSerialization` at all, so it cannot see an `NSNumber` read as a `Bool`. The tool
call here carries `offset: 0`, `limit: 1` and `replace_all: false` on purpose, and the fixture
asserts that the shipping reader answers `.integer(0)` / `.integer(1)` / `.bool(false)` where the
pre-`3277a3a0` reader in the same test answers `.bool(false)` / `.bool(true)` / `.bool(false)`.

Every arm is production code. `LegacyACPWireReader` in the test file is `ACPWireAdapter` as it
stood at `2536faf9^`, copied verbatim out of git history along with the `JSONValue` bridge as it
stood at `3277a3a0^`, so the before/after arm compares two readers that both shipped rather than
two sketches of them. `ACPStreamSession` is deliberately outside the measurement: driving it needs
a real child process on a real pipe, and run-loop latency would swamp a microsecond-scale reading.
What it adds over these numbers is the `sessionUpdate` string switch.

| Arm | What it is |
|---|---|
| `jsonobject` | `JSONSerialization.jsonObject(with:)` plus the cast to `[String: Any]` |
| `envelope` | `JSONRPCLineEnvelope.parse(_:)` — the shipped entry point, from the `String` the framer produces |
| `fields` | `ACPWireAdapter.fields(of:)` alone: the conversion `2536faf9` added at the leaf |
| `adapter-typed` / `adapter-legacy` | the shipped reader for that update kind, and the reader it replaced |
| `whole-line-typed` / `whole-line-legacy` | envelope plus reader, timed as one operation |
| `audit-event` | `ACPProviderExecutionAdapter.event(…)`, the execution ledger's own conversion |
| `codable-typed` | `JSONDecoder` from the line's `Data` into a discriminated `Decodable` model |
| `codable-jsonvalue` | `JSONDecoder` from the line's `Data` into `JSONValue` |
| `serialize-then-jsonvalue` | `JSONSerialization` then `JSONValue.object(from:)` — same destination as the arm above |

Defaults (300 iterations, 60 for the large payloads) run in the `fast` plan with generous shape
ceilings, so the path stays covered on an ordinary run. `THREADING_WIRE_STRESS=1` raises them to
20,000 / 2,000 and adds the sweep that produced the tables. Because a test plan sanitizes the
environment it launches with, the sweep runs through the bundle directly:

```bash
xcodebuild -project Threading.xcodeproj -scheme Threading -configuration Debug \
  -derivedDataPath <dd> build-for-testing
THREADING_WIRE_STRESS=1 \
  DYLD_LIBRARY_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/MacOS" \
  DYLD_FRAMEWORK_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/Frameworks" \
  xcrun xctest -XCTest ThreadingTests.ProviderWireParsingPerformanceTests \
    "<dd>/Build/Products/Debug/Threading.app/Contents/PlugIns/ThreadingTests.xctest"
```

A Release sweep needs one more setting than the Debug one: the bundle does
`@testable import Threading`, and a stock Release build has `ENABLE_TESTABILITY` off, so
`build-for-testing` fails with *unable to resolve Swift module dependency to a compatible module:
'Threading'* for every dependency at once. Pass `ENABLE_TESTABILITY=YES` on the `xcodebuild` line
and swap `Debug` for `Release` above. Note that `-enable-testing` inhibits some internal-linkage
optimisation, so a Release-plus-testability number is a slight over-estimate of what ships.

Fixture manufacture is timed separately (`fixture_ms`, 5.14 ms for all nine payloads) and is not
in any arm. The empty measured loop including its two clock reads (`timer_floor_us`) is 0.041 µs
or below — one 41.67 ns tick — so the sub-microsecond readings are at the clock's floor and
should be read as "under a tick", not as exact.

### Measured, 2026-08-28, Debug, Apple M1 Max (10 cores, 64 GB), macOS 26.5 / Xcode 26.5

`HEAD` was `d09fde33`, but this is a shared checkout and four of the five subject files carried
another session's uncommitted edits at the time
(`ACPWireAdapter.swift` `6b06044c1dc6`, `StreamEvent.swift` `898caf22d78b`,
`CodexAppServerEvent.swift` `1c5842a25283`, `ProviderExecutionAdapters.swift` `70452c923254`;
`JSONRPCLineEnvelope.swift` `f920b9c3fdac` was clean). N = 20,000 for the small payloads and
2,000 for the large ones. **Medians and p95; the maxima are not reported** because other build
jobs were running on the machine throughout and they reach hundreds of milliseconds, which is
scheduling noise rather than a property of the code. Debug matches every other baseline in this
document; a matched Release sweep was attempted and is still owed, because the shared checkout did
not compile during the window this was measured in.

**What one line costs today.** `whole-line-typed`, median (p95):

| Payload | Bytes | envelope | adapter | whole line | + audit |
|---|---:|---:|---:|---:|---:|
| `acp-text-chunk` | 253 | 5.00 µs | 6.46 µs | **12.67 µs** (13.54) | — |
| `acp-tool-call` | 580 | 7.54 µs | 40.25 µs | **50.38 µs** (54.29) | 16.33 µs |
| `acp-plan` | 585 | 7.63 µs | 39.13 µs | **48.46 µs** (51.79) | — |
| `acp-tool-result-large` | 64,016 | 163.38 µs | 19.21 µs | **182.08 µs** (192.67) | 16.58 µs |
| `acp-tool-result-structured` | 71,823 | 369.88 µs | 3.74 ms | **4.14 ms** (4.30) | 1.60 ms |
| `codex-text-delta` | 126 | 3.83 µs | 0.38 µs | **4.25 µs** (4.50) | — |
| `codex-item-started` | 185 | 4.33 µs | 2.42 µs | **7.08 µs** (7.50) | — |
| `codex-plan` | 399 | 6.04 µs | 7.21 µs | **13.79 µs** (15.46) | — |
| `codex-item-completed-large` | 59,125 | 151.21 µs | 3.04 µs | **156.04 µs** (190.88) | — |

A streamed token is cheap: 12.7 µs for ACP and 4.3 µs for Codex, about 0.15% and 0.05% of a
120 Hz frame. Serialization is linear with a fixed overhead — 13.8 ns/byte for the 253 B chunk
against 2.5 ns/byte for the 64 KB result — and the fixture asserts that ratio so a quadratic
parse fails rather than being noticed later.

The number that is not cheap is the last ACP row. **A structured tool result costs 4.14 ms to
read, plus 1.60 ms to record, on the main actor** — 69% of a 120 Hz frame for one line, and
15× the cost of the same payload's *bytes* through `JSONSerialization` (369.88 µs).

**Leaf against cast.** The reader only, on the identical parsed dictionary:

| Payload | pre-`2536faf9` | shipped | Reader | Whole line |
|---|---:|---:|---:|---:|
| `acp-text-chunk` | 0.92 µs | 6.46 µs | 7.0× | 6.67 → 12.67 µs (1.9×) |
| `acp-tool-call` | 10.96 µs | 40.25 µs | 3.7× | 20.46 → 50.38 µs (2.5×) |
| `acp-plan` | 8.08 µs | 39.13 µs | 4.8× | 16.83 → 48.46 µs (2.9×) |
| `acp-tool-result-large` | 0.50 µs | 19.21 µs | 38× | 164.92 → 182.08 µs (1.1×) |
| `acp-tool-result-structured` | 858.50 µs | 3.74 ms | 4.4× | 1.23 → 4.14 ms (3.4×) |

The reported 1.14 → 5.86 µs was **real and close**: measured through the shipped code the same
read is 0.92 → 6.46 µs. The mechanism is `fields(of:)`, which converts *every* member of an
update before any reader looks at one of them — a chunk whose only interesting member is
`content` still pays for `sessionUpdate` and `messageId`, and `fields` alone (6.04 µs) is 94% of
the typed read.

What the replica could not show is the denominator. A reader is a minority of a line: the text
chunk's whole line only doubled, and the 64 KB result barely moved because `JSONSerialization`
owns it. The one place the conversion dominates is the structured payload, where it triples the
line.

**Transport-level `Codable`.** Median, against today's whole line:

| Payload | today | `codable-typed` | `codable-jsonvalue` | `serialize-then-jsonvalue` |
|---|---:|---:|---:|---:|
| `acp-text-chunk` | 12.67 µs | **6.04 µs** | 118.88 µs | 17.46 µs |
| `acp-plan` | 48.46 µs | **12.33 µs** | 368.33 µs | 46.88 µs |
| `acp-tool-call` | 50.38 µs | 61.79 µs | 207.83 µs | 33.71 µs |
| `acp-tool-result-large` | 182.08 µs | **64.96 µs** | 282.29 µs | 185.75 µs |
| `acp-tool-result-structured` | 4.14 ms | 15.44 ms | 16.34 ms | **2.48 ms** |
| `codex-text-delta` | 4.25 µs | 3.46 µs | 59.58 µs | 9.00 µs |
| `codex-item-started` | 7.08 µs | 6.25 µs | 101.63 µs | 14.58 µs |
| `codex-plan` | 13.79 µs | 10.50 µs † | 261.67 µs | 36.17 µs |
| `codex-item-completed-large` | 156.04 µs | **47.75 µs** | 148.00 µs | 160.71 µs |

† That one cell comes from the baseline block of the same run rather than the stress block: the
runner spliced its own "Test Case … passed" line through the middle of a multi-line `print` and
took the row with it. The fixture now emits one `print` per row for that reason.

The claim splits, and the split is the useful part. Where a payload is typed all the way down —
a message chunk, a plan, a large string result — decoding it straight into a `Decodable` model is
**2–4× cheaper** than parsing to `[String: Any]` and reading it. Where a payload carries
**tool-owned JSON**, which has to land in `JSONValue` because its schema belongs to the tool, the
same route is *worse*: the tool call goes 50.38 → 61.79 µs and the structured result 4.14 →
15.44 ms. Tool calls and tool results are exactly the payloads this adapter exists for.

The replica's 2.66 against 3.55 µs was measured on the easy case and generalised. The direction
holds for a message chunk (here 6.04 against 12.67) and reverses for everything with a tool in it.

### `JSONValue`'s `Decodable` conformance is the expensive part, and it already ships

`codable-jsonvalue` is 7–10× *slower* than reaching the identical typed tree through
`JSONSerialization` and `JSONValue.object(from:)`: 118.88 against 17.46 µs for a 253 B line,
368.33 against 46.88 µs for a plan, 59.58 against 9.00 µs for a Codex delta. The cause is in
`JSONValue.init(from:)`, which asks `try? container.decode(Bool.self)`, then `Int64`, then
`Double`, then `String`, then `[JSONValue]` before falling through to the object — so every string
leaf throws and catches four `DecodingError`s, each capturing a coding path, and every object leaf
throws five.

This is not a property of the experiment. `ClaudeWireContentBlock` in `StreamEvent.swift` decodes
a tool call's `input` and `content` through exactly this initializer, `CodexStreamEvent`'s
`arguments(from:)` does it to a nested argument string, and `MCPServer` decodes a request's
`rawParameters` the same way. The Claude conversation path pays this on every tool call today.

Two cheap repairs, neither taken here because this task was a measurement: order the attempts by
what JSON actually contains (`String` first, containers last), which removes three throws from the
common leaf; or stop routing bulk provider JSON through `JSONDecoder` at all, since the
`JSONSerialization` route to the same value is already the faster one.

### Reading a structured tool result converts it three times

`fields` on the structured payload is 2.03 ms and `adapter-typed` is 3.74 ms, so the reader adds
1.7 ms on top of the conversion. It is not reading — it is converting back.
`ACPWireAdapter.toolResultText` takes its `.object` branch and calls
`JSONRPCLineEnvelope.encodedText(payload["rawOutput"]?.foundationValue)`, which turns the
`JSONValue` tree back into Foundation objects and re-serializes them pretty-printed and
sorted. The line is therefore parsed to Foundation, converted to `JSONValue`, converted back to
Foundation, and serialized again. The pre-`2536faf9` reader went from Foundation straight to text
and cost 858.50 µs for the whole read.

That round trip is deliberate — the comment on it says the rendered text must not change with the
representation — but it was chosen without a number beside it, and the number is 1.7 ms on the
main actor per structured tool result.

### The same payload is converted twice per tool call

`ACPToolCallState.init` converts the update through `fields(of:)`, and then
`ACPProviderExecutionAdapter.event` converts the *whole update again* through
`JSONValue(foundationValue:)` for the audit record. On an ordinary tool call that second pass is
16.33 µs against the read's 40.25 µs; on the structured result it is 1.60 ms, comparable to
`fields` itself. Both conversions produce the same tree from the same dictionary.

### What this means for transport against leaf

The recommendation is half right, and it points at the wrong lever.

- **Converting at the transport is worth doing, but not with `JSONDecoder`.** The measured
  cheapest way to get one typed tree from a line is `JSONSerialization` plus
  `JSONValue.object(from:)` — 17.46 µs for a chunk, 2.48 ms for the structured payload, against
  118.88 µs and 16.34 ms for the `Codable` route. A transport that converted once and handed
  `[String: JSONValue]` to both `ACPWireAdapter` and the audit adapter would delete the duplicate
  conversion above and every per-entry-point `fields(of:)` call, and the structured payload's
  whole line would fall from 4.14 ms toward the 2.48 ms the conversion itself costs.
- **A discriminated `Decodable` model is not a general answer.** It wins on payloads that are
  typed all the way down and loses on exactly the ones carrying tool-owned JSON, because those
  end up in `JSONValue` either way and `JSONValue` decodes badly.
- **The per-token path was never the problem.** 12.7 µs of a 8.3 ms frame does not justify
  restructuring a transport. The 4.14 ms structured tool result does, and none of the four
  numbers the original note reported would have found it, because none of its payloads were
  large.

Do not act on any of this by reordering the leaf back to `as?` casts. The typed reader is why an
unrecognised content-block kind, plan status or stop reason is a named `unknown` instead of a
`nil` three types away, and the boolean bug `3277a3a0` fixed was found by the corpus this fixture
inherits. The cost to remove is the *repetition* — three conversions of one payload — not the
conversion.

## Subagent transcript stress target

`ConversationRenderTests.testStressSubagentTranscriptWhenEnabled` sends either a generated
100-turn child conversation or one provider child transcript through `SubagentTimeline` and the
production `SubagentTranscriptViewController`. The ordinary generated case is part of `full`;
passing a child JSONL path reproduces a reported pane exactly. The result is one
`THREADING_PERF subagent-transcript` line in `subagent-stress.log`, split into transcript read,
model reduction, summary/presentation/reload phases, cold AppKit materialization, representative
viewport layout, per-row mount and scroll percentiles. The harness mounts the final 18 rows as a
cold viewport before it asks for every logical row one at a time; reversing that order would warm
the Markdown cache and understate first-paint work. Its `elapsed_ms` includes the later exhaustive
diagnostic and is therefore not production first paint. The fixture also asserts that one model
update rebuilds the child navigator once, styles no Markdown during presentation construction,
and grows the bounded cache by no more blocks than the viewport requested. The same command also
builds a 1,000-child, 12-activity-entry-per-child navigator and reports snapshot projection,
main-actor enqueue, utility-writer drain and reload separately as `subagent-persistence`.

The regression fixture was a 457 KB Claude child transcript with 91 replay events, 47 timeline
rows, 44 tool calls/results and one 13 KB final Markdown answer. The old retained stack eagerly
built all 49 presented rows, including hidden tool bodies: 1,286 descendants, 187 ms render,
494 ms layout, 202 ms scroll p95 and 29.9 MB renderer growth. The same Debug fixture after the
change measures 59 cheap presentation identities but only 18 materialized rows, 247 descendants,
13.0 ms render, 10.6 ms viewport materialization, 35.1 ms test-document layout, 10.6 ms row-mount
p95, 15.7 ms scroll p95 and 15.2 MB renderer growth. Its 384 ms exhaustive test elapsed is not a
384 ms first paint: render plus representative viewport mount/layout is about 59 ms, and AppKit
can spread cold height discovery across frames.

Phase instrumentation then found that the generated 600-row case spent 17.16 of 20.96 ms in
presentation construction, 3.51 ms rebuilding the child navigator and only 0.17 ms reloading the
table. Presentation identities were nevertheless parsing and styling every assistant Markdown
block, including blocks whose views AppKit had never requested; the navigator also rebuilt once
for content and again for selection. Presentation now retains structurally split source blocks,
styles a block only when its virtual row materializes, and keeps at most 64 styled blocks in an
identity-and-source-checked LRU that is cleared on selection or theme changes. The navigator takes
content and selection in one update. Fresh generated runs reduced synchronous render from
19.8–22.3 ms to 5.9–8.3 ms, with one navigator rebuild and zero styled blocks during render.

The persistence fixture found a separate quadratic pause outside the pane. Snapshot projection
canonicalized every child's parent id through `canonicalID(for:)`; a parent session is not itself
a child, so the fallback scanned the complete child array and missed once per row. Unique
transcript-path reconciliation repeated the same array materialization while children arrived.
Main-actor medians made the curve visible: 100 children projected in 10.116 ms, 250 in 63.717 ms,
and 1,000 in 760.721 ms. The 1,000-child atomic JSON write then added another 39.332 ms on the
main actor for a 10.8 MB bounded snapshot.

`SubagentTimeline` now maintains authoritative id/alias and transcript-path indexes. A negative
parent lookup and a path reconciliation are O(1), while ordered presentation remains the one
linear pass. Routine coalesced saves hand the immutable, `Sendable` snapshot to one utility writer;
renderer teardown queues its final state, explicit flush/quit drains earlier writes and persists
the newest state durably, and deletion is ordered after queued writes so stale work cannot recreate
a removed session. The writer retains atomic replacement, size rejection, quarantine blocking and
per-session files.

Three registered stress runs reduced the 1,000-child snapshot median to **1.386 ms**. Main-thread
enqueue was **0.346 ms** median; the remaining 45.638 ms encode/write ran on the utility queue.
The measured main pause therefore fell from about **800.053 to 1.732 ms** (99.8%, roughly 462×).
The fixture also reloads the finished file; all 18 focused state regressions pass, covering
alias/path reconciliation, ordered latest-write wins, durable flush, quarantine, and
delete-after-save.

The exact provider fixture exposed one more, independent cost. Its final settings inventory is a
large two-column Markdown table; the general renderer represented every row as a horizontal stack,
every cell as a wrapper, and every value with a constraint graph. The virtual transcript's settled-
width path now uses `ThemedDocumentTableView`: selectable cell labels are measured once and placed
directly, while the design component draws the themed header and separators, forwards vertical
wheel momentum to the transcript and reflows when the pane width changes. The general Markdown
path uses the same direct-layout table with a readable bootstrap width, then reflows to its actual
width; both paths page rows and columns before constructing cells.

The Release startup build then exposed a compiler-sensitive allocation pattern in that component:
Swift 6.3.2's ownership optimizer aborted in `ThemedDocumentTableCanvas.init` while optimizing the
nested `map`/key-path pass that cloned and padded the complete attributed-string matrix before
`super.init`. Grid preparation now uses a direct widest-row pass and constructs each final cell
once, including an empty field only where a ragged row actually needs it. The arm64 Release build
completes, and focused reflow plus ragged-row tests preserve width changes, rectangular geometry
and per-column alignment.

Three fresh exact-replay processes after both changes measured:

| Metric | Lazy source blocks, old table | Current |
|---|---:|---:|
| Live descendants | 247 | 171 |
| Synchronous render | 5.3–5.7 ms | 5.37–5.84 ms |
| Initial AppKit layout | 52.5–52.7 ms | 42.51–45.35 ms |
| Initial paint | 58.0–58.2 ms | 48.08–51.19 ms |
| Representative viewport layout | 29.3–29.5 ms | 15.98–17.08 ms |
| Row mount p95 | 9.7–12.0 ms | 6.54–7.16 ms |
| Scroll p95 | 9.2–10.1 ms | 5.48–6.33 ms |
| Renderer delta | 13.5–13.8 MB | 9.8–10.0 MB |

The remaining 42–45 ms cold layout is AppKit materializing and measuring the initial text viewport;
steady scrolling is below an 8.3 ms 120 Hz frame. Do not trade that first layout for retained
off-screen views or guessed row heights: both would weaken the working-set and exact-navigation
boundaries elsewhere in this document.

The exact fixture also spends about 49 ms reducing provider events into tool summaries, edit
previews and conversation rows. That reduction is pure model work and now runs on a
user-initiated worker; the main actor installs its finished `ConversationTimeline` with one
assignment and one notification. `model_ms` is therefore worker wall time and the stress line
states `model_thread=worker`. A per-child generation rejects an older reduction if a growing
provider file triggers a newer replacement before it finishes.

The load-bearing boundary is two levels of virtualization. The selected transcript is an
`NSTableView`, collapsed tool runs do not construct their individual rows, and a long assistant
answer is split at structural source-block boundaries without styling it. Only a materialized
paragraph or table is parsed and drawn, and the cache remains bounded. A width-known document
table is a directly placed grid, not nested stacks. Disclosure state belongs to the controller
and rows are inserted or removed from the cheap presentation model. Do not replace this with
hidden stack children: hidden AppKit views still participate in the layout engine.

## Shared transcript table

The main conversation and the Subagents pane now present rows through one
`ConversationTranscriptTable` (see [`native-conversations.md`](native-conversations.md)). The
extraction was measured rather than assumed flat, because it moved the incremental tool-run
reduction, the identity index and the row hosts out of two controllers into one generic type.
Three passes each of the generated fixtures, Debug, same machine and build, HEAD's files rebuilt
in the same DerivedData for the *before* column; medians:

| Case | Before | After |
|---|---|---|
| 1,000-turn mixed replay, 6,000 rows / 4,999 presented: render | 1,450 ms | 1,215 ms |
| Same replay: materialized rows / descendants / renderer growth | 6 / 307 / 64 MB | 6 / 307 / 64 MB |
| Deep jump · incremental append · result + fold · 250 stream updates | 38.2 · 5.3 · 34.0 · 6.1 ms | 41.1 · 5.2 · 30.8 · 6.4 ms |
| Active turn, 100 base turns + 100 tools: append p95 · middle jump · settle | 3.5 · 42.3 · 24.6 ms | 3.7 · 45.6 · 29.4 ms |
| Same: materialized / collapsed / expanded presented | 23 / 502 / 602 | 23 / 502 / 602 |
| Child transcript, 100 generated turns, 801 presented: render · initial paint · row mount p95 | 8.2 · 30.2 · 0.82 ms | 9.3 · 30.4 · 0.86 ms |
| Same: materialized / descendants / renderer growth | 18 / 69 / 8.4 MB | 18 / 69 / 8.0 MB |

The first cut was not flat, and only the matched run said so: `foldTurn` rebuilt the whole
ordering for every settled turn, so the 1,000-turn replay went from 1,450 ms to 5,023 ms while
every bounded-working-set assertion still passed. Folding now removes the turn's few entries in
place and inserts one fold, and the table's identity lookups fall back to a scan from the tail —
a settling turn is recent, and during replay the index is deliberately empty — which is also why
replay ended up faster than before. The remaining differences are within the run-to-run spread of
three Debug passes. Child render gained about a millisecond on 800 items because the rebuilt
presentation now goes through the same per-row append as the live parent; that is the price of
live and rebuilt rows taking one shape, and it sits well inside the bound above.

## Native conversation stress target

`ConversationRenderTests.testStressNativeConversationWhenEnabled` generates prose, mixed and
tool-heavy transcripts locally and sends them through `ConversationTimeline` plus the production
`ConversationViewController` row path. The routine edge is 400 events: that is 600 native rows
for the mixed shape and 1,100 for the tool-heavy shape, because one assistant event can carry many
content blocks. `conversation-massive-stress` adds 250, 500 and 1,000 mixed turns plus 1,000-turn
prose and tool-heavy extremes; `full+` includes that tier. Both tiers also measure a jump to the
deepest turn, an incremental tool-rich append, result attachment plus folding, and 250 cumulative
streaming updates.

The command runs each shape and size in a fresh `xctest` process. AppKit layout state and retained
controllers otherwise make later cases measure the preceding workloads as well as their own;
that accumulation is worth a separate multi-pane test, but it is not a stable scaling baseline.
Each result is a `THREADING_PERF conversation-*` line in `conversation-stress.log` or the massive
tier's `conversation-massive-stress.log`.

The first sample put the main thread in `NSView.layoutSubtreeIfNeeded` and CoreAutoLayout while
attaching the accumulated native tree. Replay batching and folded-work deferral removed the first
large tranche, but the remaining user/fold/final-answer rows still formed one `NSStackView`
constraint chain. Hiding or detaching intermediate rows could not bound that live chain.

`conversation.replay.render` brackets the production transcript-to-native-view pass. It records
only aggregate event, model-row, materialized-row, presentation-row and folded-turn counts, so
traces and Points of Interest captures can correlate the same semantic interval with AppKit
stacks without recording conversation content.

- replay rebuilds the minimap, conversation controls, and remote snapshot once at its boundary,
  rather than once for every prefix of the transcript;
- the presentation is a view-based table. The full timeline and stable presentation identities
  remain resident, while Markdown/tool views exist only in reusable hosts around the viewport;
- replay mutates the timeline and presentation model, then reloads the table once. Fold expansion
  inserts identities and collapse removes them; neither path retains an off-screen constraint tree;
- AppKit owns automatic row-height estimation/caching; the controller invalidates affected rows
  and uses one readable-width scalar to invalidate all of AppKit's heights when wrapping changes.
  It retains no per-identity height mirror. Tool, user-message and turn disclosure state is held
  outside recyclable views. Exact jumps therefore do not require a target view to exist and
  correct after the landing.

On the 100-turn mixed Debug case, 600 model rows become 399 presentation rows but only eight live
row views and 179 descendants. Model reduction measured 31 ms, presentation/reload 938 ms and final
layout 108 ms, for 1.05 s total versus roughly 3.2 s before the replay and row-lifetime work. The
same run measured a deepest-turn jump at 264 ms, an 11-row live append at 38 ms, result attachment
plus folding at 138 ms, and 250 streaming deltas at 86 ms. Cold automatic height discovery and an
uncached far jump are now the remaining conversation limits; they are separate from session-switch
layout and must not be "fixed" by retaining the full row tree again.

The first 1,000-turn mixed probe found a different model-side cliff after virtualization had
bounded AppKit: presentation construction took 1.30 s while model reduction took 38 ms, and 250
streaming updates took 204 ms. Every replayed tool result searched the growing presentation array
for a table row that cannot exist until replay's final reload. Every streaming delta repeated the
same search even though the placeholder is the tail row. Replay height invalidation now stops after
the replay guard without maintaining a diagnostic cache, timeline rows use the existing identity
index, and streaming uses the tail directly.

A fresh-process Debug massive sweep after removing those scans measured:

| Shape | Turns | Timeline rows | Cold replay | Deepest-turn jump | Live append | 250 deltas | Live rows | Renderer delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Mixed | 250 | 1,500 | 67 ms | 19 ms | 20 ms | 4.6 ms | 8 | 2.4 MB |
| Mixed | 500 | 3,000 | 120 ms | 26 ms | 39 ms | 4.9 ms | 8 | 2.7 MB |
| Mixed | 1,000 | 6,000 | 215 ms | 35 ms | 75 ms | 4.8 ms | 8 | 4.1 MB |
| Prose | 1,000 | 2,000 | 391 ms | 38 ms | 184 ms | 5.0 ms | 10 | 5.2 MB |
| Tool-heavy | 1,000 | 11,000 | 292 ms | 35 ms | 76 ms | 4.6 ms | 8 | 4.6 MB |

The 1,000-turn split makes the next owner explicit: model / presentation / minimap was
41 / 126 / 69 ms mixed, 2 / 191 / 174 ms prose, and 95 / 197 / 74 ms tool-heavy. Prose is slowest
despite carrying the fewest timeline rows because `ConversationTimeline.turns` recompacts every
user and final-assistant preview when the rail is rebuilt. The same full rebuild happens when one
live user turn is appended, which is why that operation reaches 184 ms.

That next step is now implemented without adding a second mutable turn model. The timeline records
stable user-row identities and compacts immutable user/assistant preview strings once when their
source arrives; turn extent, conclusion choice and duration remain derived from canonical rows.
Replay replaces the complete rail once. Live traffic updates the settling tail mark, then updates
that prior preview and appends one mark when the next user turn begins. It neither rebuilds the
historical turn array nor clears an active hover merely because the conversation advanced.

Fresh-process 1,000-turn checks after that change measured:

| Shape | Cold replay before → after | Minimap before → after | Live append before → after | Result + fold | Deep jump |
|---|---:|---:|---:|---:|---:|
| Mixed | 215 → 153 ms | 69 → 2.5 ms | 75 → 5.3 ms | 34 ms | 33 ms |
| Prose | 391 → 211 ms | 174 → 1.8 ms | 184 → 4.6 ms | 32 ms | 36 ms |
| Tool-heavy | 292 → 216 ms | 74 → 3.3 ms | 76 → 5.3 ms | 32 ms | 36 ms |

The separate `model_ms` diagnostic rises because the model-only mirror now pays the one-time
preview compaction when each message enters it; that work used to be hidden in every later minimap
rebuild. Production cold cost is `elapsed_ms`, which measures the controller's reduction, reload,
rail and layout together and fell for every shape. Renderer footprint stayed effectively flat at
4.2–5.4 MB, and the live answer now appears in the current mark as soon as its turn settles rather
than waiting for the next question to trigger a full refresh.

The gated massive cases assert more than timing: the exact final turn must be visible and
materialized after its jump, and fewer than 40 native row views may remain live. Renderer delta is
measured after the generated events and the separate model-only mirror exist, so it isolates the
production controller's additional timeline, presentation and viewport state rather than charging
the fixture to the renderer.

### Active-turn edge

Settled-history replay does not cover the renderer's other extreme: a single current turn whose
canonical tool rows must remain addressable until the terminal event arrives. Consecutive calls
now share one collapsed presentation row by default; exact navigation expands that group before
landing on the requested call, so compact presentation does not discard identity.
`ConversationRenderTests.testStressActiveConversationTurnWhenEnabled` starts after a mixed settled
history, appends 25, 100 or 500 tool calls in ten-row batches, streams 250 text deltas, attaches
every result in reverse identity order, then settles and folds the turn. It verifies an exact jump
to a middle tool while the turn is live, an exact jump to the final answer after folding, correct
result identity, minimap settlement, and a working set below 40 native row views. The default sweep
also combines 1,000 settled turns with 500 live tools to expose any transcript-depth dependency.

Before live grouping, three fresh-process 100-turn runs and the combined depth edge measured:

| Settled turns | Live tools | Append batch p95 | Result batch p95 | Settle + fold | Middle jump | Peak delta | Live row views |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 25 | 2.4–2.5 ms | 2.7–2.9 ms | 16–18 ms | 39–42 ms | 9.3 MB | 20 |
| 100 | 100 | 2.4–3.0 ms | 2.7–3.1 ms | 16–31 ms | 41–46 ms | 12.1–12.4 MB | 21 |
| 100 | 500 | 2.3–2.9 ms | 2.2–2.9 ms | 17–19 ms | 41–46 ms | 34.0–34.3 MB | 21 |
| 1,000 | 500 | 2.9 ms | 2.5 ms | 33 ms | 61 ms | 33.9 MB | 21 |

The grouping change was then rerun in a fresh `xctest` process at 100 settled turns plus 100 live
tools. Before exact navigation, the active turn added three presentation entries — divider, user
message and one tool disclosure — while preserving all 100 canonical calls. Expanding on the
middle-tool jump measured 5.7 ms append-batch p95, 8.0 ms result-batch p95, 28.9 ms settlement,
60.5 ms exact jump, a 10.3 MB active delta and 23 live row views. The gate therefore covers both
the compact default and the addressable expanded state.

The isolated 100-tool result and settle maxima were not repeatable; later fresh processes returned
to the same 2–3 ms batch and 16–18 ms settlement band. Per-batch work is effectively independent
of both live-tool count and settled-history depth. Memory still grows with canonical rows, as it
must if a live tool remains addressable, but AppKit stays viewport-sized.

Cold exact navigation was split into initial geometry, destination layout, correction and visible-
turn bookkeeping. At the 1,000 + 500 edge, geometry was 0.02 ms, correction 0.63 ms and the minimap
0.51 ms; destination layout owned 53 of the measured 55 ms. Three costs were investigated:

- a collapsed tool used to construct its hidden result label or `DiffView`; the body now appears
  on first expansion and remains only for that materialized row;
- an empty extension resolution wrapped every ordinary row in a component container, host and
  observer which rendered the native subtree unchanged. Empty rows now remain native, one
  controller observer handles later wrapper transitions, and rare retained permission cards keep
  their in-place wrapper;
- every newly laid-out host checked that its presentation identity still existed with a linear
  scan. A cold viewport therefore paid roughly 21 × 4,500 identity comparisons at the combined
  edge. The intermediate fix validated a captured table row directly; the final fix removed the
  diagnostic measured-height mirror and its layout callback entirely, since AppKit is the only
  height-cache owner.

The last change removed the history cliff. Repeated fresh processes plus the final clean sweep
measured:

| Settled turns | Live tools | Middle jump before | Middle jump after | Destination layout after | Peak delta | Live row views |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 500 | 41–46 ms | 29–38 ms (31 ms median) | 26–34 ms | 32.3–32.4 MB | 21 |
| 1,000 | 500 | 61 ms | 33–43 ms (37 ms median) | 29–38 ms | 32.3–32.5 MB | 21 |

A row-host reuse experiment was reverted because AppKit requests the destination before releasing
the source viewport, so no shell is available at the cold handoff. A per-row exact-height estimate
was also reverted: AppKit queried it broadly, jump time stayed flat, append work increased and
footprint rose by roughly 12 MB. The remaining 26–38 ms is the intended construction and Auto
Layout of about 21 visible collapsed headers, not work proportional to transcript depth. Reducing
that further would require a materially different drawn/reconfigurable header, not another height
cache or an off-screen view tree.

The command writes `THREADING_PERF conversation-active-*` lines to
`conversation-active-turn-stress.log`. Override either dimension for a one-point investigation
with `THREADING_CONVERSATION_ACTIVE_BASE_TURNS` and `THREADING_CONVERSATION_ACTIVE_TOOLS`.

## Multi-conversation residency stress target

`ConversationRenderTests.testStressConversationResidencyWhenEnabled` keeps multiple production
`ConversationViewController`s alive at once, matching `AgentRuntime`, and repeatedly reparents
them through one host the way a sidebar selection does. It measures controller construction, hot
switch p50/p95/max, detach/reparent/theme/layout phases, a deep turn jump, off-screen tool-rich
updates, the first return after those updates, and the process's physical footprint. The workload
uses fresh `xctest` processes per scale point so allocator high-water marks do not leak from one
case into the next. It is in `full+`, not the routine sweep: the 8 × 100-turn cases deliberately
reduce thousands of real timeline rows and retain all presentation identities while asserting that
the attached AppKit working set stays viewport-sized.

The first Debug sweep measured two different cliffs:

| Retained conversations | Turns each | Shape | Switch p95 | Retained footprint delta |
|---:|---:|---|---:|---:|
| 2 | 50 | mixed | 165 ms | 77 MB |
| 4 | 50 | mixed | 114 ms | 130 MB |
| 8 | 50 | mixed | 106 ms | 232 MB |
| 8 | 100 | mixed | 427 ms | 433 MB |
| 8 | 100 | tool-heavy | 400 ms | 422 MB |

Session count controls total memory; the selected conversation's materialized depth controls
switch latency. Tool-heavy had 8,856 model rows versus mixed's 4,856, but both had 1,656
materialized row views across the eight controllers and nearly identical switch cost. Folded
model-only tool rows therefore are not the hot path; the remaining live view hierarchy is.

The first measured fix preserves the detached-theme rule without paying it on every switch.
`AppThemeRefresh` now advances a generation for each whole-app sweep and stamps every view it
reaches. A retained conversation calls `repaintIfNeeded` on attach: a tree detached during a real
theme, accessibility, or font sweep is stale and gets the full repair; an ordinary remove/add
cycle is already current and returns in O(1). At 8 mixed conversations × 100 turns, switch p95
fell from 427 ms to 346 ms. The phase split then measured repaint at 0.007 ms and layout at
336 ms, identifying Auto Layout after reparenting as the remaining latency owner.

Keeping all conversation trees attached but hidden was measured and rejected: the 8 × 100 case
exceeded the practical memory/runtime envelope and the test process was killed. Hidden AppKit
trees are still resident layout state.

The view-based table implements the required reusable row lifetime. A post-change Debug sweep:

| Retained conversations | Turns each | Shape | Live row views | Switch p95 | Layout p95 | Footprint delta |
|---:|---:|---|---:|---:|---:|---:|
| 2 | 50 | mixed | 16 | 7.7 ms | 7.0 ms | 19.7 MB |
| 4 | 50 | mixed | 32 | 12.0 ms | 11.3 ms | 31.8 MB |
| 8 | 50 | mixed | 64 | 8.1 ms | 7.2 ms | 55.3 MB |
| 8 | 100 | mixed | 64 | 20.4 ms | 17.4 ms | 57.1 MB |
| 8 | 100 | tool-heavy | 64 | 13.9 ms | 12.9 ms | 56.6 MB |

The direct 8 × 100 mixed comparison is the architectural result: the generation cache first moved
switch p95 from 427 ms to 346 ms and exposed 336 ms of layout; virtualization then moved switch p95
to 20.4 ms and layout p95 to 17.4 ms. Retained footprint fell from roughly 433 MB to 57 MB. The
tool-heavy case has 8,856 model rows versus mixed's 4,856, yet both retain exactly 64 live row views;
model depth no longer determines the window's constraint-graph size.

## Agent work atlas scaling contract

The Activity pane must handle large repositories without making display cost proportional to
repository size or the number of agents watching a project. The reference stress shape is 100,000
repository files, 64 agents and 64,000 observed file touches; the ordinary design point is about
5,000 files, four agents and 1,000 touches.

One immutable `RepositoryFileAtlas` is built asynchronously per checkout and shared by every
agent and the project aggregate. It sorts the repository once and projects it into 192 compact
bins or 512 detailed bins plus a permanent new-file bin. Session traces stay sparse — untouched
files occupy no per-agent storage — while the project trace is maintained incrementally. A live
file event changes one session entry, one project entry and at most the already-materialized
session/project bins. It never scans the checkout or the other agents. Removing a session's file
state visits only that session's paths and, when a last timestamp must be repaired, contributors to
those paths; its action ribbon re-merges at most the retained 96 actions per remaining session.

Repository enumeration, trace mutation, first projection, persistence load/save and transcript
replay reduction run off the main thread. The utility worker is the sole owner of mutable traces;
it hands the main actor only a bounded file/action delta or a completed bounded projection, so a
projection in flight cannot trigger a Swift copy-on-write clone on the next live event.
Presentation caches are capped at 256 targets, atlas caches at 32 roots,
recent actions at 96 per session/project and call-ID deduplication at 4,096 IDs per session.
Persistence trails the last event by one second so a streaming tool call cannot turn into a disk
write per delta. The Activity filesystem adds one sparse directory index per session and one for
the project aggregate. A live file event updates only that file's ancestors; opening or scrolling
the pane asks the worker for exact totals for visible rows, caches at most 256 paths, and never
walks a closed directory or all expanded rows.

Persistence is sharded by session as well as coalesced by session. A mutation writes
`<project>.sessions/<session>.json`; it does not encode or replace every other conversation in the
project. Legacy whole-project documents are migrated write-then-delete, one shard at a time, and
remain only when a shard write fails so an interrupted migration is recoverable. Therefore write
bytes for one live agent scale with that agent's sparse trace, not with the project-wide session
count. Removing a session deletes its shard, and removing a project deletes both legacy and shard
forms.

**The git-observed floor is bounded the same way, at the checkpoint rather than at the call.** A
turn's changed paths arrive as one enqueue carrying a path list, and each path is then applied
through exactly the incremental primitive a live event uses: one session entry, one project entry,
its ancestor directories, and one bounded projection rebuild for the whole turn. Reading the paths
is one `git diff --name-only` per checkpoint on a serial `.utility` queue, at most
`AgentWorkHydration.Defaults.checkpointsPerPass` (8) per pass; a turn whose before and end trees
are identical costs no process at all, which is most turns. `observedCheckpointOrdinal` persists
the resume point, so a repeated trigger stops at an integer comparison on the worker queue.
`AgentWorkHydrationTests.testALargeTurnFoldsInOffMainAndCostsTheCallerOneEnqueue` is the opt-in
shape: 4,000 changed paths in one checkpoint, asserting the caller's share stays under 20 ms and
that twenty further triggers cost the same nothing a resumed transcript pass does.

**The Activity card resolves its source on every refresh**, which is once per tool call during a
live turn, so `AgentWorkSource.resolve(sessionID:)` is three in-memory lookups and no allocation:
`GitTurnBaselineStore.hasCheckpoints(forSessionID:)` exists precisely so that question does not
sort a copy of every retained checkpoint to answer what the first match settles.

`scripts/profile_threading.sh agent-work-stress` runs the opt-in production-model benchmark. Keep
the `THREADING_PERF agent-work` line with release evidence; specifically watch atlas construction,
64,000 sparse mutations, aggregate and directory-index construction, detailed project projection,
and the 100,000-event bounded live update loop. A new surface must not increase the 192/512 bin
limits to follow input size or put repository enumeration back on row configuration.

A Debug execution on 2026-08-08 after adding the Activity tree measured 365 ms for the off-main
100,000-file atlas, 98 ms for 64,000 sparse session mutations, 96 ms for the complete 64-agent
aggregate, 986 ms for all session/project directory indexes, 58 ms for the detailed project
projection, and 1,095 ms for 100,000 bounded live updates (about 10.95 µs per event). The live
loop performs the same session entry, project entry, ancestor-directory updates, and bin update as
the live path. It does not include notification delivery or drawing.

## Agent chart stress target

Agent-authored charts have a different pipeline from the Usage dashboard even though both finish
in `ThemedTimeSeriesChartView`: JSON becomes `ChartSpec`, validation enforces the semantic contract,
the spec maps to categorical prepared geometry, and a `ChartCardView` is mounted in a display pane.
`UsageDashboardPerformanceTests.testStressAgentChartPipelineWhenEnabled` keeps those phases together
without hiding one behind a time-series-only fixture. It uses the largest valid product contract:
eight series × thirty categories = `ChartSpec.Limits.maximumMarks` (240), not the independently
valid but product-invalid eight × sixty axes.

Each fresh process decodes, validates and maps the 7 KB spec 250 times, mounts one cold pane, applies
250 stable-shape updates to the retained card, then synchronously renders sixty animation samples.
The five default workloads are grouped bars, stacked bars, ranking, line and area. Set
`THREADING_CHART_STRESS_KIND`, `..._STACKED`, `..._CATEGORIES` or `..._SERIES` for a focused point;
the fixture clamps overrides to the mark product cap rather than benchmarking an input validation
failure.

A current-source Debug sweep on 2026-08-09 originally measured:

| Shape | Decode + model, 250× | Cold pane | Updates, 250× | Draw, 60 frames | Draw / frame | Footprint delta |
|---|---:|---:|---:|---:|---:|---:|
| Grouped bar | 88.0 ms | 44.8 ms | 90.8 ms | 300.9 ms | 5.02 ms | 12.8 MB |
| Stacked bar | 91.0 ms | 42.3 ms | 82.2 ms | 145.6 ms | 2.43 ms | 12.6 MB |
| Ranking | 89.0 ms | 47.2 ms | 83.4 ms | 247.0 ms | 4.12 ms | 12.8 MB |
| Line | 90.0 ms | 43.7 ms | 108.4 ms | 243.6 ms | 4.06 ms | 12.8 MB |
| Area | 94.4 ms | 43.4 ms | 100.7 ms | 327.3 ms | 5.45 ms | 12.7 MB |

Decode/model and stable updates stay below roughly 0.45 ms per spec, and synchronous drawing stays
below 5.5 ms per sampled frame at the product cap. The card has six live descendants, not one view
per mark: the renderer owns bounded prepared geometry. `cacheDisplay` is a deliberately synchronous
paint stress and must not be presented as compositor frame timing.

The apparent 42–47 ms cold-pane owner was a measurement error. The fixture started its clock before
creating the first `NSWindow` in a fresh XCTest process even though production installs a chart in
an existing display-pane host. On 2026-08-11 that mixed aggregate rose to 84–98 ms across every
shape, but a phase split attributed 74–94 ms to process-wide AppKit window initialization and only
8–10 ms to the chart. Optimizing geometry against that aggregate would have been placebo.

The fixture now creates and reports its offscreen host before starting the product clock. Five
fresh XCTest processes against the same isolated Debug product measured:

| Shape | Decode + model, 250× | Host window diagnostic | Cold pane | Updates, 250× | Draw / frame | Footprint delta |
|---|---:|---:|---:|---:|---:|---:|
| Grouped bar | 65.9 ms | 73.7 ms | **9.7 ms** | 65.5 ms | 4.33 ms | 12.8 MB |
| Stacked bar | 69.2 ms | 87.5 ms | **10.1 ms** | 76.8 ms | 2.73 ms | 13.0 MB |
| Ranking | 65.3 ms | 85.1 ms | **10.3 ms** | 66.0 ms | 3.59 ms | 12.8 MB |
| Line | 73.7 ms | 80.3 ms | **7.7 ms** | 73.5 ms | 3.18 ms | 12.8 MB |
| Area | 73.9 ms | 84.8 ms | **10.0 ms** | 73.0 ms | 4.66 ms | 12.8 MB |

The product clock splits further into 0.16–0.19 ms controller initialization, 6.56–8.90 ms view
load/attachment including categorical geometry, and 0.97–1.24 ms first layout. The complete chart
mount is inside one 60 Hz frame at the largest valid contract, so there is no current chart-open
bottleneck to repair. Keep `host_window_ms` as a harness-health diagnostic, but never add it to
`cold_pane_ms` again.

## Terminal-title update stress target

Terminal title reports (OSC 0/2) are provider-controlled and can arrive many times per second from
every live TUI session. The expected case is an occasional real title change; the stress case is
10,000 identical reports. Processing must remain O(1) per report, and identical reports must cause
zero delegate notifications after the first because a notification reaches persistence, the
sidebar row, the session title control, and toolbar-state rendering on the main actor.

A 2026-09-02 sample of the running app attributed 654 of 3,611 busy main-thread samples to this
fan-out. Of those, 395 reached `SessionRowView.configure`; 259 entered agent-icon presentation and
asset rendition lookup. `TerminalSession.setTerminalTitle` had notified for every report without
checking whether the title changed.

`TerminalNamingTests.testRepeatedTerminalTitleReportsNotifyOnlyOnce` now drives 10,000 reports
through the production callback and requires exactly one delegate notification. The adjacent
changed-title test keeps real transitions ordered and lossless. `TerminalSession` still refreshes
the reported title's foreground-process owner on every report—even an identical one—because title
retirement depends on the most recent claimant; only the expensive presentation notification is
deduplicated.

## Archive mutation is an exact row write

A 2026-09-02 live incident contained 686 retained sessions, 630 of them archived. Ten quick archive
requests coincided with main-thread stalls from 1.97 to 7.66 seconds; the longest interval contained
four provider completions roughly 1.9 seconds apart. Trace phases ruled out the visible tree: sidebar
reloads took 9–12 ms, tree construction stayed below 1 ms, and applying a project structure stayed
below 1 ms. The uninstrumented interval began at the archive completion's store mutation.

Both `ProjectStore.setArchived` and `synchronizeArchiveStates` still called the legacy `save()`.
That path encoded and upserted every project and all 686 session payloads inside a synchronous
transaction on `ProjectStore`'s main actor. A provider command already ran off-main; returning from
it made each successful completion pay O(all retained sessions) before the next main-actor callback
could return. Several completions therefore serialized into the multi-second hang.

Archive now uses the standing-session write seam. A click encodes/upserts one session;
reconciliation collects only sessions whose observed value changed and commits them in one SQLite
transaction. The rollback snapshot advances per accepted row, and an injected pre-commit failure
proves a batch publishes none of its values. A future-format sentinel in an untouched neighbouring
row proves neither the database primitive nor the shipping store path rewrites it. A single archive
event carries its session and project identities: the sidebar rebuilds only that project while
search, extension and curfew consumers update only the named session. `CheckoutBranchFollower`
ignores all non-project-list impacts instead of acquiring an unrelated O(projects) reconciliation
on every row mutation. `persistence.sessions.save` records `changed_rows` for trace attribution,
while the project-sidebar stress fixture times archive, restore, subtree application and layout
independently.

The final 20-project × 250-session deterministic run retained all 5,000 sessions and completed in
1.81 seconds total. The single-row archive mutation took 8.75 ms, its targeted subtree application
accounting for 2.97 ms inside that synchronous call; the following layout took 0.90 ms. Restore took
7.51 ms including 3.79 ms of subtree work, then 0.88 ms of layout. The fixture's deliberately
retained whole-graph comparison took 246 ms in the same process. That ratio is the regression signal:
archive work follows the changed row and its 250-row project, not the 5,000-row retained catalog.

### Rename commits do not drain unrelated work

The same audit found a separate Enter-key hitch. Session and project renames had already moved to
exact row writes, but both helpers first called `flushPendingRecordSaves()`. One press could
therefore synchronously commit every unrelated title, process, location and agent-metadata update
waiting in the 500 ms coalescing window. The sidebar then performed its own unconditional full
reload after the store's synchronous targeted notification had already applied the rename.

An immediate standing-row write now subtracts only its own pending identity and leaves every other
row on the timer. When that timer fires, all dirty project and session rows share one SQLite
transaction rather than taking one commit per identity. Project renames publish a project-row
impact, session renames publish a title impact carrying whether Name order can move them, and the
rename completion does not reload the complete outline a second time. The regression test queues
an automatic title for one session, replaces its durable payload with a future-format sentinel,
presses the exact rename path on a neighbour, and proves the sentinel is untouched while the
renamed row is already durable.

The event fan-out is part of the Enter-key boundary too. Navigation and transcript search used to
re-project every retained project/session synchronously on the main actor before handing their
finished values to background indexers. The navigation store now changes one keyed record and the
transcript store one keyed source for a session title/archive edge; flattening their copy-on-write
snapshots stays with the detached indexing work. Project-name overlays are likewise applied by the
workers. The extension host journal and host-fact publisher refresh one named project/session, the
extension navigator receives a one-session delta, title-only events do not remeasure aggregate
agent workload, and the curfew engine does not re-evaluate unrelated sessions. Adding a new
`ProjectsDidChange` consumer therefore requires routing every exact impact explicitly; observing
the event as an undifferentiated request for a whole-catalogue refresh puts this stall back.
The final 5,000-session fixture measured the production exact title event at 6.22 ms.

### The archive event still reached the extension host as a whole-catalogue refresh

A 2026-09-03 archive on the 38f613284 build, with 708 retained sessions across 18 projects,
stalled the main thread for 1.63 s after the exact-row write above had completed in 0.3 ms and
the sidebar's subtree application in 0.5 ms. The archive publishes `.projectStructure(project)`,
and `ExtensionHostService.refreshSnapshotJournal(for:)` routed that case beside `.structure`: one
archived row re-snapshotted every retained conversation and re-read four git files for every
checkout on the main actor. It now re-reads that project's sessions alone through
`sessionSnapshots(inProject:)` and diffs them against the standing journal;
`ExtensionRendererTests.testProjectStructureChangeReSnapshotsOnlyThatProjectsSessions` counts the
provider reads and the events. That was not the 1.63 s, though: the interval carried no span and
wrote no file, and the trace shows the refresh's git reads did not run in it.

### The rest of the archive stall is the input method's activation

Every archive and most session switches that day ended the same way: a cursor deactivation logged
by `CursorUIViewService` just before the stall, an activation logged just after it, and 1.6–2.3 s
of nothing in between. The stall monitor deliberately keeps no stacks, so the attribution came
from `sample` run against the installed app the moment `log stream` printed its "Main thread
unresponsive" line. One switch stall put about one second of the main thread inside
`TSMToolboxListener → utOpenActivateAllSelectedIMInDoc → -[IMKInputSession_Modern activate] →
invocationAwaitXPCReply → -[HIRunLoopSemaphore wait:]`: the Text Services Manager activating the
selected input method (Press and Hold, `PAH_Extension`) for the newly focused terminal and waiting
on its XPC reply, with the main queue undrained and nothing of ours running. A standalone AppKit
process activating a fresh text context on the same Mac at the same time took 2–43 ms, active or
not, so the wait is specific to this process and not yet explained; the machine was at load
average 17–45 on ten cores throughout. `AgentSessionViewController.focusTerminal()` now opens the
`focus.terminal-input` span and closes it on the next main-queue turn, which runs behind the
activation the responder change queued, so the next stall trace names the wait instead of
leaving the interval empty.

## A sidebar click does not walk the Codex sessions tree, 2026-09-03

The report was "pressing a terminal entry in the sidebar often feels like it hogs the main thread".
The installed build retained 706 sessions, 343 of them Codex, and its stall monitor had written 20
incidents in the preceding half hour, from 0.3 to 3.7 s, most with `activeOperations: []`. Each
empty incident held a 10 ms `sidebar.reload` span somewhere inside it: the freeze was a
`ProjectsDidChange` fan-out, the sidebar's observer was the cheap one, and the owner was code no
span covered. A 60 s `sample` of the running app named it: `TranscriptSearchIndexStore.refresh()`
→ `TranscriptSearchProjection.sources` → `CodexTranscript.url` → `FileManager.enumerator` →
`getattrlistbulk`, 1.9 s of one main-queue drain.

**A miss walked the whole tree, and a retained catalogue is mostly misses.** `CodexTranscript.url`
enumerated the account's `sessions` directory — nested by year, month and day, holding every
conversation the account ever had — and memoised only a found path. An archived conversation's
rollout is pruned long before its session row is, so the miss is the common case: on the reporting
machine 311 of the 343 Codex sessions had no rollout on disk, and every projection walked the same
672 entries 311 times. One warm walk measured 3.3 ms (`swiftc -O`, median of 20), so a pass cost
about a second warm and 1.7–3.7 s in the app, on the main actor, inside the store observer that
every click, attention edge and agent title change reached. The rename fix above had already made
that observer incremental on master; the installed build predated it, and `rebuildAll()` on a
`.structure` event — provider archive reconciliation posts one on every app activation — still
paid the full pass.

**The projection now reads nothing on the main actor.** `CodexTranscript` keeps a `RolloutIndex`
per account: one walk records every rollout by the conversation id its name ends with, and
answers every later lookup — hit or miss — from a dictionary. A miss re-walks only once the index
is older than `rolloutIndexMaximumAge` (one second), which folds a burst into one read while a
rollout Codex has just written is still found on the next ask; a path reported by the lifecycle
hook joins the index without any walk. `SessionTranscript.url` takes a `TranscriptLookupEffort`:
`.discovering` is the single-conversation answer and may walk, `.known` answers only from the index.
`TranscriptSearchIndexStore` projects with `.known`, notes each account it could not place a
conversation on, reads those trees once each on a utility worker, and projects the sessions on
them again from the result. A conversation the walk did not see stays unplaced without another
walk: the next event about it asks again, and until then the answer on disk has not changed.

Measured in the hosted test bundle against a fixture shaped like the report — 343 Codex sessions,
32 with a rollout among 672 files in 50 day directories — Debug, Apple silicon, warm directory
cache. One walk of that tree is 10.3 ms in the Debug test host (median of 5; 3.3 ms compiled
`-O` outside it). The before row ages the index past its bound before every lookup, which is what
the old code did for every miss:

| | main actor | walks |
|---|---|---|
| Before: discovering projection, one walk per miss | 3,579 ms | 343 |
| After: `.known` projection before the worker's walk | 4.3 ms | 0 |
| The worker's one walk | 10.9 ms, off the main actor | 1 |
| After: `.known` projection once the walk has answered | 4.8 ms | 0 |

### Regression boundary

`CodexTranscript.rolloutWalkCount` is the contract's witness. `CodexRolloutIndexTests` drives 300
misses and 5 hits through the production lookup and requires one walk, proves a miss is re-asked
only past the bound, that `knownURL` never reads, and that a reported path is indexed without a
walk. `TranscriptSearchRolloutDiscoveryTests` builds a 24-session catalogue on a fixture account
and requires the store's main-actor pass to place nothing and walk nothing, then the worker's
single walk to place exactly the conversations on disk.

### The row re-plated its mark on every tick

The same sample charged a second owner, smaller and steady: 1.05 s of main thread per minute in
`setTerminalTitle` → `refreshRow` → `SessionRowView.configure` → `applyAgentIcon`, 0.4 s of it
inside `NSImageView`'s catalogue rendition walk. The row sized and plated the agent's mark afresh
on every reconfigure and handed the view the new copy, and the view treats every new object as new
content. Identical title reports were already deduplicated (see the terminal-title target above);
this is the cost of the reports that do differ, and of every activity and loading edge, which
reconfigure the row the same way. `SessionRowView` now keeps the mark and its plate while the two
facts that decide them — the agent, and whether the row is a side chat — hold, and hands the view an
image only when it is not the one already shown; the plate is decided again where the ground moves,
never merely because the row was filled in. Extension-supplied marks stay uncached, since their
bytes may change under the same name. `SessionRowIconReuseTests` asserts the image object survives
a rename, an activity edge and a loading raise, changes with the agent, and is re-plated by
selection and kept across a reconfigure while selected.

## Update All terminal creation is one exact leaf

The 2026-09-03 report arrived with the action and its evidence: pressing **Update All** in the
agent-tool update toast froze the UI. The installed build retained 17 projects and 696 sessions.
Its stall monitor recorded consecutive main-thread stops of **9,612 ms** and **5,094 ms** at the
press, with no owning semantic span. The sidebar work that followed was only 4.6–7.7 ms, and the
PTY host log contained no updater child before the stalls. That orders the incident: the app was
blocked while creating the durable terminal record, before it launched an update process.

That installed revision still sent both `ProjectStore.addTerminal` and the immediately following
`renameTerminal` through `save()`. Each call encoded and reconciled every retained session on the
main actor. The current store had already acquired the project-record seam described above, but
Update All still performed two project commits, terminal creation still rebuilt all store lookup
indexes, and its broad `projectStructure` event made unrelated workload, curfew, transcript and
extension consumers treat one terminal as a changed project catalogue.

The title is now part of terminal creation, so the action takes one project-record commit and the
returned value already matches what is durable. Appending installs the one terminal lookup entry
directly; it changes no existing project or session position. The successful mutation publishes
`terminalAdded(projectID:terminalID:)`. The sidebar inserts that exact leaf and updates its three
identity maps, while consumers that do not model terminals ignore it and consumers that do update
only the named terminal. Branch creation remains the deliberate project-local fallback because
adding a second item on a branch genuinely changes more than one row. Project-script terminals use
the same atomic titled-creation path.

The update plan itself is bounded by the five-case `AgentKind` catalogue; the retained project and
session graph is not. The expected incident shape is roughly 700 sessions and the stress shape is
5,000. The success path must therefore be O(1) in retained sessions, one owning-project payload
write, and one presented terminal leaf. `ProjectStoreMutationTests` plants a future-format sentinel
in an unrelated session row and proves titled terminal creation neither encodes nor upserts it.
The sidebar tests pin both the exact-leaf path and the real branch-regrouping fallback, and the
existing full-plan test still launches every provider command through the complete argv transport.

The project-sidebar fixture now times titled terminal creation separately. On 2026-09-03, Debug,
Apple M1 Max, manual order:

| Shape | Terminal mutation | Following layout | Sidebar delta | Whole-graph comparison |
|---|---:|---:|---:|---:|
| 17 projects × 41 sessions = 697 | **1.580 ms** | 0.962 ms | 1.055 ms | 37.742 ms |
| 20 projects × 250 sessions = 5,000 | **3.907 ms** | 1.284 ms | 1.485 ms | 278.688 ms |

Before the typed terminal delta, the same 5,000-session fixture measured 10.818 ms for the
mutation and 8.851 ms inside the project-subtree sidebar update. Afterwards the tree, shape and
adoption phases are all zero on the ordinary path. These synthetic whole-graph comparisons contain
smaller payloads than the user's live transcripts and do not reinterpret the multi-second incident;
their job is to make any return to catalogue-sized persistence conspicuous in a repeatable run.

## Project sidebar stress target

`SidebarTreeBuilderTests.testStressProjectSidebarWhenEnabled` seeds a throwaway `ProjectStore`
database and loads the production `ProjectSidebarViewController`. It measures cold load and layout,
same-shape content refresh, collapse/re-expand, a reveal through branch and nested side-chat levels,
one targeted title event, 250 repeated row updates, one exact session creation, an archive/restore
pair, two exact removals, and the pure tree builder. Creation and removal retain deliberate
whole-graph/full-reload comparison phases so an ostensibly faster targeted path is measured against
the broad work it replaced. Archive and restore report mutation, project-subtree outline and layout
phases separately. The
fixture fixes the grouping defaults, parameterizes manual/recent/name order, and never reads or
changes the user's projects. It also asserts that the expanded outline contains exactly as many
rows as the pure tree; this catches an ancestor that a sort order accidentally left closed, not just
slow work.

The cold fixture follows `MainWindowController`'s production lifecycle: load the deferred sidebar
shell, give it its final 300 × 720 geometry, cross the explicit initial-tree mount boundary, then
perform final layout. Shell construction and shell layout are reported separately from tree mount,
because fresh-process AppKit initialization is variable and is not sidebar work. Keep small semantic
tests beside this large fixture. The persisted-closed-project case, nested side-chat ordering, exact
row count, selection, and reveal assertions prevent a faster result from silently changing what is
expanded or addressable.

`scripts/profile_threading.sh sidebar-stress` runs manual order at 500, 1,000, 2,000 and 5,000
sessions, plus recent-activity, name and type order at 5,000, in fresh `xctest` processes.
`THREADING_SIDEBAR_STRESS_ORDER`, `..._PROJECTS`, and `..._SESSIONS` narrow it to one point. The
optional `THREADING_SIDEBAR_STRESS_REGISTERED_FACT=sort` layer selects a registered integer fact as
the primary sort; `group` uses 5,000 distinct date buckets to cover heading format and allocation.
The compatibility spelling `1` means `sort`, and each run labels the mode in `registered_fact`.
The profiler's DerivedData lives inside that run's artifact directory: parallel developer builds
cannot lock its build database, while the deterministic workloads in `full` reuse the same isolated
build. Results are `THREADING_PERF project-sidebar` lines in `project-sidebar-stress.log`.

### Registered-fact arrangement envelope, 2026-09-07

The hostile grouping point gives every one of 5,000 sessions a distinct date, so it measures the
maximum extra heading count as well as date-label formatting. A current Debug bundle at 50 projects
× 100 sessions produced:

| Registered fact | Logical rows | Materialized cells | Cold reload | Tree | Shape | Indexes | Outline | Same-shape refresh |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Integer sort | 5,299 | 45 | 121.6 ms | 83.2 ms | 10.5 ms | 13.7 ms | 13.5 ms | 125.5 ms |
| Unique-date group | 9,849 | 23 | 216.6 ms | 99.9 ms | 41.2 ms | 25.4 ms | 48.1 ms | 209.6 ms |

Both runs passed the production selection, disclosure, mutation and exact-row assertions. The
5,000-session Debug regression envelope is **150 ms** for registered sorting, **250 ms** for the
deliberately maximum-cardinality grouping, and at most **64 materialized cells** for either. The
group bound accepts one rare, explicit arrangement or provider-catalogue pause while keeping it
below the retained whole-graph persistence comparison; exact value edges must instead patch the
frozen fact snapshot and rebuild only the reached project's subtree. A result outside these bounds
requires another measured repair or an explicit product decision before widening the envelope.

At 5,000 sessions the outline contains 5,120 logical rows but materializes only 23 cells, so row-view
virtualization is already doing its job. The measured fixes are above that layer:

- rendered project, session, owner and ancestor indexes replace repeated flattened and recursive
  node scans;
- `ProjectStore` maintains project/session location indexes across structural edits, making the
  model lookup used by every live row constant-time;
- content refresh touches only the viewport, since an off-screen row reads current store state when
  AppKit eventually asks for its view;
- `ProjectsDidChange` carries a session-title impact with an explicit Name-order bit. Ordinary
  title changes repaint one row; Name order rebuilds, adopts and diffs only the affected project's
  subtree. An identity-set guard falls back to the complete builder if a supposedly title-only
  event ever adds or removes a row;
- a `sessionAdded` impact inserts the common manual-order leaf and its exact indexes directly.
  Branch-group transitions and non-manual orders fall back to the affected project's subtree,
  never the complete sidebar;
- outline expansion callbacks ignore disclosure state that already matches the model, and an actual
  disclosure change upserts only that project row. It never walks or rewrites the session table.

On the 5,000-session Debug fixture, 250 targeted row updates fell from about 608 ms on the original
scan/store path to roughly 55–65 ms, and a title event takes about 1 ms rather than the roughly 38 ms
same-shape reload. The latter still exists for genuinely ambiguous content changes; its tree build
is about 30–33 ms.

The apparent outline cliff had a different cause. Programmatic expansion during cold reload invokes
the same delegate callback as a user disclosure, and that callback used the store's full save path.
Cold load therefore upserted all 5,000 sessions once for every expanded project; collapse/re-expand
did it twice more. Ignoring already-matching state and persisting only the changed project row cut a
representative 5,000-session controller load from about 3,165 ms to 200 ms and collapse/re-expand
from about 303 ms to 3.8 ms. A repeated sweep measured 135 ms load, 72 ms first layout and 7.3 ms
disclosure. These figures are regression-scale evidence, not release-build launch claims.

A later sweep after deferring absent account and pin subtrees appeared to keep materialized cell
count bound to the viewport and exercised 120 consecutive resize ticks:

| Sessions | Logical rows | Materialized cells | Load | First layout | Resize p95 / max |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 1,060 | 24 | 84.8 ms | 51.2 ms | 5.12 / 5.84 ms |
| 5,000 | 5,120 | 23 | 157.3 ms | 46.5 ms | 5.12 / 5.60 ms |

Those values came from an eager standalone controller mounted while its view still had zero
geometry. They were useful for model work but did not reproduce the product lifecycle. Moving the
fixture to the final-width deferred mount exposed the real AppKit cliff: sequential disclosure in a
live 720pt viewport retained cells from intermediate tree heights. At 5,000 sessions the corrected
before case took 232–234 ms for cold mount, including 183–185 ms in outline application; it retained
54 cells, took roughly 47 ms for final layout, and made resize p95 18–19 ms.

Cold mount now constructs the complete tree while only the list viewport is synchronously held at
zero height, then restores its real bottom constraint before the next display pass. Final width and
the rest of the window remain in force. The first expansion is one recursive request per open
project, and adoption returns the rebuilt tree directly when no presented tree exists. Clean matched
5,000-session runs now take roughly 82–99 ms for cold mount, including 33–42 ms in outline
application, retain 23 cells, lay out in 38–46 ms, and keep resize p95 around 1.6–3.8 ms. Cold
adoption fell from about 7 ms to effectively zero. Collapse/re-expand remains about 4–5 ms and a
deep reveal about 13–18 ms. A machine-contention outlier reached 147 ms mount/66 ms outline, which is
why phase metrics and repeated runs are kept instead of quoting one aggregate.

The 2026-08-11 order sweep found two costs the manual-only fixture had hidden. Manual order was
comparison-sorting an array already in manual order, and Name order re-derived each display title
(including a defaults read) for every comparison. Manual order is now a linear stable partition for
pins; derived orders sort lightweight offsets; Name order computes each title once. Fresh-process
5,000-session medians were:

| Order | Tree build before | Tree build now | Targeted title event now |
|---|---:|---:|---:|
| Manual | 46.0 ms | **25.3 ms** | 6.3 ms |
| Recent activity | 42.8 ms | **27.5 ms** | 6.4 ms |
| Name | 174.3 ms | **61–68 ms** | **13.7 ms** |

The Name-order title event was about 196.5 ms before cached names and project-local rebuilding; it
is now inside one 60 Hz frame even at 5,000 sessions. At 500/1,000/2,000 sessions it measured
9.8/11.0/15.2 ms. All three 5,000-session variants now expose the complete 5,120-row tree. Before
tree-ordered expansion, recent/name ordering could ask AppKit to expand a descendant before its
parent existed and silently exposed only 5,063 rows; expansion now walks the presented hierarchy.

`sidebar.outline.apply-structure`, `sidebar.session-order.apply`, and
`sidebar.disclosure.persist` keep the remaining AppKit, local reorder, and SQLite costs separable in
a trace. `persistence.sessions.save` reports the changed-row count for archive and every other
immediate standing-session write, so a filesystem wait cannot hide inside the outline phase. The
earlier recursive `expandChildren` experiment was initially reverted because the old
fixture made it look slower. With persisted disclosure fixed and the production lifecycle in the
fixture, batching the first expansion is now retained. A focused semantic test also caught and fixed
two adjacent disclosure errors: a lone root project had ignored persisted closure, and groups below
a project opened later did not regain their default-open state. A flattened visible-row table
remains an option only if a future product target demands substantially less than the now-bounded
AppKit mount and resize phases.

### Permanent session removal is an exact edit

Deleting one chat used to take every broad maintenance path at once: `ProjectStore` rewrote the
complete project graph, the sidebar rebuilt and reloaded every project, its caller immediately
reloaded the same outline a second time, and the main window recomputed the live-session set before
sweeping every session-owned cache. A live native conversation also synchronously serialized the
entire viewport-continuity document even though the deleted session could never restore it.

The 5,000-session Debug fixture measured a dormant deletion at 302 ms before layout and a selected
deletion at 280 ms. The targeted transaction and project-subtree outline edit reduced those phases
to about 44 ms and 19 ms respectively; the project-local outline share was about 31 ms / 11 ms. The
removed duplicate full reload alone cost another 60 ms. A 1,000-turn native transcript split the
live teardown pause and attributed 27.8 ms of 27.9 ms to the obsolete viewport save rather than to
releasing its row hierarchy. Skipping that write at the permanent-delete boundary reduced a fresh
1,000-turn teardown to **0.048 ms**; releasing the virtualized hierarchy itself was 0.001 ms.

The implementation rule is therefore stronger than “delete the row efficiently”: a permanent
single-session action stays exact through every owner. It uses one SQLite delete plus the affected
project's positional shift, replaces only that project's rendered tree and indexes, skips viewport
continuity persistence, invalidates the exact runtime/panel/drawer/attachment/MCP/capture/subagent
records, and removes owned cache directories on a utility task. `sidebar.session-remove.persist`,
`sidebar.project-structure.apply`, and `sidebar.session-remove.cleanup` keep those boundaries visible
in a CLI trace. Whole-set `retainOnly` sweeps remain appropriate for startup reconciliation, never
for an ordinary one-chat click or a project removal whose exact identities are already in hand.

Project deletion has its own batching boundary because its input is a project-sized set rather
than one chat. Git checkpoint metadata is scanned and saved once for the complete removed set;
scheduled sends are filtered and committed once rather than once per session; conversation
handoff and execution-audit files leave on worker queues. The remaining attachment-copy,
panel-cache and visual-baseline directory retention sweeps also enumerate and delete away from
AppKit. Its project-store event carries the removed project, session and terminal identities, so
search indexes, curfew state and extension fact indexes delete those keys without reconstructing
the surviving catalogue. This keeps the synchronous portion proportional to in-memory ownership
teardown and the one authoritative SQLite graph transaction, instead of sessions × auxiliary-store
size plus filesystem latency.

A follow-up audit found two broad passes still hiding inside that exact-looking route. Compact-tree
rule refresh asked the outline for every logical row merely to discover which row views AppKit had
mounted, and `ProjectStore` rebuilt the lookup dictionaries for every project, session and terminal
after removing one session. The outline now maintains a weak registry from its add/remove delegate
callbacks and the store removes one identity plus shifts only later sessions in the affected
project. The 5,000-session regression reports and gates **47 rule candidates for 5,118 logical
rows**. Three reused-binary runs put selected deletion at 11.198–14.444 ms (12.330 ms median),
versus 17.572 ms in the earlier artifact, but those runs were not a controlled same-load pair; the
load-bearing result is the deleted whole-tree/whole-store work and the mounted-row candidate gate,
not an aggregate timing claim. Artifacts are
`/tmp/threading-profiles/20260812T120530Z-sidebar-stress` and
`/tmp/threading-profiles/20260812T121710Z-sidebar-stress`.

The final exact persistence pass removed the remaining whole-state write from this route. One-chat
deletion now executes one SQLite `DELETE`, shifts only later positions in that project, updates the
selected-session scalar in the same transaction, and mutates only the affected in-memory location
indexes. Three one-project / 5,000-session runs measured the complete dormant mutation plus layout
at **32.40–35.69 ms (35.08 ms median)** and selected deletion at **12.65–15.12 ms (13.22 ms
median)**. Their exact outline work was only 1.26–1.61 ms dormant and 0.83–0.90 ms selected; the
same fixture's deliberate full-reload comparison remained about 121–133 ms. Against the prior
exact-row-but-whole-store baseline of 160.03 ms dormant and 112.53 ms selected, the medians are
roughly **78% and 88% lower**. The remaining ~30 ms cold dormant sample is the first durable SQLite
write/model shift, not a logical-row walk; the warmed selected mutation itself is 4–6 ms.

## File pane stress target

`FileTreeViewTests.testStressFileTreeWhenEnabled` builds a throwaway directory before its clock
starts, then exercises the production `FileTreeViewController`: cold refresh, first layout,
recursive disclosure, an exact jump to the final row, and a hot refresh. Flat fixtures run at 100,
1,000, 5,000, and 20,000 files; nested fixtures spread 5,000 and 20,000 files over up to 100
directories. Only about 35 cells are alive in the 700pt viewport even when all 20,100 logical rows
are addressable.

`scripts/profile_threading.sh file-tree-stress` runs every point in a fresh process under both
System and Neo Brutalism. `THREADING_FILE_TREE_STRESS_THEME`, `..._SHAPE`, and `..._ENTRIES` narrow
an investigation. The theme split is load-bearing: System draws actual Finder artwork, while an
authored theme draws semantic symbols and must do no LaunchServices icon work.

A Debug sweep after replacing each row's raw `NSImageView` with the design-system renderer measured
the flat path as follows:

| Files | Theme | Refresh | First layout | Jump to final row | Footprint delta |
|---:|---|---:|---:|---:|---:|
| 100 | System | 2.7 ms | 27.5 ms | 15.7 ms | 11.6 MB |
| 1,000 | System | 34.1 ms | 25.3 ms | 15.6 ms | 30.2 MB |
| 5,000 | System | 146.2 ms | 26.5 ms | 16.2 ms | 96.1 MB |
| 20,000 | System | 648.9 ms | 28.5 ms | 17.2 ms | 389.1 MB |
| 100 | Neo Brutalism | 2.7 ms | 23.5 ms | 13.7 ms | 8.1 MB |
| 1,000 | Neo Brutalism | 33.7 ms | 21.9 ms | 13.3 ms | 26.8 MB |
| 5,000 | Neo Brutalism | 146.5 ms | 23.6 ms | 13.6 ms | 92.7 MB |
| 20,000 | Neo Brutalism | 637.7 ms | 22.9 ms | 15.4 ms | 385.5 MB |

The original 20,000-file System fixture measured 1,117 ms refresh, 266 ms layout, a 77 ms jump,
1,432 ms hot refresh, and 412 MB of additional footprint. The strongest comparison is the AppKit
work: first layout is now bounded near the viewport rather than growing to 266 ms, and exact jumps
stay below one frame at 60 Hz in the authored theme. Refresh still scales with directory enumeration,
model allocation, and sorting; the icon renderer does not change that linear model cost.

The next sweep made hot refresh honest. `FileNode.reload()` used to replace every child before the
controller recorded disclosure, so the apparently cheap 44–52 ms refresh returned from 20,100 rows
to 100 collapsed roots. A node now keeps its object identity when its name/path and directory kind
still match; additions and removals reconcile around it. The stress test asserts the full row count
survives, and a focused two-level fixture asserts both the parent and nested node are the same
objects after a new file appears.

The first correct 20,000-file refresh cost 1.02–1.08 s. That exposed two self-inflicted scans:
matching siblings canonicalised tens of thousands of already-sibling URLs, and finding 100 open
directories walked all 20,100 outline rows. A sibling's name is its path identity relative to its
parent, so `FileNode` now stores that name once for matching, sorting and drawing; disclosure
collection traverses only directory nodes. Two fresh-process repetitions after that change measured:

| 20k shape | Theme | Primary load | Final-row jump | Correct hot refresh | Rows after refresh | Footprint delta |
|---|---|---:|---:|---:|---:|---:|
| Flat | System | 201–207 ms refresh | 15.1–15.6 ms | 227–230 ms | 20,000 | 50.0 MB |
| Flat | Neo Brutalism | 202–203 ms refresh | 12.9–13.2 ms | 229–241 ms | 20,000 | 49.7–49.8 MB |
| Expanded | System | 221–230 ms disclosure | 20.2–20.9 ms | 221–222 ms | 20,100 | 58.8–58.9 MB |
| Expanded | Neo Brutalism | 220–224 ms disclosure | 17.7–18.1 ms | 219–225 ms | 20,100 | 58.7 MB |

At 5,000 files, flat refresh is 48 ms System / 52 ms Neo; expanded disclosure is 70 ms and a
correct hot refresh is 53 ms in either theme. That is the more representative operating point;
20,000 remains the deliberate edge used to make scaling mistakes obvious.

The expanded comparison to the original row remains 1,941 ms disclosure and a 140 ms jump versus
roughly 225 ms and 18–21 ms now, but the important refresh result is correctness and cost together:
all 20,100 rows remain addressable for about 220 ms. Remaining time is the intended work of reading
and naturally sorting every open directory; changing that boundary means filesystem observation or
incremental directory deltas, not another view-layer tweak.

### File pane refresh leaves the event loop

The remaining boundary was changed rather than micro-optimised. `FileDirectorySnapshot` is an
immutable Sendable value: directory enumeration, `isDirectory` metadata, deterministic natural
sorting and a SHA-256 content signature happen in a detached user-initiated task. The main actor
keeps the identity-bearing `FileNode` objects and reconciles a changed sorted snapshot with a
two-pointer merge. A late worker result carries the node's load generation and is refused if a
newer refresh started. Completion callbacks from coalesced refreshes are retained until the newest
accepted result, so moving work off-main does not leave a caller waiting forever.

Disclosure uses the same boundary. The outline initially refuses an unread directory's expansion,
loads its value snapshot off-main, then reloads and expands that one directory. A directory with
tens of thousands of files can therefore take time to become ready without holding mouse, scroll,
resize or terminal input for the duration.

Fresh 20,000-entry runs before this change reproduced 204.2 ms initial refresh and 234.5 ms correct
hot refresh. Afterward, under both System and Neo Brutalism:

| 20,000-entry workload | Main actor before | Main actor after | Background readiness after |
|---|---:|---:|---:|
| Flat initial load | 201–207 ms synchronous refresh | **0.06–0.09 ms schedule + 18.5–20.6 ms snapshot install** | 259–272 ms including enumeration, sort and signature |
| Flat unchanged hot refresh | 227–241 ms synchronous refresh | **1.8 ms schedule + 0.015–0.020 ms apply; no AppKit reload** | 257–265 ms |
| Flat hot refresh after one insertion | same whole-tree synchronous path | **1.6–1.9 ms schedule + 16.3 ms merge/reload** | 297–299 ms under the two-process IO run |
| 100-directory / 20,100-row disclosure | 220–230 ms synchronous disclosure | **0.33–0.36 ms schedule; 19.7–21.8 ms largest AppKit completion slice** | 330–401 ms for all 100 concurrent reads and expansions |
| Expanded unchanged hot refresh | 219–225 ms synchronous refresh | **1.7 ms schedule + 0.057–0.068 ms apply** | 244–245 ms |

The readiness column is deliberately not presented as a throughput win: SHA-256 adds bounded
worker work and concurrent stress-process IO varies. The repaired invariant is event-loop
ownership. Even the deliberately extreme fixture no longer performs a quarter-second filesystem
walk or unchanged-tree rebuild on the main actor. The cold 20,000-node install, a top-level
insertion and one late bulk outline expansion can still consume roughly one frame; materially
lowering those costs would mean
replacing the identity model or the outline, not moving the same scan between view callbacks.

## Tools settings stress target

`SettingsDisclosureRenderTests.testStressToolsPreferencesWhenEnabled` exercises the production
Tools settings page without opening the app or Instruments: cold construction and layout, expansion
and collapse of the largest tool group, all-group expansion, and 48 rendered scroll positions.
`scripts/profile_threading.sh tools-settings-stress` builds an isolated test product and runs the
fixture under System and Neo Brutalism. Set `THREADING_TOOLS_SETTINGS_STRESS_THEME` to one theme ID
for a focused run. It then runs theme-independent 1,000-entry Website Access and Browser Sign-In
fixtures; override their counts with `THREADING_TOOLS_WEBSITE_ACCESS_STRESS_ORIGINS` and
`THREADING_TOOLS_BROWSER_SIGN_IN_STRESS_ORIGINS`. The baseline catalog had 12 groups and 66 tools;
the post-change tree has 67. Browser is the largest group in both at 34 tools.

Two fresh-process Debug runs per theme, with `NSApplication` initialized as it is before an in-app
settings navigation and the page attached to an offscreen `NSWindow`, measured:

| Workload | Theme | View construction | Layout | Live descendants |
|---|---|---:|---:|---:|
| Cold collapsed page | System | 28–32 ms | 59–74 ms | 223 |
| Cold collapsed page | Neo Brutalism | 27–33 ms | 54–65 ms | 223 |
| Expand Browser | System | 63–95 ms | 91–121 ms | 631 |
| Expand Browser | Neo Brutalism | 62–94 ms | 97–104 ms | 631 |
| Expand all groups, aggregate | System | 965–1,019 ms | 1,571–1,625 ms | 1,015 |
| Expand all groups, aggregate | Neo Brutalism | 947–1,031 ms | 1,636–1,658 ms | 1,015 |

Catalog discovery itself took 0.2–0.5 ms, so provider enumeration is not the cold-open owner. On the
fully expanded 5,014pt document, moving the clip view is cheap and does not relayout the settled
tree: a forced rendered scroll position cost 0.08–0.12 ms in layout. Synchronous drawing cost
19–22 ms in System and 59–74 ms in Neo Brutalism. This deliberately forces `cacheDisplay` and is a
paint stress number, not a literal animation-frame time: a live layer-backed window can composite
already-rendered layers. It does expose the relative authored-theme cost. A Neo sample placed 894
of 917 draw samples in recursive `CALayer.renderInContext`; visible leaf work included repeated
template glyph and text rendering. Virtualizing the page reduces that layer tree too, while any
separate glyph-cache change should be justified by a live Animation Hitches trace.

An earlier off-window fixture reported roughly 100 ms of layout per position because AppKit
attached a temporary constraint engine for every forced draw; keeping the window in the fixture is
load-bearing.

The expensive real path is disclosure. Expanding Browser from the collapsed page takes roughly
154–215 ms. Expanding all 12 groups in sequence takes 2.5–2.7 seconds because each click rebuilds
and lays out the increasingly large page again. A command-line `sample` capture found 841 sampled
stacks in the explicit layout following a disclosure, 770 in constraint updates, 717 walking the
view subtree, and 335 in `NSStackView.updateConstraints`; 305 of those reached constraint insertion.
The render side separately showed `ThemedDisclosureRow.performPrimaryAction` calling
`ToolsPreferencesViewController.render()`, then reconstructing the group and tool rows.

The architectural boundary was therefore the retained nested stack and whole-page replacement, not
tool data loading. The repair keeps a cheap presentation-row model in
`ToolsPreferencesViewController` and hands visible rows to `ThemedGroupedTableView`. The table draws
one continuous themed card behind each group range, so virtualization does not change the settings
shape. A disclosure inserts or removes only that group's tool rows; a group switch reloads only its
header and tool run; account/browser mutations rebuild the cheap model and ask the table to recycle
the visible cells. The fixed `SettingsPageView` and its scroll view survive all of them.

Two fresh runs after that change measured:

| Workload | Theme | Mutation / construction | Layout | Live shape |
|---|---|---:|---:|---:|
| Cold collapsed page | System | 11–13 ms | 45–52 ms | 144 descendants |
| Cold collapsed page | Neo Brutalism | 12 ms | 44–48 ms | 144 descendants |
| Expand Browser | System | 19–29 ms | 0.73–0.76 ms | viewport rows only |
| Expand Browser | Neo Brutalism | 18–20 ms | 0.70–0.75 ms | viewport rows only |
| Expand all groups, aggregate | System | 29–39 ms | 1.39–1.46 ms | 9 of 83 rows materialized |
| Expand all groups, aggregate | Neo Brutalism | 29 ms | 1.29–1.37 ms | 9 of 83 rows materialized |

Browser disclosure is now roughly **5–10× faster**, and the all-group sequence roughly **60–90×
faster**. The settled retained tree fell from 1,015 descendants to 137 in the expanded fixture.
Scrolling now intentionally pays 3.5–5.1 ms of layout per forced position to mount the new visible
rows rather than keeping all 83 mounted; it remains inside one frame. System forced drawing stays at
21–22 ms because its visible paint was already the whole cost, while Neo falls from 59–74 ms to
18–19 ms because its offscreen authored layers no longer participate in the recursive render.

These boundaries are load-bearing: do not replace the table with a stack, wrap its scroll view in
`SettingsUI.page(_:)`, or turn disclosure back into `render()`. Extension-contributed Tools fields
must remain individual rows in that same table; do not regress them to opaque section rows, nest a
second table/scroll view, or hide a total-content rebuild behind a debounce.

The same boundary applies inside dynamic sections. Website Access originally occupied one outer
table cell containing a nested `SettingsCard` with every persistent origin. At only 250 origins,
that cosmetic row took **53.4 ms to construct + 2,076.9 ms to lay out**, retained 2,313 descendants
and added 117.3 MB to the fresh test process. `PresentationRow.websiteAccessOrigin` now gives every
origin its own stable table identity; the caption, empty state and Revoke All action are separate
rows, while a single table-card decoration preserves the visual section.

At 1,000 origins, the repaired fresh process measured **63.9 ms load + 43.6 ms first layout**, with
10 of 1,005 rows materialized, 112 descendants and 7.7 MB added. Revoke tags index the same sorted
origin snapshot used to build the row identities, and every mutation refreshes that snapshot before
recycling the viewport. Do not put the origins back inside one section view.

Browser Sign-In had the same nested-card defect. Its provider picker, linked 1Password items,
Threading-vault identities and process-lifetime submission exemptions all lived in one outer table
cell. A 250-exemption fresh process took **31.8 ms to construct + 2,247.3 ms to lay out**, retained
2,310 descendants and added 112.4 MB. The repair snapshots only identity metadata during `render()`,
then gives the caption, provider, each identity, each exemption and the provider-specific empty/add
actions their own `PresentationRow`. One table-card decoration keeps the section visually whole.

At 1,000 exemptions, the repaired process measured **30.4 ms load + 25.1 ms first layout**, with 10
of 1,006 rows materialized, 102 descendants and 8.3 MB added. The action regression test invokes
`Ask Again` through a materialized row and proves both the process store and value-row count shrink
together. Remove/revoke tags always index the same sorted snapshot that built the identities, and a
mutation rebuilds that snapshot before viewport recycling. Do not aggregate any Browser Sign-In
inventory back into a single row, and do not read credential secrets while building the snapshot.

### Settings search results

Search is a frequency-scaled surface as well as a size-scaled one: an installed extension can
contribute up to eight settings pages, so the 256-package ceiling alone can produce 2,048 matching
pages, and the result controller receives updates on every query change. The original controller
mapped every match to a complete row, nested those rows in one settings page and replaced the page
on each update. At only 250 matches, a fresh process took **162.1 ms to construct + 1,169.2 ms to
lay out**, retained 2,761 descendants and added 87.0 MB. Repeating the same identities with a new
query cost another **384.4 ms mutation + 1,096.1 ms layout** and could reset the scroll position.

The repair keeps match identities in a `ThemedGroupedTableView` and materializes only the viewport.
An identity change reloads the value rows; a query-only change updates the two `SearchMatchLabel`
instances in each visible cell in place, so buttons, constraints and offscreen height discoveries
remain untouched. At 2,048 matches, the repaired process measured **25.4 ms load + 40.0 ms first
layout** and **1.8 ms update + 1.5 ms update layout**, with 18 of 2,049 rows materialized, 222
descendants and 12.2 MB added. The fixture scrolls to the end before changing the query and asserts
the exact clip origin is preserved. Run it with `scripts/profile_threading.sh
settings-search-stress`; override the ceiling with `THREADING_SETTINGS_SEARCH_STRESS_RESULTS`.

Do not rebuild result cells for a query-only highlight change, and do not turn the result set back
into one eager settings card. Action tags must continue to index the same match snapshot that
created the row identities.

**2026-08-13 — the surface moved into the sidebar.** The virtualized pane controller above was
unwired from the app in the "Fix Settings sidebar search" change and later deleted with the
row-level search redesign: results are now the sidebar's own list — each matching page's row with
the matching *settings* beneath it, clicking a setting scrolling its page to the anchored row
(`SettingsRowAnchor`/`SettingsRowReveal`). That list is a retained stack rebuilt per keystroke, so
the extension ceiling applies to it instead: a search caps what it constructs at
`SettingsSidebar.Defaults.maximumResultRows` (48) and appends a "N more pages match" line for the
cut, while setting-level rows come only from the app's own bounded catalogue (`SettingsEntry`).
The stress fixture kept its name (`testStressSettingsSearchResultsWhenEnabled`) and now drives
2,048 extension-shaped pages through the real sidebar, asserting the cap held, the cut was stated,
and the theme audit passes; `scripts/profile_threading.sh settings-search-stress` still runs it.
The resting (query-empty) page list remains uncapped: it is the app's own catalogue plus whatever
extensions actually installed, and it predates this change. Do not lift the cap without
virtualizing the results, and do not let the cap go silent.

## 2026-08-09 — command and workspace-file interactive bounds

The command palette and file mentions cross both scaling axes: extension/file cardinality grows,
and filtering runs at keystroke frequency. Their implementation-time gate is explicit:

- command catalogs filter off-main, cancel superseded work, check cancellation during the pass,
  and hand the main actor at most 100 value rows for a virtual table;
- semantic project input reads the in-memory `ProjectStore` once when the second step opens; the
  extension never enumerates checkouts, and project filtering shares the same cancellable 100-row
  result boundary as session input;
- workspace discovery uses `git ls-files -co --exclude-standard -z` once per execution checkout,
  never recursive enumeration per keystroke; the queue-confined index admits at most 100,000
  contained regular paths and 16 MiB of Git output, cancels superseded queued queries, and returns
  at most 64 relative references;
- send-time validation deliberately refreshes the roster rather than trusting the completion
  cache, which is why saved drafts detect deletes and renames;
- the stress fixtures exercise 25,000 commands, 50,000 matching paths, result caps, and refusal
  just past the 100,000-path index boundary. These are correctness workloads rather than timing
  thresholds: CI variance must not turn a bounded architecture into a flaky stopwatch assertion.

## Media document stress target

`MediaDocumentPerformanceTests` is the scale fixture for the media path — the `media` node's
player, the Lottie engine, the project-file walk and the attachments content probe. Default sizes
run on every `fast` pass so an accidental shape change fails immediately;
`THREADING_MEDIA_STRESS=1` raises the layer count to 500 and the file count to 20,000 for a
profiling sweep, and `THREADING_MEDIA_STRESS_LAYERS` / `THREADING_MEDIA_STRESS_FILES` set them
directly.

The iPhone attachment Share path has one independent byte-size axis. Expected ordinary files are
0–24 MB; the stress case is a multi-hundred-megabyte movie. A tap prepares exactly the selected
identity, only one preparation exists per gallery, and page or route changes cancel it. An
already-loaded ordinary preview shares the same immutable `Data` storage; a larger movie is
written off-main in authenticated 1 MiB ranges while holding one of the existing two preview
download slots, so resident staging payload is O(one range) and temporary custody is O(one
selected file). `RemoteAttachmentSharingTests` pins exact ordered ranges, short-range cleanup and
filename containment. Set `THREADING_ATTACHMENT_SHARE_STRESS=1` to stream a 256 MB deterministic
fixture through the production stager and verify its final size and 256 bounded fetches.

The subsystem it measures is described in
[`media-documents.md`](media-documents.md). **The player is the only high-frequency surface in the
feature**; everything else there is an action round trip, so these are the numbers that decide
whether the design holds.

### Measured, 2026-08-13, Debug, M-series

A 200-layer synthetic composition — each layer a filled and stroked rounded rectangle with an
animated position and rotation, which is a heavier document than most real ones.

| Path | Measured | Ceiling in the fixture |
|---|---|---|
| Parse, 50 layers | 5.0 ms | ratio-checked against 200 |
| Parse, 200 layers | 17.2 ms | must stay linear in layers |
| Rasterize one frame, 800 × 600 | 5.5 ms | 1 s |
| Rasterize one frame, 1,920 × 1,080 | 6.7 ms | 1 s |
| Rasterize one frame, backing cap (2,048²) | 10.7 ms | 1 s |
| **Main actor per tick** | **0.00 ms** | 2 ms |
| Animated GIF, decode + present | 2.8 ms/frame | 50 ms |
| Enumerate 5,000 files, 25 pages | 792 ms | 20 s |
| Probe 32 ambiguous candidates | 61 ms (0.9 ms read + 59 ms scan) | 1 s |

Two of those are the load-bearing ones:

- **0.00 ms on the main actor per tick.** `present(atProgress:)` hands the frame to a detached
  task and returns; what runs on the main actor per tick is bookkeeping. If that number ever moves,
  the rasterization has come back onto the main thread.
- **Sixty positions produce two rasterizations.** The fixture drives sixty `present(atProgress:)`
  calls while one frame is still rendering and counts what reaches the render host: the in-flight
  frame and the last pending position. A player that queued would produce sixty and drift further
  behind real time the longer it ran.

Rasterization is ~7 ms per frame at 1080p for a deliberately heavy document, so a 60fps document at
that size would not hold 60fps in Debug — which is why the clock is capped at the document's own
frame rate through `CAFrameRateRange`, why frames supersede rather than queue, and why the clock
stops the moment nothing can see it. These are Debug figures; Release is materially faster, and no
shipping conclusion should be drawn from them.

### The probe was 5× slower than it needed to be

The first measurement was **295 ms** for one scan's whole 32-candidate budget — on the worker a
debounced terminal scan shares. Attributing it split the cost cleanly: **1 ms of reading against
294 ms of scanning**, so the bounded 64 KiB prefix read was never the problem.

Three changes, each measured:

1. **Scan bytes, not a `String`.** The common answer is *no*, and building a 64 KiB `String` to say
   so costs a UTF-8 validation plus several grapheme-aware passes. 295 ms → 154 ms.
2. **Use the raw buffer, not `Data`'s indices.** Subscripting a `Data` by `Index` is not a pointer
   dereference. 154 ms → 110 ms.
3. **One pass, indexed by first byte.** A naive single pass that consults every needle at every
   position was *far worse* — **2,480 ms**, because the per-byte inner loop dominates everything.
   Every signature starts with `"`, `o` or `s`, so a 256-entry table makes the common byte cost one
   comparison and no iteration. 110 ms → **61 ms**.

The lesson worth keeping is the middle one: "fewer passes" is not automatically faster than
"several cheap passes", and the version that read best was 20× slower than the version it replaced.
Measure each step.

## Typing latency in a themed field

Two fields were reported as unusably slow to type in — an image-annotation note in the media
inspector, and the opening-message field in General settings. `ThemedTextField` itself was
measured first and cleared: drawing one costs **0.086 ms**, an order of magnitude *less* than a
stock `NSTextField` at 0.826 ms, and a full keystroke through the field editor including redraw is
0.317 ms. The component was never the cost. Both fields were slow for the same structural reason
in two different stores — **what the delegate does with each character**.

### The annotation note: an unbounded file rewritten per keystroke

Each character ran `SessionContinuityStore.setImageAnnotations`, and every mutation of that store
encodes the whole file, writes it atomically, reads it back and compares it byte for byte. That is
correct — it is the commit point for unsent user text — and it is affordable only if the file is
bounded. It was not: nothing ever deleted a reading position, so the file held one for every
session that had ever been scrolled. On this machine it had reached **7,163 records and 2.2 MB**,
7,159 of them positions for sessions that no longer existed.

Measured against a seeded copy of that file, Debug:

| | before | after |
|---|---|---|
| `setImageAnnotations`, median | **47.06 ms** | **2.06 ms** |
| `setConversationDraft`, median | 46.41 ms | 1.94 ms |
| file on disk | 2,234,922 bytes | 79,177 bytes |

The fix is the bound the companion clients already applied to the same data: position-only records
are kept to the 250 most recent, and a record holding an unsent draft, staged context or an
annotation document is never pruned. See [`persistence.md`](persistence.md).

Note what this also means for the **composer**: it writes a draft through the same store on every
keystroke, so it was paying the same 47 ms and is fixed by the same bound.

The residual ~2 ms is the bounded whole-file encode, write and read-back verify. It is left in
place deliberately rather than coalesced: the store's contract is that a draft is durable the
moment it is typed, and 2 ms is frame-cheap.

`SessionContinuityPruningTests` holds the boundary, including a keystroke-latency case seeded from
a written file rather than from 7,163 writes — the shape the bug actually had is an app launching
onto a file that grew over months.

### The settings field: a global broadcast per character

The opening-message field wrote `AppSettings.shared.newChatOpeningSuffix` on every
`controlTextDidChange`, and every write posts `AppSettingsDidChange`. Its observers then re-read
each project's git control files (**1.95 ms** across ten projects, measured), rebuild both sound
pop-ups — **0.41 ms** each, three directory scans and ~30 items apiece — and diff an extension
snapshot of every project and session. Several milliseconds of filesystem work per character, for
a value nothing reads until the next chat is created.

The write is now coalesced (0.4 s) and flushed when the field is left or the page disappears, so a
sentence is one write and one broadcast instead of one per character. Coalescing lives at this
field rather than in the setting descriptor on purpose: a toggle or a pop-up is a settled choice
the moment it is made and must still broadcast at once. Only free text arrives one keystroke at a
time. `OpeningMessageCoalescingTests` asserts both halves — silence while typing, and one write on
the way out.

The field became two — a prefix and a suffix, either side of the task — and the flush settles only
the half with unsettled typing in it. Writing both would cost two broadcasts for one settled
sentence, and would push whatever the page last read into the half nobody touched, undoing a
change made anywhere else while Settings stood open. The test asserts that too: typing in the
prefix leaves the suffix as it was, and counts one broadcast rather than two.

**Still open, and deliberately not changed here:** `ExtensionHostService.refreshSnapshotJournal()`
does synchronous git control-file reads for every project on *any* settings change, and
`GeneralPreferencesViewController` rebuilds both sound menus — six directory scans — on any
settings change including its own. Coalescing the field hides that from typing; it does not make
either operation bounded, and both are still per-event filesystem work on the main actor.

## The MCP tool channel's second hop

`durable-sessions.md` (§3c) proposed the stdio bridge with one cost stated and deliberately not
measured: "the hop is a local socket and is not expected to be measurable, which is a claim the
rollout should check rather than assume." This is that check.

`MCPBridgeLaunchIntegrationTests.testStressTheBridgeHopAgainstTheDirectPortWhenEnabled` is the
fixture. It is gated by `THREADING_MCP_BRIDGE_HOP_STRESS=1` and, because a test plan sanitizes the
environment it launches with, it is run through the bundle directly:

```bash
xcodebuild -project Threading.xcodeproj -scheme Threading -testPlan Threading-Fast \
  -destination platform=macOS -configuration Debug -derivedDataPath <dd> build-for-testing
THREADING_MCP_BRIDGE_HOP_STRESS=1 \
  DYLD_LIBRARY_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/MacOS" \
  DYLD_FRAMEWORK_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/Frameworks" \
  xcrun xctest -XCTest \
    ThreadingTests.MCPBridgeLaunchIntegrationTests/testStressTheBridgeHopAgainstTheDirectPortWhenEnabled \
    "<dd>/Build/Products/Debug/Threading.app/Contents/PlugIns/ThreadingTests.xctest"
```

One `MCPServer` serves all five series, so every number below answers the *same* `tools/list` for
the same session. N = 200 per series; Debug; M-series; matched build, fixture and initial state.

### Measured, 2026-08-22, Debug, M-series

| Series | Median | p95 |
|---|---|---|
| Loopback port, `URLSession`, connection reused | 4.95 ms | 5.40 ms |
| Loopback port, new connection per request | 5.70 ms | 6.20 ms |
| **Unix rendezvous, raw POST, no bridge** | **4.78 ms** | **5.23 ms** |
| **Through the bridge** | **30.35 ms** | **31.47 ms** |
| Through the bridge, small reply (a forwarded `ping`) | 0.37 ms | 0.55 ms |

**The rendezvous is not the cost.** A raw unix POST of the identical request, opening a fresh
connection each time exactly as the bridge does, is 4.78 ms against the port's 4.95 ms. The socket
is as fast as the port, and connection setup is 0.75 ms of either. Whatever the bridge adds, it
does not add it by being a socket.

**The size of the reply is the cost.** `tools/list` is 234 KB — the whole catalogue with every
tool's schema — and it is the largest message this transport ever carries. A forwarded `ping`, at
39 bytes, costs **0.37 ms end to end through the bridge**, which is the "not measurable" the draft
predicted. A `tools/call` result is a sentence and behaves like the `ping`, not like the
catalogue.

Attributed with a temporary in-bridge probe around each phase of `forward` (removed afterwards),
for the 234 KB reply, medians:

| Phase | Before | After |
|---|---|---|
| Connect to the rendezvous | 0.044 ms | 0.039 ms |
| Send, then read the response head (the app's own work) | 4.69 ms | 4.56 ms |
| Read the 234 KB body | 2.04 ms | 2.00 ms |
| Write the 234 KB reply to stdout | 10.51 ms | **8.50 ms** |
| Cache the catalogue | 6.07 ms | **3.34 ms** |

Two fixes, both in `Targets/MCPBridge/`:

1. **The catalogue was written to disk on every reply.** `remember` re-encoded the result and ran
   `CatalogueCache.store` — a temporary file, a `chmod` and a `rename` — for each `initialize` and
   each `tools/list`, even though the answer is identical every time and the app announces
   `notifications/tools/list_changed` when it genuinely moves. It now compares against what was
   last successfully stored and writes only on a change. The comparison cannot be made on the raw
   reply, because every reply carries a different JSON-RPC `id`; it is made on the `result`
   canonicalised with `.sortedKeys`, and `CatalogueCache` writes and reloads in the same
   canonical form so a snapshot loaded at launch compares equal to the same catalogue fetched
   again. A failed store leaves the marker unchanged, so the next reply retries rather than
   remembering a write that never landed.
2. **stdout paid a per-element scan and a whole-message copy.** `BridgeOutput.writeLine` called
   `Data.contains(where:)` over the entire payload to look for a newline, then appended one byte
   to it — copying a quarter of a megabyte for that byte. The scan is now two `memchr` calls and
   the newline is a second `write(2)` under the same lock, which is what made the framing atomic
   in the first place.

**Bridge median 35.92 ms → 30.35 ms** for the catalogue listing; p95 36.79 ms → 31.47 ms. The
small-reply path was already 0.4 ms and is unchanged.

**The hop remains measurable for `tools/list`, and that is stated rather than rounded away.**
30.35 ms against 4.95 ms is a real six-fold difference on that one method. What is left is not the
socket: it is 8.5 ms to push 234 KB through a pipe, 3.3 ms to notice the catalogue has not changed,
and the client's own parse of the same 234 KB — costs a stdio MCP server pays by construction, and
which a client pays once or twice per session rather than per tool call. Moving the cache
comparison off the reply path was tried and reverted: it saves 3.3 ms on a once-per-session call
and breaks the invariant `MCPBridgeTests` asserts, that a reply implies the cache behind it is on
disk. If `tools/list` ever becomes hot, the fix is to stop re-parsing 234 KB to detect an unchanged
catalogue — compare the raw `result` slice of the reply instead — not to move the work later.


## Taking sessions back against starting them

`durable-sessions.md` §6 item 7 asks for the reattach path to be measured against a relaunch, and
the first thing this measurement owes is what it does **not** compare.

`PTYHostReattachDaemonTests.testStressReattachAgainstRelaunchWhenEnabled` is the fixture. It is
gated by `THREADING_PTY_HOST_REATTACH_STRESS=1` and, because a test plan sanitizes the environment
it launches with, it is run through the bundle directly:

```bash
xcodebuild -project Threading.xcodeproj -scheme Threading -testPlan Threading-Fast \
  -destination platform=macOS -configuration Debug -derivedDataPath <dd> build-for-testing
THREADING_PTY_HOST_REATTACH_STRESS=1 \
  DYLD_LIBRARY_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/MacOS" \
  DYLD_FRAMEWORK_PATH="<dd>/Build/Products/Debug/Threading.app/Contents/Frameworks" \
  xcrun xctest -XCTest \
    ThreadingTests.PTYHostReattachDaemonTests/testStressReattachAgainstRelaunchWhenEnabled \
    "<dd>/Build/Products/Debug/Threading.app/Contents/PlugIns/ThreadingTests.xctest"
```

`THREADING_PTY_HOST_REATTACH_STRESS_SESSIONS` and `..._RUNS` narrow it to one point; the defaults
are D14's N = 8 and five runs. Each series is the wall time from the first call to all eight
sessions holding a child pid, and the eight surfaces are built **before** the clock starts in every
series, because manufacturing a fixture is not the operation.

**Both sides run `/bin/sh -c cat`, and that is the limitation to state rather than bury.** A real
relaunch is `--resume` into an agent CLI, and that CLI's own boot is seconds against these
milliseconds — measuring it would be measuring Claude, not either path here. The relaunch also pays
`StartupRelaunchDefaults.staggerInterval`, one second per session, deliberately, so that N agent
boots do not contend; the reattach pays none of it, and none of it is in these numbers either. So
what follows is the *floor* of the difference between the two paths, not the difference.

### Measured, 2026-08-23, Debug, M-series, N = 8, median of 5

| Series | Run 1 | Run 2 |
|---|---|---|
| **Take eight back** — one connect, one `list`, eight `attach`es | **26.2 ms** | **26.8 ms** |
| Start eight in this process — today's relaunch with the agent's boot taken out | 30.6 ms | 24.9 ms |
| Start eight in the daemon — one connect and one `spawn` each | 54.6 ms | 52.6 ms |

**Taking eight sessions back costs about what starting eight bare children costs, and the
difference the feature actually buys is not in this table.** Roughly 3 ms per session either way:
the reattach is one shared `list` plus eight connects and attaches, and the in-process relaunch is
eight `forkpty`s. Spawning through the daemon is the dearer of the three because it is a connect
*and* a fork *and* a round trip, which is the cost the host-backed launch already pays and this
slice does not change.

What the feature buys is everything the fixture deliberately removes: the agent CLI never boots,
because it never stopped, and there is no stagger to spread because there is nothing to spread. On
a real store the relaunch of eight Claude sessions is bounded below by eight CLI starts and eight
seconds of deliberate spacing; the reattach of the same eight is the 26 ms above plus whatever the
replay costs, which is bounded by the ring — 512 KiB per session at worst, and the probe measured
a 1 MB ring's replay at 0.4 ms to first byte and 6.9 ms to complete.

**Nothing here was optimised.** The numbers are the first measurement of a path that had not been
measured, they are comfortably inside the interaction budget, and the slice ships with them as
found.


## Host-backed terminal input and activity latency

Measured 2026-08-26 after reports that Codex input echo and its `Working` repaint felt late on
host-backed PTYs. A five-second sample of the shipping app caught the main thread in
`PTYHostTerminalLink.flush` → `TerminalSession.hostDelivery` →
`EmojiFixedTerminalView.feedFromHost` → `TerminalRenderOwner.feed`, amid AppKit drawing. The
daemon was about 0.1% CPU in the same observation. The socket and daemon were not saturated; the
host-backed path had moved parser work onto main, unlike SwiftTerm's local-process path.

The scaling contract is now:

- The external source is terminal output, unbounded over a session and delivered in wire frames
  no larger than 64 KiB. Daemon framing, ring retention and fan-out remain O(bytes).
- The launchd job remains `ProcessType = Interactive`. Daemon state and per-session IO queues are
  `userInitiated`: immediate causal work, but shared with detached sessions that have no visible
  animation deadline.
- An attached app client's serial queue is `userInteractive`. Steady live frames parse there in
  wire order through SwiftTerm's checked `TerminalFeedSender`; parser work is O(bytes) and never
  waits for a main-actor turn.
- Main receives one coalesced activity/raw-output report per burst plus SwiftTerm's render
  publication. It does not parse ordinary live bytes. The bounded exception is the first
  post-attach handoff, which follows authoritative grid adoption on main because the current wire
  has no replay-length boundary. It takes one finite backlog and holds the serial transport queue
  behind it instead of draining a continuously growing stream on main.
- A parser is lifetime-gated per link. Replacing, detaching or ending a link invalidates that gate
  before late output can enter a replacement emulator.

The deterministic regression test holds the main actor on its current turn while a fake transport
delivers `codex repaint` synchronously. Before the change, diagnostics reported 0 of 13 bytes
parsed until the main run loop advanced. After it, all 13 are parsed before that turn ends, while
the activity callback remains queued for the coalesced main delivery. This proves queue ownership,
not a wall-clock latency number. The focused parsing and QoS tests, the fake-link host-session
suite, and the real-daemon attach/detach/replay suites cover the shipping path. A fresh sample of
the patched product shell remains the final measurement after the build is installed.


## Worktree execution observation

The terminal-output edge is unbounded in frequency and descendant process count comes from build
tools, so detecting a tool-local `cd` cannot walk processes in that callback. The shipping path
does one main-actor dictionary replacement, coalesces all sessions that produced output, and runs
at most one system process-table walk per second on a utility queue. Parentage is built once for
the batch. Each session retains only its newest eight descendants and therefore performs at most
eight cwd syscalls per scan, even when a compiler or build system fans out into thousands of
workers. The expected case is one to ten simultaneously working chats; the stress case is every
live chat producing output together, which still pays one table walk plus eight bounded reads per
chat and returns only path strings to main.

`SessionExecutionProcessSnapshot` has the deterministic stress fixture: forty direct children, a
grandchild and a reachable parent cycle produce the four newest candidates in order without
growing the retained result or looping. `SessionExecutionLocusTests` separately prove that one
same-repository checkout is actionable, two are ambiguous, and runtimes without lifecycle cwd
hooks still reach the observer. A live product-shell sample remains unverified; the code path is
rate- and cardinality-bounded rather than justified by an unmeasured claim that process trees are
small.


## Main-actor latency audit (2026-09-04)

Swift's concurrency checker answers isolation and transfer safety. It cannot know that
`Data(contentsOf:)`, `JSONDecoder.decode`, a pipe `write`, symlink resolution, or an innocent
looking store accessor can occupy the main actor for hundreds of milliseconds. The project uses
Swift 5 language mode with complete strict-concurrency checking; switching the whole dependency
graph to Swift 6 is currently blocked by the pinned WasmKit package, and would not identify these
latency defects in either case.

The audit combined the existing semantic spans with a shipping-process `sample`, then traced the
main-actor callees structurally. The sample's dominant actionable stacks were terminal/native
conversation stream handling (about 1,009 ms of sampled main-thread stack presence) and duplicate
session-title propagation (about 690 ms). The source pass also found synchronous audit-ledger
writes, heartbeat writes, broad settings invalidation, repeated project-path resolution, and the
existing family of attachment, browser-baseline, display-image and persistence stores whose APIs
still permit filesystem or codec work from main.

The implemented ownership rules are:

- ACP, Codex and Claude native conversations share `AgentStreamTransport`. Pipe reads, bounded
  newline framing, primary parsing, JSON serialization, stdin writes and bounded stderr capture
  have dedicated serial worker lanes. Main receives complete typed events only. A newline-free
  line is capped at 16 MiB and pending writes at 64, so neither stream direction can create an
  unbounded buffer. The `FileHandle` readiness callback consumes available bytes before it
  returns and queues only parsing/capture: postponing the read itself can leave a pipe readable
  without another readiness edge, deadlocking a child whose stderr exceeds the pipe capacity.
- Each iOS session WebSocket has one ordered JSON encoding lane. Main-actor admission is O(1),
  pending messages are capped at 64, and the serial worker is the only owner of encoding for both
  production client frames and the demo's synthesized server frames. Advancing the connection
  generation retires queued work before it can reach a replacement socket. Main receives only an
  immutable encoded string or a typed failure; `RemoteWireEncodingLaneTests` pin worker-thread
  execution, admission order, generation retirement and backpressure.
- The execution-audit live record APIs enqueue one ordered transaction containing correlation,
  sanitization, hashing, rotation and append. The synchronous append remains only for callers
  that explicitly need its returned seal (tests and support tooling); a following read drains the
  writer lane and therefore preserves read-after-record behavior.
- The main-queue heartbeat still represents UI liveness, but admits a coalesced utility-writer
  stamp instead of performing the atomic file replacement itself.
- A provider title change mutates `ProjectStore` once. The typed `ProjectsDidChange` impact is the
  only presentation fan-out, and `MainWindowController` refreshes only the title or script context
  named by that impact. Settings changes likewise carry the persisted key, so the General pane
  rebuilds sound menus only for sound keys and the extension snapshot journal no longer rewrites
  for settings it does not consume.
- Project-script activation rejects an unchanged standardized path before paying symlink
  resolution. The canonical result remains the authority when the requested spelling changed.

`scripts/main_actor_latency_lint.swift` is a SwiftSyntax build check for explicit and inherited
main-actor scopes. A repository-wide type prepass follows global-actor inheritance into separately
declared feature extensions; those files are not an isolation escape hatch. The check recognizes
detached/queue worker closures and ratchets synchronous file, directory, symlink, serialization,
bitmap and blocking APIs by operation. The checked-in counts in
`scripts/config/main-actor-latency.json` are an inventory of legacy debt: any new occurrence or new
API category fails an ordinary build. Reducing a count is welcome; raising one requires a measured
exception and updates this audit. This complements strict concurrency rather than pretending an
actor annotation is a performance boundary.

For uninstrumented stalls, Debug builds accept `THREADING_STALL_SAMPLE=1`. The watchdog launches at
most one `/usr/bin/sample` capture at a time on its utility lane and files the bounded result beside
the semantic incident. It is off by default and absent from the Release path. This turns the next
otherwise anonymous 250 ms stall into a stack without requiring Instruments to have been attached
beforehand.

## Explicit Codex model refresh (2026-09-06)

The refresh in Agents & Accounts and the command palette normally visits 1–8 accounts with
roughly 8–30 models each. It admits at most 32 accounts, launches one helper at a time, and limits
each helper to 25 seconds, 2 MiB of output, and eight pages of 64 models. Account discovery,
process and pipe work, parsing, and catalog persistence run off the main actor. Main receives
one progress value per account and restamps one virtual Settings row, without rebuilding the
account editor or materializing model rows. Pickers read the store's locked value projection;
authentication invalidation adds a file-identity stat beside the existing catalog identity check.

The deterministic Debug child fixture returned 512 models over eight pages in 75 ms including
process startup. The opt-in installed-CLI check returned seven models in 925 ms. These are
observations, not timing assertions; the ordinary tests assert the cardinality limits, partial
failure behavior, and bounded protocol refusals.

The first pipe implementation used Foundation's `read(upToCount:)`, which waited for a full
16 KiB while the RPC server waited for the next request. Even the two-model fixture hit the
25-second deadline. One bounded `read` syscall consumes a short response immediately. The
oversized-output fixture then exposed a second problem: scanning the entire accumulated buffer
for a newline after every read was quadratic. The parser now remembers the scanned prefix, so
each byte is examined once before the aggregate output ceiling refuses the response. Helper
termination and process-group reaping happen on every exit path.

### Browser annotation hover bounds

Annotation hover is a pointer-frequency operation (typically 60–120 events/second) over pages
that may contain hundreds to tens of thousands of nodes. Native code retains one active WebKit
probe and one latest queued position, plus one target value; stale revisions cannot repaint.
Picking follows at most 12 frame contexts, 12 shadow roots per hit and 32 component ancestors.
Label extraction visits at most 128 nodes per source and eight ARIA references, reads at most
512 characters from an attribute and returns 80 characters. The former `innerText`/form-value
fallback could read an entire container despite truncating the result afterward. No DOM tree is
materialized in AppKit, and drawing touches only the target outline and visible existing pins.
The shipping-WebKit annotation integration fixture covers the selection and geometry contract.

Measured in Debug on 2026-09-07 through `BrowserAgentBridgeIntegrationTests/
testAnnotationTargetProbeNamesTheComponentUnderThePointer` with
`THREADING_STRESS=annotation-hover`: 11 probes per case, fixture construction/layout excluded,
WebKit execution timed separately from IPC. At 100 nodes both name paths had a 0 ms median
(the timer has approximately 1 ms resolution); maxima were 1 ms before and 0 ms after. At
10,000 nodes the former name read measured 3 ms median/max; bounded extraction measured below
1 ms median and 1 ms max. The matched baseline substitutes only the removed `innerText` name
read into the same production probe. These are warm Debug hover measurements, not launch or
Release results. The regression also holds snapshot-independent picking, precise shadow targets,
scaled-frame geometry and non-disclosure of form values.


### Iframe annotation geometry, 2026-09-11

The native pin model previously subtracted only the outer document's scroll offset. In the live
WebKit fixture, scrolling a nested iframe by 60 CSS pixels under scales 0.75 and 0.8 left the pin
at y=222 instead of y=186; the baseline regression failed. Frame notes now retain weak targets in
WebKit's isolated world and resolve their own bounded ancestor chain (12 frames, 32 component
ancestors), without searching the page's frame or DOM collections. Native state is still scalar
pin geometry and one editor; no per-note view trees or note text enter WebKit.

The contract is 5–10 ordinary notes and a 200-note stress batch. Scroll, resize and relevant DOM
mutations share one event-triggered RAF invalidation, with a single 100 ms timeout fallback for
occluded renderers. This matters for agent use too: a locked display paused RAF, and the first
native tests retained old coordinates until another operation forced a refresh. The fallback
fixed that reproduction without introducing a repeating poll. One native geometry call runs at a
time, with one pending invalidation. Deleting the last anchor disconnects mutation observation.

`BrowserAnnotationEditingTests.testIframeAnchorResolutionHandlesTwoHundredPins` resolves 200
pins through two scaled frames and an open shadow root, then proves anchor and observer cleanup.
Five Debug WebKit samples on macOS 26.5 measured 1 ms median / 1 ms maximum in the final focused
run (an earlier run was 1 / 2 ms). This measures JavaScript geometry resolution, excluding fixture
construction, bridge transport, native drawing and compositor latency. The shipping native
scroll/edit/clip/replacement tests passed with the display locked; keyboard activation and live
compositor timing require an unlocked display and are separate checks.

### Work-recency invalidation (2026-09-12)

A work boundary carries one session identity. The durable write is the existing coalesced exact-row
save; remote projection adds no file lookup, timer, or duplicate runtime broadcast. Recent ordering
rebuilds only the owning project's sidebar projection and adopts existing outline identities.
Supervision reorders only its already scoped children. These are boundary events, never token events.

Navigation keeps its immutable index on one detached build lane. A burst updates value metadata and
requests one successor build; it cannot launch an unbounded set of concurrent full index builders.
Transcript search similarly serializes ingestion, but work events reconcile only their changed source
set. A full structural snapshot and later work updates cannot race inside the reentrant SQLite actor.
One pending value per session coalesces repeated events. Account discovery has its own serial lane,
retaining pending accounts rather than cancelling and losing another account’s result. The existing bounded JSONL passes still yield
for queries; neither search opening nor row projection starts a filesystem walk.

The retained-catalogue fixtures for this repair are 1,000 sessions normally and 5,000 at stress,
with 32 owner clients. Both opt-in runs passed with exactly one shared catalogue build; cached
encoded-body lookup measured 0.004 ms at both sizes. These fixtures exercise snapshot fan-out;
`RemoteSessionRecencyTests` separately pins one publication for a work-only steering event, and
`SidebarRowAnimationTests` drives a completion through the actual event and outline without a
manual reload. The complete validation record is in
[`session-time-audit-2026-09-12.md`](../research/session-time-audit-2026-09-12.md).

### Agent extension install trust

The expected set is 1–10 trusted chats; stress is 1,000. Install calls check an in-memory dictionary
in O(1), without scanning sessions or grants. User grant/revoke events are rare and persist a
property-list dictionary through PreferenceStore; package inspection, update planning and copying
remain on existing bounded workers. The Settings section stores grant values, truncates captured
names at 160 characters, and materializes only viewport rows in the existing table. Revocation
removes only the affected trust rows without remounting sibling or installed package controls.
`AgentExtensionInstallTrustTests/testStressTrustListKeepsOnlyViewportControls` exercises 1,000
grants when `THREADING_STRESS=1`. No grant count determines
how many AppKit controls are built at page mount.

A Debug stress run on 2026-09-12 retained nine Revoke controls for 1,000 grants, mounted the
settings fixture in 40 ms and revoked one grant in 11 ms. The two-grant case retained two
controls and revoked in 2 ms; its first mount included cold framework initialization (118 ms),
so those mount timings are not a before/after speed comparison. The regression boundary is
viewport-sized control ownership and exact per-chat revocation, not a machine-specific timing.
