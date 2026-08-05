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
- each git child process;
- Git Review's main-thread render and file-row construction;
- the debounced attachment scan of a terminal's rendered buffer.

Do not add spans per diff line, table cell, terminal frame, token, or streamed event. A profiler
that changes the hot path is measuring itself. Prefer a nested span only where it separates two
actionable owners, such as background parsing from main-thread view construction.

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

## Command-line workflow

`scripts/profile_threading.sh` never launches the Instruments UI:

```bash
# Deterministic Git Review file-index workload.
scripts/profile_threading.sh git-stress

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

# Deterministic whole-window drag with chrome, terminal-grid and Claude-repaint phases.
scripts/profile_threading.sh window-resize-stress

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

# Routine sweep: Git, conversation, subagent, sidebar, file-tree and window-resize fixtures, sample,
# Time Profiler, Animation Hitches, and Allocations.
scripts/profile_threading.sh full 15 Threading

# Release/investigation sweep: full plus massive, unresolved-turn and multi-conversation workloads,
# CPU Profiler, File Activity, Leaks, Swift Concurrency, System Trace, and Power Profiler.
scripts/profile_threading.sh full+ 15 Threading

# Locate recent CLI and built-in artifacts.
scripts/profile_threading.sh latest
```

Each `xctrace` capture attaches to the running process for the requested duration. Exercise the
same pane action during each capture. Output defaults to `/tmp/threading-profiles`; set
`THREADING_PROFILE_OUTPUT` to retain it elsewhere. Command-line Instruments can still require
macOS Developer Tools authorization the first time, but it requires no interactive Instruments
launch or template setup.

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
positioning. That initial UIKit mount is now the next measured cold-open target. Standard dashboard
and settings screens still use a hosting controller and should migrate only when their own traces
justify it.

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
attachment scope became configurable, and both sides of that setting put new work on the **main
thread** — the observer scans on the queue the window draws on, so the scan's cost is a stall's
cost.

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

What remains is the regex pass itself, which is why the shipped column is flat at 20–55 ms
whatever the buffer holds: the `absent` row does no filesystem work at all and still costs 23 ms.
That is the next target if this ever needs one — the pass is bounded and debounced, but it is
still tens of milliseconds on the queue the window draws on, which is why `attachments.scan` is a
recorded span rather than something a stall snapshot has to guess at.

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
model reduction, presentation render, viewport materialization, layout, per-row mount and scroll
percentiles. The harness mounts every logical presentation row one at a time to expose a single
pathological row, then retains only the final 18 as its representative viewport; its `elapsed_ms`
therefore includes diagnostic work that production first paint does not do.

The regression fixture was a 457 KB Claude child transcript with 91 replay events, 47 timeline
rows, 44 tool calls/results and one 13 KB final Markdown answer. The old retained stack eagerly
built all 49 presented rows, including hidden tool bodies: 1,286 descendants, 187 ms render,
494 ms layout, 202 ms scroll p95 and 29.9 MB renderer growth. The same Debug fixture after the
change measures 59 cheap presentation identities but only 18 materialized rows, 247 descendants,
13.0 ms render, 10.6 ms viewport materialization, 35.1 ms test-document layout, 10.6 ms row-mount
p95, 15.7 ms scroll p95 and 15.2 MB renderer growth. Its 384 ms exhaustive test elapsed is not a
384 ms first paint: render plus representative viewport mount/layout is about 59 ms, and AppKit
can spread cold height discovery across frames.

The exact fixture also spends about 49 ms reducing provider events into tool summaries, edit
previews and conversation rows. That reduction is pure model work and now runs on a
user-initiated worker; the main actor installs its finished `ConversationTimeline` with one
assignment and one notification. `model_ms` is therefore worker wall time and the stress line
states `model_thread=worker`. A per-child generation rejects an older reduction if a growing
provider file triggers a newer replacement before it finishes.

The load-bearing boundary is two levels of virtualization. The selected transcript is an
`NSTableView`, collapsed tool runs do not construct their individual rows, and a long assistant
answer is split at parsed Markdown block boundaries so one visible paragraph or table does not
attach the whole answer's constraint tree. Disclosure state belongs to the controller and rows
are inserted or removed from the cheap presentation model. Do not replace this with hidden stack
children: hidden AppKit views still participate in the layout engine.

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

## Project sidebar stress target

`SidebarTreeBuilderTests.testStressProjectSidebarWhenEnabled` seeds a throwaway `ProjectStore`
database and loads the production `ProjectSidebarViewController`. It measures cold load and layout,
same-shape content refresh, collapse/re-expand, a reveal through branch and nested side-chat levels,
one targeted title event, 250 repeated row updates, and the pure tree builder. The fixture fixes the
session order and grouping defaults and never reads or changes the user's projects.

`scripts/profile_threading.sh sidebar-stress` runs 500, 1,000, 2,000 and 5,000 sessions in fresh
`xctest` processes. The profiler's DerivedData lives inside that run's artifact directory: parallel
developer builds cannot lock its build database, while the deterministic workloads in `full`
reuse the same isolated build. Results are `THREADING_PERF project-sidebar` lines in
`project-sidebar-stress.log`.

At 5,000 sessions the outline contains 5,120 logical rows but materializes only 21 cells, so row-view
virtualization is already doing its job. The measured fixes are above that layer:

- rendered project, session, owner and ancestor indexes replace repeated flattened and recursive
  node scans;
- `ProjectStore` maintains project/session location indexes across structural edits, making the
  model lookup used by every live row constant-time;
- content refresh touches only the viewport, since an off-screen row reads current store state when
  AppKit eventually asks for its view;
- `ProjectsDidChange` carries a session-row impact for agent titles, unless name ordering means the
  title can move the row. This keeps the ordinary title path out of the complete builder;
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

`sidebar.outline.apply-structure` and `sidebar.disclosure.persist` keep the remaining AppKit and
SQLite costs separable in a trace. A recursive `expandChildren` experiment remains reverted: before
the persistence cause was isolated it made both paths slightly slower. The current roughly 200 ms
cold total at this deliberately extreme scale does not justify replacing `NSOutlineView`; a
flattened visible-row table remains an option only if a future product target demands substantially
less than that.

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
