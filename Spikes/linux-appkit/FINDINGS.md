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

That third one produced the most transferable detail. `Spikes/linux-appkit/Sources/Compression/`
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
