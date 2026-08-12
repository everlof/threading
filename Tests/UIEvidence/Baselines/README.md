# UI evidence baselines

Approved PNGs mirror the paths produced under a UI evidence run's `current/` directory. The
report treats an exact byte match as accepted, a missing baseline as new, and any other result as
changed; it still shows current and baseline images together so a human reviews the visual change.

Generate a report without changing baselines:

```bash
scripts/ui-evidence.sh
```

After reviewing the report, a deliberate first-time acceptance can copy only images that do not
already have a baseline:

```bash
scripts/ui-evidence.sh --accept-new-baselines
```

That command never overwrites an existing baseline. Replace an approved image explicitly in a
normal code review so a changed baseline cannot be accepted as a side effect of running tests.

The native iOS catalogue uses the same policy with a separate baseline root:

```bash
scripts/ui-evidence-ios.sh
scripts/ui-evidence-ios.sh --accept-new-baselines
```

iOS references live under `Tests/UIEvidence/iOSBaselines/`. Generated simulator images and HTML
reports stay under `.build/ui-evidence-ios-reports/`; review them there before accepting any new
reference into the repository.
