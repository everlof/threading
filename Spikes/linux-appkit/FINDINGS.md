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
