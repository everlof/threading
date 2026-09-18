# Spike: an `AppKit` module of our own, on Linux

> **A spike, not a proposal.** It exists to replace one guess with one measurement, and it is
> wired to nothing: no Xcode target references it, no gate runs it, and the macOS build does not
> know it is here. `docs/feature-drafts/linux-host-runtime.md` is still the decision record; this
> directory is evidence for one paragraph of it.

## The question

The Linux draft rejects naming a compatibility module `AppKit`, for a stated reason: the macOS
build must be able to compile the portable surface *beside* real AppKit and use the real product as
the reference implementation. That is an argument about the laboratory, not about whether the trick
works. So: does it work, and what does it cost?

On Linux there is no system AppKit, so a module named `AppKit` is simply ours, and every
`import AppKit` in the repository resolves to it with no edit to any file.

## What it does

`swift build --product Harness` in a `swift:6.3.2-noble` container produces `Harness`, which runs the layout
correctness cases, prints the solver's scaling curve, and renders PNGs into `out/`.
`./analyse.py` groups a sweep's missing symbols into subsystems and reports how many must close
before a file compiles. `./build.sh` runs that build and ranks whatever did not resolve. `./sweep.sh` type-checks
every file in `Sources/Threading/UI/Design/` against the shim alone and classifies each one.

`./vendor.sh` copies real Threading sources in; `./vendor.sh --verify` proves they are
byte-identical to the repository. That check is the whole difference between a measurement and a
flattering one, and it is why the vendored file is copied rather than adapted.

## Runner checks

Run `python3 -m unittest discover -s Spikes/linux-appkit/tests` without Docker to check the
runner failure contracts. The UI build and sweep mount the repository so local package paths
resolve, and select `Harness` independently of the core slice. Both refuse failed builds;
`sweep.sh` takes modules from the selected build directory rather than searching old artifacts.

`coreslice.sh` verifies the vendored sources before starting Docker, saves complete build/run
logs under `out/`, and runs the already-built executable only after a successful build. It requests
`linux/arm64` explicitly and prints the actual architecture. Without arguments it builds the full
project-graph slice and runs fifteen on-disk contracts:

| Group | Checks | FINDINGS section |
|---|---:|---:|
| Graph reopen, incremental updates, stale writers, receipts and corrupt rows | 5 | 31 |
| Commit rollback, probe retry and required model reload | 3 | 32 |
| Historical authority migration, rollback and constraints | 3 | 33 |
| Future-schema refusal for checkpointed and live-WAL stores | 2 | 34 |
| Pinned-WAL move refusal and relocation of healthy/damaged project stores | 2 | 35 |

The 27 production files are byte-identical to their sources. Runtime helpers remain in the app;
the slice includes neither RemoteKit nor live account discovery. The debug harness uses
`@testable import CoreSlice` without widening the production APIs. Commit-refusal fixtures use
the existing preflight injection seam; no test fills the host disk. StateManager's quarantine and
recovery policy remain outside this executable.

`./coreslice.sh --sqlite` builds and runs nine independent storage contracts against the unchanged
production `SQLiteDatabase` and logger, symlinked from the verified core copies. They cover bound
values surviving close/reopen, statement lifetime and reset, transaction and commit rollback,
foreign keys, migration atomicity, future-schema refusal, pinned-WAL file moves, and typed
`SQLITE_FULL` recovery. Every test uses a disposable directory; the full-disk test limits SQLite's
page allocation rather than filling the host disk. Logs are `out/sqlite-build.log` and
`out/sqlite-run.log`. Passing these contracts verifies the wrapper, not `ProjectDatabase`, project
model encoding, or the complete application's recovery path.

## What is in the shim

About 1,870 lines:

| File | What it answers |
|---|---|
| `Exports.swift` | `@_exported import Foundation` — the single line that makes 816 `NSRect` sites resolve |
| `Geometry.swift` | `CGAffineTransform` and the C-style constructors Linux Foundation lacks |
| `NSColor.swift` | sRGB with straight alpha, `setFill`/`setStroke` naming the current context |
| `NSBezierPath.swift` | Construction, flattening, and AppKit's independent per-axis corner clamp |
| `NSGraphicsContext.swift` | The state stack, the CTM, clip masks, `current` |
| `NSView.swift` | Frames, the subview list, `draw(_:)`, alpha, hit testing, the layout hooks |
| `Layout/NSLayoutConstraint.swift` | Constraints, priorities, the common-ancestor rule, `NSLayoutGuide` |
| `Layout/NSLayoutAnchor.swift` | The anchor family, generic exactly where AppKit is |
| `Layout/LayoutEngine.swift` | Constraints to a linear program, and frames back out |
| `Layout/Simplex.swift` | Two-phase simplex that retains `B⁻¹`, so a constant edit warm-starts through dual simplex |
| `Raster.swift` | Scanline fill, analytic horizontal coverage, 4× vertical supersampling |
| `PNG.swift` | Stored-deflate PNG, so the container needs no system library |
| `Stubs.swift` | `NSAnimationContext`, `NSEvent`, `NSFont`, `NSAppearance` — named, not implemented |

## What Linux Foundation already gave us for free

`NSPoint`, `NSSize`, `NSRect`, `NSEdgeInsets`, `NSCoder` and `CGFloat` are real types in
swift-corelibs-foundation, with `insetBy(dx:dy:)`, `integral`, `intersection(_:)`, `isNull` and the
rest already implemented. They are the first, fourth and seventh most-referenced symbols in
`UI/Design` and the shim owes them nothing but a re-export.

## Results

See `FINDINGS.md`.

## What this spike deliberately does not touch

Text shaping, IME, accessibility, layers, the window server, the event loop, and virtualization.
Auto Layout is present. Its solver is dense and solves a whole subtree at a time; it warm-starts a
constant edit but still pays a cold cubic cost for any structural change. See FINDINGS sections 8
and 11. Each is a real item in the draft's platform-leaf list, and none
of them is made smaller by the shim compiling.

## Working on this branch

This lives on `linux-appkit`, a long-lived branch, which is the arrangement that usually rots. The
three things that keep it from rotting here:

**It is thin, on purpose.** Nothing in this directory is under `Sources/`, `Packages/` or
`Tests/`, so it cannot conflict with product work and no `xcodebuild` on master can see it. When
the spike needs something *changed* in the app — a seam widened, a direct `NSView` ownership moved
behind a structural boundary — that change belongs on **master**, as ordinary work, under the
ratchets in delivery slice 3 of the draft. Not here. A branch that starts absorbing `Sources/`
edits is a fork, and a fork is the thing the draft says not to build.

**It re-copies rather than remembers.** `./vendor.sh` re-reads the real files from the working
tree every time, and `./vendor.sh --verify` fails the moment a copy and its original disagree. So
drift is detected, not assumed.

**Every catch-up produces a number.** `./refresh.sh` rebases onto master, re-vendors, rebuilds,
re-sweeps, and prints the delta against `baseline/sweep.tsv` — by file name. That is the branch
paying rent: it reports whether ordinary macOS work is moving `UI/Design` towards or away from
portability, which nothing on master measures. `./refresh.sh --accept` adopts a new baseline, and
the baseline is committed alongside the change that earned it.

A reasonable cadence is a refresh whenever master has moved meaningfully — after a batch of
`UI/Design` work, or monthly, whichever comes first. Rebase rather than merge: the branch has one
author's worth of history and no published ref, so keeping it a clean stack of spike commits on top
of master is cheaper than a merge trail.

**Do not push it.** `submodule.recurse` is true in this repository and `master` stands a long way
ahead of `origin`; see the push rules in `CLAUDE.md`. This branch is local.
