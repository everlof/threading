# Performance Measurement

Self-profiling, command-line captures, and repeatable regression workloads.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

## The layers answer different questions

No one profiler should try to answer everything:

| Layer | What it answers | Artifact |
|---|---|---|
| `PerformanceRecorder` | Which Threading operation was in flight, and for how long? | OS signposts plus bounded Chrome Trace JSON |
| `MainThreadStallMonitor` | Did the main queue stop servicing events for at least 250 ms? | Automatic Chrome Trace snapshot |
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
100 ms. If one is unanswered for 250 ms, it requests a trace immediately. Once the queue answers,
it adds the full `main-thread.stall` interval. Automatic exports have a 30-second cooldown and
are done on a utility queue.

The watchdog deliberately does not walk or suspend the main thread. Stack collection belongs to
Apple's supported `sample` and `xctrace` tools; the watchdog's reliable job is to preserve the
semantic context that existed before those tools were attached.

## MetricKit

`MetricKitDiagnostics` subscribes only in a real app launch, never in the hosted XCTest process.
It persists both current callbacks and Apple's `pastPayloads`/`pastDiagnosticPayloads`, capped at
20 of each kind. Delivery is delayed, normally aggregates a prior period, and is not guaranteed,
so absence of a payload is not evidence that a run was healthy. The immediate recorder and
MetricKit are complements.

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

The heuristic is cardinality × row richness × mutation frequency. If two are non-trivial, use a
value model, viewport ownership, stable identity, and a stress fixture by default. A small
fixed-schema form remains free to use a retained stack and wholesale rebuild; recycled-cell
cleanup and one-controller-for-another lifecycle replacement are also not findings by themselves.

### Mobile remote dashboard scaling contract

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

Before this boundary, one visible dashboard issued `/api/me` every three seconds: 1,200 requests
per hour and about 24,000 over 20 visible hours, even with no changes. The healthy steady state is
now zero repeated REST requests: one activation/foreground snapshot, scoped deltas for row
changes, and a coalesced snapshot only for structural changes or socket recovery.

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
| Resolved | Settings search results | An installed extension can contribute up to eight searchable pages, so the 256-package ceiling can produce 2,048 extension results before built-ins. Results are value rows; a query-only change updates the two visible labels in place and preserves the exact clip origin. |
| Resolved | Git Review watched refresh | A build can expose ~9,000 generated files / ~80,000 changed lines and refresh repeatedly. The pane now reconciles stable paths in place, anchors by path + within-row offset, and defers model/height mutations until live scrolling ends. A scroller-thumb drag uses geometry-preserving identity rows and materializes full TextKit only for the resting viewport. |
| Resolved | Git Review during live resize | The 8,985-file fixture now drives 48 distinct widths through the real layout callback. Complete-index height invalidation averages 6.08 ms, with 6.66 ms p95 and 10.49 ms max, while preserving correct offscreen wrapping estimates and scrollbar extent. |
| Resolved | Account settings cold discovery | A fresh-process fixture separates real home-directory/login-marker/shell-alias discovery from page construction. Five accounts take 6.61 ms to discover, 12.31 ms to render and 8.14 ms to lay out; the seven-second cache makes subsequent callers lock-cheap. |
| Resolved | Usage dashboard | The report scans off-main with per-source metadata caches, aggregates to 90-day cells and globally deduplicates cached plus fresh records. The breakdown uses virtual table rows, the 180-day journal loads through an actor, and both history analysis and the reusable chart enforce adversarial point budgets. The million-record profile and measured gates live in [`usage-dashboard.md`](usage-dashboard.md#scaling-gate-and-measurements). |
| Resolved | Attachment preview cold open | The pane installs only the selected format's surface on first use, and its document boundary independently installs PDFKit or Quick Look only when that renderer is selected. Regression coverage pins the unused renderers as absent. |
| Resolved | Agent charts | `ChartSpec` caps the product at 240 marks and one drawn chart view owns prepared geometry. Maximum-contract decode/update work stays below 0.45 ms per spec and synchronous paint below 5.5 ms per sampled frame. |

Installed-extension discovery has a separate refusal boundary from presentation: enumeration stops
one entry past 1,024 visible names and inventory refuses more than 256 package directories before
loading any manifest. Those safety/cardinality ceilings now feed a viewport-owned preferences
table; they are not used as an excuse to retain 256 AppKit cards.

The same sweep found bounded uses that should not be "fixed" merely because they match a text
search: Advanced, General, Profile and most Keyboard settings are fixed-schema; Keyboard already
branches before constructing collapsed command detail; Usage virtualizes repeating breakdown rows
and bounds both retained report cells and chart geometry;
File and project trees use virtual outline cells; conversation Markdown uses virtual block rows;
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

`SettingsDisclosureRenderTests.testStressArchivedPreferencesWhenEnabled` manufactures its archive
before the clock starts, then reports controller/view load, model render, first layout, disclosure,
jump to the end, an unchanged project event at that end, hierarchy size and footprint. It also
asserts the clip origin is unchanged. Run both themes with
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

# Deterministic iOS cold open of the newest 160 rows, then deep scroll with 5,000 loaded rows.
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
`THREADING_STARTUP_PROFILE_SESSIONS` raises the isolated database snapshot to the requested session
cardinality (up to 50,000) by cloning a schema-valid production row with unique identity and
position fields; an already-larger snapshot is reported and left intact, and the live database is
never edited.
Set `THREADING_STARTUP_PROFILE_DERIVED_DATA` to a trusted existing DerivedData directory for fast
incremental tuning runs; omitting it keeps each retained artifact self-contained.
The startup build explicitly disables code coverage and builds only the measured host architecture.
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

The conversation-specific iOS command uses a DEBUG-only fixture and an automated display-link
scroll driver, so it needs no manual interaction. Its Debug app is explicitly compiled with `-O`:
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
page, repeated reconnect hydration, a live delta, and revision-gap resync. These deterministic
numbers exclude real network round-trip time; use a device trace and a real paired connection when
latency, radio, thermal, or GPU behavior is the question.

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
| Revision-gap resync, newest 160 rows | 1.82 ms |
| iOS remote cold open, newest 160 rows | 507.24 ms first paint |
| iOS fully loaded 5,000-row stress view | 2,081.56–2,341.54 ms first paint |
| iOS exact jump to first row | 76.45–157.32 ms |
| iOS automated deep scroll | 52.66–67.50 ms work p50 / 86.01–130.60 ms p95 |
| iOS deep-scroll frame gap | 100.04–149.93 ms p95; every observed frame over 33.3 ms |
| Mac reopen, 1,000 turns / 6,000 rows | 154.60 ms |
| Mac exact deep jump | 19.25 ms |

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
initialize dictation, and dynamically load AssistantServices. Draft restoration now compares first.
A real saved draft is still installed synchronously; the overwhelmingly common empty state does no
text mutation and leaves dictation cold until the composer genuinely needs it.

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

### Large-store session decoding

The retained startup cardinality control made the persistence scaling boundary reproducible. A
Release launch against the isolated 5,000-session snapshot initially measured `state_ms` at
**163.539 / 141.317 / 120.729 ms** (median **141.317 ms**), while the matched App Launch trace
reported **120.501 ms**. Time Profiler attributed **54.641 ms** of sampled weight beneath
`ProjectDatabase.load` to `JSONDecoder.decode`; **39.641 ms** was the `AgentSession` decoder and
**10.439 ms** was SQLite stepping. The database was paying the top-level JSON parser's fixed cost
once for every row.

Large loads now retain no more than a 1,024-row wave and decode 256-row JSON arrays on bounded
parallel workers: half the active processor count, capped at four. Results join and are consumed
serially in database order. Array decode failure retries only its 256-row batch one row at a time,
preserving the exact corrupt-row diagnosis rather than turning a speedup into a quarantine mystery.
The 512-row entry threshold is load-bearing: an initial implementation batched the 127-session
ordinary fixture and regressed its median `state_ms` to **48.926 ms**. Keeping smaller stores on
the original decoder restored **33.385 / 24.702 / 27.499 ms** (median **27.499 ms**), versus the
nearby 122-session reference median of **27.349 ms**.

With that gate, the final 5,000-session direct lines were **103.996 / 87.823 / 696.891 ms**. The
last line was discarded as an environmental outlier only because every startup phase inflated
during the disk-full, multi-build interval; the raw triplet remains recorded here. The retained
direct median is therefore **103.996 ms**, **26.4% / 37.321 ms** below baseline, and the matched
trace measured **92.191 ms** versus **120.501 ms**. Total settled-frame time is intentionally not
claimed as improved: native-window and machine-load variance dominated it. Boundary tests cover
the row-at-a-time path at 511 rows, ordering across batch and wave boundaries, and exact failure
identity inside a valid-JSON batch.

## Display-pane transition beside a live TUI

Opening the right pane originally performed two consecutive 200 ms transitions: first the split
item uncollapsed to its chrome floor, then its remembered divider width was restored. Every pixel
width along both motions became a SwiftTerm character-grid resize, emulator reflow, PTY resize and
SIGWINCH. A full-screen Codex or Claude process answers each SIGWINCH by repainting its alternate
screen, so a visually small motion multiplied into layout plus process output at animation-frame
frequency.

The remembered divider position is installed in the same geometry transaction as the uncollapse,
so there is no second restoration motion. More importantly, terminal-backed sessions take the
immediate split route even when the caller requests animation. That commits the one useful final
width without blocking the main thread on a backing-tree animation or manufacturing intermediate
terminal grids. Native conversation surfaces retain the standard motion. This is a presentation
policy at the pane boundary, not a SwiftTerm resize suppression: terminal frame, emulator, PTY,
accessibility, search and scroller state still follow the one final geometry normally.

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
and grows the bounded cache by no more blocks than the viewport requested.

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

The exact provider fixture exposed one more, independent cost. Its final settings inventory is a
large two-column Markdown table; the general renderer represented every row as a horizontal stack,
every cell as a wrapper, and every value with a constraint graph. The virtual transcript's settled-
width path now uses `ThemedDocumentTableView`: selectable cell labels are measured once and placed
directly, while the design component draws the themed header and separators, forwards vertical
wheel momentum to the transcript and reflows when the pane width changes. The general Markdown
path remains unchanged where no settled width is known.

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
only aggregate event, model-row, materialized-row, presentation-row, measured-height and
folded-turn counts, so traces and Points of Interest captures can correlate the same semantic
interval with AppKit stacks without recording conversation content.

- replay rebuilds the minimap, conversation controls, and remote snapshot once at its boundary,
  rather than once for every prefix of the transcript;
- the presentation is a view-based table. The full timeline and stable presentation identities
  remain resident, while Markdown/tool views exist only in reusable hosts around the viewport;
- replay mutates the timeline and presentation model, then reloads the table once. Fold expansion
  inserts identities and collapse removes them; neither path retains an off-screen constraint tree;
- AppKit owns automatic row-height estimation/caching; the controller invalidates affected rows
  and clears its measured-identity mirror when the readable width changes. Tool, user-message and
  turn disclosure state is held outside recyclable views. Exact jumps therefore do not require a
  target view to exist and correct after the landing.

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
clearing its diagnostic cache, timeline rows use the existing identity index, and streaming uses
the tail directly.

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

### Unresolved active-turn edge

Settled-history replay does not cover the renderer's other extreme: a single current turn whose
tool rows must remain individually visible and addressable until the terminal event arrives.
`ConversationRenderTests.testStressActiveConversationTurnWhenEnabled` starts after a mixed settled
history, appends 25, 100 or 500 tool calls in ten-row batches, streams 250 text deltas, attaches
every result in reverse identity order, then settles and folds the turn. It verifies an exact jump
to a middle tool while the turn is live, an exact jump to the final answer after folding, correct
result identity, minimap settlement, and a working set below 40 native row views. The default sweep
also combines 1,000 settled turns with 500 live tools to expose any transcript-depth dependency.

Three fresh-process 100-turn runs and the combined depth edge measured:

| Settled turns | Live tools | Append batch p95 | Result batch p95 | Settle + fold | Middle jump | Peak delta | Live row views |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 25 | 2.4–2.5 ms | 2.7–2.9 ms | 16–18 ms | 39–42 ms | 9.3 MB | 20 |
| 100 | 100 | 2.4–3.0 ms | 2.7–3.1 ms | 16–31 ms | 41–46 ms | 12.1–12.4 MB | 21 |
| 100 | 500 | 2.3–2.9 ms | 2.2–2.9 ms | 17–19 ms | 41–46 ms | 34.0–34.3 MB | 21 |
| 1,000 | 500 | 2.9 ms | 2.5 ms | 33 ms | 61 ms | 33.9 MB | 21 |

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
  edge. The measurement callback now validates its captured table row and identity directly.

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

## Project sidebar stress target

`SidebarTreeBuilderTests.testStressProjectSidebarWhenEnabled` seeds a throwaway `ProjectStore`
database and loads the production `ProjectSidebarViewController`. It measures cold load and layout,
same-shape content refresh, collapse/re-expand, a reveal through branch and nested side-chat levels,
one targeted title event, 250 repeated row updates, and the pure tree builder. The fixture fixes the
grouping defaults, parameterizes manual/recent/name order, and never reads or changes the user's
projects. It also asserts that the expanded outline contains exactly as many rows as the pure tree;
this catches an ancestor that a sort order accidentally left closed, not just slow work.

The cold fixture follows `MainWindowController`'s production lifecycle: load the deferred sidebar
shell, give it its final 300 × 720 geometry, cross the explicit initial-tree mount boundary, then
perform final layout. Shell construction and shell layout are reported separately from tree mount,
because fresh-process AppKit initialization is variable and is not sidebar work. Keep small semantic
tests beside this large fixture. The persisted-closed-project case, nested side-chat ordering, exact
row count, selection, and reveal assertions prevent a faster result from silently changing what is
expanded or addressable.

`scripts/profile_threading.sh sidebar-stress` runs manual order at 500, 1,000, 2,000 and 5,000
sessions, plus recent-activity and name order at 5,000, in fresh `xctest` processes.
`THREADING_SIDEBAR_STRESS_ORDER`, `..._PROJECTS`, and `..._SESSIONS` narrow it to one point. The
profiler's DerivedData lives inside that run's artifact directory: parallel developer builds cannot
lock its build database, while the deterministic workloads in `full` reuse the same isolated
build. Results are `THREADING_PERF project-sidebar` lines in `project-sidebar-stress.log`.

At 5,000 sessions the outline contains 5,120 logical rows but materializes only 23 cells, so row-view
virtualization is already doing its job. The measured fixes are above that layer:

- rendered project, session, owner and ancestor indexes replace repeated flattened and recursive
  node scans;
- `ProjectStore` maintains project/session location indexes across structural edits, making the
  model lookup used by every live row constant-time;
- content refresh touches only the viewport, since an off-screen row reads current store state when
  AppKit eventually asks for its view;
- `ProjectsDidChange` carries a session-row impact for ordinary title repainting and a
  session-order impact under Name order. The latter rebuilds, adopts and diffs only the affected
  project's subtree; an identity-set guard falls back to the complete builder if a supposedly
  title-only event ever adds or removes a row;
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
a trace. The earlier recursive `expandChildren` experiment was initially reverted because the old
fixture made it look slower. With persisted disclosure fixed and the production lifecycle in the
fixture, batching the first expansion is now retained. A focused semantic test also caught and fixed
two adjacent disclosure errors: a lone root project had ignored persisted closure, and groups below
a project opened later did not regain their default-open state. A flattened visible-row table
remains an option only if a future product target demands substantially less than the now-bounded
AppKit mount and resize phases.

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

## 2026-08-09 — command and workspace-file interactive bounds

The command palette and file mentions cross both scaling axes: extension/file cardinality grows,
and filtering runs at keystroke frequency. Their implementation-time gate is explicit:

- command catalogs filter off-main, cancel superseded work, check cancellation during the pass,
  and hand the main actor at most 100 value rows for a virtual table;
- workspace discovery uses `git ls-files -co --exclude-standard -z` once per execution checkout,
  never recursive enumeration per keystroke; the queue-confined index admits at most 100,000
  contained regular paths and 16 MiB of Git output, cancels superseded queued queries, and returns
  at most 64 relative references;
- send-time validation deliberately refreshes the roster rather than trusting the completion
  cache, which is why saved drafts detect deletes and renames;
- the stress fixtures exercise 25,000 commands, 50,000 matching paths, result caps, and refusal
  just past the 100,000-path index boundary. These are correctness workloads rather than timing
  thresholds: CI variance must not turn a bounded architecture into a flaky stopwatch assertion.
