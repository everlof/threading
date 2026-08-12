---
name: ui-evidence-review
description: Capture, compare, annotate, approve, and troubleshoot Threading's macOS and iOS UI evidence. Use for pixel-perfect snapshot checks, reviewing a visual diff, fixing exported annotations, accepting baselines, polishing one theme/chrome/surface, adding visual coverage for a feature, or deciding which complete or targeted evidence command to run.
---

# UI Evidence Review

Use the repository's deterministic evidence manifests and shipping render paths. Do not create a
parallel snapshot harness, compare file bytes, or accept a changed PNG without the exported human
decision that names its exact hash.

Before changing product UI, read `docs/THEME_BOUNDARY.md`,
`docs/architecture/design-system.md`, and the relevant surface architecture note. Read
`docs/architecture/ui-scenario-testing.md` before changing the evidence system itself.

## Choose the workflow

- For pixel regression or baseline sign-off, open `report/regression.html`.
- For requested polish or subjective design feedback, open `report/review.html` (also
  `report/index.html`).
- For a single macOS feature, run `scripts/ui-evidence.sh --only <coverage-entry>`.
- For one macOS stock theme, run `scripts/ui-evidence.sh --theme <theme-id>`.
- For one iOS feature or capture, run `scripts/ui-evidence-ios.sh --only <entry-or-capture-id>`.
- For a broad design-system, layout, shared component, or theme-boundary change, run the complete
  platform catalogue before claiming completion.

Coverage entry ids live in `Tests/UIEvidence/coverage.json` and
`Tests/UIEvidence/ios-coverage.json`. Prefer the smallest selection that contains the changed
surface while iterating. A partial report is not proof that the complete platform is clean.

## Review a regression

1. Generate evidence without mutating baselines.
2. Open `regression.html`. It defaults to changed, new, and unbaselined images.
3. Inspect Current, Baseline, and Diff. Treat a single changed decoded RGBA pixel as a real diff.
   PNG compression or metadata changes are intentionally ignored.
4. Mark every actionable image:
   - `Approve`: the new pixels are the intended new reference.
   - `Investigate`: cause is uncertain; do not change the baseline.
   - `Reject`: the implementation is wrong; do not change the baseline.
5. Export `decisions.json`. The export is bound to the report id, artifact id, baseline-relative
   path, and current SHA-256.
6. Apply only approved decisions:

```bash
# macOS
python3 scripts/approve_ui_evidence.py \
  --report .build/ui-evidence-reports/<run>/report \
  --decisions <decisions.json> \
  --baseline Tests/UIEvidence/Baselines \
  --require-complete

# iOS
python3 scripts/approve_ui_evidence.py \
  --report .build/ui-evidence-ios-reports/<run>/report \
  --decisions <decisions.json> \
  --baseline Tests/UIEvidence/iOSBaselines \
  --require-complete
```

7. Inspect the baseline changes in Git, regenerate the same selection, and require exact matches:

```bash
scripts/ui-evidence.sh --only <entry> --require-accepted
scripts/ui-evidence-ios.sh --only <entry> --require-accepted
```

Never use `--accept-new-baselines` to accept an existing changed baseline. It is a create-only
bootstrap for missing references.

## Work from design annotations

In `review.html`, choose Annotate image, click the exact point, enter a concise requested change,
and assign polish, important, or critical severity. Export `annotations.json` before handing the
review to another task or agent; browser storage is only working state.

For each annotation:

1. Match `artifactID` in the relevant coverage manifest and locate its source contract.
2. Confirm `currentSHA256` matches the current report. If it does not, regenerate/import and ask
   whether the note still applies; do not silently transfer coordinates to different pixels.
3. Fix the shared design component or owning layout rule when the symptom appears in more than one
   theme. Special-case a theme only when the theme's authored material or chrome contract truly
   differs, and keep that distinction in the theme/design layer.
4. Re-run the smallest affected entry/theme first, then the complete affected platform matrix.
5. Resolve the annotation only after the regenerated image proves the visual outcome and the
   regression report has no accidental changes.

## Add visual coverage

Add one canonical capture for each important visual state, not the cross-product of every state
and every theme. Put shared chrome pressure on the matrix sentinel:

- macOS `app-theme-chrome-matrix` automatically iterates `AppThemeLibrary.stock` using a rich
  native conversation. A new stock theme is covered without editing the manifest.
- iOS `ios-chrome-matrix` iterates every deterministic Mac-supplied DTO fixture. Add a DTO and a
  capture when a new materially distinct mobile chrome becomes supported.

Add feature-specific states to their existing entry. Create a new entry only for an independently
navigable surface, component contract, or user promise. Keep data bounded and use the real
virtualized production controller for transcript/file/session-sized content.

## Diagnose unexpected diffs

Use the report's environment fingerprint before touching baselines. Check device, appearance,
scale, OS/toolchain, theme id, fixture id, font availability, animation/caret stabilization, and
keyboard state. A widespread diff with identical bounds across unrelated views usually indicates
environment or shared-token drift; one bounded region usually belongs to the component shown
there.

If a diff is nondeterministic, fix stabilization or fixture state. Do not mask it with tolerance,
pixel thresholds, repeated retries, or a broad crop. Exact comparison is the contract.

Generated reports remain in `.build` and are not committed. Approved baseline PNGs are committed
with their implementation. Commit an annotation export only when it is an intentionally active
handoff, then remove it when resolved.
