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
