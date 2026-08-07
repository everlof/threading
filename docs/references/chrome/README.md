# Chrome reference archive

This directory is the evidence ledger for every app theme that takes over the window frame.
It exists because a title bar alone is not a chrome: menus, buttons, fields, scrollbars,
progress, transient surfaces, typography, and icons all have to belong to the same historical
system.

The repository stores provenance, checksums, measurements, and crop recipes—not unlicensed
third-party screenshots. `scripts/chrome_reference.py fetch` downloads a recorded source into
the ignored `.cache/` directory, and `extract` makes exact, unscaled PNG crops in the ignored
`.generated/` directory. A source image is committed only when its manifest records a licence
that permits redistribution or identifies it as project-owned.

Some original references are only preserved in period PDF manuals. Such a source records
`pdf_page` and `render_dpi`; extraction renders that single pinned page with Poppler before
applying the ordinary pixel crop. The gallery labels the result as a documentation figure so it
cannot be mistaken for a native screenshot.

## Required component coverage

Every manifest answers the same matrix:

- `window_frame`, `title_bar`, `window_buttons`, `toolbar`
- `buttons`, `choice_controls`, `fields`, `menus`, `popovers`
- `scrollbars`, `lists_tables`, `progress`, `alerts_toasts`
- `typography`, `icons`

Coverage states are deliberately about evidence, not whether some code happens to draw a
component:

- `missing`: no reliable reference has been preserved yet.
- `source_found`: a source exposes the component, but its geometry/colour has not been measured.
- `measured`: a crop or explicit measurement has been recorded and implementation can target it.
- `verified`: a rendered app fixture has been compared to the measured reference at the stated
  scale and tolerance.
- `not_applicable`: the original system had no meaningful equivalent; the note must say what
  Threading should do instead.

No chrome is “pixel-perfect” while a required component is `missing` or merely
`source_found`. `verified` is per component, never inferred from the theme existing.

## An authored chrome

Not every takeover reproduces a release. `tui` is drawn in the idiom the full-screen terminal
programs share — a box in rule characters, a header row closed by a seam, hairline caption
cells — and reproduces no single one of them. A chrome like that still gets a manifest,
because the ledger's job is to say what evidence exists, and “none, by construction” is an
answer the archive has to be able to give. Every component is `not_applicable`, and each note
says so explicitly and names what Threading draws instead.

The distinction matters in one direction only: an authored chrome may never carry `measured`
or `verified` coverage, since both mean “compared against a preserved original” and there is
none. What holds it honest instead is the shared component sweeps and the whole-window render
in `WindowChromeComponentTests`. Do not reach for `not_applicable` to retire a component of a
*historical* chrome that simply has not been photographed yet — that is `missing`.

## Workflow

```bash
scripts/chrome_reference.py validate
scripts/chrome_reference.py import retro-98
scripts/chrome_reference.py fetch aqua-tiger
scripts/chrome_reference.py extract aqua-tiger
scripts/chrome_reference.py reproduce aqua-tiger
scripts/chrome_reference.py report
scripts/chrome_reference.py html
```

`import` is the source-code half of the archive. It downloads the exact, checksummed files in
`implementation-sources.json` into ignored `.cache/implementations/` so an existing open
implementation can be read beside its Swift port. These are not runtime dependencies and the
app never executes web code. A source is admitted only at a pinned revision with an SPDX licence;
fonts and icons are excluded unless their own redistribution provenance is independently clear.
The historical screenshots remain the final visual authority: an implementation can reveal a
control's construction without proving that its pixels match the period target.

Omit the chrome ID from `fetch`, `extract`, or `reproduce` to rebuild the complete local
evidence archive. `reproduce` runs focused AppKit render tests and captures the production
design-system components named by each manifest; the gallery never substitutes an HTML/CSS
approximation for the app's actual drawing code.

Each reproduction declares one of two comparison modes:

- `component_fixture` is a reusable production-component specimen. It is useful for finding
  family-level problems, but its content or geometry may be broader than a historical crop.
- `exact_reconstruction` reproduces the linked reference crop's states, dimensions, and 1x
  composition specifically enough for direct comparison.

An exact reconstruction links only the **tight control crop** it actually reconstructs. A
second, wider crop may preserve frame seating, neighbouring content, or a resize corner, but it
is declared with `"role": "supporting_context"` and displayed as additional historical context
rather than stretched beside the control. An omitted role means `comparison_target`; supporting
context cannot be linked to a reproduction and does not block verified component coverage. The
renderer must emit exactly the linked crop's physical pixel dimensions; `reproduce` fails and
the gallery shows a wrong-size warning instead of scaling a stale or generic fixture into an
apparently valid comparison.

Review state is independent: `pending`, `mismatch`, or `verified`. Validation refuses a
`verified` reproduction unless it is an `exact_reconstruction` with a documented tolerance,
method, and review date. It also refuses to promote component coverage to `verified` until
verified reconstructions cover every comparison-target crop for that component. A render
existing on disk therefore never becomes evidence of fidelity by accident.

Validation requires every `measured` or `verified` component to own at least one exact crop,
and every cropped source to have a direct URL, original pixel dimensions, and SHA-256. That
keeps “we looked at a page once” distinct from a reproducible measurement.

`html` builds `.generated/index.html`, an offline gallery of every component slot and every
exact excerpt. Where a reproduction is declared, it places the historical pixels and the real
Threading component render in one labelled pair per reconstruction and shows the comparison
mode and review state. Unlinked crops are grouped separately as supporting context, never in the
comparison lane. It also includes provenance, source dimensions, crop coordinates, coverage
filters, and a native-pixel viewing mode. It deliberately refuses to build when an excerpt is
missing; run the complete `fetch` and `extract` commands first. Reproduction placeholders name
the command needed to generate them. The page and its images are reproducible outputs and
remain ignored by Git.

When a screenshot reveals a component we did not have before:

1. Add it as a source with the original page URL, direct asset URL, owner, dimensions, and
   SHA-256 when the asset is stable.
2. Add one tight crop per state that matters (resting/pressed/disabled/key/inactive, etc.).
   Coordinates are top-left image pixels and are never silently rescaled.
   For a PDF source, coordinates address the manifest's declared page at its declared DPI.
3. Record measurements and ambiguity in the component note. A preference-dependent state, such
   as Tiger's two possible scroll-arrow layouts, stays explicit.
4. Implement through `AppTheme.Material` or `WindowChromeStyle`, render the shared fixture at
   1×, compare it to the crop, and only then promote that component to `verified`.

Recreations are useful comparison fixtures, but never replace originals. Put project-authored
recreations under a source with `kind: "recreation"`, name the originals they interpret, and
keep their assumptions in the manifest.
