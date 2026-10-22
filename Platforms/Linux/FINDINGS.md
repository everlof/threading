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
The host owns launch behavior, so this adds no extension presentation contract. A GdkPixbuf
adapter resolves the selected application's absolute PNG/SVG icon or bounded XDG theme name
off the window thread. It reads at most 256 KiB, limits source dimensions to 1024 pixels,
and produces at most 64×64 RGBA pixels. The primary button keeps a folder fallback.

Verification on 2026-10-05: Ubuntu arm64 `WindowHarness` built, and the focused native X11
smoke exercised the real split button, AT-SPI bounds and actions, default app launch,
an eight-app chooser with six mounted rows and PageDown selection, last-used primary action,
exact checkout path with shell metacharacters, and refusal after the checkout moved. The
overlay accepts the six-row texture and shrinks its viewport for short windows. I inspected
`out/open-in/open-in-header.png` and
`out/open-in/open-in-choices.png` from the real 1120×480 window. The adapter's isolated GIO
contract checks literal directory launch and invalid input. The packaged `.deb` runtime runner
includes the same Open In journey.
The icon follow-up required `libgdk-pixbuf-2.0-0` and `librsvg2-common` in the installed
package. A focused X11 rerun passed both an absolute red PNG and a named green SVG icon with
pixel assertions; I inspected `out/open-in/open-in-header.png` and `open-in-selected-b.png`.
The Linux shim needs to materialize the visible split-button glyphs before layout: a deferred
glyph built in `draw(_:)` first acquired a zero-sized frame after that pass.
The rebuilt Ubuntu arm64 `.deb` passed the full non-root installed `bundle-smoke.sh` suite,
including Open In. I inspected the installed red PNG and green SVG states in
`out/bundle-smoke/run.UKrYwWt5/restart-out/open-in/`. The package SHA-256 is
`57e066829c7ce338627f44b8b13883d756ae67792c9a4bcdb38b62086e1dea1d`.

## 160. The Linux composer chooses a provider-qualified account

The Linux New Session pane still has the production two-chip layout. Its second unchanged
`ChipView` now presents the exact provider and account, with cached provider artwork and
production `ThemedMenuRowView` choices. The host discovers no more than 32 verified accounts
per provider; the pane retains at most 64 compact values and mounts only the rows that fit,
never more than six. Bounded provider-qualified menu tokens map back to portable `AccountID`
values in the host, where membership and executable availability are revalidated. The chosen
handle is passed to the existing agent launch route. The host owns account discovery, choice
identity, launch admission, and session recording; the shared Design controls own presentation.
This stays inside the existing composer surface rather than adding an extension contract.

Verification on 2026-10-05: the Ubuntu arm64 `WindowHarness` build and focused native X11
composer-account smoke passed. Eight named Codex accounts were available; keyboard scrolling
kept the viewport bounded, AT-SPI chose a later row, and the launched child observed the exact
named `CODEX_HOME`. I inspected `out/composer-account/composer-account.png` from the real
1120×480 window: the second chip shows the provider mark and selected account. The full
non-root installed `.deb` suite also passed the composer-account smoke. I inspected its
`out/bundle-smoke/run.UKrYwWt5/restart-out/composer-account/composer-account.png` from the
installed product shell.

## 161. Native wheel input reaches the production prompt's scroll viewport

The SDL bridge discarded every wheel event over the idle right pane, including its New Session
composer. A new real-window regression reproduced this with a 40-line Unicode brief: the editor
pixels stayed unchanged after upward wheel input. The bridge now delivers that event through
the retained AppKit window's hit testing and responder chain to the existing scroll owner.
Both fractional SDL notch axes survive the boundary, FLIPPED direction is normalized, and the
event retains its own pointer position. Invalid non-finite deltas are refused. Scrolling leaves
keyboard focus, selection and draft text intact; later typing reveals the caret again.

The Linux text renderer also computes its visible cached line range before drawing. The previous
loop examined every wrapped line to discover that range. Preparation remains document-sized;
warm drawing visits only the viewport. Three alternating Release measurements of 170 and 1,700
lines found no material latency improvement. The workload, numbers and limitations are in
`docs/architecture/performance.md` under Linux prompt viewport drawing.

This reuses the unchanged production `PromptTextView` within the existing composer surface.
The Linux host retains project/account identity, prompt admission, persistence and launch;
the shared Design editor retains presentation and text interaction. It adds no extension API.

Verification on 2026-10-05: the Release editor fixture, strict native C pointer contract,
source X11 composer journey, 11 runner contracts, and theme-boundary and main-actor-latency
checks passed. Build/core contracts passed, and the rebuilt non-root installed package's complete
runtime suite passed on rerun, including its composer wheel journey and 5,100-project outline.
I inspected its real 1120×480 `composer-scroll-up.png` and `composer-scroll-down.png` in
`out/bundle-smoke/runtime-scroll.j8q0owmb/restart-out/composer/`; returning to the tail reproduced
the original editor pixels and retained the exact Unicode brief, caret and focus. The package
SHA-256 is `f3cb72466cd2c056e887e57c5aa306826af9cb469e5c40d1c18cded35f949e82`.
Installed Weston Unicode editing, exact launch and PTY isolation passed; its inspected capture
is `out/wayland-smoke.C80opiwE/composer/capture/open.bmp`. Wayland wheel and physical trackpad
input remain unverified.

The first complete installed-suite attempt stopped on an unavailable second terminal before
reaching the composer; its original cause was not captured. The same package subsequently
passed two complete workspace journeys. The workspace test now captures its accessible terminal
reason and failure screenshot, and enables bounded navigation tracing. This is additional
failure evidence, not a claimed fix for that intermittent launch refusal.

## 162. Workspace recorder resize signals publish through one loop

The native workspace fixture's child called its JSON publisher directly from `SIGWINCH`.
A resize between the main publisher's temporary write and rename reentered that publisher,
consumed the temporary file, and killed the child with `FileNotFoundError`. A deterministic
POSIX-PTY regression failed on the old recorder on both macOS and Ubuntu. The preserved unsafe
recorder also reproduced an exited second child in the installed native workspace.

Signals now wake a pipe; the child's one input loop publishes state and mouse-mode changes.
The same opt-in `THREADING_WORKSPACE_RESIZE_INTERLEAVING=Workspace02` probe passes the complete
installed workspace journey with the corrected recorder. Its evidence is
`out/workspace-signal.XmYZaYpO`; the negative native run is
`out/workspace-signal-before.rBYn9bNC`. The 12 local runner/recorder contracts and the focused
Ubuntu recorder regression pass. This fixes a proven fixture race. The earlier unavailable-pane
failure remains a separate, unconfirmed cause; it is not relabelled as this child exit.

## 163. Composer controls participate in the shim key-view loop

The composer now declares an explicit AppKit key-view loop through its two unchanged production
`ChipView`s, `PromptTextView` and `ThemedButton`. The shim's weak next/previous edges skip disabled,
hidden and detached views and terminate an ineligible cycle. Tab and Shift+Tab traverse the loop;
Space/Return opens a focused choice, Escape restores that control, and Home/End/Page keys navigate
the bounded menu. AT-SPI focus follows the retained first responder rather than assuming every
non-editor focus belongs to Submit. The native bridge keeps composer functional keys separate
from text/IME enablement and preserves command release ownership across a session launch.
IME-owned releases have their own state, so ordinary composer keys cannot be mistaken for preedit.

The same keyboard route handles line/document boundaries and page movement in the text shim.
Return's native carriage-return character becomes a newline. Caret hit testing chooses the
nearest grapheme boundary, and vertical movement retains its column through short lines. These
paths use cached visual lines; the four-control loop and at-most-six menu rows remain bounded.
The host still owns project/account choice, input authority, admission, persistence and launch;
this adds no extension contract or fork of the production Design components.

The compact form fits the supported 640×180 window with a readable editor and all controls.
Its primary title becomes **Start**, while the accessible action remains **Start Session**.
The resize journey also exposed a stale-frame refusal: SDL can resize before Swift consumes the
size event, while a preceding key still needs painting. The placeholder now uses the same retained,
cropped frame path as other panes until the new layout is ready. It does not stretch text or abort
the window over that normal ordering.

Verification on 2026-10-06: editor/key-loop/navigation fixtures, strict C input/resize contracts,
the source X11 composer journey, theme and latency boundaries, and real IBus Pinyin preedit,
Escape cancellation and `你好` commit passed. Inspected native focus and 640×180 captures are in
`out/composer-focus.89o1e9lF`. The rebuilt non-root installed composer journey also passed;
the complete installed runtime suite passed, including 5,100-project navigation, terminal
restoration and desktop entry. Its inspected focused-chip and compact **Start** captures are in
`out/bundle-smoke/runtime-focus.oeqwo2jw/restart-out/composer/`. The package SHA-256 is
`116342912d569adc61b49cadc95e47215e00031f81e0135fccea43284744e08b`.
The installed Weston journey also verifies compositor wheel and smooth finger axis/stop delivery,
unchanged Unicode brief/caret/focus, exact return pixels and exact-project launch. Its evidence is
`out/wayland-focus.2e4kb39j`. Physical trackpad hardware remains unverified.

## 164. Production Markdown grammar compiles through the font shim

The unchanged `Markdown.swift`, `MarkdownInline.swift` and `AgentAuthoredURLPolicy.swift` now
compile in `MarkdownHarness` through the AppKit shim. The first compile exposed missing font
trait conversion and link keys. `NSFontManager` implements the measured bold/italic subset,
retaining the other trait, family role and point size; descriptor resizing retains those traits.
Plain label shaping, attributed spans and font metrics all pass italic to Pango rather than
accepting the request and drawing upright text. Unsupported conversions still refuse explicitly.

Comparing normalized attributed blocks against macOS exposed two further faults. The shim's
Right and Center alignment raw values were swapped. Fonts also lacked value equality, so
literal scanner tokens remained separate runs and could exhaust the 64-span drawing budget.
The font now supplies Swift `Hashable`/`Equatable` values; 170 repetitions of an intraword
identifier merge to one run without changing the text. This uses corelibs Foundation's
[Hashable value-box equality](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/Bridging.swift),
not an Objective-C object adapter. Raster and source-byte budgets remain unchanged.

On 2026-10-06, eight complete grammar snapshots match macOS AppKit: block splitting, headings,
quotes, lists, tables, Unicode, nested bold/italic/code, safe web-link metadata and inert non-web
labels. Both platforms also verify the nesting ceiling and equivalent-run regression. Inspected
1×/2× renders are in `out/markdown-{linux,macos}/`; the Pango and Apple font faces differ, so this
is semantic and visual compatibility evidence rather than a pixel-identity claim. Strict C
checks, the existing label/editor fixtures and 12 local runner contracts pass. The source native
composer journey passes at `out/markdown-composer.Rprjd5PY`.

The ordinary `window-smoke.sh` runs this grammar fixture. It does not mount the full
`MarkdownView` or a conversation screen. Selectable labels, complete paragraph/document paging,
transcript integration and Linux web-link activation remain required before that claim is valid.

The rebuilt Ubuntu arm64 package passes the complete installed runtime suite without Swift,
including the composer, 5,100-project outline, 1,024-terminal stress, terminal restoration,
live-child reinstall and desktop entry. Evidence is
`out/bundle-smoke/runtime-markdown.vo2dymn4`; the installed composer captures were inspected.
The package SHA-256 is `e5124b42a3eb4153d6c01de5d2980593f28b92c84fd847ecbadba36e4251630d`.
Physical Linux input remains unverified; the original intermittent unavailable-terminal failure
from §162 remains unexplained despite the later passing workspace journeys.

## 165. The shared document renderer reaches the native Linux window

`MarkdownView` now compiles in the native preview with its production paragraph, list, code,
quote, table and pager implementation. Only Objective-C action wiring has a Linux closure branch.
The document table was extracted from `ThemedTables.swift` into `ThemedDocumentTableView.swift`;
the extracted implementation is byte-identical. The preview links both files through source
symlinks rather than maintaining Linux copies of the renderer.

Selectable labels retain one bounded Pango layout for grapheme hit testing. Keyboard and pointer
selection preserve Unicode; selected text keeps its font/code/link styling and copies through an
explicit native clipboard provider. The label remains read-only. Its existing 4096-byte,
64-style and eight-line drawing limits still apply, so this does not prove complete rendering of
an arbitrarily long individual paragraph or code block.

The installed narrow-window capture exposed a separate scale bug: the old 128-device-pixel
measurement cap clipped the final line of an ordinary paragraph at 2×. Selectable-label metrics
now cover the bounded eight-line layout, and drawing uses visible tiles of at most 2048×128
pixels. An eight-line Unicode regression checks the last line's ink at 2×; its rendered capture
was inspected. Existing nonselectable label measurement and raster limits remain unchanged.

The assembled view exposed geometry the leaf fixtures could not: wrapping labels needed their
settled width before height measurement, scroll-view viewports were being pinned at their old
zero-sized frames, and Auto Layout documents floated at root coordinates. The shim now measures
wrapping in bounded follow-up passes, constrains the viewport to its scroll owner, and gives the
clip owner its document origin. Frame application calls subclass size hooks, so the shared table
reflows on resize. Wheel direction respects flipped and unflipped documents.

The table's new changed-height API updates an indexed prefix sum rather than rebuilding every
following offset. The 1,000/10,000-row fixture checks exact boundaries, one provider height read
per changed row and a bounded recycled viewport. One thousand changes took 8.24/3.65 ms in the
optimized fixture under shared-machine load; these are scope checks, not a before/after speedup.

The native optimized document journey passes at `out/document-ui-release.2dD5XcQF`: exact Unicode
copy, read-only keys, code, live light/dark appearance, resize and bounded document paging.
Open, selected, dark, narrow and last-page captures were inspected. Initial presentation took
1.95 seconds. The Debug general solver took over a minute on this same bounded page; optimized
first-paint latency and larger nested blocks remain performance work, rather than being hidden by
reducing the production page budget.

Mac `native-chat-showcase` builds and renders successfully under System, Cyberpunk and Swiss
Minimalist. Its report is `.build/ui-evidence-reports/20261006-002212-93268/report/`. Forty-eight
captures have no approved baseline; four existing references differ in the composer model label
(`gpt-6-sol` versus `gpt-6.1-sol`). No baselines were changed, and exact regression approval is
not claimed. The renderer remains a diagnostic in Linux: native conversation transport, timeline
integration, complete long-label viewports and web-link actions are still open.

The complete Swift-free, non-root installed runtime suite passes at
`out/bundle-smoke/runtime-document.wgltoi_u`, including the document journey, 5,100-project
outline, terminal restoration, live-child reinstall and desktop entry. This suite used package
SHA-256 `647b4021272287ed9af09ffdc4c57e02f5f02c73057e52f6274fc5f889834dbd`, before the final
selectable-label tile correction above.

The final rebuilt package repeats the document journey as a non-root user in the Swift-free
Ubuntu container at `out/document-installed-final.atB5oV0f`. Its narrow and dark captures were
inspected: the previously clipped final paragraph line is visible. First presentation took
2.366 seconds. The final package SHA-256 is
`34cbc8a737ae7e4b8247bab0c050b040034b65e6e5b86e9e21170b30fdd5144d`.
The complete runtime suite was not repeated for this final selectable-label-only correction;
the targeted 2× render regression, strict C checks and installed document journey passed.

## 166. Pointer claims reach the native cursor

`NSCursor.set()` previously changed only a Swift value. The Linux host now installs a cursor
provider for its native window's lifetime, mapping the shim's six semantic shapes to SDL system
cursors. The native window lazily retains at most six objects; repeated requests reuse those
objects, and teardown restores SDL's default before freeing them. The TextKit editor now declares
its I-beam through the same cursor-rectangle mechanism as selectable document labels.

Moving a view under a stationary pointer can invalidate its claim without producing an input
event. Cursor invalidation now coalesces until the content root has rendered, resolving once
against settled geometry. The last physical pointer event determines which shim pane owns that
refresh, so repainting another pane cannot overwrite the cursor.

Window-height changes also rebase the last pointer location from its old bottom-origin window
coordinates. A native regression leaves the physical pointer in a paragraph gap, narrows the
window until the heading covers that point, then restores the size. It fails against the earlier
packaged executable (`out/document-cursor-height-reference.E9V0QPs7`) and passes after rebasing
(`out/document-cursor-height.f3X3PXuw`), with the actual X server cursor observed at each step.

The strict native contract checks all six shapes, 1,000 repeated selections, object reuse and
invalid-request isolation. The Markdown fixture checks a label moving away from a stationary
pointer and separate pane ownership. Source X11 document and composer journeys pass at
`out/document-cursor.uNzfT9FJ` and `out/composer-cursor.3lDgz3uw`. Their independently captured
XFixes arrow and I-beam images were inspected. Physical pointer hardware remains unverified;
terminal-content cursor routing is still incomplete. Native conversation
transport and controller integration remain separate required work.

The complete Swift-free, non-root installed runtime suite passes at
`out/bundle-smoke/runtime-cursor.62UvxBNc`, including the native cursor document/composer checks,
5,100-project and 1,024-terminal stress, terminal restoration, live reinstall and desktop entry.
This used SHA-256 `d144f507d524e07445db7dcc3aa4683a50655a4a677026af78413b89fc4c910a`, before
the final height-rebasing and explicit default-cursor teardown corrections.

The final rebuilt package repeats the document and composer checks as a non-root user without
Swift at `out/cursor-installed-final.myiR4fBq`, including the stationary-resize cursor regression.
Its native cursor images were inspected; first document presentation took 2.563 seconds under
shared-machine load. The installed Weston composer journey passes at
`out/wayland-smoke.T1SjZVNR`; its protocol trace contains actual `wl_pointer.set_cursor` updates
and no host cursor-provider failure. This is compositor software evidence, with physical hardware
still unverified. The complete suite was not repeated for the final two corrections; the strict
C contract and targeted final-package journeys passed. The final package SHA-256 is
`0b6bfcc7682cc86e5459bcccf9b9721fc4f1ab863ee10d91337703c0fd572e81`.

## 167. The production conversation reducer compiles on Linux

`CoreSlice` now includes the exact production `ConversationTimeline`, `StreamEvent`, run-progress,
tool-summary/outcome, diff and chart value models. NativeDiffCore is pinned to the same revision
as the Xcode resolution (`363c6197d8e334fa0aaf30550fb0a0bcac540e71`). PermissionRequest and the
shared diff aliases were extracted byte-identically into Foundation files. The reducer's unchanged
20,000-character tool-result budget now belongs to `ConversationTimelineDefaults`.

Chart projection remains a host decision: the app's existing initializer supplies its exact MCP
registry decoder. The portable initializer accepts that projection explicitly, keeping the
application's admitted tool catalogue and execution/permission machinery outside the Foundation
reducer. The chart decoder was extracted byte-identically; the Linux document diagnostic supplies
no chart projection and does not advertise chart or native-session support.

The Linux contract exposed a shared live-wire bug: decoding an entire typed content array with
`try?` lost valid assistant text and tool calls when one sibling was null or another non-object.
`WireList.decode` now obtains each element decoder before trying its expected type, preserving
order and reporting skipped shapes once by structural counts. Assistant blocks and tool results
use this path. Malformed JSON still reports a malformed envelope.

The same contract source runs in Linux CoreSliceHarness and Mac XCTest. It checks boolean/integer
identity and overflow, streaming replacement, stable tool/diff/result identity, interrupted
settlement and readable provider siblings. Generated 1,000/10,000-turn histories each return one
changed-row receipt and one streaming receipt; this verifies projection scope, not a latency bound.
The complete Linux core harness and 71 focused Mac tests pass.
An additional 39-test Mac chart/factory selection passes, including both raw and qualified chart
tool names through the app's preserved registry projection.

The native document diagnostic now prepares its provider envelope and timeline on one bounded
worker, then gives the authoritative assistant message to the shared MarkdownView. Its source
X11 journey passes at `out/conversation-document.RoRmdNnJ`; normal and narrow captures were
inspected. First presentation took 2.229 seconds. This is a wire → model → document compatibility
path. The production transcript table, row factories, session transports and real conversation
controller remain required before native Linux conversation integration is complete.

The first installed suite stopped in a folder-import overlap fixture while waiting two seconds
for GTK chrome inside a deliberately held four-second hello. The fixture now releases that hello
once the owned chooser process establishes overlap, then waits separately for visible chrome.
The shipping hello deadline is unchanged. A test-only three-second GTK native-dialog presentation
delay reproduces the old failure at `out/catalogue-gtk-reference.29ugvwb6`; its trace confirms the
delay ran. The delay module is included in the source and installed regression runners.
The corrected non-root installed overlap fixture passes with four confirmed delayed presentations
at `out/catalogue-gtk-delay.Ayq809r0`, retaining the exact durable counts and selected identity.

The rebuilt package passes the complete Swift-free, non-root installed runtime suite at
`out/bundle-smoke/runtime-conversation-final.X8ObO1Qu`, including the confirmed GTK delay,
production wire/timeline/document journey, composer, large outline, terminal restoration,
live-child reinstall and desktop entry. Its document capture was inspected. Installed first
presentation took 4.339 seconds, so first-paint latency remains unresolved. The package SHA-256 is
`5fa719d77bd1a4aebd745a9bf5bdd958146cde9fd4aaaa8bcad44d72431824ee`.
Theme and main-actor boundaries, strict C delay-module compilation, shell syntax, all 60 source
copy checks and 12 local runner contracts pass. No native conversation-session completion or
physical Linux hardware claim is made.

## 168. Shared conversation cells use viewport-owned automatic heights

The production `ConversationVirtualRowHost` moved from the transcript-table feature file into
`UI/Design/`. Its implementation is unchanged except that the identical 999 column-width priority
now belongs to `ConversationRowDefaults`; the existing conversation defaults forward to it.
Linux links the shared file directly. The UI-structure ratchet decreases with this ownership move.

The table shim now supplies automatic row heights, mounted-row enumeration and cell reuse cleanup.
Offscreen rows retain estimates; only invalid visible cells ask their shared host for fitting size.
Measured changes update the indexed row geometry, and newly revealed rows settle through the same
viewport reconciliation. Removed cells release content before entering the bounded reuse pool.
An explicit changed-row reload invalidates its measurement without rebuilding history.

Automatic navigation now lands at a requested row's estimated start. Bottom-aligning an estimate
could measure a preceding partial row, change its height and push the requested row out of view.
The 1,000/10,000-row fixture exposed this and now checks the requested row remains materialized.
Both sizes use three shared hosts in a 120-point viewport, with no manual-height delegate reads;
width changes reflow visible content, offscreen invalidation creates no view, and replacement
content drops the old height. Existing indexed-height and outline fixtures also pass.

The native diagnostic mounts the production assistant block renderer inside these shared hosts.
Cheap source-block planning is now explicitly nonisolated and runs on the existing worker;
font/style materialization stays on the UI actor. The X11 journey passes at
`out/automatic-rows-native.RCzoUplB`: exact Unicode clipboard, width reflow, bounded cells, last
block and return. Its normal, narrow and tail captures were inspected. First presentation took 0.498 seconds under
shared-machine load; this is a different viewport materialization path, not a matched speedup or
proof of full conversation-controller latency. Native session transports, row kinds beyond
assistant Markdown and the production transcript controller remain open.

The final package passes the complete Swift-free, non-root installed suite at
`out/bundle-smoke/runtime-automatic-rows.P9c7oEqF`, including both document paths, delayed GTK
admission, workspace/composer, large outline, terminal restoration, reinstall and desktop entry.
Installed normal/narrow/tail automatic-row captures were inspected. First presentation took
0.374 seconds for automatic rows and 1.900 seconds for the whole-page diagnostic in this run;
these are observations of different workloads, not a matched performance comparison.
The package SHA-256 is `c8a11823b92382f86d5a8d84dfef24c0c1d7b0c98462742d4645639538f852dc`.

Mac conversation render/rhythm tests pass (38 tests, five skipped). The canonical native-chat
showcase run captures all 52 variants but exits 3: 48 are unbaselined and four differ. Inspection
of all four composer differences shows the model label changing from `gpt-6-sol` to
`gpt-6.1-sol`, its resulting control offsets, and the animated activity indicator. Decoded pixels
match the preceding showcase run outside that indicator's 36×36 region; the transcript area
matches the accepted images. No baseline was changed, and exact visual regression acceptance
is still pending. The report is `.build/ui-evidence-reports/20261006-023215-36704/report/`.

## 169. Incremental transcript table mutations preserve the viewport

The shim now implements the production transcript's `insertRows(at:withAnimation:)` and
`removeRows(at:withAnimation:)` calls. Surviving cells and automatic-height measurements move
with their rows. Removed mounted cells release content, selection follows retained rows, and
inserting/removing above the viewport restores the reading anchor. This covers the transcript's
empty animation options; animated row transitions remain unsupported.

Tail appends extend the indexed heights and identity map only for new rows. Tail removal drops
the suffix directly. Middle/disjoint edits remap cheap O(history) metadata once without asking
every row for a height or reconstructing surviving views. This does not claim constant-cost
middle insertion. The 1,000/10,000-row contracts pass across manual/automatic heights and
positional/stable identities, with 40 successive appends, disjoint edits and selected-row removal.
The existing automatic-height and large-outline contracts pass too; the bundle build gate now
runs both harnesses against its shipping build configuration.

The native diagnostic checks prefix insertion/removal and offscreen tail append/removal through
SDL key events at `out/structural-rows-native.v315Kv85`. Its inserted capture was inspected, and
the middle/inserted viewport decoded pixels are identical. Cell configurations stay unchanged;
live contents equal mounted cells. First presentation took 0.379 seconds, an observation rather
than a matched performance claim. The first native attempt used repaint serials as page-action
receipts and observed an earlier frame; the runner now waits for an explicit navigation-action
counter. This fixes test synchronization without masking rendered differences.

The complete conversation table/controller and session transports remain open: these APIs remove
another prerequisite, but the diagnostic still presents assistant Markdown blocks only.

A direct typecheck of the exact pinned NativeDiffAppKit source against the built shim identifies
the next diff-rendering prerequisites: six system color names and `CALayer.backgroundColor`.
The backing layer currently does not participate in `NSView.render`, so merely storing a color
would leave diff-row fills missing. That needs rendered layer integration before tool/diff rows
can be claimed. This probe does not claim that the app's `DiffView` adapter is already compiled.

The rebuilt package passes the complete Swift-free, non-root installed runtime suite at
`out/bundle-smoke/runtime-structural-rows.Qz1fl9aB`, including delayed GTK admission, workspace,
composer, both document journeys, large outline, terminal restoration, live-child reinstall and
desktop entry. Installed inserted/narrow/tail captures were inspected; middle/inserted decoded
RGBA buffers match exactly. The insertion changes 66 rows to 67 while retaining the same 12 live
cells and 33 cumulative configurations. Installed first presentation took 0.316 seconds for
automatic rows and 1.843 seconds for the whole-page diagnostic; these are different workloads.
The package SHA-256 is `ecdc19aa1a52dbe63bd02192c1afdab50bfc2d08392c6c96da276dc5cf435976`.
Shipping-configuration table/outline contracts, all production-source copy checks, theme and
main-actor boundaries, shell syntax and 12 local runner/worker contracts pass. No Mac source or
baseline changed in this step; the preceding showcase's pending baseline review remains pending.

## 170. Native diff drawing exposes and fixes priority precedence

The exact pinned NativeDiffAppKit renderer now builds in a distinct `LinuxNativeDiffAppKit`
target with an explicit dependency on the shim. The executable aliases its original module name;
the renderer body is unmodified. `vendor-diff.sh` verifies its source/license hashes and matching
NativeDiffKit resolution. The preview package includes the MIT license.

The missing six system color names now resolve by appearance from sRGB values sampled from
Mac AppKit 26.5 (25F71). These are platform fallbacks, not app palette policy. Backing-layer
backgrounds draw before view contents under the view's existing bounds clip and alpha. The
clipping fixture covers nested fills, ordering, inherited clipping, alpha, layer copying and
removal in both coordinate orientations. This is background support, not a complete Core
Animation compositor or animation implementation.

The existing diff theme adapter moved into `UI/Design/`; its body is unchanged, with visibility
made internal so other files can use it. ThemeContrast moved byte-identically into a standalone
color helper, and the DesignKit shared-source link follows that extraction. Linux links these
files plus exact `DiffInk`, `PerceptualColor` and `NSColor+Terminal` sources. Its existing environment
adapter supplies checked theme roles, diagnostic type scale and default contrast preference.
The focused Mac palette/OKLCH/theme/snapshot selection passes all 29 tests.

An Edit envelope and successful result pass through the production parser/timeline on a worker.
The native diagnostic mounts its authoritative eight-line diff inside the shared conversation
host. Initial capture showed a too-narrow diff: its text field was 455 pixels wide in a pane that
owed it 644. The same host/renderer on real Mac AppKit uses its full 344-point content width.
The shim's objective treated numeric priorities as proportional weights, allowing many weak
hugging constraints to outweigh one stronger width constraint.

Simplex now compares distinct priority tiers lexicographically, preserving unit-cost error
minimization within each tier. Artificial variables have their own highest tier, replacing a
finite large weight; retained-basis dual updates compare vector ratios too. The portable fixture
matches Mac AppKit for 1/8/32 weak constraints against priority 251, warm shrink/restore and a
required bound. Existing layout, clipping, indexed/automatic/structural table and large-outline
contracts pass. Earlier weighted-priority explanations describe the original implementation,
not the repaired priority contract.

Rendered inspection also found Pango adding synthetic hyphens during character wrapping.
Plain/attributed layouts now disable insertion, matching AppKit's default zero hyphenation factor.
The focused bridge contract equates wrapping with authored three-character line breaks. Removing
the correction reproduces the failure: 75 pixels of height instead of 60 for both text paths.

The final source native journey passes at `out/native-diff-final.liOCQdxi`: exact row-wash pixels,
Unicode copy, read-only text, live theme refresh, full pane width and narrow reflow. Its normal and
narrow captures were inspected. First presentation took 0.382 seconds; no matched latency
improvement is claimed. The new priority, layer and paragraph contracts run in the bundle build
gate, and the installed runtime runner includes this diff journey.

The canonical Mac native-chat showcase captures all 52 variants and exits 3 for 48 unbaselined
and four changed images. Compared with the preceding run, decoded differences are confined to
the animated 36×36 activity indicator; transcript pixels match. The accepted-image differences
still include the model-label change and its control offsets. No baselines were changed. The
report is `.build/ui-evidence-reports/20261006-032835-23841/report/`.

Full ToolCallView/app DiffView/controller integration, transport-backed conversations and
large-diff tokenization/materialization remain open. The bounded diagnostic does not establish
those paths or a complete large-transcript latency bound.

The final package passes the complete Swift-free, non-root installed runtime suite at
`out/bundle-smoke/runtime-native-diff.nPCqTDG6`, including all three document/diff journeys,
workspace/composer, GTK delay, large outline, terminal restoration, reinstall and desktop entry.
Installed light/dark/narrow diff captures were inspected. The Unicode field is 644 pixels wide
normally and 364 when narrow, its height reflows from 83 to 137 pixels, and only one row host is
constructed. Installed first presentation took 0.317 seconds for the diff and 0.313 seconds for
automatic Markdown rows. The whole-page Markdown diagnostic took 4.292 seconds, so its cold
layout remains unresolved; none of these different workloads establishes a speedup.
The package SHA-256 is `e26c12ef6b672fc26c96613c6e2bd078455089b4d73bd9b26251bdabb515a90c`.
Source-copy/license verification, shipping priority/layer contracts, paragraph/Markdown contracts,
theme/main-actor boundaries, shell syntax and 12 local runner/worker contracts pass.

## 171. Shared views observe production app events on Linux

Shared Design views (`MarkdownView`, `ConversationDiffView`, `PaneHeaderView`, `ThemedControl`
and `ThemedButton`) observe theme, profile, accessibility and backdrop changes through
`AppEventObservations`. Linux previously linked a no-op stand-in, so none of those observers
ran; only views the host explicitly invalidated could follow a theme change. The preview and its
focused icon/pane/page/subagent fixtures now link the unchanged production `AppEvent.swift`, and
the four Linux event declarations conform to `AppEvent` with the production notification names.

Linking the real file exposed a corelibs difference. An observer registered with
`queue: .main` makes `post` add a block to `OperationQueue.main` and wait for it. When the Linux
main actor already occupies the main dispatch queue, corelibs does not identify that as the
current operation queue, so a post can wait on the executor that is meant to run it. On Linux the
shared file now observes without an operation queue: a post already on the main queue delivers
inline under `MainActor.assumeIsolated`, and a post from anywhere else crosses with
`DispatchQueue.main.async`. macOS keeps `OperationQueue.main` delivery unchanged.

Asynchronous delivery made a second fault reachable. `removeAll()` removes the tokens, but a
worker post already queued for main would still have run its handler afterwards. Each
`AppEventObservations` now advances a generation on `removeAll()`, and every handler checks the
generation it was registered under, so a retired popover or panel generation cannot receive a
late event while the owner stays reusable.

`WindowHarness --app-event-contract` checks main and worker delivery, removal, reuse,
queued-generation cancellation and owner lifetime, including a worker post that must not block
on the occupied UI executor. It runs in the bundle build gate and the installed runtime suite;
the runner mock asserts that invocation. `AppEventDeliveryTests` checks the same observable
contract on macOS.

Verification on 2026-10-06: the Linux contract passes in Debug and in the shipping
`-c release --static-swift-stdlib -enable-testing` configuration. The macOS Debug app build,
including the repository boundary lints, succeeds, and seven focused Mac tests pass
(`AppEventDeliveryTests`, `ClaudeStreamContentTests`, `PortableConversationContractTests`).
Release native document, automatic-row and diff journeys pass under `xvfb-run` at
`out/llk-document_ui`, `out/llk-automatic_rows` and `out/llk-diff_ui`; their first frames took
4.316, 0.369 and 0.378 seconds. The live dark diff and dark document captures were inspected.
The same three journeys timed out or missed their selection receipts against a Debug build;
that configuration is not the one these journeys verify. The complete installed suite was not
rerun for this step.

The focused `IconButtonHarness`, `SubagentRowHarness`, `PaneHeaderHarness` and
`PageTitleHarness` targets do not build. Their shared theme boundary has referred to
`LinuxTheme` since the live light/dark theme step, but those targets link neither that file nor
its bundled snapshot. This predates the app-event change and is addressed separately.

## 172. Focused fixtures build again; stacks follow AppKit's equations

`IconButtonHarness`, `SubagentRowHarness`, `PaneHeaderHarness` and `PageTitleHarness` had not
compiled since the live light/dark theme step: the shared theme boundary they link reads
`LinuxTheme`, which those targets lacked along with its bundled snapshot. `LinuxTheme` now asks a
one-line `LinuxThemeSnapshot` locator for the file. The native window's locator returns its
resource; the fixtures link `LinuxTheme` with a locator that reads the same checked export from
the source tree. The selected-row fills moved from the sidebar host's vocabulary into the theme
boundary that reads them, so a target linking that boundary needs nothing else. The fixed-palette
subagent fixture states its own selection ground. `LinuxTheme` also compiles against macOS
AppKit now, where `NSAppearance(named:)` is failable and the shim's `components` helper does not
exist, so the subagent fixture's `--mac` reference renders again.

Once the four built, two fixtures failed. Both failures were older than this session, hidden
while the targets did not compile, and each was bisected on Linux.

The icon-button fixture expected the deferred `⋯` glyph to draw three dots on the first render.
It passed until `9b10cca34` (views clip to their bounds), and only because the glyph view, still
zero-sized, drew outside its frame. The glyph materializes in its button's first `draw`. Its new
intrinsic size is solved by the next layout pass, as in AppKit, so the fixture now asserts
materialization on the first display and the three dots on the second. Production rows
materialize their glyphs on reveal, before display. The native host repaints on its own dirty
flags, though, not on `needsLayout` raised during a draw, so a glyph left to materialize in a
draw would wait for the next input event. That gap remains.

The subagent row put its title 22pt below the row's top edge where AppKit puts it 8pt below.
This started with `8c68bfaca`, which made every vertical stack pull its last view to the bottom
edge at priority 50 so a centred stack could find its natural height. The row's heading is a
horizontal stack with no cross-axis hug of its own, so stretching it cost nothing, the solver
broke the tie by stretching it, and the title centred inside the taller heading. Dumping
AppKit's own constraints on macOS 26.5 (identifiers `NSStackView.Edge`, `.Edge.Min`, `.Stack`,
`.Align`, `.Distribution.EqualSizing`) gives the recipe the shim now follows:

- Gravity areas are the default distribution. The trailing edge hugs at the stack's hugging
  priority (250) inside a required bound; `.fill` and `.fillEqually` make it required, and
  `.fillEqually` equalizes sizes at 260.
- Across the axis, every view stays inside the stack's bounds (required), hugs both inset edges
  at the stack's perpendicular hugging priority (250), and aligns at 260. Baselines align at 260.
- `huggingPriority(for:)` and `clippingResistancePriority(for:)` exist with AppKit's defaults
  (250 and required), because production code sets them on stacks.

Within a priority tier the solver minimizes summed error, so a nested stack hugging three children
costs three times its stretch, against one for the list's bottom hug, and spare height collects
below the rows. That is the behavior on macOS. A probe of a heading holding one child shows
AppKit tying in the same way, with the same result as the shim.

Two departures are deliberate. An alignment that pins an edge replaces that edge's hug,
because it is the same equation stated more strongly. And the leading edge and spacing stay
required equalities rather than AppKit's 750/749.99 behind required inequalities: those two
extra rows per view cost 58% more on the document page on the incremental solver (§173), and
no mounted view depends on them yielding. A layout that needs AppKit's leading edge to give way
to a stronger constraint will differ.

Verification on 2026-10-06, all in one Ubuntu arm64 container:

- All four fixtures pass, and so do the layout Harness, view clipping, priority tiers, paragraph
  wrapping, the 5,100-project outline, table heights, text label/editor, search match,
  Markdown, glyph, floating glyph, and the project/session/terminal row-layout and app-event
  modes of `WindowHarness`.
- The stack and production `ControlRow` contracts pass on Linux and against macOS AppKit.
- The subagent row now matches its Mac reference at `out/llk-subagent-row/rows.png`, and the
  Mac reference passes again.
- Release document, automatic-row and diff journeys pass.

The pane-header and page-title `--mac` modes still fail. Production `Design.Surface` is
nonisolated, nested inside the `@MainActor` `Design`, but the Linux boundary declares its
`Surface` `@MainActor`, and macOS rejects a default argument that reads it. That predates this
work.

The default, full `window-smoke.sh` journey also fails, at "selection did not reach Gamma". Its
click at (100,160) lands on the second project row since the 41-point pane header moved the
rows down. A Debug build of the original shim fails the same step with identical pixels, so this
is a stale fixture coordinate, not this change; it is not repaired here. The same capture shows
the selected-row plate starting 12 pixels right of the project icon, which an earlier installed
capture also shows. That is a separate, existing navigator geometry defect.

## 173. The layout solver carries its objective and pivots sparsely

The lexicographic simplex recomputed every priority tier's reduced costs from the basis on each
iteration, in both its primal and its warm dual loop, at several times the cost of the pivot.
Each pivot also updated every column of each affected row. Reduced costs are now computed once
per solve and updated with each pivot like any other tableau row. They are recomputed exactly
before optimality is accepted, so accumulated rounding cannot end a solve early. Each pivot
collects the leaving row's nonzero columns once and updates only those, which leaves every
entry exactly as the dense loop would.

Three Release binaries from the same tree, run alternately three times each under `xvfb-run`,
give these first-presentation medians (detail in `docs/architecture/performance.md`, "Linux
layout solver objective and sparse pivots"):

| Journey | Original | Incremental objective | Final, with §172 stacks |
|---|---|---|---|
| Production document page | 4.169 s | 0.950 s | 0.479 s |
| Automatic Markdown rows | 0.314 s | 0.315 s | 0.315 s |
| Native diff row | 0.312 s | 0.311 s | 0.318 s |

The full AppKit stack recipe on the original solver took the document page from a 4.38 to a 9.66
second median. That measurement is what prompted this work, and it is why §172 keeps the
leading edge and spacing required. Every layout, priority, clipping, table, outline and stack
contract listed in §172 passes on the new solver. No per-solve timing assertion was added, and
Debug journeys were not re-measured.

The rebuilt package passes the complete Swift-free, non-root installed runtime suite at
`out/bundle-smoke/run.EJnmX5Kj`. That includes delayed GTK admission, workspace and composer,
all three document/row/diff journeys, the 5,100-project outline, terminal restoration,
live-child reinstall and the desktop entry. Installed first presentation took 0.475 seconds for
the document page, against 4.292 seconds in the §170 installed run, plus 0.317 seconds for
automatic rows and 0.259 seconds for the diff. Installed and source runs differ in load, so the
matched comparison above is the performance claim. The package SHA-256 is
`1047abafd8e1e39012d58941b94422bdc4fcd9835090189178007fd980e0923c`.

## 174. The production agent stream transport runs on Linux

`CoreSlice` now carries the exact `AgentStreamTransport`, the bounded pipe owner every native
conversation session uses: newline framing, parsing off the main actor, a capped stderr capture
that keeps draining, the ordered writer lane and its admission limit, and detach. It is
Foundation-only and compiled unchanged.

One contract source, `StreamTransportContracts.swift`, runs in `CoreSliceHarness` (and so in
the bundle build gate) and in Mac XCTest as `PortableStreamTransportContractTests`. Unlike the
existing Mac tests, it drives a real `/bin/sh` child through `Process`. The child writes:

- a line split across two writes 50 ms apart, then a malformed line;
- a 300 KiB stderr flood, more than any pipe holds;
- a single 1 MiB JSON line;
- a Unicode message echoed back from stdin.

The contract then closes stdin, waits for exit, and checks that `finish` returns exactly the
first 64 KiB of stderr. Separately it checks the newline-free output bound, write refusal after
failure, and that a detached transport delivers no line it had already parsed. These are the
corelibs paths that differ from Darwin: `FileHandle.readabilityHandler`, `Process`, `readToEnd`
and main-queue delivery.

Two platform facts shaped the contract rather than the transport. First, pumping `RunLoop.main`
is not a portable way to receive main-queue work. On Linux, corelibs' `run(mode:before:)` waited
in its descriptor poll far past its limit date, even with a timer scheduled, until something
else was enqueued. The contract awaits instead, which services the main queue on both platforms.
Second, after an async main on Linux the main actor's queue runs on a dispatch worker, so
`Thread.isMainThread` is false there even for correct delivery. The transport enters every
callback through `MainActor.assumeIsolated`, which traps off the main actor; that is the check
that holds.

Verification on 2026-10-06: the contract passes three consecutive times in Debug and three in
the shipping Release configuration on Ubuntu arm64, and the complete `CoreSliceHarness` passes
with it. On macOS the same contract passes in XCTest beside the five existing
`AgentStreamTransportTests` and the two portable conversation contracts, with no new compiler
warning. This is the transport only. `ClaudeStreamSession`'s launch planning, child-process
ownership, control channel and permission brokering are not yet compiled for Linux.

## 175. A live stream-json child feeds the shared conversation rows

`WindowHarness --stream-ui-fixture OUTPUT AGENT [ARGUMENTS...]` launches a child speaking Claude
Code's headless stream-json wire. Its output passes through the production `AgentStreamTransport`,
`StreamEvent.parse` and `ConversationTimeline` into the shared `ConversationVirtualRowHost` rows,
`MarkdownView` blocks and the pinned diff renderer:

- **Streaming tail.** One row, updated in place with `reloadData(forRowIndexes:columnIndexes:)`.
- **Settled content.** Markdown blocks and a successful Edit's diff insert above the tail through
  the incremental table APIs from §169.
- **Not mounted.** User messages, other tool calls and turn outcomes stay in the timeline without
  a row, because their production row kinds are not compiled for Linux yet.

The loop polls the native window every 16 ms and yields the main actor after every poll, so
transport deliveries run between frames.

`tests/stream_agent_fixture.py` is a deterministic agent with no network or provider. Its first
turn emits `system/init`, three text deltas a configurable interval apart, an assistant message
with Markdown and an Edit `tool_use`, the `tool_result`, and a `result`. A later turn on the
same process streams a delta and echoes the prompt. On stdin EOF it exits 0 after writing a
two-line stderr diagnostic. `tests/stream_conversation_smoke.py` checks:

- the partial reply on screen, by an X capture's pixels, while the turn is still unsettled;
- the settled turn: 7 wire lines, 3 streaming updates, 4 Markdown blocks, one diff row, the
  reported model and a completed outcome, with no malformed line or transport failure;
- an exact Unicode copy from a transport-fed paragraph;
- a second turn on the same child after F10: 10 lines, and the Unicode prompt echoed;
- after F11, stdin EOF, exit status 0, and the agent's diagnostic returned verbatim by `finish`.

The shared transport contract from §174 also gained a second-turn case: after output has
flowed, one line, a pause, then two lines at once.

The fixture's first version stalled on the second turn's first delta. It recorded the rendered
revision after each frame's awaited state write. Deliveries that ran during that await were
marked drawn and never painted, and with nothing further arriving the window stayed stale. A
temporarily instrumented copy of the transport, re-vendored afterwards, showed both remaining
lines read and delivered within milliseconds. The fixture now reads the revision before
building the frame. That was a fixture bug, not a transport one.

In Debug, frames take long enough that main-queue deliveries wait seconds behind them, and the
mid-stream capture missed the partial row. Pipe reads still landed within 5 ms of each write.
Like the document journeys, this one is verified in Release. The 4.5-second first turn
includes the agent's four one-second pauses, so it is not a latency measurement.

Verification on 2026-10-06: the journey passed in three Release runs on Ubuntu arm64; two more
runs' results were lost to my log filter. The partial, settled and second-turn captures were
inspected. The second-turn transport contract passes on Linux (Debug, three runs) and in Mac
XCTest. Strict runner contracts pass, and the installed runtime suite now runs the journey from
the packaged binary.

The rebuilt package passes the complete Swift-free, non-root installed runtime suite at
`out/bundle-smoke/run.B2qVTHkJ`, including this journey from the installed binary. Its installed
partial-stream capture was inspected and shows the reply mid-arrival. The same run repeats the
document, automatic-row and diff journeys at 0.424, 0.318 and 0.266 seconds to first frame, along
with the large outline, terminal restoration, live-child reinstall and the desktop entry. The
package SHA-256 is `7ef7d721078bb0f744ce98aceb692c2d314b590a3d445b920adac38ec8149e50`.

## 176. The pane-header and page-title Mac references build again

§172 left the `--mac` modes of `tests/pane_header/run.sh` and `tests/page_title/run.sh` failing.
Production `Design.Surface` is nonisolated: it is nested in the `@MainActor` `Design`, and that
attribute does not reach nested types. AppKit's compiler also reads `Design.Surface.accent` in
a nonisolated default argument of `drawKeyboardFocus`. The Linux boundary had declared its
`Surface` `@MainActor`, which macOS rejects at that default.

The boundary's `Surface` is now nonisolated, matching production. `LinuxTheme`'s palette lookup
is nonisolated too: its snapshot and named colours are immutable after first use, as
production's lock-backed palette is. The selected appearance and the helpers that read it stay
on the main actor.

Verification on 2026-10-06: the pane-header, page-title and subagent-row fixtures pass against
macOS AppKit. On Linux the focused sweep from §172 passes again, including all four repaired
fixtures, the layout Harness and the `WindowHarness` row-layout and app-event modes. The
installed suite was not rerun for this isolation-only change.

## 177. Backing-layer masks composite in the shim

The production long user-message bubble fades its last lines through a `CAGradientLayer` set as
its label's backing-layer mask. The shim had no gradient layer and no `CALayer.mask`. Storing a
mask without drawing it would show a full-strength collapsed message: the request accepted and
something different drawn, which these findings refuse elsewhere (§164).

A view whose backing layer has a mask now renders as an isolated group: its own fill, drawing
and every subview. Before the group rejoins its parent, under the parent's clip and opacity,
each device pixel's opacity is scaled by the mask's alpha at that pixel's centre. A pixel maps
back through the view's own transform into layer coordinates, so unit y = 0 is the top of a
flipped view and the bottom of an unflipped one. That matches the production fade's own note
that y = 0 is the first line of its flipped label. The fade is not compared with macOS here.
AppKit's offscreen caching does not composite layer masks, so no capture was taken.

Two kinds of mask are supported:

- **Axial `CAGradientLayer`:** interpolates its colours' alpha along `startPoint`→`endPoint`,
  with stated or evenly spaced `locations`.
- **Plain layer:** contributes its background alpha.

Outside the mask's frame everything is cleared, and a mask with sublayers is refused rather
than approximated. The group reuses the existing bounded transparency-layer tiles, so a masked
label allocates only the tiles it touches, within the same pixel cap. Unmasked views take no
new work beyond a nil check.

The clipping fixture checks the production fade in both orientations, against pixels:

- opaque ink at its start, 70% at the midpoint of its last quarter, and 10% just before its end;
- a subview faded with its parent, and view alpha applied on top;
- nothing drawn outside the mask frame;
- a half-alpha plain mask, and full ink restored after removal.

Verification on 2026-10-06: the fixture passes on Ubuntu arm64, and so does the complete focused
sweep from §172. The production bubble is not linked yet; that is the next step.

## 178. Shared-source integration with master on 2026-10-07

The branch is based on master `38c3cf104`. Its newer credential routing and project-cascade
write guard remain authoritative; partial Linux reads retain their separate whole-graph write
fence. The Linux core manifest contains 66 byte-identical production files, including credential
environment values, stored account-list normalization and automation workspace identity. The
last two values now have Foundation-only source boundaries; account selection and automation
activation stay in their existing host services. `ThreadingUsage` is the real local package.

Markdown grammar, inline styling and resolved style values come from three exact shared
`ThreadingMarkdownKit` sources compiled against the shim. This does not port Quick Look or its
HTML renderer. Updated menu metrics/rows, document table resizing, row arrival ownership and
sidebar glyphs retain master's implementations in the shared Design files. Glyph contrast repair
is an exact shared leaf; the app's theme registry and cached rung resolution remain on macOS.
The Linux preview keeps its checked palette, natural identity marks and overlay scrolling. It
retains animation values without claiming a Core Animation animation compositor. The dormant
compression probe is named `LinuxCompression`, so SwiftTerm cannot mistake it for Apple's
complete optional `Compression` framework.

The UI structure ratchet is reconciled against committed-tree inventories, rather than against
master's moving working tree. Master has 98 controllers, 125 platform views, 3,160 constraints
and 106 drawing sites outside Design; the rebased branch has 98, 124, 3,108 and 106. Its checked
ceilings match those actual counts. The previous branch's 85/118/2,805/96 counts predated the
additional master features.

Source Release validation passed core storage/recovery/migration contracts, conversation
reduction at 1,000/10,000 turns, stream transport and AppEvent delivery. Native diff, document,
automatic-height/incremental-row and live stream-json journeys passed in
`out/rebase-20261007.kieTFs`; document light, narrow diff dark and settled stream screenshots were
inspected. The Mac Markdown reference passed. These are source-binary checks; this integration
has not yet rebuilt or verified an installed Debian package.

The complete Linux Release product build passed. Icon-button, pane-header, subagent-row,
page-title, glyph, table/outline, priority, clipping, editor, wrapping and generic layout contracts
also passed. Fresh Linux and Mac Markdown snapshots match in all eight grammar cases.

The required `scripts/test.sh all` attempt compiled the Mac app and tests and recorded 2270
passed cases with no failed case receipt before the process guard interrupted it. The guarded
`proc_listchildpids` capture exceeded its inspection deadline; cleanup reported its directly
owned command still exiting. The complete Mac sweep and subsequent iOS simulator run therefore
remain unverified. No guard or test deadline was relaxed.

Focused Mac validation completed 144 tests (two skipped). It found one stale structural assertion
that still cast the shared terminal identity to `NSImageView` after master's migration to
`GlyphView`; the assertion now requires the actual shared glyph, preserving its identity, image
and geometry checks. Core database/account/automation, glyph legibility, Markdown, AppEvent
and conversation contracts in that selection passed.

The final Mac sidebar/project-create selection passed all 19 tests after the assertion update
and preservation of the project host's actual selection-ground callback.

## 179. Installed selection ink uses the row's painted face

The clean `cb3b113c2` archive and Debian package passed the complete Swift-free Ubuntu 24.04
arm64 runtime suite on 2026-10-09, including non-root desktop launch, live-child reinstall,
saved-terminal recovery, menus, composer, Markdown/diff/stream rendering and native input.
Rendered inspection still found an error those older assertions missed: in the dark saved-agent
picker the selected Codex mark measured only 1.060:1 at its strongest pixel; its title measured
3.734:1. Both were drawn against the picker's blue selection, while ink resolution was using
the theme's orange selection or the ancestor's ordinary surface.

The Linux navigator cell now uses `NSTableCellView` and passes the production
`SidebarHoverRowView.contentGround(for:)` to its shared project/session/terminal glyphs.
Standalone diagnostic rows that paint their own selection supply that explicit composited face.
The session and terminal Linux palette leaves resolve title and mark ink through `Design.Text.on`
using the same face. Template marks retain full opacity; dormant artwork keeps its existing
dimming. Selection, hover, runtime identity and actions remain host-owned; no new extension
surface is introduced.

The existing viewport bounds are unchanged: configuration touches mounted rows only, and one
weak ground callback per visible glyph reads its parent row. It performs no file, asset, process
or history work. The shared glyph's existing one-entry contrast cache still owns repair.

The new selected-title pixel assertion failed on the preserved clean package at 3.734:1. Source
Release saved-session Actions and provider/fallback journeys passed after the repair, and the
inspected matching dark screenshot measured glyph 4.862:1 and title 4.893:1. The provider journey
now asserts a 3:1 glyph floor and 4.5:1 title floor and changes light → dark → light while keeping
selection. Generic layout/render contracts, row layout, theme boundaries, architecture gates
and all 11 runner failure contracts passed.

The saved-terminal picker had the same title error: its selected title measured 3.734:1. The
terminal-content Linux leaf now accepts the actual row face without changing the Mac default
path. Its new pixel assertion passed through the 513-record/eight-runtime saved-shell journey;
the inspected title measured 4.893:1. The source row-layout and generic render contracts passed.
The session repair also passed a full installed runtime run in
`out/bundle-smoke/selection-installed.wh8e0a_g`, including the new light/dark/live-switch and
missing-resource contrast checks. The package containing both repairs passed the complete
installed runtime suite in `out/bundle-smoke/runtime-ink-final.61jpebbz` (Debian package SHA-256
`361c1071ec8be0543e1852fa06e5a9caf22fc9bc4bc353a310ecab00c1bb8031`). Its selected agent and
terminal screenshots were inspected. All 16 focused Mac sidebar render/icon-reuse tests passed.

Inspecting the live-switch provider screenshots then exposed an unselected-title regression:
the row had supplied a fixed composited light face when deriving both appearance variants.
The stronger all-title assertion reproduced it at 1.133:1. A weak appearance-aware row-ground
provider now resolves the painted face separately under each appearance before deriving ink.
The matched Release provider/fallback journey passed all title assertions through light → dark
→ light in `out/live-ground-after.AccCQu`; its dark product-shell screenshot was inspected.

The full Mac run also caught two integration gaps: the project-role fixture still cast the
shared identity mark to `NSImageView`, and extracting session content had dropped the provider
glyph's explicit accessible-image role. The fixture now looks up the semantic identity view,
and the shared session component restores the image role; the host still supplies its label.
The final Linux Release provider/fallback journey and shared session layout passed with that repair.

The complete Mac attempt ran 10,449 tests with 90 skips. Besides those two repaired cases,
`ThemedControlTests.testComponentGalleryCataloguesEveryConcreteDesignComponent` remains failing:
the gallery has no recorded coverage for `ConversationVirtualRowHost`, `ThemedProjectRowView`,
`ThemedMenuRowView`, `DiffView`, `PromptTextView`, `PromptTextScrollView`,
`ThemedTerminalRowContentView` and `ThemedSessionRowContentView`. That existing branch coverage
gap remains open. The complete iOS target passed 1,021 tests with one skip.

## 180. Clean rebased package and complete paragraph geometry

The clean `1959d2b2f4dd679453d9fca03825cdd284983234` Debian package and archive passed the
complete Swift-free Ubuntu 24.04 arm64 runtime suite on 2026-10-09. The manifest records that
exact revision and `source_dirty=false`; the Debian package SHA-256 is
`bbb0d6e9a9d0f6e739ca378b943b417bd6eb2a12468b56e921ec2f8a28409290`.
Evidence is in `out/bundle-smoke/clean-1959.llzvci_w`. The dark provider screenshot and saved
terminal screenshot were inspected, including unselected title ink after live theme switching.
The post-rebase Mac row/contrast/accessibility selection also passed all 20 tests.

Long conversation content still stops at the label leaf's 4096-byte/eight-line prefix.
`AppKitTextBridge/DocumentText.c` now provides a complete plain-text layout primitive, without
changing those existing label limits or claiming that expansion is connected. Preparation
validates the full UTF-8 value, shapes independent hard paragraphs with a private font map,
preserves first-strong and inherited neutral paragraph direction, and builds one indexed line
plan. Glyph overhangs participate in the paint index. A viewport raster uses binary search and
only intersecting lines; its A8 output is at most 2048×128 pixels. Hit testing returns complete
document byte offsets without scanning the document prefix. A plan has one serial owner; its
creation belongs on a bounded worker.

The scaling fixture uses 1,000/10,000 generated Unicode paragraphs (85,106/850,106 bytes), one
850,106-byte paragraph, and a 100,000-character unbroken token. A dedicated pthread owns the
plans while the caller remains available. Its independent reference uses whole-document Pango
layout. Head, middle and tail masks match byte-for-byte; pointer offsets match, including
combining text, Chinese, Arabic, emoji, RTL/neutral paragraph transitions, CRLF, empty lines,
four alignments and character wrapping. At most eight lines were painted in the stress viewport.

The first whole-document plan took 10.6 seconds to prepare 850 KB, and direct Pango did the same.
Splitting at Pango's paragraph boundaries reduced preparation to 384 ms while preserving pixels.
Seven warmed tail-raster samples measured 30.605 ms median / 31.062 ms max for whole-document
Pango and 0.065 ms median / 0.068 ms max for the indexed plan. The one giant paragraph prepared
in 337 ms and rasterized in 0.083 ms median / 0.086 ms max. These are Release C backend
measurements, not UI latency or application footprint claims. The retained plan still scales
with text and line count; integration must bound concurrent preparation, coalesce resize work,
discard stale deliveries and maintain a bounded viewport cache.

The Release WindowHarness build and existing TextLabelHarness contracts pass with the new bridge.
`tests/document_text/run.sh` runs the full reference comparison and stress measurements in a
fresh container; the package smoke's build lane runs it too. The primitive is not yet connected
to NSTextField, attributed long text, selection painting or the full user-message bubble.
The canonical fresh-container run passed in `out/document-text.VJJjWaB9`. AddressSanitizer and
UndefinedBehaviorSanitizer also passed all cases; leak detection was disabled for the reference
font stack's process caches. Those checks do not prove future aggregate cache ownership.

## 181. Complete selectable plain labels and the production user bubble

Unlimited selectable plain `NSTextField` now connects the complete paragraph backend through a
serial worker. Full UTF conversion, grapheme indexing, Pango preparation, hit testing, copy and
viewport rasterization stay on that owner. Main keeps recipe/sequence identity and pixels;
obsolete deliveries cannot replace the current viewport. Row intrinsic invalidation reaches
only the enclosing automatic table row, and the native document host observes window display
revision after yielding to asynchronous deliveries. Selection survives width changes and
collapse/re-expansion of the same source generation.

The worker admits one active job and at most 64 pending latest-label jobs. Plan retention is
8 MiB of source/64 owners, with one larger document alone; line geometry and grapheme indices
also scale with that source. The viewport LRU is 16 MiB with one oversized viewport allowed,
bounded to 8 Mi pixels/72 MiB for two RGBA planes and a selection mask. Pointer drags coalesce
absolute endpoints; keyboard/copy order is preserved. A keyboard flood and preservation of the
semantic reading position across reflow still need a complete ownership policy.

`CompleteLabelHarness` passes full head/tail rendering, whole copy, a multi-code-point astronaut
selection, rapid width changes and collapse/re-expansion. `TableHeightHarness` passes the
1,000/10,000-row automatic and indexed mutation contracts. The unchanged production
`UserMessageBubbleView` is linked into the document fixture through a narrow theme/font boundary;
its content inset uses the same `SurfaceDrawing.contentInset` kernel as Mac Design. The focused
Mac inset tests (15) and existing collapsed long-message render test (one) pass.

The first expanded native tail exposed monochrome emoji: using an A8 glyph mask discarded the
color font's intrinsic ink. Complete raster output now uses straight-alpha RGBA, with separate
ordinary and selected ink plus an A8 selection mask. Independent full-Pango RGBA and selection
comparisons pass at the head, middle and tail, including RTL/alignment cases.

The native user-bubble journey also exposed SDL dropping the activation click before the shim
received a press/release pair. The bridge now enables `SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH`, matching
the shared controls' first-click behavior. The same journey passed with this hint enabled and
its expanded light/dark tail screenshots were inspected: all text reaches the tail, emoji retain
color, and copy/Show less stay in the footer. Evidence is in
`out/user-bubble-clickthrough.OwlqUj`. The canonical build/runtime lanes include these contracts.

This integration covers plain selectable wrapping labels and the explicit user-bubble fixture.
Attributed long text, nonselectable unlimited labels, the ordinary host's asynchronous delivery
loop, full conversation controller and native provider transports remain separate work. The
clean package in §180 predates this integration and is not evidence for these new changes.

The final source build, with the activation-click hint set in code, passed the native bubble
journey in `out/user-bubble-commit.9iiXMS` and the complete-label contract. A rebuilt dirty-source
Debian package/archive then passed the entire fresh Swift-free installed runtime suite in
`out/bundle-smoke/complete-label.vxW2s9rf`; its installed dark expanded-tail screenshot was
inspected. The manifest records `1959d2b2f4dd679453d9fca03825cdd284983234` plus
`source_dirty=true`, and the Debian SHA-256 is
`c8146678c5b1e942b9db260e9266339ff5d48547a5c5ae42de5cac3ee16a9b7f`.
The 12 runner failure contracts and theme, architecture and main-actor latency gates pass.

The pre-commit `scripts/test.sh all` attempt completed 10,522 Mac tests with 92 skips and one
failure: the already documented Component Gallery catalogue gap from §179. No additional Mac
failure appeared. The runner skips its iOS lane after a Mac failure, so iOS was not rerun for
this checkpoint; the preceding clean-rebase iOS result remains the most recent evidence.

## 182. Complete-text delivery in the ordinary native workspace

The preceding complete-label integration could settle in the asynchronous document fixture,
but ordinary `WindowHarness.show` occupies MainActor in SDL's blocking wait. Scheduling only
a MainActor task there leaves complete-text metrics and pixels queued until some later event.
The shipping workspace now installs `NativeUIWorkLoop`: a serial complete-text worker queues
one receipt, pushes an SDL custom wake, and waits until the UI owner drains that receipt. The
owner drains before deciding whether to paint another frame. A completed receipt owes a frame;
ordinary idle waits and the existing runtime/deadline polling policy remain unchanged.

`NSWindowWorkerDelivery` enforces one pending receipt. The worker cannot outrun the UI with
MainActor tasks; its existing 64 latest-label pending jobs and source/viewport retention budgets
still apply. A wake captures an event type and window generation, never a window pointer.
Expired generations are ignored, and teardown drains a pending receipt before removing the
native host. Standalone shim contracts keep their ordinary MainActor fallback.
The native send is the thread-safe custom-event path documented by
[SDL_PushEvent](https://wiki.libsdl.org/SDL2/SDL_PushEvent).

`--ui-worker-contract` deliberately holds MainActor in the native wait while complete metrics
and viewport pixels arrive, observes display invalidation and rejects a stale window wake.
Its first assertion accidentally required a wake to be observed before the receipt became ready:
a startup expose can drain that receipt first. The contract now waits for both facts. The stale
wake check uses the real token from that closed window against a fresh window, accepting normal
expose/focus events while rejecting any admitted worker wake. It belongs to the installed runtime
lane, so it executes without a Swift toolchain.

This delivery boundary currently serves complete selectable plain labels. It does not make
other MainActor task sources run inside the synchronous workspace, nor connect full native
conversation transports/controller, attributed long text or semantic reading anchors.

The final static Release build passes the native worker and complete-label contracts. The
entire rebuilt package/archive runtime suite passed in fresh Swift-free Ubuntu 24.04 arm64,
including the installed worker contract, cached navigator during terminal output, blocked
persistence/input, native project actions, long-message expansion/copy, stream rendering,
provider rows, a 5,100-project outline, saved-terminal recovery, live reinstall and desktop launch.
Evidence is in `out/bundle-smoke/ui-worker.ah8qvWjU`; the resized workspace and dark expanded
user-message tail screenshots were inspected. The package manifest records
`b536e6a013fdeea70a77bfd3c3ddbae09f9eff6a` plus `source_dirty=true`; its Debian SHA-256 is
`34352c322f6f9580da069b8fd91e2dfe5e88fe18523a27b9bf5ab91f15b17505`.
Runner failure contracts (12), theme boundaries and main-actor latency gates pass. This checkpoint
changes only the Linux host/shim; the Mac/iOS suites were not repeated.

## 183. Shared native conversation transports compile and run on Linux

The CoreSlice manifest now includes the production Claude, Codex app-server and ACP sessions,
provider adapters, lifecycle ownership, transcript replay and execution audit. All 123 files are
copied from shipping sources without Linux-only replacement models. Foundation-only values and
readers were separated from host account lookup, session presentation and MCP registry ownership;
the Mac keeps those host conveniences and its existing permission broker.

`ChildProcessSpawn` now uses Linux posix_spawn actions, an exact descriptor allowlist, process
start identities shared with the daemon, and pidfd exit observation. The fallback still has one
waitpid owner. Native pipe writes suppress only their own thread's SIGPIPE, preserve an already
pending signal and restore the caller's mask. Hosted output uses a nonblocking writer with partial
progress, the link's existing byte admission budget and a five-second close backstop. Empty writes
settle without closing the pipe. The standalone child contracts check inherited descriptor refusal,
Unicode environment/cwd, process-group termination, 100 immediate children without double reaping
or pidfd leaks, bounded output/deadlines, queued partial writes through EOF, EPIPE and pipe cleanup.

`NativeConversationHarness` runs the actual four provider profiles against deterministic protocol
peers, both as local children and through the real packaged background daemon. Each completes two
Unicode turns in one process, checks durable ownership and exactly one EOF exit, and verifies Codex
permission denial followed by an explicit host approval. These tests need no provider credentials
or network service. Permission presentation and MCP admission remain host-owned: an unwired Linux
permission host denies, and an unwired MCP catalogue admits no tools. No new extension authority or
public customization surface was added.

The shared remote package uses Swift Crypto 5.0.0 on Linux, Foundation geometry and raw zlib
DEFLATE for ZIP/gzip. Apple Security's URLSession trust adapter stays Apple-only; the portable pin
decision fails closed but is not a Linux TLS client implementation. Independent Python readers
validate compressed Unicode ZIP/gzip, and the native remote contract checks recipient-only secret
opening and tamper rejection. The package includes the Swift Crypto license/notice and BoringSSL's
license from its recorded source revision. The first Swift-free install caught missing libcurl;
the Debian dependency list now declares libcurl, zlib and the C++ runtime explicitly.

Focused Mac lifecycle/replay/permission/ACP regression tests passed (141), as did the complete
remote-kit suite (276) and PTY-kit suite (81). Linux PTY-kit tests passed (81); Linux remote-kit tests
passed (276) using the repository's existing XCTest watchdog, with seven diagnosed upstream
setUp/tearDown deadlock retries. The watchdog also correctly refused a distinct real hang in the
new Linux unzip integration test's blocking Process.waitUntilExit. Awaiting its termination callback
fixed that test on both platforms; it is not handled as a watchdog retry. The native static
transport, child and remote contracts all pass and are included in the canonical bundle build lane.

The ordinary workspace still needs native conversation callback delivery, composer/permission
presentation and provider launch-plan integration. The existing stream document fixture retains
its narrower transport path. Long attributed text and the full conversation controller are also
open; this checkpoint does not claim that the native transports are mounted in the workspace.

The rebuilt Debian package/archive passed the entire fresh Swift-free Ubuntu runtime suite in
`out/bundle-smoke/native-ports.mGoif907`. The resized workspace and expanded dark user-message
screenshots were inspected. Its manifest records `b536e6a013fdeea70a77bfd3c3ddbae09f9eff6a` with
`source_dirty=true`; Debian SHA-256 is
`82bc11cb1b58e7acb5b82ac9a38454eb9eb4dffdcf9de7af6c4cead18fc170bc`.
All 123 core copies and the 12 runner failure contracts pass. The verifier now parses its manifest
once when checking unrecorded files instead of launching a full manifest pipeline per file.

The required pre-commit `scripts/test.sh all` completed 10,522 Mac tests with 89 skips and one
failure: the already documented Component Gallery catalogue gap, now listing nine components.
No additional failure appeared. This failure prevented the runner's iOS stage; iOS was not rerun
at this checkpoint. Native conversation UI integration remains open as stated above.

The branch was then rebased onto master's session-name-history and invitation-fragment fixes.
The two affected CoreSlice copies were refreshed. Post-rebase verification passed the full core
contract harness, all four local native conversation profiles, the static WindowHarness build,
the native worker wake contract and the three shared navigator row-layout contracts. Focused Mac
session-history, sharing, lifecycle and ACP tests passed (69), and the updated remote package's
Mac suite passed (277). The full installed UI evidence above predates this rebase; the rebuilt
window and focused contracts are the post-rebase evidence. The full Mac/iOS lane was not repeated
for these upstream changes.

## 184. Native conversation UI delivery and shared user-message anatomy

The normal workspace occupies MainActor in SDL's blocking wait. The native transports previously
queued their parsed lines, exit callbacks, deadlines and replay completions on the main executor,
which cannot run there. ConversationCallbackDelivery now names that host boundary explicitly.
The default keeps Mac main-queue/Task delivery; the Linux host can use its native wake mailbox.
Deadline cancellation covers both an unfired timer and an already queued UI receipt. Transcript
and subagent readers use the same injected boundary.

NSWindowWorkerDelivery now admits at most 64 pending operations. Worker receipt delivery waits
for capacity and then for the UI owner to run its operation, pacing each serial stream reader and
the shared deadline lane. Deferred launch/permission callbacks share that mailbox without waiting
on the UI owner. The workspace still admits at most eight running instances. Shutdown releases
pending receipts before removing the native window owner. This extends the text-worker-only
boundary from §182; a complete-text worker still owes only one receipt at a time.

Receipt pacing exposed an existing read-admission gap: FileHandle callbacks could keep queuing
raw chunks while their serial parser waited for the UI. AgentStreamTransport now bounds those
queued bytes at 32 MiB per transport and reports one typed outputBackpressure failure on overflow.
Framing's existing 16 MiB line limit and bounded diagnostic suffix still apply. This is explicit
failure rather than silently losing conversation events. The Mac contract holds the first UI
receipt while later bytes arrive and checks ordered delivery plus one fault. The native-window
contract drives a real child flood while SDL occupies the UI, then verifies the same bounded fault.

The native-window contract also drives the actual Claude, Codex, Grok ACP and Cursor ACP sessions
through two persistent Unicode turns, Codex permission replies, EOF, a silent ACP handshake
deadline and a deferred planning failure. These are native-loop callbacks, with no main-executor
poll or Task.yield in the occupied loop. The contract is included in the installed runtime lane.

ConversationUserRow now owns the unchanged production short/long bubble factory and its trailing
alignment. Its Foundation-only geometry/source thresholds are shared with ThreadingDesignKit and
Linux. The 600-character/8-line decision stops counting after the character threshold, rather than
walking an entire long message before choosing its collapsed presentation. The Linux document
source now uses this factory and preserves expansion by row identity. The production conversation
row factory also compiles against the shim; the host's fixed-theme font boundary supplies its
named roles. Eleven feature-owned constraint sites moved into Design, and the structural ratchet
was lowered from 3156 to 3145.

The long-message native journey passes collapse, full copy, expansion, head/tail, automatic height
and dark mode. A short-message journey checks right alignment, compact height, selectable Unicode,
absence of long-message controls and a live dark switch. Their current dark screenshots were
inspected in out/user-row-native-delivery and out/short-user-row-native-delivery. Focused Mac
transport/lifecycle/ACP/replay/content contracts pass (83), including the new bounded-backlog test;
all 124 CoreSlice copies and the 12 runner contracts pass.

The ordinary saved-session route still opens GraphicalTerminal: mounting the native conversation
controller/composer, preserving usesNativeUI in its runtime snapshot, launch-plan preparation,
permission presentation and full tool-row interaction remain next steps. These prerequisites do
not claim that native Chat is already selected in that workspace. Timeline ordering, launch and
permission authority remain host-owned; no extension capability or replacement slot was added.

Mac conversation evidence was captured with the ui-evidence-review workflow and compared to an
isolated checkout of e630f882819f2c775cea28e167ef8a141110eb44 using the same command. All ten
static fixture images match decoded RGBA exactly. The two live-plan images differ only in the
animated ThinkingOrb glyph (35×35 pixels in dark, 12×24 in light), which was inspected. The
stored baselines are older: their differences and missing newer captures were not approved or
rewritten. Current report: .build/ui-evidence-reports/20261009-094510-25102/report; comparison
report: /tmp/threading-before-native-delivery-e630/.build/ui-evidence-reports/20261009-095636-47772/report.

The corrected package/archive passed the full installed runtime suite in fresh Swift-free Ubuntu
24.04 arm64, including the new native conversation delivery/output-budget contract and short-row
journey. Evidence: out/bundle-smoke/native-callbacks.egLHw2hv. Manifest revision:
e630f882819f2c775cea28e167ef8a141110eb44, source_dirty=true. Debian SHA-256:
f7b4255c9bb644ac6c4d0340d3cf8caf602bf4c3813bde2ff6e910243c6ce190.
The initial package had an incorrect manually supplied provenance value; it was rebuilt with the
actual checked-out revision before this installed suite. The full Mac/iOS suite was not repeated
or a commit made at this iteration; the preceding checkpoint's gallery failure remains recorded
in §183. The ordinary native-conversation workspace route is still incomplete.

Inspecting the installed short-dark screenshot caught a fixture publication race after those
structural checks passed: state.json advertised the dark ready state before frame.png was replaced,
so the journey sometimes copied the previous text tile over the newly dark surface. The fixture
now publishes pixels before their ready-state marker. The short-row journey additionally requires
bright text pixels in the label region rather than trusting readiness flags alone. It passed again
in out/short-user-row-publication-fixed and its dark frame was inspected. The package above predates
this capture-order fix and is not final evidence for the strengthened journey; it must be rebuilt
and rerun at the next shipping checkpoint.

The package was rebuilt with the capture-order fix and tested again in fresh Swift-free Ubuntu.
The installed native callback/output-budget contract, long-message journey and strengthened
short-row pixel journey passed in out/bundle-smoke/native-callbacks.hz9CxYXT. The installed short
dark and expanded long-message dark screenshots were inspected: both have readable text, and the
long message retains its full tail and controls. Debian SHA-256:
7fafc2ce987819088f1bfa76b6e67ae91d39492c6e8ddb3c8118fc546dfcbf60.
Its manifest still names e630f882819f2c775cea28e167ef8a141110eb44 with source_dirty=true.
ThreadingDesignKit's nine tests and the 12 Linux runner contracts also pass.
The complete installed runtime suite finished successfully, including non-root startup, live
reinstall, saved-terminal recovery, native workspace/actions/accessibility and desktop entry.
The required pre-commit scripts/test.sh all completed 10,538 Mac tests with 94 skips and one
failure: the same nine-component Gallery catalogue gap recorded above. No other test failed.
The runner therefore did not enter its iOS stage; iOS remains unverified at this checkpoint.
The branch was rebased without conflicts onto 18c48627d (sidebar preference test isolation).
The changed PreferenceStore comment was synchronized into CoreSlice; all 124 copies match.
Post-rebase verification passed the static WindowHarness build, CoreSlice contracts, all four
native callback profiles and the UI-worker wake contract. The installed package evidence above
predates this rebase. A focused Mac rerun was stopped after its build made no progress in the
boundary-check phase for several minutes; those post-rebase Mac tests did not run. The full Mac
result above is the completed pre-rebase evidence; it was not repeated in a loop.

## 185. Saved native conversations mount in the ordinary workspace

The saved runtime snapshot now retains usesNativeUI. Selecting a native record opens a
WorkspaceConversationPane; terminal records still open WorkspaceTerminalPane. Both delegate
header, session menus and Open In to WorkspacePaneChrome and share the existing eight-runtime
cap. Retained native panes keep their draft, scroll position, timeline and child when switching
to another pane. This preview surface is deliberately host-only. The host continues to own durable
selection, account routing, launch admission,
provider identity and lifecycle; no extension replacement or execution authority was added.

NativeWorkspaceSession uses the production transports and timeline. Its serial worker reads the
saved record, then releases the store lock before account/history lookup and transcript parsing.
Markdown partitions are prepared on that worker; stable timeline locations replace tool results
without searching the transcript. Views are materialized only for the table viewport. Live row
preparation is capped at 64 jobs and 32 MiB; stream text uses the production plain streaming label.
Native wake receipts only invalidate the navigator when its own display revision changes.

Child launch, daemon admission and launch-record persistence run on the worker. The shared
ConversationPreparedChild hands pipe ownership to a transport once and retains an early exit
until its handler is installed. An abandoned preparation terminates its child. Existing Mac
callers keep their default launch path. Metadata writes check project, provider, account, native
surface and launch activity so an old pane cannot overwrite a later incarnation. Quit shares one
bounded detach deadline across retained native children.

The native pane mounts the production user-row factory, Markdown blocks, streaming/outcome rows,
PromptTextView and ThemedButton. Its table comes from ConversationContentTable in Design.
The shim now implements bounded editable select/copy/cut/paste through the native pasteboard.
Editor insets and the real caret feed the native input-method rectangle. Two defects were found
through real-shell evidence: the text.bubble symbol lacked adapter artwork and trapped, and an
unconstrained Auto Layout status label displaced a manually positioned pane. Explicit symbol
artwork and consistent layout ownership fixed those causes. Captures now wait for worker row
preparation and plain-text viewport pixels, including after a dark switch.

The deterministic ordinary Codex journey passed three Unicode/multiline turns on one real daemon
child, native prompt copy, draft/pane retention across a terminal switch, dark appearance, durable
provider identity, restart replay and same-thread resume. The peer writes the provider's admitted
dialogue records rather than response-item copies, which the production replay reader deliberately
ignores. Evidence: out/native-workspace-prepared-child. Ninety focused Mac launch/lifecycle/ACP
and prepared-child tests pass, as do the 12 Linux runner contracts and all 125 exact core copies.

The final package's focused native journey passed at out/native-workspace-packaged-stop. Captures
are 1120×900: the fixture now resizes after selection and moves the window onto the Xvfb screen,
because ImageMagick silently clipped an enlarged centered window. Inspected full-height evidence
exposed a narrow user bubble and inconsistent dark-switch colors in the sidebar/status/user text.
These are outstanding visual defects; the functional fixture is not visual parity evidence.

The installed suite first failed to discover an SDL window after reusing an X display. Fresh and
sequential focused Actions checks passed. Keeping that shared test display alive with -noreset
let the rerun pass startup, live reinstall, workspace, session Actions, Open In, catalogue,
project Actions and composer journeys. It then failed document_ui_smoke.py's native arrow-in-gap
assertion. That failure remains unresolved, and the later installed lanes did not run.
Manifest: 9ea2ab6a9e9aeefe9bff8ac2452c700cf0cb8905, source_dirty=true. Final Debian SHA-256:
ce577d33835ef4f4224df0af2fcb087412df79cfb9276a9635ef17637f847980.

The required scripts/test.sh all attempt caught stock table construction in the new Design
factory. It now constructs ThemedTableView, with the Linux transparent table adapter. The corrected
run passed repository boundaries and the Mac app build and started tests, then was stopped with
exit 143 at the user's requested pause. It did not complete the Mac suite or enter iOS. The prior
full suite's gallery failure remains recorded in §184; the ninety focused tests above passed.

The ordinary Claude plan is available but its UI journey is not verified. Full tool disclosures,
permission presentation, questions, the other providers' workspace launch routes, complete native
accessibility, worker-side replay reduction and the full production conversation controller remain
open. This checkpoint does not claim production UI parity.

## 186. Installed-suite cursor ordering and retained menu rows

§185's installed suite stopped at document_ui_smoke.py's arrow-in-gap check. The cause was the
test display, not the cursor policy. The installed lane keeps one Xvfb display alive with
-noreset, so each journey starts with the pointer where the previous client left it. A window
mapped under a stationary pointer set its cursor before any pointer motion, and Xvfb then showed
later cursor changes only after the pointer moved again. The arrow reference could therefore be
read before the window's own cursor reached the server. On that shared display about one run in
three failed; a fresh display never did.

`NativeCursor.park()` now warps the pointer to the root window's corner before a journey starts
its window, so the pointer always enters through motion, as on a fresh display.
`NativeCursor.settled()` takes a reference cursor only after two spaced reads agree, because a
client's cursor request reaches the server only when that client next flushes. Composer and
document journeys use both. Eight consecutive document runs on one -noreset display passed,
against roughly a third failing before. Only test code changed.

The rerun then passed composer, document, user bubble, stream and native workspace, and failed
at the installed account picker, 4/4 in the package. The navigator rebuilt its menu rows on every
frame: `ThemedMenuRowPlan.row(at:)` constructs a new `ThemedMenuRowView`. A press that moved the
highlight caused a redraw, and the release reached a fresh row that had never seen the press, so
`onChoose` never ran. AppKit keeps a menu row's view for as long as the menu is open.
`RetainedMenuRows` keeps the visible page's rows across frames while the menu kind and every
entry's title, help, enabled and selected state match. A changed menu builds fresh rows. Only the
visible page is retained. The Actions menu and the account picker both use it, and
`Specimen.mountMenuRows` keeps rows that are already mounted instead of detaching them all.
After repackaging, the installed account picker passed 4/4.

## 187. Native workspace bubble width, row heights and dark-switch evidence

The narrow user bubble recorded in §185 had two causes.

The first was in the shim. A wrapping label's intrinsic width came from its last layout width, so
a squeezed measurement became permanent. An AppKit probe in a real window showed that a
wrapping `NSTextField` under Auto Layout with no `preferredMaxLayoutWidth` reports its
single-line natural width as its intrinsic width (186pt for the probe string), however it was last
laid out, and that the bubble grows back after the pane widens. The shim now does the same:
`intrinsicContentSize` uses the unwrapped natural width whenever the label wraps at its layout
width. The complete-text path takes the widest raster line when the text wrapped. Bounded labels
cache one unwrapped measurement, which appearance or text changes clear.
`CompleteTextMetrics.wrapped` records whether any paragraph took more than one visual line.

The complete-text worker returns a label's size after its row has been measured. On macOS a
wrapped size is known when the row is measured, so nothing re-measures later. When a worker
result changes a label's size, the label now finds its enclosing automatic-height `NSTableView`
and calls `noteHeightOfRows(withIndexesChanged:)` for its row: the same call a Mac caller makes
after a content change.

The second cause was in the pane. `WorkspaceConversationPane.refresh` updated the column width
only when the table's frame width differed from the viewport. The clip view had already sized the
table, so the column stayed at the shim's default 100pt. `ConversationVirtualRowHost` states the
column width as each host's own width, so every user label was measured at 100pt, squeezed to
39pt and committed. The pane now also compares the column's width. The bubble renders on one
right-aligned line and rows are spaced correctly
(out/llk-native-ws/native-first-reply.png). Making the measuring pass include the root's own
superview constraints was tried and reverted: the host's width constraint is already installed on
the host itself.

The dark-switch color defects were in the test, not in rendering. `native_workspace_smoke.py`
waited on `ready(2)` and on `'dark=true'` in the last frame, each from its own read of the log.
`ready` could accept the last light, prepared frame from before the switch while the second read
found the first dark frame, which still drew the previous rasters and was not yet prepared. The
capture then showed the stale state: light sidebar, light-mode ink on dark surfaces. Five
repeated runs captured it 3 times. A capture 1.5s later was correct every time, and a draw-time
probe showed the status ink resolving to the dark palette (white, alpha 0.7). `ready` now judges a
single frame from a single read, including its theme. The dark capture must also show a dark
sidebar ground and light status ink, measured with ImageMagick, so a retained light-mode ink fails
the journey rather than only appearing in the picture. The disabled prominent Send button's dark
title matches its dimmed light-on-accent ink; that one is not a defect.

With the race fixed, the restart replay waited forever in 3 of 3 runs. After restart the window
was briefly 480px tall, and the pane's readiness walk included a retained row scrolled out of
view. That label never draws, so it never requests a viewport, and
`isWaitingForCompleteTextViewport` stayed true. A label hidden or clipped out by every ancestor
now awaits nothing, because a viewport is requested only when the label draws.

The native workspace journey passed 3 of 3 runs with the dark assertions
(out/llk-native-ws). Document, user bubble and short user row journeys passed from the same
Release build. All 20 focused harness lanes passed, as did the 12 Linux runner contracts. All 125
exact core copies and the AppKit vendor copies verify.

## 188. The ordinary Claude journey and a green installed suite

`native_workspace_smoke.py` now takes an optional provider. Its Claude peer speaks the headless
stream-json wire: it answers the `initialize` control request, then for each turn emits
`system/init`, a partial text delta, the assistant message and a `result`. Like the real CLI, it
writes the dialogue to the account transcript under the project's slug. The peer asserts the
production stream flags, a fresh launch's `--session-id` and a restart's `--resume` of the same
id with its transcript present. The ordinary Claude journey then passed the same checks as Codex:
- three Unicode/multiline turns on one daemon child, with draft and pane retention;
- the dark pixel assertions;
- the durable provider identity, restart replay and same-thread resume.

It passed 3 of 3 runs (out/llk-native-ws-claude); Codex passed 4 of 4 with the parameterized
script. The installed runtime suite now runs both providers. The full run below predates adding
the Claude lane.

The full installed suite passed end to end for the first time since §185, with 121 PASS lines and
exit 0. That covers startup, live reinstall, the workspace lanes, session and project Actions,
Open In, catalogue, composer, document, user bubble, stream, the native workspace, account
picker, project count, native outline, terminal restart and the desktop entry. Evidence:
out/bundle-smoke/run.wo7hwjMu, log out/llk-bundle-smoke4.log. Manifest:
964d50fedf48331bceab800b3a3e1513ee14a0e3, source_dirty=true. Debian SHA-256:
7db9670232881689e8991149fe1765b57b76da3b816d0adf4c0da41f53985fa2.

Permission presentation, questions, full tool disclosures, the other providers' workspace launch
routes, complete native accessibility and the full production conversation controller remain
open. This checkpoint does not claim production UI parity.

## 189. Native permission requests use the production card

Linux answered every native permission request with a refusal:
`ConversationPermissionDecision.decide` had no presenter. Codex and ACP ask through that seam, so
any command or edit outside a session's mode failed without asking anyone.

The automatic answers lived inside the Mac's `PermissionBroker`, beside system-grant briefing,
the audit store, unattended runs and `ProjectStore`. `PermissionPolicy` now holds them in a
Foundation-only production file: read-only tools and commands, Allow for Session, then the
session's mode. Both hosts call that function. Its one host-owned input is the inventory of
Threading MCP tools the host serves. The Mac passes its built-in registry through overloads
beside the broker, so its callers are unchanged. CoreSlice vendors the policy and
`ShellCommandPolicy` byte-identically. A new Mac test locks in that a host serving no MCP tools
gets no preapproval for their names.

The Linux host's `PermissionBroker` applies the shared policy and queues what remains on the
retained `NativeWorkspaceSession` that raised it; with no live session it refuses. The session
answers one request at a time and re-checks the rest of the queue when one is answered, as the
Mac does, because Allow for Session can settle requests already waiting. Pending requests are
denied when the agent exits or the session closes. The pane mounts the production
`PermissionRequestView` as the transcript's last row; `DocumentRowSource` keeps that card after
the streaming and settled rows. The status reads "Waiting for permission" while a card waits, as on the Mac.

The card links unchanged. `ConversationDecisionHeader` and `FlippedClipView` moved into their own
production files so Linux can link them without the question card or the conversation
controller's support file. The card gained the established `#if os(Linux)` closure branch for its
three actions, and `makeButton` takes `Selector?`. Its paired-device and manager paths cross a
Linux boundary that makes the remote projection undecidable, so nothing but the card can answer.
The shim gained `NSScrollView.borderType`, which accepts only `.noBorder`, and a border-only
surface update. The `hand.raised` mark has Linux artwork; its absence trapped the first run,
the same class of gap as `text.bubble` in §185.

Production `ThemedButton` takes the keyboard on click on the Mac as well, so after a decision the
composer no longer has focus. The journey clicks back into it, as a person would. The Mac is
inconsistent here: retiring a question card returns focus to the prompt when the card held it
(`ConversationViewController.removeQuestion`), while retiring a permission card does not. Linux
matches the permission behaviour; that choice is the Mac's to settle.

`tests/native_permission_smoke.py` drives a deterministic Codex app-server through the real daemon
in `manual` mode. In the first turn `ls -la` is accepted by policy with no card, and the
following `touch` raises the production card (out/llk-perm/permission-card.png). Return in the
composer does not answer it, and the pointer chooses Deny. In the second turn, Allow for Session
answers the `touch` and policy then accepts the following `rm` with no third card. It passed 3 of
3 debug runs and once from Release. The Codex and Claude native workspace journeys, document,
user bubble and short user row journeys, all 20 focused harness lanes, the native conversation
delivery, UI worker and app event contracts, and the 12 Linux runner contracts pass. All 127
core copies and the AppKit vendor copies verify. On the Mac, 118 focused permission, mode,
card, question, changed-files and conversation-render tests pass, and the build ran the
repository boundaries. `scripts/test.sh all` ran 10,543 Mac tests with one failure:
`testComponentGalleryCataloguesEveryConcreteDesignComponent`, the gallery gap recorded in §184.
It names nine components, none from this work. Because the Mac half failed, the iOS half did not
start. The installed suite now runs the permission journey.

Claude asks through its `PreToolUse` hook and Threading's HTTP listener, which the Linux host
does not run, so a headless Claude there still blocks the tools it would ask about. Questions,
full tool disclosures, the other providers' workspace launch routes and the full production
conversation controller remain open.

## 190. Editable text fields and native provider questions

The shim's `NSTextField` was a label: `isEditable` trapped, and there was no `init(string:)`,
delegate or placeholder. Every production form that takes typed input was out of reach,
including the question card. Its "Write your answer…" field is built whether or not it is shown.

An editable field now edits through a field editor, as AppKit's does:
- **Focus.** `NSWindow.makeFirstResponder` redirects focus on an editable field to a
  single-line `NSTextView`, placed inside the field over its cell's `drawingRect(forBounds:)`.
  `currentEditor()` returns it while it edits. Linux text input reaches whichever text view holds
  focus, so a card's field editor receives typing, composition and paste.
- **Notices.** The shim's `NSTextView` gained AppKit's `didChangeText()` hook. It runs after
  every user edit: typing, deletion, composition, cut, paste and undo. A programmatic `string`
  assignment does not call it. The field reports `controlTextDidBeginEditing` on the first change
  and `controlTextDidChange` on each change. `controlTextDidEndEditing` carries AppKit's
  `NSTextMovement` value.
- **Keys.** Return ends the edit, sends the action and keeps the editor with its text selected.
  Tab and Shift-Tab move along the key-view loop and commit. A typed or pasted line break becomes
  a space.
- **Placeholder.** It stays visible under an empty editor until the first keystroke.
- **Size.** An editable field has no intrinsic width; its height is one line.
- **Cells.** `NSTextFieldCell` is subclassable, with `drawingRect(forBounds:)` and
  `cellClass`, so the Linux `ThemedTextField` draws the production well through `ThemedSurface`.
  It uses the field fill, an accent border with an inner focus ring while editing, the 8-point
  text inset and the 32-point field height. Bevel materials, the outlined search style and hover
  presentation are not themed there yet. Long text is not scrolled to the caret within a field.

Swift does not run a class's own property observers inside its initializers, so `init(string:)`
applies the editable configuration directly. The first contract run caught a field that was
editable but not selectable, and therefore ignored clicks. The shim `NSTextView` also returned
early from drawing with an empty visible rect. A field editor in an unlaid-out card had converted
an infinite row index and trapped.

`tests/text_editor` now checks the field: focus lands on its editor, delegate notices arrive,
a line break becomes a space, Return sends the action and ends the edit, Tab moves and commits,
the editor leaves, and `abortEditing` works.

Codex asks questions through `item/tool/requestUserInput`; the production `CodexQuestionRequests`
already validated and answered them. `NativeWorkspaceSession` now holds the requests, bounded as
the Mac bounds them, and retires them when the provider settles them or the agent ends. The pane
mounts the production `ConversationQuestionCard`, which links with the established Linux closure
branch for its three buttons. The production `ControlRowView` and `ConversationChoiceRow` link
too. WindowHarness had been carrying placeholder `ControlRowMember`/`ControlRowMetrics`
declarations, which now apply only to the narrower harnesses. The shim gained the `textField`,
`radioButton` and `layoutChanged` accessibility vocabulary. The `questionmark.bubble`, `circle`
and `checkmark.circle.fill` marks have Linux artwork, the check knocked out with `.copy`.

`DocumentRowSource` keeps decision cards as a trailing block in arrival order. A card already
shown keeps its row, and nothing else reloads. Permission and question cards can wait together.
A question card that leaves while it holds focus returns focus to the prompt, as on the Mac. The
status reads "Waiting for your answer" while one waits.

The decision journey gained a third turn: a two-page question. The pointer picks Blue, moves on,
clicks the free-text field and pastes "Fixture 日本語 café". The provider then receives exactly
`{color: [Blue], name: [Fixture 日本語 café]}` (out/llk-perm/question-answer.png). The pane now
logs only enabled card buttons, so a journey cannot press Send answer before it can act. The
journey passed 4 of 4 debug runs and once from Release, beside both native workspace journeys,
the document, user bubble and short user row journeys, the three native contracts and the 20
focused harness lanes. On the Mac, the card's change is the original code under its `#else` and
`canImport(ObjectiveC)` branches. 79 focused question, permission, card, changed-files and
conversation-render tests pass after it.

The full installed suite then passed from the clean commit, with 123 PASS lines and exit 0. That
includes the Claude native workspace lane and this decision journey. Evidence:
out/bundle-smoke/run.esDD4pFR, log out/llk-bundle-smoke5.log. Manifest:
e775372e5872d311550e370f629b4763a3ad25a8, source_dirty=false. Debian SHA-256:
003c6c8c4ed8523fa58b89628efa5be9aa3bb4330a11e13f3cfa876fb537e252.

## 191. Integration with master and a complete component gallery

The branch was rebased onto master `9d4abe35b` on 2026-10-14; it had fallen 44 commits behind.
Shared documents were the only conflicts:
- **`performance.md`.** Each side had added its own paragraphs under the same headings. The
  base version confirmed that neither replaced the other's text, so both were kept.
- **`CLAUDE.md`.** Master's build-system wording and the branch's Linux-preview sentence were
  merged into one paragraph. The command list keeps every command.
- **`ClaudeTranscript.swift`.** It keeps master's new `subagentURL(childID:root:)`. Its
  `exists(sessionID:for:in:)` stays in the branch's `ClaudeTranscript+Host.swift`.

Five core copies changed on master and were refreshed. Two of master's additions reached the
portable core through host machinery, so each was split at the boundary the branch already uses:
- **Attachment detection.** Its content policy, `assistantTexts(in:)`, stays in
  `AttachmentDetection.swift` and joins CoreSlice. Recording a reference reaches the attachment
  store and its resolver, so it moved, with the worker actor, to
  `AttachmentDetection+Recording.swift`.
- **Subagent observer.** `SubagentSessionState` now holds an `any SubagentActivityObserving`
  instead of the concrete Mac attachment observer, which conforms. A host without attachments
  supplies none.
The manifest now holds 128 exact copies.

The branch-only `ui-structure` ratchet then failed. A per-file report of the pre-rebase and
post-rebase trees shows every new site came from master's own new code. Following the previous
integration's practice, `application-structure.md` names each upstream addition and the ceilings
moved to 103/125/3,208/107. The architecture, theme, mobile-theme and localization boundaries
pass.

The full Mac suite had one failure since §184: eight production views this branch moved into
`UI/Design` had no Component Gallery story. Master's own Mermaid story arrived with the rebase.
A new "Shared row anatomy" section mounts each extracted view as itself:
- **`PromptTextView` and `PromptTextScrollView`.** The editor network, with a working submit.
- **`DiffView`.** It is fed through the production `EditDiff` path.
- **`ConversationVirtualRowHost`.** Two hosts at different stated column widths.
- **`ThemedMenuRowView`.** Rows from one `ThemedMenuRowPlan`, with a receipt when chosen.
- **The navigator row shells.** A project row, a checkout with its actions shown, a conversation
  and a running terminal.
Their 19 strings have Swedish entries in the catalogue's canonical layout. The stories first added
10 constraint sites to the gallery, which sits outside `UI/Design`, and the ratchet refused them.
They now state their sizes through `NSView.fixSize(width:height:)` in `UI/Design`, beside the
existing `squareSizeConstraints`, so the ceiling stays at 3,208.

After the rebase, the Linux build, all 20 harness lanes, both native workspace journeys, the
decision journey, the document, user bubble and short user row journeys, the native delivery
contract and the 12 runner contracts pass from Release. All 128 core copies and the AppKit vendor
copies verify.

On the Mac, all 242 `ThemedControlTests` pass, including the gallery catalogue test. A
`scripts/test.sh all` run executed 10,744 tests with failures in four classes:
- **Not reproducible.** `HookLifecycleTests`, `MainWindowSizingTests` and
  `ThemedTabStripViewTests` passed when rerun by themselves.
- **Pre-existing.** The two `SimulatorPaneControlsTests` recording cases time out every time.
  They also fail on master `9d4abe35b`, run in a separate worktree on this machine, and this
  branch does not touch the simulator recording code.
Because the Mac half failed, the iOS half did not start.

## 192. Production tool rows and symbols drawn for their size

Linux had flattened every native tool call into one muted notice line, with its result appended
as text. The pane now mounts the production `ToolCallView`, as the Mac factory does. A tool call
is one quiet row: its glyph, the tool and its subject, and a size line such as "3 lines". A click
opens it to the output and closes it again. `DocumentRowSource` keeps which rows are open by entry
identity, so a recycled host rebuilds an open row open, and the table re-measures the row
whenever it opens or closes.

The view links with the established Linux branch for its click recognizer. Its Threading MCP
action names come from the Mac's built-in registry, which Linux does not compile, so that
lookup is guarded out there. The Linux host serves no Threading MCP tools, so every MCP tool is
named by its own tool name. A chart call has no Linux chart card yet and shows as its tool row.

The shim gained `NSClickGestureRecognizer` and its delegate. A press is offered to the
recognizers of the view it hits and that view's ancestors, after their delegates agree. The
press still reaches the view, so selectable text inside keeps working. The click fires on a
release inside the recognizer's view once the pointer has moved no more than AppKit's
four-point hysteresis. The tool row's delegate turns down presses in its open body, so its
output stays selectable. The shim also gained `NSView.trackingAreas`, and the Linux theme gained
the three tool-row tokens and `Design.Text.quaternary`.

The first open row drew a large, heavy chevron pointing up. There were two causes:
- **Size.** The symbol provider was a global that the placeholder pane installed at its
  36-point hero size. Every symbol was rasterized there and then only rescaled, and
  `NSImageView` ignored `symbolConfiguration`.
- **Direction.** The `chevron.down` artwork had its point above its arms on an unflipped
  canvas, so every chip's menu chevron had always pointed up (visible in §191's composer
  evidence).

Symbol images now keep their name, and `withSymbolConfiguration` asks the host to redraw them at
that point size and weight. `NSImageView` applies its `symbolConfiguration` the same way, which
also sets its intrinsic size. `LinuxSymbols` installs the provider once at window startup. An
unconfigured symbol still draws on the large canvas, so the placeholder hero stays sharp. The
chevron points down, and `chevron.right` has artwork. The glyph-view harness now asks a recording
provider for a configured symbol. It also checks that an image view's configuration sets its
size.

The decision journey's first turn now carries a real Codex `commandExecution` item for `ls -la`,
with Unicode output. The pointer opens its production row, checks that it grew, and closes it
from its header (out/llk-perm/tool-row-open.png). From a Release build the composer, decision,
both native workspace, document, user bubble and short user row journeys pass, as do the 20
harness lanes. On the
Mac, the view's change is its original code under the `#else` and `canImport(ObjectiveC)`
branches; 204 focused showcase, permission card, conversation render, extension renderer and tool
identity tests pass, and the build ran the repository boundaries. `scripts/test.sh all` then ran
10,744 Mac tests with one failure, `testClosingThePaneFinishesARunningRecording`, which also
fails on master (§191). The disk filled after the Mac half finished, which is what the run's
exit reports; the iOS half would not have started after a Mac failure in any case. An approved
storage cleanup reclaimed 20.7 GB.

## 193. The native sidebar is a pane, not the drawing specimen's framed window

The ordinary Linux window still used `Specimen.Window`'s rounded gray outline around the whole
sidebar. That outline was useful in the original standalone rendering laboratory, but it put a
second frame inside the native window: a line along the left and bottom edges and curved corners
where the Mac's sidebar continues to the window edge. The light-mode native capture reproduces
it in `out/parity-before-20261016/native-first-reply.png`.

The native build now fills the complete pane. Its host mounts one unchanged production vertical
`SeparatorView` at the trailing edge, using the theme's rule ink and border weight. The Threading
light/dark rule colors exceed the Mac split's 1.2 contrast floor against their conversation
grounds, so the rule is also the Mac split's first-choice ink for these surfaces. The standalone
`Harness` retains its diagnostic outline. This adds one retained view and three constraints per
window, independent of project/session counts; it adds no discovery, data traversal or workers.
It changes existing host-owned chrome, with navigation, selection and actions still host-owned,
and publishes no new extension component.

The new pixel check fails on the old native capture's left edge. It checks the flat outer edges
and full-height two-device-pixel divider in both appearances. The first rerun also exposed a
capture race: SDL had published the 900-pixel conversation while the sidebar still held its
480-pixel bitmap. Waiting for the conversation alone admitted that partial shell. Picker frame
receipts now include appearance, and the journey waits for both retained surfaces to report the
requested height and matching appearance before capturing. It does not retry pixel assertions.

The corrected light and dark captures are in `out/parity-verified-20261016`. This is a sidebar
frame correction: exact RGBA comparison of the first-reply and dark captures finds 4,924 changed
pixels in each, all on the sidebar edges, and no changed pixels elsewhere. The runner's 12
failure contracts, the standalone layout/render harness, theme boundaries and both source-copy
verifiers pass. The Debug native journey passed its light/dark edge checks but timed out waiting
for third-turn row preparation during concurrent clean compilation; that run is not a full
journey pass.

The optimized source build (`-c release --static-swift-stdlib -Xswiftc -enable-testing`) then
passed the complete native workspace journey, including both edge checks, Unicode/multiline
turns, the retained draft and daemon child, a terminal switch, restart replay and same-thread
resume. Its inspected captures and log are `out/parity-release-20261016` and
`out/parity-release-20261016.log`. This revision has not been run through the full installed
Debian bundle suite.

This is not a claim of complete UI parity. The source and captures still show the
simplified composer, missing sidebar gradient/well and incomplete window chrome; display-scale
geometry also needs a matched logical-size comparison.

The fresh Mac `sidebar-edge-reveal` evidence also passed and was inspected; its report is
`.build/ui-evidence-reports/20261016-201754-53131/report/index.html`. No baseline was approved.

## 194. The reply composer shares production prompt anatomy

The native reply used a fixed 72-point editor on an elevated plate and a separate titled Send
button. The Mac prompt is one field with its own footer, a compact send/stop glyph, a two-line
resting text area and a bounded growing viewport. `PromptChrome` now owns those existing Mac
policies, called by both `PromptView` and `WorkspaceConversationPane`. This is a shared source
symlink on Linux, not a second set of copied visual constants. The field uses the exported
Threading field surface; the Linux drawing leaf now preserves the supplied border width instead
of forcing every applied surface to one point. The return and stop symbols have supported vector
artwork at that leaf.

The Linux host mounts one retained composer, stack, footer, spacer and button. It reads the
editor's cached TextKit used rect to fit the draft, grows to the shared 180-point ceiling, then
scrolls. It compares scroller state before assignment to avoid repeated tiling. No files,
transcripts or provider discovery enter the layout path. Draft admission, marked-text handling,
submit/interrupt and permission decisions remain host-owned; this extends the existing host-only
conversation composer and adds no extension capability or replacement slot.

Focus callbacks report the new focus state before `NSWindow.firstResponder` changes. Reading
that property inside the callback painted the previous state's border; the host now retains the
callback's Boolean, as the production prompt does. The native journey moves focus between the
editor and sidebar and checks actual rendered border ink and exact four/two-device-pixel weights
at the fixed 2x backing scale. It also pastes a long draft, verifies the 360-pixel height ceiling
and scrolling, clears back to the resting height, and clicks the presented send glyph to submit.
Its startup waits for the first retained pane rather than selecting SDL's transient startup
window. The permission journey now focuses the editor from presented composer geometry, since
its old hard-coded point lies in the new footer.

The optimized native workspace journey passes with these checks, Unicode/multiline input, three
turns on one daemon child, retained drafts, terminal switching, light/dark appearance, durable
identity, restart replay and same-thread resume. Its inspected captures are in
`out/parity-prompt-review-20261016`. The permission journey passes denial, session approval,
opening/closing a tool row and a two-page question with an edited answer; its captures are in
`out/parity-prompt-permission-final-20261016`. The Mac's 63 `PromptInputTests` and eight
`ComposerWindowFitTests` pass. The 12 Python runner contracts and both source-copy verifiers pass.
The standalone rendering/layout harness passes with its specimen frame retained. The final
optimized Linux build succeeds. Mac `session-composer-layout` evidence passes, with the short
light System, tall dark System and short Swiss Minimalist renders inspected in
`.build/ui-evidence-reports/20261016-203721-18167/report/index.html`. No baseline was approved.

This is still partial parity. Linux does not yet mount attachments or the Mac's complete model,
effort, scheduling and usage footer. Its status strip, sidebar backdrop/well, window chrome and
display-scale geometry also remain separate work. These source-built journeys do not replace the
full installed Debian bundle suite or the complete Mac visual catalogue.

## 195. Sidebar region colors and saved-session selection come from the production theme

The checked Linux palette exported ordinary roles but omitted the sidebar's authored background
and navigator well. Consequently the native host painted `panel` above `surface`; its saved-agent
and terminal pickers also retained the original drawing specimen's hard-coded blue selection.
The project tree already used the production selection role, so two lists in the same sidebar
could disagree about the same selected state.

`LinuxThemeSnapshotTests` now exports the two sidebar gradient stops and navigator fill from
`AppThemeStyles.threading`. It checks that the supported house recipe remains a static vertical
two-stop gradient and an opaque, unbevelled well; a future authored change fails verification
instead of silently losing unsupported dressing. All previously exported numeric role values are
unchanged. `SidebarBackdropView` owns the Linux drawing leaf in the shared production component
source, linked into the host by symlink. The native root mounts that backdrop and the well;
diagnostic specimen windows retain their original ground. Saved-session selection now uses
`Design.Surface.selectionFill`, resolving its paired neutral ink in the active appearance.

The first measured implementation painted the complete wash behind the opaque well and took
roughly 55–63 ms for the sampled 900-pixel navigator frames. A structural clipping parent now
exposes only the header while keeping the backdrop's full-column coordinate space, and the Linux
`NSGradient` leaf skips rows outside that visible interval. The same samples take about 35–36 ms.
Exact decoded RGBA comparison of the ready, first-reply and dark captures finds zero changed
pixels after this optimization. The gradient stores two colors and constructs no window-sized
intermediate image; the small retained decoration tree is independent of project/session count.
This extends existing host-owned chrome, with no extension slot or change to navigation authority.

The final native workspace journey passes its exact exported-region/selection pixel checks in
both appearances, pane edges, composer focus/growth, pointer submission, Unicode/multiline turns,
retained draft and child, terminal switching, restart replay and same-thread resume. The inspected
captures are in `out/parity-sidebar-visible-20261016`. The existing Add Project journey passes its
pointer and AT-SPI choices, folder creation and durable Scratchpad identity. Inspection of its
menu also exposed a pre-existing fixed separator offset crossing the second label; the rule now
uses the boundary of the mounted rows and follows the visible page.
The final optimized build and Add Project rerun pass; the corrected menu was inspected in
`out/parity-sidebar-menu-verified-20261016/add-project-menu.png`.

The existing Mac `sidebar-edge-reveal` catalogue entry now captures both System and Threading,
in light and dark, from the real main-window controller. Its inspected Threading images are in
`.build/ui-evidence-reports/20261016-204943-60510/current`. The navigator fill and top-of-gradient
samples match Linux exactly: light `(235,245,253)` / `(217,234,250)`, dark `(6,19,33)` /
`(11,34,55)`. This is a color comparison at different logical window sizes, not geometric parity.
The Mac snapshot verification passes after export, as do the 12 Python runner contracts, both
source-copy verifiers and the standalone rendering/layout harness. No visual baseline was approved.

Sidebar branding, footer controls, window chrome and logical display scaling remain visibly
incomplete, as do the composer's full controls and attachments. The complete installed bundle
suite and complete Mac visual catalogue have not been rerun for this pass.

## 196. Native workspace geometry uses an explicit display scale

The ordinary SDL window passed pixel dimensions into an AppKit tree fixed at 2 pixels per
point. A 1120×900 X11 window therefore exposed only 560×450 logical points, while its fixed
320-pixel sidebar was narrower than the Mac's 240-point default. The same literal conversion
was repeated across pane headers, composer painting, menus, input, IME and accessibility.

`WorkspaceDisplay` now owns that conversion. The ordinary app defaults to 1× and accepts
`THREADING_LINUX_UI_SCALE=2`; other values fail explicitly. Standalone drawing probes retain
2×. The native sidebar follows `SidebarDefaults.defaultWidth` at 240 points, yielding 240 or
480 pixels. SDL retains bounded surfaces: 320…1280 pixels of content beside the sidebar,
180…900 pixels in height. Its minimum and maximum window widths now follow the sidebar's
actual pixel width. Saved-agent title/status regions are laid out in points before conversion.

This is explicit integer scale selection, not automatic monitor-DPI discovery. Fractional
scales, changing scale while the window is open and automatic per-monitor transitions remain
unimplemented. Terminal cells retain their existing physical metrics; only their header and
workspace origin follow the chrome scale. The current 900-pixel height cap also limits the
logical height available at 2×.

The release build passes. The real native conversation journey passes at both scales, including
light/dark region pixels, the one-point pane rule, two-point focused/one-point resting composer
borders, the 180-point editor ceiling, pointer sending, Unicode/multiline input, retained draft
and process, switching to a terminal and restart/resume. Both permission journeys pass policy,
keyboard, pointer, expandable tool rows and questions. The installed-runtime runner now includes
these two journeys at 2× as well as its default 1× lanes.

Inspected captures: `out/parity-scale-{1x,2x}-20261016/native-dark.png`, and the Add Project
menus in `out/parity-scale-menu-{1x,2x}-20261016`. Both menu journeys pass pointer and AT-SPI
choices, folder creation and durable Scratchpad identity. An interactive before/after comparison
of the ordinary desktop layout is available in this chat's display panel. The Mac Threading
sidebar capture from §195 confirms the matching 240-point width; the header's missing brand,
window chrome and footer remain visible differences.

The default-scale workspace journey passes exact terminal character geometry, selection and
clipboard offsets, focus isolation, real PTY resize, retained children and input while storage
is blocked (`out/parity-scale-workspace-r2.log`). The full AT-SPI geometry journey passes,
including odd-sized windows (`out/parity-scale-accessibility.log`). The native outline journey
passes 5,100 projects and 1,024 saved terminals, bounded visible rows, wheel/pointer/keyboard,
resizing and restoration near the middle/end (`out/parity-scale-outline-r2.log`). A 480-pixel
window now mounts 14 project rows rather than 7; tests keep explicit viewport bounds and use a
shorter workspace when testing offscreen selection.

The session Actions and Open In journeys pass at 1×. The new-session composer passes focus,
scrolling, choices, native and AT-SPI Unicode editing and exact launch; its 560×180 minimum
window is covered in `out/parity-scale-composer-minimum-20261016`. Account identity choices
also pass. The 12 Python runner contracts and both vendored-source verifiers pass.

The wider outline exposed a real trailing-content defect: its project count and hover
controls could extend beyond the selection capsule. The host had supplied the production row
background but omitted AppKit's outer cell band. The Linux boundary now supplies the measured
16-point trailing band minus the same `SidebarDensity.trailingCellReclaim` used by the row;
project, session, terminal and status content respect it. This remains viewport-only work and
does not change the mounted row count. The inspected count/hover captures in
`out/parity-scale-inset-journeys-20261016/project-count` show the controls inside the capsule.
Project count, per-row Actions, project creation, and saved-shell restart journeys pass. The
workspace and large-outline journeys were rerun successfully after this correction
(`out/parity-scale-inset-{workspace,outline}.log`).

Provider marks pass at explicit 2×, including selected/unselected contrast and missing-artwork
fallback. The account picker passes 32 identities with 15 visible 28-point rows at 1×. Its
source-check helper must receive an absolute evidence directory because the fixture derives its
isolated HOME there. Terminal failure rendering also uses the shared scale; the saved-terminal
refusal journey passes lost-reply, missing/unavailable ownership surveys and explicit retry
without changing durable identity (`out/parity-scale-failure.log`).

At 1120×900, sampled navigator raster medians were 28.24 ms at 1× and 52.68 ms at 2× (21
frames each). These are software-raster costs under Docker/Xvfb, not display latency or a new
performance target. The larger 2× sidebar paints more pixels than the previous narrow fixture.
The complete installed Debian suite, Wayland lane and complete Mac visual catalogue have not
been rerun for this scale change. No visual baseline was approved; full UI parity remains open.

## 197. The native sidebar keeps the production brand in its header

The Linux pane previously used a 12-point text field whose label changed between Projects,
Agents, Terminals and menu names. The Mac header instead keeps the Threading identity beside
the Add Project and arrangement controls. Linux now mounts `SidebarBrandView` in that retained
`PaneHeaderView`. The accessible list and window title continue to state the current navigation
context, and the existing Actions control keeps its actual command semantics.

`ThreadingMarkGeometry` is now a shared Design source rather than embedded in the Mac layer
view. Its normalized points, six strands, shield, core and particle geometry are unchanged.
The Mac still receives CGPaths. The Linux adapter expresses the same paths as NSBezierPaths,
including exact quadratic-to-cubic conversion, and its static mark retains the eight paths
until bounds or backing scale changes. The 24-point slot is shared with the Mac brand view;
the house-theme wordmark uses its default 13-point semibold role. The palette export now checks
that Threading has no custom brand and exports the Mac's legibility-adjusted mark ink in both
appearances. Existing palette role values were verified unchanged.

Customization remains the existing theme-owned brand presentation, with no new extension
contract. The Linux leaf currently supports only the checked house theme's default identity.
Navigation, input, command availability and accessible state remain host-owned. Theme-supplied
logos/wordmarks/analyzers, particle hover/press treatments and launch animation are still absent
on Linux; this is a still-presentation port, not an implementation of those behaviors.

The release build passes. All 23 Mac SidebarBrandViewTests plus the theme export test pass
(`out/parity-brand-mac-export.log`). The real native conversation journey passes at both scales,
including light/dark appearance, input, retained process/draft, terminal switching and resume.
The inspected screenshots are `out/parity-brand-{1x,2x}-20261016/native-{ready,dark}.png`.
The installed-runtime pixel helper now requires exported brand ink and wordmark ink inside
these measured header slots, in addition to its existing gradient, well and selection checks;
all four captures pass. Add Project also passes its pointer/AT-SPI menu choices, folder
creation and Scratchpad identity (`out/parity-brand-menu.log`).

The canonical Mac `sidebar-edge-reveal` capture also passes. Its report is
`.build/ui-evidence-reports/20261016-212856-83986/report/index.html`; the inspected dark
capture retains the production header. Comparing decoded RGBA for the full 240×40-point
header against the preceding `20261016-204943-60510` capture finds zero changed pixels in
both Threading appearances. This establishes that extracting the geometry preserved the Mac
header, not that the complete Linux and Mac shells are pixel-identical. The Linux Add Project
menu capture was inspected as well: the brand remains in place above its menu choices.

The 12 Python runner contracts, both vendor identity checks (including all 129 core sources),
and `git diff --check` pass. No visual baseline was approved. The complete Mac catalogue,
installed Debian suite and Wayland lane have not been rerun for this slice. Full UI parity
remains open, including window chrome, sidebar footer, composer controls and brand motion.

## 198. The project outline separates row chrome from inset content

The Linux host gave its outline a six-point outer gutter while mounting each cell's content
across the whole row. Consequently the production selection capsule was inset twice and the
project icon straddled its left edge. The disclosure was a Unicode prefix inside the title,
so it appeared after the project icon and its pointer target depended on title-slot arithmetic.

The outline now spans the sidebar width. Its full-width mounted cells retain selection and
input ownership, while their shared project/session/terminal content receives the platform's
inset geometry: 25 points before a root cell, 14 points for each depth step, and 16 points after
the cell at the default 240-point width. The existing density policy supplies any trailing
reclaim. `SidebarWidthDensityTests/testInsetCellGeometryUsedByLinuxOutline` measures these
values in the real Mac sidebar, including 25/39/53-point leading edges through three levels.
The Mac test passes (`out/parity-outline-mac-geometry.log`).

Expandable rows lazily mount one shared `GlyphView` in the measured 13-point disclosure slot
starting at 12 points. The marker follows expanded state and selected-row ink; the project name
contains only its name. Pointer disclosure uses that mounted marker's horizontal bounds across
the row height, while keyboard and accessibility continue through the existing project action.
The first pointer journey exposed the old title-based target after the glyph moved; that
coordinate duplication was removed. Accessibility row extents now cover the entire visible row
for projects and children alike, rather than starting at an unrelated manual child indent.
The outline also takes the production four-point `contentTopInset` below its header.

The matched shipping-window capture exposed the remaining vertical mismatch: AppKit's inset
table starts its first row ten points into the document, with zero intercell spacing. The Mac
geometry test now verifies both (`out/parity-outline-mac-vertical.log`). The shim's explicit
`.inset` style owns that ten-point document breathing at both ends; row offsets, hit testing,
viewport lookup, reading anchors and document height all use it. It scrolls away with the rows,
unlike the header's four-point fixed breathing. Full-width tables retain their existing zero
inset. The focused outline fixture covers both styles, variable heights, top/bottom non-row hit
regions, last-row visibility and viewport-bounded construction without height remeasurement.

This remains the existing navigator presentation contract. Themes own ink and silhouette;
Threading owns project identity, selection, expansion, actions and accessibility. No new
extension surface or data authority is introduced. Construction stays bounded by mounted
viewport rows, with one optional marker per expandable mounted cell and no offscreen tree of
views. The retained outline and its cheap item projection are unchanged.

The release build and all three focused outline fixtures pass (`out/parity-outline-build-r4.log`,
`out/parity-outline-shim.log`). Final-source native journeys pass for 5,100 projects and 1,024
saved terminals, including disclosure pointer input, keyboard, wheel, resize and restoration
near the middle and end (`out/parity-outline-matched-large.log`). The exact AT-SPI and complete
workspace journeys pass (`out/parity-outline-matched-{accessibility,workspace}-r2.log`). Their
expected visible counts changed with the zero-gap rows; the AT-SPI test checks the partially
clipped first row and fully visible selected last row after scrolling, not just the count.
The 2× project count, project actions, project creation and saved-shell restart journeys pass
in `out/parity-outline-matched-20261016/`.

Canonical Mac evidence is `.build/ui-evidence-reports/20261016-213925-25000/report/index.html`.
All three selected tests pass, including the new house-theme outline fixture in the shipping
window. Both Mac appearances and the Linux 1× large outline and 2× project/terminal captures
were inspected. At the selected terminal's centre, both light captures have exact RGB
`(211, 108, 0)` and horizontal fill bounds 10…230 points. The vertical fill bounds are 86…112
points in both after subtracting the Mac's 40-point caption region. This proves those measured
placement and fill properties, not equality of all rendered pixels: font rasterization and
several glyph shapes still differ. Empty-project disclosure and multiple expanded projects
also retain Linux's existing behavior and remain parity work.

The added live light-to-dark project journey passes and its dark capture was inspected
(`out/parity-outline-appearance-20261016/project-count/`). The dark terminal selection has
the same measured bounds as above and exact RGB `(255, 154, 61)` in both platforms. The
12 Python runner contracts, vendor identity checks and `git diff --check` pass. No baselines
were approved. The complete Mac catalogue, installed Debian suite and Wayland lane were not
rerun; full UI parity remains open.

## 199. Chrome text consumes the production held theme tiers

The idle workspace already mounts the shared `SessionPlaceholderView`. Its gray text was not a
placeholder styling override: the Linux `Design.Text` adapter replaced secondary, tertiary and
quaternary theme roles with `Design.Ink(on: ground)`, the neutral ink recipe intended for an
arbitrary terminal or selection background. That loses the house theme's authored blue/cream
hue and its label-legibility ladder across every control using those chrome roles.

The Mac palette export now records the actual `Design.Text` tiers after `LabelLegibility` holds
them against the theme's chrome grounds. It temporarily selects the Threading palette and
restores the previous palette afterward. Linux consumes these six appearance-specific RGBA
values through its existing cached dynamic colors, preserving their alpha and live appearance
behavior. The explicit arbitrary-ground/selection `Design.Ink` path is unchanged. This adds
constant palette data and no view, per-frame contrast search, or size-dependent callback work.
It preserves the existing theme presentation contract; command routing, input and accessible
identity remain host-owned.

The theme export test passes (`out/parity-placeholder-theme-export.log`). Existing palette role
values are retained. The native Add Project journey now inspects the empty pane before opening
its menu, toggles both appearances, and checks actual title/detail pixels against the exported
roles. At 1× a small glyph need not contain any fully covered pixel, so the check enumerates the
exact 8-bit source-over colors for strongly covered glyph pixels instead of requiring a solid
foreground sample. The new 1× capture passes; the preceding neutral-gray capture is rejected by
the same check. Both display scales pass the full Add Project pointer/accessibility journey
(`out/parity-placeholder-1x-r2.log`, `out/parity-placeholder-2x.log`).

The native conversation and permission/question/tool-expansion journeys pass after the shared
ink change (`out/parity-placeholder-native.log`, `out/parity-placeholder-permission-r2.log`).
The first permission command used an old helper without Xvfb and could not find a window; its
result was discarded and the supported Xvfb helper completed the journey.

Canonical Mac evidence passes all three selected tests at
`.build/ui-evidence-reports/20261016-215647-69830/report/index.html`. The added placeholder
captures measure an actual 880×480-point available pane in a 1121×521-point shipping window;
the extra region is the Mac caption/toolbar and pane rules. Both appearances were inspected
beside the real Linux shell captures. This removes differing available pane sizes from the
comparison, but does not prove identical text rasterization/compositing or symbol artwork.
Linux's DejaVu Sans medium request resolves to the installed Book face, and its terminal glyph
still uses the diagnostic symbol geometry; those remain visible parity differences.

The normalized checked palette was reverified against Mac without exporting it again
(`out/parity-placeholder-theme-verify.log`). The final release resource build, 12 Python runner contracts, both vendor identity checks and
`git diff --check` pass. No baselines were approved. The full Mac catalogue, installed Debian
suite and Wayland lane were not rerun; full UI parity remains open.


## 200. Terminal artwork retains its optical size inside the placeholder slot

The platform symbol adapter capped every image canvas at 32pt. The unconfigured placeholder
requested a 44pt slot and 36pt artwork, but both were clamped to 32pt, then enlarged to fill the
44pt image view. Its diagnostic terminal border also used an 11% stroke and a closed-looking
prompt. In the real 1× shell this occupied 42×37 pixels, compared with the Mac reference's
34×30-pixel footprint.

The bounded canvas now admits the existing 44pt slot without changing the requested optical
size. Terminal artwork uses filled screen/inner contours and a separate open prompt silhouette,
with proportional border and corner geometry. The 12pt sidebar mark uses the same definition.
This remains a Linux-owned symbol service behind the shared Design components; there is no new
extension surface, command or input authority. Rasterization stays bounded at 88×88 pixels per
image, with no additional views or per-frame work. It does not import or redistribute SF Symbols.

Inspected final real-shell captures show a 34×29-pixel empty-pane mark at 1× and 68×59 at 2×.
The native Add Project journey checks those optical bounds in both appearances as well as its
existing text-color and interaction contracts. The previous 42×37 capture fails the new check.
The capture wait now observes both the idle pane and sidebar presentation after changing theme;
waiting only for the former could record a transient mixture of two appearances at 2×.

The final release build passes (`out/parity-terminal-final-build.log`). Both Add Project journeys
pass (`out/parity-terminal-final-{1x,2x}.log`), with inspected light/dark images under the matching
`out/parity-terminal-final-{1x,2x}-20261017/` folders. The selected terminal, expansion, keyboard,
click and accessibility journey passes at 2× (`out/parity-terminal-final-outline-20261017/`).
The retained terminal-row layout fixture and native conversation journey pass
(`out/parity-terminal-native.log`), along with 12 Python runner contracts, both vendor identity
checks and `git diff --check`.

The Mac reference is the unchanged canonical shipping-window evidence at
`.build/ui-evidence-reports/20261016-215647-69830/report/index.html`. This is an improvement in
optical size, stroke weight and shape, not exact pixel equality: rasterization, typography,
remaining symbols and window chrome still differ. No baselines were approved. The full Mac
catalogue, installed Debian suite and Wayland lane were not rerun.

## 201. Independent project expansion uses the outline's own row index

The Linux host had two row models: the virtual `NSOutlineView` already supported independent
branches, but `SidebarVisibleRows` flattened only one `expandedProjectID`. Opening a second
project therefore collapsed the first. Child reconciliation also inferred ownership from that
single expanded project, and empty projects had no disclosure at all.

The native outline data source and stable item identities now live in `NavigatorOutline.swift`.
`SidebarVisibleRows` queries the outline's existing index instead of rebuilding another tree.
Selection retains the project ID and child ID, with positions used only as lookup hints. Both
projects can stay expanded, empty projects can change disclosure direction, and a disclosure
click preserves a selected child in another project. Collapsing the selected child's own parent
resolves selection back to that parent. The host retains expansion, selection, command routing,
persistence and runtime admission; this extends the existing host-owned navigator rather than
adding an extension surface.

The scaling gate covers ordinary small project sets and 5,100-project stress inputs. Explicit
reload/expansion rebuilds the outline's lightweight records; scroll, paint and keyboard movement
query its index and mount only viewport cells. The exact production source/resolver fixture uses
two branches with 600 runtimes of each kind, caps each kind at 512, and observes 18 created/mounted
views for 7,148 logical rows. It checks independent/empty expansion and stable selection after
project reorder plus a prepended child (`out/parity-expansion-index-final.log`). Its former
Foundation-only test now links the real shim outline, and the bundle contract lane runs it.

The native multiple-project journey passes at 1× and 2× in both appearances, including an exact
persisted terminal-ID check after activation (`out/parity-expansion-identity-{1x,2x}.log`).
Inspected images are under `out/parity-expansion-final-{1x,2x}-20261017/multi-project/`.
The existing 5,100-project/1,024-terminal scrolling, resize and restoration journey, project-count
journey and native conversation journey pass (`out/parity-expansion-{large,count,native}.log`).
The 12 Python runner contracts, source identity checks and `git diff --check` pass. The runner
fixture now supplies the newly added `SidebarVisibleRowsHarness` executable.

The added shipping Mac test confirms the same independent/empty expansion and sibling-selection
behavior. Its first images caught an unfinished disclosure animation. An attempted animation
completion wait did not finish in the offscreen host; a process sample showed XCTest waiting
with idle workers, and that test run was explicitly stopped. The fixture now captures the stable
initial expanded tree before exercising the disclosure action. All four canonical tests pass
(`out/parity-expansion-mac-final.log`), and the inspected light/dark report is
`.build/ui-evidence-reports/20261016-222308-46521/report/index.html`. The selected Beta terminal
fill has identical measured bounds `(10, 144, 230, 170)` in both 1× sidebars after removing the
Mac’s 40pt caption offset, with exact light RGB `(211, 108, 0)`. This verifies row placement and
selection fill, not equality of text or disclosure pixels.
Startup expansion preferences remain different: the Mac honors stored `Project.isExpanded`,
while Linux starts collapsed. Left/Right navigation, disclosure artwork, typography and window
chrome also remain parity work. No baselines were approved, and the full Mac catalogue,
installed Debian suite and Wayland lane have not been rerun for this change.

## 202. Plain arrow keys navigate the outline instead of opening catalogs

The native input bridge previously encoded physical Right and Left as the same events used to
open saved terminal and agent catalogs. That made ordinary outline traversal impossible. Physical
arrows now have distinct events (53/54); explicit catalog commands retain 10/11 and remain in the
existing project Actions menu, reachable with Shift+F10. Existing menu/catalog back navigation,
terminal input and editor caret movement retain their routes.

`SidebarVisibleRows.navigate` queries the outline index directly. Right expands a closed project
and stays on it, matching the Mac reference; Left returns a child to its project, then collapses
that project.
An open project stays selected, including an empty one, and leaf/collapsed-root boundary presses do
not repaint. Expansion still rebuilds lightweight row records; ordinary selection movement is an
indexed lookup and mounts only viewport cells. This is existing host-owned navigation, with no
new customization surface or provider operation.

The production-source fixture verifies expand/open-project no-op/parent/collapse plus empty and leaf
boundaries while retaining the 7,148-row, 18-mounted-cell stress check
(`out/parity-arrow-reference-index.log`). The release build and C input/pointer contracts pass
(`out/parity-arrow-reference-build.log`, `out/parity-arrow-pointer.log`). Native multiple-project
journeys pass at 1× and 2× in both appearances and verify the exact terminal ID after Return.
Inspected captures are in `out/parity-arrow-reference-{1x,2x}-20261017/multi-project/`, including
`keyboard-expanded.png`. The 2× capture also exposes clipped empty-pane explanatory text at the
fixed 1,120px window width; this remains a separate layout gap.

Saved-catalog journeys now use the actual Actions menu through a shared test helper, also mounted
by the bundle runner. Broader validation exposed stale fixtures, not failed arrow handling:
several eight-row catalog checks implicitly assumed 2×, a named-account click assumed 2×, the
agent-create grid still expected the old navigator size, and attach tests still expected a
full-width catalog or the former 320px navigator/82px header. These assertions now declare their
scale or use the current 240px navigator/41px header. The startup journey now clicks the header
Add Project menu and chooses Existing Folder instead of the removed tile.

Native conversation and permission journeys pass, as do terminal restart, refused saved-terminal
admission, terminal catalogs and their 512-row/runtime bounds, remembered working directories,
terminal picker reattachment/back navigation, clean-profile startup, agent creation, named Codex
and Claude admission, native Claude resume, agent reattachment and shared session titles. Logs
are under `out/parity-arrow-*` (final reruns: `terminals-r2`, `terminals-r3`, `startup`,
`agents-r3`, `agents-r4`, `agents-r5`). Twelve Python runner contracts and both vendor identity
checks pass. Full installed-Debian and Wayland suites have not been rerun for this change.

The Mac reference rejected the initial assumption that a second Right should select the first
child: real AppKit key events leave the open project selected. Linux now matches that observed
behavior; Down visits its first child. The Mac test explicitly selects a child before checking
Right-on-leaf and Left-to-parent, so a failed first-child assumption cannot make those checks
vacuously pass. Earlier test attempts used an unsupported text-view selector and then the wrong
Swift argument label; the final reference uses `keyDown(with:)` with real arrow-key events.

All four targeted canonical Mac tests pass (`out/parity-arrow-mac-reference.log`). The inspected
light/dark report is `.build/ui-evidence-reports/20261016-224303-97769/report/index.html`.
Provider-artwork and late-agent-admission journeys also pass in the `agents-r5` evidence folder.
The native 1×/2× outline journeys were rerun after matching the Mac Right-key behavior.
Typography, disclosure artwork, footer/window chrome, startup expansion persistence and the
2× placeholder clipping remain parity work. No baselines were approved. The complete Mac
evidence catalogue has not been rerun for this targeted navigation change.

## 203. Bundle real UI font weights and share the family across text paths

The Linux label bridge asked DejaVu Sans for regular, medium, semibold and bold, but the installed
family only provided Book and Bold. The missing intermediate faces collapsed the intended
hierarchy, and its wider metrics increased the difference from the Mac reference. An isolated
Fontconfig trial of upstream Inter 4.1 produced closer label metrics before changing the app.
For the same dark `GammaEmpty` row, the measured bright-ink bounds were `(52,181,139,193)` on
Mac, `(52,181,154,193)` with DejaVu Sans, and `(52,181,139,193)` with Inter. This is one concrete
width/placement match, not pixel equality or proof that every string matches SF.

The AppKit module now carries unmodified Inter 4.1 variable upright/italic fonts, their upstream
OFL 1.1 license and source/hash record. `NSFont` enters one serialized registration gate; the
native host prepares it on the existing detached startup worker before mounting UI. Fontconfig
registration is process-local and reads two known resource files, never a per-label directory
scan or a font installation into the user's profile. Plain labels, attributed runs and complete
worker-owned document layouts share `FontFamily.h`. Monospaced code and the fixed-cell terminal
retain DejaVu Sans Mono. This changes the host's existing platform typography adapter and adds
no extension presentation contract or user-facing setting.

The archive and Debian package now include `LinuxAppKitSpike_AppKit.resources` and the Inter
license/provenance directory. The package explicitly declares its Fontconfig/PangoFT2 runtime
libraries; the manual stack fixture links them too. The installed bundle runner checks both
font hashes and license files. A source-free Ubuntu run installs the actual Debian package,
checks that Swift, `/repo` and a global Inter installation are absent, exercises all three shared
row-layout fixtures and both native outline scales, then verifies the same Inter label ink
bounds. Evidence is in `out/parity-font-installed-final-20261017/` and `out/parity-font-installed-final.log`.

The text-label fixture now requires all four requested weights to render differently, including
medium versus regular and semibold versus bold (`out/parity-font-text.log`). The native multiple-
project, native conversation, Add Project/placeholder ink and 5,100-project scrolling/resize
journeys pass (`out/parity-font-{1x,2x,native,ink-final-1x,ink-final-2x,large}.log`). Inter's line
metrics shift the centered empty-state stack's raster phase: measured mark bounds are now
34×30 at 1× (the Mac reference footprint) and 68×58 at 2×. The optical test records those exact
measured bounds; no symbol path was changed. The 12 Python runner contracts pass.

The current Release label benchmark reports 28.52ms median/29.22ms maximum for 54 mounted labels,
22.80/25.13ms for 18 compound readings, and 1.55/1.85ms versus 1.63/1.78ms for 170 versus 1,700
storage rows at the same 180px viewport (`out/parity-font-benchmark.log`). These are current
measurements, not a claimed before/after speedup. Work remains viewport-bounded.

All four targeted canonical Mac tests pass. The expanded reference includes a 360×240-point
placeholder pane in a 601×281 shell; inspected report:
`.build/ui-evidence-reports/20261016-225158-17713/report/index.html`. A first request for a
320-point pane produced a 360-point pane while the shell changed the sidebar/window geometry.
That observation does not establish a 360-point minimum: the declared content minimum is 320.
Narrow resizing and the clipped 2× Linux placeholder still need a dedicated matching check.
Typography/rasterization, placeholder ink contrast, disclosure art, footer/window chrome and
persisted expansion remain parity work. No baselines were approved. The complete Mac catalogue,
full Debian journey suite and Wayland lane were not rerun for this font change.

The final package with font preparation on the startup worker passes the same source-free
installed checks (`out/parity-font-package-final.log`, `out/parity-font-installed-final.log`).
Its 1×/2× selected-outline captures are pixel-identical to the inspected first installed captures.
The archive and Debian artifacts were rebuilt; source changes remain uncommitted.

## 204. Preserve open strokes and match navigator disclosure roles

The navigator asked for a generic control symbol capped to 10 points and secondary neutral ink.
The real Mac outline requests the eight-point semibold chevron role and tertiary theme ink,
switching to the selected ground's label tier only when the project itself is selected. Linux
now makes that same request inside the existing 13-point disclosure/hit slot. The marker no
longer opts into the separate provider-artwork contrast repair, which brightened the authored
tertiary tier. Glyph ownership remains viewport-bounded; an expansion-state change materializes
one marker image, while selection only changes its ink. This is an existing host-owned outline
adapter, with no new extension surface or capability.

A separate reference investigation found that the canonical hidden-window capture composites
placeholder labels more strongly than their authored alpha: a 0.7 title measured about 0.91;
light/dark detail labels measured about 0.859/0.773 instead of 0.627/0.523. An isolated AppKit
probe reproduced two draws of a translucent `NSTextField`; a displayed probe produced a single
composition. That does not yet prove the complete shipping window's displayed result. Priming
backing layers did not fix the shipping fixture, and directly rendering its layer tree omitted
large portions of the window. Those experimental capture edits and the temporary failing opacity
assertion were removed. The established canonical capture path remains unchanged, and Linux's
placeholder palette was not changed to imitate the questionable reference. Logs and isolated
probes remain under `out/parity-label-*` and `out/label-*.swift`. A reliable full-window opacity
comparison remains open; no visual baseline was approved.

The first smaller-role captures still looked triangular. Reducing the chevron stroke exposed
an actual closing edge: `NSGraphicsContext.stroke(polygons:)` joined the last vertex to the
first whenever a subpath had at least three points. `NSBezierPath.polygons()` had discarded the
explicit closure state. Flattening now repeats the start point only for `.close`, and the
stroker visits consecutive segments without inventing an edge. Polygon fills retain implicit
closure. The existing CoreGraphics current-path route already handles closure explicitly and
keeps that behavior. The portable chevron stroke also scales to its small role instead of
forcing a 1.5-point minimum. General cap/join fidelity remains outside this correction.

`FloatingGlyphHarness` now checks open and explicitly closed Bezier strokes plus implicit fill
closure, alongside its existing CoreGraphics path-state and nine-mark checks. The final Release
fixture passes (`out/parity-chevron-path-final.log`); its first attempt sampled the wrong Y-up
bitmap coordinate, which was corrected before passing. Native 1×/2× outlines pass with real
light/dark pixels, independent/empty expansion, stable child identity, selection and keyboard
activation (`out/parity-chevron-open-{1x,2x}-20261017`). The native check limits optical size,
authored alpha and covered ink area, catching both the oversized role and the extra closing edge.
Selected-project and initially collapsed captures are included for inspection. Native conversation
and permission/tool/question journeys pass (`out/parity-chevron-{native,permission}.log`).

The old standalone raster comparison runner could not compile the current shim on macOS because
its source list includes `NSTextFieldEditing` without the Linux-only `NSTextView` declaration
(`out/parity-chevron-raster.log`). It provides no equivalence result for this change. The Release
package fixture and actual native window remain the valid rendering paths. The full targeted Mac
reference passes all four tests after restoring its original capture helper; report:
`.build/ui-evidence-reports/20261016-231830-94605/report/index.html`.

The final archive and Debian package were rebuilt (`out/parity-chevron-open-package.log`). A
source-free Ubuntu installation passes the native outline and new pixel checks at both scales,
all three shared row-layout fixtures and bundled-font checks
(`out/parity-chevron-open-installed.log`, `out/parity-chevron-open-installed-20261017/`). Its
expanded dark captures are decoded-RGB-identical to the inspected build captures; the installed
collapsed and selected-project states were also inspected. Add Project/menu/placeholder-ink
journeys pass at both scales (`out/parity-chevron-open-ink-{1x,2x}.log`), as do 12 Python runner
contracts and both vendor identity checks. The portable mark remains an approximation of SF:
at 1× its faint antialias bounds are still taller than the Mac reference. Typography,
placeholder capture/contrast, narrow layouts, footer/window chrome and persisted expansion
remain parity work. The complete Mac catalogue, full Debian suite and Wayland lane were not
rerun. No baselines were approved; source changes remain uncommitted.

## 205. Clipped labels keep one complete line instead of silently wrapping

The narrow 2× placeholder stopped after “start” despite space for more glyphs. The label bridge
set a finite Pango width and single-paragraph mode, but single-paragraph mode still permits word
wrapping. With ellipsizing disabled, its negative height did not enforce one line. The first
word-wrapped line was drawn and the remaining words fell outside the label's height.

An isolated real-AppKit probe confirms that overflowing `.byClipping` labels keep the start of
one line for left, center and right alignment. Fitting labels retain their requested alignment.
The shared `LabelLayout.h` now configures that behavior for plain rendering, attributed rendering
and selectable-label geometry. For clipping it first obtains the complete line's logical width
and uses the larger of that width and the visible field width; the destination remains bounded
and crops the result. Wrapping, truncating and complete-paragraph modes retain their separate
contracts. This removes two copies of layout configuration instead of fixing only the placeholder.
It changes an existing host text adapter, with no new user setting or extension surface.

`TextLabelHarness` checks exact pixel equality between a narrow label and a crop of its full
line for plain/attributed and selectable/nonselectable labels under all three alignments. Its
existing Unicode, mixed runs, wrapping, truncation, selection, theme and production component
checks pass (`out/parity-clip-text.log`). Native 1×/2× outline journeys now resize the real window
to 360- and 320-point content panes, check the accessible action stays inside the pane and retain
the selected terminal through resize and activation (`out/parity-clip-{1x,2x}-20261017`).
Inspected images show the full detail at 360 points and ordinary single-line clipping at 320.
The narrower case still cannot display the entire sentence; wrapping it would change the shared
Mac component's stated behavior. The matched 360-point Mac reference remains the inspected
`20261016-231830-94605` canonical report; its placeholder opacity uncertainty is documented above.

The input bound remains 4,096 UTF-8 bytes/64 attributed spans, with the same bounded raster output.
No file scan or unbounded history work was added. Current Release measurements are 26.73ms median /
30.25ms maximum for 54 labels, 21.58/21.92ms for 18 compound readings, and 1.69/2.18ms versus
1.68/1.90ms for 170 versus 1,700 storage rows at the same viewport (`out/parity-clip-benchmark.log`).
These are current bounds observations, not a claimed speedup. Native conversation and
permission/tool/question journeys pass (`out/parity-clip-{native,permission}.log`).

The rebuilt Debian package passes the same resize and navigation journey at both scales in a
clean Ubuntu container without the checkout, Swift or globally installed Inter
(`out/parity-clip-installed.log`). All four installed narrow captures are decoded-RGB-identical
to the inspected build captures. The full-size 1× dark outline is also pixel-identical to the
prior turn; at 2× the only changed rectangle is the clipped placeholder detail line
`(561,255)-(1040,276)`. Twelve Python runner contracts, both vendor identity checks and
`git diff --check` pass. Artifacts were rebuilt (`out/parity-clip-package.log`).

The standalone Mac probe pins its root width explicitly; without that constraint AppKit grows
the content view past the requested window width. That observation is not a new 360-point
window minimum. Window scaling/minimum policy, placeholder opacity, typography and full chrome
remain parity work. No Mac product sources or visual baselines changed in this iteration. The
complete Mac catalogue, full Debian suite and Wayland lane were not rerun.

## 206. Startup sizing applies UI scale and uses the native fitted geometry

The ordinary workspace requested 1120×480 physical pixels at both scales. At 2× this halved
its logical area and left the 240-point sidebar beside a needlessly narrow placeholder. Startup
now applies the UI scale to the requested 1120×480 points. `tw_open_workspace` fits that request
to the primary display's usable bounds and the existing rendering budget, and installs the
sidebar-aware native size constraints before creating the renderer. The Swift host reads back
the actual window dimensions for its initial pane layout instead of painting at the unconstrained
request. Standalone diagnostics keep their existing opening path.

This does not double terminal budgets. The 320…1280-pixel terminal width and 180…900-pixel window
height remain physical limits shared with saved-grid admission and software rendering. Expanding
those limits requires a coordinated PTY/rendering change. The fit respects those minima even on
a display smaller than the minimum; automatic display scaling and complete Mac window-size
policy remain open. No new customization surface was added: native geometry stays host-owned.

The native outline journey asserts the actual startup window and its very first pane frame,
then retains its independent expansion, stable selection, light/dark pixels, narrow resize and
terminal activation checks. At 1× the 1400×1000 Xvfb display still opens a 1120×480 window. At 2×
it opens 1400×900 with a 920×900 pane. Startup-only 2× probes on 1000×700 and 2400×1400 displays
open 1000×700 and 1760×900 respectively. Their real-window captures were inspected: the large
pane displays the complete placeholder detail, while the small display retains ordinary clipping
in its 260-point pane. Evidence is under `out/parity-window-start-{1x,2x}-20261017` and
`out/parity-window-{small,large}-2x-20261017`.

Fixed-viewport count, action and eight-row catalogue fixtures now request their intended
1120×480 test window explicitly instead of inheriting startup dimensions. The Add Project pixel
fixture reads its capture dimensions rather than assuming a fixed image stride. Count/action
pixels, session titles, provider artwork, late agent admission, 512-row terminal catalogue and
eight-runtime limits, remembered working directories, and native conversation/composer journeys
pass. The latter's grown-composer capture was inspected. Logs are the corresponding
`out/parity-window-*-20261017` directories and `out/parity-window-native.log`.

The saved-terminal picker and clean-profile startup journeys pass against the final Release
binary (`out/parity-window-terminal-release-20261017`). Earlier helper attempts omitted the
picker's project directory or defaulted to an older Debug binary; neither supplied valid evidence
for this build. The valid run verifies the same child/grid/history on attachment and native
same-child reattachment on reopening. Twelve Python runner contracts, both vendor identity
checks and `git diff --check` pass.

The archive and Debian package were rebuilt (`out/parity-window-package.log`). A clean Ubuntu
installation without Swift, the checkout or globally installed Inter passes both scale journeys,
three shared row-layout fixtures and bundled-font checks (`out/parity-window-installed.log`).
Its two initial captures and four narrow-pane captures are decoded-RGB-identical to the inspected
Release captures. Installed evidence is `out/parity-window-installed-20261017`.

The Wayland runner now includes a 2× render pass on its fixed 1280×800 Weston output. Extending
that coverage exposed test assumptions left from the old 2× default: row buttons were expected
to be 40×40 at 1×, the placeholder ink probe sampled a doubled offset, and title interaction used
old fixed coordinates. The fixture now uses the current 20-point row targets, the production
icon slot and the title's published accessible geometry. Its compositor pointer helper previously
identified a window by 800/1120×480 dimensions, rejecting the correctly rendered 1280×800 2×
window. It now finds a mapped desktop surface with Threading's title, excluding the compositor
background even when the app fills the display. The module compiles with warnings treated as
errors against Weston 13. The failed intermediate runs are retained in
`out/parity-window-wayland{,-final}.log`; their successful render frames are not presented as a
complete interaction-suite pass.

The final installed Wayland `--actions` lane passes completely
(`out/parity-window-wayland-verified.log`, `out/wayland-smoke.z9UOgroP/`): both scale render
journeys, AT-SPI actions, physical pointer/keyboard menus, title reveal/focus return, drag release,
and Unicode composer wheel/smooth scrolling with exact project launch and PTY isolation. The
2× startup, dark idle pane, title-reveal terminal and composer captures were inspected. Weston
uses a software headless output; this does not verify a physical compositor's display scaling.
The complete Mac catalogue and full Debian suite were not rerun. The last canonical Mac reference
is unchanged; full window chrome, typography, placeholder opacity and persisted expansion remain
parity work. No visual baselines were approved and source changes remain uncommitted.

## 207. Stroke caps, joins and translucent ink follow the authored path

The existing `NSBezierPath.lineCapStyle` and `lineJoinStyle` properties were accepted but ignored.
The software stroker built a quad per segment and a disc at each segment's end, including the
last endpoint but not the first. It then painted every piece independently. Besides rounding
miter/bevel corners and making open caps asymmetric, this compounded translucent ink and
antialias coverage at overlaps. The CoreGraphics current-path adapter compounded this again by
submitting each segment as a separate stroke.

`StrokeOutline` now expands butt/round/square caps and miter/round/bevel joins, with the authored
miter limit, in user space. Its pieces have a consistent winding and pass through one nonzero
fill, so intersections receive one composition. Explicit closure is retained separately from
vertices: an open line returning to its start has caps there, while `close()` adds the first
join. Closed strokes retain their holes. Both Bezier and CoreGraphics path consumers use this
operation; the latter preserves its complete subpaths instead of splitting them into lines.
This changes the existing rendering adapter, with no extension or user-facing settings surface.

The Release floating-glyph fixture passes the nine shared classic marks, template mark, path
state/closure checks, and new cap, join, miter-limit, closed-hole and alpha assertions
(`out/parity-stroke-glyphs.log`). An isolated native AppKit probe confirms the same cap extents,
join distinctions, miter fallback and single-composition alpha
(`out/parity-stroke-mac-probe.swift`, `out/parity-stroke-mac-20261017`). Its first very small
aliased round-cap sample differed because Quartz covers an edge pixel that the portable
center-sampled aliased rasterizer does not; the cross-platform geometry check uses a larger
corner away from that sampling ambiguity. These are geometry/ink contracts, not a claim that
the two rasterizers produce identical antialias pixels.

Native outline journeys pass at both scales in both appearances, including disclosure size/ink,
independent expansion, narrow resize and terminal activation (`out/parity-stroke-{1x,2x}-20261017`).
Conversation/composer and permission/tool/question journeys pass
(`out/parity-stroke-{native,permission}.log`). The actual initial window and focused composer
captures were inspected; an interactive before/after comparison was opened for the 2× window.
The production label fixture passes (`out/parity-stroke-text.log`). Current Release measurements
are 21.35ms median / 21.96ms maximum for 54 labels, 16.73/16.86ms for 18 compound readings and
1.56/1.58ms versus 1.66/2.16ms for 170 versus 1,700 storage rows at the same viewport
(`out/parity-stroke-benchmark.log`). Geometry expansion is linear in flattened path size and
reuses the bounded raster leaf; there is no per-stroke full-window alpha allocation. These
measurements show no observed regression, not a controlled speedup claim.

The placeholder opacity investigation also tried a WindowServer readback of a displayed native
probe, including launching it as an application bundle. Screen capture access was available,
but the process remained inactive and WindowServer returned wholly transparent pixels. That
provides no color evidence. The Linux palette and canonical Mac capture helper were left
unchanged; the uncertainty recorded in finding 204 remains open.

Both native Add Project/placeholder-ink journeys pass (`out/parity-stroke-add-{1x,2x}.log`).
The initial-window comparison changes 200 pixels at 1× and 429 at 2×, confined to the authored
sidebar mark and disclosures; the initial placeholder remains pixel-identical. The rebuilt
package also passes the full installed Wayland `--actions` lane at both render scales
(`out/parity-stroke-wayland.log`, `out/wayland-smoke.heohEkls/`), including accessibility,
physical pointer/keyboard navigation and Unicode composer scrolling. Its 2× window was inspected.

The full `bundle-smoke.sh` build and contract phase passes, including the production PTY/native
provider paths, virtualization, clipping and 10,000-row document contracts. Archive startup,
non-root installed startup, live `.deb` reinstallation, workspace input/resize, session Actions,
Open In and late agent admission also pass. That run then exposed old assumptions in
`actions_smoke.py`: it inherited the new 1× default while asserting 2× button geometry, and
expected a mouse column based on the old 320-pixel sidebar. The fixture now explicitly requests
its bounded 2× viewport and derives the expected terminal cell from the actual pane origin and
unchanged 10×22-pixel cells. Exact mouse press/release bytes remain required. The failed runs are
`out/parity-stroke-bundle.log` and `out/parity-stroke-bundle-resume.log`; their evidence directories
are `out/bundle-smoke/run.UenIvd7C` and `out/bundle-smoke/stroke-resume.uuOFVeFW`.

A regular-application WindowServer probe also returned transparent pixels. The current
ScreenCaptureKit screenshot API was tried for the same isolated window and failed with capture
error -3811. Neither result supports changing the placeholder palette. Those probes are retained
under `out/label-{windowserver,screencapture}-*` and `out/parity-{windowserver,screencapture}-*`.

The resumed installed run passes Actions, project menus, composer/document/diff/stream paths,
native Codex/Claude conversations, permissions at both scales, account selection and Add Project
(`out/parity-stroke-bundle-resume-final.log`, `out/bundle-smoke/stroke-resume.nwpzUUYf`).
It then exposed a source-free fixture defect: the provider-artwork fallback test copied the
executable and its artwork resources but omitted the required AppKit font resource bundle.
The fixture now copies both bundles and removes only provider artwork. A build-tree fallback
had previously concealed that omission.

The final resumed tail exits successfully (`out/parity-stroke-bundle-tail.log`,
`out/bundle-smoke/stroke-resume.umkbpMJN`). It covers bundled/fallback provider marks, bounded
account rows, project actions, the ordinary outline in both appearances, 5,100 projects with
1,024 terminals, terminal recovery/refusal/catalogue/capacity, working-directory identity and
desktop-entry launch. Together these runs cover the complete package suite; this was not one
uninterrupted green invocation. The installed ordinary startup capture was inspected, and its
startup plus 360/320-point dark placeholder captures are decoded-RGB-identical to the tested
Release build. Twelve Python runner contracts, both vendor checks and `git diff --check` pass.
The Mac catalogue was not rerun; full chrome, typography, reliable placeholder-opacity evidence
and persisted expansion remain parity work. No baselines were approved or changes committed.

## 208. Project disclosures restore the shared durable state

The Mac sidebar writes `Project.isExpanded`; Linux's bounded navigation projection dropped that
field and its outline therefore always started collapsed. The projection now carries the existing
value, including the shared `true` default for new projects. Initial and imported snapshots restore
all expanded identities in one outline projection, without emitting gesture callbacks or writes.
The outline contract restores 5,100 roots with one populated branch using exactly two child-count
queries, builds no detached views, and verifies expand/collapse notifications separately.

Pointer, keyboard and page-reveal expansion share the outline's delegate route. One worker writes
one current project payload through `updateProjectExpansion`; it preserves position, embedded
terminals, session rows and runtime selection, and refuses a missing identity without upserting it.
Navigation waits for the receipt while resize and terminal input remain serviced. A failed write
restores the previous expansion and selected row. This is host-owned state on the existing surface,
not a new preference, extension component or database schema.

The CoreSlice contracts pass, including mixed standing states, idempotence, missing-project refusal
and an expansion update beside an unreadable unrelated session. The initial payload assertion
incorrectly compared JSON text (encoder key order is not stable); its corrected assertion compares
all decoded fields after the round trip. `out/parity-expansion-contracts-final.log` also includes
the outline and native visible-row contracts. The failed assertion is retained in
`out/parity-expansion-contracts.log`.

Native multi-project journeys pass at both scales (`out/parity-expansion-{1x,2x}-verified-20261017`):
independent/empty disclosure changes, keyboard traversal, mixed-state restart, exact runtime
identity and a held-store-lock refusal that restores the selected child. Both restarted windows
were inspected. Their unchanged collapsed startup states are decoded-RGB-identical to finding
207's captures at both scales. The first restart attempts used the project-window title to find a
window already attached to a terminal; the corrected lookup retains process identity and accepts
both product titles. Failed evidence remains in `out/parity-expansion-{1x,2x}-20261017`.

The native 5,100-project/1,024-terminal journey passes, including middle/tail restoration with the
first branch still expanded; collapsed count/hover/keyboard assertions also pass
(`out/parity-expansion-navigation-20261017`). Fixtures that specifically inspect collapsed badges
now seed that state rather than depending on Linux ignoring the stored expanded default. The
project-action fixture identifies project controls by semantic identity so a newly created terminal
can appear under its expanded project; its final pointer/keyboard/menu/drag journey passes in
`out/parity-expansion-actions-final-20261017`. The earlier action attempt used the wrong argument
in a local runner, and its next attempt exposed the two-rows-only fixture assumption; both logs
are retained. The ordinary native Codex conversation/composer/terminal/restart journey passes
(`out/parity-expansion-native-verified.log`); an earlier invocation refused an already existing
output directory before launching the app. Twelve Python runner contracts, both vendor checks and
`git diff --check` pass.

The archive and Debian package were rebuilt (`out/parity-expansion-package.log`). A fresh Ubuntu
installation without the checkout, Swift or global Inter passes the complete two-scale disclosure
journey and bundled-font/layout checks (`out/parity-expansion-installed.log`). Installed evidence
is `out/parity-expansion-installed-20261017`: both initial windows, all four narrow dark placeholder
captures, both mixed-state restarts and both empty-branch collapses after restart match the source
build's decoded RGB exactly. The installed collapsed-empty-branch window was also inspected.

The focused Mac `ProjectDatabaseTests` run also succeeds: 68 tests, zero failures, one existing
live-legacy-document test skipped because no `projects.json` fixture is present
(`out/parity-expansion-mac-database.log`). The complete Mac visual catalogue, full Debian runtime
suite and Wayland lane were not rerun for this change. Full chrome, typography and reliable
placeholder-opacity evidence remain parity work. A restored runtime still initially enters the
Linux saved-runtime picker; Mac restores selection in the ordinary outline, so that presentation
is a separate remaining gap. No visual baselines were approved and no changes were committed.

## 209. Restored runtimes select their ordinary outline row

Linux restored the correct daemon runtime but replaced the sidebar with its saved-agent or
saved-terminal catalog. Returning from that catalog highlighted the project rather than the
restored child. Mac's `select(sessionID:)` and `select(terminalID:)` reveal the ancestor chain and
select the exact child in the ordinary outline.

Startup now retains a stable outline target beside runtime activation. After the first standing
projection, it expands that target's parent if needed, resolves the child and scrolls it into view.
An already-open parent performs no write; a folded parent uses the existing single-worker
expansion route. Other branches retain their stored choices. Native conversation restoration,
terminal-agent attachment and standalone-terminal attachment use the same presentation rule.
The saved catalogs remain explicit project-menu destinations. Runtime creation and attach-only
startup rules are unchanged, and this adds no user-facing setting or extension surface.

The native multi-project journey passes at both scales, including selected-child restoration
without a catalog, a second restart from a deliberately folded parent, persistence of only that
parent's reveal, unrelated collapsed/empty branches and busy-store rollback. Final evidence is
`out/parity-restored-outline-{1x,2x}-final-20261017`. Restarts inherit the real pointer position;
the first capture attempts did not wait for its exit repaint and retained transient hover ink.
The fixture now waits for that existing repaint before capture. Both scales' final restored
sidebar images were inspected, and a before/after comparison was opened against finding 208.

The ordinary native Codex conversation journey passes with a collapsed parent on restart,
AT-SPI selection of the exact restored conversation, transcript replay, retained identity and a
new turn on the same provider thread (`out/parity-restored-outline-native-verified.log`). Its
replayed conversation capture was inspected. The initial capture gate expected every sidebar
frame to be an agent picker and therefore waited forever after the correctly restored outline
appeared; it now follows either presentation, resets state at each new app launch, and still
requires a prepared conversation and matching sidebar height/appearance. That failed run remains
in `out/parity-restored-outline-native.log`.

Focused terminal-agent, Claude, standalone-shell, working-directory and launcher journeys pass:
`out/parity-restored-outline-runtime-20261017` contains deep-history exact-row restoration beyond
the recent page and same-child Claude reattachment; `out/parity-restored-outline-runtime-tail-20261017`
contains shell restart and real-bash cwd tracking; `out/parity-restored-outline-startup-verified-20261017`
contains clean-profile import and targeted/untargeted same-child relaunch. Their old automatic-picker
assumptions now request a catalog explicitly where browsing one is the test. The cwd fixture allows
the deliberate restored-parent expansion while still comparing all other settings, terminal data,
ownership and the other project's bytes. The launcher fixture folds the expanded project before
moving to its next sibling. Earlier failed runner/fixture attempts remain in the corresponding
runtime logs. AT-SPI restoration assertions share the existing catalog test helper, and the
standalone agent runner now supplies an explicit D-Bus session for that inspection.

The rebuilt archive and Debian package are recorded in `out/parity-restored-outline-package.log`.
A clean Ubuntu installation without the checkout, Swift or globally installed Inter passes both
multi-project restoration and the complete native-conversation journey at 1× and 2×
(`out/parity-restored-outline-installed.log`, evidence `out/parity-restored-outline-installed-20261017`).
Both initial collapsed windows, both mixed-state restarts and both folded-parent reveal captures
are decoded-RGB-identical to the final source-build captures. The installed 2× replayed conversation
was inspected, as was the source-build deep-history agent selection. Twelve Python runner contracts,
both vendor identity checks, shell syntax and `git diff --check` pass. The full Debian runtime suite,
Wayland lane and Mac visual catalogue were not rerun; this change touches Linux presentation only.
Full window chrome, typography and reliable placeholder-opacity evidence remain unfinished. No
baselines were approved or changes committed.


## 210. Installed journeys must state their intended outline state

The follow-up installed-package sweep exposed old fixture assumptions after findings 208–209.
The live reinstall journey still expected an automatic saved-terminal picker. It now checks the
ordinary outline's exact selected terminal ID through AT-SPI, rejects a picker frame, and retains
its existing daemon PID, child PID, attachment and unchanged-database checks across actual Debian
package replacement. Its runner supplies a D-Bus session for that accessibility inspection.

The workspace ownership and catalog-count fixtures had relied on every imported project rendering
collapsed, despite its persisted expanded default. Their project-only arrow sequences and collapsed
aggregate badges now seed `isExpanded = false` explicitly and first assert the imported default.
The project-create fixture instead keeps expanded branches and identifies project rows by their
semantic controls, allowing the new terminal child to remain visible. No product behavior was
changed to satisfy these tests; the native multi-project journey still covers expanded defaults,
independent branches, selected-runtime restoration and failed-write rollback.

The complete installed Wayland lane passes at both scales, including AT-SPI actions, physical seat
pointer/keyboard routing, title reveal, Unicode composition and wheel/smooth scrolling:
`out/parity-restored-outline-wayland.log`, evidence `out/wayland-smoke.1Ul53r9K`. The title-reveal
frame was inspected (the BMP was decoded to `input/title-reveal.png` for viewing). The successful
live-reinstall capture was also inspected at
`out/bundle-smoke/restored-outline.aJiIipm1/installed-out/reinstall-reattached.png`.

The full-window comparison uses the actual Mac shell capture
`.build/ui-evidence-reports/20261016-212856-83986/current/sidebar-edge-reveal-threading-light-hovered.png`;
the `chrome-threading-*.png` theme sentinel is a conversation render, not a whole-window reference.
The sidebar footer and top window toolbar remain absent from Linux. A further concrete mismatch
is visible in the Wayland shell: a newly opened project shell gets the project name/identity in its
page header (`WindowHarness` cases 8/9), while restoration gets the saved terminal name/identity.
That header/reveal discrepancy is addressed in finding 211; this verification pass did not claim full UI parity.


All installed runtime journeys now pass, composed across the resumed runs rather than claimed as
one uninterrupted green suite. `out/parity-restored-outline-bundle-runtime-verified.log` covers
archive/non-root installed startup and live reinstall (`restored-outline.aJiIipm1`);
`out/parity-restored-outline-bundle-tail-verified.log` covers workspace ownership, saved-session
Actions and Open In (`restored-outline.ZAxQjySA`);
`out/parity-restored-outline-bundle-tail-catalogue.log` covers delayed agent admission, Actions and
project Actions (`restored-outline.zXnU2PrG`); and
`out/parity-restored-outline-bundle-tail-create.log` completes project creation, composer/document/
conversation/diff surfaces, native Codex and Claude, both-scale native permission journeys,
provider/account/count/large-outline checks, terminal restart/refusal/catalog limits, cwd identity
and desktop launch (`restored-outline.STjBycRy`). These directories are under `out/bundle-smoke/`.
Earlier failing attempts remain alongside them, including a local resume-helper attempt that
omitted `cd /tmp`; it failed before its first product journey and was corrected separately.
The archive/package are the unchanged finding-209 artifacts. This pass did not repeat builds,
portable compiled contracts or the Mac visual catalogue. Python runner tests, both source-copy
verification commands, shell syntax and `git diff --check` pass. No baselines were approved or
changes committed.


## 211. A newly opened shell keeps its terminal page identity

The shell header was built before its worker committed the terminal record and permanently kept
its project's name, identity and reveal closure. Startup restoration already used the terminal
record, so the same shell changed its page name and reveal destination merely by reopening the app.
Mac's `PageTitleView` names the page and reveals its own sidebar row.

`GraphicalTerminal` now retains the saved name beside its typed terminal ID after the creation
receipt is consumed. Reconciliation updates the mounted `WorkspacePaneChrome` and active reveal
target together, only when that exact runtime still owns the active pane. The header cancels any
old header/menu gesture and republishes its native geometry/accessibility identity, without
replacing the terminal pane, PTY or input owner. Returning through a project's cached shell command
uses the retained metadata immediately. Before commitment, the header simply says `Terminal`.

The first new native catalog assertion exposed a second path: restarting an exited saved shell
replaces its runtime object, so that object also needs the existing saved title alongside the ID.
The saved activation route now supplies both from its already-bounded row snapshot. The failed
first attempt remains in `out/parity-terminal-page-native-20261017/catalogue-1/journey.log`.
Neither path adds synchronous store access, per-frame catalog scanning or another extension
surface. The existing at-most-eight receipt loop and bounded row projection keep ownership;
`PageTitleView` still owns visible header presentation.

Final release build: `out/parity-terminal-page-build-final.log`. The native X11 workspace and
Open In journeys pass, including clipboard, held mouse ownership, blocked-selection input, PTY
resize and exact external-app paths. The saved-terminal journey passes at 1× and 2× through fresh
creation, live reuse, same-ID restart, cached project activation and AT-SPI header reveal of the
exact focused child. A folded parent opens durably while every other project/terminal field stays
unchanged. The 512-row/eight-runtime capacity and import-refresh journey also passes. Logs and
inspected images are in `out/parity-terminal-page-native-final-20261017`.

The rebuilt archive and Debian package are recorded in `out/parity-terminal-page-package.log`.
A clean Ubuntu install without Swift or the checkout passes the complete changed saved-terminal
journey at both scales (`out/parity-terminal-page-installed.log`, evidence
`out/parity-terminal-page-installed-20261017`). The complete header bands are decoded-RGB-identical
to the source-build captures at both scales; the installed 2× window was inspected.
The full installed Wayland lane passes rendering at both scales, accessible actions, physical seat
input, Unicode composition and smooth/wheel scrolling (`out/parity-terminal-page-wayland.log`,
`out/wayland-smoke.JQIvEr2y`). Its real title click now asserts the durable terminal ID rather than
the parent project. The resulting shell was inspected and compared in the display panel with
finding 210's Wayland capture.

Twelve Python runner contracts, both source-copy checks and `git diff --check` pass. The full
installed Debian runtime suite and Mac visual catalogue were not repeated for this Linux-only
header change; finding 210 records the prior full runtime coverage. No baselines were approved or
changes committed. Full UI parity remains incomplete, including window toolbar/footer. The fresh
shell creation selection discrepancy observed here is addressed in finding 212.


## 212. Opening a project shell selects its child without taking keyboard focus

Mac's shell creation route selects the terminal child. Linux previously retained the project row
until explicit title reveal, even after finding 211 corrected the page header. Project-shell
activation now reveals the exact saved terminal in the ordinary outline, opening its parent
through the existing durable expansion path while leaving keyboard input in the terminal.
Cached project-shell activation uses the known identity immediately. A fresh shell retains one
pending reveal intent for its exact runtime until the worker publishes the committed record.
Sidebar navigation or switching panes cancels that intent; returning focus to the pending terminal
does not revive it and overwrite the user's newer selection.

The creation receipt now publishes after the database and host lock close. Parent revelation may
immediately request an expansion write, so publishing under the creation lock could refuse that
legitimate write. The deferred receipt still publishes an already-committed terminal if the later
selected-terminal write fails. No spawn/retry authority changes, synchronous UI I/O, unbounded
catalog work or new customization surface were introduced. The existing bounded receipt loop,
outline projection and expansion worker retain ownership.

`terminal_creation_selection_smoke.py` controls the first handshake through a single connection
to the real daemon. At both scales it proves immediate selection, durable parent expansion,
terminal keyboard focus and exact attached child reuse. Its delayed case navigates to Beta and
returns focus to the pending Alpha shell before releasing the handshake: Beta stays selected,
Alpha stays folded and no expansion write is requested. The fixture runs in both native-window
and installed-package runners. Source evidence is in
`out/parity-created-selection-native-20261017`; both 2× scenario captures were inspected.

Existing project-only navigation fixtures now explicitly fold the selected terminal's parent
through real input before walking project siblings. Project menu fixtures assert the exact new
terminal identity, and catalog/cwd fixtures account for the already-expanded creation parent.
The first workspace regression exposed a stale context-menu row lookup that could choose the new
terminal child; it now resolves another durable project ID. That failed attempt remains in
`out/parity-created-selection-regression-20261017`. The final workspace, project creation, Open In,
both-scale catalog and capacity journeys pass in
`out/parity-created-selection-regression-final-20261017`. The before/after shared-runtime capture
was displayed for comparison.

The release build and rebuilt archive/Debian package are recorded in
`out/parity-created-selection-build.log` and `out/parity-created-selection-package.log`.
The complete installed Wayland lane passes at both scales
(`out/parity-created-selection-wayland.log`, `out/wayland-smoke.EfVhK6HG`). A focused physical-input
rerun adds explicit child-selection and terminal-focus assertions before title reveal and passes
(`out/parity-created-selection-wayland-input-final.log`, `out/wayland-smoke.o4NmPFCG`); its initial
shell capture was inspected. The first local focused runner omitted its project directory and
failed before product startup; its separate failed log remains preserved.

The installed runtime sweep passes archive/non-root startup, actual live-child Debian reinstall,
workspace ownership, Actions/Open In, delayed agent admission, project controls, conversation
surfaces, Codex/Claude, permissions, accounts and multi-project restoration in
`out/parity-created-selection-bundle-runtime.log` (`out/bundle-smoke/created-selection.WkxENvjl`).
It then exposed a window-lookup race in the new creation fixture: the PID-only X11 search returned
a window that disappeared before Return, producing `BadWindow`. The fixture now waits for the
accessible project selection and matches the visible product window by both PID and title, as the
other native journeys do. This is a fixture correction; the tested package is unchanged.

The resumed installed tail passes both new scenarios at 1× and 2×, the 5,100-project/1,024-terminal
outline, restart/refusal/catalog/capacity checks, live cwd tracking and identity guards, and desktop
launch (`out/parity-created-selection-bundle-tail.log`,
`out/bundle-smoke/created-selection.ltIwhsgk`). Together the two runs cover the complete installed
runtime suite; this was not one uninterrupted green run. Both installed 2× scenario captures were
inspected. All four sidebar captures are decoded-RGB-identical to their source-build counterparts
(`out/parity-created-selection-installed-pixels.log`). Twelve Python runner contracts, both vendor
identity checks, shell syntax and `git diff --check` pass. No Mac product source changed in this
pass, and the Mac visual catalogue was not repeated. No baselines were approved or changes
committed. Full UI parity, including the window toolbar/footer and remaining typography and
surface differences, is still unfinished.


## 213. The empty sidebar is a message, not a selected project

The installed empty workspace rendered a selected orange `Add project folder…` row where the
Mac shell centers `No Projects` and its folder-import hint. The two-label presentation now lives
in `UI/Design/SidebarEmptyState.swift`, used by the existing lazy Mac mount and symlinked into the
Linux shell. Linux mounts it only for an empty ordinary project list, hides it for menus/imported
projects, and exposes its text as the empty list's accessibility description. There are zero
project rows and zero selected children. The real header Add Project control and keyboard import
route remain available.

The hint promises folder drop, so SDL file-drop events now enter the existing asynchronous import
gate. The event copies one path of at most 1,023 bytes and refuses oversized payloads without
truncation; SDL-owned payload memory is released for both file and text drops. The worker validates
an existing directory and uses LinuxHost's canonical import/identity path. The existing single
pending-import gate bounds concurrency, and no file, process or database work enters the UI actor.
The presentation and import operation remain host-owned; no extension surface was added.

The new native fixture drives a GTK drag source with real XTest pointer input into SDL, rather
than injecting a host command. At 1× and 2× it checks the empty list/description, live light/dark
appearance, ordinary-file refusal, a Unicode/spaced folder import and duplicate identity, with no
PTY child created. The fixture is included in both native and installed runtime runners. GTK's
Python introspection package is a test dependency only. The first attempt lacked that package;
the first compile also exposed the Linux font adapter's missing `emphasizedBody` role. Both were
corrected without changing the shared component's typography.

The final release build is `out/parity-empty-sidebar-build-final.log`. Native logs and inspected
light/dark/imported captures are in `out/parity-empty-sidebar-native-final-20261017`. The prior
installed empty frame and new source frame are displayed for comparison. The rebuilt archive and
Debian package are recorded in `out/parity-empty-sidebar-package.log`.

The clean installed subset passes archive/non-root startup, provider PATH, both-scale empty
sidebar/drop journeys, all three Add Project choices and desktop launch
(`out/parity-empty-sidebar-installed.log`, `out/bundle-smoke/empty-sidebar.FvvUZAiq`). The local
subset helper inherited the full runner's overbroad final success label; its log now records the
actual scope explicitly, and the helper's label is corrected for future use. The full installed
runtime suite was not repeated. Both appearances' sidebar pixels match the source-build captures
exactly at both scales (`out/parity-empty-sidebar-pixels.log`); the installed 2× light frame was
inspected.

The focused real Mac shell evidence passes (`out/parity-empty-sidebar-mac.log`,
`.build/ui-evidence-reports/20261017-014955-76663`). Its Threading light capture was inspected, and
the empty navigator area is decoded-RGBA-identical to the pre-extraction reference in both
appearances. The greeting outside that area changes with time and is not part of this claim.
This narrow extraction did not repeat the full Mac catalogue.

The complete installed Wayland lane passes rendering at 1×/2×, accessible actions, physical seat
input, Unicode composition and smooth/wheel scrolling (`out/parity-empty-sidebar-wayland.log`,
`out/wayland-smoke.oJMgJB4H`). Native folder drop itself is verified through X11 only; Wayland drop
remains unverified. Twelve Python runner contracts, both vendor identity checks, shell/Python
syntax and `git diff --check` pass. No baselines were approved or changes committed. Full UI
parity remains incomplete: the empty right-pane welcome/composer, toolbar/footer, and remaining
typography/ink differences are still visible in the shell comparison.

## 214. The idle workspace keeps its session composer standing

The Mac shell already presents its opening composer, while Linux first showed a separate
`No Session Selected` / `New Session` screen (and a different empty-store welcome). Linux now
mounts one composer immediately, even when project or agent choices are missing. Escape returns
keyboard focus to the navigator without discarding the editor, draft or accessible identity.
Project selection and folder import update the destination while preserving the draft. Explicit
New Chat still starts a fresh brief. The Mac's project-switch draft-reset behavior is not claimed
by this incremental Linux lifecycle.

Launch derives the current project and provider-qualified account from host state. Missing
choices, an empty/provisional brief and pending project selection/import prevent submission.
Empty project/agent chips also expose their disabled state and zero actions through AT-SPI.
Import completion is consumed before composer submission and presentation, so the first imported
project updates the form in the same frame. Project choice values are projected only when the
project snapshot changes; typing reads cached admission booleans. Account choices remain capped
at 64 and popup views at six. Host authority covers destination, identity, draft lifecycle and
launch; the presentation uses existing Design controls without adding an extension surface.

Release build `out/parity-standing-composer-build-gates.log` and package build
`out/parity-standing-composer-package.log` pass. The native composer/account and both-scale empty
sidebar/drop journeys pass in `out/parity-standing-composer-native-final-20261017`; inspected
captures include the imported Unicode project with its retained draft, compact 560×180 form,
and light/dark empty states. The accessibility and Add Project tail passes in
`out/parity-standing-composer-native-tail-resolved-20261017`. Updating that older accessibility
fixture also removed stale assumptions about combo-box roles, disclosure-edge clicks, project
headers after terminal creation and accessible row objects across an outline rebuild. Its exact
geometry, focus and read-only terminal text contracts remain enforced. Earlier failing attempts
are retained separately.

Real IBus Pinyin preedit, Escape cancellation, `你好` commit and no premature launch pass
(`out/parity-standing-composer-ime.log`). Twelve Python runner contracts, vendor identity checks,
Python/shell syntax and whitespace checks pass. No Mac source changed in this increment, and no
Mac catalogue or baseline acceptance was run. The full UI remains visibly incomplete: the hero
mark/greeting, prompt border and options, toolbar/footer, and broader composer behavior still
need parity work. Native folder drop remains verified through X11 only.

Installed Wayland rendering at both scales, AT-SPI actions and physical seat controls pass in
`out/parity-standing-composer-wayland.log` (`out/wayland-smoke.Z9Rtembr`). Its composer fixture
initially armed a one-shot screenshot after all relevant events had already settled; moving the
pointer to force a frame then captured an intermediate chip hover. The fixture now establishes
the start caret, waits for its post-presentation accessibility state, and arms capture before the
edit that returns to the tail. It retains exact whole-frame comparisons rather than masking the
hover difference. The corrected focused lane passes Unicode entry, wheel/smooth scrolling, exact
project launch and PTY isolation (`out/parity-standing-composer-wayland-composer-final.log`,
`out/wayland-smoke.NLJOptLy`); its opening-brief render was inspected. The earlier attempts remain
in their own evidence directories. The source before/after welcome comparison is displayed.

The clean installed runtime sweep (`out/parity-standing-composer-bundle-runtime.log`,
`out/bundle-smoke/standing-composer.k8w9qRAH`) passes archive/non-root startup, provider PATH,
live-child reinstall, workspace/input, Actions, provider admission, composer/account, native
conversation/permission at both scales, shared content renderers, Add Project, provider artwork,
account picker and project-count journeys. The multi-project fixture then reached a stale
`New Session` assertion; it now resolves the standing form's Start Session control by identity and
checks its disabled state and exact narrow-window bounds. That complete outline journey passes
in `out/parity-standing-composer-bundle-tail.log`
(`out/bundle-smoke/standing-composer-tail.2hG4n48K`). Its narrow dark render was inspected.
The first empty-sidebar tail check also exposed a fixture-isolation error: it compared complete
shared-daemon records even though earlier journeys leave records whose uptime continues to
advance. It now saves both snapshots and compares exact session IDs/PIDs, retaining the no-new-
child contract without requiring unrelated runtime metadata to stand still. The corrected run's
snapshots confirm that only `uptimeSeconds` changed at both scales.

The installed 2× empty/imported renders also expose a remaining prompt-surface defect: before
editing, the field fill spans only y=636…701; after importing with a draft it spans y=636…815
in the same 1280×900 window (sampled inside the field at x=535). The standing form still lets the
text view paint that fill instead of giving the whole viewport the shared `PromptChrome` surface.
This is recorded for the prompt-anatomy work, not counted as visual parity in this increment.

The final clean installed tail passes (`out/parity-standing-composer-bundle-tail-final.log`,
`out/bundle-smoke/standing-composer-tail.dd6bg0Yy`): creation selection and empty-sidebar import
at both scales, the 5,100-project native outline, saved-terminal restart/refusal/catalogue/capacity,
cwd ownership/tracking and desktop launch. The installed 2× empty render and the packaged composer
were inspected. Together with the successful prefix and corrected multi-project run above, this
covers the complete installed runtime suite against the same package; it was not a single
uninterrupted green invocation. No code was committed and no baseline was approved. The 1:1 UI
goal remains active.

## 215. The opening prompt owns its whole surface and follows the Mac's dimensions

The standing form still painted its field through the text document. On a cold 2× empty frame
that filled only 66 pixels of a 180-pixel viewport, then expanded after editing. The document is
now transparent inside a `PromptChrome` surface, which owns the field fill, border, corner shape
and whole-box focus ring independently of document height. The opening column cap (720 points)
and minimum prompt height (116) now live in the shared boundary and the Mac controller aliases
those unchanged values. Linux uses the Mac's 32-point pane margin, bottom alignment and 10-point
row spacing, with bounded pressure relief at its smaller supported minimum window. The prompt
grows upward from 116 to the shared 180-point ceiling before scrolling.

The height calculation reads the retained TextKit layout used by the editor; unchanged-width
pointer/wheel events reuse that cached document, and the host adds only constant work. The form
still retains one editor/surface and bounded chooser rows. Destination, account, draft, launch
and input authority stay host-owned; no extension slot was added. The opening footer options,
attachments and hero/greeting remain incomplete.

Rendered tests caught the first focus implementation reading the old `firstResponder` from
inside its transition callback: the accent ring appeared when focus left the editor. It now uses
the callback's supplied focus state, as the reply composer does. The native composer journey
checks the actual two-point focus and one-point resting border, 720-point centered width,
116-point resting/180-point grown height, Unicode editing, exact tail scrolling, the compact
window and single launch. The empty-sidebar journey checks a continuous field-color strip through
the full cold viewport in both appearances at 1× and 2×, then retains its native import/draft and
process-identity assertions. Theme captures now wait for both panes' presentation.

The changed layout also exposed an existing input defect: one motion leaving the navigator for
the composer returned only navigator cancellation. The bridge now emits a combined crossing
(event 27/action 7), and the host clears the old hover then dispatches that same motion to the
composer. The reverse crossing already had the corresponding action 6. No synthetic event is
queued behind the next click. The C pointer contract covers both directions and retained gesture
ownership; the real accessibility journey deterministically crosses each way. Its setup accepts
ordinary navigator motion or the existing reverse-crossing event, depending on the initial pointer.

Release builds are recorded in `out/parity-opening-prompt-build-focus.log` and the final
`out/parity-opening-prompt-build-crossing.log`. The main native composer/account and both-scale
empty-field/import journeys pass in `out/parity-opening-prompt-native-focus-20261017`; focused,
compact and 2× cold-empty renders were inspected. The final accessibility/Add Project tail is
`out/parity-opening-prompt-native-crossing-final-20261017`. The pointer contract passes in
`out/parity-opening-prompt-pointer.log`. Earlier failed focus/crossing attempts remain separate.

The focused Mac composer catalogue passes (`out/parity-opening-prompt-mac.log`,
`.build/ui-evidence-reports/20261017-022902-72069`). System's empty state and the Cyberpunk and
Swiss Minimalist short forms were inspected. The Mac's values did not change; this is not a
complete Mac catalogue run or baseline approval. The Linux before/after empty form is displayed
for comparison. Twelve Python runner contracts and both vendor identity checks pass.

The final package builds successfully (`out/parity-opening-prompt-package-final.log`). Its clean
Ubuntu installed subset passes composer/account, empty field and native import at both scales,
Add Project, narrow multi-project outline and desktop launch
(`out/parity-opening-prompt-installed-final.log`, `out/bundle-smoke/opening-prompt.26FMyHrt`).
The final installed 2× cold-empty field and typed composer renders were inspected. This increment
reruns that relevant subset; the complete installed runtime coverage is recorded in finding 214.

The complete installed Wayland actions lane also passes in one final invocation
(`out/parity-opening-prompt-wayland-final.log`, `out/wayland-smoke.rncwiNS5`): rendering at both
scales, AT-SPI actions, physical seat controls, Unicode composer entry, wheel/smooth scrolling,
exact project launch and PTY isolation. Its opening composer render was inspected. Real IBus
Pinyin preedit, Escape cancellation, `你好` commit and no premature launch pass in
`out/parity-opening-prompt-ime.log`. Python syntax and whitespace checks pass. Native folder
drop remains verified through X11 only. No code was committed and no baseline was approved;
the broader 1:1 UI goal remains active.


## 216. The opening welcome shares the Mac's mark, greeting and geometry

The Linux composer still used a terminal-placeholder hierarchy: a 44-point terminal symbol,
15-point provider title and destination caption. The Mac shell instead floats a 40-point
Threading mark above a 20-point semibold greeting, with no default caption. Linux now mounts a
`ComposerWelcomeView` Design boundary around the existing shared mark paths and one primary-ink
wrapping label. `ComposerWelcomeLayout` owns the mark size, 620-point reading measure, three-line
cap and 48-point minimum clearance for both hosts; Mac aliases preserve its previous values.
The 12-point mark/text spacing and pane margins remain Design roles. The whole group centers in
the space above the form and disappears when it cannot fit, rather than clipping behind controls.

`ComposerGreeting` is compiled from the same source on both platforms. Its daypart now directly
names `ThemeWelcomeGrammar.Daypart`, the type the old `ThemeWelcome.Daypart` already aliased.
The date-aware greeting is picked once for a new form and retained through typing, provider
choices, project choices and theme appearance changes. No provider or project data enters the
welcome. The fixed app pool, one label, at most three lines and eight retained mark paths bound
both ordinary and narrow-window work; unchanged text/width reuse label metrics. This is existing
host-owned composer presentation and adds no extension slot. Theme-authored welcome content,
alternate marks, captions, scrims and animation still require Linux implementation.

AT-SPI now publishes the actual greeting with a stable identifier and omits it when the hero is
hidden. Removing the invisible old destination caption leaves project/provider identity on the
corresponding combo boxes. The geometry journey caught the first implementation storing heading
bounds without adding that node to the bridge's component-coordinate dispatch. Both window and
parent coordinate routes now include it; the test also checks that the label is not focusable.
Composer tests observe provider/project changes on their actual chip identities and assert that
the welcome remains unchanged through those choices. The first updated fixture omitted the
chips' existing `Project:`/`Identity:` prefixes; that failed attempt is retained separately.

The first clean installed run passed composer/account, then timed out awaiting the second native
folder drop; no second transfer reached the host log. The fixture terminated the GTK selection
owner 200 ms after releasing the pointer without observing completion, allowing a lifetime race
under concurrent build load. The source now reports
ready/data/end signals with its PID, and the driver waits for both URI delivery and drag end
before terminating it. This replaces the fixed post-release wait; it does not retry a missing
transfer or weaken the import/duplicate/no-child assertions.

The final source build is `out/parity-welcome-build-heading.log` (77.93 seconds). The focused Mac
composer catalogue passes in `out/parity-welcome-mac.log`
(`.build/ui-evidence-reports/20261017-024431-16480`). System, Cyberpunk and Swiss Minimalist empty
welcomes and the styled short forms were inspected. Against finding 215's focused report, 28 of
41 decoded images match exactly; the other 13 differences are confined to greeting text bounds
(the fixture selects live greetings). This is not a complete Mac catalogue or baseline approval.
The Linux before/after welcome comparison is displayed, and the 2× dark empty shell was inspected.
Real IBus preedit, Escape, `你好` commit and no early launch pass in `out/parity-welcome-ime.log`.


The final native suite passes in `out/parity-welcome-native-verified-20261017`: composer/account,
light/dark empty welcome and real folder imports at 1×/2×, empty/full accessibility, heading
coordinates and Add Project. The 2× light shell was inspected, and each drop's log now records
ready, data and end for its own selection-owner PID. Earlier failed source runs remain in
`out/parity-welcome-native-20261017` (fixture chip labels) and
`out/parity-welcome-native-final-20261017` (heading coordinate dispatch).
Twelve Python runner contracts, both vendor identity checks, changed Python syntax and whitespace
checks pass. The final installable package is recorded in `out/parity-welcome-package-final.log`.


The final clean installed subset passes in `out/parity-welcome-installed-final.log`
(`out/bundle-smoke/welcome.d0EleO28`): composer/account, both-scale empty welcome/import,
Add Project, narrow multi-project outline and desktop launch. The installed 2× empty welcome
and 320-point narrow pane were inspected. The full installed runtime suite was not rerun;
finding 214 records its preceding coverage. The initial failed installed run remains at
`out/parity-welcome-installed.log` (`out/bundle-smoke/welcome.dcBjaD51`).

The complete final installed Wayland actions lane passes in `out/parity-welcome-wayland-final.log`
(`out/wayland-smoke.U04DrfzK`), including 1×/2× rendering, AT-SPI, physical seat controls,
Unicode composer input, wheel/smooth scrolling, exact project launch and PTY isolation. The final
Wayland welcome render was inspected. Native folder drop remains verified on X11 only. Prompt
footer/options, attachment controls, toolbar/footer and wider theme support remain incomplete;
no baseline was approved and no code was committed. The full 1:1 UI goal remains active.


The compact 2× Actions journey also passes (`out/parity-welcome-actions-20261017/actions.log`),
including disabled empty-store commands, chooser cancellation, pointer/keyboard/AT-SPI commands,
bounded menu scrolling, focus isolation, exact shell reuse and named-account provider creation.
Its standing-form assertion resolves the editor by identity: at that height the greeting is
correctly absent. Native app logs are retained beside the journey log.

## 217. The opening prompt carries a real permission choice

The Linux composer previously fixed every new session to Manual in its launch worker while
omitting the Mac's permission footer. It now mounts the production `ChipView` inside the prompt,
using shared `PermissionModeLabels` for the hand mark and inheritance wording and the existing
`AgentPermissionMode` titles, descriptions and Codex caveat. `PromptChrome.contentFrames` supplies
the same 12-point horizontal inset, 10-point vertical inset/gap and 26-point footer within the
existing 116/180-point prompt limits. The existing five-control key loop includes the footer,
and the editor retains Return for a newline and Super+Return for submission.

New briefs still start at Manual. The six explicit choices and Use Agent's Setting travel from
host state through `AgentSessionCreation` into the durable record and the existing provider
command builders. Nil emits no permission override. This does not claim Mac Settings/account
inheritance resolution. Project and identity changes retain the draft choice; explicit New Chat
resets it. Permission selection, persistence and launch remain host-owned, with no new extension
slot. The fixed seven-value menu measures once on open and mounts at most six shared rows;
AT-SPI exposes the same chip, rows and full explanations. Shared menu width limits still apply.

The real window journeys found two existing assumptions exposed by the footer. Menu dismissal
used top-level project/provider frames; it now resolves the selected chip and converts through
its actual parent hierarchy, so a repeated permission-chip click dismisses the popup. After a
compact/full-window round trip, cached text left the document's hit area at its old short height.
`NSTextView` now observes the clip viewport and updates its document floor from cached layout in
constant time, without reshaping text for a height-only resize or wheel event. The text-editor
harness checks unchanged used-text geometry and a window-dispatched click in the expanded blank
area. The first failed composer journey remains in `out/parity-permissions-native-20261017`.

Visual review then found an accessibility focus split: the native input flag moved to the
composer while the Swift host still considered the navigator focused. Accepted choice actions
now update both authorities. The stronger installed test reproduced the old package's missing
focus border (`out/parity-permissions-installed.log`,
`out/bundle-smoke/permissions.98hR4sb1`). It checks physical typing after the accessible choice
and compares the real focused/resting prompt border rather than trusting only AT-SPI focus.

The focused Mac composer run passes in `out/parity-permissions-mac.log`
(`.build/ui-evidence-reports/20261017-030309-64378`). System Codex Auto, Cyberpunk short and Swiss
Minimalist short renders were inspected. Against finding 216, 30 of 41 decoded images match
exactly; the other 11 differences remain confined to live greeting text. This is a focused
catalogue, not complete platform coverage or baseline approval. The Linux before/after prompt
comparison is displayed; normal, compact, permission-menu and dark footer renders were inspected.

Before the final accessibility-focus correction, the complete relevant native subset passed in
`out/parity-permissions-native-final-20261017`: composer, all 14 permission/provider choices,
named account, empty/import at both scales, empty/full accessibility and Add Project. The shared
text-editor harness passes in `out/parity-permissions-editor.log`; real IBus preedit, Escape,
Chinese commit and no premature launch pass in `out/parity-permissions-ime.log`. The compact
2× Actions journey passes in `out/parity-permissions-actions-20261017/actions.log`. The earlier
installed Wayland actions lane also passes in `out/parity-permissions-wayland.log`
(`out/wayland-smoke.4YypF4yq`). Final-package verification is recorded below.

The final source build is `out/parity-permissions-build-focus.log` (55.13 seconds), and the final
package is `out/parity-permissions-package-final.log`. The final composer and all 14 permission
cases pass in `out/parity-permissions-native-verified-20261017`, including physical typing and
focus-border comparison after accessibility selection. Final light/dark footer captures were
inspected. Twelve Python runner contracts, both vendor identity checks, shell syntax and
whitespace checks pass.

The final installed Wayland actions lane passes in `out/parity-permissions-wayland-final.log`
(`out/wayland-smoke.LWwdfr6x`): both rendering scales, AT-SPI actions, physical seat controls,
Unicode composition, wheel/smooth scrolling, exact project launch and PTY isolation. Its final
opening-footer render was inspected. The installed X11 dark permission footer was also inspected
and shows the corrected focus border.

The clean installed X11 subset passes in `out/parity-permissions-installed-final.log`
(`out/bundle-smoke/permissions.q8J3gDqh`): composer, all 14 permission/provider cases with the
stronger focus check, named accounts, empty/import at both scales, Add Project, narrow outline
and desktop entry. This is the relevant subset rather than a rerun of the complete installed
runtime catalogue from finding 214.

The last menu review found wheel input unhandled by the choice presenter, while the seventh
option could only be reached by keyboard. The shared composer choice host now
consumes wheel input inside the popup, accumulates fractional steps and updates its bounded
rows. The permission fixture reaches Bypass Permissions with native wheel events for both
providers and captures the scrolled popup. This also covers project and account menus through
the same presenter. The wheel-support build/package logs are `out/parity-permissions-build-wheel.log`
and `out/parity-permissions-package-wheel.log`; verification follows below.

The latest source composer and all 14 permission cases pass in
`out/parity-permissions-native-wheel-20261017`. The latest clean installed permission/account
subset and desktop launch pass in `out/parity-permissions-installed-wheel.log`
(`out/bundle-smoke/permissions-wheel.h0LdRULh`), including both providers' wheel-selected final
option, saved mode, exact argv, physical typing and focus pixels. The scrolled source Codex and
installed Claude menus were inspected. The full installed X11 subset immediately preceding the
wheel-only correction is recorded above; the complete runtime catalogue was not rerun.

The latest installed Wayland actions lane also passes in
`out/parity-permissions-wayland-wheel.log` (`out/wayland-smoke.qi5xfibb`); its opening-footer
capture was inspected. This lane checks the existing Wayland input/scroll/launch contracts;
the new permission-menu wheel selection itself is verified on X11. The 12 runner contracts,
changed Python syntax, shell syntax and whitespace checks pass. No baseline was approved and
no code was committed. Model/effort, speed, surface selection, attachments, remaining toolbar
and footer controls, and wider theme behavior remain incomplete. The full 1:1 UI goal stays active.

## 218. Model/effort picker portability groundwork, 2026-10-17

The next opening-composer gap is the shared model-by-effort matrix. The existing Mac control
now compiles through a Linux source link; only its Mac view controller, InjectionNext hooks and
haptic calls are platform-guarded. Its drawing, selection, keyboard and accessibility logic
remain shared. This finding is groundwork, not a claim that Linux users can choose a model yet:
the opening composer still needs a bounded account-catalogue worker, a mounted picker,
selection/admission semantics, accessibility projection and fresh/resume launch wiring.

The first Linux build identified actual compatibility gaps rather than requiring another picker:
tracking areas had no continuous mouse-moved delivery, focused cells could not scroll into view,
radial gradients and symbol palette composition were absent, and the Linux theme boundary did
not expose accent-muted. These contracts now exist. Pointer tracking visits the old/current hit
paths, stops behind an overlay and respects key-window activation. Focus reveal scrolls the
nearest document clip on both axes, without changing an already visible rectangle. Palette
composition keeps size/weight, applies the one supported ink to source alpha, and preserves
geometry for palette-only configuration. Radial fills interpolate once per visible device pixel
under the path and inherited clip, with no intermediate bitmap or overlapping translucent rings.

The matrix previously scanned every model before rejecting offscreen rows. It now computes its
dirty row range directly. Linux view drawing receives its ancestor-clipped visible rectangle,
so a tall document no longer receives its complete height as the dirty region. The existing
`ViewClippingHarness` now checks a 1,000-row document's distant-cell reveal and exact dirty
viewport, repeated pointer moves, cover/key-window transitions, transformed radial alpha and
actual palette pixels. All pass in `out/parity-model-picker-contracts.log`.

`AgentModelOption.swift` contains the existing reasoning/model/default value types, while
`ProviderModelCatalog.swift` contains the existing pure Codex decoder and Claude/config helpers.
Both are byte-identical core-slice entries. The Mac `AgentModels` caller keeps bounded reads,
cache freshness, direct-catalogue precedence and account/default policy. Its focused provider
settings/default/catalogue tests passed: 34 executed, one skipped, no failures in
`out/parity-model-catalog-mac.log`. The complete existing Linux core contract executable also
passes in `out/parity-model-picker-core.log`; this does not test a Linux catalogue worker that
has not been implemented.

The Release host build passes in `out/parity-model-picker-shim-build.log` (69.33 seconds), with
the final palette-only sizing adjustment linked by `out/parity-model-picker-final-build.log`.
The package log is `out/parity-model-picker-package.log`. Both vendor checks pass with 131 core
files, and all 12 Python runner contracts pass. No user ACP changes were overwritten.

The focused Mac shipping-popover render passes and all six current images were inspected in
`.build/ui-evidence-reports/20261017-033510-46563`. The baseline report has four changed and two
unbaselined images. The older baselines lack the current hidden-model footer, separate provenance
line and diamond Ultra treatment; those presentation changes predate this portability edit.
This is not an exact before/after comparison or full-platform catalogue, and no baseline was
approved. Linux matrix pixels themselves remain unverified until the real composer mounts it.

One installed-test launch began before package assembly finished and correctly refused the
incomplete DEB (`out/parity-model-picker-installed.log`, evidence
`out/bundle-smoke/model-foundation.iT4RIbSC`). The package completed before the final installed
run was started. The concurrent Wayland installation waited long enough to install the finished
package; its installed WindowHarness SHA-256 was checked against the packaged executable:
`05a722f83aeabe4d7e398e8c7dab53257fa5cb09bdf8f13f782e07cad2aa6e3b`.
Final runtime verification is recorded below.

The final source X11 subset passes in `out/parity-model-picker-native-20261017`: composer,
all 14 permission/provider choices, named accounts, empty/import at 1×/2×, empty/full AT-SPI and
Add Project. The light focused composer and dark permission footer were inspected. The installed
Wayland actions lane passes in `out/parity-model-picker-wayland.log`
(`out/wayland-smoke.uYL7mYyQ`): both rendering scales, accessibility, physical seat input,
Unicode composer, wheel/smooth scrolling, exact launch and PTY isolation. Its opening capture
was also inspected. These are regression checks of the existing shell, not Linux picker evidence.

The three focused Mac picker interaction/presentation contracts also pass in
`out/parity-model-picker-mac-contracts.log`. All 16 source composer captures have identical
decoded RGBA pixels to the preceding verified permission-wheel build. That exact regression
comparison covers the existing Linux composer only.

The complete installed X11 runtime runner (`tests/bundle_runtime_smoke.sh`, using the already
built package in a clean Swift-free Ubuntu image) passes in
`out/parity-model-picker-installed-final.log`, with evidence in
`out/bundle-smoke/model-foundation.0aQMSI43`. This covers startup and live reinstall, Actions and
Open In, all composer permission choices, shared documents/diffs/streaming, native Codex and
Claude conversations and decisions at both scales, account/provider rows, expansion persistence,
folder drop, large outlines, saved-terminal restart/refusal/capacity/cwd identity, and desktop
launch. Installed minimum-window, scrolled opening composer and 2× grown native composer
captures were inspected. The baseline comparison and unmounted-picker limits above still apply.

No code was committed and no baseline was approved. Account catalogue worker, mounted Linux
matrix, model/effort selection persistence and launch wiring remain the next work. The full
1:1 UI goal remains active; this finding closes only the compatibility groundwork.

## 219. Opening model/effort integration checkpoint, 2026-10-17

The Linux opening composer now mounts the production model/effort matrix and shared content
body behind its CPU chip. Mac and Linux use one presentation factory for the account-default
row, Auto effort and supported combinations. The host reads the exact selected account on a
serial worker, with one active read and one coalesced pending request; stale receipts cannot
replace a different account's catalogue. Settings/state files cap at 1 MiB, Codex's cache at
16 MiB, admitted models at 512 and distinct effort columns at 32 plus Auto. No model cache
means Codex keeps CLI inheritance and a disabled picker, without an invented catalogue.

Explicit choices enter the existing session record and portable launch builders. Codex's
reasoning override is a TOML string inside its own shell operand, including on resume. Fresh
launches re-read and validate the selected account's catalogue before saving a session. A
catalogue refresh retains an invalid explicit choice and disables Start until corrected;
keyboard submission uses that same gate. Account changes and New Chat clear model/effort;
project changes retain them. The brief survives identity changes. Linux does not yet restore
per-account last-successful choices or implement hidden-model preferences.

The shared matrix now supports Home/End and Page Up/Down, preserving the effort where available
and falling back to Auto on an unsupported row. Arrow navigation still skips unsupported
combinations. Linux maps physical Space to the AppKit key code used by the grid. AT-SPI
publishes only visible clipped cells (maximum 128), with separate focused and selected/checked
state, and refuses stale composer/popup identities. The real product shell remains the host;
its existing menu surface still approximates the Mac popover's complete chrome.

The first shared-body refactor shifted label alignment and legacy-theme rounding on Mac.
Restoring native constraints inside the shared Mac body fixes those differences. All six
current picker images in `.build/ui-evidence-reports/20261017-041023-19418/current` have exactly
the same decoded RGBA pixels as §218's `20261017-033510-46563` images. The Windows 98 result was
inspected again. Four focused interaction/presentation contracts, including boundary navigation,
pass in `out/parity-model-composer-mac-contracts.log`. The render log is
`out/parity-model-composer-mac-final-render.log`. This is focused evidence, not a full Mac UI
catalogue run; the pre-existing baseline differences in §218 remain unapproved.

The initial Linux build crashed inside SwiftPM/libdispatch before compilation
(`out/parity-model-composer-build.log`); its terminal exit was confirmed before retrying.
The retry compiled successfully in 190.30 seconds (`out/parity-model-composer-build-retry.log`).
The first two runtime attempts verified Codex choice/inheritance/resume, then stopped on a
Claude fixture error: it wrote `additionalModels` instead of the provider's actual
`additionalModelOptionsCache`. The fixture now uses the shared parser's real wire key and
scrolls to the additional model before pointer selection. These failed attempts are retained
in `out/parity-model-composer-native-20261017` and `out/parity-model-composer-verified-20261017`.

The new journey is wired into both composer-only/full source runners and the installed runtime
runner. Existing composer, permissions and accessibility expectations include the extra chip.
All 12 Python runner contracts, shell syntax, Python syntax, both vendor verifications (131 core
files), and `git diff --check` pass. No user ACP edits were overwritten.

The user requested a pause at the next good stop during this validation. Package assembly,
installed X11/Wayland checks for this integration, broader theme fidelity, final popover chrome,
and the other full-composer controls remain pending. The last packaged and installed artifact
is still §218. No commit, push or baseline approval was performed. Final checkpoint results
follow below.

The final Linux build passes in `out/parity-model-composer-space-build.log` (52.29 seconds).
An intermediate runtime run caught a real Space activation gap: SDL delivered Space through
committed-text input, where the synthetic AppKit event had key code zero. That boundary now
maps Space to 49 as well as mapping the functional-key path. The final runtime evidence is
`out/parity-model-composer-final-20261017`: all seven model/effort cases pass, covering physical
Space and arrows, pointer selection, both providers' inheritance, named-account switching with
the brief intact, a 600-model/40-effort input capped to model 511/effort 31 with bounded visible
accessibility cells, stale-catalogue refusal before record/process creation, persistence, and
exact Codex resume arguments. The failed Space run remains in
`out/parity-model-composer-checkpoint-20261017`.

Real Linux light-grid, Claude catalogue and distant-cell captures were inspected. The file
named `codex-selected-ultra-dark.png` still contains light pixels: the fixture waits for the
theme log message rather than completed presentation. It must wait for presented dark pixels
before this image can serve as dark evidence. Dark matrix appearance, 2× matrix interaction,
Wayland model selection and a freshly installed package remain unverified for §219.

The final source runner completed with exit 0 (`out/parity-model-composer-final.log`). Alongside
all seven model cases, the existing composer journey passes its focus loop, scrolling,
project/provider choices, multiline Unicode edits and exact launch. All 14 permission/provider
cases also pass, including Claude's Tab/Shift+Tab traversal through the model chip. The current
build/test processes have finished. Work is paused here at the user's request, with the full
1:1 UI goal unfinished and the validation/packaging limits above preserved for the next turn.

## 220. Commit validation and mainline integration, 2026-10-17

Before committing the accumulated Linux checkpoint, `scripts/test.sh all` ran the full Mac
suite: 10,748 tests, 106 skips, four failing test cases (eight assertions, one unexpected).
Evidence is `out/parity-commit-all.log`. Its failure prevented the wrapper from starting iOS.
The component-gallery coverage check identified the newly extracted picker body and the
Linux-only welcome view. The existing picker story already mounts the body; its component
registry now names it. The textual Mac catalogue audit explicitly distinguishes the welcome
view compiled only under `#if os(Linux)`, whose runtime evidence lives in the Linux shell.
No gallery appearance or application behavior was changed by that correction.

The four-case focused rerun (`out/parity-commit-recheck.log`) passes the gallery coverage check
and `SidebarChatPreviewTests/testTheRowsButtonTakesItsOwnPressInsideTheOutline`. Both simulator
recording cases still time out waiting for their saved movie:
`testARecordingIsVisibleOnTheDeviceAndItsButtonUntilTheMovieIsSaved` and
`testClosingThePaneFinishesARunningRecording`. They are recorded as unresolved validation
failures, not counted as passing or assumed fixed by rebasing. The iOS suite remains unrun.
The Linux runner contracts (12 tests), vendor identity checks and staged whitespace check pass.
The checkpoint includes the existing ACP provider changes alongside the accumulated UI work.

## 221. Rebase onto current master, 2026-10-17

The requested checkpoint is committed and all 113 branch commits rebased onto local `master`
`784c1cc43527c8fe2a29a5de5599a0f312611efe`, which contains fetched `origin/master`
`f9178a72e5ce46c0175a72b69c9ffa164168ebb4` and the local mainline work. The repository names
its mainline `master`. `backup/linux-appkit-before-rebase-20261017` preserves the original
checkpoint `099dda4c0`, including the user's ACP changes. Nothing was pushed.

Extraction conflicts preserve mainline's hook/runtime permission origin and `deferToAgent`
policy, remote launch environment and transcript-mirror lookup (including the existing-file
resume preflight helpers), transcript selection, reading
measure, and Grok's permission flag before the `agent` subcommand. The portable permission
policy accepts the host's optional provider kind, so the Mac still lets runtime-owned hook
approvals reach the runtime before applying a standing mode. Native runtime requests retain
their yes/no decision path. The CoreSlice copies are refreshed from the shared sources.

Linux links the unchanged production `ProseLabel`; user bubbles and streaming prose no longer
need a platform-specific label substitution. Its theme boundary states the new 14-point reading
face, 13-point code face, 52-em column and production leading. The bounded Pango label bridge
carries `NSParagraphStyle.lineSpacing` into the same layout used for measurement, drawing and
selection. Like alignment and wrapping, that label uses its leading paragraph style; this does
not add arbitrary per-paragraph styling to the complete-text document engine. A focused
Markdown contract checks that three lines gain exactly two spacing gaps. The Markdown fixture's
theme vocabulary follows the shared renderer's new API. The native workspace fixture now
checks Grok's argument ordering and removes the Codex seed's permission mode when creating a
Cursor record, which deliberately rejects that setting.

This branch introduced the UI structural debt ratchet before these mainline changes. Its
reconciled baseline is 104 controllers, 126 platform views, 3,232 constraints and 107 drawing
sites. Every increase is accounted for by incoming mainline code: the web-extension workbench
adds one controller, one view and 18 constraints; the remote-host prompt adds two constraints;
the simulator pane adds three; the component gallery adds one. No new Linux feature ownership
is hidden by this adjustment.

The static Linux release builds of WindowHarness, CoreSliceHarness, MarkdownHarness and
LinuxHost pass (`out/parity-rebase-build.log`, `out/parity-rebase-harness-build.log`). Core
contracts pass in `out/parity-rebase-core.log`; Markdown rendering, selection and spacing pass
in `out/parity-rebase-markdown.log`; all 12 Python runner contracts pass in
`out/parity-rebase-python.log`. Both vendor identity checks pass, including all 131 core files.
Codex, Claude and Grok saved-native journeys pass in `out/parity-rebase-runtime`; Cursor passes
in `out/parity-rebase-runtime-remaining` after correcting its fixture. These exercise multiple
turns on one daemon child, Unicode, composer growth and focus, pane switching, persistence,
restart replay and same-thread resume. The real Codex light and dark shell captures were
inspected, including the new prose and multiline user bubble. This is source-build evidence,
not a new installed package or a claim that the paused UI-parity goal is complete.

The final Linux runtime continuation exits successfully: all seven model/effort cases, the
composer interaction journey and all 14 provider/permission launch cases pass in
`out/parity-rebase-runtime-remaining`. They cover physical keyboard/pointer selection, inherited
values, account switching, the bounded large catalogue, stale refusal before record/child
creation, exact launch arguments and persisted choices. §219's installed-package, Wayland and
2× matrix limits remain; its incorrectly timed dark matrix capture is not promoted to proof.

The focused Mac run finishes with exit 0 and 75 tests passing in
`out/parity-rebase-mac.log`: permission broker/deferral/modes, Grok ACP, transcript selection,
conversation arrival, model/effort launch values and gallery coverage. Repository boundary
checks and the full app/test-target compilation pass. The full-suite recording failures and
unrun iOS suite in §220 remain explicit limitations; this focused run does not close them.
All rebase integration work is committed before returning to the requested pause.

## 222. Account-scoped model visibility in the Linux composer, 2026-10-19

The Mac opening-composer picker keeps a hidden-model set per provider-qualified account. Its
matrix exposes a hide affordance for nonselected model rows, and a footer restores the hidden
catalogue rows. The Linux shell already mounted the shared matrix, but omitted both callbacks
and the footer; the Mac `model-effort-picker-system-light.png` evidence and the Linux
`out/parity-rebase-runtime-remaining/models/codex-keyboard-grid.png` made the gap visible.

The Linux composer now loads account visibility beside the bounded catalogue on the existing
serial worker. A compact `model-visibility.json` under the Linux support directory holds at
most 128 accounts and 256 hidden model identifiers per account, with a 1 MiB read/write cap.
The host filters the 512-option picker projection, preserves the account default and explicit
selection, counts only hidden identifiers still in the current catalogue, and wires the shared
matrix's hide callback and the shared content view's footer. Hide and Show all dismiss the
picker and return typing focus. The worker serializes writes with catalogue reads and the host
admits only one pending visibility mutation. The picker and chrome remain shared Design views;
the host owns account identity, persistence and launch admission.

The first native visibility run reached the hide row and trapped on pointer hover. The shared
matrix requests `eye.slash`, which the Linux diagnostic symbol service did not recognize. The
failure was a platform-glyph gap, not a catalogue failure; its failing run is
`out/parity-model-visibility-focused2`. The Linux symbol service now draws that glyph. The
focused source rerun passes hide, restart with the model still hidden, Show hidden models,
restoration and exact launch (`out/parity-model-visibility-fixed/models.log`). Its real-shell
footer and restored-grid PNGs were inspected. The composer journey and all 14 permission cases
pass in the same runner. The dark picker capture now waits for dark pixels instead of accepting
only a theme log message; the inspected `codex-selected-ultra-dark.png` in the earlier full
run is genuinely dark. The first seven existing model cases passed there before the missing
glyph interrupted the eighth.

The visible footer was exercised by pointer. The follow-up source X11 journey in
`out/parity-footer-a11y` also publishes it as a button in the bounded model panel, moves focus
from the grid with Tab and back with Shift-Tab, activates it with Space after a restart, then
hides and restores a model again through its AT-SPI action. Its inspected focused capture shows
the shared button's focus ring. The model-row hide affordance was exercised by physical pointer
movement and click, including a captured hover state in the installed rerun below.

The release WindowHarness build, both vendor identity checks, all 12 Python runner contracts,
theme boundary check and whitespace check pass. Speed, surface, attachments, last-used choice
restoration and full popover chrome remain opening-composer parity work.

`package-app.sh` built the Ubuntu arm64 archive and `.deb` from this dirty source tree with the
recorded revision and dirty generation (`out/parity-model-visibility-package.log`). A separate
Ubuntu 24.04 container installed the `.deb` without Swift or repository sources and passed the
focused visibility journey from `/opt/threading-linux-preview/bin` in
`out/parity-model-visibility-installed.log`. Its captured hover glyph, hidden footer and
restored grid under `out/bundle-smoke/model-visibility.qgrcLgwF/models` were inspected. This
is a focused installed check, not the complete bundle smoke, a Wayland run or a 2× matrix run.
The increment is uncommitted at this pause checkpoint; the previous requested mainline rebase
and its commit remain intact.

The footer accessibility follow-up built the release host with the package's testing flag and
passed the focused source X11 journey in `out/parity-footer-a11y`. The same journey passed from a
freshly built static `.deb` in a Swift-free Ubuntu 24.04 arm64 container
(`out/parity-footer-package.log`, `out/parity-footer-installed.log`, and
`out/bundle-smoke/model-visibility.R8QwxiTg/models`). Its installed focused footer image was
inspected. The C bridge publishes the footer as a button, while the panel stays capped at 128
visible accessibility children. The complete bundle runner, Wayland, 2× matrix interactions and
the remaining composer controls have not been checked in this follow-up.

## 223. The opening composer can create a native conversation, 2026-10-19

The Mac opening footer offers an Interface choice for Codex and Claude, with each provider's
terminal UI and `Native (Experimental)` as the two options. Linux already restored saved native
sessions through its conversation pane, but every fresh composer submission still created a PTY.
The new footer chip uses the shared `ChipView` and bounded choice menu. The C accessibility
bridge exposes it as an Interface combo box and places it in the existing keyboard loop.

A native submission reserves one of the eight workspace slots, then validates the exact
project, account and explicit model selection and commits a native session on a bounded worker.
Its receipt adds the ordinary saved row, mounts `WorkspaceConversationPane`, and sends the
captured opening brief through `NativeWorkspaceSession`. The terminal choice retains its
existing creation path. A failed admission leaves the draft in the composer. The first live
journey exposed a missing worker-receipt wakeup; the SDL loop now polls while that creation is
pending, then returns to its ordinary wait. The Docker bind mount retained an older timestamp
for an edited Swift file, so an apparent second failure was an unchanged binary; touching the
source in the build container forced the intended recompilation.

`tests/composer_surface_smoke.py` passes from the source build for Codex at 1× and 2× and for
Claude at 1×. It uses the real X11/AT-SPI shell, selects the native Interface row, confirms the
saved `nativeUI` record, checks one exact Unicode opening turn at the fake Codex app-server or
Claude stream peer, waits for the prepared reply, and rejects a terminal frame. The existing
terminal `composer_smoke.py` passes with the expanded
focus loop. The release build, theme-boundary check, Python syntax checks and `git diff --check`
pass. The static Ubuntu arm64 `.deb` also passes the focused Codex journey at both scales and
the Claude journey at 1× in a
Swift-free installed runtime. Its package SHA-256 is
`1c3e7c052934c90e6b24f0c7d9fc88a7264944cb4644f1834f91fe5d4394ed98`.
The final installed `out/parity-composer-surface-installed/{codex-1x,codex-2x,claude-1x}`
captures were inspected,
including the trailing Interface chip and completed native replies. The complete bundle runner,
Wayland and the remaining speed/attachment/draft parity are still open.

## 224. Opening Speed choice reaches both Linux session surfaces, 2026-10-19

The Mac composer offers a three-state Speed choice for supported Codex models and Claude Opus.
Linux now mounts a themed `gauge`/`bolt.fill` chip beside model and permissions, with a bounded
three-row menu and an AT-SPI combo box. The selected `Bool?` is saved with the session. Fast
uses the Codex model's validated Fast service tier and enables `features.fast_mode`; Standard
explicitly sends the default tier. Claude gets a private per-session `--settings` file with
`fastMode`, and a native Claude stream also sends `apply_flag_settings`. The two Codex launch
paths use one tier resolver so startup and `turn/start` agree. Catalogue and settings reads stay
on bounded workers. Project-specific Claude settings are included when resolving the chip's
inherited title. The existing composer remains host-owned; no extension slot was added.

The focused source X11 journeys passed for Codex and Claude at 1× on both terminal and native
surfaces, plus Codex native at 2×. They selected Speed through AT-SPI, verified the three rows,
the saved `fastMode`, exact provider flags or native turn/control request, and a completed native
first turn. The final source rebuild and existing Codex/Claude Interface journeys passed.

The static Ubuntu 24.04 arm64 package is
`out/threading-linux-preview-ubuntu24.04-arm64.deb` (SHA-256
`abe7572e4032cf2cdcec59645bd766dce79e9a6e09f821296e57aaf99c5fc0f9`). All four
Speed journeys passed from this installed package at 1×, and Codex native passed at 2×, in a
fresh Swift-free container as an unprivileged user. The installed Speed menu, Claude selected
chip and 2× compact composer screenshots in `out/parity-speed-installed` were inspected. The
installed terminal journeys also switched back to inherited Fast before choosing Standard. The
560×180 footer chips stay within their bounds; their labels shorten at that minimum width.
The theme-boundary check, Python and shell syntax checks, and `git diff --check` pass.

Linux has no app-wide Settings ▸ Chats speed choice, so its inherited row says **Follow Agent
Setting** and resolves directly from provider settings. The Mac general-setting layer, live
in-conversation speed switching, attachments and remaining composer presentation are still
parity work. Speed-specific resume behavior, the complete bundle runner and Wayland were not
exercised in this increment.

## 225. Native reply Speed choice applies to live turns, 2026-10-19

The Mac reply composer carries a Speed chip after model, mode and effort. Linux's native
conversation pane now mounts the production `ChipView` and three production menu rows for
supported Codex and Claude models. It saves the optional override on the session's serial
worker. Claude first acknowledges an explicit `apply_flag_settings` request on its live stream;
Codex's retained app-server reads the new service tier for the next `turn/start`. Choosing
**Follow Agent Setting** records nil for the next launch and leaves the active process at its
current speed, with a visible notice. The menu and selected chip use theme-owned drawing.
The host keeps session identity, transport admission, persistence and choice timing.

The AT-SPI chip and rows publish their actual window-pixel bounds and the active conversation
UUID. A queued action is checked against the mounted node and UUID before it reaches the pane.
The first implementation used event kinds 52/53, which already mean worker wake and physical
Right; the press was silently consumed after SDL dequeued it. Dedicated kinds 56/57 fixed the
collision. The rendered menu accepts both AT-SPI choice actions and a real pointer click.

Focused source X11 journeys passed for Codex and Claude at 1× and Codex at 2×. Each opened a
Fast native session, selected Standard, checked durable `fastMode=false`, sent a second turn,
selected inheritance, checked the cleared override, and sent a third turn. Codex sent
`serviceTier=default` on both later turns; Claude acknowledged the live Standard flag and sent
no reset request for inheritance. Screenshots were inspected from the real shell, including
the 2× menu and the notice beneath the transcript.

The rebuilt static Ubuntu 24.04 arm64 package is
`out/threading-linux-preview-ubuntu24.04-arm64.deb` (SHA-256
`ab45e4d6ce220d9894b540e7841cd8120e489d2d83bd249bbf1b1b0b8d418208`). The same
three journeys passed from the installed package in a fresh Swift-free container as an
unprivileged user. Installed captures in `out/parity-live-installed` were inspected at 1× and
2×. The first install attempt stopped before the UI with `x11 not available`; a second clean
install with an explicit Xvfb display precheck passed. The exact cause of the first display
failure is unverified. The theme-boundary check, Python and shell syntax checks, and
`git diff --check` pass.

The Mac app-wide Settings ▸ Chats inheritance layer, the other native reply configuration
chips, attachments and remaining conversation chrome still need Linux parity work. The full
bundle runner, Wayland and a speed-specific restored-session journey were not exercised here.

## 226. Native reply Model and Effort choices, 2026-10-20

The Mac reply composer presents Model and Effort separately. Linux now mounts those production
chips ahead of Speed. Its retained session reads the same account catalogue as the opening
composer on a bounded worker, respects hidden models, and keeps at most six themed menu rows
mounted while keyboard focus pages through a larger catalogue. The current and default model
remain selectable. Codex saves the chosen model and effort for the next app-server `turn/start`;
Claude acknowledges `set_model` on its live control channel before saving. Switching to a model
without Fast support explicitly turns Fast off, and an effort the new model does not support
returns to the model default. Claude's reply Effort chip stays hidden because its transport has
no live effort control. AT-SPI exposes the mounted chips and rows, with actions validated against
the active conversation UUID. Session identity, transport requests and persistence stay
host-owned; the popup uses only Design controls.

The first real shell run found that Linux lacked diagnostic artwork for the Mac's `brain` symbol.
That symbol now has a bounded native glyph. A compact 560×180 capture then showed the send
control at the previous wide-window x coordinate, beyond the pane. The constrained vertical
content stack had kept the wide footer frame after the shrink. Positioning the reply editor and
footer with the same `PromptChrome.contentFrames` used by the opening composer, while retaining
the production footer stack and the Mac chip compression priorities, brought the send point to
x=527 at 1× and x=1054 in the 1120-pixel 2× window. The journey asserts those bounds.

Focused source X11 journeys passed for Codex at 1× and Claude at 2× after the layout fix.
The final static Ubuntu 24.04 arm64 package is
`out/threading-linux-preview-ubuntu24.04-arm64.deb` (SHA-256
`55f5d52415fd596e818e24809e60b9d26be6e2b0aa32e728ffb0029e64a5d4b6`). In a fresh
Swift-free installed container, Codex and Claude passed `configuration-live` at 1× and 2× as an
unprivileged user; the existing `speed-live` journey passed for both at 1×. The configuration
journey checked a 14-model catalogue with only six mounted rows, End/Home paging, exact saved
model and effort, Claude's live model control, Fast reset, the next provider turn and rendered
reply. Installed captures in `out/parity-configuration-installed` were inspected. The theme
boundary, shell/Python syntax and whitespace checks pass.

Linux still needs the reply Mode chip, attachments and context meter, app-wide speed inheritance,
and the remaining conversation chrome. The complete bundle runner and Wayland were not exercised
in this increment.

## 227. Opening model and effort follow the last accepted chat per account, 2026-10-20

Mac restores the opening composer's last accepted model and effort for the exact account. Linux
now writes that choice on the serial catalogue worker only after a terminal or native session
record commits. A fresh composer and an account switch load the saved choice with the bounded
catalogue; an absent or hidden model is rejected, and accepting Auto for both clears an older
explicit choice. The host owns the account-qualified file with a 128-entry limit, while the
existing themed model picker remains the presentation surface.

The source X11 Codex terminal journey passed choice, restart, account switch and Auto clearing;
the existing account journey passed. The native journey passed exact model and effort in the
committed record and app-server launch, followed by restoration in a fresh project with the
same account data directory. Both journeys passed again from a Swift-free Ubuntu 24.04 arm64
`.deb` as an unprivileged user. The installed saved and cleared composer captures and the
native restored capture were inspected. The focused Mac run passed 42 tests, and the theme
boundary, main-actor latency, Python syntax and whitespace checks passed. These are focused
shipping journeys, not a complete bundle or Wayland sweep.

## 228. Native reply context and status placement match Mac, 2026-10-20

Mac places narration above the reply box and keeps the newest context reading beside Send.
Linux had already decoded provider turn metrics but did not retain them for its native pane;
it also placed the Ready line below the box. `NativeWorkspaceSession` now retains the newest
context tokens and optional window from live and replayed turn boundaries. The reply footer
uses the shared `TurnStatusText` formatter: a Codex window becomes a percentage with warning
ink above 90%, and Claude's reading is an absolute count. A later turn without usage leaves
the reading intact. The status line now sits above the box. The bounded AT-SPI projection
publishes the full context text and actual bounds, including when the compact footer shortens
the visible label. The existing prompt chrome remains host-owned session presentation.

Source X11 journeys passed Codex's absent → 95% → retained reading and Claude's absent → 610
tokens → retained reading. Codex passed light, dark and 560×180 captures, and the existing
configuration journey passed at compact width after the status move. The saved Codex native
journey wrote a token-count transcript record, restarted the app, restored `95% context` and
retained it through the next provider turn. That replay journey and both live provider journeys
passed again from the installed static `.deb` in a clean Swift-free Ubuntu 24.04 arm64 container
as an unprivileged user. Installed light, dark, compact, Claude and replay captures were
inspected. The package SHA-256 is
`840f0464a78a1711a972ff48369b1758300e444a32fe697f5b7edd5af9210120`.
The full bundle runner, Wayland and the Mac app-wide Chats settings inheritance are still open.

## 229. Linux prompt image drops reach opening and native sessions, 2026-10-20

Mac shows a removable image thumbnail while composing and adds its quoted file path only at
submission. Linux previously sent every SDL file drop to project import, even over the prompt.
Kind 55 now carries pointer coordinates. Drops over the navigator retain the directory-import
worker; drops over either prompt enter one Design attachment strip. It prepares at most 32 images
serially off the UI thread, refusing files above 32 MiB, source dimensions above 8192, or more
than 40 million source pixels, and returns at most 128×128 RGBA preview pixels. A cleared draft
invalidates queued work. The ordinary 80-point tile has a visible remove action; at the 560×180
minimum window its preview height compresses so the remove action stays reachable. Files that
cannot be previewed become literal quoted paths in the editor. Image-only submissions send the
same quoted path spelling as Mac, for both terminal launches and Codex/Claude native replies.
Attachment admission and submission remain host-owned behavior of the existing protected
composer surfaces.

The real Xdnd source journey passed opening image drop, empty-text submit, pointer removal,
reattachment and exact terminal-agent argument. The live Codex and Claude native journeys each
passed a second provider turn containing only the quoted image path. All three journeys passed
again as an unprivileged user from a static Ubuntu 24.04 arm64 `.deb` installed in a Swift-free
container. The final package repeated those three journeys after the decoder's read loop gained
an independent byte ceiling for a file that grows after `fstat`. Installed normal, minimum-window,
2× Codex and Claude reply captures were inspected;
the existing installed sidebar journey still passed directory drop, ordinary-file refusal and
duplicate identity. Theme boundary, main-actor latency, shell/Python syntax and whitespace
checks passed. The package SHA-256 is
`648b484936a19485658f16260cc8628593cc5cfdb14d70d3a8bd83828c9308a0`.
Clipboard image paste, movie posters, session-owned file custody, accessible thumbnail actions,
the complete bundle runner and Wayland remain open.

## 230. X11 clipboard images reach both Linux composers, 2026-10-20

Mac accepts pasted file URLs and PNG/TIFF image data into the prompt attachment rail. Linux's
SDL2 clipboard bridge exposed only text, so Ctrl+V in the opening and native composers could not
reach the image strip. The Linux host now asks the X11 `CLIPBOARD` owner for a local `text/uri-list`
first, then PNG or TIFF data. A separate display connection on a serial worker handles the
selection protocol, including `INCR` chunks, with a 32 MiB ceiling and 1.2-second timeout per
target. Xlib threading is initialized before SDL opens the display. At most four conversions can
be pending per composer; the submission action waits for the selected conversion and thumbnail
decode. Raw bytes go to a private 0600 temporary file and then through the same bounded Design
thumbnail path as Xdnd. Unsupported formats preserve ordinary text paste. A cleared draft
invalidates a pending conversion, and a stale completed file is removed. The host still owns
clipboard admission and submission; this adds no extension presentation surface.

The standalone X11 contract transferred and compared a 2.1 MB `INCR` payload and URI list. A
fresh Swift-free Ubuntu 24.04 arm64 container installed the static `.deb` with its explicit
`libx11-6` dependency. As an unprivileged user, the installed opening composer passed drop,
file-URL paste, text fallback, PNG paste, removable preview and image-only terminal launch; the
submitted temporary PNG matched the original byte for byte. Installed Codex and Claude native
conversations each passed a dropped-image second turn and pasted-PNG third turn with exact
provider prompt and PNG bytes. The opening and both native pasted-preview captures were visually
inspected from the real window. Theme boundary, main-actor latency, shell/Python syntax and
whitespace checks passed. Package SHA-256:
`1f2ebf6c2bbd8b04e9ff3f5ed9f09dc6da47d40184fad2242dd926eb0f709323`.

Wayland image paste, TIFF end-to-end exercise, session-owned temporary-file custody and accessible
thumbnail actions remain. An intervening editor change while a clipboard owner stalls can also
place fallback plain text at the current caret rather than its original keypress position.

## 231. Linux image thumbnails have accessible Remove actions, 2026-10-20

The Mac attachment tile presents its image and close control as separate accessible elements.
Linux drew the same visible control, but the manually projected AT-SPI tree omitted the entire
attachment rail. The bounded Design strip now supplies the visible tile and Remove bounds for
both opening and native composers. The host projects at most 32 image nodes with separate named
push buttons, and routes each press through the existing attachment identity and current
composer scope. Removing a tile retires its AT-SPI action; an old button cannot remove a later
image in the same slot. Admission and removal remain host-owned behavior of the existing
protected composer surface; no extension presentation API changed.

The source and installed Ubuntu 24.04 arm64 `.deb` journeys passed Xdnd, file-URL and raw-PNG
paste, accessible removal, a later paste after using the retired button, and exact image-only
submission. The installed Codex and Claude native journeys each passed accessible removal and a
subsequent image reply. All three installed pasted-preview captures were inspected from the real
shell. Theme boundary, main-actor latency, Python syntax and whitespace checks passed. The
package SHA-256 is
`26911ba3f08b4958b4f2966e37d25dc004ba9e0b0352e623e56801fbd2cca777`.

Wayland image paste, TIFF end-to-end exercise, session-owned temporary-file custody and delayed
text-paste ordering remain. The broader Linux layout and visual system are still short of 1:1
Mac parity.

## 232. Match the composer theme before comparing, and hand TIFF over as PNG, 2026-10-20

The Linux preview uses `AppThemeStyles.threading`, so the existing Mac System-theme composer
image was the wrong visual reference. The Mac composer evidence now includes Threading light and
dark at tall, short, scheduled and empty states. A real installed Linux pane was captured at the
same 900×640 logical size as the Mac tall fixture. Inspection shows the shared 720-point prompt
box is already positioned and sized closely; the most visible structural gaps are the missing
managed-worktree row above it and curfew/schedule actions beside Start. The new Mac captures are
unbaselined evidence and were not approved as regression baselines.

Mac's pasteboard path decodes TIFF and writes PNG before it names the image in a prompt. Linux
previously wrote the TIFF bytes to a `.tiff` file, leaving provider support to chance. The X11
worker now decodes TIFF through GdkPixbuf and streams PNG encoding into a callback capped at
32 MiB. It refuses oversized source dimensions, then writes the same private `.png` path used
for raw PNG paste. The opening and Codex/Claude source and installed journeys passed TIFF paste,
preview, image removal or submission, and the native provider's `.png` path with matching
decoded pixels. The three installed TIFF preview captures were inspected from the real shell.
The Mac composer evidence test, theme boundary, main-actor latency, Python syntax and whitespace
checks passed. The static Ubuntu 24.04 arm64 package SHA-256 is
`a21aa0b455cf0224f8199cc9b38f37b9e4c36f58dd2420126f165112dc2d6f3e`.

The managed-worktree and time controls still require their host behaviors on Linux. Wayland
image paste, session-owned temporary-file custody and delayed text-paste ordering also remain.

## 233. Delayed X11 text paste keeps its keypress selection, 2026-10-20

The opening and native composers ask an X11 clipboard owner for file URLs and images on a
worker before falling back to plain text. That owner can hold each selection request for up to
1.2 seconds. Previously, if the user moved the caret or typed while it answered, the fallback
called `paste` at the *current* caret. The pasted words could land after later typing instead of
at the point where Paste was pressed.

The shared paste path now captures the selected UTF-16 range at the keypress and rebases it over
intervening edits outside that range. Typing at the original caret follows the paste in input
order. If an edit replaced the selected text, or repeated characters make the changed side of
the caret ambiguous, it refuses that delayed fallback rather than replacing an unrelated span.
After insertion, a later caret move remains active, shifted past the inserted text when needed,
so the next keystroke follows the user's most recent cursor action.
Attachment conversion, its generation guard and its serial worker are unchanged. The focused
Foundation fixture covers Unicode offsets and every short two-character string through single
insertions and deletions.

A real X11 clipboard owner held each unsupported image/URI request for 300 ms while the
installed composer moved its caret to the end or beginning and typed. Both installed journeys
put the delayed text at the original selection and kept the later caret for another keystroke;
their captures in
`out/parity-paste-anchor-caret-installed` were inspected. The existing source and installed image
attachment journeys also passed. Theme boundary, main-actor latency, Python syntax and
whitespace checks passed. The rebuilt static Ubuntu 24.04 arm64 `.deb` SHA-256 is
`90af794396842bf18881836301c6d1757b426ff705648b0a56fc5f6136ac0330`.

An edit through the selected text cannot be replayed in original order without an editor edit
log; that fallback is left unapplied. Wayland image paste, session-owned temporary-file custody,
the managed-worktree row and time controls remain separate parity work.

## 234. Wayland composer image paste reaches the agent, 2026-10-20

The X11 clipboard reader added for composer images cannot read a Wayland compositor's selection.
The active SDL video driver now chooses the native clipboard route at the Paste keypress. X11
keeps its separate Xlib selection connection; Wayland asks the packaged `wl-paste` client for
the same three exact targets: local file URIs, PNG and TIFF. Each request runs on the existing
serial clipboard worker, with no shell, a 32 MiB output ceiling, a 1.2-second deadline and
child termination/reaping on timeout or oversize. The Ubuntu package declares `wl-clipboard`
so the installed app has that client. Both routes then use the same image validation, TIFF-to-PNG
conversion, attachment preview and submission path. Clipboard admission and session submission
remain host-owned behavior of the existing composer surface.

In a fresh Swift-free Ubuntu 24.04 arm64 install under headless Weston, the real Wayland
keyboard pasted a file URI, TIFF and raw PNG into the opening composer. All three produced image
previews; URI and TIFF removal retired their rails, and TIFF's removable image was named `.png`.
The raw PNG remained attached for Start Session, and the launched agent received its exact
bytes at the private `.png` path. The compositor capture in
`out/wayland-smoke.FFrg9jwg/composer/capture/pasted.png` was inspected. The same static package
passed the installed X11 delayed-text, URI, TIFF, PNG and image-only submission journey. Its
SHA-256 is `800973bee58d36ad0d8a37d85112004d14e5277dac83ddca9354f9cd08f954d7`.

The Wayland journey covers the opening composer; a native reply's Wayland clipboard ingress,
movie posters and session-owned temporary-file custody remain unverified or unimplemented. The
managed-worktree row, time controls and broader visual differences from Mac remain open.

## 235. The composer can launch in an added sibling checkout, 2026-10-20

Mac's location chip distinguishes where a new session runs from switching the composer to a
different project. Linux's chip previously named only the selected project; its menu navigated
projects, and every launch used that project's folder. The Linux chip now shows the Git branch
discovered at window open, lists this checkout and other added worktrees of the same repository,
and puts project navigation behind **Switch Project…**. Choosing a sibling leaves the draft,
provider and model choices in place. Terminal and native creation both route the process,
settings lookup, saved record and selected sidebar row to that sibling. Both records capture the
branch read from Git. The worker checks the
checkout identity and branch again before committing either kind of session, so a removed or
switched checkout is refused instead of silently launching elsewhere.

Git control files are read directly on a worker, including linked-worktree `.git` pointers;
each read has a 4 KiB cap. The worker groups projects by repository, so main-thread composer
refresh only visits siblings, not the complete project list. The bounded existing chip/menu
surface remains host-owned: it decides execution location, while the shared Design controls
still draw it. Linux does not yet create a new worktree from this menu or watch `HEAD` for an
external branch switch while the composer remains open.

The installed Ubuntu 24.04 arm64 X11 shell tests `composer_checkout_smoke.py` and
`composer_surface_smoke.py ... codex checkout` passed: the former preserved the draft while
selecting a sibling, verified the agent's cwd, SQLite owner and saved branch; the latter
completed a native provider turn from that sibling, captured `feature` as its branch and selected
its saved row. The installed checkout menu, selected composer and first native reply captures
were inspected. The static package SHA-256 is
`5771235599dcf83444ff9f7d93162421b255e284dd77d981b05fbf8b4e8557fd`.
The installed broad composer journey also passed after its AT-SPI test reacquired the editor
node across resize and menu publications; it verified the unchanged plain-project launch,
Unicode editing, paste, focus loop and rendered prompt. Theme boundary, main-actor latency,
Python/shell syntax and whitespace checks passed.

## 236. Added checkout projects now sit beneath repository roots, 2026-10-20

The Linux navigator previously projected every project as a top-level row. It now groups every
added Git project beneath a stable repository root, even when only one checkout is present;
plain folders and the scratchpad remain standalone. Grouping uses the live checkout catalogue
and the project's persisted `lastKnownRepositoryIdentity`, so a removed worktree stays in the
same group with the production unavailable-checkout warning. A checkout row uses the shared
branch/path presentation, retaining the full path in its tooltip and accessibility name. The
repository root borrows an available checkout for its icon and actions, preferring the main
working tree. Root expansion is a user preference and flushes on a bounded worker before the
window processes a quit; project expansion still uses its exact SQLite row write. Row selection,
hover and Left/Right navigation use outline identities, and the existing viewport projection
still mounts only visible cells.
This extends the existing `sidebar.project-row@1` presentation; no new extension surface is
needed. Repository membership, selection, commands and the availability mark remain host-owned.

The Git control-file reader is shared by the window and CLI importer through the recorded
CoreSlice vendor manifest. The importer writes repository identity when a project is added; the
production and vendored navigation DTOs now expose that saved value. The Linux row's explicit
compression priorities keep the branch legible before truncating its quiet path, and the
portable symbol boundary draws the same warning triangle used by the Mac missing-checkout row.
Both fixes came from inspecting the real shell against the
`sidebar-worktree-light` and `sidebar-worktree-unavailable-light` Mac evidence baselines.

The source X11 journey passed with two live checkouts, a removed saved worktree, a standalone
folder, pointer and keyboard repository folding across an app restart, a preserved composer
draft, and a terminal
launch whose cwd, owner and branch match the selected sibling. The 5,100-project outline fixture
still mounted 18 cells, and its grouped 5,100-checkout case kept parent navigation and viewport
mounting bounded. The Ubuntu 24.04 arm64 static package was installed in a runtime
container without the source tree or Swift; its terminal and native Codex checkout journeys
passed, and their rendered screenshots were inspected. The package SHA-256 is
`e9a74adf2203124f6541ef135d3957ad844465005b3728f59eccffed1e83616c`.
The installed non-Git multi-project outline journey also passed its independent disclosures,
selection, keyboard traversal, restart and busy-store rollback in both appearances.
Theme, architecture, main-actor latency, vendor, Python syntax and whitespace checks passed.
The repository root still lacks Mac's **New Worktree…** command; broader shell chrome and
composer controls remain separate parity work.

## 237. New worktrees can be created from both Linux entry points, 2026-10-20

The macOS composer location menu and repository root `+` use one worktree creation flow. Linux
now places **New Worktree…** after the live checkout choices and at the end of the repository
creation menu. Both routes ask for a branch, make a sibling directory using the Mac naming rule,
run `git worktree add -b`, verify that the result belongs to the same repository, import it, and
select it. Git and import run on a worker; Git is bounded by a 15-second process-group timeout.
The composer draft survives the new destination. The GTK branch prompt carries the Mac wording
and Create/Cancel actions but remains a visual parity gap against Mac's themed text prompt.

The installed journey found an outline ownership bug: importing into a folded repository
selected the new project only until the next outline projection, which fell back to the old
repository representative. Import now reveals the repository before resolving the selected
checkout. The repository accessibility row also publishes its visible `+` and actions while
keeping a stable repository row ID; activating either control passes the current representative
project ID through the existing exact-target route.

The installed Ubuntu 24.04 arm64 package passed `composer_checkout_smoke.py` with both creation
routes, saved project paths, destination and draft assertions, plus the existing sibling launch,
missing-checkout and fold/restart checks. `project_create_menu_smoke.py` passed separately for
ordinary project rows. The real-shell checkout menu and selected new worktree screenshots were
inspected. Package SHA-256:
`a685c5c15379af61b1f6dcba3ff603030aacf5276627475dc76c64dcbc46f4a0`.
The shared themed prompt, live branch watching, managed workspace row and scheduling controls
remain Linux parity work at this checkpoint.

## 238. Open Linux windows follow external branch switches, 2026-10-20

Mac keeps its checkout presentation current when Git changes `HEAD`. The Linux catalogue was
read only during project discovery, leaving an open composer chip and checkout row on a stale
branch. A single inotify worker now watches the Git metadata directories of added checkouts,
including linked worktrees. Git replaces `HEAD` through a rename, so the watcher observes the
directory rather than the old file inode. It re-reads only affected checkouts on its worker,
coalesces changes by project ID, and wakes SDL through the existing worker event. Branch-only
changes update the bounded composer choices and mounted row; identity or availability changes
request full worker discovery. Registration re-reads the catalogue to close the discovery gap.

The installed Ubuntu 24.04 arm64 X11 journey passed both New Worktree entry points, the
repository New Chat submenu return, import/reveal, and an external `git switch -c` while the
composer remained open. AT-SPI observed the new branch in the chip and checkout row, with the
main checkout unchanged. The selected live-branch screenshot was inspected. The GTK text prompt
remains visibly different from Mac's shared themed prompt; managed workspace and scheduling
controls remain separate Linux parity work. The installed package SHA-256 is
`65816f1850b8a553d445e1ddb3eb8c04b80aa0fdbf9eee5d2ee7ee911f1a9f40`.

## 239. New Worktree uses an app-owned themed prompt on Linux, 2026-10-20

The GTK entry dialog had the right worktree wording but looked unrelated to Mac's
`TextPromptAlert`. Linux now opens a separate fixed-size prompt process that draws the same
informational title/message structure with the shared `ThemedTextField` and `ThemedButton`
components. The visible view lives in `Sources/Threading/UI/Design/`; the host owns modal
input blocking, the bounded answer, Git validation and import. Return, Escape, pointer actions,
clipboard text and IME use the Linux window bridge. The prompt exposes a dialog, single-line
editable field, and Create/Cancel buttons through AT-SPI, with edits and actions returning to
the same host path as keyboard input.

The installed Ubuntu 24.04 arm64 package passed `themed_prompt_smoke.py` in light and dark,
including keyboard submission/cancellation and AT-SPI field edits and button activation.
`composer_checkout_smoke.py` passed both creation entry points, preserved the draft, and
continued to pass the external branch-switch check. Both prompt captures and the selected
checkout in the installed app were inspected. Theme, architecture, main-actor latency, Python
syntax and whitespace checks passed. Package SHA-256:
`5af9c97c188c5294b407d1525d06b837616f825b3d68c4f90099ba2f638c3a69`.

The prompt uses the same design tokens and control components, but its SDL window still needs a
direct Mac panel comparison for exact silhouette, positioning and window-stack behavior. The
managed-workspace row, scheduling controls and broader chrome remain Linux parity work.

## 240. The worktree prompt follows the shared alert constraints, 2026-10-20

The first Linux prompt positioned its icon, labels, field and buttons with absolute frames.
That duplicated the Mac alert's geometry inside a Design component even though the Linux
AppKit shim already implements `NSStackView`, `NSLayoutConstraint` and fitting size. The prompt
now uses the Mac alert's content structure: a vertical title/message stack beside the 30-point
icon slot, followed by a full-width field and a trailing action row, all pinned to a 360-point
minimum content column with Design spacing. The SDL window takes its size from the resulting
`fittingSize`; the root bitmap frame is the only frame the host supplies. Button accessibility
rectangles are converted from their nested stacks into that root's coordinates.

The installed Ubuntu 24.04 arm64 package passed the themed prompt smoke at 1× and 2× in both
appearances, including keyboard and AT-SPI submit/cancel. The real Linux prompt captures were inspected
beside the Mac Threading-theme alert evidence: both are 400 points wide, while Linux currently
fits to 203 points high and Mac to 200. Their controls and copy align closely; the remaining
three-point difference appears in fitted content metrics and needs measurement of the shim's
font and labels. The theme boundary and whitespace checks passed.

The same audit found two larger shell-level divergences. `WorkspacePlaceholderPane` positions
the opening composer's column, editor, action and chips with frames where the Mac
`SessionComposerViewController` uses stacks and constraints. `WorkspaceConversationPane`
positions its scroll viewport, status and reply composer with frames where the Mac
`ConversationViewController` constrains its outer layout. Those controllers are not yet shared
with the Linux host. Menus, attachment tiles, virtualized row slots and the bitmap viewport
also use frames for placement; they are separate from the static content constraints discussed
here. Moving the two pane shells toward the Mac constraint structure needs a bounded solver
cost check because conversation size and update frequency scale with transcript activity.

The greeting inside the opening composer was another bounded component-level example:
`ComposerWelcomeView` placed its mark and text manually. It now uses the Mac hero's vertical
stack, centered on both axes with the same 12-point gap and a 40-point mark constraint.
The host still gives the hero its available viewport region and chooses whether it fits.
The installed composer journey passed after this change, including resize, editor focus,
Unicode input, project/provider choices and launch. Its real 480-point and 640-point shell
captures were inspected, and the theme boundary remained clean.

## 241. The opening composer column uses the Mac constraint structure, 2026-10-20

`WorkspacePlaceholderPane` previously calculated frames for the composer surface, destination
chips, submit button and hero on every presentation. The root still takes its viewport frame
from SDL, but a retained `NSStackView` now owns the column's bottom pin, centered 720-point cap,
32-point side bounds and medium-spaced chip/prompt/action sections. The prompt width and action
row follow that column through anchors. A single height constraint takes the editor's cached
TextKit and attachment measurement; the hero is pinned to the space above the column. The
destination row has the Mac location-chip compression rule, stable identity width and a flexible
trailing spacer. Converting the attachment drop target into root coordinates was necessary once
the surface became a nested arranged view.

The installed Ubuntu 24.04 arm64 composer journey passed after this change with normal, tall,
180-pixel compact and 560-pixel minimum-width windows, including keyboard focus, multiline
Unicode and clipboard input, accessibility edits, choices and exact launch. The compact capture
shows the greeting hidden and the editor and submit action visible; the narrow capture shows
the column and footer compressed within the pane. The installed 2× native-composer journey also
passed and its opening capture was inspected. The general 2× composer smoke's fixed 720-point
assertion is inapplicable because the workspace has a 1,280-physical-pixel content ceiling;
at 2× the actual logical pane is narrower. The 2× native journey checks that real size. The
theme boundary, Python syntax and whitespace checks passed. Internal editor/footer placement,
the conversation pane's outer frame layout and theme-authored welcome behavior remain parity
work.

## 242. The native conversation pane follows the Mac outer constraints, 2026-10-20

`WorkspaceConversationPane` previously assigned full-width frames to the scroll view, status
label and reply composer on every presentation. The Mac controller gives those peers distinct
relationships. Linux now pins the scroll viewport to the pane edges and above the status, aligns
the status to the reply box's text inset, and centers the composer above the bottom inset. The
composer takes a stated width under the same 400-priority rule and reading-width-plus-padding
cap as Mac, while its cached TextKit measurement updates one height constraint. The viewport
document remains outside this root constraint island through the scroll view's document-view
boundary; visible conversation rows keep their existing recycling and width contracts. The
status now uses the Mac subheading and tertiary-ink roles with a truncating line.

The installed Ubuntu 24.04 arm64 native workspace journey passed at 1× and 2×: a growing and
resetting reply, pointer send, Unicode and multiline turns, retained draft, pane switch, dark
appearance, durable thread identity, restart replay and same-thread resume. Real ready, first
reply and dark shell captures were inspected. At the default 1× 1120-pixel window the reply
box is 752 pixels wide and centered at x=304; the 2× pixel-budgeted pane gives it 592 pixels
at x=504. The installed smoke now asserts both cases against the default Mac column cap and
pane insets. Package SHA-256:
`209b5374adb42b6a6f25ba3c2a81ad5265fa963d7b85b6960673f3f884e3c521`.
Theme boundary, Python syntax and whitespace checks passed. The inner prompt
editor/footer still use frame placement, and the Linux pane has not gained Mac's minimap,
scheduled rail or extension presentations.

## 243. Both Linux prompts share the Mac content constraints, 2026-10-20

The opening and native reply hosts no longer assign frames to the editor, attachment rail or
footer. `PromptChrome.configureContentStack` and `contentSizingConstraints` now supply macOS
`PromptView` and both Linux hosts with the same vertical stack behavior and five attachment,
editor and footer size equations. Each host pins its stack inside the field with the same
12-point side and 10-point footer insets. Cached TextKit height still changes only the outer
field height constraint. The opening footer's Mac compression priorities let model and mode
labels yield before the trailing surface choice; the reply footer keeps its send control inside
the constrained row.

An 80-point image rail plus the required prompt gaps and footer cannot fit at the Linux
window's usual 180-pixel height floor. The workspace now raises its native minimum while an
attachment is present and restores the 180-pixel floor when it is removed or the pane changes.
The bridge also corrects a resize that bypasses the window manager's advertised minimum, as
the X11 smoke does. The image rail itself now uses the Mac horizontal `NSStackView` with fixed
80-point tiles and a top/trailing constrained remove control. Its scroll document still takes
a viewport frame, as Mac's does; preview positions are stack-owned.

The installed Ubuntu 24.04 arm64 package passed the opening composer journey at normal,
560-pixel wide and 180-pixel tall sizes, the native workspace journey at 1× and 2×, and the
native image reply journey at 1× and 2×. After the horizontal rail change, the installed opening image
journey passed Xdnd, URI-list, TIFF, raw PNG, remove and exact provider bytes. It also
verified a two-image row, reflow after removing one, the attached minimum, and return to the
180-pixel floor; `out/attachment-pair-final/image-attached-pair.png` and
`out/attachment-stack-final-opening/image-attached-compact.png` were inspected. The final
native image captures at `out/attachment-stack-final-native/native-image-attached.png` and
`out/attachment-stack-final-2x-retake/native-image-attached.png` were inspected. The 2× TIFF
test initially clicked the footer because its last editor offset was unscaled; the corrected
test passed the same installed package. Package SHA-256:
`faa86aab8404cdc318fde8cc6801bd5d547e3ad4db55a237b1e713dbb5749411`.

Targeted macOS evidence tests passed for `session-composer-layout` and
`native-chat-showcase`; the Threading light short/tall composer captures were inspected.
The native showcase report has four changed tool-state baselines, also changed in prior
reports from October 6; none was accepted here. The theme boundary, Python syntax and
whitespace checks passed. Remaining frame writes in these Linux pane hosts set the SDL root
viewport, popup placement, bounded visible menu rows and the scroll table document width.
They do not position static prompt children. The Linux native pane still lacks Mac's minimap,
scheduled rail and extension presentations.

## 244. The opening column uses one Mac/Linux constraint declaration, 2026-10-20

The previous migration put both prompt interiors on `PromptChrome` constraints but left the
opening column's outer equations copied into two hosts. `PromptChrome.constrainOpeningColumn`
now installs the same center, bottom, pane-width measurement, 720-point cap, side bounds,
prompt width and action-row width for Mac and Linux. The measurement retains priority 240 and
the stack its priority-1 horizontal hugging. Linux keeps a reference to the returned bottom
constraint for its 180-pixel compact-window policy; the SDL bitmap still sets the root
viewport size. The first consolidation lowered the UI-structure ratchet from 3232 to 3224
controller constraint sites.

The installed Ubuntu 24.04 arm64 composer journey passed with keyboard focus, multiline and
accessibility editing, scrolling, choices, narrow and compact resizes, and an exact agent launch.
Its normal, 560-pixel narrow and 180-pixel compact shell captures were inspected. The package
SHA-256 is `89083e26c6983b0593ab18fbb50941ea357795c2cfe9be8fb5619f5c1d233043`.
The architecture and theme boundary checks passed. The targeted macOS
`session-composer-layout` evidence test passed; its 49 rendered PNGs are pixel-identical to
the preceding targeted run, and the Threading light tall/short results were inspected.
The new captures remain unbaselined review evidence.

The frame audit found no remaining static prompt-child frame assignment in the Linux opening
or reply pane hosts. Their imperative frames size the SDL root viewport, transient menus and
bounded visible menu rows. The scroll attachment document also takes a viewport frame, as on
Mac. It found another duplicated layout in `Specimen.Row`: Linux had framed the shared
`ThemedProjectRowView` visual while Mac pinned it to its cell on all four edges. The visual now
owns one `pin(to:)` declaration called by both hosts. Linux adjusts only its outline gutter
constants when they change, preserving viewport-bounded row reuse and avoiding redundant
solves. Moving Mac's pins into Design lowered the UI-structure ratchet again to 3219 sites.

The final installed package passed the project-row `+` menu journey, including exact project
identity, disabled manager choice, nested chat creation and terminal creation. Its menu capture
was inspected. The installed composer journey also passed again; its normal screenshot has
pixel-identical sidebar and prompt regions to the pre-migration capture. The macOS
`sidebar-session-rows` evidence tests passed and the Threading light outline was inspected.
Those 50 captures are unbaselined review evidence. Final package SHA-256:
`873afcdfcb4f56d4331273e88aa370447308ce9c6ea617c0183b6e2dc25f10cc`.

Session and terminal row wrappers still take host-calculated frames despite their shared
constrained content. Their Mac cells give the content leading and center-Y anchors plus a
trailing inequality against host-owned action slots, which requires porting the row host's
slot structure rather than simply replacing a frame setter.

## 245. Session and terminal content use the Mac row constraints, 2026-10-20

`SidebarRowDefaults.constrainContent` now declares the five outer relationships once for the
Mac session/terminal cells and the Linux mounted rows: content leading and center Y, content
trailing at least one spacing step before the trailing slot, and the slot's trailing edge and
center Y. The Linux row retains the shared `ThemedSessionRowContentView` or
`ThemedTerminalRowContentView` and updates only its outline-gutter constraint constants during
recycling. The session and terminal layout fixtures pass, including a long Unicode session
title beside an expanded status slot. The UI-structure ratchet fell from 3219 to 3207
constraint sites.

The installed 2× provider journey exposed a separate old frame path after this migration. The
saved-session picker still placed `Snoozed` in the navigator text layer using
`SavedAgentRowLayout`, while its shared title reserved only the row's empty 20-point slot. The
title could satisfy its own trailing constraint and still overlap that unrelated text. The
picker now mounts the status inside the same constrained trailing slot as outline rows, and the
unused frame calculator is removed. The slot grows to 64 points for diagnostic status text;
the absent-provider-artwork mark remains visible.

The installed Ubuntu 24.04 arm64 provider journey passed provider marks, selected/unselected
states, long Unicode titles, complete accessible account/ID labels, live terminal identity and
missing-artwork fallback. Its final `out/sidebar-final-verified/out/provider-marks-idle-snoozed.png`
and `provider-marks-fallback-claude-selected.png` captures were inspected at 2×: title and
status no longer overlap. The installed independent-project outline journey passed expansion,
selection, keyboard traversal and restart in both appearances; its
`out/sidebar-final-outline-verified/out/both-expanded-beta-selected.png` capture was inspected.
Targeted macOS `sidebar-session-rows` evidence tests passed, and the long-title
capture was inspected. Theme-boundary, UI-structure and whitespace checks passed. Final package
SHA-256: `d4140776e0d7e7ffd43867cd9c372c99e1f93b5bf45d3021611dcf76c3a3172b`.

At this checkpoint the Linux slot still presented diagnostic status text and lacked the Mac
cell's activity mark and hover actions. The label placement is corrected in the next entry.

## 246. Durable attention follows the Mac title stack, 2026-10-20

The Mac row does not put `Snoozed`, `Woke` or `Scheduled` in its activity/action slot. It lazily
adds a caption after the compressible icon/title view in `rowContentStack`, with required
horizontal hugging and compression. `SidebarRowDefaults.configureSessionContentStack` and
`configureAttentionLabel` now state that arrangement and label priority once for Mac and Linux.
The Linux mounted session wraps `ThemedSessionRowContentView` in the same outer stack, creates
its attention label only when text is present, and hides it when the row is reused or the snooze
expires. The independent trailing slot stays at the Mac 20-point resting width. Selected labels
use selection secondary ink; unselected labels use tertiary ink.

The installed Ubuntu 24.04 arm64 provider journey passed selected/unselected artwork,
long Unicode names, snooze expiry, full account/ID accessibility, live terminal identity and
missing-artwork fallback. The 2×
`out/attention-stack-provider/out/provider-marks-idle-snoozed.png`,
`provider-marks-idle-expired.png` and `provider-marks-fallback-claude-selected.png` captures were
inspected. The installed native-workspace journey passed three turns, terminal switch, dark
appearance, restart and same-thread resume; its
`out/attention-stack-native/captures/native-ready.png` sidebar is pixel-identical
to the pre-change installed capture. The long-title/recycled-row fixture and theme, structure
and whitespace gates passed. Targeted macOS `sidebar-session-rows` evidence passed all four
tests, and its 50 PNGs are decoded-pixel-identical to the prior targeted report; the scheduled
caption capture was inspected. Final package SHA-256:
`0a2e64ced19803830171b5da24bc6fa0dd4fc94175e7817681d15989e6dbe18d`.

Linux still lacks the Mac activity marks and hover-action controls in the trailing slot. The
saved picker also shows `Retained` as diagnostic text because it has no provider activity
observer; that semantic gap remains separate from this layout migration.

## 247. The model picker shares its Mac constraints, 2026-10-20

The frame audit found one remaining platform split inside a shared Design component:
`ModelEffortPickerContentView` declared its title, scroll viewport and optional footer with
constraints on Mac but assigned their frames in `layout()` on Linux. Both now execute the same
constraint declaration. The Linux popup pins the content to its frame-sized menu surface and
deactivates those four pins before removing a picker on dismissal or refresh.

The first direct port exposed a real bounded-window case: a 600-model catalogue could not open
because its 336-point preferred scroll height was required even when the host popup had less
room. The shared constraints now cap the viewport at its natural width and height and prefer
that size at high priority, allowing the scroll area to compress while keeping the title,
footer and outer edges required. The ordinary Mac popover retains its natural size. The
matrix document's frame remains scroll-owned on both platforms.

The final installed Ubuntu 24.04 arm64 package passed the large-catalogue keyboard and
horizontal-scroll journey and the repeated-open hidden-model/footer journey, including
focus, restart, restoration and exact launch. The large-catalogue capture was decoded-pixel
identical to the previous installed build; the final footer capture was decoded-pixel
identical to the pre-cleanup capture and was visually inspected. The targeted Mac
`model-effort-picker` rendered test passed and its system-light image was inspected. Its old
accepted baselines are at a different capture scale, so this run was treated as review
evidence rather than a baseline update. Theme boundary, UI structure and whitespace checks
passed. The installed `WindowHarness` matches the rebuilt binary by SHA-256. Package SHA-256:
`efa1c07d528cb383763a65dc63868f11fdc5ee0a722c0a2ce0d42503158d0afd`.

Remaining direct frame writes in the inspected Linux shell set SDL bitmap/viewports,
scroll documents, transient popup bounds and bounded menu rows. macOS's shared menu document
also lays out its row slots by frame. The older `Specimen.Row` project-control frame path is
outside the production outline, which mounts `ThemedProjectRowView` and its constrained
controls; it remains legacy code to remove rather than a source of current screen geometry.

## 248. Saved row dormancy follows live provider state, 2026-10-20

The shared row content already knew how to tint a dormant session, but the Linux host never
passed it that state. The saved picker also appended `Retained` as a diagnostic caption where
Mac shows only durable `Scheduled`, `Woke` and `Snoozed` attention beside the title. Linux now
uses the shared selection/dormancy policy and the same 0.5 opacity for non-template dormant
provider marks. Scheduled rows keep their ordinary ink, as on Mac. Neither the picker nor the
production outline puts the diagnostic word into the constrained title stack.

Counting cached runtimes as active was a second false signal. An exited terminal may remain
cached for selection and a native conversation lives in a different cache. The row projection
now reads the terminal's process state or the native stream's launch/running state. The host
invalidates its navigator on those lifecycle transitions rather than waiting for another user
event. A real native-exit journey exposed why that invalidation initially did not arrive:
`PTYHostPipeLink` queued its hosted-child exit on `DispatchQueue.main`, which the SDL event
loop does not service. The link now calls its consumer from its callback path, as the local
child route already does; each stream uses its existing UI delivery to cross to the owner.

The final installed Ubuntu 24.04 arm64 provider journey passed selected/unselected artwork,
snooze expiry, Unicode title truncation, accessible identity, dark appearance and missing
artwork fallback. It also exited a retained saved shell and confirmed that its terminal row
no longer claimed `retained`. The installed 2× native workspace journey passed three turns,
pane switch, dark appearance, restart and resume, then killed the live provider. Without a
click, its saved row lost the `retained` accessibility suffix, the pane rendered
`Agent exited (143)`, and the session record stored exit code 143. The real idle/snoozed,
exited terminal and exited native
captures were inspected. The shared Mac sidebar evidence passed all four targeted tests. Its
50 PNGs are byte-identical to the previous run; the dormant and scheduled captures were
inspected. Mac `PTYHostPipeSessionTests` passed all 15 hosted-child cases after the callback
change.
The session-row layout fixture, vendor source equality, theme boundary, UI structure,
Python syntax and whitespace checks passed. Installed `WindowHarness` matches the rebuilt
binary by SHA-256. Package SHA-256:
`43124fcf654e99f115b955d94f3c680def793d0ad372082b435e52378e130548`.

The Linux trailing slot still lacks Mac's provider activity mark and hover-action controls.
The outer SDL viewport, scroll documents, popup bounds and bounded visible menu rows retain
their frame ownership; the inspected static content uses the shared constraint declarations.

## 249. The optional Open In header control collapses like the Mac stack, 2026-10-20

The next frame audit found a manual width cap on Linux's production `PageTitleView`. The Mac
header puts its optional Open In control in an `NSStackView`; hiding it removes its arranged
slot. Linux instead handed that control directly to `PaneHeaderView` and subtracted its full
width from the title even when no external app was available. Removing only the subtraction
changed no pixels: the still-constrained hidden control kept occupying 54 points. Linux now
mounts the same split control in a one-item stack, so the shared `PaneHeaderView` constraints
resolve the title against the control's actual visible width. Mac also gives the title an
intrinsic 360-point cap and a matching width constraint. That metric now lives on the shared
`PageTitleView`, and both hosts use those two declarations. The SDL header root still takes
the bitmap viewport frame; it does not assign frames to either child.

An installed Ubuntu 24.04 arm64 run with a long terminal name measured the title at 236 points
inside a 560-pixel window before the change, both with and without Open In. Afterward the
hidden-control title was 290 points, while the visible-control title remained 236 points.
At 960 pixels both states now stop at Mac's 360-point cap instead of extending past it. Open In
kept its previous control geometry, and the 560-pixel visible-control screenshot was
decoded-pixel identical to the baseline. The final wide and narrow captures were inspected:
the name uses the previously blank space in a narrow pane and obeys the cap in a wide pane.
The before/after Linux captures are in `.build/linux-header-parity/`. The installed Open In
journey passed primary and chooser presses, app-icon rendering, paging, exact checkout
launches, last-used preference and stale-checkout refusal. Theme boundary, UI structure and
whitespace checks passed. The macOS Debug app build and standalone PageTitleView fixture passed.
The targeted `design-system-components` evidence test passed; its PageTitleView light and dark
captures were inspected and are decoded-pixel identical to the earlier gallery run. That report
also has four changes in other components and many gallery captures without baselines; no
baseline was updated in this pass (`.build/ui-evidence-reports/20261020-102826-64692/`).
Final package SHA-256:
`f64d1043370194f8d57887ffdc24db097af222bd662fd00ed0c52b87c6ec7e98`.

This audit still distinguishes component geometry from viewport placement: the live header,
prompt, project and session content use shared constraints; the host sizes the SDL bitmap,
scroll documents, popup bounds and visible menu rows. The Mac menu document also positions its
bounded rows by frame. The old specimen-only project-control frame path does not feed the live
outline. The Linux session trailing slot still lacks the Mac activity mark and hover actions.

## 250. Session status-slot geometry is the same constraint code on both hosts, 2026-10-20

A follow-up frame audit confirmed that the live sidebar's project, session and terminal content
already uses shared constraint declarations. The remaining frame assignments in that path size
the SDL viewport, scroll documents, popups and bounded visible menu rows; the Mac menu document
also positions rows by frame. The standalone specimen's hand-placed project controls do not
feed the production outline. One component detail was still Mac-only: the four constraints
placing the session activity mark within its trailing slot.

`SidebarRowDefaults.constrainSessionStatus` now owns those four declarations. The Mac row calls
it in place of its local copies; Linux mounts a status view in the same fixed trailing slot and
calls that exact helper. The 12-point mark size has one definition in `SidebarRowDefaults`,
which the Mac indicator default references. This establishes geometry only: Linux does not yet
paint an activity mark or expose the Mac hover controls, because its host still needs truthful
activity state and functional row actions. Only mounted session rows allocate the new view.

The Linux release build and installed `--session-row-layout-fixture` passed; that fixture
checks the solved status rectangle against the outer column and verifies long-title reuse.
The installed Ubuntu arm64 provider-row journey passed selected/unselected artwork, Unicode
title truncation, accessible identity, dark appearance, snooze expiry, terminal exit and absent
artwork fallback. Its light and dark shell captures were inspected in
`.build/linux-session-slot/`. The installed `WindowHarness` SHA-256 matched the builder's
binary; the package SHA-256 is
`c1bcc251e82a10792b620885bc0ca44595308c04503cf5ba114b1733279d65df`.
The macOS Debug build and targeted `sidebar-session-rows` evidence tests passed. All 50
sidebar-row captures were decoded-pixel identical to the preceding targeted run, and the
working-at-rest and hovered captures were inspected. This selection has 50 images without
accepted baselines; none was accepted in this pass. Theme boundary, UI structure and whitespace
checks passed.

## 251. Native session activity uses the shared slot and a bounded animation patch, 2026-10-20

The native Linux session row now distinguishes loading, an explicit in-flight provider turn,
pending user permission/question and idle. Codex, Claude and ACP expose `hasActiveTurn` from
their existing turn bookkeeping through the shared conversation protocol; an attached provider
process alone does not imply work. The pending decision takes precedence over an in-flight turn.
Only visible non-idle rows mount `ThemedSessionActivityMark`. Both hosts pin status content with
`SidebarRowDefaults.constrainSessionStatusContent`, using the Mac row's four declarations. The
Linux mark sits inside the already shared trailing status-slot constraints.

The first installed animation ran at roughly 53–60 ms per full sidebar raster frame under the
Ubuntu arm64 test container. The final host hides each visible working mark for the occasional
full navigator raster, retains the solved 12-point rectangle's background, and updates only
that rectangle in the SDL sidebar texture at 24 frames per second. A fixed mark is painted once
under reduced motion. This leaves viewport sizing in the host and component geometry in the
shared constraint solver. No provider-sized or hidden rows are built for the animation.

The packaged `WindowHarness` and the installed binary both hash to
`176a44649f2d7d49e16751068549ef4537fef71d8f7701e43cbcce9786699b8a`; the package
hash is `72a8bb469bedf38a4edf964ff9eb207fdad6f9592301133592965e724c0d7669`. The
installed Ubuntu arm64 session-row fixture passed. A real saved native Codex session in the
installed shell passed light and dark UI journeys: two working screenshots had different mark
pixels while the full sidebar frame count stayed flat, and a provider permission request
replaced the arc with a filled dot. The same two journeys are wired into the packaged bundle
smoke run. All four screenshots were inspected in `.build/`. The
macOS `sidebar-session-rows` evidence tests passed, and all 50 captured images were decoded-
pixel identical to the preceding run; no baseline was accepted. Theme boundary, UI structure,
vendored-core and whitespace checks passed. The Mac row's hover actions and its other activity
states remain open parity work.

## 252. Saved-session picker rows use the shared sidebar height, 2026-10-20

The live saved-session picker mounted shared, constraint-laid-out session content in 22-point
outer row frames. The ordinary Linux outline and macOS sidebar both use
`SidebarDefaults.rowHeight` (28 points). This was a host geometry mismatch, not a missing
constraint inside the component: `navigatorRowRect` sizes the bounded SDL/AT-SPI viewport
rows, while `SidebarRowDefaults.constrainContent`, `constrainSessionStatus`, and
`constrainSessionStatusContent` solve the content and mark positions on both platforms. The
picker now takes both its frame height and stride from `SidebarDefaults.rowHeight`.

The installed Ubuntu arm64 shell shows a 56-pixel selected row at 2× and mounts seven rows
in a 480-pixel-high navigator. I inspected its selected-title and working-activity captures
in `.build/session-titles-28.png` and `.build/native-working-height-final.png`. The installed
title/deep-selection, agent-catalogue, terminal-catalogue, and native-activity journeys pass;
the activity journey covers an animated provider turn and a pending-permission dot. The title
journey exposed an Escape routing bug: a composer that existed but lacked focus consumed the
second Escape after the picker closed. Escape now checks `!sidebarFocused` before asking that
composer to defocus. The agent-catalogue test's old assertion also assumed a deliberately
refused spawn stayed retained; it now expects the persisted saved row without a live runtime.

The installed session-row fixture, theme boundary, UI structure, vendored-core, Python syntax,
and whitespace checks pass. Builder and installed `WindowHarness` both hash to
`fc5da5f12ad7a0c7ff4c91d4f461fb675a407c0fda93b67fec1b58e81813814e`; the package
hash is `14d08a9751f965d2bc3d0507a898ad580f16341653a8b6024269b165b4165864`. Mac
sidebar evidence from the previous pass established the 28-point row height and its 50 images
were unchanged there; this pass did not rebuild or re-capture macOS. Mac hover actions and the
remaining activity states are still open parity work.

## 253. Saved-runtime selection uses the sidebar capsule silhouette, 2026-10-20

The ordinary Linux outline already paints selected session rows through the shared
`SidebarHoverRowView`, but the separate saved-runtime picker drew its selected `Specimen.Row`
over the entire host rectangle with a fixed five-point corner. Installed shell evidence put that
orange rectangle at x=12…467 and y=86…141 physical pixels in a 480-pixel sidebar. The matched
Mac Threading-theme and ordinary Linux outline capsules begin at x=20, end at x=459, and inset
one point vertically from the 28-point row.

Picker session and terminal rows now derive their local selection inset from the same
`SidebarDensity.selectionInsetX` that `SidebarHoverRowView` uses, accounting for the picker's
six-point viewport origin. They draw the capsule with `SidebarRowDefaults.hoverHighlightInsetY`
and the theme's fitted control radius. The row frame remains the bounded SDL/AT-SPI viewport,
and its content and status views keep their shared constraints. Action and account list rows
retain their distinct menu treatment. Only mounted picker rows compute this constant-time
geometry; animation still updates only the activity mark's small texture region.

The installed Ubuntu arm64 working capture at `.build/native-working-capsule-final.png` and
saved-terminal capture at `.build/terminal-catalogue-capsule-final.png` were inspected. The
agent row's selected fill bounds are x=20…459 and y=88…139, the same 440×52-pixel core
rectangle as the ordinary Linux outline and Mac Threading-theme selected row at 2×. Their
corner contours differ by a pixel at the very tips in the Mac and Linux captures. The installed
native activity journey still passes animated working and pending-permission states; the
installed title, agent-catalogue and terminal-catalogue journeys also pass with seven visible
picker rows. The session-row layout fixture and theme-boundary, UI-structure, and whitespace
checks pass. The builder and installed `WindowHarness` hash to
`50da2aa3adba1be1e16c09349450249046687f1d2884f4385e6744afe8d95f64`; the package
hash is `73b24a09c40080d5b54d206c939ee265f8ec297e5d43b6814c5982dbc5388d91`.
Mac source was unchanged and was not rebuilt in this pass. Mac hover actions and the remaining
activity states are still open parity work.

## 254. Claude background work keeps the saved row marked after the turn, 2026-10-20

The Mac sidebar has a distinct `readyWithBackgroundWork` state: a four-point filled dot while
Claude can accept another prompt but still has live background tasks. The Linux row previously
went idle as soon as the foreground turn finished, even though its Claude stream already emitted
`backgroundWork` events. `NativeWorkspaceSession` now records the most recent full task count
from those events and ranks pending user input, loading, and foreground work ahead of the
background state. A new stream clears the previous count. Its visible row paints a static dot
with the same `SidebarRowDefaults.sessionBackgroundDotSize` used by the Mac indicator, centered
in the existing shared constraint-laid-out status slot. The background state does not schedule
the working arc's animation patch.

The installed Ubuntu arm64 Claude journey passed in light and dark themes: the accessible saved
row reported background work after the turn, a visible dot appeared in its trailing slot,
remained pixel-still, and disappeared after the provider restated an empty task list. I inspected
the active and cleared shell captures in `.build/native-background-active-light.png`,
`.build/native-background-cleared-light.png`, `.build/native-background-active-dark.png`, and
`.build/native-background-cleared-dark.png`. The existing installed Codex journey still passed
its working arc and pending-permission dot. The installed session-row fixture passed. The builder
and installed `WindowHarness` hash to
`7736f3ceb0413311b81913960743206ea6d9ff985c655a44baf63e5e50ec3b5a`; the package hash
is `ae3b343c1d45898f8b8dad04a25f9c3e1c5e2c76fdfb3be15eb05838146e353d`.

The Mac hover Archive control is still open: its action is a two-system transaction through
`ProviderArchiveSync`, which Linux does not compile yet. Showing the button before that behavior
exists would make the parity surface misleading.

The targeted macOS `sidebar-session-rows` evidence run passed all four tests. Of its 50 captures,
38 are decoded-pixel identical to the preceding run; the other 12 full-window captures rendered
at 1× instead of the previous 2× backing scale. Their layouts were inspected, including the
Threading light outline, and no change was seen beyond capture scale. No baseline was accepted.
Theme-boundary, UI-structure, Python syntax, and whitespace checks passed.

## 255. Archived conversations leave Linux navigation before its row cap, 2026-10-20

The Mac sidebar excludes archived sessions, but Linux's indexed navigator counted every
retained session and selected the most recent 512 before decoding. An installed-shell fixture
with five saved sessions showed both archived identities as ordinary visible rows. That same
test failed against the previous package at its exact accessible-row assertion.

`ProjectDatabase.navigationSnapshot` now applies one guarded archived predicate to its count
and recent-row queries. The SQL filters before `LIMIT`, so archived conversations cannot crowd
out visible ones. Legacy sessions without an `archived` key remain visible. A malformed unrelated
payload remains in the count instead of being silently hidden by a partial read; the full graph
loader still diagnoses it. An exact `sessionRecord` read retains archived conversations. The
provider rollout snapshot and three-way reconciliation plan were moved byte-for-byte from
`ProviderArchiveSync` into Foundation-only `ProviderArchiveState.swift`, which the macOS app and
Linux CoreSlice compile from the same source. Session-row customization remains at
`sidebar.session-row@1`; selection, activity, and actions stay host-owned.

The Linux core contracts pass for archived counts, newest visible rows after the cap, durable
archived records, and active/archived/absent/ambiguous provider rollouts. The targeted macOS
database case and all ten `ProviderArchiveSyncTests` pass. The installed Ubuntu arm64 journey
passes with only the three unarchived fixture rows in the AT-SPI list; its shell screenshot was
inspected at `.build/archive-navigation-installed.png`. The installed 5,100-project / 1,024-
terminal outline regression also passes. On the Release 5,100-session storage fixture, the
bounded navigator measures 12.7 ms median / 14.5 ms maximum with the archive filter, compared
with the earlier 8.1 / 8.7 ms; the matched full-graph read is 40.7 / 48.6 ms. This is a measured
4.6 ms median cost on a worker, not a claim about window launch time. The builder and installed
`WindowHarness` hash to `7e2ce2f2b5ae7daa3a2f84a4dafe586b4d0523e7a589dddba386f7a059ee4719`;
the package hash is `8a6a59b4bf8aad7327a80885f8eb817399601270f6015b99a00949d6ff2bb53c`.

The hover Archive control and Settings restore path remain open. Linux has the provider-state
rules now, but still needs the stop barrier, account-routed provider command, durable transaction,
Undo, and restored-row presentation before exposing Archive as an action.

## 256. Linux Snooze has durable deadlines and native activity wakes, 2026-10-20

The session row menu now offers Snooze and Unsnooze beside Pin and Archive. Mac and Linux use
`SnoozeWallClockMoments` for the same rounded hour, next-day morning and next-Monday dates; the
shared calculation also corrects the pre-9 AM case where the Mac menu named today's 9 AM as
"Tomorrow" or this Monday as next Monday. Mac's targeted preset suite passed all 24 tests.
The Linux menu still needs the custom-time picker and the remaining session actions.

Linux's one off-thread snooze coordinator checks the exact session and project under the store
lock before each write. A startup pass materializes deadlines missed while the app was closed;
the host keeps one map of remaining deadlines and sends only due IDs to a batched indexed write.
Clock changes are rechecked at most a second later. A new native permission or question wakes
the session early; a turn completion spends the snooze only if that outcome was pending when
Snooze was chosen. Visiting a Woke session clears its durable receipt. Terminal-backed sessions
still need their provider-neutral important-activity edges before their snooze behavior fully
matches macOS.

The installed Ubuntu arm64 journey passed right click and keyboard menu entry, preset Snooze,
Unsnooze, an expired deadline at startup, a deadline while the app remained open, wake receipt
rendering and acknowledgement on visit, then Pin and Archive. Its Snooze preset and selected
Snoozed-row captures at `out/archive-archive-ui21/` were inspected. A native Codex fixture
passed working-to-approval activity while snoozed; the permission woke it with an
`approvalRequested` receipt, and the `out/native-snooze-ui2/native-woke-on-approval.png` capture
was inspected. The Linux Release build, byte-identical CoreSlice verification, theme boundary,
Python syntax and whitespace checks passed.

## 257. The conversation pane's standing constraints have one declaration, 2026-10-20

The Linux conversation pane already used anchors, but it restated the Mac controller's
transcript, status-line and reply-column relationships. `ConversationPaneLayout` now declares
those constraints once under `UI/Design/`; the Mac controller and Linux host both call it.
Each supplies the appropriate pane edge anchors, so Mac's safe area and Linux's SDL bitmap
root remain honest host boundaries. Mac-only rails and overlays add their own constraints.
The UI structure ratchet fell from 3,196 to 3,186 constraint sites, and its checked-in ceiling
was lowered to match.

The Linux Release binary passed the installed native activity journey after this extraction;
its real permission/reply shell capture at `out/native-pane-layout-ui2/native-awaiting-user.png`
was inspected. The installed and builder binary hashes match at
`2eaf7d4851a09ca003af5ac008fb2aa4927cfbb30430f839af96cfa5f9840344`.
The normal macOS Debug app build passed with the reduced UI structure ceiling. Theme boundary,
vendored CoreSlice equality and whitespace checks also passed. This extraction keeps the prior
Mac equations; the post-extraction visual inspection in this pass was on the installed Linux
shell.

## 258. The custom Snooze picker reuses the Mac constraints, 2026-10-20

The Linux session menu now offers `Custom time…` through the shared valid-day and quarter-hour
policy. The Mac and Linux sheet bodies call one `ScheduleMomentPickerLayout` declaration for
their heading, list columns, minimum scroll heights, footer and root-edge constraints. Their day
and time rows use the same constrained content. A scan of 29 frame reads/writes in the Linux
window harness found the remaining writes at SDL root/bitmap bounds, positioned menu overlays
and recycled rows, scroll documents, or diagnostic fixtures. A manual table-width assignment
in the new picker was redundant with the `NSTableView` shim and was removed.

The child SDL window now enables prompt input routing before waiting for events. Its standalone
bound allows the Mac sheet's exact 520×460-point size at 2× (1040×920 physical pixels), while
the workspace remains bounded at 900 physical pixels high. The picker starts keyboard navigation
in the Time column, matching the Mac sheet's first responder; a column switch and Down then
select Tomorrow. The parent checks the returned moment against the exact session before its
existing durable Snooze write.

The targeted Mac picker suite passed all 11 tests and rendered four live themes; its system-light
PNG was inspected. The installed Linux 1× sheet passed pointer selection, and the installed
keyboard path selected Tomorrow. The installed 2× session-menu journey passed custom Snooze,
verified a future quarter-hour in SQLite and the Snoozed row, then Unsnooze, Pin and Archive.
The 1040×920 sheet and Tomorrow-selection captures at
`out/archive-picker-shared-constraints4/` were inspected. The theme boundary, UI structure
ratchet (3,170 sites), vendored CoreSlice equality, Python syntax and whitespace checks passed.
The builder and installed `WindowHarness` hashes match at
`c48deb85b3bb8232e994b6e21a9f7b20f4411463afb2b4b5e70e391542496a32`.
Other session actions and terminal-backed important-activity Snooze wakes remain open parity work.

## 259. Session renaming follows the Mac prompt and naming policy, 2026-10-20

The Linux row menu now offers **Rename Session…** through the existing one-field themed prompt.
The prompt preloads the custom name, accepts a blank name to resume following the agent, and
offers **Use Agent's Name** when a custom name exists. Its field and buttons are Design controls.
`ThemedAlertLayout` now declares the modern alert's icon, top, edge, minimum-width and section
width constraints once; the Mac alert and Linux prompt both activate that declaration. The
accessibility bridge reads the prompt's actual constrained label, field and button bounds, so
its advertised rectangles do not assume a scale or restate positions.
The Mac Rename sheet rendered at 400×168 points. Linux's constrained view also fitted at
400×168, but the generic SDL window constructor imposed a 180-point minimum and prompt mode
then locked that enlarged window. The constructor now respects an explicitly requested height
below 180 for a non-workspace window; workspace's 180-point minimum stays in force. The installed
rename journey asserts the exact 400×168-point prompt window at both display scales.

The durable mutation runs on a worker under the exact-session store lock. `SessionHistoryTitle`
shares the Mac visible-name and placeholder policy with Linux, so a changed name records the
same searchable history and an unnamed session does not invent a prior name. The bounded row
snapshot cannot silently replace a longer stored custom title when the prompt's unchanged
visible prefix is submitted. The parent updates the row and active pane header only after the
save succeeds.

The installed 1× and 2× X11 journeys passed the exact 400×168-point window assertion,
row-menu activation, Unicode input, SQLite persistence, previous-name history, the clear
action, and blank confirmation. Their real-shell captures at `out/rename-session/` were
inspected beside the 400×168 Mac sheet render from `SessionRenamePromptRenderTests`.
The existing worktree prompt passed light/dark keyboard and AT-SPI regression after the
SDL sizing fix. The installed 2× session-menu
regression also passed preset and custom Snooze, Unsnooze, Pin, and Archive. The builder and
installed `WindowHarness` hashes match at
`a27fc12ff4720f3774891a243181d6995fdca8233de6abe3acd37e8b8eb5642c`.
The rename journey is mounted into the installed bundle smoke at both scales.
An installed live-agent fixture then renamed the selected row while its PTY stayed active. The
header and row both displayed the saved name, the database held the same custom title, and the
agent received no prompt or menu input. Its shell capture at
`out/rename-session/active-pane-renamed-header.png` was inspected.

## 260. Constraint audit and active-session Close, 2026-10-20

The frame audit followed the live Linux opening, conversation, header, sidebar and alert trees.
Their standing content uses the same production `NSLayoutConstraint` declarations as macOS:
`PromptChrome`, `ConversationPaneLayout`, `SidebarRowDefaults`,
`ThemedProjectRowView.pin(to:)`, `ScheduleMomentPickerLayout` and `ThemedAlertLayout`.
Remaining frame writes in those paths size SDL bitmap roots, outline row slots, scroll documents,
floating popup bounds and bounded visible menu rows. The Mac menu document also positions its
row slots by frame. One old `NavigatorTextRow` path still calculated hardcoded label rectangles,
but no call site ever appended a row to it. That dead path was removed; the live outline already
mounts the shared constrained project, session and terminal content views.

The active agent's row menu now offers **Close Session**. Its warning confirmation uses the
shared alert content constraints and Design controls. A worker revalidates the exact saved
session under the store lock, asks the PTY host to stop the child, and leaves the database row
for resume. Cancel leaves the process running. The installed 2× AT-SPI journey passed both
choices, checked the daemon's exit and retained SQLite row, and found no prompt input in the
agent PTY. The final installed static `WindowHarness` and builder binary match at SHA-256
`d705f627325d26e4d7cef16c38d3994caf459bc9776b7ec628e7713c4800298e`.
Its real-shell capture at `out/session-close/session-close-confirm-final-2x.png` was inspected.
The targeted Mac render test passed and its 400×194-point sheet capture at
`out/session-close/session-close-prompt-mac.png` was inspected alongside it. Theme boundary,
UI structure and whitespace checks passed.

The next installed 2× journey mounted the production `SessionPlaceholderView` under the page
header after Close. The view now owns the same four mounting constraints on both hosts; macOS
passes its content guide and Linux passes its below-header render root. The journey kept the
saved row selected, published the solved title and action bounds to AT-SPI, and reopened the
terminal through **Start Again**. Its inspected real-shell capture is
`out/session-close/session-close-dormant-final-2x.png`; the installed static binary matches the
builder at SHA-256 `0785dff8cb6b54ac2482af9c4c2b1226e9ca824c17256ce1fee59bfbf2f1037a`.
The journey also caught a blank heading for custom-renamed sessions: both hosts now use the
session's displayed name when composing the dormant title. The targeted macOS hosted-shell
render passed with an empty raw title and the same custom name; its full-window capture at
`out/session-close/session-close-dormant-mac.png` was inspected beside the Linux capture.
The captures use different themes and viewport sizes, so they establish the matching content
and constrained placement rather than a pixel diff. The Mac sheet includes a remembered
“Don't ask again” checkbox, while Linux's roughly 400×150-point dialog omits it.

An installed 2× follow-up right-clicked a saved row while its child ran detached in the daemon
and no terminal was mounted. One bounded off-thread daemon survey added **Close Session** to
that open menu; the worker wake delivered the result without polling the UI loop. The Close
worker revalidated the exact saved row, stopped the daemon child, and retained the row without
mounting its terminal or sending menu input to the PTY. The inspected shell capture is
`out/session-close/session-close-unmounted-menu-2x.png`. The existing mounted Close/rename/
dormant/resume journey also passed against the same installed static binary, SHA-256
`93bf9986f17a189a8b304f2c8c74588748b2e4583e1ca7610eb7779dd3a98134`.

## 261. Shared opening composer assembly, 2026-10-21

The Mac and Linux opening composers already activated the same bounded column constraints in
`PromptChrome`, but each host still built its chip row and vertical stack separately. Both now
call `configureOpeningChoices`, `configureOpeningColumn` and `mountOpeningColumn` with their own
controls. The component owns the arrangement, spacing and column anchors. The Mac keeps its
optional managed-workspace row and safe-area hero guide; Linux keeps its directly anchored hero
view. The Linux choice overlay remains above the column in drawing order. This shares the
production AppKit declarations with the shim while leaving host-specific content in each host.

The rebase also left the Linux core slice stale. Its manifest now records the three newly needed
Mac sources, and all 139 vendored files verify byte-identically. Linux-only confirmation settings
moved out of the copied core into the window harness. The C smoke contracts link the clipboard
selection bridge used by `Window.c`.

The real X11 composer journey passed window-size, choice-menu, focus-loop, Unicode editing,
wheel, clipboard, accessibility and exact one-agent launch checks. Its tall, compact, narrow,
minimum and typed-prompt captures under `out/composer/` were inspected. The smoke test now waits
for scroll accessibility state and the asynchronous clipboard worker before sending later text;
without that barrier, its immediate Return could replace the selection before the paste arrived.
Five Codex permission combinations passed before the wider matrix was stopped. The focused Mac
`session-composer-layout` render suite passed and its tall and short images were inspected; the
report has no approved pixel baselines. All eight Mac `ComposerWindowFitTests` passed, including
the shortest allowed window and the column's width cap. Theme-boundary, UI-structure, whitespace
and both vendor verification checks passed.

## 262. Shared view ownership audit, 2026-10-21

Sharing only a constraint list still left two code paths assembling the same view. The General
settings page and its rows now use `SettingsPageStructure` and `SettingsRowStructure` from
production Design on both hosts. The Mac `SettingsComponents` facade and the Linux General pane
delegate their common scrolling page, header, section and row hierarchy to those components.
The opening and reply prompts now mount `PromptContentView` for the editor, attachment slot and
footer. Both composers mount `PromptAttachmentStripView` for the scroll document, tile ordering
and rail size. The custom-time Mac sheet controller and Linux SDL host now present the same
`ScheduleMomentPickerView`; only window lifecycle and input dispatch remain with the hosts.

The Linux build and settings-row constraint contract passed. The real X11 General page,
opening composer, two-image attachment rail and custom Snooze picker were inspected. The
opening-composer journey passed focus, resizing, menus, Unicode editing, accessibility and an
exact one-agent launch. The picker keyboard journey selected tomorrow's quarter-hour. A
clipboard-based attachment journey passed image-only submission, two previews, removal, URI
paste, TIFF-to-PNG, raw PNG and text fallback. The separate Xdnd drag journey remains to be
rerun under the bundle's installed X11 environment; its simulated drop was not received in the
concurrently loaded development container. The Mac app compiled the changed Swift sources, but
the render and picker tests remain unverified: Xcode's result bundle and the last Linux screenshot
write hit `ENOSPC` before the tests finished. A storage cleanup proposal is pending. The native
conversation capture now waits for the full-height sidebar paint and samples selection colour
inside the selected capsule; those journey changes also need their complete installed rerun.

The audit still has shared-view work, so this checkpoint does **not** claim one complete UI:

* The Mac `PromptView` owns editor behavior and rich drag/drop. Linux still uses
  `WorkspacePlaceholderPane` / `WorkspaceConversationPane` and `PromptTextView` around the
  shared prompt content and attachment views. Port the remaining AppKit and
  application-service boundary APIs so the hosts instantiate `PromptView` itself.
* `Specimen.Row` still assembles project, session and terminal sidebar wrappers separately from
  the Mac `ProjectRowView`, `SessionRowView` and `ProjectTerminalRowView`, although the inner
  Design content views are shared. Keep the virtual row slot host-owned and reuse the row shell.
* Linux text prompts and the Mac alert now subclass `ThemedAlertBodyView`, which owns their
  heading, section order, action row, and constraints. Their control models and modal event
  hosts are still separate; the Linux host must eventually use the shared `ThemedAlert` model
  and its complete interaction semantics.
* The Linux General settings pane still presents fewer sections than the Mac General page.
  Reuse the complete page composition after its model and settings-store adapters are portable.

SDL bitmap roots, visible virtual row frames and popup-window placement are host geometry,
not duplicate content views. The Pango-backed title label is likewise a rendering shim pending
the shared label's animation backend. The Linux `AgentActivityBeamView` is currently an inert
placeholder because its saved-runtime rows have no verified working-state input; it must be
replaced by the production beam when that state becomes available. These exceptions need review
whenever their content grows.

The shared alert body was added after this checkpoint. Static structure and theme checks pass,
and an unsigned macOS Debug build succeeds. A signed build reached packaging but failed because
an older `ThreadingTests.xctest` inside DerivedData was unsigned. Three macOS alert tests pass;
their rendered classic requesters and the Close Session sheet in the real main-window host were
inspected. Linux `WindowHarness` compiles and its X11 text-prompt smoke passes in both appearances,
with keyboard and AT-SPI actions; the light/dark prompt images were inspected. These checks used
the existing Lima validation VM because Docker Desktop's containerd metadata returned an I/O
error. The shipping Mac `New Worktree` sheet was also rendered and inspected against the Linux
prompt. They share the same content and constraint tree, but Linux measures 400×203 pixels while
Mac measures 400×200; the field and actions are about three pixels lower on Linux. This remaining
Pango/AppKit intrinsic-height difference needs a shim-level fix, not another prompt-specific frame.
The worktree request's title, message, button and placeholder now come from the same
`WorktreePromptSpec.request` on Mac and Linux. The broader prompt/transcript/sidebar migrations
listed above remain open.

The next `PromptView` dependency slice is now shared source on Linux: `ConversationContextRailView`,
`PromptCompletionView` and `ThemedSurfaceView` compile unchanged apart from conditional CoreSlice
imports and the appearance invalidation appropriate to Linux's retained dynamic colours. The
completion panel was mounted from the production presenter in a Linux render fixture in both
appearances; its three rows, unavailable state and selected state passed, and both renders were
visually inspected. The shim now exposes selected accessibility state, middle-button down events,
scroll content size and window resize/move notification names. This is preparation, not a claim
that Linux mounts `PromptView`: the editor still needs media, drag, image and pasteboard
APIs. The render exercise also found that Linux's `SelectionSurface` adapter measured
selection ink against an accent role rather than the painted selection over its actual ground;
it now measures against the painted result. This palette policy remains a separate Linux adapter
and should be replaced by the production `SelectionSurface` when its contrast dependencies are
portable.

The file-mention reference, parser and search-failure values are now in one Foundation-only
`WorkspaceFileModels.swift` source. Mac compiles it through its filesystem-synchronized target;
Linux `CoreSlice` vendors a byte-identical copy, verified by `vendor-core.sh --verify`. The
Linux `AppKit` text view also now exposes the production composer delegate and undo-owner API:
edit notices reach `NSTextViewDelegate`, and `UndoManager.removeAllActions()` clears the same
bounded edit journal the editor uses for Ctrl-Z. The real text editor harness passes a draft
replacement and undo ownership test. A diagnostic compile of the full `PromptView` still has
media, pasteboard, drag, image and theme API gaps, so that view is not mounted by Linux yet.
The desktop text-prompt model is also shared now: `TextPromptRequest.swift` is the one request
type on both hosts, and the worktree's wording comes from `WorktreePromptSpec.request`.
Linux's modal host keeps only its native accessibility identity,
input loop and window flags around that request. The Linux package compiled after this change;
the X11 prompt journey was not rerun at this checkpoint. An unsigned macOS Debug build and the
`WorktreeCreationPromptRenderTests` shipping-shell test passed. Its light and dark dialog captures
were inspected after the model extraction.
`check_ui_structure.py` now also ratchets the runtime Linux host's 15 native-view declarations,
93 constraint sites and 8 stack constructors, excluding links to shared Design sources. A new
Linux-only view hierarchy therefore requires an explicit baseline change and review while the
remaining sites are migrated.

The opening and reply composers now mount the production `PromptAttachmentThumbnail` from the
same source as macOS. Its image crop, border, remove control and constraints are no longer
reimplemented by `LinuxPromptAttachmentTile` and `LinuxPromptAttachmentRemoveButton`; both
Linux-only classes were removed. The Linux host still owns bounded decoding, file admission,
submission and AT-SPI registration. The shared tile exposes its existing identity and remove
rect to that host, while Linux's symbol and radius adapters provide the required AppKit roles.
`WindowHarness` and the unsigned macOS Debug app build. The real Xvfb attachment journey passed
Xdnd, URI-list, TIFF, PNG, text paste, image-only submission and removal. Its one- and two-tile
captures, including the compact window, were inspected in `out/tile-port/`. Opening a tile in
the media inspector and its context menu remain Mac-only services; Linux leaves those actions
unadvertised until the host implements them. The enclosing `PromptView`/Linux pane duplication
remains open.

The Linux menu and editor now compile the production `SelectionSurface.swift` directly. The
Linux-specific copy of `stated` and the editor's simplified `dynamic` selection were removed;
the host theme boundary supplies the selected palette role and full `Design.Ink` value used by
the common algorithm. `WindowHarness` builds. The real Xvfb composer journey passed keyboard,
AT-SPI, Unicode edit and selection actions; its selected-text and provider-menu images were
inspected in `out/selection-port/`. The production completion panel's selected row was rendered
and inspected in both light and dark appearances. Linux still exposes only the checked theme
snapshot, so other themes require their palette export before this proves visual parity there.

A direct diagnostic link of the complete Mac `PromptView.swift` into `WindowHarness` still fails
to compile. Most early missing model names (`ComposerCapability`, `ComposerCompletionQuery`,
`WorkspaceFileReference`, `WorkspaceFileMentionQuery`, `SessionID`) already exist in Linux
`CoreSlice`; they need explicit module imports or aliases. The next substantive seam is AppKit:
`NSDraggingInfo`/`NSDragOperation`, drag registration, image pasteboard reads, bitmap decode,
and text layout methods. The view also calls Mac application services for media inspection,
attachment custody, file promises and thumbnail preparation. Linux currently implements those
through its pane host. The diagnostic link was removed after recording the errors, so the
checked Linux target remains buildable. Porting the full view should migrate these services
behind AppKit and host adapters before replacing either Linux pane; declaring an empty
`PromptView` counterpart would only hide the duplicate.

## 263. The native Linux conversation uses the production transcript table, 2026-10-22

The real saved-conversation pane now mounts `ConversationTranscriptTable` from the same source
as macOS. The shared table owns row order, dividers, adjacent-tool folding, viewport recycling,
Markdown block paging, disclosure state, row rhythm and text selection. Its production
`ConversationRowView` factory builds visible cells. Linux's pane supplies only the local
streaming line, decision cards and input/composer host. `DocumentRowSource` no longer builds
native conversation rows; it remains for isolated document and diff fixtures. The unused
`ConversationContentTable` adapter was removed.

The AppKit compatibility layer gained the table callbacks, event click count and text hit
offset needed by those exact sources. Linux's event loop feeds drag and release events to the
same `TranscriptTextSelection` object, which owns range, highlight and copy behavior on both
platforms. Live and replayed assistant Markdown page boundaries are prepared on the session's
bounded worker before UI delivery. The common table materializes only viewport content and
parses only an active page. Transcript spacing metrics were extracted from `Design.swift` into
a source linked unchanged by both builds.

`WindowHarness` and the unsigned macOS Debug app build. The full native Xvfb conversation
journey passed three turns on one daemon child, multiline and Unicode input, cross-block
selection/copy, light and dark appearance, retained draft, restart replay and same-thread
resume. The first reply, highlighted selection and replayed transcript were inspected in the
real product shell under `out/transcript-table-port/`. The native permission journey covers
the production tool row, decision card, deny/allow and two-page question flow. Theme and
structure checks pass without increasing the Linux-only view or constraint baselines.

Full parity still requires the production chart canvas on Linux (the shared row factory
currently shows the tool row when chart rendering is unavailable), selection autoscroll when
a drag leaves the transcript viewport, and the enclosing `PromptView` port. The sidebar row
shells, complete General settings composition and alert interaction model remain the other
duplicated UI assemblies identified in §262.

## 264. Session row status and actions share one view, 2026-10-22

The macOS `SessionRowView` and Linux's recycled navigator cell both used the same
`SidebarRowDefaults` constraints, yet each separately constructed the status column, `⋯` and
Archive controls, and their hover stack. `SidebarSessionTrailingSlot` now creates that subtree
once in production Design source. Both hosts mount it and supply only their session-specific
status content and action callbacks. The slot retains its accessibility identities and the
Mac crossfade/width behavior; Linux still creates it only for visible session cells. The Linux
UI structure ratchet falls from eight to seven local stack constructors.

The Linux build and session, terminal and project layout fixtures pass. The real native
conversation journey still passes after the change, and its mounted sidebar row was inspected.
The archived-navigation journey rendered the actual hover controls with title truncation and
correct row bounds. Four macOS `sidebar-session-rows` evidence tests pass; the repository's
decoded-pixel report matches all 50 current renders against the nearest pre-change capture,
and the light and dark hover states were inspected. The installed Linux journey passed
Snooze/Unsnooze, Pin and Archive through the same mounted row and its menu; its hover and
post-archive renders were inspected. The test fixes its calendar to the same Stockholm time
zone as the app under validation, so "tomorrow" cannot straddle the UTC midnight boundary.
The remaining project, terminal and session row shells still need a
shared owner where their assembly overlaps; this extraction covers the common trailing
session subtree, not the complete sidebar row.

## 265. The default session row mounts from one assembly, 2026-10-22

`SessionRowView` and Linux's recycled `Specimen.Row` now instantiate
`SidebarSessionRowAssembly` from the production Design source. It creates the native identity
and title stack plus the shared trailing slot, mounts both as cell children, and installs the
outer content, slot-size and edge constraints. The Mac cell retains extension replacement,
selection, hover, activity and action routing; Linux retains outline identity, virtual row
placement and its saved-session action routes. This removes another Linux-only stack
constructor without making all session-row behavior portable.

`WindowHarness` and the unsigned Mac Debug app build. The Linux session, terminal and project
layout fixtures pass. The real Xvfb archived-navigation journey passes Snooze/Unsnooze, Pin and
Archive. Its 1120×900 hover and post-archive renders were inspected and are pixel-identical to
the pre-change Linux captures. The UI structure ratchet now records six Linux-only stack
constructors and 3,119 constraint sites overall. The Mac `sidebar-session-rows` suite passes
four tests and renders 50 states. The repository evidence comparator accepts all 50 decoded
images against the preceding capture; the light and dark hovered rows were inspected.

The full Mac `PromptView` is still not mounted on Linux. The current diagnostic build of that
source reaches AppKit drag, pasteboard, bitmap/text-layout APIs and Mac attachment services,
after the Linux core's composer/query model names. Those adapters are the next large seam;
repeating the surrounding composer in a Linux-only view would preserve the duplication.

## 266. Both Linux composers mount the production PromptView, 2026-10-22

The opening and saved-conversation hosts now mount the exact `PromptView.swift` source used by
macOS. Their separate editor, footer, submit and attachment subtrees are gone. The opening host
keeps its external Start button and sets `.outside`; the reply host uses `.footer` and the view's
own send/stop control. The hosts still own provider choices, transport, native event routing and
AT-SPI publication. The old `LinuxPromptAttachmentStrip` has been deleted.

The port exposed three shim defects that the separate Linux compositor had hidden. An active
constraint must be removed from the container where it was installed even if its view has since
been reparented. An empty `NSImageView` has no intrinsic size, or its required hugging conflicts
with a real chip's fixed symbol slot. A text document that shrinks after its viewport gains a
width must clamp the clip's scroll origin, or the text can sit outside the visible rect. The
production prompt fixture now mounts and renders text, a model chip and footer send control in
both appearances. Image preparation and clipboard reads enter the native bounded worker mailbox,
which wakes the synchronous window loop and keeps submission disabled until delivery.

`WindowHarness` builds and the real Xvfb Codex conversation journey passed three turns, growth,
scrolling, selection, dark appearance and restart replay. The opening composer journey passed
resizing, focus order, menus, Unicode editing, accessibility and launch. The attachment journey
passed Xdnd, URI-list, TIFF-to-PNG, raw PNG, removal and image-only submission. Captures of the
mounted reply, opening composer and two-image rail were inspected under
`out/prompt-view-native/evidence-3/`, `out/prompt-view-opening-1/` and
`out/prompt-view-attachment-2/`. The Linux UI structure ratchet drops from 93 to 89 local
constraint sites and from six to four local stack constructors.

## 267. Terminal rows share their action slot and constraints, 2026-10-22

`ProjectTerminalRowView` and the Linux outline cell now instantiate
`SidebarTerminalRowAssembly` from production Design. It owns the terminal icon/title stack,
the actual `ThemedIconButton`, and the same edge relationship to the cell. The Mac wrapper
continues to own hover, menu and foreground spinner behavior; the Linux host owns virtual row
placement and keeps the action disabled and absent from AT-SPI until it has a terminal-menu
route. No separate blank Linux slot or local terminal constraints remain. The UI structure
ratchet drops from 89 to 86 Linux constraint sites.

The Linux `WindowHarness` build and wide/narrow/recycled terminal layout fixture pass. A native
1120×480 Xvfb window with six saved terminals was rendered and inspected at
`out/terminal-assembly.fcUHahEx/evidence/terminal-assembly-native.png`. The unsigned Mac Debug
app build passes. The `sidebar-session-rows` evidence entry passes four macOS tests and renders
50 states; the terminal row and shipping-window captures were inspected. This run had no
checked-in baselines for that entry, so it establishes rendered evidence but no accepted pixel
regression comparison. The full 5,100-project native-outline journey did not reach its row checks:
its initial viewport began at row one while its selected project was row zero. The focused
one-project window above verifies this mounted terminal row, but does not validate the large
outline journey.

The ownership audit still has substantive work: the Linux alert builds its own controls around
the shared `ThemedAlertBodyView`; General settings uses shared page structure but omits Mac
sections; Linux menu surfaces still draw their own panel around shared menu rows; the terminal
menu and busy spinner are not yet hosted on Linux; and the saved-runtime beam remains a Linux
placeholder. `WorkspacePlaceholderPane` still creates the opening host's
choice and action stacks, but delegates their spacing and constraints to `PromptChrome` and
mounts the exact `PromptView`; these stacks are host composition until the corresponding Mac
presenter can be moved behind a shared owner. The remaining Linux structure count is an audit
queue, not proof that every site duplicates macOS UI.
