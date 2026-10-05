# Findings

Measured 2026-09-17 against this checkout, in `swift:6.3.2-noble` on arm64 — the same image and
Swift as `scripts/test-ptyd-linux.sh`, so the compiler that checks the daemon checks this too.
Re-run `./sweep.sh` before quoting any number; it writes `out/sweep.tsv`.

## 1. The trick works, mechanically, and costs nothing at the call sites

A Swift module named `AppKit` builds on Linux and every `import AppKit` in the repository resolves
to it. No file needs an `#if canImport`, a typealias header, or a rename.

The single highest-leverage line in the whole shim is `@_exported import Foundation`. Real AppKit
re-exports Foundation, which is why `NSRect`, `CGFloat` and `NSCoder` resolve from `import AppKit`
alone — and swift-corelibs-foundation already implements `NSPoint`, `NSSize`, `NSRect`,
`NSEdgeInsets` and `NSCoder` with the real geometry methods. Before that line, 816 `NSRect` sites
failed. After it, they were free.

## 2. Real Threading code renders real pixels on Linux

`Sources/Threading/UI/Design/PlatinumBitmapFont.swift` — 171 lines, vendored **byte-identical**,
verified by `./vendor.sh --verify` — draws its glyphs through the shim into `out/specimen.png`.
`advance(of: "Threading on Linux")` returns 123px, the file's own metrics, unchanged.

Two behaviours came through without being asked for, which is the part worth noticing:

- The first render dropped the title because the string held an em-dash. That is the file doing
  exactly what its doc comment promises — returning `false` for unsupported Unicode so the caller
  can fall back — and it happened against a shim that has never heard of a font.
- `Design`'s drawn surfaces rely on `NSGraphicsContext` save/restore to keep a clip from leaking
  into a sibling. Reproducing that stack exactly was enough; nothing else needed adjusting.

## 3. The shim is small, and the small part is the drawing

1,048 lines total, including a scanline rasterizer and a PNG encoder. What that buys:
`NSColor`, `NSBezierPath` (with AppKit's independent per-axis corner clamp, the asymmetry
`ThemedSurface.Shape` documents), `NSGraphicsContext` with a real state stack and clip masks, and
an `NSView` tree with `draw(_:)`, alpha and hit testing.

Across all 153 files in `UI/Design`, the drawing primitives are essentially *done*: the residual
asks are a handful of members (`NSBezierPath.setLineDash`, `.flattened`, `.bounds`,
`NSColor.cgColor`), not missing machinery.

## 4. What it does not buy — the measurement

Type-checking each of the 153 files in `UI/Design` against the shim alone:

| Verdict | Files | Meaning |
|---|---:|---|
| `clean` | 2 | Compiles standalone with zero errors |
| `shim-clean` | 24 | Nothing missing but *Threading's own* types — the shim owes these files nothing |
| `shim-gap` | 127 | Wants something the shim does not have |

116 distinct `NS`/`CA`/`CG`/`CT` symbols are still missing. Ranked by how many files want them:

| Missing | Files | Bucket |
|---|---:|---|
| `NSLayoutConstraint` (+ `leadingAnchor`, `trailingAnchor`, `topAnchor`, `bottomAnchor`, `widthAnchor`, `translatesAutoresizingMaskIntoConstraints`, `noIntrinsicMetric`, `NSLayoutGuide`) | 75 | **Layout** |
| `NSAccessibility` (+ `NSAccessibilityCustomAction`) | 56 | **Accessibility** |
| `NSTextField` (+ `NSMutableParagraphStyle`, `NSString.draw`, `NSAttributedString.draw`/`.size`, `NSTextView`, `NSLayoutManager`, `NSTextAlignment`) | 52 | **Text** |
| `NSStackView` | 46 | **Layout** |
| `NSImage` (+ `NSImageView`, `NSBitmapImageRep`, `NSImageInterpolation`, `CGImage`) | 36 | **Images** |
| `NSWindow`, `NSScreen`, `NSApp`, `NSViewController` | 19 | **Platform services** |
| `NSCursor`, `NSTrackingArea`, `NSEvent.keyCode`/`.charactersIgnoringModifiers`/`.type` | 18 | **Input** |
| `CALayer`, `CABasicAnimation`, `CAMediaTimingFunction`, `CGPath`, `CGContext` | 9 | **Compositing** |

113 of the 127 gap files need nothing from the drawing layer at all — they are blocked purely on
layout, text, accessibility, stacks or images.

## 5. What this says about the draft

It confirms the draft's split rather than challenging it. `docs/feature-drafts/linux-host-runtime.md`
names three propositions — widget presentation, structure, platform services — and says the first
is mostly bounded already and the second is the real project. That is exactly the shape of the
measurement: 1,048 lines closed the drawing, and the top of the remaining list is `NSLayoutConstraint`
in 75 files and accessibility in 56.

It also sharpens one number. The draft estimates "about one strong engineer-year" for a narrower
AppKit-shaped compatibility layer reaching a visibly useful build. Nothing here contradicts that,
because nothing here touched the expensive parts: a Cassowary solver and its invalidation contract,
HarfBuzz/FreeType/fontconfig plus an IME, AT-SPI, and a virtualized `NSTableView`. The cheap 1,048
lines are the cheap 1,048 lines.

## 6. The one argument the draft makes that this does not answer

The draft's objection to the name is about the *laboratory*: the macOS build must compile the
portable surface beside real AppKit and use the real product as the reference implementation. Name
the module `AppKit` and you cannot — the two cannot coexist in one process, and the compiler stops
being able to tell you which call sites are already portable.

That objection survives intact. What this spike shows is that the objection is the *only* one: the
trick is not technically fragile, it is methodologically expensive. A plausible resolution is to
name the real seam something of ours and keep an `AppKit`-named typealias layer as a Linux-only
compatibility shim that only vendored third-party code imports — SwiftTerm being the case that
actually motivates it.

## Not measured here

Runtime behaviour beyond one frame, layout correctness, scrolling, any scaling contract, text
shaping quality, IME, accessibility trees, and anything at all outside `UI/Design`.

---

# Round two: Auto Layout

Measured 2026-09-17, same image and machine. `Sources/AppKit/Layout/` adds `NSLayoutConstraint`,
the generic anchor family, `NSLayoutGuide`, intrinsic content size with hugging and compression
resistance, and a solver. The shim went from 1,048 lines to 1,871.

## 7. It is expressible, and it is correct

`NSLayoutConstraint` was the top of the gap list — 75 of 153 files — and it is now gone from that
list entirely. `LayoutTests` checks nine hand-computed layouts and all nine pass: the
flipped/unflipped origin pair, centring, multipliers, a low-priority width yielding to a required
trailing edge, compression resistance beating hugging, three siblings sharing a row at 58.66pt
each, a layout guide positioning a sibling, and an unsatisfiable pair being *reported* rather than
silently laid out at zero.

`out/constraints.png` is a sidebar with no frame set anywhere — every rectangle in it is the
solver's answer, and the label widths come from the real `PlatinumBitmapFont.advance(of:)`.

**The picture lied once, and the lie is instructive.** The long fourth row's label appeared to
overrun its chip, which looks exactly like a constraint engine getting an inequality wrong. It was
not: the solver had compressed that label from its intrinsic 245pt to 222pt, correctly, and the
*drawing* simply was not clipping to the view's bounds. A rendered-state test would have filed
that as a layout bug. Worth remembering when the render evidence for this eventually gets written.

## 8. The solver is the wrong solver, and now there is a number for it

One full re-solve of a constraint-driven list, release build:

| rows | items | constraints | LP rows | variables | median |
|---:|---:|---:|---:|---:|---:|
| 5 | 21 | 85 | 89 | 136 | 1.6 ms |
| 10 | 41 | 170 | 174 | 266 | 10.2 ms |
| 20 | 81 | 340 | 344 | 526 | 96.6 ms |
| 40 | 161 | 680 | 684 | 1046 | 682 ms |
| 80 | 321 | 1360 | 1364 | 2086 | 5272 ms |

Roughly 8× per doubling — cubic, which is what a dense two-phase simplex re-solved from scratch
costs. Eighty sidebar rows take five seconds. This repository's Scaling Gate would refuse it on
sight, and it should.

That is the finding, not a defect to apologise for. The draft says "a Cassowary-family solver is a
candidate, not a decision", and this says *why* Cassowary rather than "some linear solver":
Cassowary's contribution is not solving the system, it is editing a live tableau — incremental
add/remove and dual simplex on change. The correctness half of layout is a weekend. The part that
makes it a layout engine rather than a demo is the invalidation contract, exactly as the draft's
phrase "own the solver **and its invalidation contract**" implies. An incremental solver plus a
per-container solve (rather than one solve for the whole window) is the shape that would need
measuring next.

## 9. The gap list is a conjunction, not a queue

Closing the single largest blocker in the whole list moved **three files**: `AnnotationSendBar`,
`PaneFooter`, `PaneHeader`. Verdicts went from 127/24/2 to 124/27/2.

That is not a disappointing result, it is the most useful thing measured so far, and it is only
visible because the sweep was re-run rather than reasoned about. `./analyse.py` groups the
remaining 116 missing symbols into subsystems and asks how many have to close before a file
compiles:

| Blocked by | Files |
|---|---:|
| 1 subsystem | 23 |
| 2 subsystems | 18 |
| 3 subsystems | 27 |
| 4 or more | 56 |

Greedily closing whole subsystems, best-first:

| After closing | Gap files clear |
|---|---:|
| text | 5 / 124 |
| + accessibility | 8 |
| + stack views | 18 |
| + the rest of `NSView` | 33 |
| + input/events | 40 |
| + window/app | 47 |
| + images | 65 |
| + layers/CG | 71 |
| + controls | 82 |
| + the rest of `NSColor` | 94 |

So a ranked list of missing symbols reads like a queue and is nothing of the kind: a file compiles
when its *last* blocker goes, not its first. Nine subsystems have to be finished before two thirds
of `UI/Design` will build. The "about one strong engineer-year" estimate in the draft looks, if
anything, better supported after this than before it — and the order to do the work in is not the
order the frequency table suggests.

## 10. Liberties taken in the layout layer, recorded

- **No baselines.** With no text stack, `firstBaseline` is the top edge and `lastBaseline` the
  bottom. Every baseline-aligned row in the app is therefore wrong here by the font's ascender.
  That is a text problem wearing a layout problem's clothes, and it will not resolve until the
  text bucket does.
- **Ambiguity resolves, but not where AppKit resolves it.** An under-determined system has many
  feasible vertices; the engine adds a 1e-4 preference for the smallest, topmost, leftmost, far
  below any real priority. Ambiguity resolving *somewhere* is not the same as resolving where
  AppKit would, and a real port needs the comparison, not the assurance.
- **One solve per subtree, from scratch.** No incremental edit, no per-container scoping, no
  `updateConstraints` pass. See section 8.

---

# Round two, part two: warm starting

`Simplex` now retains `B⁻¹` beside its tableau. Moving a constraint's `constant` changes only the
right-hand side, which leaves the basis dual-feasible — the objective did not move — so a few
*dual* simplex pivots can restore primal feasibility instead of a fresh phase one and phase two.
`LayoutEngine` caches the program per root and compares its structure (coefficients and relations,
compared rather than hashed: a false positive lays the window out against the wrong constraints).

Three cases guard it, all passing: a warm re-solve lands on the same geometry a cold solve does; an
edit that makes the program infeasible is still *reported* rather than returning stale frames; and
two hundred successive resizes on one retained tableau do not drift from a cold answer. The last is
the failure a warm-start cache is most likely to ship with, because it looks perfect on the first
frame and goes wrong where nothing is asserting.

## 11. The warm start fixes one case, not the scaling — and the pivot count is what says so

| rows | LP rows | cold | warm, active set unchanged | pivots | warm, crossing a threshold | pivots |
|---:|---:|---:|---:|---:|---:|---:|
| 5 | 89 | 1.8 ms | 0.11 ms | 0 | 0.29 ms | 5 |
| 10 | 174 | 10.8 ms | 0.22 ms | 0 | 1.48 ms | 10 |
| 20 | 344 | 80.9 ms | 0.48 ms | 0 | 10.4 ms | 20 |
| 40 | 684 | 619 ms | 1.04 ms | 0 | 79.5 ms | 40 |
| 80 | 1364 | 4910 ms | 2.76 ms | 0 | 653 ms | 80 |
| 160 | 2724 | 47468 ms | 8.40 ms | 0 | 5158 ms | 160 |

The first warm column is a resize that never changes *which* constraints are active — a drag that
does not push any label through its compression threshold. It is 5,600× faster than cold at 160
rows, and **it took zero pivots**, which means it measured the `B⁻¹ · b` multiply and nothing else.
A benchmark reports that number by accident unless someone checks the pivot count, and the first
version of this table did exactly that.

The second column widens the sweep until every row's label stops being clipped by its chip and its
soft 400pt width becomes satisfiable. The active set changes, the dual simplex has to work, and the
pivot count comes out at exactly one per row. At 160 rows that is 5.2 seconds — nine times better
than cold, and still growing about 8× per doubling. **Cubic again.**

The arithmetic says why, and it is not incrementality. One pivot rewrites the whole dense tableau:
2,724 rows × 6,891 columns ≈ 18.8M operations, times 160 pivots ≈ 3.0G operations — which is the
five seconds, near enough. Meanwhile each constraint row has at most six non-zero coefficients out
of 4,166 variables. **The tableau is about 99.9% zeros and every pivot touches all of them.**

So the ranking for anyone who picks this up:

1. **Sparsity is the big lever**, not incrementality. A sparse revised simplex pivots over the
   non-zeros, which here is three orders of magnitude fewer numbers.
2. **Then scope.** One solve per *container* rather than one per window keeps n small in the first
   place; AppKit does not solve a whole window as one program either.
3. **Then the warm start**, which is already here and is worth keeping — a drag that does not
   change the active set is the common case, and 8ms at 160 rows is a frame.

None of this changes the draft's estimate. It sharpens what "own the solver and its invalidation
contract" has to mean: a sparse, scoped, incremental solver, where this spike has built the third
of those three and measured why the other two are not optional.
---

# Round three: the headless core

Measured 2026-09-18. `./headless.py ../..` classifies every import in `Sources/Threading/Core`,
`Models` and `Application` — the draft's delivery slice 2, "make the product layers compilable",
asked as a number instead of a plan.

## 12. Two thirds of the non-UI code already imports nothing Linux lacks

636 files:

| | Files | |
|---:|---:|---|
| **443** | 69% | import only what Linux already has |
| **88** | 13% | also need a substitution with a known Linux equivalent |
| **105** | 16% | reach something with no Linux story yet |

The substitutions are unglamorous and mostly mechanical: `Darwin` → `Glibc` (32 files), `os`/`OSLog`
→ swift-log (36), `CryptoKit` → swift-crypto, which is the same API (21), `Network` → NIO or POSIX
sockets (10), `ImageIO` → libpng/libjpeg (11).

The blockers are more interesting, because **73 of the 105 are `AppKit`** — the UI question, which
is the other half of this spike and not slice 2's problem. Strip those and the genuinely non-UI
blockers come to about thirty files:

| Files | Blocker | What it would become |
|---:|---|---|
| 20 | `Security` | Keychain — libsecret, or a different credential story |
| 6 | `UserNotifications` | libnotify / D-Bus |
| 6 | `SwiftTerm` | ours, but its AppKit half is the UI question again |
| 3 | `AVFoundation` | GStreamer / ffmpeg |
| 2 each | `ServiceManagement`, `IOKit`, `AuthenticationServices`, `Sparkle`, `ApplicationServices` | systemd user units; device identity; a browser handoff; updates; look at these |
| 1 each | `SystemConfiguration`, `PDFKit`, `CoreImage`, `CoreMedia`, `CoreVideo`, `VideoToolbox`, `MetricKit` | |

`Security` at 20 files is the one that is a *product* decision rather than a port: where an agent
account's credentials live when there is no Keychain is a question about what Threading promises,
not about which library to link.

## 13. This is an upper bound, and saying so is the point

Imports say what a file *reaches for*. They do not say it compiles. A Foundation-only file can
still be unportable through a path assumption, a `Process` launching a macOS binary, a
case-sensitivity assumption, or a Darwin API reached through a typealias. Every number in section
12 is a ceiling.

Converting it into a measurement means doing to `Core` what round one did to `UI/Design`:
type-check each file on Linux and separate "fails only on Threading's own types" from "fails on a
platform symbol". That is the obvious next step and it is not expensive — the sweep machinery
already exists.

What the ceiling is good for is *ordering*. It says slice 2 is not a rewrite: it is roughly thirty
files of genuine platform decisions, one of which (credentials) is a product question, plus a pile
of mechanical substitutions. Against the nine-subsystem conjunction the UI faces, that is a very
different size of problem — which is exactly why the draft put it first and said it is worth doing
even if Linux stops there.

## 14. The ceiling holds: the compiler says 66%

`./sweep-core.sh` type-checks each of those 636 files on Linux against **Foundation alone** — no
AppKit shim, nothing from this spike. That absence is the design: with no `AppKit`, `Security` or
`IOKit` module in the container, a file that needs one fails with an unambiguous `no such module`
instead of a thousand cascading symbol errors, so the blocked set classifies itself.
`./classify-core.py` then separates a *platform* failure from a file that merely missed its
siblings, because only the first is a portability problem.

| Verdict | Files | |
|---:|---:|---|
| compiles standalone | 36 | 5% |
| needs only our own siblings | 383 | 60% |
| needs `import FoundationNetworking` | 6 | 0% |
| blocked: missing module | 189 | 29% |
| blocked: platform symbol | 22 | 3% |
| **nothing platform-specific in the way** | **425** | **66%** |

66% measured against the 69% the import ceiling predicted. The ceiling was close to honest, which
is itself worth knowing: for this codebase, the cheap import scan is a decent proxy for the
expensive compile, and slice 2 can be tracked with the cheap one between sweeps.

Of the 211 blocked, **72 are `AppKit`** — the UI question — and most of the rest have a known
Linux equivalent rather than a wall: `Darwin` → Glibc (29 files), `os`/`OSLog` → swift-log (27),
`CryptoKit` → swift-crypto with the same API (16), `CoreGraphics` (9), `Network` → NIO (8),
FSEvents → inotify (4 files, one file-watcher), `SQLite3` and `Compression` (1 each).

**The genuinely hard tail is about twenty files:**

| Files | Blocker |
|---:|---|
| 12 | `Security` — Keychain |
| 3 | `AVFoundation` |
| 2 each | `UserNotifications`, `ApplicationServices`, `Sparkle` |
| 1 each | `MetricKit`, `ServiceManagement`, `CoreImage` |
| 1 each | `RelativeDateTimeFormatter`, `ListFormatter`, `ProcessInfo.beginActivity`, `URLResourceValues.volumeAvailableCapacityForImportantUsage`, `NSNotification.Name.NSSystemClockDidChange` |

That last group is the interesting one, because none of it is a framework — it is Foundation APIs
that **swift-corelibs-foundation simply does not have**. `RelativeDateTimeFormatter` and
`ListFormatter` are the kind of thing an import scan can never find, and they are exactly why the
compile was worth running rather than reasoning about.

## 15. Two bugs in the measurement, worth recording

Both would have produced a flattering number, and both were caught by disbelieving a good result:

- **`str.splitlines()` splits on `\v`.** The sweep escapes each file's errors onto one line with a
  vertical tab; Python treats that as a line break. Twenty-six rows read as 1,810 files and the
  tool reported "97% compiles standalone". The classifier now splits on `"\n"` explicitly.
- **Our own modules counted as platform blockers.** `ThreadingDomain`, `ThreadingRemoteKit` and
  `NativeDiffCore` are not on the search path for a one-file type-check — the same artifact as a
  sibling type not being compiled alongside, not a portability problem. `NativeDiffCore` needed
  naming specially because it is referenced as a `.product(name:)` from a package of ours fetched
  from GitHub, so scanning package directories and target declarations both missed it.

And one real finding fell out of the noise: on Linux, **`URLSession` and friends are not in
Foundation** — swift-corelibs-foundation splits them into `FoundationNetworking`. Those files are
not blocked, but each needs a `#if canImport(FoundationNetworking)` import, so it is a genuine
porting chore with its own bucket rather than a footnote.

---

# Round four: linking a real core slice

Measured 2026-09-18. `sweep-core.sh` asked "would this file type-check alone". This asks the two
questions it structurally cannot: do the files compile **together**, and does the code then
**work**. `coreslice.sh` builds one vertical slice — open a database, hold a project graph, encode
it — from files vendored verbatim, and `close.py` grows the slice by repeatedly compiling, reading
the unresolved names out of the errors, and vendoring whatever declares them.

## 16. It does not run yet, and stopped somewhere precise

**Not achieved: the slice does not execute.** It reached 21 vendored application files plus three
of our own packages and stalled on a specific, one-line problem, described below. The intended
third rung — compile-alone, compile-together, *run* — is still the second rung.

What it took to get that far:

| | |
|---:|---|
| 21 | application files, vendored byte-identical |
| 3 | of our packages, built from source unmodified: `ThreadingDomain`, `ThreadingRemoteKit`, `ThreadingExtensionKit` |
| 2 | file splits (below) |
| 11 | lines of SQLite module map |
| ~120 | lines of OSLog shim, standing under 760 unchanged call sites |

`ThreadingDomain` and `ThreadingRemoteKit` **build on Linux unmodified** — the first direct
evidence that the kernel packages' Foundation-only claim holds on a platform they have never been
compiled for.

## 17. Where it stalls: one missing import in one of our packages

```
ThreadingExtensionKit/Sources/ThreadingExtensionKit/ExtensionHostClient.swift:548
  error: type 'URLSession' (aka 'AnyObject') has no member 'shared'
```

That file imports Foundation and uses `URLSession.shared` and `HTTPURLResponse.localizedString`.
On Linux those names exist as placeholder `AnyObject` typealiases until `FoundationNetworking` is
imported, so the failure is not "missing API" — it is the type resolving to something useless while
looking present. The fix is three lines at the top of the file:

```swift
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
```

Left unmade deliberately: `Packages/` is app code, and by this branch's own rule that change
belongs on master as ordinary work, not here.

## 18. The two splits, and why they are the real story

The slice needed exactly two files split, and both were a few lines in the wrong place:

- **`Models/TerminalTheme.swift`.** `Project` persists a `TerminalThemeID` — a Foundation-only
  string wrapper. It is declared in a file whose first two lines are `import AppKit` and
  `import SwiftTerm`, because the same file holds the theme's colours and its
  `asSwiftTermColors()` bridge. Persisting a project therefore reaches a terminal emulator.
  `application-structure.md` already says where this belongs: *"ThreadingDomain owns typed project,
  session, terminal, transcript, and account identities."*
- **`Core/Settings/SettingsEvents.swift`.** 31 lines. The last four declare `ProfileDidChange`,
  whose payload is an AppKit-bearing `TerminalProfile`. Everything above is Foundation-only. Four
  lines at the bottom of one file put AppKit in the transitive closure of saving a project.

## 19. Swift's unit for imports is the file, and nothing checks that

`check_module_boundaries.py` enforces dependency direction between **modules**, and most of
Threading is still one app target. Inside that target the real granularity is the file: one
framework-bearing declaration makes the whole file framework-bearing for everyone who needs
anything else in it. Nothing measures this, so `./split-candidates.py` now does:

**113 files import a framework with no Linux story. 72 of them also declare types that appear to
need none — 366 types.**

| Framework | Files with candidates |
|---|---:|
| AppKit | 43 |
| Security | 19 |
| ImageIO | 9 |
| CoreGraphics | 8 |
| AVFoundation, ServiceManagement, IOKit, CoreText, UserNotifications | 8 |

The largest single case is `Core/MCP/MCPTools.swift`: **135 candidate types behind one
`CoreGraphics` import**. Every MCP argument struct in that file is a plain `Codable`, and the lot
of them are unportable because something in there wants a `CGRect`.

This reframes section 12's "about thirty files of real platform decisions". That number stands for
*decisions*; it undercounts the work and overstates its difficulty at the same time, because most
of the remaining blocked set is not a decision at all — it is types sitting in the wrong file.
Slice 2 can be planned as a worklist of splits rather than discovered one compile error at a time,
and **every one of those splits is worth doing on master whether or not Linux ever happens**,
because it tightens the dependency direction the architecture document already asks for.

`split-candidates.py` is a heuristic and says so in its header: it cannot see through a typealias
or an extension in another file, so its output is a worklist to confirm, never a patch to apply.

## 20. What the closure size actually said

The loop was expected to converge at a dozen files and did not stop growing until it ran out of
things to vendor. Saving a project graph reaches account preferences, agent model names, managed
workspaces, pending checkout moves and account discovery — because `AgentSession` is a wide record
and `ProjectDatabase` needs all of it to encode a row.

That is a less comfortable finding than the splits. The splits are cheap and unambiguously worth
doing. This one says the **record types themselves are broad**, so "extract the persistence layer"
is not only a matter of moving files out of AppKit's way: `AgentSession` comes too, and it carries
curfew rules, launch failures, workspaces and checkout moves with it. Slice 2 should expect to take
a position on that before it starts, rather than discover it halfway.

## 21. Three measurement notes

- **`os` → swift-log is not the swap the import scan implied.** Threading makes 760 `privacy:`
  interpolations, and that vocabulary is OSLog's string-interpolation machinery, which swift-log
  has no equivalent for. A straight swap would rewrite every call site *and* delete a policy —
  `Logger.swift` requires each interpolation to choose `privacy:` explicitly, enforced by
  `scripts/check_logging_boundaries.py`. Keeping the vocabulary and putting something under it cost
  about 120 lines, and the shim **honours** redaction rather than ignoring it: a Linux build that
  quietly logged everything in the clear would pass every test and violate the contract those call
  sites were written to.
- **Swift 6 language mode was removed from the experiment.** Compiling the slice in Swift 6 mode
  produced concurrency diagnostics on `TerminalThemeID`'s static members. Those belong to the
  Swift 6 migration the app has not finished — tracked separately in the shipping contract — not to
  Linux. The slice is pinned to Swift 5 mode so the variable under test stays the platform.
- **A bug in `close.py` hid a file for two rounds.** Two files here are called `Identifiers.swift`
  (one in `Models`, one in `ThreadingDomain`) and copying by basename overwrote the first with the
  second. It surfaced much later as a *missing module*, which is the kind of misdirection worth
  paying for once. Collisions now get their parent directory prefixed.

## 22. Three real portability fixes, and then a decision rather than a bug

Continuing past section 17 fixed each blocker in turn. All three changes are in `Packages/`, are
inert on Apple platforms, and were verified with `swift build` on macOS for both packages.

1. **`ExtensionHostClient.swift` — a missing conditional import.** `URLSession.shared` failed as
   `type 'URLSession' (aka 'AnyObject') has no member 'shared'`, because swift-corelibs-foundation
   leaves the name behind as a placeholder typealias. Three lines of `#if canImport(FoundationNetworking)`.
2. **`ExtensionHostDescriptorTransport.swift` — a qualification that cannot be conditional.** The
   file already imported Darwin conditionally, but the call sites said `Darwin.read(...)`
   explicitly — to avoid colliding with same-named members in scope — and a module-qualified name
   has no `#if` form. The qualification moved into two private `posixRead`/`posixWrite` helpers.
   There are ten such qualified calls across four of our packages; this fixed the two in the path.
3. **`GzipWriter.swift` — a framework with a real substitute.** Guarded behind
   `#if canImport(Compression)`; without it `deflate` reports "not worth compressing", which the
   caller already handles by sending the body uncompressed.

That third one produced the most transferable detail. `Platforms/Linux/Sources/Compression/`
implements the two symbols `GzipWriter` uses on top of zlib, and the trap is the naming: Apple's
`COMPRESSION_ZLIB` produces **raw DEFLATE**, which is what the gzip framing expects, while zlib's
own `compress2()` writes a zlib header instead. Getting that wrong yields a stream that passes
every length check in the caller and is not valid gzip. The shim goes through `deflateInit2_` with
a negative window size, which is zlib's way of saying "no header". It is kept as a compiled
reference rather than wired in, because reaching it from `ThreadingRemoteKit` would mean changing
that package's dependencies.

**Then it stopped on something that is not a bug.** `RemoteHostPinning.swift` imports `CryptoKit`.
The fix is well known — swift-crypto exposes the same API as `import Crypto`, so it is the usual
`#if canImport(CryptoKit)` / `#else import Crypto` — but it requires **adding a third-party package
to the project**, and `CLAUDE.md` is explicit that the dependency list is short and deliberate
("Five local Swift packages… All five are ours"). That is a decision, not an edit, so the slice
stops here.

Which is the right note for this round to end on. The blockers went: a missing import, a
qualification, a substitutable framework — and then a question for a person. The first three are
what most of slice 2 looks like. The fourth is what the remaining twenty files look like.

## 23. A rule this branch broke, deliberately

Section "Working on this branch" says anything needing a change in the app belongs on master. The
three fixes above are in `Packages/`, so they break that rule. They are here because they are
*Linux-portability* changes — meaningless on macOS, and the branch's entire subject — and because
committing to master triggers the autoinstall rebuild described in `CLAUDE.md`, which is not a side
effect to cause unasked.

They are independent of everything else on the branch and can be cherry-picked to master at any
time. Anyone reading this later should assume they *should* be, since each one is a small
correctness improvement to a package that claims to be Foundation-only.

---

# Round five: landing it

## 24. The fixes are on master, and the stand-ins are gone

Everything in rounds four and five that was worth keeping regardless of Linux is now on master, as
three ordinary commits verified with the full app build (boundary lints included) and the `fast`
test level:

| Commit | Change |
|---|---|
| `c9a43797c` | `TerminalThemeID` and `TerminalThemeNames` move into `ThreadingDomain`, gain `Sendable`, and get six tests for their persisted contract |
| `1f33a569c` | `ProfileDidChange` moves beside `TerminalProfile`, leaving `SettingsEvents.swift` Foundation-only |
| `12cfbf576` | The three package guards: `FoundationNetworking`, `posixRead`/`posixWrite`, `canImport(Compression)` |

The payoff the spike predicted was that the stand-ins would be **deleted rather than reconciled**,
and they were. `standins.sh` is gone; `coreslice.list` now names 23 files, all vendored
byte-identical and checked by `./vendor-core.sh --verify`; and the slice stops at exactly the same
`CryptoKit` frontier as before. That equivalence is the evidence that the two splits on master do
precisely what the stand-ins did, and nothing less.

Section 23's broken rule is repaired too: outside `Spikes/`, this branch now differs from master
only by the draft update in `docs/feature-drafts/linux-host-runtime.md`.

## 25. What landing it turned up that the spike did not

- **`ThreadingDesignKit` compiled its own `TerminalThemeID`.** Its `Shared/` folder is symlinks into
  the app's sources, so it built `TerminalTheme.swift` itself. `plugins.md` confirmed the kit
  already depends on `ThreadingDomain` and has `Seam/SharedNames.swift` for exactly this, so the
  fix was two aliases rather than a design change. A Linux build of the slice could never have seen
  this: the kit is not on its path.
- **An alias narrower than the type it replaces changes an API.** `TerminalThemeID` was `public`
  in the app and `ThemeResolution` names it in public API, while the neighbouring domain aliases are
  internal. Following the neighbours' pattern exactly would have broken the build; the two new
  aliases keep the access level the types had.
- **The two private tests nobody had.** `migratedFromName` and `recoveredFromCollision` had no
  direct coverage. Moving them into a package whose purpose is pinning persisted identities was the
  natural moment to add it — and the base64url round-trip test was checked to exercise `+`, `/` and
  both padding lengths, rather than assumed to.

## 26. The test run, stated exactly

The `fast` level ran 9,311 tests with 14 failing assertions across 12 cases. None is caused by
these changes:

- **Eight cases fail identically on the pristine parent commit**, `60f92498b` —
  `AppSettingDefinitionTests` (4), `SidebarBrandViewTests` (3), `SilenceGateFooterTests` (1). They
  track work landing on master at the time: the sidebar re-sort and new settings rows.
- **Four cases in `GitTurnCheckpointTests` were timeouts**, `timedOut(nil)` and "exceeded timeout of
  20 seconds", during a run that took over two hours with real `git` processes under load. Run on
  its own with these changes, the class passes all 38 tests.

Both halves were established by running the failing classes against the parent commit and in
isolation, not by reading the failure messages and deciding they looked unrelated.

## 27. Repair the measurement runners before extending the shim

The UI runner still mounted only the spike at `/w`, although the manifest now refers to two
packages under `../../Packages`. Those paths do not exist in that container. Worse, `build.sh`
looked only for source-location diagnostics and printed "builds clean" when Docker or package
resolution failed without one. `sweep.sh` ignored the failed build and searched all old build
artifacts for an AppKit module, so stale output could stand in for a new measurement.

Both runners now mount the repository at `/repo` and select the UI `Harness` product, independently
of the core slice's blockers. Build failure returns failure. The sweep requires a successful build
and uses that configuration's module directory before touching the previous report.

The core runner now checks all vendored files before launching Docker, retains complete logs,
stops after build failure, and runs with `--skip-build`. Its old `head -60` pipeline could close
the compiler's output early and discard later diagnostics. The harness itself remains a placeholder;
none of this establishes that a project graph saves and reopens on Linux.

Verification: seven runner regression tests passed using substituted Docker/Swift commands,
shell syntax checks passed, and all 23 core copies matched their originals. A real Linux UI build
attempt timed out after 45 seconds while Docker's independent info probe also failed to respond.
No new compiler frontier, sweep counts, or runtime evidence is claimed by this increment.


## 28. The storage engine runs unchanged; the project graph still reaches TLS

After restarting Docker and rebasing onto rewritten master `c89fb6521`, the full core slice was
rebuilt. It still fails at `RemoteHostPinning.swift:1`, `no such module 'CryptoKit'`.
Tracing the dependency makes the next step more specific:

```
CoreSlice → AccountPreferencesStore → AccountAppearancePreferences
         → ThreadingRemoteKit (whole module) → RemoteHostPinning
         → CryptoKit + Security + Apple server-trust challenge APIs
```

The earlier suggestion that adding swift-crypto would clear this frontier was incomplete.
`RemoteHostPinning.swift` also imports `Security`, uses `SecTrust` and `SecCertificate`, and
implements `URLSession` server-trust handling. SHA-256 support alone cannot make that file
portable. The first boundary candidate is the Foundation-only account appearance contract; local
preference storage should not require a TLS implementation just to encode appearance values.
This round does not change the shipping package boundary or substitute a fake pinning module.

The independent SQLite layer does not need any of that. `SQLiteHarness` compiles the existing,
verified `SQLiteDatabase.swift` and `ThreadingLogger.swift` through relative symlinks, alongside
this spike's existing OSLog adapter. `./coreslice.sh --sqlite` verifies both source identity and
those links' contents before starting the container. There is no second edited wrapper.

All nine contracts passed with Swift 6.3.2 in Swift 5 language mode and SQLite 3.45.1 on native
arm64 Linux:

- Unicode TEXT, raw TEXT bytes, BLOB, 64-bit integers, floating-point values and NULL survive
  closing and reopening an on-disk database.
- Reset clears old bindings; scope exit and repeated explicit finalization release statements.
- A constraint refusal rolls back earlier writes in its transaction and permits later valid work.
- An injected pre-commit failure leaves no committed row after reopen.
- Foreign keys refuse orphans and cascade parent deletion.
- Failed migration rolls back both DDL and `user_version`; successful steps run once in order.
- Opening a future schema refuses without changing file bytes or creating WAL/SHM sidecars.
- A pinned WAL refuses a file move; releasing the reader permits checkpoint, move and complete readback.
- A bounded `max_page_count` fixture produces typed `SQLITE_FULL`, retains committed rows and
  accepts a new write after lifting the page limit.

The first run also passed on amd64 under emulation: Docker selected a locally cached image of that
architecture and warned about the mismatch. The runner now requests `linux/arm64` and prints
`uname -m` so the platform cannot silently vary. Ten Python runner checks pass, including selecting
the SQLite product, separate logs, and rejecting a modified wrapper before Docker starts.

This is behavioral evidence for the production SQLite wrapper, not a completed project-graph
port. `ProjectDatabase`, its models, application recovery, and the real Linux TLS/credential
adapters remain unverified here. No performance conclusion is drawn from these fixed-size cases.

## 29. Account appearance no longer imports the TLS stack

The three account appearance types moved byte-for-byte from `ThreadingRemoteKit` into
`ThreadingDomain`. The wire kit now depends on Domain and exposes public aliases under the old
names; `AccountPreferencesStore` imports Domain directly. The spike's manifest no longer has a
RemoteKit dependency, and its account-store copy is re-vendored from the changed production file.
This is a shared-code extraction prepared on this branch for independent review/landing on master,
not an Apple-framework stub or a change to the remote trust policy.

The storage format is unchanged: the new tests decode an existing-shaped JSON fixture and compare
its re-encoded object, including explicit false, absent inheritance and an unknown surface key.
They also pin surface identifiers, normalization and alias type identity across the two modules.
The original definitions and their new Domain file compare byte-identical.

Rebuilding the full Linux core slice clears `RemoteHostPinning` and stops at
`AgentAccountDiscovery.swift:2`, `no such module 'os'`. This is `OSAllocatedUnfairLock` in its
short-lived account-discovery cache, not logging. The model reaches it through
`ConversationHandoff.continuing` → `AgentSession.handoffModelSnapshot` → live account/model
lookup. Those are runtime operations declared beside the persisted session record. Moving their
ownership out of the record is the next boundary candidate; replacing a lock would leave the
record coupled to account scans and preferences.

Verification for this extraction: all 15 Domain tests pass on macOS and arm64 Linux; all 215
RemoteKit tests pass on macOS, including the public-alias contract. The shipping macOS app builds
with its repository gates and passes all 11 hosted `AccountAppearanceTests`. These validate the
shared-code move; they do not establish that the full Linux project slice compiles.
The shipping `ThreadingMobile` Debug build also succeeds for a generic iOS Simulator destination;
this is compilation/link verification, not an iPhone runtime test.

## 30. Live handoff lookup leaves the persisted session file

`ConversationHandoff.continuing` and `AgentSession.handoffModelSnapshot` moved unchanged into
`Core/Agent/ConversationHandoffRuntime.swift`. The stored path, validating initializer, decoder,
provisional-model settlement and compatibility properties remain in `Models/AgentSession.swift`.
This preserves call sites and runtime behavior while making it possible to compile the record
without discovering accounts or loading their configured models.

The measured dependency set shrank from **23 files / 9,516 lines to 20 files / 7,546 lines**.
`AgentAccountDiscovery`, `AgentModels` and `AccountPreferencesStore` are no longer vendored. Every
remaining copy verifies byte-identical against the working tree; no source-body adaptation or
replacement lock was needed.

Rebuilding on arm64 Linux clears the `os` import failure and reaches semantic checking. The full
slice still does not compile. Its next errors are a mixture, not one platform substitution:

- Missing durable types: `ProjectExecutionHost`, control grants/supervision/roles, prompt and
  attachment values, and session read-receipt state.
- `AgentEnvironment` shares `AgentDefaults.swift` with constants but reaches command-line tool
  installation, environment keys and `AppSettings`.
- `AgentSession.displayTitle` consults `AppSettings` for its title policy.
- `ProjectTerminal.init` calls `GitInfo.currentBranch` while sharing the persisted project file.
- Scheduled-message records refer to outbox and usage defaults declared in larger feature files.

Blindly expanding the manifest would reintroduce platform imports: environment keys share an
AppKit-bearing constants file, `GitInfo` imports `os`, read receipts import RemoteKit, and the
command-line tool installer imports Darwin. These are the next ownership boundaries to inspect;
a list of unresolved names is not evidence that every corresponding file belongs in persistence.

Verification: the shipping macOS app builds with repository gates and passes all 106 selected
handoff, provider-capability, side-chat and `StateManager` tests. Three new cases exercise the
runtime entry point directly: frozen source provenance/provisional target settlement, a repeated
handoff refreshing only its direct source, and rejection of same-runtime/same-session targets.
All ten runner tests pass and all twenty vendored copies match. Linux compilation still fails on
the unresolved dependencies listed above; the project-graph executable has not run.


## 31. The real project database runs on Linux

The persistence slice now builds, links and runs on **arm64 Linux**, Swift 6.3.2 in Swift 5
language mode, with SQLite 3.45.1. All **27 files / 8,877 lines** are byte-identical production
copies. The only compatibility module used by these records is the existing OSLog adapter;
there is no AppKit, RemoteKit, account scanner or replacement persistence implementation.

The last dependencies were ownership boundaries:

- Launch environment composition moved from `AgentDefaults` into `AgentEnvironment`.
- Session title preferences and terminal creation's git lookup moved into runtime extensions.
- Remote host to SSH destination conversion moved beside the SSH adapter.
- `SessionReadReceiptState` became a standalone model, separate from its RemoteKit-aware store.
- Outbox capacity became a shared default, independent of queue delivery protocols.
- Durable `ControlActor` and `ControlScope` moved beside `ControlGrant`, separate from live
  control outcomes. Their authority and encoding semantics are unchanged.

The manifest additionally takes the real prompt/context values, usage values, host records and
control-authority records. Moved bodies are unchanged; no field, permission rule or JSON key was
adapted for Linux. These production extractions remain prepared on this branch for independent
review/landing, not as spike-only alternate definitions.

`CoreSliceHarness` replaces the placeholder with five contracts against disposable on-disk state:

1. Save, close and reopen projects/sessions, retaining IDs, order, Unicode titles, selection and
   a remote execution host record.
2. Update one session and retain its sibling and unrelated project.
3. Refuse a stale whole-graph writer after another connection adds a project; preserve that project.
4. Persist participant receipt generations across connections and cascade them with session deletion.
5. Reject a corrupt session payload as an identified corrupt row, leaving the row in place.

All five pass through `coreslice.sh`; the debug executable uses `@testable import` rather than
changing access control in the production files. A first stale-writer fixture incorrectly used a
selection-only mutation, which does not advance the graph generation; the corrected fixture uses
a new project, matching the production contract. Full logs remain under `out/coreslice-*.log`.

This establishes the exercised database behavior, not a complete Linux host. StateManager,
application recovery, all schema migration histories, standalone terminal creation, credential
custody and live agent transports remain outside this Linux executable.

Shipping verification: the macOS app builds with its repository gates, and the focused hosted
run passes **109 tests**, with one existing legacy-import test skipped because there is no live
`projects.json` fixture. The run covers ProjectDatabase, read receipts, launch environment,
remote host components/store, handoff runtime and StateManager. All ten spike runner tests pass;
all 27 vendored files verify and `git diff --check` is clean. No UI appearance changed.


## 32. Recovery primitives preserve the graph across refusal and retry

One bounded slice extends `CoreSliceHarness` with three recovery contracts, using the existing
`ProjectDatabase.transactionCommitPreflight` injection seam. Production files and the vendored
dependency set are unchanged. All eight project contracts (five persistence, three recovery) pass
on arm64 Linux with Swift 6.3.2 and SQLite 3.45.1; all ten runner tests pass.

- Refusing a whole-graph deletion at commit rolls back projects, sessions, selection and cascading
  receipt deletion. An independent connection sees the retained state. Retrying on the original
  writer without reloading succeeds, proving its observed generation did not advance on refusal.
- A refused recovery probe propagates failure and leaves no temporary probe row. A subsequent probe
  succeeds, leaves no row, and does not invalidate an existing reader's graph generation. The graph
  and receipt survive close/reopen.
- SQLite-valid pages containing invalid session JSON pass the integrity/write probe but fail the
  authoritative model load with the exact corrupt row identity. The row and receipt remain intact.
  This pins why the documented recovery sequence includes both the probe and the complete reload.

The fixtures use disposable directories, deterministic commit refusal, and the real SQLite store.
They do not fill the host disk or claim to reproduce an OS I/O failure. The independent wrapper
suite already exercises real `SQLITE_FULL` through SQLite page limits. This slice does not port
StateManager, quarantine, recovery presentation or the complete app's in-process resume policy.
No shipping source changed, so the previous macOS shipping validation remains applicable; the
new executable code was built and run through `coreslice.sh`. Logs are `out/coreslice-*.log`.


## 33. Historical authority migration survives refusal and retry on Linux

`MigrationContracts.swift` creates a schema-4 fixture using the production historical DDL and
seeds two sessions, a manager grant, a released supervision tenure and its event. It exercises
`ProjectDatabase`'s real migration chain to the current schema (6), not a harness copy of that
chain. Three new contracts pass on arm64 Linux with Swift 6.3.2 and SQLite 3.45.1:

- An injected commit refusal rolls back the schema version and DDL, leaves the historical event
  present, leaves no intermediate v5 or later receipt tables, and passes `foreign_key_check`.
- Retrying the upgrade preserves the ordered graph, full grant, tenure and event payloads. The
  same child can be readopted into a new tenure; the new receipt tables work. Both tenures, the
  historical event and receipt survive close/reopen.
- A second active tenure receives the typed constraint refusal without changing history.
  Deleting the manager cascades its grant, both tenures and their event while retaining the
  surviving child's receipt. The upgraded database has no dangling foreign keys.

All **eleven** project contracts pass (five persistence, three recovery, three migration), and
all ten runner tests pass. The 27 vendored production files remain unchanged and byte-identical.
Logs are `out/coreslice-*.log`. This is a synthetic historical database using current model
encodings, not a corpus of old user databases; it verifies this schema-4 upgrade path, not every
historical payload format. No shipping code changed, so no additional macOS build was needed.
StateManager, quarantine and complete host recovery remain outside the executable.


## 34. Downgrades refuse future project schemas, including live WAL

Two additional contracts exercise `ProjectDatabase`'s constructor against a synthetic newer
schema, rather than testing only `SQLiteDatabase`'s optional version bound. Each fixture contains
a real project plus an unknown future table and payload. Both pass on arm64 Linux, Swift 6.3.2,
SQLite 3.45.1:

- A checkpointed future database is refused three times with exact found/supported versions,
  without entering the migration commit seam, changing main-file bytes or creating sidecars.
- A live-WAL future database is refused the same way. The fixture verifies that the main-file
  header still records the supported version while the future version and table exist in WAL;
  this proves the check reads SQLite's effective state, not merely the main header. Main-file
  and committed WAL bytes remain identical across refusals, and the directory entry set stays
  unchanged. The newer writer then updates its unknown payload successfully, closes, and the
  version, project and updated future payload survive reopening.

The shared-memory sidecar's presence is checked, not its byte contents: it is SQLite's transient
coordination state, not the persisted-data assertion. Directory equality proves no artifacts
were introduced by this constructor; this is not a test of StateManager's quarantine policy.

All **thirteen** project contracts and all ten runner tests pass. The 27 production copies remain
byte-identical and unchanged. Logs are `out/coreslice-*.log`. No shipping source changed, so the
previous macOS validation remains applicable. The fixture models a future schema increment and
unknown table, not arbitrary future formats or a complete downgraded application launch.


## 35. Project stores move safely after pinned readers release WAL

Two additional Linux contracts exercise `ProjectDatabase.prepareForFileMove()` and actual
single-file relocation for healthy and deliberately damaged project stores. Each holds an old
reader snapshot while committing a new session, selection, participant receipt and opaque panel
and attachment payloads. The damaged variant also writes invalid JSON into the new session row.

The move primitive refuses while the reader pins WAL and leaves all bundle paths in place; the
reader still sees its original snapshot. After the reader closes, the primitive succeeds,
checkpointing the committed state and removing dependence on sidecars. The fixture closes the
writer and moves only the main file, then reopens through `ProjectDatabase` at the new path.

The healthy variant retains ordered session identities, the latest title and selection. The
damaged variant still fails its authoritative load with the original corrupt row identity; direct
inspection confirms the exact damaged payload and both session rows remain. Both retain the
latest receipt and byte-equivalent opaque auxiliary strings. These strings test storage, not the
panel/attachment codecs. A file move must preserve recoverable evidence rather than turn damage
into missing data.

All **fifteen** project contracts pass on arm64 Linux with Swift 6.3.2 and SQLite 3.45.1. The 27
production copies are unchanged and verify byte-identical; `git diff --check` passes. Full logs are
`out/coreslice-*.log`. No shipping source or runner changed, so the prior macOS and runner-test
validation remains applicable. These fixtures verify the move primitive, not StateManager's
choice to quarantine, naming/recovery policy, or an app-level recovery flow.


## 36. A Linux host connects durable project terminals to the real PTY daemon

The experiment now includes `LinuxHost`, a runnable command-line host with `run` and `list`
operations. It uses the verified production storage slice, the actual `ThreadingPTYHostKit`
package and the production daemon built from `Targets/PTYHost`. A Linux Unix-socket adapter owns
transport only; the package owns frames, identities, bounds and compatibility. Project terminals
keep their proper domain identity instead of borrowing agent-session identifiers.

A run opens an explicitly selected store under an exclusive file lock, loads its graph, connects
and checks the daemon's protocol, saves the project/terminal record, and requests a PTY spawn.
Output is streamed in bounded chunks, input forwarded after spawn acknowledgement, and the
child's exit status returned. A separate invocation reopens and lists the durable records. The
minimal child environment and fixed grid are explicit prototype constraints, not provider launch
policy. No shipping app source changed.

`host-smoke.sh` builds both executables on arm64 Linux and owns a disposable daemon/store. Its
real `/bin/sh` verifies stdin/stdout are terminals, reads forwarded text, reports its working
directory and observes `stty size` as 24×80. Another launch exits 7, which the host preserves.
The reopened store has one project and two distinct terminal records. Additional refusal checks
hold the store lock or remove the daemon rendezvous, and confirm the durable listing is unchanged.
Full build/run evidence is retained in `out/host-smoke.log`.

This moves the experiment from storage verification to an executable local host boundary. It is
not a working native Linux Threading app: raw keyboard mode, resizing, attach/reconnect, agent
launch/account policy, native rendering, accessibility and extension surfaces remain unfinished.
The adapter is experimental, uses debug-only record access and does not replace the asynchronous
macOS client. Store/launch authority is deliberately host-owned; no public UI component is added.


## 37. Terminal watchers reconnect, forward raw keys and follow window size

`LinuxHost attach TERMINAL_UUID` now resolves an existing project terminal from its store and
attaches that exact typed identity through the production daemon. It does not spawn a replacement
or rewrite the graph. Replay status is reported explicitly; a cut raw history is not claimed to
restore an exact terminal screen.

The Linux transport leaf now owns the caller's terminal mode during a live connection. A real
TTY enters raw mode and provides the spawn grid; pipe callers retain the 80×24 fallback. SIGWINCH
sends the current dimensions after binding. A small system module exposes Linux `signalfd`, which
Swift's Glibc module omits. The host blocks relevant signals before storage decoding can create
workers, polls the signal descriptor beside input/output, and restores the caller's mode on normal
exit, errors and handled termination. No Swift work runs in an async signal handler. SIGKILL
remains uncatchable.

The arm64 Linux smoke lane now proves:

- A first watcher exits while its real shell waits in a PTY read. Another watcher attaches the
  persisted identity, receives prior output, delivers new input and observes the same child PID.
  The before/after store listings are identical; an identity absent from the store is refused.
- An outer PTY starts at 31×97. A key sent without a newline reaches the child immediately.
  Changing the outer terminal to 42×113 and sending SIGWINCH makes the child's `stty size`
  observe the new dimensions.
- The complete original caller termios is restored after normal child exit and after external
  SIGTERM. The previous real-shell, exit-status, ownership and persistence checks still pass.

`host-smoke.sh` runs these checks against the actual production daemon; the new Python fixture
uses kernel PTYs and bounded waits rather than mocked transport or grid state. Evidence remains
in `out/host-smoke.log`. Shipping sources are unchanged. This is progress on the runtime/platform
boundary, not native UI, provider launch policy, emulator screen restoration or accessibility.


## 38. Linux and macOS share the login-shell command plan

`ShellCommand` moved unchanged from `AgentLauncher.swift` into its own Foundation-only file.
`AgentLaunchPlan` also became a standalone value. Its new `inLoginShell` factory holds the former
launcher's exact `cd && exec` composition and login-shell argument shape, taking the resolved
shell path as a value. `AgentLauncher` delegates to it and retains shell discovery, account
routing, provider flags, permissions and `launchEnvironment()` resolution. This is a shared
production extraction prepared on this branch, not an alternate Linux provider implementation.

The experiment vendors both files byte-identically: **29 files / 9,040 lines**. `LinuxHost
login-run DIRECTORY SHELL EXECUTABLE [ARG ...]` uses the same factory and quoter with an explicit
Linux shell. It still creates a project terminal; running a CLI this way does not manufacture a
managed agent record or claim that provider lifecycle/discovery has been ported.

The real arm64 Linux PTY smoke passes with a directory containing quotes, dollar signs and a
semicolon, and arguments containing empty strings, Unicode, newlines, leading dashes, quotes and
command-substitution syntax. A real child reports the exact cwd and argument values; substitution
marker files remain absent. Existing shell, reconnect, raw-input and resize checks also pass.
The host therefore shares executable command composition rather than only matching a string
snapshot. The full account/provider policy and native UI remain unfinished.

Shipping verification: all **99** selected macOS tests pass (launch quoting, permission modes and
provider capabilities), with no failures or skips. The app builds with its repository gates.
The Linux host smoke passes, all 29 vendored sources verify byte-identical, and
`git diff --check` is clean. No UI appearance changed.


## 39. Managed Codex sessions share production command assembly

`CodexLaunchCommand` now holds the provider invocation and terminal command composition as a
portable value operation. `AgentLauncher` supplies its resolved conversation overrides, permission
mode and hook flags in the existing order, retaining all account discovery, hook maintenance,
model metadata and default-setting decisions. The same invocation helper supplies the startup
update-check override on non-terminal Mac routes too. Resume preflight remains host-owned; the
builder never substitutes a new conversation for a supplied transcript ID.

LinuxHost's `codex DIRECTORY SHELL CODEX_EXECUTABLE PROMPT` creates and selects a real
`AgentSession(kind: .codex)`, persists explicit Manual permission mode, builds the shared command
and spawns a typed agent identity through the actual daemon. `attach-agent` resolves that stored
session without treating a project-terminal UUID as an agent. The Linux caller's HOME is passed
for CLI-owned existing login state; no macOS credential store is read or copied.

The smoke uses an explicitly named argument-recording executable, not a pretend authenticated
provider. Through a real PTY it verifies the exact prompt (including leading dash, quotes, command
substitution text and Unicode), cwd, no-alt-screen, update override, untrusted approval,
read-only sandbox and user-reviewer flags. SQLite contains one selected Codex session with stored
Manual mode. Reattachment checks reuse of that agent identity and refusal of a terminal identity.

This establishes managed launch wiring and persistence, not a successful authenticated model
turn. Provider transcript discovery/resume, hook/MCP integration, model catalogs, multiple
accounts and native UI remain unfinished. Credentials remain CLI-owned in this prototype;
Threading's own Linux secret-store decision is still open. All production sources are vendored
byte-identically; the dependency slice now contains 30 files.

This integration exposed an EOF/exit race in the experimental host: input may cross a child's
exit and receive `sessionExited` before the actual exit-status frame. The host now suppresses
further input, including readiness from that same poll cycle, and waits up to five seconds for
the authoritative `exited` frame. It never turns the refusal into an invented success or failure
status. The smoke repeats eight immediate exit-7 children with closed stdin to cover this path.

Verification: the finalized Linux host smoke passes all shell, reconnect, keyboard/resize,
quoting, managed-agent fixture, identity-refusal and repeated-fast-exit checks. The macOS app
builds with its repository gates and all **99** launch-quoting, permission-mode and provider
capability tests pass without failures or skips. All 30 vendored copies verify and
`git diff --check` is clean. This is still not evidence of a live authenticated Codex turn.

## 40. The rasterizer reaches a native Linux window

`window-smoke.sh` now opens an SDL2/X11 window under Xvfb, using the existing specimen views
and byte-identical production `PlatinumBitmapFont`. `LinuxWindowBridge` owns only native window
lifetime, pixel presentation and event translation; it does not own product drawing or records.
`WindowHarness` loads an existing production project store on a worker under the host lock and
passes immutable snapshot values to the UI. Selection is local, and only viewport rows exist as
views. This is still diagnostic specimen UI, not the production navigator or a selected backend.

The completed Linux run proved native Down-key selection of Beta, mouse selection of Gamma,
resize from 800×480 to 960×600, Escape dismissal and unchanged durable project/terminal listings.
The captured X window, `out/window-native.png`, was inspected: all three fixture names and terminal
counts are readable, Gamma is selected, and the resized row remains inside the window. The first
run used fixed subsecond waits and failed; the test now waits for the native title and completed
frame dimensions, retains failure logs, and passed. This is correctness evidence, not a latency
measurement or proof of production UI parity.

The experiment deliberately caps software rendering at 1280×900 and label preparation at 80
characters. It builds only visible rows, but high-cardinality preparation and resize latency are
not yet measured. The font still lacks shaping and IME; the window lacks AT-SPI, terminal content,
live store updates, themes and extension composition. These are requirements for a product, not
features the shim claims to supply. The harness is host-only, with no new durable component API.

The platform proof is bounded here. The next shared extraction should address session creation
and launch coordination, keeping macOS and Linux on the same host-independent operations while
platform presentation and notifications stay in adapters. The SDL experiment by itself does not
improve macOS architecture; the production record/runtime and command-plan separations do.

## 41. Fresh-session assembly is shared with the shipping macOS store

`AgentSessionCreation.makeRecord` now owns fresh-record capability admission, handoff destination
validation, unnamed-title defaults, launch options and managed-workspace assignment. The shipping
`ProjectStore.addSession` delegates to it while retaining account/model catalogue admission,
project/identity checks, fallback git lookup, incremental persistence and sidebar notifications.
The Linux host uses the same factory and no longer fabricates the provider name as the title.
Imports and forks retain their separate provenance/resume operations.

The byte-identical CoreSlice now includes 31 production files. Its new Linux contract checks
fresh records across every runtime, account/permission refusal, native-surface clamping, initial
resume state and mismatched handoff refusal. Those checks and the existing 15 persistence contracts
passed. The real-daemon host smoke also passed, including the managed-command recorder's assertion
that the stored fresh session has the same empty title as macOS.

This is record assembly, not a complete shared creation transaction: the Linux host still has its
own project ownership and persistence coordination, and macOS still owns presentation delivery.
The operation creates one record and validates at most the existing bounded handoff chain; it
performs no filesystem, account, process or catalogue work.

The focused macOS run for §41 completed: 56 tests passed across fresh-session creation, provider
capabilities and durable store mutations; the shipping app and repository gates built cleanly.

## 42. Launch environment policy no longer depends on the Mac host

`AgentEnvironment` now takes explicit dictionaries and tool-path settings. Process environment,
macOS preferences and command-line-tool installation paths resolve in `AgentEnvironmentHost`;
`EnvironmentKeys` is a separate Foundation-only vocabulary. The shipping terminal and headless
launchers use the same pure inherited-identity filter. The 33-file CoreSlice compiles it unchanged.

The Linux host applies that filter to its own caller environment rather than substituting a fixed
PATH and dropping account locations. Missing PATH/TERM/LANG retain the experiment's explicit
fallbacks; present values, including an intentionally empty PATH, are preserved. The Linux CLI
keeps caller colour/pager claims because it still forwards to that terminal rather than owning
a graphical emulator. It does not read macOS preferences or transfer the Mac's environment.

The real-daemon Linux smoke passed with an added child-process observation: fixture PATH, HOME,
CODEX_HOME, CLAUDE_CONFIG_DIR and a fixture-only Cursor credential survived, while CODEX_CI,
CODEX_THREAD_ID, CLAUDECODE and AI_AGENT were absent. The observation prints only fixture-key
results on success and never dumps ambient credentials. All existing PTY lifecycle, input,
resize, shell quoting and managed-command recorder checks passed in the same run.

The focused macOS environment verification completed with 10 passing tests: command-line-tool
PATH composition plus production terminal/headless identity, account, colour and pager behavior.

## 43. Both hosts use the production Unix connection boundary

`PTYHostSocket.connect` now serves the shipping macOS PTY client and Linux host. Socket address
construction, close-on-exec setup, the connect deadline and kernel error inspection have one
owner. The caller chooses blocking or nonblocking mode after connection. The deadline uses
monotonic elapsed time, and embedded NUL is refused rather than allowing the kernel to interpret
only a prefix of the requested path. `PTYHostClientError` moved unchanged to a portable file.
The Mac client retains its handshake, session binding, DispatchIO pump, bounded write queue and
diagnostics; Linux retains its stream loop. This is not full client parity.

The 35-file CoreSlice compiled and passed its new Linux connector contract: both requested modes,
close-on-exec, nonexistent and oversized socket paths, and embedded-NUL refusal. Existing session
creation and all 15 persistence contracts passed too. The real-daemon Linux host smoke then
passed through this connector, covering PTY launch/reopen/reattach, raw input, resize, terminal
restoration, shell quoting, environment policy, managed agent identity and authoritative exits.

The focused macOS PTY client run for §43 completed with 18 passing tests, including the new
embedded-NUL refusal and close-on-exec checks.

## 44. Session binding belongs to one portable policy

`PTYHostConnectionBinding` now governs both the production macOS client's send path and the Linux
host. Input requires a binding; spawn/attach cannot replace an existing stream; resize, detach,
close-input and kill must name the full typed identity, not just its UUID. A matching spawn
refusal releases the binding. Connection readiness, locking and byte delivery remain host-owned.

Failed-send rollback uses an opaque attempt reservation. Merely matching the session ID is not
sufficient: after a refusal, a newer attempt may retry that same ID. An older failure must not
clear it. Contracts cover retries for both the same session and a different session, as well as
cross-kind identities sharing a UUID and unrelated refusals. This protects ordering at the policy
boundary; it is not a claim that the synthetic failure ordering was observed in a running app.

The 36-file Linux CoreSlice passed these binding contracts and all existing connector, creation
and persistence contracts. The real-daemon Linux smoke then passed with binding admission wired
into control sends, raw input and received refusals, retaining launch, reconnect, resize, raw-key,
exit-status, quoting and environment behavior. The full client is still not portable: protocol
handshake/admission, diagnostics, bounded asynchronous writes and event delivery remain to share.

The focused macOS verification for §44 completed with 22 passing client/binding tests, including
the same-session retry reservation case.

## 45. Both clients retain the complete hello batch within a finite budget

`PTYHostHandshake` now carries pending deliveries across reads and through the end of the batch
containing hello. macOS and Linux use the same ordering, stderr distinction and daemon-refusal
perspective. Hosts inject control decoding diagnostics and admission effects; socket reads,
retirement writes and event delivery remain outside the policy. Linux now skips additive control
frames consistently with the Mac client and drains retained deliveries before polling again.

The shared handshake bounds pending wire bytes at 4 MiB, counting eight-byte headers as well as
payloads. Even an empty-output flood consumes the budget. Overflow is a typed handshake refusal
before pending delivery; this replaces the Mac path's deadline-only bound on aggregate storage.
Linux also polls against the original hello deadline rather than granting another full wait after
pre-hello traffic.

The 37-file Linux CoreSlice passed hello-batch ordering, stderr, additive controls, refusal
perspective and aggregate-bound contracts, alongside the earlier binding, connector, creation
and persistence contracts. The final Linux host smoke passed its real-daemon checks and two
explicit fake-peer checks: output before/beside hello survives with stderr routed correctly, and
an unknown frame sent three seconds into a silent handshake does not extend its five-second
deadline. These are protocol fixtures, not evidence of an authenticated provider session.

The focused macOS run for §45 completed with 23 passing client/binding tests, including a real
fake-daemon connection that exceeds the pre-hello buffer limit. The shipping app and repository
checks built cleanly. No test process remained active at this checkpoint.

## 46. The full production PTY client runs on Linux

The CoreSlice now compiles all of `PTYHostClient`, not only its portable policy helpers.
`PTYHostClientHost` preserves the app's EventLog-backed initializer and availability probe;
`PTYHostClientDefaults` separates transport bounds from registration and filesystem locations.
The core receives a journal callback and still uses the existing diagnostic logging adapter.
macOS keeps DispatchIO reads/writes. Linux keeps DispatchIO reads and uses a serial socket writer
whose close-on-exec duplicate cannot be reassigned by read-channel cleanup. Sends use socket-local
SIGPIPE suppression and a monotonic whole-frame deadline. Queue admission stays in the shared
client; close cancels queued work before it can start another deadline.

The handshake's retained deliveries enter the event queue after channel-owner allocation and
before live reads start. This preserves hello-batch ordering while ensuring that a failed Linux
writer allocation cannot deliver events from a connection that never finished opening.

`PortablePTYClientHarness` exercised the byte-identical client against the production Linux daemon:
spawn, disconnect, replay and attachment to the same child, input, drain and authoritative exit 7.
It also passed production queue-overflow refusal/binding release, a stalled socket's write deadline,
a closed-peer error without a process-global SIGPIPE override, and queued-write cancellation. The
final `host-smoke.sh` run passed this harness and all existing CLI/PTY/handshake checks. The 40-file
CoreSlice compiled and passed its existing contracts. macOS passed 54 focused client, binding and
terminal-session tests with the host adapter in use. No test jobs remained active at this checkpoint.

The Linux CLI still uses its smaller synchronous Link. Migrating that host and the native window
to the production client's event interface is next; neither its event buffering nor many-client
Linux throughput/shutdown latency has been established by this single-session probe. This is a
runtime portability result, not a complete Linux app or release-readiness claim.

## 47. The Linux CLI uses the production client throughout

Removed the CLI's separate `Link` implementation. Connection, handshake, binding, decoding,
ordered writes and close now come from the byte-identical `PTYHostClient` used by macOS.
`HostEventInbox` bridges its asynchronous callbacks to the CLI's stdin/signal poll loop with a
nonblocking close-on-exec socket pair. Admission, notification and the batch swap share a lock,
so producers cannot lose the wakeup between the consumer's drain and its next poll. Controls,
stdout, stderr and close stay in order. Spawn admission now has one absolute deadline rather
than restarting its timeout whenever another event arrives.

Scaling gate: this host has one connection, typical small interactive chunks and an unbounded
output lifetime/rate. The inbox admits at most 4 MiB of payload/encoded controls and 1,024 events;
empty frames consume entries. One consumer-held batch may coexist with one accumulating batch.
Overflow is an explicit failure, never silent byte loss followed by a successful child status.
Callbacks do not wait for the consumer or write stdout. Controls are charged by encoded size;
output uses its existing byte count without a codec pass. This bounds the adapter, not all
libdispatch internals. CLI stdout can still block its consumer, and graphical integration needs
its own scheduling/backpressure measurements rather than inheriting that behavior.

The full Linux host smoke passed after migration, including real PTY raw keys, initial/live
geometry, exit/SIGTERM restoration, same-child reconnect/replay, persisted identities, launch
quoting/environment/permission rules, hello-batch ordering and the total hello deadline. An added
real-daemon check compared an entire 2 MiB live output stream byte for byte. The portable harness
also checked inbox order/close, notification rearming, byte overflow and 100,000 empty callbacks
with no consumer; the existing full-client queue/deadline/cancellation checks still passed.
The final run exited zero and no test job remains active. No shipping macOS source changed in
this slice; the prior 54-test Mac client/binding/session result is unchanged, not a fresh run.
The native window has not yet adopted this runtime or acquired a terminal emulator/input path.

## 48. SwiftTerm and the production client share a real Linux PTY

Added the existing vendored SwiftTerm package as a direct spike dependency; no emulator source
fork or alternate ANSI parser was introduced. `PTYEmulator` owns the embedding contract: worker
feed/resize/snapshot under SwiftTerm's lock, visible-cell values carrying grapheme text, width and
attributes, cursor/title state, and a callback for terminal replies. The expected grid is 80×24;
admission limits it to 240×100, with 2,000 scrollback lines. Snapshots copy only visible cells.
A future window consumer must keep one snapshot request outstanding at display cadence. This
slice does not claim measured window rendering, shaping, IME, accessibility or snapshot latency.

The first build exposed a generator hang, not a compiler failure. Its Git child exited 128 because
the Docker-mounted worktree's `.git` pointer named host-only metadata. A bounded standalone
reproduction timed out too. A syscall trace showed Git reaped while the generator remained in
Foundation's `waitUntilExit()` run-loop wait. Switching the shared build-info generator to a
termination callback registered before launch completed the same probe. Only then was the exact
stuck generator terminated and the build rerun. A checked-in regression fixture now exercises
unavailable metadata, a clean tagged repository and a dirty repository, each with a process
deadline. It passed against compiled generator binaries on both Linux and macOS.

The final Linux host smoke exited zero. Its emulator contracts cover individually fragmented
UTF-8 bytes, wide/combining cells, SGR foreground, alternate-screen restoration, cursor addressing
and query response, resize and invalid-grid refusal. A real PTY child then checked its cursor
query's response sent through `PTYHostClient`, set its title, accepted a key after resize, observed
100×30 through TIOCGWINSZ and exited 7. The resulting cell snapshot retained the Unicode text and
reported the child's final grid message. All prior client, inbox, CLI, reconnect, handshake,
2 MiB stream and fast-exit checks passed in that same run. No test process remains active.

The native window still has no terminal presentation/input path. These are screen-cell and
runtime results, not inspected glyph evidence. Reattachment to the emulator also remains work:
this adapter is currently for fresh spawns and does not yet implement replay-response suppression
or exact screen reconstruction. The full Linux application remains unfinished.

## 49. A native Linux window displays and drives a real terminal

`WindowHarness --terminal STORE SOCKET DIRECTORY ABS_EXECUTABLE [ARG ...]` now opens a native
SDL window backed by the production client and SwiftTerm. A worker connects, creates a durable
project-terminal record through the production SQLite store under its transaction lock, and
spawns the child. Input admission waits for the matching spawned identity. Exit is the matching
daemon status and remains visible in the native title. Closing disconnects; it does not take
process ownership away from the daemon. This mode is a host-only diagnostic embedding, not a
new extension component or a completed product navigation flow.

SwiftTerm feed/resize/snapshot runs on a serial worker. A separate Pango/Cairo worker renders
visible cell graphemes with font fallback, foreground/background, bold, underline and cursor.
The shared package gained `Terminal.ansiColor(at:)` so the renderer reads the live palette,
including OSC 4 changes, rather than inventing a second palette. A runtime contract changes an
indexed color and checks the snapshot RGB. The fixed diagnostic face is 16px DejaVu Sans Mono in
10×22 cells; the native window's 1280×900 cap implies at most 128×40 cells. This does not prove
cross-cell script joining, full terminal styles, IME composition or accessibility.

Frame admission is at most once per 33 ms, even when native events arrive continuously. Only one
snapshot/raster request can be outstanding, with one completed RGBA frame retained for the UI.
Visible UTF-8 export also has a 4 MiB cap. The UI uploads the completed image and handles events;
it does no database access, protocol parsing or font shaping. Native expose events repaint the
existing texture. A dense-grid opt-in child fixture emits 300 full grids at 60 Hz for subsequent
stress measurement; that dense workload has not been run at this checkpoint.

The final `window-smoke.sh` run exited zero. It reran the portable client/emulator contracts and
the original project-list navigation/resize/store-preservation checks, then launched a real raw
PTY child in terminal mode. Native X events typed `native-input`, resized the window to 960×660,
and the child verified both the bytes and its 96×30 TIOCGWINSZ result before exiting 7. Alt-F4
closed cleanly and the production store reopened with exactly one additional terminal record.
The first attempt's `xdotool windowclose` destroyed the X window without a window manager and
failed during XInput cleanup; the final test exercises the native close shortcut instead.

Inspected `out/terminal-native.png` from the final product-shell experiment: the CJK cell, combining
accent, Ångström, indexed green and true-color blue text, typed line, confirmed grid and cursor
are visible without replacement boxes or overlap in this fixture. This is evidence for those
rendered glyphs and interactions, not broad language or accessibility coverage. The small screen's
warm worker rasterizations were 5.0–7.0 ms and warm UI presentation 2.9–4.1 ms. First text shaping
was 193 ms on the worker; first blank-frame presentation was 10.4 ms. These are Debug Docker/Xvfb
samples, not dense-grid, tail-latency or many-session results.

The macOS shipping build and all 38 `TerminalColorQueryTests` passed with the new SwiftTerm
palette accessor. No test jobs remain active. Full native project/session navigation, emulator
reattachment, complete keyboard protocols, scrollback/selection/clipboard, IME, AT-SPI, profile
and theme integration, and packaging remain unfinished. Changes are uncommitted.

## 50. Dense terminal output reuses shaped ASCII without changing pixels

The maximum-grid workload is now automated by
`THREADING_LINUX_TERMINAL_STRESS=1 ./window-smoke.sh`. It resizes to 1280×900, starts a real PTY
child's 300 full-grid updates at 60 Hz, probes keyboard acknowledgment during output, waits for
authoritative exit 0, captures the final screen and verifies frame production stays idle after
output/exit settle. Moving the window to (0,0) before resizing is required: the first run's
centered window extended outside Xvfb, so its screenshot captured only 1100×764 of the surface.
The final matched runs both capture the complete 1280×900 grid.

The direct renderer reshaped identical ASCII in every cell. `TerminalDrawing.c` now keeps at
most 95 printable ASCII layouts × two weights for one frame. This is a fixed array with no
externally sized key collection. Foreground/background remain per-cell, and the existing Pango
drawing path keeps antialiasing. Unicode still uses direct Pango, including fallback and color
fonts. All cached layouts are released at the frame boundary. A first alpha-mask cache trial was
discarded: it changed antialiasing pixels and did not improve the measured keyboard result.
Do not infer mask equivalence from a similar-looking screenshot.

`terminal_renderer_contract.py` compares the actual C renderer against direct Pango over mixed
ASCII weights, colors, underlines, combining accents and wide cells, requiring exact RGBA bytes.
That contract passed repeatedly. The final native interactive (960×660) and dense (1280×900)
screenshots also matched reference and cached output byte for byte. Inspected the complete dense
window: all 40 rows and the full 128-column extent are present. The explicit reference switch,
`THREADING_TERMINAL_REFERENCE_RENDERER=1`, keeps the same workload available for future checks.

Matched Debug Docker/Xvfb results, with identical final geometry and child workload:

| Metric | Direct Pango | Cached layouts |
|---|---:|---:|
| Dense-frame samples | 74 | 103 |
| Worker draw median / p95 | 33.90 / 42.86 ms | 18.17 / 31.04 ms |
| UI presentation median / p95 | 7.89 / 12.46 ms | 9.45 / 25.76 ms |
| Keyboard acknowledgment probe | 129 ms | 93 ms |

Worker median improved about 46%. Presentation tails did not improve; sample counts differ
because the faster worker publishes more frames during the same output workload. These shared
machine measurements establish reduced repeated shaping work and exact rendering preservation,
not a frame-rate or end-to-end latency guarantee. They exclude many-session behavior, IME and
cross-cell script joining. Idle verification means no new rendered frames, not zero timer wakeups.

Both final native runs exited zero, including pixel contracts, portable client/emulator contracts,
project selection/resize, interactive input/resize/exit/persistence, stress input and idle checks.
No test jobs remain active. This slice changes the Linux renderer and its fixtures only; the
prior macOS 38-test color result is unchanged, not a new Mac run. Changes remain uncommitted.

## 51. Native functional keys use SwiftTerm's live keyboard modes

Removed the native bridge's fixed escape table for functional keys. SDL now reports semantic key
identity, modifiers, and press/repeat/release. The graphical host maps that finite vocabulary to
SwiftTerm's existing `TerminalFunctionalKey` API. `PTYEmulator` calls `encodedFunctionalKey` under
the terminal lock on the same worker that processes output, so DECCKM and kitty mode changes are
read live rather than copied into UI state. No new encoder or shipping SwiftTerm change was needed.

Text and functional keys now share one ordered worker hop. Sending text directly while queuing a
Backspace would let subsequent text overtake the edit; both now enter `Terminal.sendUserInput`,
which also preserves SwiftTerm's semantic interaction state. Admission is bounded at 256 pending
events plus the executing event, with 32 bytes per native text event. Overflow publishes an
explicit failure and stops further admission. This cap is an implementation bound; saturation of
that new input queue was not separately injected in this slice.

The portable emulator contract passed normal/application arrows, modified navigation, legacy
repeat/release behavior, kitty repeat/release and ordered text/editing. The native fixture then
switched modes in a real raw PTY child and verified bytes from actual X keyboard events: normal
Up, application Up, Ctrl-Right, kitty Ctrl-Tab, kitty Up press/release, Home/End, Page Up/Down,
Delete, F2, and mixed text/Backspace/Return. A text marker after keyup separates each mode change,
so the fixture does not change modes while a preceding key is still held. Inspected the rendered
`out/terminal-keyboard.png` showing the child's successful checks; the window closed normally.

The final stress-enabled window smoke exited zero, rerunning renderer pixel equivalence, portable
client/emulator checks, project navigation, native terminal resize/input/exit/persistence, native
keyboard modes and the maximum-grid live-output fixture. The input acknowledgment under that
load was 96 ms in this run; it is one probe, not a latency guarantee. No test jobs remain active.
No shipping macOS source changed in this slice, and no new Mac test run is claimed.

Coverage is deliberately specific: enhanced printable-key reporting, full keypad/Insert handling,
IME composition and desktop shortcut integration remain unfinished. The graphical host's handling
of input racing child exit also needs the explicit late-input/authoritative-exit policy already
used by the CLI; these staged fixtures do not cover that race. Project/session navigation and
reattachment to the graphical emulator remain separate unfinished app work. Changes are uncommitted.

## 52. Keep the graphical terminal alive across late-input refusal

The graphical host previously treated every in-band error as fatal. Input can cross the child's
exit, however: `sessionExited` qualified by `input` refuses that input without carrying the child's
status. The window now stops input admission and waits for the matching authoritative `exited`
frame, following the CLI's existing policy. One worker-owned five-second monotonic timer is armed
on the first refusal; repeated refusals neither allocate more timers nor extend the deadline.
A completed exit makes the timer inert, and window closure prevents late failure publication.
Other errors, disconnects before exit and mismatched exit identities remain failures.

The native wire fixture sends an actual X keyboard event, observes its input frame, then controls
the peer ordering. It covers exit status 7 with the window still open past the timeout, repeated
refusals without an exit, an unrelated error qualifier, disconnect and a wrong session identity.
This complements the smoke suite's real-daemon PTY checks; it does not replace them.

Validation: `window-smoke.sh` exited zero, including all five native exit-ordering cases,
real-daemon client/emulator checks, project navigation, native input/resize/persistence and
functional keyboard modes. `git diff --check` passed. The optional dense-output stress lane was
not repeated for this lifecycle-only change. No shipping Mac source changed in this slice;
no new Mac test run is claimed. Graphical reattachment and combined project/session navigation
remain unfinished, and the branch work remains uncommitted.

## 53. Project activation reaches a live terminal in the same native window

`WindowHarness --app STORE SOCKET ABS_SHELL [ARG ...]` connects the existing project browser to
`GraphicalTerminal`. Enter creates one durable terminal in the selected project's directory;
Ctrl+Shift+P returns to projects, and Enter revisits the retained child/emulator rather than
spawning again. Both views reuse the same native window. The activation Return's remaining key
repeat/release is consumed at the mode boundary so it cannot become unsolicited terminal input.
The standalone diagnostic modes remain available.

Customization decision: this remains a deliberately host-only diagnostic platform embedding,
not a public extension component or shipping replacement sidebar. Store identity, launch,
process/input ownership and navigation stay host-owned. The existing specimen draws the bounded
project viewport; the existing terminal renderer draws the selected emulator.

Scaling decision: expected navigation covers a few projects; the retained-runtime ceiling is
eight terminals, checked before creating another runtime. Each retains the existing capped grid,
2,000-line scrollback, one pending render and one published frame. Hidden terminals continue
processing child output to preserve emulator truth but receive no new render requests. Switching
uses one keyed lookup and renders only viewport rows; it does not reload the whole catalogue.
The initial store snapshot still loads on a worker. Newly saved terminal counts are published
under the existing runtime lock. This is not a many-session memory or throughput measurement.

The native journey fixture opens two real daemon children in different project directories,
returns through projects, revisits the original child and screen, then exits both children and
returns to projects. A child refuses a duplicate spawn via a per-project marker, and records its
actual PID and cwd. The journey captures both the project browser and the revisited terminal.

Validation: the complete `window-smoke.sh` run exited zero, including the new two-project native
journey and all existing client, emulator, renderer, keyboard and exit-ordering checks. Inspected
`out/project-terminals.png`: the selected project, retained-terminal stars, counts and navigation
hint are visible. Inspected `out/project-terminal-revisited.png`: the original project, PID,
directory and earlier output remain beside the revisit acknowledgment. `git diff --check` passed.
The eight-runtime ceiling and many-child throughput were not stress-tested in this slice. A
terminal failure still ends this diagnostic window; per-terminal failure presentation remains
unfinished. No shipping Mac source changed or Mac tests ran. Changes remain uncommitted.

## 54. A failed terminal does not close the project browser

In the integrated native host, `GraphicalTerminal.takeFrame()` failures now enter a retained
terminal-unavailable view instead of escaping the application event loop. Only that terminal's
client is stopped. Ctrl+Shift+P returns to projects, where another retained terminal remains
usable. Revisiting the failed entry shows its failure again; it does not create another durable
record or silently retry a launch. Standalone `--terminal` retains its nonzero failure exit for
command-line diagnostics. Native-window presentation errors still terminate the window.

The error view uses the existing host-only specimen surface and production bitmap font. Its
message is capped at 1,024 Unicode scalars, unsupported characters are explicit question marks,
and wrapping measures glyph advances within the current viewport. The maximum line count comes
from available height, with an ellipsis when the viewport truncates the message. Failed views
wait for native events instead of polling frames; resize alone rebuilds their bounded display.
Terminal input is not admitted from the error view. No extension contract or Mac surface changed.

The project journey now takes an actual competing lock on the disposable store while Gamma is
activated, keeping Alpha and Beta running. It captures normal/narrow failure surfaces, sends a
key to the failed view, releases the lock, revisits the retained failure, then returns to Alpha's
original child/screen and exits both healthy children. Gamma must never create a child marker.

Visual review caught two issues in the first narrow capture: it sampled the old texture stretched
before the resize redraw completed, and the completed redraw split ordinary words at arbitrary
glyph boundaries. The fixture now waits for `FAILURE_FRAME 320x480` after presentation rather
than sleeping for an assumed redraw duration. Diagnostic wrapping prefers the last space that
fits, with glyph wrapping only for an overlong word. These are rendering/capture findings, not
claims that the behavioral assertions alone verified layout.

Final validation: the smoke suite exited zero after the wrapping correction, including the real
store-lock failure, navigation back to both surviving children, and existing client/emulator,
keyboard, exit-ordering and renderer contracts. Inspected the final 800x480 and 320x480 captures:
the cause and return shortcut are readable, with whole words at the narrow width. `git diff
--check` passed. The optional dense-output lane and Mac tests were not repeated; this slice changes
only the Linux diagnostic host. Explicit retry/replacement and graphical restart restoration
remain unfinished. Work remains uncommitted, and no test process remains running.

## 55. Explicit terminal replacement requires evidence that no child remains

Ctrl+Shift+N in the integrated project browser creates a replacement for the selected terminal;
Enter continues to revisit it. The shortcut is advertised when replacement is admitted. Before
attempting a spawn send, the runtime marks child ownership uncertain. Only a matching `exited`
frame or a matching definitive spawn refusal clears that uncertainty. `alreadyExists` cannot
clear it, because that refusal says a child may exist. A pre-spawn failure can be replaced; a
live child, lost spawn reply, write failure or disconnected running child cannot. Replacement
never sends kill. The prior client stops, the new runtime gets a fresh durable terminal identity,
and previous saved records remain counted rather than disappearing when the cache entry changes.

This stays within the eight-entry runtime cache; replacement changes one entry. The per-project
historical count is a scalar, not another retained runtime or emulator. Native activation consumes
the shortcut's remaining repeat/release events across the mode switch, as Enter already did.
No shared Mac behavior, new extension contract or new chrome component is introduced.

The real-daemon journey retries Gamma after a store-lock failure, exits it, explicitly replaces it,
and verifies a distinct child PID in the same directory. It also refuses replacement of live
Alpha and checks exactly four new durable terminal records across the whole journey. A separate
controlled peer receives spawn then disconnects without a result; Ctrl+Shift+N must refuse and
must not connect again. That fixture uses a SQLite backup of the disposable production store,
not a hand-authored schema.

Validation: `window-smoke.sh` exited zero with both new replacement journeys and all existing
native/client/emulator/renderer checks. Inspected `out/project-terminal-replace.png`: the selected
project, accumulated terminal count and distinct view/new-terminal shortcuts are legible.
`git diff --check` passed. Individual definitive spawn-refusal reasons were not separately injected
in this slice; the exercised paths are pre-spawn store failure, confirmed exit, live child and
unacknowledged spawn/disconnect. No Mac test or dense-output stress rerun is claimed. Graphical
restoration and selecting among persisted terminals remain unfinished. Changes remain uncommitted.

## 56. Replay needs a byte boundary before an emulator can reattach safely

The daemon already orders `attached`, historical output, then live output, but the old frame did
not state how many output bytes were replay. `totalBytesWritten` is a ring offset rather than
replay size: seeds and CAN are not counted there, and overwritten history still is. Suppressing
responses for an arbitrary callback or time interval would either answer historical queries or
swallow live replies.

The shared `PTYHostAttached` now carries optional `replayByteCount`, computed from the exact
payload array the daemon queues. Nil means an older peer omitted the field, not zero. The
additive field leaves existing callers and Mac attachment behavior intact. Wire tests distinguish
missing, zero and nonzero boundaries. Real-daemon tests assert both cut history including CAN and
exact history including screen/mode seeds. The calculation examines the bounded payload list,
not every byte of its data.

`PTYEmulator.feed(..., replaying: true)` parses under the terminal lock while suppressing delegate
sends, then restores ordinary sends. The portable harness consumes the announced byte boundary,
including a callback split between replay and live bytes, and refuses missing/invalid counts.
It reconnects a fresh emulator to a child that has already consumed its first cursor-query reply.
The next child input must be the user's x, not another historical query response; the reconstructed
cells, subsequent resize and exit status are checked too. Fragmented historical queries and
resumption of live query replies have a separate emulator contract.

This closes a transport prerequisite rather than claiming graphical restoration is implemented.
At this point the window still needed persisted-terminal selection, bounded attach lifecycle and
explicit cut-history presentation; exact screen/mode seeds for graphical detach were also unfinished.

Validation: all 78 PTY wire-package tests passed on macOS. The shipping Mac app build and two
focused real-daemon tests passed, proving exact-seed and cut-tail byte counts through the bundled
helper. The full Linux window smoke also exited zero, including the live emulator reconnect and
existing native navigation, replacement, failure, keyboard and rendering contracts. `git diff
--check` passed; no localization or project-file churn appeared. No new appearance change or
visual claim is made in this slice. Work remains uncommitted and no test job remains active.

## 57. A second native window can attach a saved terminal without respawning it

`WindowHarness --attach STORE SOCKET TERMINAL_UUID` validates project-terminal membership through
the production database on its worker, then uses the shared client to attach the existing daemon
identity. It creates no record and never sends spawn. The same client/emulator setup now serves
fresh and attached sessions. A five-second worker deadline bounds the attach/replay wait;
missing, negative or over-budget replay counts fail rather than enabling input on guessed state.

The worker parses precisely the historical byte prefix with replies suppressed. Only completed
replay admits native input and frame requests. The daemon grid is adopted by publishing a single
initial viewport to the UI. A worker acknowledgment of that publication fences older queued frame
requests, so a request carrying the initial default window size cannot resize the child before
the UI adopts its grid. Grids beyond the current window's 128-column/40-row ceiling are refused.
Cut replay is explicitly labeled in the window title; it is not claimed as exact reconstruction.

The native fixture launches a real raw child, answers its cursor query, resizes to 96x30 and
closes the first window process. A second process attaches the saved terminal identity. The child
asserts that no additional SIGWINCH occurred and that its next byte is user input, not a duplicate
reply to its historical query. A new live query still receives a reply. The fixture compares
saved record listings, child PID metadata and physical window dimensions, captures the rejoined
screen, then checks exit 7. Controlled peers separately omit the boundary, send an invalid one,
or leave replay incomplete; none may publish a terminal frame or wait indefinitely.

This is still a host-only diagnostic entry point. In this slice, persisted-terminal selection
inside the project browser, automatic restoration and graphical detach seeds remained unfinished.
No new extension component or shipping Mac presentation is introduced.

The first rendered-evidence run exposed a presentation defect after the host adopted the saved
grid. The attached frame's immutable input contained the expected text and a 960x660 background;
reading SDL's software-renderer surface after `SDL_RenderCopy` showed those same pixels across the
full extent. The X11 drawable still showed only a blank 960x528 surface plus a black strip. Delayed
captures and rebuilding the renderer did not change it, so emulator replay, rasterization and
renderer allocation were excluded as causes.

`tw_resize` now marks the rare host-driven resize. Present and repaint still use the software
renderer, then explicitly flush its owned window surface with `SDL_UpdateWindowSurface` only for
that path. User-driven resize keeps the ordinary SDL event/renderer path and pays no extra update.
The renderer rebuild experiment was removed. The retained pixel assertions require the adopted
surface's last pixel and visible replay text, so the original blank 960x528 result cannot regress
silently.

Validation: the focused real-daemon attachment fixture passed the same-child, grid, replay-query,
live-input, visible-pixel, exit and malformed-peer contracts. The inspected 960x660 screenshot in
`out/terminal-reattached.png` shows the original child PID and live `SAME CHILD, GRID AND HISTORY`
line over the full terminal background. The complete `window-smoke.sh` run then exited zero,
including native project navigation, ordinary window resize, terminal rendering, functional keys,
exit ordering, replacement safety and all attachment refusals. `git diff --check` passed. No Mac
code changed in this follow-up. Changes remain uncommitted and no test process remains active.

## 58. The project browser can select and attach a saved terminal

Right on a selected project now opens its saved terminals, newest first. Up/Down and pointer
selection use the same bounded row geometry as the project list; Enter attaches the selected
persisted identity through `GraphicalTerminal`, and Left or Escape returns to projects. Returning
from a terminal with Ctrl+Shift+P preserves the picker context. A retained runtime is starred in
the picker and its project is starred in the outer list. Fresh-terminal creation, revisit and
explicit replacement remain separate project actions.

The database snapshot is still decoded on a worker. It projects at most the newest 512 terminal
identities and bounded display titles per project, while rendering constructs only viewport rows.
Fresh runtimes are keyed by project identity and restored runtimes by terminal identity; both
caches share the existing eight-runtime ceiling. Hidden runtimes continue processing their bounded
emulators but receive no frame requests. The snapshot is fixed for the window lifetime, so external
records do not appear live and no terminal restores automatically.

This remains a host-only diagnostic surface built from the existing `Specimen.Window` and
`Specimen.Row`. It is not a public extension component. The host keeps store validation, launch,
process, input, resize, persistence and navigation authority when presentation is customizable.
No shipping Mac UI or source changed.

The end-to-end fixture creates an older dormant record and then a live persisted terminal, resizes
the latter to 96x30, closes its first window while leaving the daemon child alive, then reaches both
identities through the project picker. It verifies newest-first selection, Down/Up navigation, the
same child PID, adopted physical window size, replay boundary, live query/input and exit status,
and proves the attach did not alter durable records. The fixture also exposed that the bridge had
collapsed keyboard Escape and window quit into one event while translating Alt+F4 only in terminal
mode. Keyboard cancel now has its own event; SDL/window quit remains distinct, and Alt+F4 is handled
in both host modes.

Validation: the complete `window-smoke.sh` run exited zero after the event fix, including the new
picker journey and all renderer, event-inbox, emulator, keyboard, production-client, native project,
replacement, exit-ordering and malformed/incomplete attach checks. The final two-record,
scalar-bounded-title version then rebuilt and passed its isolated real-daemon/Xvfb journey. Two
attempts to repeat the whole suite in the subsequently degraded Docker VM stopped in the older
project journey before reaching the picker: one lost Xvfb, and one missed Gamma's eight-second
title deadline after the daemon had spawned it. Inspected `out/project-terminal-picker.png`: both
saved rows, the newest selected terminal, shortcut hint and persisted-ID prefixes are visible in
the real X11 window. Automatic restoration, live store updates, exact graphical detach seeds and
full scrollback reconstruction remain unfinished. No Linux test process remains active.

## 59. A saved agent session can reopen in the native terminal window

`WindowHarness --attach-agent STORE SOCKET SESSION_UUID` now resolves a persisted `AgentSession`
under the store lock and attaches its `agentSession` daemon identity. The existing graphical
terminal pipeline handles bounded replay, renderer activation, input, resize and exit; it does
not create another durable record. The previous `--attach` path still resolves only project
terminals. This is a host-only diagnostic entry point, not a public extension component or a
shipping agent-session browser. The host owns store validation, process and PTY authority, and
the window remains presentation only.

The real-daemon/Xvfb fixture launches a managed Codex session through the shared login-shell
plan using an explicit test executable, stops the CLI client, then opens the saved identity in
the native window. It checks the original child PID, cut-history title, adopted 80×24 grid,
no attachment resize, live keyboard input, exit status 9 and unchanged persisted listing. An
unknown valid session UUID is refused. The focused fixture passed. `WindowHarness` and the daemon
built on Linux; the existing focused project-terminal reattachment fixture also passed its
same-child, grid, replay-query, live-input, exit and malformed-peer checks. The vendored
production files remained byte-identical. The complete window suite
passed its earlier native window, keyboard and terminal checks but stopped in the pre-existing
project-navigation fixture before reaching this new case: the fixture missed the return-to-projects
title deadline after the terminal frame had rendered. No Mac source changed in this slice.

## 60. The project window can navigate saved agent identities

Left from a project now opens its persisted agent sessions, newest first; Right keeps the
saved-terminal picker. Both use a fixed initial store snapshot, at most 512 identities per kind
and project, and viewport-only row construction. Their retained runtimes share the existing
eight-entry ceiling and use typed agent/terminal cache keys so an equal UUID cannot cross the
identity boundary. Enter on an agent attaches its persisted `agentSession` identity using the
same replay and native terminal path as explicit `--attach-agent`. Ctrl+Shift+P returns to the
same picker and selection. No new child or durable record is created by navigation. This is a
host-only diagnostic presentation; process, identity, membership and input authority stay with
the host. Starting or resuming a dormant agent from the window is still unfinished.

The real-daemon/Xvfb fixture stores an older exited Codex session and a newer live one, closes
the CLI client, then exercises the standalone attach and project-window picker. It checks the
newest selection, Down/Up movement between distinct IDs, same child PID, replay, live input,
exit 9, return navigation, and unchanged store listing. The inspected `out/agent-picker.png`
shows two rows with the newer one selected. The existing saved-terminal picker fixture passed
against the same rebuilt window.

The full `window-smoke.sh` run passed all renderer, client, native navigation, replacement,
picker, replay and refusal checks. Two earlier full runs had missed different keys in the older
project-navigation fixture after X11 focus changes, with no following selection frame. That
fixture now waits for `xdotool windowfocus --sync` before delivering each key and uses a 50 ms
key delay; this is a test-stimulus change, not product event handling. The subsequent complete
run passed the previously failing journey and both pickers. Mac product source was unchanged.

## 61. The Linux project window starts a managed Codex session

`WindowHarness --app-codex STORE SOCKET ABS_SHELL ABS_CODEX` now accepts an explicit local Codex
executable. Ctrl+Shift+A on a selected project creates a fresh `AgentSession` using the same
production record, command and login-shell plan policies as `LinuxHost codex`. The graphical
terminal worker reopens the store under its nonblocking lock, confirms the project still belongs
to it, saves the selected record, then sends an `agentSession` spawn. It uses the window's actual
cell grid at spawn rather than booting the TUI into a placeholder grid. The newly persisted
identity joins this window's bounded saved-agent picker; selecting it reuses the retained
emulator and child. A competing store owner refuses creation before a record or child appears.

This adds a host-owned create action to the existing diagnostic project surface, not a new
public extension component. The host retains project/identity checks, permission defaults,
store ownership, process launch, input and exit truth if presentation later becomes customizable.
The Linux mode has no account/model picker, provider transcript-ID discovery or dormant-session
resume yet. Its real-daemon fixture uses an explicit test executable, so it verifies the managed
command flags and terminal behavior without claiming an authenticated Codex login.

The focused Docker/Xvfb journey passed: one Manual/read-only Codex record and selected ID,
80×21 initial PTY, unchanged child PID on picker revisit, live input and exit 6, plus unchanged
store contents after lock refusal. I inspected `out/agent-create-project.png` and
`out/agent-create-picker.png` in the native window; the new command hint and retained agent row
are visible. A focused rerun after the retained-project mark fix also passed; the inspected
`out/agent-create-returned.png` shows the persisted agent count and retained-runtime star on the
project row. The complete `window-smoke.sh` run passed before that final presentation fix. Its
final-code rerun stopped before the new fixture in the older project-navigation test: the second
rapid Up key did not produce an Alpha selection after the first selected Beta. Six subsequent
isolated real-daemon/Xvfb runs of that older journey passed, and the focused agent-creation and
lock-refusal journeys passed on final behavior. The loaded-suite key loss remains unresolved; a
passing focused journey is not a full-suite result. No Mac product source changed.

## 62. A saved Codex agent can carry its provider identity into a later Linux window

Codex does not accept a caller-supplied session ID. The rollout header reader is now a
Foundation-only core operation shared with the Mac discovery path and vendored byte-identically
into the Linux slice. It checks only launch-adjacent day directories, reads at most 64 KiB from
each candidate, caps directory entries, matches the recorded working directory and creation
time, and refuses multiple matches. Linux polls it on a utility queue after the daemon confirms
spawn, then saves the provider ID only while the original session still awaits one. A rollout
that never appears leaves the record awaiting an ID.

Selecting a saved Codex agent first attaches to the daemon's existing identity. If the daemon
reports that identity unknown, the window reloads the record under the store lock and builds a
shared `CodexLaunchCommand` resume for its persisted provider ID. It never turns an unknown ID
into a fresh conversation or adds a second session row. Live agents still reattach to the same
child; exited agents can start a new child for the same conversation. The host owns identity,
store, process and PTY authority; this remains the diagnostic host-only window surface.

The real-daemon/Xvfb fixture uses a fake Codex executable that writes a `session_meta` rollout
and later records the exact `resume <provider-id>` argv in a second app window. It also verifies
the original permission flags, PTY, retained-child revisit, exit, store lock refusal and
unchanged session count after resume. The fixture does not prove an authenticated Codex login or
test concurrent same-directory provider launches; those still need product-level validation.
The final `window-smoke.sh` run passed the complete native renderer, project, terminal, agent,
replay and refusal suite, including the new resume journey. The focused Mac rollout-identity
test passed on the final lazy-directory-walk source.

## 63. Linux Codex launches bind to the account their record names

The Linux window previously persisted a `.standard` Codex account but inherited `CODEX_HOME`
from whichever shell opened it. A later window could therefore resolve a provider ID under a
different login from the one that created the session. The account command prefix now comes from
the same Foundation-only assembly as the Mac launcher: a standard record runs through
`env -u CODEX_HOME`, inside the login shell, so a shell profile cannot reintroduce the inherited
alternate path. The headless Linux host uses that prefix too. Named accounts remain unsupported
by this diagnostic host and are refused on resume rather than silently routed to the default.

The saved-agent path still asks the daemon first. Only when its identity is absent does it reload
the record under the store lock, locate that exact provider ID in the default account's rollout
tree near the record's creation day, and apply the Mac's bounded mixed-ordinal health check.
Missing or known-broken rollouts leave the durable session untouched and start no child. The
lookup is bounded per selected resume, not a scan in project-list rendering. It does not make
rollout discovery in concurrent same-directory launches exact, support named accounts or prove
an authenticated Codex turn.

The complete native Docker/Xvfb `window-smoke.sh` and headless `host-smoke.sh` suites passed on
this route, including wrong-account and broken-rollout refusals. The focused macOS launch,
rollout-identity and resume-health suite passed 40 tests. Both Linux suites use a fake provider,
so an authenticated Codex resume remains unverified.

## 64. A clean Linux profile can open a project and keep its terminal across window restarts

The native window previously required an existing experimental database and an already-running
PTY daemon, so the only path to its first project was a separate host command that also launched
a shell. `LinuxHost --add-project STORE DIRECTORY` now imports an existing directory without a
daemon or a terminal record. It canonicalizes symlinks with the same Foundation-only project path
rule as the macOS `ProjectStore`, deduplicates by that durable path, and uses the existing
nonblocking store lock. It inserts only the new project row and graph generation, preserving
standing session and project payloads; missing directories refuse before creating a store.

`run-app.sh DIRECTORY` is a source-tree Linux development entry point. It builds the existing
host and native window, uses private XDG data/runtime directories, imports the project, then
starts or reuses `threading-ptyd` under a startup lock before opening that same native window.
Only the daemon replaces a stale socket. Closing the window leaves the daemon and its running
children alive; running the command again reaches the saved terminal picker and the same child.
Project identity, store admission, daemon rendezvous and process ownership stay host-owned; this
adds no extension presentation API or new window component.

The complete `host-smoke.sh` passed the offline import, symlink deduplication, missing-path and
lock refusals, a standing-row sentinel, and an actual PTY launch through the alias. The complete
Docker/Xvfb `window-smoke.sh` passed the native terminal, agent, renderer, refusal and new startup
journeys. After the incremental-import and caller-relative-path fixes, its focused startup lane
again passed clean-profile launch, same-PID reattach and daemon reuse on final code. The focused
macOS `ProjectStoreMutationTests` passed 11 tests, including the symlink-identity case. This is
still a development command, not a packaged release or a project picker. Authenticated Codex, IME,
accessibility, theme parity and other product surfaces remain outside this evidence.

## 65. Linux launch writes leave standing conversations alone

The CLI and native window previously used `ProjectDatabase.save(state)` for each terminal or
agent creation and for Codex rollout-ID discovery. That re-encoded and upserted every retained
project and session after loading the graph, even though the user changed one row. A newer-format
field in an unrelated row would be dropped, and launch cost grew with the complete archive.

Both Linux hosts now use the production exact-row mutations. An existing-project Codex launch
inserts one session and its selected ID in one graph transaction. The first Codex session in an
unknown project uses `addProjectAndSession`, so a failed commit leaves neither project, session
nor selection. A terminal launch updates its owning project row (terminals still live inside that
payload), or adds one new project row containing its first terminal. Codex provider-ID discovery
updates only its standing session. Each host still loads the graph on a worker, so this removes
whole-graph write/encoding cost, not the current whole-graph read or the size of a project's own
terminal array.

The real-daemon Linux host suite passed recorder-backed Codex launches and shell terminals in
existing and new projects while preserving exact unknown-field sentinel bytes in another project
and standing conversation. The complete native Docker/Xvfb suite passed the same preservation
check through graphical Codex creation and rollout-ID discovery, plus its terminal, picker,
resume, renderer, startup and refusal journeys on the final shared database code. Focused macOS
`ProjectDatabaseTests` and `ProjectStoreMutationTests` passed 62 tests (one skipped), including
rollback for session/selection and first-project/session transactions and byte preservation for
standing rows.

## 66. Native terminal clipboard paste reaches the child as one ordered gesture

The SDL window handled committed text and functional keys but had no clipboard route, so a user
could type a command but could not paste a path or multiline prompt. Ctrl+Shift+V now requests
text from the native clipboard. The host accepts only valid UTF-8 up to 64 KiB, refuses a larger
selection without sending a truncated prefix, and sends the accepted bytes through the existing
ordered terminal worker. The emulator reads its live bracketed-paste mode under its terminal lock
and emits the same start/text/end sequence as the macOS terminal when that mode is on. The
shortcut's printable `v` and control byte are suppressed rather than leaking into the child.

The bound applies after SDL retrieves the X11 selection: `SDL_GetClipboardText` may allocate the
whole source text before the host can inspect its length. Retrieval happens only for an explicit
paste, outside the frame loop. Selection, copy, rich clipboard types and IME composition remain
unimplemented in this diagnostic surface. Input routing and transport remain host-owned; this
adds no extension presentation API.

The complete Docker/Xvfb `window-smoke.sh` suite passed on the final code. Its new real-child
fixture set the X11 clipboard, sent native Ctrl+Shift+V, checked exact Unicode and multiline
bytes with bracketed paste on, checked plain bytes with the mode off, and proved a 64 KiB-plus-one
selection was refused before a following small paste completed. This is clipboard/PTY evidence,
not an IME, copy/selection, or installed-distribution check.

## 67. A selected agent no longer reloads every saved conversation

The native Linux window already loads the complete graph once on a worker to build its project
snapshot. It then did that same decode again on each saved-agent attach, each Codex rollout-ID
update, and each resume. Those operations know one session ID; they should not decode every
archived record to find it or persist the one changed payload.

`ProjectDatabase.sessionRecord(id:)` now queries the session primary key and its owning project
primary key. It uses the same indexed-column and payload checks as a complete load, returning the
session's stored position for an exact-row update. An unrelated unreadable row is never decoded
by that operation. To keep this partial result from being mistaken for an authoritative graph,
the same connection refuses `save(_:)` after a targeted read until a complete `load()` succeeds;
exact-row writes remain available. The native agent paths use this lookup under the existing
nonblocking store lock. The initial window snapshot, terminal identity search, and terminal
creation still read the whole graph. The owning project's embedded terminal array is part of its
one row, so this is bounded by that row as well as by the selected session payload.

The scaling contract is one user-selected attach or resume, or one rollout-ID update per fresh
Codex launch, against an archive expected to hold thousands of sessions and stressed at 50,000.
The targeted path performs two primary-key seeks and decodes two payloads regardless of the number
of other sessions; no UI-frame callback invokes it. This is structural work evidence, not a
measured end-to-end launch-latency result.

The focused macOS `ProjectDatabaseTests` suite passed 54 tests (one skipped), including target
session/project validation, an unrelated unreadable row, exact-row update preservation and the
partial-read reconciliation refusal. The final owner-validation test passed again after its
assertion was strengthened. The complete Linux Docker/Xvfb suite passed the real selected-agent
resume journey with an unrelated session made unreadable *after* the window snapshot was built;
the fixture restored that row before later journeys. The complete real-daemon Linux host suite
also passed against the shared loader refactor. Neither suite measures authenticated Codex use or
absolute launch latency at the stated 50,000-session stress cardinality.

## 68. A master refresh changes the core copies without moving the existing UI verdicts

On 2026-09-25 the branch was rebased onto the current macOS product tree. Re-vendoring changed
four of the 45 portable core copies: `Project`, `ScheduledMessage`, `SessionCurfew` and
`SessionLaunchFailure`. All 45 copies are byte-identical to their production sources. The real
daemon `host-smoke.sh` and Docker/Xvfb `window-smoke.sh` suites passed after the refresh, including
the clean-profile startup and saved-agent resume paths. This checks that the new stored fields
have not broken the current Linux host; it does not prove a migration of arbitrary future stores.

The AppKit shim still builds. A fresh per-file sweep found no changed verdict among existing
`UI/Design` files. `SimulatorRecordingBadge.swift` is the one new file and is a `shim-gap`
(`NSAccessibility`, `NSString.draw`, `NSString.size`). The measured totals are 125 `shim-gap`,
27 `shim-clean` and two `clean` files, versus 124, 27 and two in the previous baseline. The
baseline remains unchanged so later refreshes continue to report that added gap.

The complete Mac test target passed 9,515 tests (83 skipped) on the refreshed stack. The complete
mobile target passed 898 tests (one skipped) on an explicit iOS Simulator destination; the
runner's default device name was ambiguous among three installed simulators and never reached
test execution. Neither test target exercises an authenticated Linux Codex installation.

## 69. The Linux terminal routes native pointer input through the live mouse mode

The native window had SDL button and wheel events, but terminal mode ignored them; only the
project picker used pointer input. The terminal now admits left, middle and right button
press/release and at most eight wheel steps per event into its existing bounded input queue.
The serial emulator worker asks the shared SwiftTerm terminal for its current DEC tracking mode,
modifier policy and wire encoding. Tracking-off events send nothing, X10 reports presses only,
and VT200-style modes report releases. Shift bypasses reporting unless the child requested shift
capture. Grid positions derive from the diagnostic renderer's fixed cell dimensions; events
outside the visible grid are ignored. Project-list pointer behavior remains separate.

The full Docker/Xvfb `window-smoke.sh` suite passed. Its new real PTY child switched from tracking
off to X10/SGR and then VT200/SGR while native X clicks and wheel events arrived. It checked no
bytes in the off state and exact press, release and wheel escape sequences in the enabled states.
Motion/drag reporting, local selection/copy and normal-buffer scrollback are still missing; this
test does not establish pointer behavior under IME or a non-X11 compositor.

## 70. The Linux terminal can browse normal-buffer history without losing the live screen

SwiftTerm already retained 2,000 normal-buffer rows for the native terminal, but SDL wheel
events were discarded whenever a child had not enabled DEC mouse tracking. A shared viewport
operation now moves through that bounded history under the terminal lock and sets SwiftTerm's
existing `userScrolling` state. New PTY output therefore leaves a held viewport on its rows;
returning to the live end resumes following output. The renderer draws only the visible grid,
hides the live cursor while historical rows are shown, and marks that state in the diagnostic
window title. Wheel input is processed on the serial terminal worker; each native event is
limited to eight steps and each step moves three rows. Frame requests remain bounded to one
outstanding render.

The live mouse mode still wins when a child asks for reports. An alternate-screen child gets
cursor keys from wheel steps when alternate scrolling is enabled, rather than normal-buffer
history. Alt requests local scrolling; Shift bypasses mouse reporting unless the child has
requested shift capture. This is behavior of the existing host-only diagnostic terminal, not a
new extension component: Threading still owns the viewport, input routing and PTY authority.

The portable emulator contract checked changed rows, a hidden historical cursor, stable rows
after new output, return to the live cursor and alternate-screen cursor-key input. A real PTY
child under Docker/Xvfb then supplied 60 numbered lines; native SDL wheel events moved the
rendered viewport into history and back. The captured held view showed rows 025–048, and the
returned live view showed rows 038–060. The held view stayed in scrollback after the child wrote
row 060. Captured frames were inspected in the real SDL window. Local text
selection/copy, a visible scroll indicator and behavior under a non-X11 compositor remain
unverified. The complete Docker/Xvfb `window-smoke.sh` suite passed on the final code, and
the macOS SwiftTerm `ScrollbackEndTests` suite passed all three tests.

## 71. Local Linux terminal selection uses SwiftTerm's retained-buffer model

The SDL window could paste but could not copy a path or a line from shell output. Local
left-button drags now use the same `SelectionService` that owns selection behavior in SwiftTerm's
Apple views. It anchors rows in the buffer, so a selection made while viewing history copies
those historical cells. The Linux adapter asks the service once per visible row for its selected
columns, then paints those cells in its existing Pango/Cairo terminal frame. It creates no
parallel text model and never snapshots all retained history for a frame.

When DEC mouse tracking is enabled, ordinary clicks still belong to the child. Shift claims a
local selection unless the child requested shift capture; after child exit, pointer input is
local regardless of the last mouse mode. Ctrl+Shift+C extracts selected UTF-8 on the serial
terminal worker and sends at most 1 MiB to SDL's native clipboard on the UI thread. Empty or
oversized selections leave the clipboard unchanged. The shortcut itself sends no byte to the
PTY. Held-left-button motion is coalesced to one pending worker operation, rather than filling
the bounded key/button input queue. The only retained text remains SwiftTerm's 2,000-line
scrollback; each frame still copies at most the 128×40 visible grid. This is the existing
host-only diagnostic terminal; Threading keeps PTY input, selection ownership and clipboard
authority, and no extension presentation contract is added.

The Linux emulator contract passed exact Unicode copy, visible-cell selection, Shift bypass and
ordinary mouse-report authority. macOS SwiftTerm `SelectionTests` passed 30 tests. The native
Docker/Xvfb journey copied `ROW 025` from a held historical viewport and `ROW 038` after the
PTY child exited; the child still accepted its expected input afterward, so neither drag nor
copy leaked a control byte to it. The captured native frames were inspected in both states:
selected cells painted `(55,100,142)` against the adjacent terminal background `(23,25,29)`.
The complete Docker/Xvfb `window-smoke.sh` suite passed on the final code. DEC motion/drag
reports, word/row click gestures, IME and non-X11 clipboard behavior remain outside this slice.

## 72. Terminal launches record the same durable attempt on macOS and Linux

The graphical Linux host created a Codex record with an awaiting provider identifier but left
`hasLaunched` false. A saved Linux session therefore disagreed with the macOS terminal launch
path about whether its process had started. The Linux resume path also left an old exit code
standing when it spawned a new process. `AgentLaunchRecording` now applies the resolved plan to
one record before persistence: it marks the attempt launched, stamps activity, clears the old
exit code and stores the plan's resume state. The macOS terminal controller, Linux CLI host and
Linux native window use that same byte-identical helper; the native window writes the standing
session row before a provider resume. Admission, database transaction scope, daemon acknowledgement
and recovery remain host-owned, so this is still short of a shared creation transaction.

The CoreSlice grew to 46 production files. Its Linux contract passed the shared transition,
and the full Docker/Xvfb `window-smoke.sh` passed, including a fresh managed Codex record with
`hasLaunched=true` and a separate-window resume that removed an injected stale exit code without
changing the provider ID. The shipping macOS app built and `AgentSessionCreationTests` passed
all three focused cases; the repository's architecture gates ran cleanly in that build. A prior
launch failure deliberately remains visible until the runtime survives startup. The smoke uses
an argument-recording Codex stand-in rather than an authenticated provider installation.

## 73. The Linux launcher opens the project it was given

With two projects in the durable store, `run-app.sh PROJECT` imported the requested folder but
the window selected row zero. A later invocation for a different checkout could therefore open
the earlier project's shell. The launcher now passes its canonical project path to the window in
both shell and Codex modes. The worker that loads the startup graph resolves that path against
the stored canonical project identities and returns a selected index; a missing project is an
explicit refusal. The UI mounts only its existing viewport rows, and selecting a project still
does not start a child. This is startup navigation in the diagnostic Linux host, not a new
product sidebar or extension surface.

The full Docker/Xvfb `window-smoke.sh` passed on the final code. Its clean-profile journey
opened project A and kept its shell child in the daemon, launched the same store for project B
with a configured Codex executable and observed B selected without another child, then launched
for A again and reattached the original PID. The captured B frame was inspected: B's row was
visibly selected. Existing native-window, terminal, agent and attach smoke cases also passed.
The startup snapshot still decodes the complete graph on a worker; choosing its project adds one
worker-side project lookup and no per-frame scan. Automatic restoration of the last agent or
terminal remains unfinished.

## 74. Linux startup navigation reads a bounded session window

The project window displayed at most 512 saved agents per project but decoded every saved session
to make that list. `ProjectDatabase.navigationSnapshot` now counts session rows with the indexed
`project_id` column, reads each project's most recent 512 session payloads through the
`(project_id, position)` index, and carries the saved selected-session ID. The Linux startup worker
maps that read into the same visible project and picker rows. A partial navigator read cannot
authorize `save(_:)`'s whole-graph reconciliation; exact-row writes remain available. The selected
ID is exposed by storage but is not used for automatic restoration yet, because Linux browsing
does not keep that selection current.

The opt-in `./coreslice.sh --navigation-stress` built the production storage slice in Release on
arm64 Linux. On one disposable store with 5,100 sessions across two projects and about 165-byte
titles, five warmed reads gave **45.3 ms median / 50.7 ms max** for the old full-graph path and
**8.1 ms median / 8.7 ms max** for the navigator. Fixture creation and save took 252.5 ms and
were excluded. The navigator decoded 612 recent payloads, while its count query still examined
all 5,100 indexed identities. This is an isolated storage comparison, not a native-window launch
time measurement. The ordinary Linux storage contracts passed with two projects, per-project
newest-first windows, selection, terminals, a dormant corrupt session and the partial-read write
fence. The focused macOS `ProjectDatabaseTests` case passed. The full Docker/Xvfb native window
journey passed, and its selected-project frame was inspected.

Project terminals are still embedded in each project's JSON payload, so this read decodes every
terminal in each project before returning at most 512. A very large project count also multiplies
the per-project window. Automatic restoration of a selected agent or terminal remains unfinished.

## 75. A targeted Linux relaunch reattaches its selected live agent

The project launcher used to return to a project list even when its selected agent still ran in
the retained PTY daemon. The native window now persists a saved-agent choice through the shared
database's exact session read and scalar selection write on a worker. Opening a shell or saved
terminal clears the agent selection when the store accepts the write, matching macOS navigation.
On a targeted relaunch, the startup snapshot accepts a selected agent only if it belongs to the
requested project, lies in the bounded recent window, has launched, is not archived and has no
recorded exit. It then attaches to that typed daemon identity. This startup path never resumes or
spawns a process; an unavailable child reaches the existing failure view, from which the agent
picker remains reachable. Generic `--app` still opens the project list, and terminals do not yet
restore automatically.

The first implementation awaited the selection write inside SDL's event loop. On Linux the Swift
main actor resumed that loop on another native thread; SDL then refused its renderer context with
`BadAccess`. The corrected loop never suspends after opening the window. One worker performs the
store operation, publishes a locked result, and the SDL thread polls only while that write is
pending before continuing the captured action. A refused agent or retained-terminal selection
leaves the picker or project list in place. A new shell still reports its own launch refusal on
the existing unavailable view when a competing owner holds the store.

The focused Docker/Xvfb journey verified a competing-owner selection refusal, durable movement
from an older saved agent to the live one, targeted relaunch to the **same child PID** without a
new spawn, an explicit different-project launch remaining on that project's list, and shell
selection clearing the agent ID before another targeted relaunch. The full
`window-smoke.sh` suite passed on the final code, including the project-terminal failure path,
saved-terminal picker, Codex resume, attach refusals and clean-profile launcher. The saved-agent
picker frame was inspected in the native window. The recent-window limit, missing automatic
terminal restoration, incomplete provider coverage, IME and accessibility remain outside this
slice.

## 76. Native Linux terminal composition stays out of the PTY until commit

The SDL terminal bridge now distinguishes text-editing preedit from committed text input.
Extended editing events preserve long UTF-8 compositions up to a 1 KiB preview bound; a longer
preedit shows an explicit placeholder. Pango draws the preview, underline, selection and caret
near the emulator cursor on the drawing worker, while SDL receives the cursor rectangle for its
input-method candidate placement. Functional keys used during composition are withheld from the
PTY, including their key releases after commit or cancellation. The durable terminal, input
authority and daemon lifecycle remain unchanged.

The renderer contract passed for Unicode preedit, cached/direct pixel parity and invalid UTF-8
refusal. In the live Docker/Xvfb X11/IBus/libpinyin lane, the raw PTY child observed no bytes
during composition and exactly the UTF-8 bytes for `你好` after selection. The captured native
window showed the terminal's blue-bordered Chinese preview. The IBus candidate panel was disabled
for the screenshot assertion so an overlapping input-method window could not satisfy it. The full
`window-smoke.sh` suite also passed after the event-routing change, including normal keyboard,
mouse, clipboard, agent attach and clean-profile journeys.

This verifies one X11 input method in the experimental terminal. Other engines, Wayland,
accessibility, general text controls and complete enhanced keyboard protocols remain unverified.

## 77. The native Linux navigator is discoverable through AT-SPI

The SDL window's ATK bridge now publishes an application, frame and the currently mounted
project or saved-runtime list to the session accessibility bus. List rows carry the durable
project/runtime ID, bounded Unicode name, selection state and `select`/`open` actions. An action
queues the same SDL events that pointer selection and Enter already use; ATK owns no store or
runtime policy. The projection contains at most 32 rows and refuses names over 511 UTF-8 bytes;
Swift supplies only the visible viewport with a 400-byte title prefix. The GLib side processes at
most eight ready callbacks per event-loop pass. Without a session bus, the window continues to
use its existing SDL route. This remains a host-only diagnostic navigator, not a new extension
component.

A live AT-SPI client under Ubuntu 24.04 ARM/Xvfb discovered eight rows from fifteen projects,
read their roles, IDs and selected state, followed ten paced keyboard selections into the
scrolled viewport, and found the original `Project06-界` name there. Invoking the row's AT-SPI
actions changed the native selected project and opened its real PTY. The full Linux window suite
passed with no session bus. The IBus Pinyin lane passed with the AT-SPI bridge active, including
visible preedit, no early PTY bytes and the exact Unicode commit. A final focused AT-SPI rerun
passed after the bridge's row-identity and shutdown handling changes.

At this point the terminal exposed its title and an explicit text-unavailable description, not its
screen contents. Component geometry and hit testing, a full selection interface, focus/event
semantics, actual screen-reader inspection and non-X11 desktop evidence remain open. The ATK
bridge is a measured platform leaf; it does not settle the eventual Linux toolkit or packaging.

## 78. The Linux terminal projects its visible screen as AT-SPI text

The terminal node now implements read-only ATK Text. Its content comes from the emulator snapshot
already used by the Pango drawing worker, so it reflects only mounted viewport rows and does not
walk scrollback on the UI thread. The worker drops unused trailing columns and rows, preserves
whitespace through the cursor, skips wide-cell continuations, and replaces concealed cells with
spaces before publishing. A separate 64 KiB text budget yields an explicit overflow message
instead of an oversized AT-SPI reply. The C bridge validates UTF-8, maps Unicode character
offsets, and emits insert/remove notifications for the changed span plus caret changes. Text is
cleared when the terminal starts, fails, or yields to the navigator so a retained accessibility
reference cannot read stale output.

The Ubuntu 24.04 ARM/Xvfb AT-SPI client opened a project through the navigator action and read
the live PTY's visible `界` and combining-accent text through the Text interface. It verified
Unicode character count and lookup, a valid caret offset, refusal of remote caret movement,
absence of concealed text and offscreen scrollback, then sent input and observed the updated
screen without restarting the window. The focused `THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh`
lane passed.
The full `./window-smoke.sh` suite also passed, covering the renderer, PTY, native input,
scrollback, clipboard, saved-terminal and agent paths, reattach, and clean-profile startup with
the text projection in every prepared frame.

Component geometry and hit testing, selection, full focus behavior, IME preedit announcements, actual
screen-reader inspection and non-X11 desktop evidence remain open. The published text is a
bounded visible-screen projection, not a transcript or a full terminal accessibility model.

## 79. Linux AT-SPI focus follows the real SDL window

The ATK bridge now marks the selected mounted navigator row or terminal focusable, and focused
only while SDL reports keyboard focus for its window. Moving selection transfers the focused
state to the new mounted row; replacing a viewport row drops focus before retiring the old node.
Opening the terminal transfers focus from the row without inventing another input path. The
bridge holds one reference to the focused node through a transition so removal cannot leave a
dangling pointer, and skips duplicate state-change notifications when nothing moved. The focus
projection examines at most the 32 mounted rows when a list selection changes and one terminal
node on a frame; it does not scan saved sessions or offscreen rows.

The Ubuntu 24.04 ARM/Xvfb AT-SPI client verified focus on the selected project, transfer across
keyboard scrolling and an AT-SPI row action, then focus on the real PTY terminal. It opened a
second native window, verified the original terminal lost focus, closed that window, and verified
focus returned. `THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh` passed on the final code. Focus
state does not yet prove a complete screen-reader experience, component geometry, or selection
semantics. This remains a host-only platform leaf.

## 80. Mounted Linux accessibility nodes report native geometry

The frame, project/saved-runtime list, mounted rows and terminal now implement ATK Component.
The application root does not advertise a screen rectangle. Row extents use the diagnostic
renderer’s actual 2× coordinates: at 800×480 the first row is `(12, 56, 776, 44)` pixels in the
window, and each later mounted row begins 48 pixels lower. The list starts below the 52-pixel
title strip. One Swift row-rectangle helper now supplies the rendered frame, native pointer
hit test and AT-SPI publication; the bridge’s row action uses the published rectangle’s centre.
The helper mirrors the root’s integer half-size bounds on odd-pixel windows. Screen coordinates
add SDL’s current window position; parent-relative row coordinates subtract the list origin.
Frame and terminal queries read live SDL geometry; the navigator republishes list and row bounds
after resize. An unmounted or retired node reports unavailable extents, and a component’s point
lookup examines only its mounted children.

The Ubuntu 24.04 ARM/Xvfb AT-SPI client compared frame and row extents with `xdotool`’s native
window geometry, checked all three coordinate forms, an odd 801×481 window and the gap between
rows, then clicked at a reported row point and observed the same project selection. It verified
that a held list loses its extents when the terminal mounts, and that the terminal’s bounds update
after a native 960×600 resize. The final `THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh` lane
passed. I inspected the captured 800×480 and 801×481 lists and 960×600 terminal frame; the
first accessible row rectangle matches the visible blue selection band.

The full `./window-smoke.sh` suite passed with the shared pointer geometry, including native
project clicks, saved-runtime pickers, terminal input, reattach and clean-profile startup without
a session bus. The final row-bound validation change affects only the AT-SPI-enabled path.
I inspected its 960×600 project frame after the native click selected Gamma.

The following slice adds visible terminal character extents. Bounds-change notifications,
richer selection and actual screen-reader/magnifier inspection remain open. This geometry is
for the current bounded diagnostic window, not a portable layout contract for the future
product shell.

## 81. Visible Linux terminal characters retain their rendered cell geometry

The terminal's existing visible-grid projection now carries a bounded run for each retained
display cell and line break alongside its Unicode text. ATK Text resolves an offset through
those runs to the renderer's fixed 10×22-pixel cell rectangle; a point query returns the first
Unicode scalar in the cell. A two-column glyph reports a 20-pixel rectangle, and the base and
combining scalars of one grapheme report the same rectangle. Newline offsets have zero-width
rectangles at the end of their displayed line. Screen coordinates add the live SDL window
origin. The renderer, IME candidate placement, terminal viewport sizing and accessibility
bridge now share the native cell-size constants. This is cell geometry, not a Pango glyph-ink
measurement.

The mapping is built from the same SwiftTerm snapshot and trimming decision as the text; it
does not read hidden scrollback or reconstruct geometry from the flattened string. At most
128×40 cells and 40 line breaks are retained per frame, under the existing 64 KiB text bound.
Character lookup is logarithmic in that bounded run list; point lookup searches only the
queried row. The synthetic overflow message has no character geometry because those words
were never drawn. An unmounted terminal reports no hit or character extents even if an AT-SPI
client keeps its old object reference.

The Ubuntu 24.04 ARM/Xvfb AT-SPI client opened a real PTY through a project-row action and
queried `界`, both scalars of `é`, the following newline, window/screen coordinates, hit
offsets, live replacement text and a stale terminal reference after returning to projects.
`THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh` passed. The bridge writes unavailable
rectangles as `(-1, -1, -1, -1)`; the AT-SPI client normalizes the horizontal corners, so the
fixture asserts the unavailable vertical extent rather than a wire-specific x/width pair.
I inspected the captured real-window terminal frame. The fixed cell rectangles are useful for
accessibility navigation and magnifier placement, but do not prove glyph-ink alignment,
bounds-change notifications, a selection interface or actual screen-reader behavior.
The full `./window-smoke.sh` suite also passed without an accessibility bus, covering native
Unicode rendering, keyboard and pointer input, scrollback/copy, saved-terminal and agent
reattach, launch refusals and clean-profile startup. I inspected its Unicode terminal capture;
the glyphs and cell placement remain consistent with the fixed-grid renderer.

## 82. A saved Linux Codex login now routes through its own home

The Linux app window previously refused every named Codex session even though the durable
session already records an account handle. The headless host could create only a standard
record. `CODEX_HOME` inherited from the environment was already cleared for standard launches,
but macOS discovery could still call the inherited override the standard login, making the
displayed account disagree with the launch route.

`CodexAccountLocations` now gives both hosts one Foundation-only rule. The standard handle
means `HOME/.codex`. A legacy named handle such as `codex-work` requires the exact
`HOME/.codex-work/auth.json` marker; macOS may also use its provider-verified registry for
keyring-backed named locations. Duplicate handles or one path claimed by different handles
are withheld. Resolution probes the selected legacy directory rather than enumerating every
login on an input or resume path. Linux reads no macOS credential or preference store.

`THREADING_LINUX_CODEX_ACCOUNT=codex-work` is the diagnostic window's explicit new-session
choice; the headless `codex` command accepts the same handle as an optional final argument.
Both persist it and launch with that account's `CODEX_HOME`. A dormant graphical session
resolves its stored handle again, verifies its rollout in that account's `sessions/` tree,
checks known-broken numbering, and only then sends the resume command. The saved-agent row
labels a named account both immediately after creation and after reopening the window. This
diagnostic control remains host-only; session identity, login admission and process routing
remain host-owned if a future product picker becomes customizable.

The Ubuntu ARM/Xvfb/PTY smoke created a named session despite an inherited foreign
`CODEX_HOME`, persisted its handle and provider ID, reopened the exact conversation, and
refused resumes with either a missing login marker or a different `HOME` before child spawn.
It also exercised the optional headless command. I inspected the real 800×480 picker capture:
`codex [codex-work]` is visible in the selected row. The two macOS resolver unit tests passed,
as did the architecture, theme and main-actor latency ratchets. There is still no in-app
account picker, Linux registry for keyring-backed logins, or support for other providers.

The saved-agent picker smoke had seeded its older row with `/bin/true`. The daemon keeps an
observed exit for five seconds, so on a slower run that row vanished before the picker could
attach. The fixture now seeds a live older child and explicitly exits it after opening the row;
the agent-only suite passed with that deterministic lifetime. This changes the test's source of
truth rather than extending the daemon's bounded exit retention.
The complete `./window-smoke.sh` suite then passed with the final resolver and live fixture,
including standard and named Codex creation/resume, saved-agent reattach, terminal input and
rendering, and clean-profile startup.

## 83. A Linux window can choose a Codex login without an environment edit

The diagnostic window now opens a bounded native Codex login chooser with Ctrl+Shift+I from the
project list. It offers the standard home and up to 31 legacy named homes validated by the shared
`CodexAccountLocations` rule. A one-time worker scan streams the home directory, retains only the
first 31 valid names in lexical order and publishes immutable handles to the UI. Empty `.codex-*`
directories do not spend a picker slot. The renderer mounts only viewport rows and publishes their
same handles through AT-SPI. Arrow keys and pointer select a row; Enter makes it the new-session
choice. The configured `THREADING_LINUX_CODEX_ACCOUNT` remains the initial choice, including when
it is unavailable, so a missing explicit login is never silently replaced by the standard one.

Launch resolves the chosen handle again before creating a session, while resume continues to use
the handle in that session's stored record. The window's pending-session entry captures its launch
handle, so choosing another login while a child starts cannot relabel its saved row. The project
header shows the current new-session choice even after a shell exits. This chooser is host-only
diagnostic UI: identity, marker admission, persistence, process routing and revalidation remain
host responsibilities. It does not add a Mac controller or a new extension surface.

The Ubuntu ARM/Xvfb smoke started with an invalid configured handle, presented a real two-row
chooser despite 40 earlier-sorting unverified `.codex-*` folders, selected `codex-work`, and
created a session under `HOME/.codex-work` with the exact persisted handle and provider ID. A new
window resumed that provider ID through the same home; missing-marker and wrong-`HOME` resumes
were refused before spawn. I inspected the captured 800×480 account picker: both rows and the
selected named login are legible. The complete `./window-smoke.sh` suite passed, including the
terminal, agent, reattach and clean-profile journeys. The chooser's header-only follow-up is
covered by a focused named-account rerun. Live account-list refresh, in-app sign-in, non-legacy
credential stores, other providers and packaged distribution remain open.

## 84. Native navigator text needs a platform leaf, even when row chrome is shared

The real X11 capture rendered the Unicode project `Project06-界` as `Project06-?`: AT-SPI already
published the original name, but the specimen bitmap font could not display it. The Linux window
now keeps the specimen row background, selection mark and shared row rectangle while a Pango leaf
shapes the title and only the mounted project, saved-runtime or account rows into that frame.
The host caps names before encoding. The leaf validates UTF-8, frame and row bounds, accepts at
most 33 labels and 32 KiB of text, and reuses one row-sized Cairo surface instead of creating
offscreen views or a second full frame. Explicit grayscale antialiasing prevents colored fringes
when the transparent row surface is composited over a selected row.

The final 800×480 AT-SPI capture visibly renders `Project06-界` with clean selected-row text.
A C pixel contract distinguishes Unicode from `?`, checks selection and clipping, and rejects
invalid UTF-8 and excessive labels before touching the frame. In the accessibility journey,
19 steady redraws with nine labels had a 0.920 ms median and 0.987 ms maximum; the first draw
was 7.28 ms with font setup. The host still owns row identity, selection, persistence and
accessibility actions. This is a diagnostic Linux renderer, not a Mac UI change or a finished
shipping sidebar. Both the AT-SPI-only journey and the complete `./window-smoke.sh` suite passed;
the architecture and theme boundary checks remained clean.

## 85. The native navigator has one AT-SPI selection owner

The Linux list previously exposed `SELECTABLE` and `SELECTED` row states plus a row `select`
action, but AT-SPI clients could not ask the list which child was selected or select one through
the standard Selection interface. A dedicated ATK list type now exposes one selected child by
mounted row index. Its selection write enqueues the existing generation-checked native row action;
the window still owns pointer, keyboard and accessibility selection. Clearing or selecting every
row is refused because nonempty project, saved-runtime and account lists use one current choice.
Changes to mounted row identities or selected state emit one list selection-change notification;
unchanged redraws emit none. A list hidden by the terminal refuses new remote selection, so an
old accessibility proxy cannot take input ownership from the terminal.

The real Xvfb/AT-SPI journey selected a project through the list interface, observed pointer and
keyboard changes through that interface, retained one selected child while scrolling a 15-project
catalogue, and verified the hidden-list refusal after opening the Unicode-named project into a
real PTY. The focused `THREADING_LINUX_A11Y_ONLY=1 ./window-smoke.sh` passed along with the
architecture and theme checks. This remains a bounded diagnostic list; terminal text selection,
native screen-reader inspection and broader focus/event coverage remain open.

## 86. A Linux host can create a real Claude session without a second command policy

The macOS remote host already composed two Claude terminal commands from one session: resume
with its known UUID or fresh with a caller-minted UUID. That command assembly is now a portable
`ClaudeLaunchCommand` value. The Mac remote path supplies its integration flags and resolved
permission mode to the same value that the experimental Linux CLI uses. Account discovery,
settings and hooks remain host-owned; no Linux shim imports AppKit or Mac preferences.

`LinuxHost claude` creates a durable Claude session through the existing session-creation and
exact-row persistence paths, records the minted UUID as its resumable provider ID, and spawns
the typed agent identity through the production PTY daemon. It explicitly selects Manual and
clears an inherited `CLAUDE_CONFIG_DIR` for the standard `HOME/.claude` account. A real-shell
recorder run verified the permission flag, UUID, quoted leading-dash prompt and a custom `HOME`
while an unrelated project and session retained their exact stored bytes. The headless daemon
reattach path can use that identity. The Mac remote-host tests passed (26 cases); the complete
Mac target passed 9,519 tests (83 skipped), and the complete iOS target passed 898 tests (one
skipped) on an installed simulator. The ordinary `scripts/test.sh all` mobile handoff could not
select its default iPhone 17 Pro destination on this machine, so `scripts/test-mobile.sh` was run
separately with an explicit installed simulator ID. Architecture and theme boundary checks passed.

The recorder does not prove an authenticated Claude installation or transcript generation.
The headless command still has no exited-session resume or named Claude account choice. The
subsequent native-window path is recorded in section 87.

## 87. The native Linux window now owns a Claude create, attach and resume journey

The diagnostic window's managed-agent route now chooses the provider from a saved session rather
than assuming Codex. The project view exposes Ctrl+Shift+L for a fresh standard-account Claude
terminal beside its existing Codex action; `run-app.sh` passes whichever absolute provider
executables are available. Fresh creation uses the shared `ClaudeLaunchCommand`, selects Manual,
clears an inherited `CLAUDE_CONFIG_DIR`, stores the caller-minted UUID and selected row, then
spawns the same typed identity through the production PTY daemon. A reopened window first attaches
to the daemon-held child. If that child has exited, it resumes only after an exact transcript
preflight; a missing file refuses the launch without creating another conversation.

The preflight does not carry a second guess at Claude's project slug. `ClaudeTranscriptPath` is a
Foundation-only value shared with the Mac storage fallback, including its measured UTF-16 encoding
of punctuation and non-ASCII project paths. The Linux check runs on the terminal worker and reads
one computed file. Fresh agent creation now reads zero standing session payloads through the
bounded navigation snapshot and checks its proposed UUID by indexed identity lookup instead of
decoding the entire graph. On the 5,100-session/two-project Release fixture, the median creation
read was 0.3 ms versus 38.0 ms for a full graph read; an unreadable unrelated session row no
longer blocks an exact new-row write. The visible navigator still mounts only viewport rows from
its bounded saved catalogue. The existing project and saved-agent navigation is host-owned: Threading
retains account routing, session identity, persistence, PTY ownership and resume admission even
if a future extension can customize its presentation.

The real Xvfb journey used a custom `HOME`, a conflicting inherited `CLAUDE_CONFIG_DIR`, and a
project path containing dots and an underscore. Its recorder checked the fresh and resume flags,
the exact durable provider UUID, a second window's attachment to the same live child, and refusal
after removing the transcript. The focused native agent suite and one-command startup suite
passed. The project-action and saved-agent screenshots in `out/claude-project-list.png` and
`out/claude-agent-picker.png` were inspected in the rendered window. The Mac transcript-path and
remote-host suites passed 35 focused tests. The complete `scripts/test.sh all` gate passed 9,519
Mac tests (82 skipped) and 898 iOS tests (one skipped) with zero failures. Architecture and theme
boundaries stayed clean, and all 50 vendored core files verified byte-identical.

This remains a source-tree diagnostic window, not a packaged Linux release. The recorder is not
an authenticated Claude installation; named Claude accounts, host hook integration and exited
Claude resume from the headless CLI remain open.

## 88. Named Claude sessions use one account identity across the Mac and Linux hosts

The Mac account list and Linux hosts now share `ClaudeAccountLocations`. A standard handle
always routes to `HOME/.claude`; a legacy named handle requires its exact `HOME/.claude-*`
directory with `.claude.json` or `settings.json`. Verified Mac registry records may admit other
directories without a marker, but neither host accepts Claude Science data roots, and duplicate
handles at different paths are withheld rather than selected by scan order. This is a routing
address, not credential handling. Linux reads neither the Mac registry nor provider secrets.
When a verified alias names a marker-backed legacy home, discovery keeps the legacy handle at
that path, preserving the session identity the older Mac account list already exposed.

The native Linux project view offers a bounded Claude picker at Ctrl+Shift+O and starts the
selected account with Ctrl+Shift+L. It scans `HOME` once on a worker, keeps at most 31 verified
named homes beside the standard choice, and mounts only visible picker rows. The saved session
stores its chosen handle. After the child exits, resume resolves that stored handle and the exact
transcript in its account directory; the current picker choice cannot move the conversation.
The headless `LinuxHost claude` command accepts the same optional handle and refuses an unavailable
one before writing a session. Account selection, durable identity, transcript admission, and PTY
ownership remain host-owned even if a later extension customizes the picker presentation.

The Xvfb recorder verified named creation, exact resume, refusal after removing the login marker,
refusal under another `HOME`, and the headless CLI route. It also checked that 40 empty
`.claude-*` directories and a Claude Science root do not consume the picker's 31-account bound.
The standard Claude and named Codex journeys passed in the same native agent suite. The rendered
account picker and project action line were inspected in `out/claude-account-picker.png` and
`out/claude-named-project.png`. Mac unit tests cover exact routing, Science exclusion, registered
locations and ambiguous handles. This still does not prove an authenticated Claude installation,
host hook integration, or exited-session resume from the headless CLI.

## 89. Headless Claude resume uses the saved account and one indexed row

`LinuxHost resume-claude` now takes a saved session UUID and uses `ProjectDatabase.sessionRecord`
to read only that session and its owning project. It checks the existing project, resolves the
stored account handle under the current `HOME`, and requires the exact transcript path produced
by `ClaudeTranscriptPath`. Missing stores, unavailable named accounts and transcripts refuse
before spawning; none fall back to a new conversation or a different account. The shared
`ClaudeLaunchCommand` builds
the `--resume` command with the saved provider ID, and the PTY daemon keeps the same typed session
identity. `attach-agent` continues to reconnect an already running child.

An existing row is recorded as launched only after the daemon accepts the spawn. This preserves
its exact bytes when a duplicate resume meets a live child. The Linux host smoke runs a real
daemon and a recorder child under a named Claude home, checks fresh launch, exited-session
resume, absent transcript/marker and changed-`HOME` refusals, then leaves a child alive and
checks that a second resume neither rewrites the row nor starts another child. An unrelated
corrupt session row remains untouched and does not block the indexed resume. The full host smoke
and shared-core harness pass in a native aarch64 Linux VM. This recorder verifies routing and
durable identity, not authenticated Claude behavior.

The complete Mac target passed 9,521 tests (83 skipped, zero failures). Architecture, theme,
main-actor latency and vendoring checks passed. `scripts/test.sh all` could not select its default
iPhone 17 Pro simulator because that device is not installed. A separate full mobile attempt on
the installed Threading iPhone 17 simulator built successfully but its boot check remained in
CoreSimulator data migration for more than seven minutes, before XCTest launched. iOS tests are
therefore unverified for this slice.

## 90. Native Linux agent exits survive window restarts

The graphical host previously kept a daemon `exited` frame only in its terminal instance. A
targeted restart then read the saved session's still-empty `lastExitCode` and tried to attach an
agent that had already ended. The host now writes an observed exit to that indexed session row
under the store lock, preserving other rows. Before targeted startup restoration it releases the
store lock, surveys the daemon on a worker, and attaches only a confirmed running child. A held
exit updates the same row without inventing an activity time; an absent child opens the project
list without inventing a status. Query failure keeps the existing attach-only failure route.

Explicit saved-agent selection distinguishes a live child from a held exit or an absent child.
It attaches the live one and starts a provider resume for the other two after the account and
transcript checks. An existing session's launch record is cleared only after the daemon's
`spawned` reply, so a rejected or competing spawn cannot erase the prior exit. The real Xvfb
Claude fixture now checks an observed exit, targeted reopen, accepted resume, a child that exits
while the window is closed, daemon-summary reconciliation, and another explicit resume under
the same UUID. This is daemon and recorder evidence, not an authenticated Claude run.
The complete native window smoke suite passed after this change, including the existing terminal,
Codex, named-account, attach-refusal, and startup journeys.
The daemon summary does not carry the exited frame's `signalled` flag, so reconciliation records
its numeric status as sent; only an exit observed by the window can map a signal to `128 + status`.
The full Mac target passed 9,521 tests (80 skipped, zero failures). The required `scripts/test.sh
all` iOS leg did not start: Xcode could not resolve its default `iPhone 17 Pro` simulator
destination on this machine. No shared Mac or iOS source changed in this slice.

## 91. The Linux development app reopens from its saved project list

`run-app.sh` previously required a directory on every invocation even though the native window
already had a generic saved-project mode. The launcher now accepts no argument after the first
project import, verifies the store exists before creating runtime state, reuses the same daemon,
and opens the saved project navigator without importing or spawning a child. An explicit directory
still imports and targets that project. Both terminal-only and provider-enabled generic modes use
the same existing native window routes.

The focused real Xvfb startup fixture first refuses a no-argument clean profile without creating
data or a daemon. It then imports two projects, reopens without a path, confirms unchanged project
and terminal counts, and reattaches the original child under the same daemon PID. A second
no-argument reopen with both provider commands configured selects the other saved project without
launching a child. `THREADING_LINUX_STARTUP_ONLY=1 ./window-smoke.sh` passed. This remains a
source-tree launcher; it is not a packaged desktop entry point or an in-window project importer.

## 92. The PTY client is one compiled module on Mac and Linux

The Linux host previously compiled a copied `PTYHostClient` among its vendored core files.
That let the native window exercise the same source text as macOS, but the two builds could
still acquire different client changes between vendoring runs. The client, its Unix socket,
handshake, binding and write policy now live in `Packages/ThreadingPTYClient`. Both the
shipping Mac app and the experimental Linux host import that package; only the Mac adapter
owns EventLog, OSLog diagnostics and the availability probe. Diagnostics cross the package
boundary as typed events, preserving the Mac logger's privacy treatment.

The package explicitly links `ThreadingDomain` alongside `ThreadingPTYHostKit`. Xcode's
dynamic package products did not link the domain identity metadata transitively; the same
direct dependency is present on the embedded macOS daemon. The Linux core slice now vendors
44 production files instead of copying the seven client files.

The package built independently on macOS. In a native aarch64 Linux VM, the real-daemon host
smoke, the full Xvfb graphical window suite and all shared core-slice contracts passed; the
vendored-file verification remained byte-identical. These checks cover spawn, detach and
reattach, bounded output, saved-project reopen, agent resumes and exact session identity.
The focused Mac PTY suite passed 48 tests (one skipped). The complete Mac target passed
9,521 tests (83 skipped, zero failures). Architecture, theme and main-actor-latency
boundaries passed. The required `scripts/test.sh all` iOS leg built for the installed
Threading iPhone 17 simulator, but XCTest never launched: CoreSimulator did not report boot
readiness after eight minutes, so the attempt was stopped. iOS tests remain unverified for
this slice; no iOS source changed.

## 93. The Linux window can import its first project

The source-tree launcher now initializes an empty private store and starts or reuses its daemon
when invoked with no directory. The navigator mounts one **Add project folder** row in that
state. Enter, a click, its AT-SPI open action, or Ctrl+Shift+P in the project list opens Zenity's
native GTK folder dialog. The dialog and `LinuxHost --add-project` run on a worker; SDL keeps its
owning thread while the picker is open. A selected existing directory is canonicalized, imported
once under the store lock, and selected in a refreshed bounded navigator snapshot. The import
command now reads project rows without decoding the entire stored session graph. Cancellation
leaves the catalogue unchanged; startup and import never spawn a child.

This is a deliberately host-only project import surface. Threading owns path identity, duplicate
admission, store writes and process startup; the Linux platform leaf owns the folder dialog. It
does not add an extension component or imply a packaged desktop release.

The focused real Xvfb startup fixture passed from a clean profile: it captured and inspected the
empty and populated windows, clicked the Add project row, imported through the GTK dialog,
repeated the same import through Ctrl+Shift+P without a second row, cancelled a third dialog,
and then opened and reattached the same daemon-held shell. An initial full-suite run exposed
Zenity inheriting the smoke runner's script-bearing stdin. Both helper processes now receive a
closed stdin; the complete native-window suite passed through its final startup case afterward.
The AT-SPI lane also passed: the empty Add project row's accessible open action launched and
cancelled the GTK dialog, and the existing bounded-list, focus and terminal-text checks passed.
The older focus fixture now targets its second window when sending Alt+F4, avoiding an
intermittent close of the wrong X window after an accessibility focus query.
The accessibility bridge marks a select event separately from pointer clicks: selecting the
empty action row does not start a dialog, while its subsequent open event does.
The complete Mac target passed 9,521 tests (83 skipped, zero failures) after this Linux-only
change. The complete iOS Simulator target passed 898 tests (one skipped, zero failures), so
`scripts/test.sh all` finished successfully. Architecture, theme and main-actor-latency checks
passed as well.

## 94. Normal Linux relaunch follows the saved agent

The native window previously considered a selected agent only when the launcher named a project.
No-argument relaunch always started at the first project, even when a live daemon-held agent was
selected in another project. The normal route now chooses that agent's owning project and uses the
same attach-only daemon survey as the explicit route. A named project still takes precedence. A
held exit or absent child leaves the chosen project list open; neither case starts a replacement.

The initial navigator remains bounded to 512 recent agents per project. A selected agent already
in that snapshot is reused; one outside it costs one indexed session read and takes one picker
slot. The real Xvfb fixture imports a different project first, selects a live agent in the second
project, pushes it beyond the recent page with 513 dormant rows, and reopens without a directory.
The window attaches to the original PID, then records exit 9. A later no-argument launch opens the
selected project's list instead of respawning the child. The fixture also verifies that an
explicit first-project choice overrides the live selection and that opening a shell clears it.
The complete native-window smoke suite passed on the final code.

The repository's `scripts/test.sh all` gate passed: 9,522 Mac tests (83 skipped) and 898 iOS
Simulator tests (one skipped), with zero failures. Architecture, theme and main-actor-latency
boundary checks passed.

## 95. The Linux window runs from an Ubuntu arm64 preview tarball

The source-tree launcher previously always verified vendored files and invoked SwiftPM. It now
uses sibling `bin/WindowHarness`, `bin/LinuxHost` and `bin/threading-ptyd` when its bundle marker is
present. The existing source-tree path still builds its products. `package-app.sh` builds the
three release executables with a static Swift runtime on Ubuntu 24.04 arm64, stages the launcher,
runtime README and source stamp, and writes a tarball. The host products currently need Swift's
`-enable-testing` flag for their `@testable` imports of the experimental core slice. This is a
preview artifact, not a release-grade app or a replacement for the macOS distribution pipeline.
The bundle runner passes the source revision and dirty state into its builder: a linked worktree's
`.git` pointer names a path outside the Docker mount, so Git inside that container cannot read
the checkout. The VM invocation supplies those values from the host worktree; a complete checkout
can compute them locally. Packaging refuses missing or malformed provenance rather than stamping
an unknown revision with a false clean state.

`bundle-smoke.sh` builds the tarball in the pinned Swift container, then extracts it in a fresh
Ubuntu 24.04 container with no Swift toolchain or source checkout. The runtime receives only the
archive and test fixtures. It checks dynamic-library resolution and runs the existing real-Xvfb
clean-profile startup journey without binary-path overrides: native folder import, duplicate and
cancel behavior, saved-project reopen, daemon reuse and reattachment to the same terminal child.
The folder fixture pastes the directory path and reads it back before submission; synthetic
character-by-character typing intermittently let GTK autocomplete leave a stale suffix, making a
valid test directory look absent to the application.
The bundle needs Ubuntu's SDL2, Pango/Cairo, AT-SPI, SQLite, Zenity and font packages; those are
listed in its README. This proves the Ubuntu 24.04 arm64 Xvfb path, not other distributions,
Wayland, desktop installation or authenticated provider runs.

The bundle's project-import presentation is deliberately host-only. Threading retains canonical
path, store, daemon and process authority; Zenity supplies the platform folder dialog. Packaging
adds no extension component or alternate presentation contract.

The focused source-tree native-window smoke and the archive-only bundle smoke passed. The
rendered empty-project window from the extracted bundle was inspected. All 10 spike runner
contracts, architecture/theme/main-actor-latency checks and `scripts/test.sh all` passed. The
complete Mac target ran 9,522 tests (83 skipped), and the iOS Simulator target ran 898 tests
(one skipped), with zero failures.

## 96. The Ubuntu preview has an installable desktop package

The archive required manual dependency installation and a shell launch. `package-app.sh` now
also builds an Ubuntu 24.04 arm64 `.deb` from the same three binaries and launcher. Its control
file declares the Linux runtime packages; it installs under `/opt/threading-linux-preview` with
the launcher beside its binaries, plus a desktop entry and the existing Threading mark. A
symlinked command in `/usr/bin` would break the launcher's sibling-binary lookup, so the desktop
entry points to the installed script directly. The package has no maintainer scripts and leaves
the user's XDG store and daemon state outside package-owned paths.

The source-free Ubuntu runtime smoke installs the `.deb` before installing any GUI test tools,
validates its desktop entry, then runs both the archive and installed launcher through the
clean-profile folder-import, saved-project, daemon-reuse and same-child reattachment journey.
The installed path runs as an ordinary user. Reinstalling the package leaves the saved SQLite
store byte-identical and readable. `gtk-launch` opens the packaged desktop entry under Xvfb as
that user with default XDG paths; its real first-run window and the imported-project window were
captured and inspected. The smoke fixture now searches only visible X windows, because an old
unmapped Zenity dialog can briefly retain the same title and reject focus with X11 `BadMatch`.

This desktop integration is deliberately host-only: Threading still owns launch, project
identity, store, daemon and process authority, while the operating system owns menu placement.
The artifact remains a preview: the experimental host still builds with `-enable-testing`, and
Wayland, other distributions, authenticated providers and a production upgrade channel remain
unverified.

The archive/package runtime smoke, 10 spike runner tests, architecture/theme/main-actor-latency
checks and `scripts/test.sh all` passed. The complete Mac target ran 9,522 tests (83 skipped),
and the iOS Simulator target ran 898 tests (one skipped), with zero failures.

## 97. Desktop launches recover the login-shell provider path

A graphical desktop session can omit `~/.local/bin` or a shell-managed Node prefix from `PATH`.
The Linux launcher previously searched only that inherited path, so a working CLI could be
absent from the provider list. Even an explicit executable override could reach a script with an
`/usr/bin/env node` shebang but fail when `node` was missing from the inherited path.

`run-app.sh` now asks the configured shell for `PATH` with `-l -c`, the same mode used to launch
providers, once before discovering Codex and Claude. It reads the result from a private runtime
file so profile output cannot be mistaken for path data, accepts at most 16 KiB without line
breaks, and puts the login-shell entries ahead of the inherited path without dropping them.
The probe has a three-second deadline and a one-second kill grace; failure, timeout or unusable
output leaves the inherited path in place. Explicit provider overrides still win, including an
empty value that disables discovery. The README keeps explicit paths as a fallback for CLIs
configured only in an interactive profile.

The focused Ubuntu 24.04 arm64 fixture passed for discovery from a minimal GUI path, a real
Bash login profile, an `/usr/bin/env` interpreter, inherited path retention, explicit and empty
overrides, oversized output, shell failure and timeout. The fixture uses stand-in binaries and
does not establish authenticated provider behavior.

## 98. Ordinary relaunch and package reinstall retain the selected terminal

The store now records a selected standalone terminal alongside the existing selected-agent
state. Choosing either clears the other in the same transaction. Navigation finds the terminal
in its owning project's already-decoded payload, and a selection older than the recent window
takes a slot within the existing 512-row limit. An explicit different project still wins.
Startup surveys the daemon after releasing the store lock and only reattaches the saved child;
an absent or exited terminal returns to the project list without spawning a replacement. An
unavailable survey is not evidence of exit, so attachment retains its explicit failure path.

Linux package builds now compile a daemon generation from the preview version and source
revision. Dirty builds also fingerprint the daemon and its contract/domain sources, so changed
daemon inputs at one Git revision cannot claim the same clean generation. The bundle manifest
records that generation for comparison with the live daemon's status.

The source startup fixture passed with 514 saved terminals: ordinary reopen restored the deep
selection's original PID, an explicit different project took precedence, and exited/absent
children returned to navigation. The extracted archive and installed non-root application passed
the native folder-import and reopen journeys. A live fixture closed the window, reinstalled the
actual same-version `.deb`, verified unchanged store bytes and daemon/child identities, then
automatically reattached through the installed launcher. Live status matched the manifest's
generation. Fresh startup, restored-terminal and post-exit navigator screenshots were inspected.

An earlier first-window timeout did not reproduce in the source or packaged runs. It exposed a
fixture cleanup defect: the test learned the daemon PID only after observing the first window.
Failure handling now captures bounded fixture logs, process state and visible titles before
cleanup, and verifies the daemon identity from its runtime PID file independently of window
success. A temporary impossible-title probe preserved the original assertion, captured the actual
empty-project window in `out/bundle-smoke/failure-probe/startup-failure.log`, and confirmed that
the fixture daemon had exited. No startup deadline or product behavior was changed for that test.

This proves same-package reinstall on Ubuntu 24.04 arm64 with Xvfb. It does not establish safe
cross-generation daemon replacement, Wayland support or authenticated provider behavior. These
artifacts are stamped `source_dirty=true`. The complete macOS suite passed 9,642 tests with
83 skips and no failures, including all 61 database tests (one skipped). The iOS suite also
passed all 920 tests with one skip and no failures; the complete `scripts/test.sh all` gate passed.

The Release archive and `.deb` were rebuilt after rebasing onto master `1355acd79`, at Linux
revision `32e2e27ec` with the pending title and renderer changes. The Swift-free archive and
installed non-root journeys, desktop provider discovery, same-child live reinstall and desktop
entry all passed again. The installed target-project, reattached-terminal and desktop-first-run
screenshots were inspected. These artifacts remain explicitly marked `source_dirty=true`.

## 99. Session names share the macOS policy

`AgentSessionRowPresentation` projects typed session, provider and account identity alongside
the existing title policy: a nonempty custom name wins, followed by the agent title when enabled,
the prompt title and the host's unnamed fallback. The macOS property supplies its existing
preference; the Linux preview follows the same enabled default without reading Mac settings.
The native renderer owns bounded labels, provider/account decoration and accessibility text.
Fresh admission and indexed restoration of an older selected session use the same projection.

The Linux core contracts and native AT-SPI fixture passed. Five stored rows exercised the
precedence and Unicode cases without changing their persisted bytes. A fresh stand-in Claude
process produced the unnamed row alongside Codex rows. With 519 saved sessions, an older selected
row retained its name and selection within the 512-entry catalogue and eight-row viewport.
All three native screenshots were inspected. The fixture uses `/bin/true`, so it verifies title
presentation and admission rather than authenticated provider behavior. All four new macOS
policy tests passed within the complete 9,642-test macOS run (83 skips, no failures). The iOS
gate also passed 920 tests with one skip and no failures.

## 100. Raster scans stay within each shape's horizontal bounds

An opt-in startup trace placed 6,995 ms of an 8,265 ms Debug first frame in raster work on the
loaded Linux VM. The scanline rasterizer cleared and composited every column for each covered
row, including narrow stroke segments and joints. Those two loops now stay inside clipped shape
bounds. Crossing order, antialiasing, clip arithmetic and source-over submission order remain
unchanged. Full-frame clip-mask allocation remains a separate cost.

The isolated optimized fixture compared the real shim and specimen with a frozen reference:
all six raw RGBA outputs matched, including fractional/offscreen paths, holes, transformed nested
clips, overlapping translucent strokes and four navigator sizes/row counts. Five-run process CPU
medians improved by 4–17%; the exact median/max measurements and reproduction command are in
[`performance.md`](../../docs/architecture/performance.md#linux-preview-raster-bounds-2026-09-30).
Heavy scheduling contention made wall times unsuitable for a launch-speedup claim. Native title
and deep-selection checks passed with the new renderer. The original startup and selected-terminal
restoration scenarios also passed on a frozen-runner rerun, with unchanged deadlines; that does
not prove the earlier intermittent timeout eliminated. The following empty-project accessibility fixture
also passed, but the broader 15-project accessibility fixture timed out waiting for its second-row
selection to reach the window title. That run did not establish a passing complete accessibility
lane; the later trace and mask correction below resolved the observed failure.

The diagnostic rerun subsequently caught a separate fixture race: GTK had published the folder
dialog's title before its X window was mapped, so `X_SetInputFocus` failed with `BadMatch`.
The fixture now waits for a visible dialog. Application/window lookups are scoped to the fixture's
PID, and a bounded opt-in trace follows accessibility enqueue, SDL delivery, row selection and
frame phases. The complete native accessibility path subsequently passed with the direct-mask
and retained-exposure changes below, without increasing deadlines.

## 101. Populated navigator drawing spends less time building clip masks

The navigation trace showed accepted accessibility selection reaching Swift immediately, followed
by seconds in raster work. Returning from the terminal at 960×600 with 11 rows spent 12,512 ms
in rasterization and exceeded the unchanged 12-second fixture deadline. An optimized CPU probe
attributed 60–75% of populated navigator drawing to clip masks.

Masks now write thresholded, byte-quantized alpha directly through the same scan converter as
fills. They no longer allocate an RGBA probe, blend discarded RGB or traverse it to extract alpha.
Seven raw frame fixtures and 6,912 bytes of direct mask values matched both the original and
intermediate implementations exactly. The mask change alone reduced the 960×600/11-row CPU
median/max from 42.14/43.31 to 17.30/17.58 ms, and 1280×900/17 rows from 105.67/107.09 to
31.73/33.68 ms. Full-frame alpha storage remains; these are optimized isolated drawing results,
not a Linux launch-time claim.

Same-size native exposures now replay the retained texture rather than rebuilding row models,
republishing accessibility and rasterizing an unchanged navigator. Actual geometry changes still
redraw, and semantic changes retain their dirty state. The three navigator event paths use one
implementation, including while store selection or folder import is pending. A real X11 exposure
test failed against the preserved earlier executable because it produced another raster frame.
The updated full native accessibility lane passed exact pixel restoration without another raster,
subsequent selection, actual and odd-sized resize, focus, Unicode terminal geometry and return
to projects. The startup lane also passed folder import, ordinary reopen and selected-terminal
restoration. Native navigator, terminal and restored/exited-terminal screenshots were inspected.
The observed Debug terminal-return raster took 1,088 ms on this run; changing host load prevents
treating its comparison with the earlier 12,512 ms as a stable launch-speedup measurement.
The raster oracle now stores each run's frames in a fresh directory. A repeated comparison
passed; a deliberate missing-mask probe on the reused output path correctly failed while
retaining the previous successful report, so stale artifacts cannot satisfy a missing output.

## 102. Explicit activation can restart the same saved shell

Opening a saved terminal used to attach even when its child had exited or disappeared, leaving
that destination unusable. Explicit activation now validates the exact terminal in its owning
project, surveys the daemon, attaches a live child or attempts one plain spawn with the same
typed identity. Startup restoration remains attach-only. A definitive refusal permits another
explicit activation and fresh survey; a lost spawn reply retains uncertain ownership and cannot
trigger another attempt. This path never asks the daemon to replace a child or writes a new
terminal record. It keeps the eight-runtime ceiling and performs selected-project reads,
directory checks and the bounded daemon survey on a worker.

`ProjectTerminalStartPlan` shares the recorded-directory fallback with macOS. Hosts provide
directory availability and retain their own shell executable, arguments, initial-command and
admission policies. The pure value carries terminal and owning-project identity, chooses the
recorded directory when available and otherwise uses the owning project's folder. Linux still
does not persist live cwd changes. This remains a host-owned action in the experimental navigator;
presentation cannot grant process-replacement authority.

The shared Linux core contracts and all three new macOS policy tests passed. The real native
fixture preserved record bytes, custom title, creation date, selected identity and exact argv;
explicit restart produced a new PID, duplicate live activation and normal relaunch retained the
existing PID, and a removed directory fell back to the owning project. It checked the initial
96×27 grid and attach-only startup after exit. Controlled peers verified explicit retry after
`alreadyExists`, no retry after a lost spawn reply, and no spawn after failed/missing ownership
surveys. Both native directory screenshots were inspected. The first run's exited-title assertion
omitted the existing history-restoration suffix; correcting that assertion changed no deadline
or product behavior. The focused lane is `THREADING_LINUX_RESTART_ONLY=1 ./window-smoke.sh`.
The Swift-free installed Release package passed the same restart/refusal fixtures, alongside
archive startup, non-root installation, desktop launch and live reinstall. A focused installed
follow-up also proved uncached explicit activation attaches the already-running child, and an
offline child exit stays dormant until explicit activation. Installed directory screenshots
were inspected. The artifacts identify source revision `3417b0ec2` with `source_dirty=true`.

The fresh-shell catalogue gap identified here is addressed in the next finding.

## 103. A fresh shell joins the saved picker through its existing runtime owner

Project shells previously updated the displayed count but stayed outside the saved-terminal
picker until a snapshot reload. A worker now publishes one receipt immediately after durable
record creation, even if the following selection or spawn fails. The navigator upserts that exact
identity into its capped recent rows and records the persisted count. Folder-import snapshots
settle before receipt consumption, avoiding stale refreshes and duplicate count increments.

The project and saved-row routes resolve one runtime owner by exact terminal identity. Explicit
restart replaces the same owner slot, so returning through the project reaches the restarted
child. Lost spawn replies still prohibit a replacement. This remains host-owned navigation in
the diagnostic frontend; no public extension authority or new drawing surface is introduced.
Review caught a pending-selection race: prepending a receipt could shift the row before its
committed Enter action replayed. Receipt consumption now waits for that replay, and ordinary
insertion preserves selected identity even at the 512-row cap.

The scaling contract is one normal admission and at most eight outstanding runtime receipts,
with at most 512 value rows per affected picker and only viewport rows rendered. Idle navigation
does not poll. A pending creation uses the existing 33 ms event wait until publication settles;
all store writes remain on the runtime worker. Project ownership is looked up through an index
built only when the initial or imported snapshot arrives.

The new native regression failed against the previous installed Release package at the missing
saved picker after creating the first shell, confirming the reported defect. The delayed-receipt
selection interleaving is reviewed but has no deterministic native race fixture yet.

The updated Swift-free installed Release package passed `bundle-smoke.sh` under non-root X11.
The new fixtures proved immediate AT-SPI row admission, unchanged persisted records, same live
PID through both routes, and a new PID under the same ID after exit. A 513-record fixture kept
the picker at 512 values and eight mounted rows. Eight real retained shells stayed usable through
saved selection; the ninth was refused without a new row or child. A real GTK folder import
refreshed the snapshot without changing the stored bytes or doubling counts. All four new
screenshots were inspected. Existing startup, provider PATH, live reinstall, saved restart/refusal
and desktop-entry checks also passed, as did the ten local runner tests and syntax checks.
The tested artifacts identify source revision `d518687a3` with `source_dirty=true`; source hashes
were unchanged between compilation and final inspection. Live shell cwd persistence remains the
next lifecycle gap.

## 104. Live shell directories persist without transferring project ownership

The previous installed Release package reproduced the missing persistence: ordinary bash changed
directory, but its durable terminal record retained the launch directory. The runtime now keeps
one latest path per retained shell (maximum eight), accepting validated local OSC 7 or sampling
the root process once per second on its worker. Remote, relative, oversized and control-bearing
OSC paths are rejected. SwiftTerm retains replay provenance across parser fragments, so an OSC
sequence beginning in history cannot become a live observation by ending in a later feed.

An attachment now carries the daemon's original optional process start time, including retained
exited sessions. Linux verifies that incarnation before accepting a PID and checks its start
ticks around each bounded `/proc/PID/cwd` read. Missing or mismatched start times disable process
sampling while preserving live OSC reports. The initial sample settles the child launch baseline
without overwriting a newer OSC observation.

Persistence validates an existing local directory and updates only the exact terminal in its
original project. A targeted transaction compares the last acknowledged directory, preserves
settings, ordering, sibling terminals and sessions, and never recreates a deleted row. Idempotent
acknowledgement avoids duplicate writes. Missing/stale records stop metadata tracking; busy
storage keeps one latest value and retries with bounded backoff. SQLite uses a zero busy timeout
for this worker. There is no per-output database work or window-actor file/process sampling.

Exit flushes before restart eligibility is published. Window close queues a final sample/write,
and app shutdown waits asynchronously for at most two seconds. Busy storage or a timeout can
leave the last committed directory. A no-OSC `cd; exit` wholly between samples cannot be recovered
after the PID disappears, and process fallback follows the root shell rather than arbitrary
foreground descendants. This remains host-owned behavior in the diagnostic Linux frontend.

The installed Release package passed ordinary bash with OSC 7 disabled: Unicode/spaced cwd,
same-ID restart in that directory, continued tracking after same-PID reattachment, original
project/settings preservation after entering another imported project, and deleted-directory
fallback. Controlled peers passed missing/wrong incarnation stamps, unrelated-PID isolation,
historical and split-replay OSC rejection, invalid live reports, and valid fragmented local OSC
updates with process sampling disabled. All four new native screenshots were inspected.
The full installed runtime lane also passed startup, provider PATH, live reinstall, saved-shell
restart/refusal, catalogue limits and desktop launch. The Release client/emulator contracts
passed, including a 2,000-report latest-value check. macOS passed 27 daemon tests and 66 database
tests (one existing live-project import test skipped because no legacy document was present),
79 protocol tests, and 134 parser tests. All 46 vendored files matched their originals.

The first controlled-peer run omitted required pixel dimensions in its grid; correcting the
fixture made the real attachment frame decodable without changing product code. The build
container also waited for stdin EOF after its harness completed. Explicit shell exit now runs
cleanup first; the eleventh runner test holds stdin open, checks exact daemon cleanup, and fails
when that exit is removed. The completed build was released explicitly and the installed runtime
lane rerun against the same binaries. The artifacts identify revision `489de13ec` with
`source_dirty=true`; compiled source hashes remained unchanged. The shared attachment stamp was
backported to local master as `b49e57dbc`, preserving unrelated work there.

## 105. Navigation and the active terminal share one workspace

The app previously replaced its navigator with a bare terminal and entered a nested event loop.
The workspace now keeps a fixed 320-pixel navigator beside the selected terminal, servicing both
from one loop. Existing project, saved-runtime and account routes keep their original runtime
owners, selection transaction, eight-runtime ceiling and 512-value picker bound. Only viewport
rows are mounted. The shim's existing specimen controls still draw navigation; this is progress
on native workspace structure, not production theme or extension-renderer parity.

SDL retains independent pane textures. Terminal output uploads its own frame without rebuilding
the sidebar; resize redraws bounded visible content and never stretches retained terminal cells.
The combined width ceiling grows to 1600 while the terminal's 1280-pixel/128-column limit stays
intact. Attachments adopt their existing grid with navigation added outside it. Pointer input,
IME cursor placement and accessible text geometry use the same terminal origin. AT-SPI exposes
both direct frame children and follows actual pane focus rather than hiding the inactive pane.

Ctrl+Shift+P focuses navigation, and from the focused project list opens the folder chooser.
Tab returns to the terminal; Escape dismisses one picker layer or returns from Projects to the
terminal. The terminal's own Tab/Escape bytes remain ordinary input. Navigation-owned key releases
stay suppressed after an activation changes panes, and composition is canceled when focus moves.
This remains a host-owned experimental navigator: Threading retains selection, persistence,
launch authority, input routing and bounded rendering. No Linux-specific extension API is added.

The installed Release workspace fixture keeps twelve projects in an isolated store and drives
real daemon PTYs through native input and AT-SPI. It verifies simultaneous visible siblings,
exact child reuse across projects, bounded mounted rows, unchanged navigator render counts during
terminal output, Unicode clipboard input, offset character extents and selection, and the child's
actual resized grid. A mouse press held across a session switch is completed on its original
child; the next child receives no orphan motion or release. Unsupported sidebar buttons leave
focus unchanged, proven by subsequent input reaching the same child. Six native screenshots were
inspected, including both focus states, resized panes, text selection and the held-button switch.

Final review caught native-only focus changes on unsupported sidebar buttons and invalid
accessibility selections. Focus now changes only with an event the workspace owner receives.
Selection writes and folder import freeze navigation decisions while their workers are pending;
they continue to route input to the visible terminal. The initial combined loop kept drawing
that terminal but discarded its input during these waits, so focus, rendering and input now use
the same route on both ordinary and pending turns.
An AT-SPI selection of an already-selected row remains an idempotent success; the row's explicit
select action transfers focus. Existing fixtures use Alt+F4 for window closure while retaining
Escape assertions for picker dismissal.

The final installed package passed startup/import, provider PATH, live-child reinstall, workspace
input, saved-shell restart/refusal, catalogue limits, live/replayed working directories and desktop
launch. The separate installed accessibility lane passed the existing list/selection/viewport
contracts plus simultaneous pane geometry and focus. Release client/emulator contracts and all
eleven runner tests passed. Artifacts identify revision `722b7f4fc` with `source_dirty=true`;
the six changed compiled source files matched their recorded build-time hashes after validation.
Eight further installed scenarios passed agent attachment/creation, named Codex and Claude
accounts, Claude lifecycle, retry refusal, selected-terminal restoration and project navigation.
The older agent fixture expected a project list after clearing agent selection by opening a
shell. It now verifies restoration of that selected shell's exact durable ID and live PID,
unchanged saved rows and a still-cleared agent selection.

The storage-contention regression holds a SQLite write transaction, confirms the selection
worker owns the host lock, focuses the still-visible old terminal and requires its exact input
byte before releasing either lock. It then verifies the requested destination opens with both
original runtime identities intact. The unchanged fixture fails at that input assertion on the
pre-fix package and passes on the final package, which also passes all three accessibility
scenarios. The additional post-selection screenshot was inspected. The final `.deb` SHA-256 is
`2d1e45b1d62a5d56de1dd8d6fb67e5e221c8dab8639fce8ae9d779a913a6c5cd`.

## 106. Agent catalogue admission follows the committed row

Fresh agents previously published a boolean after launch preparation. The navigator reconstructed
an unnamed row from the request, addressed its project by an old array index, and incremented the
displayed count. A folder-import snapshot could already contain that durable session; consuming
the boolean afterward inserted it again and counted it twice.

Creation now publishes one typed receipt immediately after the session transaction commits, while
the store's host lock still owns the count/read/write sequence. It carries the actual saved row's
presentation, project identity and committed full count. Reconciliation looks up that project by
identity, preserves an existing snapshot row's presentation and order, and admits a missing row
within the 512-value cap without moving the selected identity. Counts use the committed absolute
value and the imported snapshot, rather than incrementing a possibly refreshed count. This is the
preview's serialized append/import contract; it does not claim synchronization with external
session deletion.

A later spawn refusal does not undo the durable receipt. Failed-runtime cleanup checks both
pending creation and untaken publication so a receipt arriving between the two checks cannot be
discarded. The event loop continues bounded admission polling even when the visible terminal
has failed. At most eight retained runtimes contribute receipts or commit-order metadata; an older
receipt observed in a later turn stays behind already-published newer admissions from its project.
No database read or unbounded archive walk occurs on the UI actor.

The installed native fixture holds the real client's hello handshake while the system GTK
folder chooser is open, releases creation, observes the post-commit spawn request, then supplies
a definitive spawn refusal before the import snapshot returns. The pre-fix package reports
514 agents for 513 durable records; the fixed package reports 513 and publishes one saved row.
A second case inserts the receipt into an already-selected 512-row picker and preserves that
selected UUID. A third adds 512 newer fixture records before import, proves the admission is
outside the recent projection, and retains it without incrementing the authoritative 1,025 count.
All original record payloads remain unchanged. All three installed cases passed, and their
rendered native pickers were inspected.

The full installed bundle lane, Release client/emulator contracts, eight existing agent/account
and shell lifecycle scenarios, and eleven runner tests passed. Both changed compiled inputs
matched their build-time hashes after validation. The artifact identifies `19634fb38` with
`source_dirty=true`; its `.deb` SHA-256 is
`1a7aacbb199f470d04a5a5d21a2351b1e16ae8cbbde9655fd8e8c0bed1feebce`.

## 107. Production provider image drawing reaches the native Linux sidebar

Saved agent rows now keep title, provider and account as separate values. Claude and Codex
marks replace the generic dot and provider prefix, giving the session title more of the fixed
320-pixel sidebar. Their exact asset-catalogue PNGs are verified and packaged beside the window
binary. Missing artwork retains the explicit provider-name fallback. The accessible label keeps
provider, account and stable identity, reserving their byte budget before truncating a long title.
This remains the host-owned diagnostic navigator: selection, persistence, account routing,
launch and input authority stay in the host; no new extension contract is introduced.

`TemplateImageDrawing.swift` is vendored byte-identically and compiled against the shim. Its real
transparency-layer and source-in operations now work, including fractional tint and inherited
opacity. Graphics state is thread-local, matching AppKit's background drawing contract, while
views retain main-actor isolation. Layers allocate sparse 16-pixel tiles instead of one window
buffer per icon. Image storage is bounded; fixed provider decoding accepts at most 64 KiB and
64×64 pixels, checks PNG dimensions before Cairo allocation, and runs once on a utility worker.
Four cached presentations share the two decoded payloads; only mounted rows draw them.

The lab compiles the same production file against real AppKit and the shim, using the catalogue
artwork at 1× and 2×. It checks aspect fit, clipping, color artwork, selection ink, translucent
source-in tint and inherited opacity, and reports exact pixel differences rather than claiming
raster equivalence between different image samplers. Separate shim contracts cover asymmetric
pixel orientation, nested groups, fractional clips, invalid image bounds and concurrent contexts.
Custom account badges, theme choice, extension icon overrides and the full production sidebar
remain outside this slice.

Validation passed: all 36 cases on both real macOS AppKit and Linux, the focused Swift 6 image
contracts, seven byte-identical frozen-reference raster frames plus the mask fixture, eleven
runner tests, Release client/emulator contracts and the full installed-package lane. The latter
includes simultaneous workspace input/geometry, catalogue admission and caps, shell restart and
working-directory identity, live-child reinstall and desktop launch. The new installed fixture
proves both marks and selection states, long Unicode titles, account/ID accessibility and the
same shell UUID/PID across a deliberately resource-free copied-binary fallback. Its native
screenshots and representative cross-platform images were inspected. The comparison report is
`out/provider-image-comparison-20260930/index.html`; different samplers and transparent-pixel RGB
quantization remain visible in its exact difference counts, not hidden by a baseline tolerance.

The tested package identifies `e44038b58` with `source_dirty=true`; all shipping compiled inputs
matched their recorded build-time hashes afterward. The nonshipping lab separately needed an
explicit SwiftPM source link and conversion of `CGFloat` report values to `Double` for Linux
Foundation JSON serialization. The final `.deb` SHA-256 is
`31398cd761132f6c8e80f8741b97e130687027529586361ebfede61a61f3bbd4`.

## 108. Contextual Actions reuse production command admission

The diagnostic navigator now exposes its supported operations through an Actions button and
Ctrl+Shift+Space. Nine command values cover folder import, shell open/create, Codex/Claude
creation and account choice, and saved agent/terminal catalogues. Only the visible rows are
mounted. Disabled commands stay discoverable with an accessibility reason and no open action;
keyboard invocation receives the current refusal. Closing the picker restores the previous
catalogue and input focus.

`HostCommandContract.swift` compiles byte-identically on Linux after moving the unchanged
`AppCommand.hostDescriptor` projection beside its AppKit adapter. The picker captures a typed
project ID and rechecks both that identity and current availability through `HostCommandPlane`
before dispatching to the existing runtime handlers. The same admission path guards project
shortcuts. This is deliberately host-owned diagnostic presentation: identity, availability,
persistence, account routing, launch, focus, input and accessibility remain Threading's
responsibility. It does not introduce an extension component or claim themed Mac menu parity.

Button press/release, cancellation and accessibility activation share one bridge action. Review
found two ownership edges: shortcut release before the first terminal existed could leave text
suppressed, and returning focus to navigation after an outside dismissal could leave Swift
waiting for a mouse release that the native bridge had already cancelled. Key suppression now
covers the initial Actions surface, and navigation focus clears both sides of gesture ownership.
The installed fixture enables actual terminal mouse reporting and records child input, so leaked
UI events or a missing later release cannot pass merely because the child ignored mouse events.

The first native capture also exposed an ellipsized Actions label. The button now has room for
the complete label and both text insets; the fixture independently measures the installed font
width and checks the published rectangle. ATK's remote `DoAction` reply acknowledges receipt
before calling the local action callback, so its boolean cannot prove refusal. Disabled-action
checks instead use a synchronous D-Bus barrier followed by no native enqueue, no selection
change and unchanged durable identities. Separate old-package runs reproduced both input
failures; their logs and recorded bytes are under `out/actions-{keyboard,mouse}-before.log` and
`out/actions-regression-before.json`.

Validation passed for the 47-file vendor identity check, Release core/command and PTY-client
contracts, eleven runner tests, and the complete installed-package suite. The new fixture checks
real header gestures, keyboard and AT-SPI activation, bounded rows and disabled admission,
native folder chooser cancellation, both focus-return paths with actual mouse bytes, exact shell
UUID/PID reuse, and both provider routes with isolated named-account PTY stand-ins. Native
normal/pressed, empty/disabled, live-menu and provider-route screenshots were inspected in
`out/bundle-smoke/restart-out/actions-*.png`. Actual provider services and complete themed-menu
parity remain outside this diagnostic slice.

The unchanged command adapter projection passed the six focused ordinary Mac test classes on
both the Linux baseline and exact master candidate: 64 tests, one skipped because no extension
was installed, zero failures. The three-file shared extraction landed on master as `22e4c7b98`,
with unrelated working edits preserved. The tested Ubuntu arm64 package records `2de566a24`
with `source_dirty=true`; its SHA-256 is
`6f6b5326dcbbc5b8b3676cc14e048ee910d5aaf9d55c8d5c7a6ef46c51ba4667`.
The existing detailed AT-SPI suite also passed against that installed binary, covering bounded
navigation, simultaneous panes, native/text geometry and independent focus. All 129 recorded
spike compilation inputs retained their build-time hashes after verification.

## 109. Flat surfaces share production geometry and paint

`SurfaceDrawing.swift` now owns the production flat fill/border painter and fitted silhouette.
Mac `ThemedSurface` keeps its public `Shape` spelling through a typealias, resolves the default
radius after the half-border inset, and delegates flat drawing. Hard/soft bevel selection and
artwork remain in the Mac wrapper. The shared leaf has no theme observer, control/responder,
CoreText or layer dependency, so Linux compiles the exact file against its existing shim.
The native plugin design kit also links the new leaf through its existing shared-source boundary;
extracting a dependency from `ThemedControl` requires both compilation owners to receive it.

Selected navigator rows and the Actions button now call that painter instead of constructing
their own rounded selection path. Their current radius, colors, clipping and paint order remain
the same. This is still diagnostic assembly, not production sidebar or button behavior parity;
Linux does not yet consume the Mac theme environment or bevel artwork. This adds no public
extension surface: the existing host retains selection, focus, command and runtime authority.

The scaling boundary is unchanged: fixed-cost silhouette construction and paint occur only for
mounted rows (normally eight, bounded by the viewport), never for all 512 retained catalogue
values. There is no new discovery, I/O, view population or animation work. The existing raster
comparison includes the new exact source so the laboratory still compiles the shipping painter.

Linux validation passed: the full installed Ubuntu 24.04 arm64 Release package lane, including
workspace input/focus/resize, bounded catalogue admission, Actions pointer/keyboard/AT-SPI
activation, provider glyphs, shell identity/restart/cwd, live-child reinstall and desktop launch.
The native normal/pressed Actions and selected-row screenshots were inspected. The existing
raster suite still matches all seven RGBA frames and its threshold mask. A separate matched run
of that same fixture, changing only pre/post `Specimen`, found zero differing bytes across five
navigator frames at three viewport sizes (14,592,000 RGBA bytes). This is shim equivalence;
it does not claim identical raster sampling between AppKit and Linux.

The tested package identifies `a9fc15bd3` with `source_dirty=true`; all 128 recorded spike source
inputs retained their build-time hashes. The `.deb` SHA-256 is
`92b99be59c08cf6a9880ceaba1fb54f03e6fcc11c4e365c8dbd1d2d34f783e86`.

On macOS, both complete 85-test evidence capture runs passed. The extraction also passed
363 tests covering that catalogue and the existing surface geometry, bevel and panel-inset
contracts (one opt-in stress test skipped). All 24 command-palette captures across six states
and four theme/appearance choices have identical decoded pixels before and after the extraction;
the real shell, navigator and component images were inspected as well.

Full-catalogue pixel equivalence remains unverified. The canonical decoder's measured throughput
under host contention projected roughly seven hours for the 1.645-billion-pixel catalogue, so its
partial comparison was preserved rather than reported as complete. It also exposed existing
gallery variability: a clock/random greeting, animated artwork and time-based usage data, plus
ambiguous accessory/banner widths. Those owners were unchanged by the extraction. No baseline
was accepted, no pixels were masked, and the partial report is not a clean full-catalogue result.


## 110. Saved-agent identity, title and attention have separate presentation owners

The preview's single concatenated label let a long title push account and session identity past
its ellipsis. Saved-agent rows now have a primary title, a smaller provider/short-ID/account line,
and a reserved status region. The provider mark remains beside those runs. Missing artwork still
leaves the textual provider; the bounded accessible name still includes provider, account, short
ID and attention, and the accessible ID remains the exact durable UUID. A retained runtime says
`Retained`, not `Working`: the preview has no provider activity observer.

Both hosts consume `AgentSessionRowPresentation` for identity and semantic attention precedence.
Mac `SessionRowView.configure` passes its existing `NativeSidebarParity` facts through the value;
its constraints, badge, theme, extension slots, trailing actions and command ownership are unchanged.
The snooze predicate stays lazy when scheduled/wake already wins. Linux supplies no unsupported
scheduled-start state. Valid durable snooze deadlines remain values in its snapshot, and the next
visible expiry invalidates the cached raster and accessibility without rebuilding the catalogue.

This is still the existing host-only diagnostic sidebar, with no new public extension contract.
Selection, durable IDs, runtime ownership, account admission and command execution remain with
the host. Layout differs intentionally from the Mac sidebar, whose account badge and hover actions
need different reservations; no unused shared rectangle API was introduced.

Scaling stays tied to the viewport: the 512-row saved catalogue remains value data, while the
current 900px maximum mounts at most 17 rows. There are at most three text fragments per mounted
agent row plus two header fragments. The bridge explicitly caps rows at 32 and fragments at 98,
retains the 32KiB aggregate UTF-8 limit and 1KiB fragment limit, and validates the complete batch
before drawing. It borrows bytes only during the synchronous call and reuses one width-by-64px
Cairo surface. Deadline bookkeeping visits only the mounted rows during an existing redraw;
terminal output still reuses the cached navigator.

The focused Pango contract passed Unicode, independent clipping, complete-batch rejection and
unellipsized status widths. The first full installed Release package lane also passed, including
workspace, 512-row catalogue, Actions, retained provider PIDs, reinstall and desktop launch.
Selected, unselected, retained-status and missing-artwork row renders were inspected. All 132
recorded package inputs stayed unchanged. That package's SHA-256 is
`3a22696a5ea157fd27d2111e35522526c9a5e6a70c828e41d82ca09a24635292`.

Review then found a gap in that passing fixture: its live terminal already woke the host loop.
Without a terminal, an indefinite native event wait left an idle saved-agent picker showing
`Snoozed` after its deadline. A separate installed run of that same package reproduced the stale
label after 25 seconds, with only the list and Actions button mounted and no child spawned.
The corrected host chooses a deadline wait, capped at one second to recheck wall-clock changes.
The native wait keeps one monotonic total deadline and continues pumping accessibility internally;
ignored events neither finish the wait early nor restart its timeout.

The native wait comparison reproduced both defects before the fix: an ignored SDL event ended a
200ms wait at 75ms, and a 2000ms wait left the accessibility callback undispatched. Afterward the
same checks passed at 203ms for the deadline, 0ms for a queued event and 69ms for accessibility
dispatch. These are focused wait-contract measurements, not application performance results.
The corrected installed Release suite passed, including the no-terminal expiry and live-terminal
expiry cases, preserved selected UUID, and absence of an unintended child. Both idle states were
inspected in the native window. Workspace, Actions, provider, catalogue, restart, reinstall and
desktop-entry lanes passed again, and all 132 recorded package inputs kept their frozen hashes.
The corrected package's SHA-256 is
`6feccd0ca6830ce4695a7d3520a84d956620291ce9d03de88dfdd77e1ee013aa`.
The Mac row suite passed all 19 focused tests, including attention precedence, unchanged titles,
refresh/reuse and press-start/recycle/release routing. A fresh host captured the 38 canonical
light/dark sidebar rows; all 1,021,440 decoded pixels matched the before capture exactly.
Representative idle, long-title, selected, pinned, scheduled and blocked rows were inspected.
This verifies the native row surface, not full-application pixel equivalence or performance.


## 111. Resolve neutral ink against the painted ground

The diagnostic navigator now consumes the exact production `NeutralInk` and
`TextLegibilityPolicy` leaves. Its Swift assembly resolves label and secondary roles against
body, header, selection and the current Actions-button ground once per navigator redraw.
Mounted rows reuse those values; cached terminal-only frames do not resolve them again.
Template provider marks, bitmap fallback labels and Pango labels receive the same label ink;
the smaller account/identity/status runs receive secondary ink. Plain Claude artwork keeps its
original brand pixels. This does not add Linux theme selection or a public customization surface;
commands, selection, accessibility identity, runtime and account ownership remain with the host.

The C text bridge accepts host-resolved straight sRGB RGBA, with every component required to be
finite and within zero through one. It validates the complete bounded descriptor batch before
painting, including a malformed later fragment. Alpha is composited once through the existing
premultiplied Cairo intermediate. The detail flag now selects font size only. The existing
98-fragment, 32KiB aggregate, 1KiB per-fragment and mounted-row bounds are unchanged.

The focused renderer fixture compiles the exact shared leaves into a test-only ink exporter.
Its independent pixel/contrast assertions cover the actual body/header/blue-selection grounds,
a pale selection, all four Actions states, role ordering, reading/glance floors, translucent and
zero-alpha text, unchanged pixels outside the clip, and whole-batch rejection of invalid RGBA.
The raster fixture also consumes the same leaves for template marks and bitmap text. The focused
Linux text/neutral-ink contracts and the full source-built native window lane passed. The installed
Ubuntu 24.04 arm64 bundle lane also passed, including workspace, Actions, provider-mark,
catalogue, terminal-restart, reinstall and desktop-entry cases. Normal/open Actions and selected
provider rows were inspected in fresh X11 screenshots. Four focused `NeutralInkTests` passed on
macOS. The ordinary Mac build gate separately reports a pre-existing UI-structure ceiling mismatch
(2,854 constraint sites against 2,852); the focused test build bypassed that gate for this run.
Matched Mac/Linux pixels, Wayland, theme selection and a measured Linux Release latency bound
remain unverified.

## 112. A production disclosure mark runs through the AppKit shim

The shim now exposes `NSBezierPath` element inspection, geometric bounds including cubic extrema,
flattening and affine transformation. The unchanged production `OpticalCentring.swift` compiles
against it on Linux. Focused Linux geometry checks cover a triangle's centroid and optical rise,
cubic bounds, flattening and transformation; a macOS AppKit comparison checked the corresponding
path API and bounds. The shim's curve flattening retains its bounded 96-segment rasterizer limit,
so highly curved paths are not claimed pixel or centroid equivalent to AppKit.

`DisclosureTriangleDrawing.swift` is a small `UI/Design` drawing leaf. The diagnostic Linux
Actions button uses it inside the existing host-owned button surface: down when closed, up when
open. The mark does not add a hit target or an accessibility action. `OpticalCentring` positions
its ink, while the button keeps command admission, pointer handling and AT-SPI identity. The
installed X11 screenshot contract checks visibility and orientation in both states and confirms
the button's 100×36 accessible bounds; normal/open renders were inspected. This is one shared
drawing component in the diagnostic navigator, not a port of the production sidebar or theme
environment.

The Linux `Harness` now exits nonzero when its layout checks fail. `shim-smoke.sh` runs those
checks, validates the CRC and dimensions of three rendered PNGs, and injects a layout failure to
verify that no PNG is written after refusal. It skips only the optional scaling benchmark; the
ordinary harness still runs that benchmark. The installed `.deb` lane passed end to end in a
Swift-free Ubuntu container, including the new mark check. Its SHA-256 is
`3e6a567d60c485ff43b1bc867e53e8508efa3eea5a55a960ee1377fee1e6d30c` and its manifest
records revision `e696b12cb18d42beb3193ef4978339f6b8722bcb` with `source_dirty=true`.
On macOS, the focused `OpticalCentringTests` passed all 12 cases with the same pre-existing
UI-structure gate bypassed for that test run.

## 113. Shared navigator slots and two more production views compile against Linux AppKit

`NavigatorRowGeometry.swift` now owns the 4pt leading inset, 16pt icon slot and 6pt content gap
used by the Mac sidebar's project row. The diagnostic Linux navigator vendors that exact leaf:
project dots and provider images are centred in its icon slot, and both bitmap and Pango labels
start at its 26pt title offset. Saved-agent title and detail runs use the same leading offset.
Text clipping remains bounded by each mounted row; selection, command admission, accessibility,
provider identity and trailing status remain host-owned. This is a shared presentation value,
not a port of the Mac sidebar's theme or hover controls. Only visible rows are rendered; the
existing 512-value picker cap and mounted-row/text-fragment limits remain in force.

The Linux shim gained real `NSStackView` arranged layout, hidden-member detachment, spacing,
insets, equal distribution and reparenting behavior. The tracked stack fixture passes on macOS
AppKit and Linux, and compiles and renders unchanged production `ControlRow.swift` on both.
`NSView.backingAlignedRect` now snaps inward using the active device transform, including a
fractional nested origin. A combined-file probe compiles exact production `GlyphView.swift` and
`TemplateImageDrawing.swift`; its rendered fixture passes 1×/2× alignment, template tint,
artwork colour, size cap, aspect fit and decorative accessibility. Those two fixtures are
component evidence; the complete production theme/text environment is not yet on Linux.

The focused Mac navigator geometry tests passed 2/2, including a mounted `ProjectRowView`.
Targeted real-shell sidebar evidence rendered and was visually inspected at full and narrow
widths with preserved icon/title placement. This machine captured 1× screenshots against 2×
checked-in baselines, so a pixel-equality verdict is unavailable. The full source-built Linux
native window suite passed after its two test fixtures stopped carrying a selected terminal
into cases that require the project list, and after its picker assertion distinguished a 960px
terminal pane from the 1280px window that includes the sidebar. The shim smoke passed its layout,
backing-alignment, PNG and injected-failure checks. The installed Swift-free Ubuntu 24.04 arm64
package suite passed workspace, Actions, provider marks, saved terminals, catalogue limits,
reinstall/reattach and desktop launch. Its `.deb` SHA-256 is
`f0235e2cc33ca50d8bce3cd477fdfc47128aae9d9cacd4f34d9c25f4788d76c1`.
Fresh installed X11 provider-row and desktop-launch images were inspected. Wayland, whole-app
Mac/Linux visual parity and a measured Linux Release latency bound remain unverified. A fresh
per-file design sweep still reports 125 shim-gap files out of 157; cross-file production helpers
make some of those raw per-file verdicts false positives, but substantial text, accessibility
and window integration work remains.

## 114. Project-row presentation and a Pango label leaf run through Linux AppKit

`NavigatorProjectRowPresentation.swift` now owns the native title, optional checkout path,
identity-mark visibility and typography role for project, checkout, repository and quiet heading
rows. `ProjectRowView` applies that value while keeping selection, commands, counts,
accessibility and extension replacement host-owned. The diagnostic Linux navigator vendors the
same value for its mounted project rows, giving their title the corresponding semibold role and
using its identity-mark rule. The Linux diagnostic still appends agent/terminal counts in one
shaped text run and does not implement the Mac theme or full row composition. The new Mac value
tests passed 2/2. Six real-shell project/checkout screenshots at full and narrow widths were
inspected and are byte-identical to same-machine, same-scale captures from before the refactor;
the checked-in baseline images use another backing scale and are not the comparison here.

The Linux `AppKit` shim now has a label-only `NSTextField` backed by bounded Pango/Cairo shaping.
It accepts at most 4096 UTF-8 bytes for shaping and rasterizes no more than 2048×128 visible
pixels and eight lines per label. Intrinsic size, first-line baseline, alignment, clipping,
wrapping and head/middle/tail ellipsis have concrete implementations. Editing, selection,
bordered/background controls and IME are explicitly unsupported; a wrapped label's last-baseline
anchor currently reports its first-line baseline. `NSBaselineMetric` supplies a measured offset
and solved-height fraction to the linear layout solver, so a vertically centred label's baseline
moves correctly when its height changes. `NSView.render` flips a child only when its coordinate
orientation differs from its parent; this closes the nested flipped-parent label gap.

The tracked Linux text fixture passed composed/decomposed accent and Arabic ligature shaping,
bounded clipping, ellipsis pixels, intrinsic size, empty-label height, baseline, accessibility
name and font-weight mapping. It compiled unchanged production `ControlRowView.swift` and
rendered two real Latin/Arabic labels, plus an upright label nested in a flipped parent.
`out/text-label-control-row.png` and `out/text-label-flipped.png` were inspected. The full
source-built X11 native-window suite passed with the new shim and project-row role. Two earlier
runs stopped when an `xdotool search` process hit its own five-second timeout inside title
waiters; those waiters now retry a timed-out query within their existing 15-second overall
deadline and still fail if the title never appears.

The final installed `.deb` suite passed in Swift-free Ubuntu 24.04 arm64, including live-child
reinstall, native workspace, Actions and provider accessibility, saved-terminal restart,
512-row picker cap, desktop launch and non-root window. Its SHA-256 is
`b8185e9c4cc382def84fbd58f88ccfaa70b8ed2bee2a62ef1cad7464ba8df335`. Fresh installed
project-list, provider-row and desktop-entry PNGs were inspected. The theme-boundary and
main-actor-latency gates passed, as did vendored-source byte identity and `git diff --check`.
The shim specimen, stack-layout, glyph-view and text-label fixtures also passed, with rendered
evidence inspected. The latest Design sweep reports 9 clean, 30 shim-clean and 120 shim-gap files.

The same final `.deb` also passed the clean headless-Wayland render smoke in Swift-free Ubuntu:
two selected-project states produced distinct inspected 800×480 frames, an `xdg_toplevel`, and
`wl_surface` commits. During diagnosis, default libdecor published a GTK `WindowHarness`
accessibility tree without `linux.actions`; disabling libdecor restored Threading's tree but
removed the client decoration path. Selecting Ubuntu's Cairo libdecor plugin instead restored
Threading's custom tree while retaining decoration subsurfaces and 24-pixel top geometry. The
package now depends on that plugin and sets `LIBDECOR_PLUGIN_DIR` only for its Wayland window,
unless the caller explicitly overrides it. Its default installed `--actions` smoke passed:
AT-SPI opened and closed Actions, normal/open frames differed, the daemon did not receive the
plugin override, and no GDK warning appeared. A separate installed `--actions` run supplied an
explicit Cairo-only `LIBDECOR_PLUGIN_DIR`; WindowHarness kept that exact override and the same
render and accessibility checks passed. Physical Wayland pointer, keyboard and IME input on a
desktop remain unverified.

## 115. Provider marks use a real Linux NSImageView leaf

At that stage the Linux AppKit shim supplied `NSImageView` with AppKit's default proportional-down scaling,
the other three scaling modes, image-derived intrinsic size and template-only `contentTintColor`.
Its default is decorative in accessibility, as observed on macOS. The preview's mounted provider
marks passed through this view instead of a second hand-drawn image branch in `Specimen.Row`.
Only rows in the current viewport create an image view: the installed 512-row picker contract
still mounted eight rows, so saved catalogue size does not become view count.

The tracked glyph fixture passed 1×/2× alpha-tint and aspect-ratio pixel checks for the new
leaf, alongside the unchanged production `GlyphView` checks. Its PNGs were inspected. The full
source-built X11 window suite and the Swift-free Ubuntu installed-package suite passed, including
selected/unselected Codex and Claude marks, Unicode titles, absent-artwork fallback and AT-SPI
identity. Fresh installed provider-row images were inspected. The installed package also passed
headless-Wayland toplevel, project-frame and Actions accessibility checks; normal/open frames
were inspected. The new `.deb` SHA-256 is
`a7f263998b1a8ca69639979ca705284c0a8b4b2083844f9a56e8f87b8ca76741`.

Image decoding, SF Symbol lookup/configuration, animation and whole-product theme delivery are
still outside this image-view leaf. It proves the mounted image path can use the shim, not that
all production `NSImageView` consumers compile or that the Linux sidebar matches macOS. The
fresh per-file Design sweep still reports 9 clean, 30 shim-clean and 120 shim-gap files: no
file lost its last blocker yet. Plain `NSImageView` is gone from the missing-symbol list, while
symbol configuration, accessibility identifiers and platform image services remain in that tail.

## 116. Navigator text is mounted through the Linux AppKit label shim

The native window now mounts each visible navigator text fragment as a bounded `NSTextField`
inside the same view tree that paints its row chrome and provider mark. The separate
`NavigatorDrawing.c` batch renderer and its C-only contract were removed. The host still owns
selection, commands, identity and the AT-SPI row tree; decorative label views do not add a
second accessibility route. Admission remains limited to visible rows, 1024 UTF-8 bytes per
fragment, 32768 bytes per frame and the existing label count cap. Long text truncates within
its own rectangle, leaving status and account fragments independent.

The label now preserves regular, medium, semibold and bold font roles through Pango. Its
coverage mask uses one bounded bitmap blend when graphics state permits, while clips and
transparency layers retain the general path. Fixed-frame view trees with no active constraints
also skip the simplex solver; constrained stacks still use it. In the 54-label rebuilt-tree
Release benchmark, the median frame fell from 29.88 ms to 6.24 ms (maximum 7.91 ms after the
change). The shared neutral-ink fixture checked actual rendered text pixels and contrast on
eight grounds, alpha compositing, clipping, Unicode, title/detail isolation and the unchanged
production `ControlRowView`. The focused label fixture and shim specimen passed.

The full source-built X11 window suite passed after a prior Debug run hit its 8-second terminal
title wait during a 6.84-second whole-window raster. Debug pure-Swift rendering under host load
still has that latency risk; the installed Release path is the measured shipping path. The full
Swift-free Ubuntu installed-package suite passed, including provider marks, Actions, AT-SPI,
saved-terminal restart, live-child reinstall and desktop launch. Fresh installed provider and
Actions PNGs were inspected. The same package passed headless Wayland toplevel and buffer
checks, two project selection frames, and AT-SPI Actions open/close; all three new Wayland
states were inspected. Its `.deb` SHA-256 is
`79b14f38dba6afed942d30719710d29ac76d7f743e52a4699d505b339b13f91b`.

The theme-boundary and main-actor-latency gates, vendored-source byte identity and
`git diff --check` passed. Text editing, selection, rich text and IME remain outside this
bounded label leaf. The diagnostic sidebar still does not establish complete macOS UI parity.
The refreshed per-file Design sweep at that point reported 9 clean, 30 shim-clean and 120
shim-gap candidates. `NSAccessibility`, appearance change hooks and `NSWindow` appeared often.
`NSTextField.applyFont` also appeared, but that method is a Threading extension in
`FontRole.swift`: the one-file sweep had not compiled its owner. This label leaf is now
exercised in the native window, but no additional Design file had lost every blocker.

## 117. Authored multiline titles keep their measured lines on Linux

The Linux `NSTextField` already drew authored line breaks in wrapping mode, but its intrinsic
measurement called Pango in single-paragraph mode. That collapsed a two-line title to one line
in Auto Layout. The text bridge now measures the first visible Pango lines directly, up to the
label's eight-line cap, and keeps an empty wrapping label at zero width with one line of height.
The shim also stores a typed `NSAccessibility.Role.staticText` rather than a string-only role,
which lets the unchanged production `ThemedMultilineTitleLabel` compile in the Linux fixture.
The role remains local view metadata; the native host's separate AT-SPI tree is still the
installed window's accessibility route.

The fixture links that production source by symlink and supplies only the test theme's label
ink and heading-font decision. Its constrained host verifies the title's authored two lines,
intrinsic height, position, painted pixels and normalized accessible label. The rendered title
PNG was inspected. The focused label fixture, full source-built X11 window suite and full
Swift-free Ubuntu installed-package suite passed. Fresh installed provider and Actions frames
were inspected. The rebuilt package passed headless Wayland toplevel/buffer checks, two project
selection frames and AT-SPI Actions open/close; the three new Wayland frames were inspected.
The `.deb` SHA-256 is
`d93aefa6ba695bc9c6a9948e2a0fd6a809131ae8874d161dec3a850d8648d1cd`.

The per-file Design sweep reports 9 clean, 34 shim-clean and 116 shim-gap *candidates* after
adding the typed role. Its classifier now catches nested static members such as
`NSAttributedString.Key.font`, but the totals are not a proof that four entire files became
portable: app-owned extensions like `NSTextField.applyFont` still appear as gaps, and missing
app-owned types can prevent Swift from resolving a contextual member like `.group`, hiding a
real shim gap. The multiline production component is verified in a constrained Linux fixture;
it is not yet mounted in the installed diagnostic window. Editing, rich text and IME remain
outside the bounded label shim.

## 118. Bounded attributed drawing carries a production compound reading

`CompoundValueLabel` builds an attributed string for each candidate count, measures it,
and draws only complete segments that fit. The Linux AppKit shim now supplies the font,
foreground/background ink, kern and underline attributed keys plus Pango-backed `size()` and
`draw(at:)`. A single Pango layout measures and draws the complete attributed string. Input
is limited to 4096 UTF-8 bytes, 64 style runs, eight visible lines and a
2048×128 raster. A run-cap ellipsis trims complete UTF-8 scalars before crossing the byte
limit. Cairo uses grayscale font antialiasing: its default antialias mode had produced dark
subpixel components in translucent red glyphs on a clear destination. A clear-versus-white
composition check now catches that error.

The focused fixture links the unchanged production `CompoundValueLabel` and supplies only
theme values. It checks intrinsic size, complete-segment omission in a constrained view,
painted pixels and the full accessible value. Mixed Latin/Arabic color, background and
underline pixels, alpha compositing and the 64-run/4096-byte boundary also pass. The
attributed and compound PNGs were inspected. In Release, rebuilding 18 visible compound
readings across eight frames took a median 10.34 ms and maximum 11.05 ms. The existing
54-label navigator benchmark measured 7.23 ms median and 11.12 ms maximum in the same run.

The complete source-built X11 suite passed before the final style-run boundary correction;
the focused fixture passed again afterward. The final source built as a Swift-free Ubuntu
Release `.deb` and passed the full installed X11 suite, including Actions, provider images,
AT-SPI, workspace panes, saved-terminal restart, live reinstall and desktop launch. Fresh
installed Actions and provider PNGs were inspected. The same `.deb` passed headless Wayland
toplevel and buffer checks, two project frames and AT-SPI Actions open/close; the project
and open-Actions frames were inspected. Package SHA-256:
`e189588b87cd4fdb9851768f7523142baa0f7a49c2bb0ecca5942e0258655751`.

The refreshed per-file Design sweep reports 9 clean, 36 shim-clean and 114 shim-gap
*candidates*. It still counts app-owned extensions such as `NSTextField.applyFont` as shim
gaps, and missing app-owned types can conceal contextual member gaps. The production
compound component runs in the fixture but is not mounted in the installed diagnostic
window. Paragraph styles, `NSString.draw`, editing and IME remain outside this attributed
leaf; this evidence does not establish complete macOS UI parity.

## 119. NSString rectangles and paragraph alignment reach a production badge

The attributed Pango bridge now takes an optional bounded layout width, line-break mode and
alignment. Linux AppKit exposes `NSParagraphStyle`/`NSMutableParagraphStyle` with those two
properties, `NSAttributedString.Key.paragraphStyle`, attributed `draw(in:)`, and `NSString`
`size(withAttributes:)`, `draw(at:withAttributes:)` and `draw(in:withAttributes:)`. The point
and rectangle paths share the same prepared style spans. Rectangle drawing uses Pango's word
and character wrapping, clipping and head/middle/tail ellipsis inside the caller's rect, with
at most eight visible lines and a 2048×128 pixel raster. Both direct attributed preparation
and the `NSString` convenience methods take a bounded prefix before copying text into the
drawing leaf. The fixture exercises 50,000-character source strings and the existing style-run
and UTF-8 limits.

`NSView` now converts points through frame offsets and nested flipped boundaries, stores
accessibility identifiers and values, and exposes a typed button role, press hook and drag
callback. The text fixture links the unchanged production `SimulatorRecordingBadge` with
test-only theme/control/surface dependencies. It verifies measured title size, a constrained
frame, drawn dot and title pixels, recording and finishing PNGs, accessible value, inside and
outside pointer releases, and the disabled finishing action. The recording, finishing,
truncated-rectangle and wrapped-string PNGs were inspected. The fixture does not use the
production `ThemedControl` or mount the badge in the installed diagnostic window.

The focused fixture passed after the final bounded-prefix change. Its Release benchmark
rebuilt 18 visible `CompoundValueLabel` readings across eight frames in 6.59 ms median and
8.24 ms maximum; the 54-label navigator benchmark measured 6.58 ms median and 7.25 ms
maximum in that run. The full source-built X11 suite passed before that last prefix change;
the final source built into a Swift-free Ubuntu Release `.deb` and passed the complete
installed X11 suite. Fresh installed Actions and provider PNGs were inspected. The same
package passed headless Wayland toplevel/buffer, two project frames and AT-SPI Actions
open/close checks; all three Wayland states were inspected. Package SHA-256:
`1302b0795c0f0ca5c61d4314bd1c5b7e713a7794a361e61da24b281b2ec14be8`.

The per-file Design sweep reports 9 clean, 37 shim-clean and 113 shim-gap *candidates*.
`SimulatorRecordingBadge.swift` moved from the two `NSString` member candidates to
shim-clean, though it still needs app-owned dependencies to compile. The sweep remains a
classifier, not a proof of full source compilation: app-owned extensions appear as gaps and
unresolved contextual members may be missed. Advanced paragraph properties, editable text,
control IME and complete screen-reader behavior remain outside this leaf.

## 120. Storage proposal viewport redraws stay bounded as the cleanup list grows

The production `StorageProposalOutlineView` is a delete approval surface: all candidate paths
and sizes must remain visible by scrolling and readable through its full accessibility value.
It already drew only intersecting rows, but each scroll repaint measured every size string and
walked every row to find those few visible ones. A Release fixture with a 180-pixel viewport
measured 5.63 ms median for 170 rows and 30.20 ms for 1,700 rows, across eight warm repaints
each. The view now caches row tops and the widest size column for the current resolved fonts,
uses binary search to reach the first visible row, and draws only the visible run. A font-name or
point-size change rebuilds the geometry; a test changes the fixture's font scale and checks that
the full fitting height changes and returns. The same Release fixture measured 4.52 ms median
at 170 rows and 2.40 ms at 1,700 rows after the change. These short timings show the loss of
total-row redraw scaling in this fixture, not a guarantee about slower hardware or first mount.
The initial run used a Japanese path segment and the final run used `Ångström` to avoid missing
glyph boxes in the container, so the absolute before/after times are not a matched text sample.
The initial flatten and geometry measurement still scale with the proposal size once per font
configuration.

The Linux shim now supplies `NSFont.boundingRectForFont` through Pango ascent/descent metrics
and `NSAccessibility.Role.group`. The font rectangle is a layout approximation, not a macOS
glyph-union rectangle. Its lazy cache uses a lock, and the bounded `NSString` and attributed
drawing methods are callable outside the main actor as their AppKit counterparts are. The
focused fixture links the unchanged production outline source, with test-only model and theme
values; it checks 170 rows, full accessible text, first/deep viewport pixels, and typography
remeasurement. The first and last PNGs were inspected; the container lacks the Japanese font
used in the initial path fixture, so the final evidence uses `Ångström` for a supported
non-ASCII path segment. This component is not yet mounted in the installed diagnostic window.
The focused macOS `StorageProposalOutlineRenderTests` suite passed all five tests after the
source change, and its real AppKit light and dark rendered PNGs were inspected. The macOS build
first found the repository UI-structure inventory two constraint sites above its checked-in
ceiling. Three repeated project-row square-size pairs were moved to a Design-owned helper,
reducing the measured count from 2,854 to 2,848; the ceiling was lowered to 2,848, and the
subsequent focused build and architecture checks passed.
The fresh per-file Design sweep reports 10 clean, 38 shim-clean and 112 shim-gap *candidates*.
`StorageProposalOutlineView.swift` moved from the font-metrics gap to shim-clean; the new
Design-owned square constraint helper is the additional clean file. This remains a one-file
classifier, not a measure of how many full screens compile together.

The final source built into a Swift-free Ubuntu Release `.deb`. Its full installed X11 suite
passed: workspace panes, Actions keyboard and AT-SPI behavior, provider marks, saved-terminal
restart, live reinstall, desktop entry and non-root launch. Fresh installed Actions and
selected-provider PNGs were inspected. The same package passed headless Wayland toplevel and
buffer checks, two distinct project frames, and AT-SPI Actions open/close; the normal,
alternate and open-Actions Wayland captures were inspected. Package SHA-256:
`aa656bfb21ee8aee66b91987670b69f115e41bf5b29e8edb0ec4eaa6b85339cd`.

The complete source-built Debug X11 suite did not pass this time. One run exceeded the
agent-catalogue fixture's four-second handshake window while a separate Design sweep was
compiling; its subsequent run passed that catalogue case but timed out during Actions keyboard
navigation, where the trace showed 2–4-second raster frames and the test permits 15 seconds
to reach the ninth command. The installed Release Actions test passed that same ninth-command
and accessibility path. The Debug suite's full completion remains unverified; no source-built
Actions success is inferred from the Release result.

## 121. Inherited appearance drives a production sparkline on Linux

The Linux `NSView` shim now inherits an explicit `NSAppearance` through its retained tree,
notifies only descendants whose effective appearance actually changes, and carries that
appearance through layout and drawing. Reparenting between differently themed roots gives the
subtree one change rather than an intermediate detach/attach pair; an explicitly themed child
does not follow its parent. `NSAppearance.currentDrawing()` and the scoped
`performAsCurrentDrawingAppearance` now match the production API shape, including nested
restoration. The render walk restores its previous `NSGraphicsContext.current` too. The shim's
application default remains Aqua: a native Linux system appearance preference is not connected
to the window yet, and the full dynamic `NSColor` catalogue is still absent.

The focused fixture links the unchanged production `ThemedBarSparklineView` and supplies only
the test theme's chart colour role. It checks inherited appearance callbacks, a protected
explicit child, reparenting, nested drawing-appearance restoration, the chart's group label,
and distinct light/dark pixels. Both Linux PNGs were inspected. Production project activity
provides exactly 12 weekly values, so the view's per-paint series walk is bounded; the fixture
uses seven values. The final focused Linux fixture passed after the appearance scope was moved
around layout as well as drawing.

The real macOS Component Gallery `design-system-components` capture passed. Its production
sparkline light and dark images were inspected in the gallery shell; they are new, unbaselined
artifacts in that report, so no baseline was accepted or regression match claimed. The Linux
per-file Design sweep reports 10 clean, 43 shim-clean and 107 shim-gap *candidates*.
`BrowserAnnotationChrome`, `ColorPairSpecimen`, `SplitButtonView`,
`ThemedBarSparklineView`, and `ThemedSurfaceView` moved from appearance-only candidates to
shim-clean. That is compilation classification, not proof that their containing screens run on
Linux or that Linux colours match the Mac theme palette.

The complete source-built X11 window suite passed after the final appearance-scope change,
including the Actions ninth-command path that had timed out in the preceding Debug run,
provider marks, workspace panes, saved terminal restart and live directory tracking. Its
present native window is still the diagnostic host; the production sparkline is verified in
the constrained shim fixture, not mounted in that installed window.

The final source built into a Swift-free Ubuntu Release `.deb` and passed the complete installed
X11 suite, including Actions, provider images, workspace panes, saved-terminal restart, live
reinstall and desktop launch. Fresh installed Actions and selected-provider PNGs were inspected.
The same package passed headless Wayland toplevel/buffer, two project frames and AT-SPI Actions
open/close; normal, alternate and open-Actions frames were inspected. The package SHA-256 is
`e38cdf10816aea8d5668f072aec88e2c8d9aac76437c722d32efd337c2507964`.
The theme-boundary, main-actor-latency, UI-structure and diff checks passed.

## 122. Retained named colours re-resolve in the Linux drawing appearance

The earlier appearance scope could redraw a view, but `NSColor` still stored only the RGBA value
from construction. A view or attributed run that retained a colour would therefore keep the
light ink after its parent switched to dark. The Linux shim now accepts production's
`NSColor(name:dynamicProvider:)` API, resolves named colours when their components are read for
painting, and preserves that behavior through `withAlphaComponent`. A nested appearance scope
restores the previous drawing appearance, and the scope is thread-local so concurrent renders
cannot overwrite each other's appearance. The shim keeps fixed colours value-equal; retained
dynamic recipes use stable identity equality and hashing rather than a hash that changes with
the active appearance.

A local AppKit probe measured the default-accent sRGB values of label, secondary label, tertiary
label, separator, accent and window background under Aqua and Dark Aqua. The Linux shim now uses
those values for this bounded semantic catalogue. AppKit also confirmed that an alpha variant
remains dynamic while `blended(withFraction:of:)` freezes when it is called; the shim follows
those timing semantics, though its blend arithmetic is still a simple sRGB interpolation and
does not reproduce AppKit's colour-managed numerical result. `usingColorSpace` returns a fixed
snapshot of the requested appearance. The OS appearance preference, user accent selection and
the rest of AppKit's semantic catalogue are not connected.

The focused Linux fixture retains one named colour and its alpha and blend variants across a
parent appearance switch. It checks the measured semantic components, fixed blend timing,
colour-space snapshot, stable hash, nested scope restoration and thread isolation, then renders
light and dark swatch PNGs. Both final PNGs were inspected: named and alpha swatches change from
red to blue, while the blend remains pink and system label ink changes dark to light. The
unchanged production sparkline fixture still passes. The per-file Design sweep remains 10 clean,
43 shim-clean and 107 shim-gap *candidates*: `NSColor.Name` drops from the gap list, but the
files using it still have other missing platform or app-owned members. These counts do not show
that a complete themed product screen compiles on Linux.

The complete source-built Debug X11 suite passed on this change, including the Actions
ninth-command path, provider artwork, workspace panes, saved-terminal restart, live directory
tracking and attach incarnation checks. The native diagnostic host still uses its own fixed
palette; this run is a regression check for that shipping path, while live light/dark colour
switching is currently proved only in the constrained shim fixture.

The final source built into a Swift-free Ubuntu Release `.deb` and passed the complete installed
non-root X11 suite: clean startup, workspace panes, Actions keyboard and AT-SPI behavior,
provider artwork, saved-terminal restart, live reinstall, desktop entry and directory tracking.
Fresh installed Actions and selected-provider PNGs were inspected. The same package passed
headless Wayland toplevel/buffer and two-project rendering plus AT-SPI Actions open/close; its
normal, alternate and open-Actions captures were inspected. Package SHA-256:
`82d3ee7961d27e716fc511b87285d05d6e9a5b37edb382af17bf8398fe4c68bb`.
The real macOS Component Gallery light/dark sparkline captures from the preceding appearance
pass were re-inspected as the product-shell reference; they are still unbaselined, so no visual
baseline acceptance is claimed. Theme-boundary, main-actor-latency, UI-structure and diff checks
passed.

## 123. View-tree queries preserve the native-plugin containment boundary

The Linux `NSView` tree had parent and child links but lacked AppKit's
`isDescendant(of:)` and `isHiddenOrHasHiddenAncestor` answers. A local AppKit probe confirmed
that descendant includes the receiver itself, while hidden state includes any hidden ancestor.
The shim now walks its retained parent chain for both queries and refuses to add a view beneath
itself or one of its descendants, preserving the tree invariant those queries require. Each
query is proportional only to view depth, not to the number of views in a list.

The focused Linux fixture links the unchanged production
`NativePluginPresentationBoundaryView`. It installs a presentation and a separate host sibling,
checks that only the presentation and its descendants receive the boundary's system-chrome
permission, verifies the four-edge layout, and confirms that moving a descendant into the host
sibling removes permission. A hidden presentation also hides its descendants without hiding the
host sibling. The fixture passed. The per-file Design sweep changed from 10 clean / 43
shim-clean / 107 candidate gaps to 10 clean / 44 shim-clean / 106 candidate gaps;
`NativePluginPresentationBoundaryView.swift` is now shim-clean. This proves the containment
component's behavior in a bounded tree, not native plugin loading or a full Linux theme audit.

The complete source-built Debug X11 suite passed after the view-tree change, including Actions,
provider marks, workspace panes, saved terminal restart and live directory tracking. The final
source also built into a Swift-free Ubuntu Release `.deb` and passed the complete installed
non-root X11 suite, including live reinstall and desktop launch. Fresh installed Actions and
selected-provider PNGs were inspected. That package passed headless Wayland toplevel/buffer,
two-project rendering and AT-SPI Actions open/close; normal, alternate and open-Actions frames
were inspected. Package SHA-256:
`d95437baab9a77b4a92f53d5c8b306cc37bfbce7a5df8e6ce7eb241207239146`.

## 124. A content window gives retained views their attachment lifecycle

The Linux tree now has a bounded `NSWindow` content owner. A content root and its descendants
answer `NSView.window`; they receive `viewWillMove(toWindow:)` and
`viewDidMoveToWindow()` when attached, removed, or moved directly between parents or windows.
`layoutIfNeeded()` lays out that root. The SDL host still owns the native window and its input,
decorations, focus and close events. This object does not claim those AppKit services.

A local macOS AppKit probe measured the ordering before implementation. Attaching a subtree
calls `will` from parent to child while the old window is visible, then `did` from child to
parent after the new window is visible. Direct reparenting within one window still issues one
callback pair with that window at both ends. Direct reparenting across windows issues one pair
without an intermediate nil window. Removing a subtree reverses the owner to nil with the same
preorder/postorder callbacks, and assigning the same content root twice is inert. The Linux
fixture checks those cases, including moving a root from one content owner to another; it passes.

The one-file Design sweep remains 10 clean / 44 shim-clean / 106 candidate gaps. Its former
generic `NSWindow` and `NSView.viewDidMoveToWindow`/`viewWillMove` gaps are now resolved into
specific members such as `NSWindow.makeFirstResponder`, `backingScaleFactor`, and window
notifications. `AgentWorkloadAnalyzerView.swift` is classified shim-clean, but its app-owned
types and Objective-C timer selectors are not thereby runnable on Linux. This classification
does not mean a complete product view tree can be mounted.

At this stage the native `WindowHarness` still constructed a new raster tree per frame. A live
retained production tree needed a host-owned lifetime before the content owner could represent
real attach and detach events there; mounting an ephemeral frame tree would have given callbacks
and timers a false lifetime. The focused fixture proved the view-tree rule, while the native
window suites remained regression evidence for the shipping preview path.

The complete source-built Debug X11 suite passed, including the lifecycle fixture, Actions,
provider marks, workspace panes, saved-terminal restart and live directory tracking. Its native
window capture was inspected. The final source built into a Swift-free Ubuntu Release `.deb` and
passed the full installed non-root X11 suite on retry, including live reinstall and desktop
launch. Fresh installed Actions, bundled-provider and absent-resource fallback captures were
inspected. The same package passed headless Wayland toplevel/buffer, two-project rendering and
AT-SPI Actions open/close; its normal, alternate and open-Actions frames were inspected. Package
SHA-256: `52ab8acd785dce1253a4ea442cef540e8575869457c330ef1aa8e8994e2aed28`.

One installed X11 attempt timed out waiting 15 seconds for the *second* provider-marks window,
which launches a copied binary without bundled artwork; the process was still alive and its log
was empty. That exact path passed on the next complete installed run. An intervening retry
could not install Ubuntu dependencies because DNS lookup failed and produced no UI result. The
first timeout's cause is unconfirmed; the successful rerun does not establish that startup is
free of intermittent delay. Theme-boundary, architecture-boundary and diff checks passed.

## 125. The native preview retains its shim view tree across frames

`WindowHarness.show` now attaches one `Specimen.Window` root to the Linux `NSWindow` content
owner for the SDL window's lifetime and detaches it before the SDL window closes. The owner
reports the preview raster's two device pixels per AppKit point through
`backingScaleFactor`. Native window input, focus, decorations and display migration still belong
to SDL; this does not turn the diagnostic host into the production Mac window.

The root keeps separate row and text layers. Dirty frames reconfigure and hide/reveal their
viewport slots instead of recreating the root and every visible `NSTextField` and row. The
existing viewport cap remains 32 choice rows and 98 text fragments, with the 32 KiB mounted
text budget; offscreen project and session values are not turned into views. This gives a future
production component a real host-owned attach lifetime and removes per-frame leaf construction
from the native navigator path. At this stage the rows were still diagnostic assembly, with
native SDL input routed outside the shim responder tree.

The first retained-root X11 capture revealed that the title disappeared after selection. The
old frame builder got the default title from a fresh root, then cleared it after putting the
text into a label; the retained root kept that cleared value. The host now states the default
at the start of each frame before a mode-specific title replaces it. A title-crop pixel check
was added to the native smoke after selection and resize. The broken capture had zero dark
pixels in that crop; the corrected capture had 584 and was visually inspected.

The per-file Design sweep remains 10 clean / 44 shim-clean / 106 candidate gaps.
`NSWindow.backingScaleFactor` no longer appears among them, but all seven files that used it
have other missing platform or app-owned dependencies. The sweep is still one-file compilation
classification, not a runnable product screen.

The complete Debug source-built X11 suite passed after the retained-root and title fixes,
including the new title-pixel assertion, Actions, provider marks, workspace panes,
saved-terminal restart and live directory tracking. Fresh native project and provider captures
were inspected. A subsequent focused Linux fixture passed a changed-height retained row with
the *same* icon child and a reused text-label slot; it caught and verified the icon-frame update.
The shared static specimen and unchanged production label fixtures passed as well.

The final source built into a Swift-free Ubuntu Release `.deb` and passed the complete installed
non-root X11 suite, including bundled and fallback provider artwork, Actions, live reinstall,
saved-terminal restart and desktop launch. Fresh installed Actions, provider and fallback images
were inspected. That package passed headless Wayland toplevel/buffer, two distinct project frames
and AT-SPI Actions open/close; normal, alternate and open-Actions frames were inspected. Package
SHA-256: `662d38fd314247bb388bace1fb4dcd7cf6fc07338cec21574d9ad6864b8bf5f9`.
Architecture, theme and diff gates passed. A complete production screen, shim responder routing,
system appearance and dynamic backing-scale migration remain unverified and unimplemented.

## 126. The retained window can own focus and a production shortcut scope

The content owner now implements the bounded first-responder lifecycle needed by controls:
`NSWindow.firstResponder` and `makeFirstResponder(_:)`, plus responder become/resign callbacks.
The window itself is the fallback responder. A view that refuses to resign keeps focus, while a
view that refuses to become first responder falls back to the window. Removing a focused subtree
or moving it to another window clears the source window's focus; reparenting inside the same
window preserves it. Direct focus requests can choose an attached view whose
`acceptsFirstResponder` is false, matching a local macOS AppKit probe. The probe also checked
same-window/cross-window reparenting and default key-equivalent traversal, including hidden
children. These are shim-owned focus rules, not SDL keyboard delivery.

The unchanged production `KeyEquivalentScopeView.swift` now links in the Linux text-label
fixture. That fixture proves a chord reaches the scope only when its own subtree has focus,
including a field editor represented by an `NSText` delegate. The `NSText` type is only a field
editor identity here; it does not implement text editing or IME. The fixture checks focus
transfer, vetoed resignation, failed becoming, same-window reparenting and detached/root-replaced
focus cleanup. It passed. The per-file sweep is now 11 clean / 44 shim-clean / 105 candidate
gaps; `KeyEquivalentScopeView.swift` is clean. These counts do not mean other production controls
are linked or runnable. At this stage SDL navigator input still routed outside the shim responder
tree, so native events did not invoke production key equivalents or controls.

The complete source-built Debug X11 suite passed with this `NSWindow` responder change,
including the production scope fixture, native keyboard/pointer selection, Actions,
accessibility, workspace panes, saved-terminal restart and directory tracking. Fresh workspace
navigator and saved-terminal picker captures were inspected. The theme, architecture,
main-actor-latency and diff gates passed. The installed Release package and Wayland path were
last verified for §125 before this focus change; this pass did not rebuild that package.

## 127. Native row presses enter the retained AppKit view tree

The SDL bridge still classifies a bounded row press, including an AT-SPI select, as a `TWEvent`
with window pixel coordinates. `WindowHarness` now converts that location to AppKit points,
hit-tests the retained `Specimen.Window`, and sends `mouseDown(with:)` to the hit view. A plain
child forwards an unhandled press to its parent, matching a local macOS AppKit probe. The
diagnostic row reports its viewport slot to the host, which keeps selection identity,
persistence, command admission and accessibility state. This replaces the host's separate row
rectangle search for project, saved-runtime, account and Actions rows; it does not create an
unbounded view per model item.

The shaped text layer paints over the rows but declines hits, so a label press reaches its row.
An icon child forwards to the same row, and hidden recycled slots cannot answer a press. The
focused Linux specimen fixture checks all three paths. The complete source-built Debug X11
suite passed with this press routing, including pointer selection, AT-SPI Actions, bounded saved
pickers, workspace focus, restart and directory tracking. Fresh Actions and navigator captures
were inspected. Theme, architecture, main-actor-latency and diff gates passed. At this stage
keyboard navigation, terminal gestures and the header Actions button remained native-owned;
production themed controls are not yet mounted or receiving these events. This pass did not rebuild the
installed Release package or rerun Wayland.

## 128. Navigator arrow keys follow the focused shim row

The SDL bridge used kinds 3/4 for both Up/Down keys and sidebar wheel turns. It now labels a
wheel turn with `action=1`, while an arrow key keeps `action=0`. The C bridge contract pushes
both native SDL events and checks the distinction. `WindowHarness` presents a key event with
AppKit virtual key codes 126/125 to the current first responder for arrow keys; the retained
diagnostic row reports a direction, and the host applies that direction to its existing bounded
selection state. `NSView.keyDown` forwards unhandled keys to its parent, matching a local macOS
AppKit probe. Wheel turns keep the existing native selection route, and terminal input stays
owned by its active pane.

Each dirty navigator frame assigns first responder to the selected mounted row for projects,
saved runtimes, accounts or Actions. Leaving the sidebar for a terminal clears that focus.
No model-sized focus objects are created: the selected view is one of the viewport row slots.
The focused Linux specimen verifies Down through window first responder, Up forwarded from an
icon child, and focus clearing after its slot is hidden. The full source-built Debug X11 suite
passed with this route, including keyboard selection, Actions, workspace focus isolation,
bounded pickers, restart and directory tracking. Fresh Actions and navigator captures were
inspected. Theme, architecture, main-actor-latency and diff gates passed.

The shim now exposes `NSEvent.keyCode` and `charactersIgnoringModifiers`; the one-file Design
sweep is 11 clean / 45 shim-clean / 104 candidate gaps. `ShortcutRecorderView.swift` is now
classified shim-clean, but that one-file check does not link or run its app-owned dependencies.
The preview still does not mount production themed controls, send text/IME events to AppKit
editors, or deliver general key equivalents. The installed Release package and Wayland path were
not rerun after this change.

## 129. Visible provider marks mount the production glyph view

The diagnostic navigator now mounts the unchanged production `GlyphView.swift` in its
viewport-bounded row slots. Its decoded provider artwork and the existing ground-resolved label
ink reach `TemplateImageDrawing` through the production view. The host still assembles its own
rows and has no Linux SF Symbol provider, theme selector, account badge or production sidebar
composition. A symbol request in this diagnostic host fails explicitly rather than silently
drawing an empty icon.

The first native capture exposed a layout error: `GlyphView` opts into Auto Layout, but the
diagnostic row gives it a measured fixed frame without constraints. The shim solved that view
and moved the image out of the row. The row now opts this instance into autoresizing-mask
translation, matching its fixed-frame ownership. A retained-row specimen checks that a real
layout/render walk preserves the frame and paints a tinted pixel in the 13pt icon slot. The
focused Linux text/row fixture passed. Fresh X11 captures of selected Claude and Codex rows were
inspected: both marks are visible, the selected template uses the selection ink, and the plain
Claude mark keeps its coral artwork. The native provider smoke passed bundled and absent-artwork
cases, including pixel and accessibility assertions. Theme, architecture, main-actor-latency
and diff gates passed. The full source-built X11 suite then passed end to end, including
catalogue, Actions, provider marks, workspace panes, terminal input, saved-runtime restart and
directory tracking. An earlier targeted Actions/provider/catalogue run passed provider marks
but timed out in the catalogue fixture's two-second title wait while the architecture gate ran
concurrently; that same catalogue case passed in the isolated full run. The installed Release
package and Wayland path were not rebuilt or rerun after this change.

## 130. Navigator clips use bounded device-pixel storage

The row renderer already limited fill scans to covered X coordinates, but every `addClip()` still
allocated a full-window `CGFloat` mask. Each visible navigator row clips its chrome and title,
so a small row inside a 1280×900 frame repeatedly reserved a mask for the whole window. The
shim now stores a clip's quantized alpha only within its transformed device-pixel bounds and
intersects that region with its parent before allocation. Raster fills, images, text and
transparency-layer composition read the same local coverage. Full-window clips still have their
full-window cost; visible-row clips now follow visible-row size. The unchanged raw-mask API
continues to serve the frozen raster oracle.

The standalone raster fixture was repaired for the newer production glyph and text sources. Its
eight pre-change RGBA/mask hashes matched the compact implementation exactly, and an optimized
comparison matched the frozen raster reference. Three `-Onone` process-CPU samples changed the
960×600/11-row median from 4,025.93 to 2,547.53 ms, and the 1280×900/17-row median from
9,916.03 to 5,253.77 ms. Parallel Docker work made wall time unsuitable for a native-latency
claim. These numbers exclude SDL, Pango, image presentation and installed Release performance;
the measured scope is the standalone renderer. The full source-built X11 suite then passed with
compact clips, including navigator selection, accessibility, Actions, provider marks, workspace
panes, saved-runtime restart and directory tracking. The observed Debug raster samples were
lower in several frames than the prior run, but host load and changed project imagery prevent
claiming a controlled native speedup.

The rebuilt Ubuntu Release archive and `.deb` passed the Swift-free installed-package suite,
including navigator, Actions, provider marks, live-child reinstall, saved-runtime restart and
desktop launch. The fresh installed project-list capture was inspected with compact clips.
The same installed `.deb` passed headless Wayland frame and AT-SPI Actions checks; the normal
project and open Actions captures were inspected.

## 131. Project rows show the production generated icon fallback

The Mac project row uses `GeneratedProjectIcon.image(for:)` when no stored icon exists. The Linux
diagnostic project list now calls that same production file only for mounted visible rows and
displays its 16pt tile through the existing production `GlyphView`. Provider marks retain their
13pt slot. A 256-entry `NSCache` count limit bounds the shared name-to-image fallback across
long scrolling; row views remain capped by the viewport. The diagnostic host supplies just the
two `ProjectIconDefaults` display constants, since the complete Mac icon discovery/storage
service is not yet part of the Linux host. Its own row assembly, selection, commands and AT-SPI
identity remain host-owned.

The shim added an HSB color initializer and a bounded 2× drawing-handler `NSImage` path for this
unchanged image factory. A retained-row fixture checks the 13pt provider and 16pt project mark
frames and nonempty pixels after layout. The focused Harness and native window builds passed.
A fresh 800×480 X11 project-list capture was inspected: Alpha and Beta show distinct colored
initial tiles in the correct slot without overlapping their titles. Native AppKit rendered the
same two production tiles at 2× for comparison. Their interior RGB fills matched exactly;
after compositing over the respective row grounds, 884/1024 Alpha and 887/1024 Beta pixels
matched byte-for-byte, with 950/1024 pixels within four RGB values for each tile. Differences
were concentrated in glyph and rounded-edge antialiasing. The full source-built X11 suite passed
with these tiles in its project rows. The focused macOS
`ProjectIconTests/testGeneratedIconIsDeterministicPerName` also passed after the cache bound.
The rebuilt Swift-free Ubuntu Release package passed its installed smoke suite, and its fresh
project-list capture was inspected: both generated tiles stay clear of their row titles and the
selection. The installed Wayland project capture also shows the generated tile beside its title.
The complete Mac project row, discovered artwork, theme and extension environment are still
absent from this Linux preview.

## 132. A production search-match label renders highlighted text

The Linux `NSTextField` shim now accepts bounded attributed style runs, single-line mode and
the label cell's last-visible-line truncation choice. Pango supplies font ascent/descent and
the needed wrapping modes. The unchanged production `SearchMatchLabel.swift` links in its own
focused fixture with only test theme vocabulary. That fixture checks a diacritic-insensitive
“Motión” match, highlighted run pixels, a visible tail ellipsis, the full accessible value,
and a pixel change when last-line truncation is enabled. Its PNG was inspected. The focused
search fixture, existing text-label fixture and native macOS AppKit typecheck passed. This
brings another production label onto the shim; live theme changes, editing, selection and IME
remain outside the proved behavior.

## 133. Project rows move collapsed counts into the trailing slot

The Mac `ProjectRowView` shows a collapsed-session count at the trailing edge only when it is
nonzero. The Linux diagnostic list previously appended both agent and terminal totals to the
visible title. It now keeps the project name in the shared `NavigatorRowGeometry.titleRect`,
reserves a bounded trailing digit slot for the sum, and omits that slot for zero. The complete
two-count summary remains in the AT-SPI row name. Only visible rows materialize count labels;
the 32-point title floor keeps a very large count from consuming the whole row at the minimum
window width. This is still a host-built diagnostic row, without Mac hover controls.

A focused native X11 fixture seeded one saved terminal for AlphaCount and none for BetaEmpty.
It found count ink only in Alpha's trailing slot before and after selection, checked both AT-SPI
names, and selected rows by keyboard and pointer. The two 800×480 product-window captures were
inspected: icon, title and count remain separated in selected and unselected states. The case is
now part of both source-built and installed-package smoke scripts. The full source-built X11
suite and rebuilt Swift-free Ubuntu Release installed-package suite passed with it. The fresh
installed captures of Alpha counted and Beta selected were inspected as well.

The rebuilt `.deb` also passed headless Wayland project-frame and AT-SPI Actions checks;
its fresh zero-count project row and open Actions captures were inspected. Physical Wayland
pointer, keyboard and IME input remain outside that headless check.

## 134. A production icon button runs on the Linux control and event shim

The unchanged production `ThemedControl`, `ThemedIconButton`, `PointerClaims`, `SurfaceDrawing`
and `GlyphView` now link in one focused Linux fixture. The shim added a cell-free `NSControl`,
tracking-area entry/exit, frontmost cursor-rect claims, a content-window event dispatcher,
ordered removable local event monitors, screen-coordinate conversion, and accessibility hit
behavior. The production button's release monitor is exercised after its view is detached: the
held action fires once on release and a second release does nothing. Dragging out cancels a
press; Space and accessibility press invoke the same action; a disabled button refuses them.
Five inspected PNGs show the glyph at rest, hover and pressed plates, keyboard focus outline,
and disabled ink. The focused fixture passed again after recursive cursor cleanup: its backdrop
re-registers its cursor in `resetCursorRects()`, so a layout invalidation cannot leave a stale
one-shot claim. The full source-built X11 and rebuilt installed-package suites passed. Native
row click and keyboard delivery now pass through the shim window dispatcher.

At this measurement the button was not mounted in the native shell. The Actions band still
consumed its own SDL gesture and emitted state/activation codes without the raw release
coordinates the button's monitor needs. The glyph boundary had no Linux symbol provider, and
the complete production theme graph was not mounted. The next slice below adds the visible
project-row control through those host bridges.

## 135. Visible project actions mount the production icon button in the native Linux shell

The app-mode project list now mounts the unchanged production `ThemedIconButton` as each visible
project row's trailing `⋯` control. The control uses the production 20-point inline target and
defers its symbol until reveal; the row keeps the shell mounted for accessibility and swaps its
collapsed count for the button on hover. Only the current viewport's at most 32 rows acquire
controls. The Linux diagnostic palette supplies the button's required ink roles, and a bounded
symbol provider supplies `ellipsis` and `plus`; another symbol name fails explicitly rather than
silently substituting artwork. Command availability, target identity, selection and durable
operation routing remain host-owned while the design component owns the button's surface,
gesture, glyph and accessible name. The labeled Actions header keeps its existing presentation
and route.

The shim window now delivers native pointer events through hit testing, tracking, local monitors
and weak press capture. Its cancel route clears a held press on focus loss or pane transition.
SDL kind 27 is an opt-in navigator-only motion/down/drag/up route; a terminal-owned press keeps
its terminal owner. AT-SPI publishes one bounded child action per mounted project row, with the
row's stable project ID and a generation-checked event. Shift+F10/Menu emits a semantic selected
project action event even without a session bus. A row action menu retains its exact project ID
without changing selection; a chosen project command resolves that ID before taking the existing
host operation path. The held press can drag into an Actions row and release through that same
command admission path.

The first real X11 capture exposed a shim layout bug: `LayoutEngine.rootAbsolute` used the
ancestor row's size for a fixed-frame child, leaving the button's glyph below and left of its
surface. It now retains the child's own size while accumulating ancestor offsets. A nested
20×20 button/12×12 centred glyph regression, the production icon fixture and generic layout
suite pass. The recaptured real-shell normal, row-hover, button-hover and open-menu images were
inspected; the ellipsis is centred inside the trailing 40-pixel target. The strict C fixture
passes with and without a session bus, covering pointer ownership, terminal isolation,
accessibility identity and stale queued actions. The focused native X11 fixture passes hover,
pointer, AT-SPI, keyboard, preserved selection and header interactions. A second daemon-backed
X11 fixture passed a held press from Beta's `⋯` through drag and release on `Open shell`:
Alpha stayed selected while the menu opened, then the operation selected Beta and opened
Beta's terminal through the normal command path. A separate counted-row X11 fixture passed
after neutralizing Xvfb's inherited pointer position before launch: its inspected baseline
shows Alpha's trailing `1`, and the hover capture shows that digit replaced by the centered
ellipsis while Beta remains blank. The AT-SPI total stays unchanged across the hover. The full
source-built `window-smoke.sh` suite passed with both cases and the strict C bus/no-bus contract
included. The rebuilt Release arm64 `.deb` passed `bundle-smoke.sh` against the installed,
Swift-free Ubuntu runtime, including the project action and count-hover fixtures. Its installed
hover captures were inspected: the ellipsis is centered and replaces the count on hover.
`tests/wayland_smoke.sh --actions` then passed against the same rebuilt package under headless
Weston, including two distinct 800×480 project frames, buffer commits, the AT-SPI header and
project-row Actions activation, and changed menu pixels. Converted Weston captures of the
normal project shell and open menu were inspected. Headless Weston verifies rendering and
accessibility. Section 137 adds compositor-originated pointer and keyboard coverage for the
header Actions route; other Wayland gestures, project-row right-click, IME, and the full
production theme and extension UI graph remain outside this slice.

## 136. Add Project mounts the production header control and its host-owned menu

The app-mode navigator mounts one retained, unchanged production `ThemedIconButton` with the
`plus` symbol in its header. It takes the Mac sidebar's inline 20-point target and diagnostic
chrome ink. The title's bounded text run stops before that target, and Actions remains a
separate hit region. The Mac control presents a menu on mouse-down, so the Linux control now
sets `presentsMenu` and opens a bounded three-entry menu on press: **Start New Project…**,
**Use an Existing Folder…**, a separator, then **New Scratchpad**. The separator sits outside
all actionable row bounds; the accessible list contains only the three commands. The menu
and command admission are host-owned; the production control owns its glyph, hover, press,
focus and accessibility behavior.

The bridge publishes a frame-level AT-SPI push button named `Add Project`, accessible ID
`linux.add-project`, with the same 40×40 window-pixel bounds as the rendered target. Its
generation-checked kind-30 event opens the menu. The menu's AT-SPI list is `Add Project` and
its stable command IDs are `project.new`, `project.add`, and `project.scratchpad`. The existing
Ctrl+Shift+P shortcut still runs the existing-folder command directly. Both project choices
use a worker-owned Zenity platform dialog: the existing-folder chooser adopts a directory,
while a save-style name-and-place chooser creates or adopts a directory and sends it to the
locked LinuxHost `--add-project` operation. Cancellation creates no folder. Scratchpad needs
no chooser: LinuxHost `--ensure-scratchpad` lazily creates `~/Threading/Scratchpad`, adopts a
same-path project or preserves an existing flagged row's ID, and stores `Project.isScratchpad`.
Git init and seeded README/.gitignore are best effort and never overwrite user files. The
scratchpad is pinned before ordinary projects in the bounded navigator projection. The worker
reads the host's exact returned path with a 4096-byte bound before selecting the new row;
host refusal stays visible. A pending operation disables the `+` control until it finishes.

The focused native X11 fixture passed against rebuilt WindowHarness/LinuxHost. It checked
the `+` glyph's normal and hover pixels, all three pointer/AT-SPI menu rows and their IDs,
Escape, AT-SPI and Ctrl+Shift+P existing-folder chooser cancellation, and a cancelled New
Project save. A completed save created and selected the chosen directory. Scratchpad created
the folder without a chooser, persisted its flag, appeared first in the navigator, and kept
the same project ID and a user-edited README on a second press. Its fresh 800×480 menu capture
was inspected: the plus remains clear of Actions and a visible rule separates Scratchpad from
the folder choices. Full source, installed-package and Wayland reruns for this revision are
pending. The full Mac theme engine, extension UI graph, Scratchpad settings relocation, and
richer themed menu presentation remain outside this diagnostic shell.

## 137. Headless Weston injects real Wayland pointer and keyboard events

`tests/wayland_input_module.c` is a test-only Weston 13 module. It creates a compositor seat and
accepts bounded move/button/key commands over a local datagram socket. For the 800×480 installed
window, it reports the mapped content-view origin; the Python fixture adds that origin to
window-relative AT-SPI button bounds before moving the seat pointer. This closes a false
assumption exposed by the first failed attempt: Wayland AT-SPI screen extents matched window
coordinates, while Weston had placed the window at (106, 44). The corrected run sent a real
`wl_pointer.button` pair to the installed SDL client, opened and closed Actions, pressed the
production header `+`, and found the three Add Project command IDs through AT-SPI. A pointer
press on the production project-row `⋯` and a right press on the row each opened the exact
project Actions menu. It then sent Shift+F10 as `wl_keyboard.key` events and reopened Actions
through the native keyboard route. A held press on the project-row `⋯` then entered the menu,
highlighted `Open shell` under drag and opened the terminal on release. The client protocol
trace contains both event types, and the AT-SPI menu state changed after each action.
`tests/wayland_smoke.sh --actions` passed against the
rebuilt `.deb` with this lane and the existing render and AT-SPI lanes. This proves
compositor-injected pointer and keyboard delivery for those specific commands under headless
Weston; physical devices, other drag gestures, broader shortcut behavior, and IME remain
unverified on Wayland. The final installed captures are under `out/wayland-smoke.Qh2ECGRc/`;
the Actions capture was inspected after conversion to PNG.

The project-row right press resolves the visible row's durable ID without changing selection.
The source and installed two-workspace fixture exposed a focus edge: opening that menu from a
terminal must remember the prior focus owner. Escape now restores the active terminal, and the
fixture proves the next byte reaches its original PTY rather than the menu or another project.

## 138. The Add Project menu creates folders and a durable Scratchpad

The Mac header `+` actually offers three entries: Start New Project, Use an Existing Folder,
and New Scratchpad below a separator. The Linux `+` now uses the unchanged production
`ThemedIconButton.presentsMenu` gesture, opening its bounded navigator menu on press. The
same three stable command IDs feed the host command gate. AT-SPI exposes the `Add Project`
button and three actionable menu rows; the decorative separator has no action. Ctrl+Shift+P
retains its direct existing-folder meaning. The first focused X11 run caught a root cause in
the menu refresh: it replaced the new menu's three descriptors with the general Actions
catalogue before the first frame. Refresh now branches by presentation kind, preserving each
menu's membership.

The Linux host's `--ensure-scratchpad` command is the durable path. A user click sends it on
a worker, away from SDL's owning thread. It lazily creates `~/Threading/Scratchpad`, scans the
project index once, preserves an existing scratchpad row's ID, adopts a same-path ordinary row,
or inserts one flagged `Project.isScratchpad`. The production and vendored
`ProjectNavigationEntry` both carry that stored flag, so the navigator pins Scratchpad before
other projects without deriving identity from its path. README and `.gitignore` seed only when
absent; Git init and first commit are best effort with a bounded process deadline. The `.deb`
declares Git as a dependency: the Swift-free Ubuntu package fixture caught that without Git,
repository provisioning returns before seed creation. The host
prints its canonical selected path, which the worker reads under 4096 bytes rather than
reconstructing a path from another source. Any refusal is surfaced through
`PROJECT_IMPORT_REFUSED`; no candidate row is painted as imported until the snapshot reloads.
The explicit command performs one index read and one row write at most; the pointer path
remains O(visible) and no project-wide work enters motion/hover callbacks.

The focused source X11 fixture passed after rebuilding WindowHarness and LinuxHost. It
exercised pointer and AT-SPI menu opening, exact row IDs/names, Escape, a cancelled save,
existing-folder chooser cancellation through AT-SPI and Ctrl+Shift+P, an actual New Project
folder creation/import, and Scratchpad creation, pinning, repeated ID, and preservation of an
edited README. I inspected its 800×480 menu capture: the three choices and separating rule
are visible, and the `+` and Actions targets do not overlap. `vendor-core.sh --verify` passed
with all 47 vendored files byte-identical after adding the scratchpad projection to both
production and CoreSlice. The final installed Ubuntu `.deb` suite passes New Project creation,
Scratchpad seeding and repeated identity under a non-root user; its real shell menu and hover
captures were inspected. The final `tests/wayland_smoke.sh --actions` run passes the installed
menu's AT-SPI and physical pointer routes. The complete source agent smoke also passes. Its
first attempt reached the new menu and right-click fixtures, then hit an isolated three-second
`xdotool` typing timeout in the existing agent attachment fixture; the unchanged fixture passed
on rerun along with the named agent cases. The Mac Scratchpad settings relocation and richer
themed menu surface remain outside this diagnostic shell.

## 139. Classic floating glyphs draw through a bounded AppKit graphics path

`ThemedFloatingGlyphView` is the production Design component that gives floating cards and
popovers semantic folder, branch, handoff, status, changes, model, plan, speed and workspace
marks under period themes. Its classic branch calls `NSGraphicsContext.cgContext` for paths,
line and fill ink, rectangle primitives and antialias control. The Linux shim previously had
only alpha and transparency calls on that bridge, so the unchanged view could not compile or
draw. The shim now stores a bounded 4096-element current path, preserves open versus closed
subpaths, consumes that path on stroke or fill, and keeps it separate from saved graphics state
as CoreGraphics does. Saved state restores line width, ink and antialiasing. `NSColor.cgColor`
captures an appearance-resolved color for these drawing commands. The existing rasterizer now
uses one center sample with binary horizontal coverage when antialiasing is disabled; its
ordinary antialiased path remains the default.

`tests/floating_glyph` links the exact production view and `TemplateImageDrawing` by symlink,
supplying only the small theme environment needed by the component. Its Linux fixture passed
all nine distinct classic marks, the system-template branch, intrinsic size, decorative
accessibility, slot containment, path consumption, open-path behavior and graphics-state
restoration. Fresh folder, branch, speed, model, plan, workspace and system PNGs were visually
inspected. The frozen raster comparison passed exact byte equality for all eight existing
frames and masks after adapting only the reference test's call signatures to the optional
antialias argument. `git diff --check`, shell syntax and Python syntax checks passed. This
proves a production drawing leaf under the shim; the native Linux window has not mounted it,
and Mac/Linux glyph pixel parity, the full theme graph and popover hosting are unverified.

## 140. Project rows show the production `+` and `⋯` pair in the Linux navigator

The Mac `ProjectRowView` keeps a `+` beside its `⋯` in a 20-point target, a 2-point gap,
and another 20-point target. The Linux diagnostic navigator now mounts a second unchanged
production `ThemedIconButton` in each visible project row with the Mac control's `plus`
symbol, `New chat or terminal` name, deferred glyph, inline target and menu-on-press gesture.
The retained row positions the two controls at fixed 40-pixel targets, with the `+` left of
the existing `⋯`. Its collapsed-session count yields to both controls on hover. The title
reserves the pair's width only while revealed. At most the 32 visible row slots acquire
buttons; pointer movement uses arithmetic row hit testing and does not scan stored projects.

The native AT-SPI row publishes both children in visual order, with stable
`sidebar.project.create.<project ID>` and `sidebar.project.actions.<project ID>` identities.
The create action enqueues a generation-checked kind-33 event carrying the visible slot;
the C bridge reads the current row's exact ID at dequeue, and the Swift host checks it
against the live project before presenting host-owned choices. Replacement retires both
children and invalidates queued actions. The strict C pointer/AT-SPI fixture passed with
and without a session bus, including both controls' bounds, hit testing, exact IDs and
stale-action refusal. The focused source X11 `project_actions_smoke.py` passed after building
WindowHarness and LinuxHost. Its inspected 800×480 row-hover capture shows the two centred
glyphs beside the selected project. The separate `project_count_smoke.py` passed and its
initial and hover captures were inspected: Alpha's `1` becomes the `+`/`⋯` pair, while the
zero-count Beta row remains blank until hovered. Both tests retain selection, Actions,
keyboard and terminal checks.

These are the existing host-owned row controls within the public project-row presentation
contract; project identity, command admission, selection, accessibility and the native
fallback remain host-owned. This slice mounts the control pair in the diagnostic shell,
not the complete `ProjectRowView` with morphing labels, discovered icon artwork, hover card,
theme state and extension replacement. The full menu behavior and installed package are
verified separately after the row control route is integrated.

## 141. Project-row creation routes through the exact project in the Linux host

The row `+` now opens a three-choice host menu with the Mac labels `New Chat…`,
`New Manager…` and `New Terminal`. It keeps the visible row's durable project ID, even when
another row is selected. Each command is rechecked through `HostCommandPlane` immediately
before use. `New Terminal` enters the existing persistent terminal creation path for that
project. `New Chat…` opens a bounded two-provider choice using the existing Codex and Claude
session commands; Escape returns to the parent menu one layer at a time. The Linux shell has
no composer yet, so this provider choice is its current path to starting a chat.
`New Manager…` remains visible but disabled with an accessible reason because the manager
runtime is not implemented here. A menu opened while a terminal owns focus remembers that
owner for dismissal. Held press, drag and release uses the same exact-target command gate.

The dedicated source X11 `project_create_menu_smoke.py` passed: AT-SPI and pointer both
opened Beta's menu while Alpha stayed selected, the disabled Manager was described, Chat
opened the Codex/Claude choice and Escape stepped back, and New Terminal selected Beta and
mounted its terminal. I inspected the rendered 800×480 menu capture at
`out/project-create-menu/project-create-menu.png`; all three rows are legible. The complete
`THREADING_LINUX_AGENT_ONLY=1 ./window-smoke.sh` source suite passed with the new fixture.
The rebuilt Ubuntu 24.04 arm64 `.deb` passed its full non-root installed runtime suite,
including the same project-create fixture and desktop-entry launch. I inspected its
installed 800×480 menu capture; all three rows are readable and Manager is visibly
unavailable. `tests/wayland_smoke.sh --actions` passed against that package under headless
Weston: AT-SPI exposes and invokes the row Create target, and compositor-injected pointer
input opens the exact-row menu. The Wayland Actions capture was also inspected. Physical
devices and other desktop sessions remain unverified. Theme-boundary, main-actor-latency,
vendored-core, Python/shell syntax and `git diff --check` gates passed.

## 142. Single-gravity stack replacement supports production subagent composition

The unchanged `SubagentNavigatorRowView` and `SubagentSummaryView` install their heading,
detail and pager stacks with `NSStackView.setViews(_:in:)`. The Linux stack previously had
only incremental arranged-view insertion, so the navigator row's one-file Design sweep named
`NSStackView.setViews` as a platform gap. The shim now accepts the production-used `.leading`
and `.top` single-gravity arrangements. One call replaces the arranged views and ordinary
subviews in order, keeps shared views, and rebuilds layout constraints once. Later
`addArrangedSubview` calls, such as the summary card's pager, stay in that gravity area.

The first Linux fixture exposed a constraint-lifecycle bug: after replacing a 20-point child
with a 40-point child, the stack kept its old 55-point width instead of fitting 75 points.
The old arrangement constraints were being deactivated after detachment, when their owning
container could no longer be found. Replacement now retires them before detaching views,
removes other constraints tied to discarded children, and preserves each removed child's own
width and height constraints on that child. This keeps repeated replacement from accumulating
stale stack equations. The shared stack fixture passed against macOS AppKit and the final
Linux shim, covering order, measured widths and positions, hidden-view collapse, removal,
later addition, and retained size constraints. The production `ControlRow` fixture passed in
both runs as well.

A Mac probe showed that separate leading, center and trailing gravity areas occupy different
positions in a fixed-width stack. The shim explicitly refuses those unimplemented combinations
and center/trailing/bottom placement; the mounted production call sites use one `.leading` or
`.top` area per stack. The fresh one-file Design sweep reports 13 clean, 53 shim-clean and 94
candidate shim-gap files. `SubagentNavigatorRowView.swift` no longer lists the stack method;
its remaining candidate is the app-owned `NSTextField.applyFont` extension. The complete
subagent card is not yet linked or mounted in the native Linux window, and the sweep does not
prove its app-owned dependency graph or visual parity.

## 143. Width-aware labels and constraint fitting close two layout shim gaps

Production alerts, status strips and summary views set `NSTextField.preferredMaxLayoutWidth`
to let a wrapping label's intrinsic height follow its actual pane width. The Linux label
previously always measured its natural unwrapped width, even though its draw path could wrap.
The Pango bridge now measures at a bounded positive preferred width, for both plain and
attributed runs, respecting word/character wrapping and the existing eight-line/128-pixel
limit. Clearing the preference restores natural measurement; changing it invalidates the
cached metrics. A macOS AppKit probe of a 13-point wrapping label measured 514×16 naturally,
194×48 at preferred width 200, and 100×96 at width 100. The Linux text-label fixture now
checks those directional size changes, reset, attributed text and line-limit behavior. Its
complete production-label suite passed in Ubuntu arm64.

`NSView.fittingSize` now solves the view's constraint subtree with AppKit's 50-priority
zero-size proposal. It measures without changing live frames and retains a separate warm
start from normal window layout. A Mac and Linux shared fixture measures a constrained
80×30 child with 10/12 horizontal and 5/7 vertical insets as 102×42, then changes the child
width and confirms a new fit without disturbing the 200×100 live root. The same fixture
exposed a deeper `NSStackView` difference: Mac top/leading gravity leaves spare space after
fixed rows, while a flexible spring consumes it. The shim now keeps top-gravity rows compact
and admits explicit unconstrained vertical spacers to fill. The Mac and Linux stack fixtures
pass fixed-child, spring, constraint-replacement and unchanged production `ControlRow` cases.

These are layout primitives for production components; they do not by themselves mount a
new pane in the installed Linux shell. The label retains the shim's bounded eight-line text
path, and a full Mac/Linux text-layout pixel comparison remains outstanding.

## 144. Production subagent navigator row compiles and renders in a focused Linux fixture

`tests/subagent_row/` links the unchanged production `SubagentNavigatorRowView`,
`ThemedControl`, `ThemedIconButton`, pointer claims and drawing leaves. Its item-model
prelude is a byte-exact copy of the first 131 lines of `SubagentSummaryView.swift`, checked
on every fixture run. A fixed-palette, app-owned adapter supplies the production row's
font, status, selection, localization and folder-symbol roles. The adapter retains the
quiet-selection contrast rule and the role-specific 11/12-point font decisions; it is not
the full live Mac theme engine. The production row itself has no source edits.

The first Mac/Linux captures uncovered a real stack-layout gap: when a row was taller than
its visible lines, the shim's `.top` stack stretched its heading down to fill the spare
height. With fewer visible lines the error grew to 40 points. The Mac row kept its heading
at the top and left the spare height below the content. The Linux stack now constrains the
last visible child within the bottom edge without requiring it to touch that edge for
`.top` gravity. A row-render assertion holds the title within 12 points of the row top.

`./tests/subagent_row/run.sh --mac` and `./tests/subagent_row/run.sh` pass. Both render
selected, unavailable and pending rows, then move the selection. The fixture checks row
accessibility names, selected values and unavailable help, exact metadata/task/activity
labels, disabled presses, selection callbacks and the file-backed folder action. I
inspected the 376×350 Mac and Linux PNGs. After the stack correction their selected title
positions differ by one pixel (global minimum Y 316 on Mac, 315 on Linux); metadata,
task and activity vertical positions match exactly in this fixture. The moved selection
plate appears on the third row in both renders. The Linux shim's `setAccessibilityHelp`
now preserves the row's explanation for an unavailable transcript.

This proves the row in one fixed palette and bounded fixture, not the complete
`SubagentSummaryView` card, live theme changes, plugin composition or a mounted Subagents
pane in the installed Linux shell. The fixture's folder glyph is diagnostic artwork; a
general Linux symbol service remains a separate dependency for wider Design components.

## 145. Image interpolation and source-rectangle drawing preserve production choices

The image shim's earlier `draw(in:)` leaf always used bilinear sampling. Production image
surfaces request `.high` for photos, screenshots and attachments, while the legacy window
chrome requests `.none` when cutting exact pixel plates from a sprite sheet. The same calls
also use `.copy` to replace old chrome pixels, including transparent ones. The shim now has
AppKit's `NSImageInterpolation` raw values, `NSImageRep.HintKey.interpolation`, a saved
`NSGraphicsContext.imageInterpolation` state, and the full `NSImage.draw(in:from:operation:
fraction:respectFlipped:hints:)` route. A per-draw hint overrides the context setting without
leaking to the next draw. `.none` uses nearest source pixels; `.high` uses bounded premultiplied
cubic sampling when enlarged and a bounded area sampler when reduced. `.copy` replaces the
destination's alpha as well as its color; `.zero` source means the whole image. Drawing loops
only over the destination intersected with the output bitmap, with no image-sized intermediate.

The focused `tests/image_shim/run.py` compiled the actual shim as a macOS module, rendered
the same cases through real AppKit, and compared sampled outputs. Nearest, source crop,
transparent half-opacity copy and hint precedence matched exactly. Enlarged high-quality
samples differed by at most 18/255 per channel. AppKit's high downsampling of an 8×8
checker returned 165 gray, while the shim's bounded area filter returned 128; both avoid a
nearest-neighbor checker pattern, but the filters are not pixel-identical. PNGs in
`out/image-interpolation/` were inspected. The same actual shim and image contracts passed in
the pinned Ubuntu arm64 Swift container via `tests/image_shim/run_linux.sh`; the older
template-alpha, clipping, bounded transparency tile and thread-isolation contracts passed
in both environments.

A current Linux AppKit module build and focused one-file typecheck of seven production
Design image/chrome files no longer reported `NSImageInterpolation`, the hinted draw method,
or `NSGraphicsContext.imageInterpolation` as platform gaps. `AnnotatedImageView` and
`ThemedImagePreview` now have only their app-owned sibling dependencies in that isolated
check. Other surfaces still need independent platform leaves: `GeneratedAppIcon` asks for
`NSBitmapImageRep` and `NSShadow`; `ImageCompareView` asks for `NSCompositingOperation` and
`NSImage.representations` plus app/window/event APIs; the window chrome asks for gradients,
shadows and window notifications. This fixture proves image drawing behavior, not complete
product-image surface mounting or high-quality pixel identity on every scale and color space.

## 146. Final installed package keeps the native shell working after the shim changes

After the text, fitting-size, stack and image revisions, `./bundle-smoke.sh` rebuilt the
Ubuntu 24.04 arm64 package from the final sources and passed its complete non-root installed
suite: clean-profile launch, daemon reattach and reinstall, project-row actions/create menus,
provider marks, bounded catalogue, saved terminals and desktop-entry launch. The resulting
`.deb` has SHA-256
`efa53b44f86d222dfa06b933b91c64137fc9a10f93858f97a8e9b2bfd400dd29`.
`tests/wayland_smoke.sh --actions` passed against that package: native buffer commits,
AT-SPI Add Project/Create/Actions targets, compositor-originated row/menu pointer input,
right-click, Shift+F10 and drag release. I inspected the final installed X11 project-row
hover and create-menu captures and the final Weston Actions capture. The final Mac and Linux
subagent-row fixtures also passed; their rendered captures were inspected.

A fresh `./sweep.sh` classifies the 160 one-file Design checks as 13 clean, 55 shim-clean and
92 candidate gap files, versus 13/53/94 before this slice. `AnnotatedImageView` is now
shim-clean, as is `ImageAnnotationRailView` with respect to its old `fittingSize` candidate;
the latter still needs `NSTextFieldDelegate`. The leading reported member is
`NSTextField.applyFont` in 42 files, but that is an app-owned extension omitted from this
one-file sweep, not evidence that AppKit itself owes the method. Other genuine missing
platform groups include editable text, tables, accessibility notifications, animation,
window and image services. The native shell still assembles its own rows and fixed palette;
this installed pass does not establish a complete production screen or desktop-wide parity.

## 147. The native shell mounts the production pane header

The retained native window now mounts unchanged production `PaneHeaderView`, `OpticalInsets`,
`PaneFooterView` vocabulary and `ThemedIconButton` controls. `SeparatorView` was extracted from
`ThemedIndicators.swift` without changing its source, and both DesignKit and Linux link that
same file. The header replaces the diagnostic title's independent band geometry and manually
painted labeled Actions plate. The default band is 41 points: the 28-point control row, six
points above and below, and its one-point separator. The title yields before either 20-point
control. Native input and AT-SPI receive the controls' actual laid-out frames; at 800 pixels
wide, Add Project is `(692,20,40,40)` and Actions is `(744,20,40,40)`. In the 320-pixel sidebar
they move to X212 and X264. The list begins at Y82 and its first row at Y86. Titles now name
the active section without filling the header with keyboard instructions.

The shim adds cached `NSView.LayoutRegion` recipes and guide/rect/inset queries. Its safe areas
and margins currently have zero insets: SDL/libdecor decorations sit outside the retained
content tree. This is an explicit Linux content policy, not macOS's default 20-point margins
or corner/window-control clearance. The Harness covers six recipes, 100 repeated queries,
flipped and unflipped resizing, 20 cross-window reparents and detached resizing without
accumulating guides or constraints. Each recipe retains one guide and four constraints.

`tests/pane_header/run.sh` and `--mac` pass. Their wide/narrow/wide captures have identical
header and action-control frames; the title has platform font measurement/frame-padding
variation. The fixture checks compression, optical margins, centerlines, retained constraints,
separator pixels, selected and disabled states, and accessibility activation. The shipping
Mac `PaneHeaderTests`, `PaneFooterTests` and `PaneHeaderRenderTests` pass 26 tests. I inspected
all nine product renders (System, Cyberpunk, Swiss, Bauhaus and Classic Player) and the Linux
wide/narrow, selected, disabled, project-hover, create-menu and odd-resize captures.

Native X11 Actions, Add Project, project actions/create, counts and provider-mark contracts
pass. The fixtures now locate controls/rows from their accessibility bounds, and project-import
checks wait for the actual accessible row/control rather than treating the earlier import log
as a completed UI publication. The Release AT-SPI lane passes exact navigator/terminal bounds,
Unicode text and character geometry, odd sizes, 1280×600 resizing, independent focus, and native
input. A Debug run under competing builds exceeded its 12-second resize wait; the unchanged
shipping Release fixture passed. This is not a claim that Debug rendering meets latency goals.

Customization gate: the preview header remains host-only. Threading retains project/runtime
identity, command admission, import and PTY ownership. This slice adds no extension authority
or replacement API. Scaling gate: one header, one title and two controls are retained per
window; resizing/pointer events touch that fixed tree and the existing visible row slots.
The production theme engine, complete navigator cells and floating menu presentation remain
unmounted; the shell still uses its bounded diagnostic rows and fixed palette.

The final `./bundle-smoke.sh` rebuild passes the complete installed non-root Ubuntu suite,
including clean-profile import, live-child reinstall, simultaneous panes, command admission,
project menus, glyphs/counts, saved-terminal restart/catalogues/directories and desktop entry.
The `.deb` SHA-256 is
`8d79b00be464208b58ae2bcb5294c0be26327a7bf163894c2e34fe8ad5fcc30e`.
`tests/wayland_smoke.sh --actions` passes on that package: native toplevel/buffer commits,
Add/Create/Actions accessibility, compositor-owned header and row pointer input, right-click,
Shift+F10 and drag release. The fresh installed Weston Actions capture was inspected. Moving
resized X11 fixture windows onto the display corrected clipped evidence; the final Release
AT-SPI/workspace runs pass and produce complete 1280×600 and 1280×528 captures, both inspected.
Theme boundaries, source links, exact separator extraction, runner contracts and diff checks pass.

## 148. The native command list mounts production menu rows

`ThemedMenuItem`, `ThemedMenuMetrics` and `ThemedMenuRowView` are now in separate production
Design files, linked into both DesignKit and the Linux window. The Mac presenter and Linux host
use the same `ThemedMenuRowPlan` to calculate column reservations and run heights once. The
Linux host mounts only the visible page of real menu rows below its retained production pane
header. Its fixed palette roles stay in a host adapter; the AppKit shim supplies view tracking,
accessibility, font descriptors and text raster state rather than theme policy.

Command identity, availability, persistence and PTY admission remain host-owned. The native
AT-SPI list publishes each mounted row's actual laid-out bounds; pointer hit tests and the
press/drag/release path use those bounds too. At 800×480, seven 28-point rows fit below the
41-point header, so the ninth command is reached by the existing bounded keyboard scroll.
The Actions smoke now navigates to an offscreen identity before inspecting it, and the host
routes menu Up/Down independently of the diagnostic project row's first-responder callback.

The focused Linux Harness menu-leaf tests pass, including overlapping tracking areas and
whole-pixel indexed Pango text. Native X11 project-action and Actions smokes pass pointer,
keyboard, AT-SPI, disabled admission and exact terminal ownership. I inspected the installed
native menu capture: the selected fill, title alignment and disabled rows are visible in the real
shell. On Mac, the focused menu suite passes 19 tests; System light/dark, Cyberpunk and Swiss
renders were inspected, and the source extraction plus the Linux Release compile fix left
those renders byte-identical. The diagnostic Pango renderer still maps requested families to
DejaVu proportional or mono; arbitrary installed font matching is not established here.

Customization gate: this preview menu remains host-only. Its rows have presentation and local
interaction behavior, while Threading retains command identity, admission, launch and
accessibility publication. Scaling gate: the command catalogue is bounded, the column plan is
computed once per dirty frame, and only viewport rows are constructed; pointer movement does
not scan persisted projects or sessions. The full floating `ThemedMenuPresenter`, production
theme engine and complete navigator cells remain outside this preview slice.

The final `./bundle-smoke.sh` rebuilt the Ubuntu arm64 `.deb` from these sources and passed
the complete non-root installed suite: clean launch, live-child reinstall, workspace,
Actions/Create/Add menus, provider marks, counts, saved terminal restart and catalogue,
directory identity and desktop entry. The package SHA-256 is
`e44f9e60c176454c0cb3179a538d8d2ed6250cc08360d9469a332721f9fd38`.
`tests/wayland_smoke.sh --actions` passed on that package under headless Weston, including
native buffer commits, AT-SPI Add/Create/Actions, compositor pointer input, right-click,
Shift+F10 and drag release. I inspected the installed X11 Actions and Create captures and
the final Wayland Actions capture. The shell remains a diagnostic preview rather than a full
production Linux UI.

## 149. Visible project rows share the production native subtree

`ThemedProjectRowView` now owns the icon, shaped title, optional checkout path, collapsed count
and trailing `+`/`⋯` controls for both the Mac `ProjectRowView` and Linux's visible project
slots. The existing `NavigatorProjectRowPresentation` supplies the title role. The production
`SidebarRowDefaults` moved verbatim into Design, linked into DesignKit and Linux, so the row's
gutter and control geometry have one source. Mac keeps its table cell, title morph,
customization container, hover card and project model adapter around that shared subtree.
Linux keeps `ProjectSnapshot` identity, selection, AT-SPI list publication, command validation
and PTY ownership around it. The Linux project list no longer lays out a separate project
title, mark, count or control pair in its diagnostic text layer.

The AppKit shim now clips each rendered view to its own bounds, including nested flipped views,
and honors ordered subview insertion so count ink stays behind the hover controls. It carries
the image-view symbol configuration requested by production and a monospaced-digit font leaf;
the host supplies a fixed-palette typography adapter. A focused Linux bitmap fixture checks
nested bounds, explicit clips, flipped coordinates, sibling restoration, ordering and hit tests.
Only visible project slots retain native content. Generated icons keep their bounded cache;
pointer and selection changes reconfigure the retained slots without scanning the project
catalogue or building hidden rows.

Mounting a count exposed a conflicting intrinsic-width rule: the label was pinned across a
38-point slot while its hugging and compression priorities both required its natural width.
The Linux layout solve then failed, leaving the pane header at its old 800-pixel width after a
terminal narrowed the sidebar to 320 pixels. The count now yields to the slot, and the packaged
layout fixture checks a retained row and header through 800/320/800-pixel resizes. The shared
buttons also publish hover-state changes to the host's existing dirty-frame signal, so moving
from a revealed row into `+` or `⋯` repaints the control without replacing the row.
The text shim now measures intrinsic width and baselines at the attached window's backing scale,
matching its Pango raster scale so a wide row does not ellipsize its name early. The host
publishes AT-SPI control rectangles and held-menu gesture bounds from the laid-out buttons,
rather than keeping a second set of row offsets.

Customization gate: the Mac `sidebar.project-row@1` replacement and after-title slot remain in
place. Linux currently mounts the native default content; it does not load extension-provided
replacement UI. In both hosts, project identity, selection, command admission and process
ownership remain host decisions. Live production theme roles, outline/table semantics and the
other navigator row kinds remain outside this preview slice.

Verification on 2026-10-03: the focused Mac row suite passed 22/22 tests; regenerated light and
dark row-kind renders were inspected and remained byte-identical. Linux `ViewClippingHarness`,
`TextLabelHarness` and the packaged 800/320/800-pixel project-row fixture passed. The complete
`bundle-smoke.sh` installed Ubuntu suite and `tests/wayland_smoke.sh --actions` passed. I inspected
the installed X11 normal/hover/count captures and Wayland's rendered project row: full names,
count-to-controls crossfade and button hover plates are visible in the real shell.

## 150. The content pane mounts the production page title

The Linux workspace now retains a `PaneHeaderView` and the exact production `PageTitleView`
above its terminal. A small Pango-backed `MorphingTitleLabel` supplies the one-line text API
while the Apple-only glyph animation is unavailable. The page title carries the selected saved
runtime's name and provider mark, or the project's name for a fresh shell. Pressing it reveals
the owning outline row. The Actions control is hidden until a Linux session menu exists; the
shared production view no longer exposes that hidden child to accessibility. The header is a
separate retained texture, so a terminal frame upload does not reshape or repaint its title.

This header exposed two real shim gaps. Soft inequality constraints had the wrong slack sign
and no weighted violation variable, so an optional intrinsic width could make an otherwise
feasible tree fail. The Linux diagnostic symbol also made its bitmap canvas the optical glyph
size rather than the requested layout slot; its required 16-point header slot then conflicted
with a 12-point intrinsic width. Both are corrected at their shim sources. The title fixture
links the production file on Mac and Linux and passes wide, narrow, hover, reveal, Actions,
provider-icon and hidden-Actions states. Existing Linux layout, clipping, outline and pane
header fixtures pass. Their generated renders were inspected.

The right pane reserves the header's 41 points at 2× scale as an 82-pixel inset. SDL texture
composition, terminal pointer and wheel coordinates, PTY frame/grid height, IME caret geometry
and AT-SPI component/text coordinates now use that inset. The title and its reveal action are
host-owned in this preview; runtime identity, selection persistence, command admission and
PTY ownership remain host-owned. The same customization-surface decision applies to the
preview header. The title costs one bounded bitmap on resize or interaction, while terminal
output continues to reuse the header texture and the mounted navigator rows.

Verification on 2026-10-03: the full installed Ubuntu `bundle-smoke.sh` suite passed, as did
the focused installed AT-SPI geometry and saved-terminal picker checks. The latter restored a
960×660 terminal viewport inside a 1280×742 outer window, retained its child and history, and
returned to the picker. The installed `tests/wayland_smoke.sh --actions` run passed its render,
AT-SPI and pointer checks. I inspected the installed X11 workspace captures with the visible
header and the title pressed to reveal its outline row. Wayland's existing checks cover the
navigator; they do not yet capture the terminal header there. The header's title is not yet
published as a separate control in the native AT-SPI tree.

## 151. The idle workspace mounts the production session placeholder

An app launch without an active terminal now opens a 320-pixel navigator and an 800-pixel
right pane. That pane retains the production `SessionPlaceholderView` rather than showing
an empty terminal texture. With projects it offers **No Session Selected** and **New Session**;
with an empty store it offers **No Projects Yet** and **Add Project**. The host supplies a
fixed diagnostic palette, a terminal symbol and the existing project creation/admission
routes. The placeholder retains its own view tree and bitmap and repaints only on resize or
interaction. Project rows remain bounded to the visible outline viewport.

The production view needed a narrow Linux `ThemedButton` leaf, two typography roles, and a
symbol lookup seam on `NSImage`. Linux closure action routing keeps the macOS selector path
intact. The initial installed capture showed the title clipped against the top edge and the
symbol above the window. A centered vertical `NSStackView` lacked a weak equation closing
its last child to the bottom of the stack, leaving its height underdetermined. Adding that
fitting constraint to the shim corrected the cause; the existing stack and ControlRow
contracts continue to pass. The title button's focus ring also needed an explicit
first-responder reset when terminal focus returns to the navigator.

The native bridge now treats the idle right pane separately from the terminal. It publishes
the actual laid-out action rectangle to an AT-SPI panel with title, detail and button; pointer,
Tab/Return and AT-SPI presses enter the same host action route. Opening a terminal clears the
idle texture and nodes before publishing terminal content. The first cross-pane hover test
found that canceling idle hover consumed the only pointer motion into a project row. Queuing
a replay then let a following click overtake the hover in an account picker. The bridge now
emits one crossing event, and the host clears idle hover and delivers the navigator motion
in the same turn. The active page title is now its own native AT-SPI button, with its bounds
and reveal action sourced from the mounted header.

Customization gate: this is a host-only diagnostic embedding of a production default view;
no new extension component is declared. Threading still owns project identity, selection,
menu admission and PTY lifecycle. Scaling gate: the retained idle tree and bitmap have a
constant size, and neither pointer motion nor terminal output remounts project rows or
reads the project graph. The preview still uses fixed colors and a limited symbol catalogue.

Verification on 2026-10-03: the macOS `Threading` Debug build and its boundary scripts passed;
the Linux stack and ControlRow contracts passed. The full non-root Ubuntu arm64
`bundle-smoke.sh` run passed from package build through desktop launch, including idle actions,
provider and account pickers, the 5,100-project outline, saved-terminal restart and directory
identity. Its evidence is `out/bundle-smoke/run.Ejy5RtDy`, and the installed `.deb` SHA-256 is
`72c734cfe147ce911a2a38c368356ed55cb440592444aae2fc4e4d96ae94dacb`. Focused installed
AT-SPI and account-picker runs passed, including one-motion idle-to-sidebar hover followed by
a first-click choice. The installed Wayland `--actions` run passed on the same source and its
idle, shell and title-reveal captures were inspected at `out/wayland-smoke.5TD0H9Qu`: the icon,
labels and button are centered, the terminal header is retained, and title reveal clears its
focus ring when selection returns to the navigator.

## 152. Visible table cells now have a reusable AppKit row shell

`NSTableView` and `NSOutlineView` now place each mounted cell inside a retained
`NSTableRowView`. Table and outline delegates can supply row chrome separately from cell
content, and `rowView(atRow:makeIfNecessary:)` answers only for mounted viewport rows.
Selection follows the stable row identity through reorder and scroll. Cell and row pools are
bounded independently by the visible viewport; no row view is built for a collapsed or
offscreen project. The 5,100-project/1,024-child outline fixture checks row-local cell
geometry, selection drawing hooks and bounded row-view construction.

The native navigator keeps its diagnostic row fill for now. Mounting the exact production
`SidebarHoverRowView` also needs the live theme roles and activity-beam stack, so this change
adds its AppKit row contract without inventing a second host-drawn version of that control.
The row shell is a platform shim; project identity, disclosure, selection admission and process
ownership stay with the host.

The first full installed run found a coordinate regression that the initial outline fixture
missed. A dirty-frame refresh put a cell's old document-space rectangle back into its new
row-local shell, so the host could not intersect its bounds with the visible navigator.
`Specimen.Row.configure` now retains a zero-origin frame while mounted in `NSTableRowView`;
the focused fixtures check that post-mount refresh as well as converted viewport geometry.
Verification on 2026-10-03: `shim-smoke.sh`, the focused outline fixture, and the full
installed Ubuntu bundle suite passed, including the 5,100-project/1,024-child native outline.

## 153. Saved-agent pages expose the production Actions control and menu rows

The right-pane `PageTitleView` now shows its existing Actions icon for a mounted saved agent.
It opens a bounded retained overlay containing two unchanged `ThemedMenuRowView` items:
**Copy Session ID** and **Copy Project Path**. The Linux host rechecks the active page,
owning project and saved-agent identity before writing either value to the native clipboard.
The menu is deliberately scoped to commands whose Linux behavior is implemented; a fresh
shell or saved terminal does not display an agent action it cannot perform.

The SDL bridge composites the menu after the terminal and header without rerasterizing it on
PTY output. While open it owns pointer and keyboard input, including Escape and arrow/Enter
navigation, before those events reach the terminal. The AT-SPI bridge publishes the actual
Actions bounds and mounted rows, and its queued row press carries the exact page identity for
host revalidation. Dismissing the menu removes its retained pixels and accessible nodes.
Customization gate: this is a host-owned Linux command surface around production default
components; it does not declare a new extension component or transfer admission, clipboard or
PTY ownership to a view. Scaling gate: the menu has two retained rows and one bounded bitmap,
and it performs no project scan or database read on pointer motion or PTY output.

Verification on 2026-10-03: the focused Release Linux build and installed Ubuntu/X11 smoke
passed. The smoke exercised AT-SPI Actions/row presses, pointer opening, keyboard selection,
exact clipboard values and Escape dismissal against a live synthetic agent; its PTY input log
remained unchanged across every menu gesture. I inspected the installed screenshot: the menu
is anchored below the header control, both rows are readable and its rounded corners composite
cleanly over the active terminal. The full non-root Ubuntu arm64 `bundle-smoke.sh` suite passed,
including this smoke, workspace restoration, account/project actions, and the large outline;
its evidence is `out/bundle-smoke/run.WGP2EZlo`. The installed Wayland `--actions` suite passed
rendering, AT-SPI and native seat input on the rebuilt package, with evidence at
`out/wayland-smoke.gMgfdUFV`. The saved-agent menu itself has not yet been driven under Wayland.

## 154. A project can begin a session with a real editable brief

The right-pane New Session → New Chat → provider path now mounts the unchanged production
`ThemedTextView` inside a scrolling editor. The Linux AppKit shim supplies the TextKit storage,
layout, selection, undo and IME composition methods that component expects. SDL sends committed
text, preedit and functional keys to that editor only while it has focus; the terminal keeps its
separate input kinds. The host passes the finished brief to the existing exact-project agent
launch and persists one session. Selecting a different project closes the old composer so its
brief cannot launch in the wrong directory.

The native AT-SPI panel publishes a text node with a stable identity, bounded value, caret,
selection, focus and layout bounds. It accepts keyboard editing through the window; AT-SPI
programmatic mutation was added in section 155. The host publishes at most 64 KiB of editor text to
the accessibility bridge. The pane rerenders after an editor change without rerasterizing the
unchanged sidebar; the earlier full-pane redraw cost was about 350 ms per key under arm64 Docker
emulation. Text layout caches lines and paints the visible viewport; large first pastes and
complex-script caret geometry need separate performance and visual checks.

Customization gate: this is Linux preview wiring around a production Design editor, not a new
public extension component. The host retains project identity, provider and account choice,
prompt admission, process launch and persistence. The themed editor owns presentation and
selection colors. The focused editor fixture and native composer smoke cover the shim and the
real X11 shell; the installed package repeats the journey.

Verification on 2026-10-03: the editor fixture, focused native composer smoke and full
non-root Ubuntu arm64 `bundle-smoke.sh` suite passed. The installed suite's composer screenshot
and selected-text screenshot in `out/bundle-smoke/run.hpCyruL8/restart-out/composer/` were
inspected at 1120×480: the action is fully visible, both brief lines and emoji render, and
selected text remains readable. After the final forward-delete, clipboard-cut and Escape fixes,
the Release `.deb` was rebuilt and its installed composer journey passed again in a Swift-free
Ubuntu container; the final screenshot is `out/composer-installed-final/composer.png`. The
theme-boundary and main-actor-latency checks are clean. Wayland composer input is verified in
section 155.

## 155. The Linux composer accepts accessibility edits through the production editor

The composer's AT-SPI node now implements `EditableText` set, insert, delete, copy, cut and
paste, plus `Text` selection and caret changes. Each callback queues a bounded edit instead of
changing its text projection during an accessibility call. The queue holds at most 16 edits,
each with at most 64 KiB of UTF-8. An SDL event wakes the Swift host, which checks a fresh
composer identity and applies the edit to the same production `ThemedTextView` used by native
keyboard input. The host converts AT-SPI Unicode scalar offsets to TextKit UTF-16 ranges;
the shim retains selection, undo and drawing ownership. The queue rejects offsets beyond its
predicted text length, and unmount or a new composer identity invalidates pending events.

The X11 composer journey now enters a brief with keyboard and clipboard input, replaces and
edits it through AT-SPI, cuts and pastes it through the native clipboard, selects an emoji, and
launches one agent with the final exact Unicode prompt in the selected project. The emoji
offset check crosses the UTF-16/single-scalar boundary. It also captures the installed window
after the accessibility edits. These are Linux bridge and shim changes; the production Design
view is unchanged. Threading still owns project identity, prompt admission, process launch and
persistence, while the theme owns editor appearance. The text and queue bounds keep each
mutation finite and prevent callback reentrancy into the rendering path.

The separate Weston composer journey now types Swedish `å` and a newline through real seat
events, verifies the AT-SPI value and rendered pixels, and launches one exact-project agent
without leaking prelaunch keys into its PTY. Weston needs an explicit `[keyboard]` layout in its
test config; `XKB_DEFAULT_LAYOUT` alone left the compositor on the US map. The capture shows
both lines and the caret in the actual SDL window. Physical keyboard and IME behavior on
Wayland remain unverified.

The full production `PromptView` is a larger integration boundary than its text box: it eagerly
creates completion and context-rail presenters and compiles attachment, pasteboard, drag, image
and QuickLook paths even when those features are hidden. Several of those AppKit services and
Objective-C selectors have no Linux shim yet. This slice reuses its unchanged production
`ThemedTextView` instead of copying `PromptView` into a Linux fork. The shared extraction
in section 156 exposes the prompt's text/focus/submit core while leaving optional media and
platform services behind the production Design boundary.

Verification on 2026-10-04: strict Ubuntu arm64 C compilation, the focused native X11 composer
smoke, the theme-boundary and main-actor-latency checks, and the full non-root installed
`bundle-smoke.sh` suite passed. The package evidence is `out/bundle-smoke/run.7p7WxUag`; I
inspected its `restart-out/composer/composer-accessibility-edited.png` at 1120×480 after the
programmatic edits. The installed `.deb` SHA-256 is
`5f10b4caf91eb8e8430ee83a8985a58c895e5e8e9cf6b126bf0343df7f535259`.
The rebuilt package also passed `tests/wayland_smoke.sh --actions`, including real compositor
input for the multiline Swedish composer. Its evidence is `out/wayland-smoke.DbZITLu6`; I
inspected `composer/capture/open.bmp` after conversion to PNG at its native 1120×480 size.

## 156. The Linux composer mounts the production prompt editor

`PromptTextView` has moved from inside `PromptView.swift` to its own shared Design source.
The macOS `PromptView` still uses that class and its plain-text setup. The Linux composer
mounts the same class through `PromptTextView.scrollingPrompt()`, so placeholder drawing,
focus callbacks and Return semantics have one implementation. The surrounding Linux pane
continues to own project selection, text bounds, session launch and persistence. Full
`PromptView` still depends on Mac attachment and context services; the Linux host keeps its
existing composer shell around the shared editor.

The Linux AppKit shim now supports the editor's bounded string drawing, plain-text settings
and scroll elasticity. It reserves keys for SDL's composition events while IME text is
marked; Escape cancels that preedit before it can close the composer. The focused editor
fixture covers placeholder pixels, long-text caret scrolling, Return variants and marked
text commit. The installed X11 composer journey checks the empty placeholder, Unicode
editing through AT-SPI, and Command-Return session launch.

Customization gate: this is a shared production Design editor in a Linux host, with no new
public extension surface. The host retains the `composer.session-start@1` command and its
project, provider, admission and draft decisions. Prompt presentation remains in Design.

Verification on 2026-10-04: the macOS app built and its focused prompt tests passed; a movie
attachment test that timed out during the first parallel run passed alone on rerun. The
Linux editor fixture, focused native X11 composer smoke, theme-boundary and main-actor
latency checks, and full non-root installed Ubuntu arm64 `bundle-smoke.sh` passed. The
installed evidence is `out/bundle-smoke/run.7Rgnxkhl`; I inspected its
`restart-out/composer/composer-empty-placeholder.png` at 1120×480. The rebuilt `.deb` is
SHA-256 `9bfee3bb46215d605ea4b04331e99e89ec20b219dc5b4aa5f10175960686fbc5`.
Installed Weston `tests/wayland_smoke.sh --actions` passed rendering, AT-SPI, seat input,
and the multiline Swedish composer. Its evidence is `out/wayland-smoke.YaFoq797`; I
inspected `composer/capture/open.bmp` at its native 1120×480 resolution. Live composer
IME cancellation and candidate commit also passed under X11/IBus with
`THREADING_LINUX_COMPOSER_IME_ONLY=1 ./window-smoke.sh`. I inspected
`out/composer-ime/composer-preedit.png` and `composer-committed.png`: the provisional `你`
is underlined and Escape removes it without closing the pane; `你好` renders after commit.
The IBus journey verifies that no session starts during either preedit, then Return adds a
line and Command-Return launches one exact-project session without leaking the brief into
the PTY. The app and IBus daemon must share `HOME` for SDL to find the input context.

## 157. Linux reuses the production composer choice control

The Linux composer now mounts the unchanged production `ChipView` source twice, for project and
provider selection. Its choice presentation callback opens a bounded overlay of production
`ThemedMenuRowView` rows. The pane keeps at most six menu rows mounted even when the host has
thousands of projects; changing the visible page replaces those rows. The Linux AppKit shim
supplies the chip's surface painting, text measurement, symbol art and accessibility hooks.
It does not copy the Mac composer or its choice control into a Linux fork.

The host supplies exact project and provider identities and revalidates a choice before changing
the active composer target. Changing either choice updates the title and chip while preserving
the prompt text and composer identity. The AT-SPI bridge exposes two combo boxes and the
visible menu rows, and sends exact row identity back through the host event path. Old composer
actions cannot select a row in a new composer instance. Pointer and keyboard selection use the
same pane model. The native key route remains with an open menu after a pointer press, and
selection returns focus to the prompt. Printable keys select a matching menu entry without
editing the draft. The host still owns project and provider availability, prompt admission,
process launch and persistence. This is a Linux host mounting shared Design components inside
the existing `composer.session-start@1` customization boundary, with no new extension surface.

Verification on 2026-10-04: the Ubuntu arm64 `WindowHarness` target and focused native X11
composer smoke passed. The smoke opened both choices through AT-SPI, chose a second project and
Claude Code, selected provider rows with the pointer and keyboard, used type-to-select, and
preserved a draft across those changes. It edited Unicode through the shared prompt view and
launched exactly one agent in the selected project. I inspected the real 1120×480
window captures `out/composer/composer-project-menu.png`, `composer-provider-menu.png` and
`composer.png`; the chips and selected, bounded menu rows are visible. Theme-boundary and
main-actor-latency checks passed.

The full non-root installed Ubuntu arm64 `bundle-smoke.sh` suite also passed, including the
composer choices and exact project launch from the packaged `.deb`. Its evidence is
`out/bundle-smoke/run.cK3kh2ki`; I inspected
`restart-out/composer/composer-project-menu.png` from that installed window. The `.deb`
SHA-256 is `f272b47cc67b394d4a17bc00f83c463eccda293a70449a575466462e8e171f03`.

## 158. Linux reuses the production primary button

The Linux idle placeholder and New Session composer now mount the unchanged production
`ThemedButton` instead of a Linux-only control copy. The composer moves Start Session below the
shared `PromptTextView`, matching the production action order. Its button shows the shared
Command-Return shortcut, disables for an empty or provisional IME draft, and sends its action
through the existing host-owned submission path. Project/provider identity, admission and agent
launch remain with the Linux host. This is part of the existing
`composer.session-start@1` surface; it adds no extension contract.

The shim gained the button's AppKit, CoreText and Core Animation vocabulary. Ordinary controls
still paint through the retained bitmap view tree. The optional floating layer path compiles but
is not mounted or visually verified in this slice. Linux Pango now measures clipped single-line
attributed text at both 1× and 2×, reserving the larger rounded width so the production button
does not truncate its own title at 2×.

Verification on 2026-10-04: Ubuntu arm64 `WindowHarness` and the focused native X11 composer
smoke passed. The smoke checked that the button lies below the editor, is disabled before input,
enables after a draft, and launches one agent in the selected project by a real pointer click.
It also exercised project/provider choices and multiline Unicode editing. I inspected the fresh
1120×480 `out/composer/composer.png`: the full Start Session title, shortcut cue, editor and
focus state are visible. Theme-boundary and main-actor-latency scripts passed. The packaged
`.deb` suite and floating button behavior were not rerun for this checkpoint.

## 159. Linux mounts the production Open In split control

The terminal header now mounts the unchanged production `SplitIconButtonView`. A Linux GIO
adapter discovers desktop applications registered for directories and launches the selected
application with a `GFile` for the active project's checkout. The host keeps project identity,
active page selection, directory validation, app availability, and the last-used preference.
GIO work runs outside the SDL window thread. The chooser retains at most 64 lightweight app
choices while mounting at most six shared `ThemedMenuRowView` rows. Keyboard, pointer, and
AT-SPI actions use the same validated app ID path; Command-O invokes the primary action.
The host owns launch behavior, so this adds no extension presentation contract. The primary
button currently uses a folder glyph until Linux resolves each app's icon hint into bitmap art.

Verification on 2026-10-05: Ubuntu arm64 `WindowHarness` built, and the focused native X11
smoke exercised the real split button, AT-SPI bounds and actions, default app launch,
an eight-app chooser with six mounted rows and PageDown selection, last-used primary action,
exact checkout path with shell metacharacters, and refusal after the checkout moved. The
overlay accepts the six-row texture and shrinks its viewport for short windows. I inspected
`out/open-in/open-in-header.png` and
`out/open-in/open-in-choices.png` from the real 1120×480 window. The adapter's isolated GIO
contract checks literal directory launch and invalid input. The packaged `.deb` runtime runner
now includes the same Open In journey; a full installed bundle run remains to be verified.
