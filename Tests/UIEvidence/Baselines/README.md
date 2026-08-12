# UI evidence baselines

Approved PNGs mirror the paths produced under a UI evidence run's `current/` directory. The
report treats exact decoded RGBA equality as accepted, a missing baseline as new, and any other
result as changed. PNG metadata and compression do not create false failures; one changed rendered
pixel does. For changed captures, the regression report shows current, baseline and an exact
difference mask together.

Generate a report without changing baselines:

```bash
scripts/ui-evidence.sh
```

Every run contains `review.html` for polish annotations and `regression.html` for sign-off. In the
regression report, mark each changed/new image Approve, Investigate or Reject and export
`decisions.json`. Apply approved images only with the hash-bound approval command:

```bash
python3 scripts/approve_ui_evidence.py \
  --report .build/ui-evidence-reports/<run>/report \
  --decisions ~/Downloads/decisions.json \
  --baseline Tests/UIEvidence/Baselines \
  --require-complete
```

The decisions are tied to the report id and each image hash. The command refuses stale or moved
artifacts and overwrites an existing reference only when that exact current image was explicitly
approved. Baseline PNGs are ordinary reviewed source changes.

`--accept-new-baselines` remains a bootstrap shortcut for captures with no reference; it never
overwrites an existing baseline. Prefer decisions once the initial baseline set exists.

The native iOS catalogue uses the same policy with a separate baseline root:

```bash
scripts/ui-evidence-ios.sh
scripts/ui-evidence-ios.sh --accept-new-baselines
```

iOS references live under `Tests/UIEvidence/iOSBaselines/`. Generated simulator images and HTML
reports stay under `.build/ui-evidence-ios-reports/`; review them there before accepting any new
reference into the repository.
