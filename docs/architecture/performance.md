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
- Git Review's end-to-end load-and-render;
- Git reader queue wait plus work;
- each git child process;
- Git Review's main-thread render and file-row construction.

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

# Lightweight stacks from an already-running app.
scripts/profile_threading.sh sample 15 Threading

# One Instruments template from the command line.
scripts/profile_threading.sh trace "Time Profiler" 15 Threading

# Routine sweep: Git fixture, sample, Time Profiler, Animation Hitches, Allocations.
scripts/profile_threading.sh full 15 Threading

# Release/investigation sweep: full plus CPU Profiler, File Activity, Leaks,
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
the original scroll behavior. Opening the diff at deterministic row 777 of 1,000 takes 6 ms;
the fixture also asserts that the row still carries its exact new-file editor line.

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
